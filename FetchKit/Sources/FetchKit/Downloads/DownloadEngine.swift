import Foundation
import FetchPluginAPI

public actor DownloadEngine {
    private struct Job {
        let request: DownloadRequest
        var state: DownloadState
        var task: Task<Void, Never>?
        var finalURL: URL?
        var pathKey: String?
        /// Which byte ranges are already on disk. Kept up to date as segments
        /// land, so pausing does not discard finished ones.
        var segmentMap: SegmentMap?
    }

    private let provider: any DebridProvider
    private let transfer: RangeTransfer
    private let segmented: SegmentedTransfer
    /// Ranges to fetch in parallel per file. 1 falls back to `RangeTransfer`'s
    /// single open-ended range.
    private var segmentsPerFile: Int
    private var maxConcurrent: Int
    private let pollInterval: TimeInterval
    private var jobs: [DownloadID: Job] = [:]
    private var queue: [DownloadID] = []
    private var running: Set<DownloadID> = []

    /// Partial-file paths with a transfer in flight. `running` alone does NOT
    /// guarantee Task 12's one-writer invariant, because `Task.cancel()` is
    /// cooperative.
    private var activePaths: Set<String> = []

    private var continuation: AsyncStream<DownloadEvent>.Continuation?
    public nonisolated let events: AsyncStream<DownloadEvent>

    public init(
        provider: any DebridProvider,
        transfer: RangeTransfer = RangeTransfer(),
        segmented: SegmentedTransfer = SegmentedTransfer(),
        // 1 by default, not 8: the segmented path builds a live URLSession,
        // and an engine constructed with an injected RangeTransfer for a test
        // would otherwise reach for the real network. The app opts in.
        segmentsPerFile: Int = 1,
        maxConcurrent: Int = 3,
        pollInterval: TimeInterval = 2.0
    ) {
        self.provider = provider
        self.transfer = transfer
        self.segmented = segmented
        self.segmentsPerFile = segmentsPerFile
        self.maxConcurrent = maxConcurrent
        self.pollInterval = pollInterval

        var captured: AsyncStream<DownloadEvent>.Continuation?
        self.events = AsyncStream { captured = $0 }
        self.continuation = captured
    }

    public var maxConcurrentSetting: Int { maxConcurrent }

    public func setSegmentsPerFile(_ value: Int) {
        segmentsPerFile = min(max(1, value), SegmentedTransfer.maxSegmentsAllowed)
    }

    /// The map for a job, so a caller can persist it and hand it back on
    /// `restore` — resume then refetches only the holes.
    public func segmentMap(for id: DownloadID) -> SegmentMap? { jobs[id]?.segmentMap }

    public func state(of id: DownloadID) -> DownloadState? { jobs[id]?.state }

    /// The request behind a job. Exposed so a caller can persist a row and
    /// rebuild it after a relaunch — the engine holds the only copy, and
    /// `.enqueued` carries just a filename and a size.
    public func request(for id: DownloadID) -> DownloadRequest? { jobs[id]?.request }

    public func setMaxConcurrent(_ value: Int) {
        maxConcurrent = max(1, min(10, value))
        pump()
    }

    public func enqueue(_ request: DownloadRequest) -> DownloadID {
        let id = DownloadID()
        jobs[id] = Job(request: request, state: .queued, task: nil, finalURL: nil)
        queue.append(id)
        emit(.enqueued(id, filename: request.file.shortName, totalBytes: request.file.size))
        pump()
        return id
    }

    /// Puts a job back after a relaunch, **without starting it**.
    ///
    /// The id is supplied rather than generated: it is the one persisted with
    /// the record, and the row's controls, its partial file, and its history
    /// all hang off it.
    ///
    /// Restored jobs are never started here, whatever `state` says. Auto-
    /// resuming on launch would have Fetch burning bandwidth before its window
    /// appeared, and `LaunchRecovery` already encodes the rule — a download
    /// interrupted by a quit comes back `.paused` and waits for user intent.
    /// `resume(_:)` is the way forward from there.
    ///
    /// Restoring an id that already exists is a no-op, so a reconcile that
    /// runs twice cannot produce two rows for one download.
    public func restore(
        id: DownloadID, request: DownloadRequest,
        state: DownloadState, bytesDownloaded: Int64,
        segmentMap: SegmentMap? = nil
    ) {
        guard jobs[id] == nil else { return }

        // A map for a different size means the link points at other content;
        // resuming against it would interleave two files.
        let usable = segmentMap.flatMap { $0.matches(totalBytes: request.file.size) ? $0 : nil }
        jobs[id] = Job(
            request: request, state: state, task: nil, finalURL: nil,
            segmentMap: usable)
        emit(.enqueued(
            id, filename: request.file.shortName, totalBytes: request.file.size))
        emit(.stateChanged(id, state))
        if bytesDownloaded > 0 {
            emit(.progress(
                id, bytesDownloaded: bytesDownloaded,
                totalBytes: request.file.size, bytesPerSecond: 0))
        }
        // Deliberately no `pump()`: nothing is queued, so nothing can start.
    }

    /// The debrid's current, authoritative file list for a torrent already on
    /// the account.
    ///
    /// What "download the files I skipped" needs: the torrent is already
    /// there, so nothing has to be submitted or waited for — but the file
    /// **ids** in a list fetched earlier are not stable, which is why §6 says
    /// selections are re-resolved by relative path. This is the list to
    /// re-resolve against. Throws `.fileNotFound` when the account no longer
    /// has it, which is a real answer and not an error to swallow: the caller
    /// re-submits.
    public func authoritativeFiles(
        in torrentID: DebridTorrentID
    ) async throws -> [DebridFile] {
        try await provider.files(in: torrentID)
    }

    /// Submit an uncached magnet, poll until the debrid has it, then queue
    /// every file it contains. This is the uncached path — the main reason to
    /// own a debrid client rather than a plain download manager.
    ///
    /// Equivalent to `enqueueMagnet(_:subfolder:destinationRoot:selecting:
    /// nil)` — kept as its own overload so existing call sites are
    /// unaffected by the selective variant below.
    public func enqueueMagnet(
        _ rawMagnet: String, subfolder: String?, destinationRoot: URL
    ) async throws -> [DownloadID] {
        try await enqueueMagnet(
            rawMagnet, subfolder: subfolder, destinationRoot: destinationRoot, selecting: nil
        ).downloadIDs
    }

    /// Selective variant of `enqueueMagnet`. `selecting` holds the relative
    /// paths (`DebridFile.name`) the user chose in the file-picker sheet —
    /// almost always selected against a **preview** file list
    /// (`checkCached(listFiles: true)`), not this torrent's authoritative
    /// one, because the picker must not submit a magnet just from being
    /// opened (that would add a torrent to the account every time someone
    /// browses a result and backs out, §6). `nil` enqueues every file,
    /// matching the plain overload above.
    ///
    /// This submits the magnet, waits for the debrid's own authoritative
    /// file list, and re-resolves `selecting` against it **by relative
    /// path** — `DebridFile.name` is stable across both responses even
    /// though the file IDs are not (§6, "Two kinds of file list"). A
    /// selected path with no match in the authoritative list is skipped and
    /// reported via `SelectiveEnqueueResult.missingPaths`, never silently
    /// dropped.
    public func enqueueMagnet(
        _ rawMagnet: String, subfolder: String?, destinationRoot: URL, selecting: Set<String>?,
        rename: (@Sendable (DebridFile) -> String?)? = nil,
        groupName: String? = nil,
        metadata: ReleaseMetadata = .unparsed
    ) async throws -> SelectiveEnqueueResult {
        let prepared = try await prepareMagnet(rawMagnet)
        return enqueueSelected(
            torrentID: prepared.torrentID, infoHashHex: prepared.infoHashHex, files: prepared.files,
            selecting: selecting, subfolder: subfolder, destinationRoot: destinationRoot,
            rename: rename, groupName: groupName, metadata: metadata
        )
    }

    // MARK: - Hosted links (7e §4)

    /// Submits a hoster link to the debrid and returns a request for the file
    /// it will serve.
    ///
    /// The counterpart of `prepareMagnet`, and the same division of labour: it
    /// commits the link to the account and waits for the service to be ready,
    /// but enqueues nothing — the caller decides whether to queue what comes
    /// back.
    ///
    /// **Polls only where the provider says to.** TorBox queues a link and
    /// reports progress; Real-Debrid and Premiumize resolve one synchronously,
    /// and polling them would wait for a state change that happened before the
    /// first look.
    public func prepareHostedLink(
        _ url: URL, subfolder: String?, destinationRoot: URL,
        groupKey: DownloadGroupKey? = nil,
        metadata: ReleaseMetadata = .unparsed
    ) async throws -> DownloadRequest {
        let id = try await provider.submitLink(url)
        let web = provider.hostedLinksNeedPreparing
            ? try await pollUntilHostedReady(id)
            : try await provider.webDownload(id: id)

        // The service's name where it has one; the URL's last component where
        // it does not. Neither is authoritative — the transfer still learns
        // the real name from `Content-Disposition` — but a queued row has to
        // say something, and "" would render as a nameless download.
        let name = web.name.isEmpty ? url.lastPathComponent : web.name

        return DownloadRequest(
            source: .debridHosted(provider: provider.id, download: id),
            file: DebridFile(
                id: DebridFileID(rawValue: id.rawValue),
                name: name,
                shortName: name,
                size: web.size ?? 0,
                mimeType: nil),
            subfolder: subfolder,
            destinationRoot: destinationRoot,
            // One pasted link is one batch, so it is one attempt — the same
            // rule a torrent's chosen files follow.
            groupKey: groupKey ?? DownloadGroupKey(content: "hosted:\(id.rawValue)"),
            metadata: metadata)
    }

    private func pollUntilHostedReady(_ id: DebridDownloadID) async throws -> DebridWebDownload {
        var delay = pollInterval
        while true {
            let web = try await provider.webDownload(id: id)

            // Thrown, not queued: a row that can never move is worse than an
            // error the user sees while they are still looking at the sheet.
            if case .failed(let reason) = web.state {
                throw DownloadError.debrid(.torrentFailed(state: reason))
            }
            if web.state.isReady { return web }

            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            delay = min(delay * 2.5, 10.0)
        }
    }

    /// Submits a magnet and polls until the debrid's authoritative file
    /// list is available — but does **not** enqueue anything.
    ///
    /// **Blocking. Do not call this from anything a user is looking at.** It
    /// does not return until the debrid holds the torrent, which for an
    /// uncached one is minutes to hours; every UI call site it once had sat
    /// on a spinner for exactly that long, and that is what
    /// `beginPreparation` exists to replace. What is left for this is the
    /// non-interactive case — `enqueueMagnet(...selecting:)` for a torrent
    /// already known to be cached, where the poll returns on the first look.
    public func prepareMagnet(_ rawMagnet: String) async throws -> PreparedMagnet {
        guard let magnet = MagnetLink(rawMagnet) else {
            throw DownloadError.unsafePath(rawMagnet)
        }
        let torrentID = try await provider.submitMagnet(rawMagnet: magnet.raw)
        let files = try await pollUntilReady(torrentID)
        return PreparedMagnet(torrentID: torrentID, infoHashHex: magnet.infoHash.hex, files: files)
    }

    /// Enqueues a subset of an already-known (authoritative) file list —
    /// the second half of both `enqueueMagnet(...selecting:)` and the
    /// "prepare, then choose" flow (`prepareMagnet` above). `selecting` is
    /// matched against `files` by relative path via `FileSelectionResolver`;
    /// `nil` enqueues all of `files`.
    /// `rename` maps a file to the path it should be written to, relative to
    /// `subfolder`. Returning nil for a file leaves it at its original path —
    /// which is what a weak parse must do (§9).
    public func enqueueSelected(
        torrentID: DebridTorrentID, infoHashHex: String, files: [DebridFile],
        selecting: Set<String>?, subfolder: String?, destinationRoot: URL,
        rename: (@Sendable (DebridFile) -> String?)? = nil,
        groupName: String? = nil,
        metadata: ReleaseMetadata = .unparsed,
        // Supplied only by `beginPreparation`, which announced a key before
        // these files existed so the row the user watched prepare is the row
        // they arrive in. Everyone else mints one here, as before.
        groupKey: DownloadGroupKey? = nil
    ) -> SelectiveEnqueueResult {
        let toEnqueue: [DebridFile]
        let missing: [String]
        if let selecting {
            let resolution = FileSelectionResolver.resolve(selectedPaths: selecting, authoritative: files)
            toEnqueue = resolution.matched
            missing = resolution.missing
        } else {
            toEnqueue = files
            missing = []
        }

        // One attempt for the whole batch: picking three files from a torrent
        // is one go at one torrent, so the three share a row. Minted here
        // rather than per file — this call *is* the queueing action — and
        // minted per call, so queueing the same torrent again is a new row
        // instead of joining whatever the last attempt left behind.
        let group = groupKey ?? DownloadGroupKey(content: infoHashHex)

        fetchLog(toEnqueue.isEmpty ? .warn : .info, "enqueue",
                 "matched \(toEnqueue.count) of \(files.count) file(s), "
                 + "\(missing.count) unmatched")
        let ids = toEnqueue.map { file in
            enqueue(DownloadRequest(
                providerID: provider.id,
                torrentID: torrentID,
                file: file,
                infoHashHex: infoHashHex,
                subfolder: subfolder,
                destinationRoot: destinationRoot,
                renamedPath: rename?(file),
                groupKey: group,
                groupName: groupName,
                metadata: metadata
            ))
        }
        return SelectiveEnqueueResult(downloadIDs: ids, missingPaths: missing)
    }

    // MARK: - Preparing in the background

    /// How many consecutive "ready, but no files" answers to accept before
    /// calling it a fault. A real service can report finished a moment before
    /// its file listing catches up; it does not do so five times running.
    static let emptyReadyPollsBeforeGivingUp = 5

    /// Preparations still polling, so they can be cancelled and so a torn-down
    /// engine does not leave a poll running against an account.
    private var preparations: [PreparationID: Task<Void, Never>] = [:]

    /// Submits a magnet and **returns**, leaving the debrid's own fetch to run
    /// as a Downloads row instead of as an `await` the caller is holding.
    ///
    /// This is the uncached path the report is about. `enqueueMagnet` and
    /// `prepareMagnet` both submit and then poll to completion before
    /// returning, and every caller of theirs is a sheet — so an uncached
    /// torrent meant a spinner for as long as the debrid took to fetch the
    /// whole thing, with nothing in Downloads and no way to leave. The magnet
    /// was already on the user's account by then; only the *evidence* of it
    /// was trapped in a modal.
    ///
    /// The submission itself is still awaited: a magnet the service refuses
    /// outright should be reported where the user is still looking at it,
    /// rather than as a row that appears and immediately fails. Everything
    /// after that — the poll, the enqueue of the files it resolves to — runs
    /// on this engine's own `Task` and reports through `events`.
    ///
    /// `selecting` is carried through to the `enqueueSelected` this performs
    /// when the torrent lands, and is matched by relative path against the
    /// authoritative list exactly as the blocking path does (§6).
    @discardableResult
    public func beginPreparation(
        _ rawMagnet: String, selecting: Set<String>?, subfolder: String?,
        destinationRoot: URL,
        rename: (@Sendable (DebridFile) -> String?)? = nil,
        groupName: String? = nil,
        metadata: ReleaseMetadata = .unparsed,
        displayName: String? = nil
    ) async throws -> PreparationID {
        guard let magnet = MagnetLink(rawMagnet) else {
            throw DownloadError.unsafePath(rawMagnet)
        }
        let torrentID = try await provider.submitMagnet(rawMagnet: magnet.raw)

        let id = PreparationID()
        let infoHashHex = magnet.infoHash.hex
        // Minted here rather than in `enqueueSelected`, so the row the user
        // watches prepare is the row the files arrive in. One queueing action,
        // one row — the same rule, extended backwards over the wait.
        let group = DownloadGroupKey(content: infoHashHex)

        fetchLog(.info, "prepare",
                 "submitted \(LogRedaction.token(infoHashHex)) to \(provider.id.rawValue)")
        emit(.preparationStarted(
            id, name: displayName ?? groupName ?? magnet.displayName ?? infoHashHex,
            groupKey: group))

        preparedTorrents[id] = torrentID
        preparations[id] = Task { [weak self] in
            guard let self else { return }
            do {
                let files = try await self.pollReportingProgress(id, torrentID: torrentID)
                guard !Task.isCancelled else { return }
                await self.finishPreparation(
                    id, torrentID: torrentID, infoHashHex: infoHashHex, files: files,
                    selecting: selecting, subfolder: subfolder,
                    destinationRoot: destinationRoot, rename: rename,
                    group: group, groupName: groupName, metadata: metadata)
            } catch is CancellationError {
                await self.forgetPreparation(id)
            } catch {
                await self.failPreparation(id, error: error)
            }
        }
        return id
    }

    /// Stops polling, takes the row away, and — unless told otherwise —
    /// deletes the torrent from the debrid account.
    ///
    /// **Deleting is the default now, and it is the right one.** This used to
    /// leave the torrent behind on the argument that the user had "already
    /// paid the wait for it". That is backwards for the case it actually
    /// covers: cancelling an *uncached* torrent means cancelling a fetch the
    /// service is running right now, and leaving it means the account goes on
    /// downloading something nobody wants, holding a slot until it finishes.
    /// Cancel should cancel.
    public func cancelPreparation(_ id: PreparationID, deletingRemotely: Bool = true) {
        guard let task = preparations.removeValue(forKey: id) else { return }
        task.cancel()
        if deletingRemotely, let torrentID = preparedTorrents.removeValue(forKey: id) {
            // Detached from the cancel: the row goes now, and a service that
            // is slow to answer must not hold it on screen. A delete that
            // fails leaves a torrent on the account, which is recoverable in
            // their web UI; a cancel that hangs is not recoverable at all.
            Task { [provider] in try? await provider.delete(torrent: torrentID) }
        }
        preparedTorrents[id] = nil
        emit(.preparationCancelled(id))
    }

    /// Removes a torrent from the debrid account.
    ///
    /// Exposed because cancelling a *download* means the same thing as
    /// cancelling a preparation: the copy on the service was made for this
    /// download and nothing else is going to use it.
    public func deleteRemoteTorrent(_ torrentID: DebridTorrentID) async {
        try? await provider.delete(torrent: torrentID)
    }

    /// Which torrent each live preparation is polling, so cancelling one can
    /// delete it.
    private var preparedTorrents: [PreparationID: DebridTorrentID] = [:]

    public var activePreparations: [PreparationID] { Array(preparations.keys) }

    private func forgetPreparation(_ id: PreparationID) {
        preparations[id] = nil
        preparedTorrents[id] = nil
    }

    private func failPreparation(_ id: PreparationID, error: any Error) {
        preparations[id] = nil
        preparedTorrents[id] = nil
        fetchLog(.error, "prepare", "gave up: \(String(describing: error))")
        emit(.preparationFailed(id, (error as? DownloadError) ?? .network(String(describing: error))))
    }

    private func finishPreparation(
        _ id: PreparationID, torrentID: DebridTorrentID, infoHashHex: String,
        files: [DebridFile], selecting: Set<String>?, subfolder: String?,
        destinationRoot: URL, rename: (@Sendable (DebridFile) -> String?)?,
        group: DownloadGroupKey, groupName: String?, metadata: ReleaseMetadata
    ) {
        preparations[id] = nil
        // Kept, not deleted: the files are about to download from it.
        preparedTorrents[id] = nil
        fetchLog(.info, "prepare",
                 "ready with \(files.count) file(s); "
                 + "selecting \(selecting.map { "\($0.count)" } ?? "all")")
        // Announced before the rows arrive, so the UI can retire the preparing
        // row and let the file rows take its place in one update rather than
        // showing both.
        emit(.preparationFinished(id))
        _ = enqueueSelected(
            torrentID: torrentID, infoHashHex: infoHashHex, files: files,
            selecting: selecting, subfolder: subfolder,
            destinationRoot: destinationRoot, rename: rename,
            groupName: groupName, metadata: metadata, groupKey: group)
    }

    /// `pollUntilReady`, reporting what it sees on the way.
    ///
    /// The blocking path throws away every intermediate answer; this is the
    /// same loop with the progress the debrid was already sending forwarded to
    /// the row.
    private nonisolated func pollReportingProgress(
        _ id: PreparationID, torrentID: DebridTorrentID
    ) async throws -> [DebridFile] {
        var delay = pollInterval
        var readyButEmpty = 0
        while true {
            try Task.checkCancellation()
            let torrent = try await provider.torrent(id: torrentID)

            if case .failed(let reason) = torrent.state {
                throw DownloadError.debrid(.torrentFailed(state: reason))
            }
            await self.emitProgress(id, PreparationProgress(
                fraction: torrent.progress,
                seeds: torrent.seeds,
                bytesPerSecond: torrent.downloadSpeed,
                eta: torrent.eta,
                state: torrent.state))

            if torrent.isReady { return torrent.files }

            // **A service that says it is done but lists nothing is a bug, not
            // a wait.** Twice now that exact shape has produced a row that
            // polls for ever with no explanation: TorBox reporting `uploading`
            // for a finished torrent, and Premiumize mapping its folder id to
            // an empty file array. Both looked identical from here — "not
            // ready yet" — and both were permanent.
            //
            // So it is given a few polls to settle (a real service can report
            // finished a moment before its listing catches up) and then
            // reported. A stalled row that says why beats one that spins.
            if torrent.state.isReady || torrent.filesArePresent {
                readyButEmpty += 1
                if readyButEmpty >= Self.emptyReadyPollsBeforeGivingUp {
                    throw DownloadError.debrid(.providerRejected(
                        detail: "the service reports this torrent as ready but lists no files"))
                }
            } else {
                readyButEmpty = 0
            }

            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            delay = min(delay * 2.5, 10.0)
        }
    }

    private func emitProgress(_ id: PreparationID, _ progress: PreparationProgress) {
        // Only for a preparation still running: a cancelled one must not go on
        // painting progress after its row has gone.
        guard preparations[id] != nil else { return }
        emit(.preparationProgress(id, progress))
    }

    /// Polls a submitted torrent until the debrid has its file list ready,
    /// backing off 2s -> 5s -> 10s, capping at 10s (spec §6). Shared by
    /// `prepareMagnet` and (through it) both `enqueueMagnet` overloads.
    private func pollUntilReady(_ torrentID: DebridTorrentID) async throws -> [DebridFile] {
        var delay = pollInterval
        while true {
            let torrent = try await provider.torrent(id: torrentID)

            if case .failed(let reason) = torrent.state {
                throw DownloadError.debrid(.torrentFailed(state: reason))
            }
            // `torrent.isReady`, not `torrent.state.isReady`: a finished
            // TorBox torrent reports `uploading` once it starts seeding, and
            // this loop used to wait for a `.completed` that never came back.
            // The non-empty file check has moved into `isReady` itself.
            if torrent.isReady {
                return torrent.files
            }
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            delay = min(delay * 2.5, 10.0)
        }
    }

    public func cancel(_ id: DownloadID, deletePartial: Bool) async {
        guard jobs[id] != nil else { return }
        jobs[id]?.task?.cancel()
        // Wait for the cancelled task to actually stop before this job's
        // path can be considered free — `Task.cancel()` only requests
        // cooperative cancellation, it does not guarantee the in-flight
        // `RangeTransfer.transfer()` call has stopped writing yet.
        await releasePath(id)
        // Re-read AFTER the await. `releasePath` only returns once the old
        // task has fully run, including its own finish()/fail() callback — a
        // download that finished during this window is on disk under its
        // final name; reporting it cancelled would strand a real file.
        guard var job = jobs[id], job.state != .completed else { return }
        job.task = nil
        job.state = .cancelled
        jobs[id] = job
        running.remove(id)
        queue.removeAll { $0 == id }

        if deletePartial, let url = try? partialURL(for: job.request) {
            try? FileManager.default.removeItem(at: url)
        }
        emit(.stateChanged(id, .cancelled))
        pump()
    }

    /// Forgets a job entirely, so its row can leave the Downloads list.
    ///
    /// **Why this had to be written.** `DownloadEvent.removed` was declared and
    /// handled in `AppModel`, but nothing ever emitted it — so a cancelled row
    /// was permanent, and cancelling the same download twice left two corpses
    /// with no way to clear either. There was no "clear" to expose because
    /// there was nothing to call.
    ///
    /// A job still running is cancelled first: removing a row whose transfer
    /// kept writing would leave a file growing on disk with nothing in the UI
    /// admitting to it.
    ///
    /// The partial file goes with the row, for the same reason `cancel` deletes
    /// it — once the row is gone nothing can resume it, so the `.fetchpart` is
    /// unreachable bytes. A **completed** download's final file is never
    /// touched: clearing a row is a bookkeeping act, not a delete.
    public func remove(_ id: DownloadID) async {
        guard let job = jobs[id] else {
            // **Still say it is gone.** Returning silently here left rows that
            // no engine owned permanently stuck: `AppModel` clears a row when
            // it hears `.removed`, and nothing else emits it.
            //
            // A row loses its engine whenever the provider list is rebuilt —
            // saving a key, enabling a service, starring one — because
            // `configureProviders` replaces every engine and empties the map
            // that says which row belongs to which. The row's Remove and
            // Clear Failed then asked a *new* engine to remove a job it had
            // never heard of, and it declined, and the row stayed for good.
            //
            // Removing something that is not here is not an error. The
            // postcondition — "this id is not in this engine" — already holds,
            // and saying so is what lets the caller finish tidying up.
            emit(.removed(id))
            return
        }

        if job.state == .downloading || job.state == .preparing {
            await cancel(id, deletePartial: false)
        }
        // Re-read after the await: `cancel` waits for the in-flight task to
        // stop, and a download that finished in that window is on disk under
        // its final name.
        let settled = jobs[id]
        // `pathKey` rather than recomputing `partialURL`: that call creates
        // directories, pre-checks disk space and disambiguates against files
        // that exist *now* — three side effects with no business in a delete,
        // and a different answer than the path actually written. A job that
        // never started has no pathKey and no partial file to remove.
        if settled?.state != .completed, let key = settled?.pathKey ?? job.pathKey {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: key))
        }

        jobs[id] = nil
        queue.removeAll { $0 == id }
        running.remove(id)
        if let key = settled?.pathKey ?? job.pathKey { activePaths.remove(key) }
        emit(.removed(id))
        pump()
    }

    public func pause(_ id: DownloadID) async {
        guard jobs[id]?.state == .downloading else { return }
        jobs[id]?.task?.cancel()
        await releasePath(id)
        // Re-read AFTER the await. `releasePath` only returns once the old
        // task has fully run, including its own finish()/fail() callback — so
        // a job that legitimately completed during this window must not be
        // clobbered back to .paused with its finalURL discarded.
        guard var job = jobs[id], job.state == .downloading else { return }
        job.task = nil
        job.state = .paused
        jobs[id] = job
        running.remove(id)
        emit(.stateChanged(id, .paused))
        pump()
    }

    /// Callers must `await` this call to completion before assuming a paused
    /// job is safe to `resume` — `pause` is `async` precisely because it
    /// waits for the prior transfer to actually stop (see `releasePath`). An
    /// un-awaited `pause` racing a `resume` can leave `resume`'s guard
    /// observing a job that is still `.downloading`, in which case `resume`
    /// silently no-ops rather than doing anything unsafe.
    /// Starts a job that is not running: paused, failed, or **queued**.
    ///
    /// `.queued` is the one that had to be added, and it was a dead end. A
    /// restored job is put back in `.queued` without being added to the
    /// engine's queue and without a pump — deliberately, so relaunching does
    /// not spend bandwidth before the window appears. But nothing could start
    /// it afterwards either: this guard rejected `.queued`, and the Downloads
    /// row offers Resume on the same rule, so a download restored as queued
    /// had no button, no menu item and no code path that would ever run it.
    /// An install with 124 such rows had 124 downloads it could not start.
    public func resume(_ id: DownloadID) {
        guard var job = jobs[id],
              job.state == .paused || job.state == .failed || job.state == .queued
        else { return }
        job.state = .queued
        jobs[id] = job
        if !queue.contains(id) { queue.append(id) }
        emit(.stateChanged(id, .queued))
        pump()
    }

    /// Test helper: block until the job reaches a settled state.
    public func waitUntilSettled(_ id: DownloadID) async throws {
        while let state = jobs[id]?.state,
              state == .queued || state == .downloading || state == .preparing {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: - Scheduling

    private func pump() {
        var deferred: [DownloadID] = []
        while running.count < maxConcurrent, !queue.isEmpty {
            let id = queue.removeFirst()
            guard jobs[id]?.state == .queued else { continue }
            if !start(id) { deferred.append(id) }
        }
        queue.insert(contentsOf: deferred, at: 0)
    }

    /// Returns `false` when another job already owns this destination path —
    /// the caller (`pump`) must defer, not drop, the job in that case.
    @discardableResult
    private func start(_ id: DownloadID) -> Bool {
        guard var job = jobs[id] else { return true }
        guard let partial = try? partialURL(for: job.request) else {
            fail(id, error: DownloadError.unsafePath(job.request.file.name))
            return true
        }
        let pathKey = partial.standardizedFileURL.path
        guard !activePaths.contains(pathKey) else { return false }
        activePaths.insert(pathKey)
        job.pathKey = pathKey
        running.insert(id)
        job.state = .downloading
        emit(.stateChanged(id, .downloading))

        let request = job.request
        let segments = segmentsPerFile
        // Restored map, or a fresh plan. A size of 0 means the debrid never
        // declared one, and an undeclared length cannot be split.
        let startingMap = job.segmentMap
            ?? (request.file.size > 0
                ? SegmentMap(totalBytes: request.file.size, segments: segments)
                : nil)
        job.segmentMap = startingMap

        job.task = Task { [provider, transfer, segmented] in
            do {
                if segments > 1, let startingMap, !startingMap.isComplete {
                    try await self.runSegmented(
                        id, request: request, partial: partial,
                        startingMap: startingMap,
                        segmented: segmented, transfer: transfer, provider: provider)
                } else {
                    try await self.runWhole(
                        id, request: request, partial: partial,
                        transfer: transfer, provider: provider)
                }

                let final = partial.deletingPathExtension()   // strip .fetchpart
                try? FileManager.default.removeItem(at: final)
                try FileManager.default.moveItem(at: partial, to: final)
                await self.finish(id, at: final)
            } catch {
                await self.fail(id, error: error)
            }
        }
        jobs[id] = job
        return true
    }

    /// One whole-file transfer over a single connection.
    ///
    /// `nonisolated` on purpose, like `runSegmented` below: this runs for the
    /// life of the download, and an actor-isolated method would hold the
    /// engine for that whole time — no other job could start, pause or report.
    private nonisolated func runWhole(
        _ id: DownloadID, request: DownloadRequest, partial: URL,
        transfer: RangeTransfer, provider: any DebridProvider
    ) async throws {
        try await transfer.transfer(
            to: partial,
            expectedSize: request.file.size,
            linkProvider: {
                try await Self.resolveURLRetrying(for: request, using: provider)
            },
            onProgress: { bytes in
                Task { await self.report(id, bytes: bytes, total: request.file.size) }
            }
        )
    }

    /// Parallel byte ranges, with the two recoveries the single-connection
    /// path already had and this one did not.
    ///
    /// **An expired link is re-resolved once.** `RangeTransfer` has always
    /// relinked on a 403/410; the segmented path called the same condition
    /// "range not supported" and gave up. The retry starts from the map as it
    /// stands *now*, not from the map this attempt began with, so segments
    /// that landed before the link died are kept rather than refetched.
    ///
    /// **A link that ignores `Range` falls back to one whole-file stream.**
    /// The old behaviour — fail the download — was wrong twice over: the file
    /// is perfectly downloadable over one connection, and this repo's own
    /// measurements say one connection is the *fastest* option here anyway.
    private nonisolated func runSegmented(
        _ id: DownloadID, request: DownloadRequest, partial: URL,
        startingMap: SegmentMap,
        segmented: SegmentedTransfer, transfer: RangeTransfer,
        provider: any DebridProvider
    ) async throws {
        var map = startingMap
        var relinked = false

        while true {
            // Resolved once per attempt rather than per segment: a debrid link
            // is valid for hours, and asking eight times would be eight times
            // the rate-limit cost for one file.
            let url = try await Self.resolveURLRetrying(for: request, using: provider)
            do {
                _ = try await segmented.transfer(
                    from: url, to: partial, map: map,
                    onProgress: { progress in
                        Task {
                            await self.report(
                                id, bytes: progress.bytesComplete,
                                total: progress.totalBytes)
                        }
                    },
                    onSegmentComplete: { range in
                        Task { await self.recordSegment(id, range: range) }
                    })
                return
            } catch DownloadError.linkExpired where !relinked {
                relinked = true
                // What actually landed, per the engine's own record — the
                // local `map` is this attempt's starting point and knows
                // nothing about the segments that completed during it.
                map = await self.segmentMap(for: id) ?? map
                if map.isComplete { return }
            } catch DownloadError.rangeNotSupported {
                // `SegmentedTransfer.preallocate` has already grown the
                // partial to the full length, and `RangeTransfer` reads that
                // length as "how much is done". Handing it a zero-filled
                // full-size file would make it take its `offset ==
                // expectedSize` shortcut, pass a size-only `verify`, and
                // rename a file of zeros to its final name. Truncate first.
                try Data().write(to: partial)
                try await self.runWhole(
                    id, request: request, partial: partial,
                    transfer: transfer, provider: provider)
                return
            }
        }
    }

    /// Records a landed range, so a pause keeps what finished rather than
    /// discarding every segment that had completed.
    private func recordSegment(_ id: DownloadID, range: Range<Int64>) {
        guard var job = jobs[id] else { return }
        job.segmentMap?.markComplete(range)
        jobs[id] = job
    }

    /// Awaits a job's in-flight task to its actual, provable end before
    /// freeing its destination path for reuse — the file is not "free" the
    /// moment `Task.cancel()` is called, only once the task has stopped.
    private func releasePath(_ id: DownloadID) async {
        guard let job = jobs[id] else { return }
        await job.task?.value          // Task<Void, Never> — cannot throw
        if let key = job.pathKey { activePaths.remove(key) }
    }

    private func partialURL(for request: DownloadRequest) throws -> URL {
        let resolved = try DestinationResolver.resolve(
            root: request.destinationRoot,
            subfolder: request.subfolder,
            relativePath: request.renamedPath ?? request.file.name
        )

        try FileManager.default.createDirectory(
            at: resolved.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try PreflightCheck.assertSpace(
            needed: request.file.size, at: resolved.deletingLastPathComponent()
        )

        // Never silently overwrite an existing file.
        let directory = resolved.deletingLastPathComponent()
        let unique = PathSanitizer.disambiguate(resolved.lastPathComponent) { candidate in
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).path)
        }
        return directory.appendingPathComponent(unique).appendingPathExtension("fetchpart")
    }

    private func report(_ id: DownloadID, bytes: Int64, total: Int64) {
        emit(.progress(id, bytesDownloaded: bytes, totalBytes: total, bytesPerSecond: 0))
    }

    private func finish(_ id: DownloadID, at url: URL) {
        guard var job = jobs[id], job.state != .cancelled else { return }
        job.state = .completed
        job.finalURL = url
        job.task = nil
        jobs[id] = job
        running.remove(id)
        if let key = job.pathKey { activePaths.remove(key) }
        emit(.stateChanged(id, .completed))
        emit(.finished(id, at: url))
        pump()
    }

    private func fail(_ id: DownloadID, error: any Error) {
        guard var job = jobs[id] else { return }
        fetchLog(.error, "download",
                 "failed \(LogRedaction.path(job.request.file.name)) "
                 + "via \(job.request.providerID.rawValue): \(String(describing: error))")
        // A cooperative cancel unwinds the transfer with CancellationError.
        // That is the expected outcome of pause/cancel, not a failure — without
        // this the UI flashes "Failed" on every pause, because the losing task
        // reports before the pause writes its own state.
        if job.state == .cancelled || job.state == .paused { return }
        if error is CancellationError { return }
        job.state = .failed
        job.task = nil
        jobs[id] = job
        running.remove(id)
        if let key = job.pathKey { activePaths.remove(key) }
        let mapped = (error as? DownloadError) ?? .network(String(describing: error))
        emit(.stateChanged(id, .failed))
        emit(.failed(id, mapped))
        pump()
    }

    private func emit(_ event: DownloadEvent) { continuation?.yield(event) }
}

extension DownloadEngine {
    /// The one place a request turns into a URL to fetch.
    ///
    /// Switching over `DownloadSource` rather than testing `directURL != nil`
    /// is what lets a third case exist at all — the ternary this replaced had
    /// two branches and silently treated everything else as a torrent.
    ///
    /// **There is deliberately no fallback.** A hosted download whose
    /// unrestrict fails must fail: fetching the hoster URL itself would
    /// succeed and write an HTML page named like a movie.
    /// `HostedDownloadTests.aHostedDownloadNeverFallsBackToFetchingTheHosterPage`
    /// is the assertion, and it checks the directory is empty rather than
    /// merely that the download failed.
    /// `resolveURL`, with a slower retry than the HTTP layer's.
    ///
    /// A cached TorBox download failed on a 500 from `requestdl`. That request
    /// *is* retried — `RetryPolicy` covers 5xx three times — but at 0.5s and
    /// 1s, which is far too quick for the kind of 500 a debrid returns when it
    /// is briefly overloaded or rate-limit-adjacent. All three attempts land
    /// inside the same bad second and the download dies with a transient
    /// error.
    ///
    /// So: three more tries, seconds apart, before giving up. Only for errors
    /// that can plausibly clear — an expired key or a deleted file is not
    /// going to fix itself, and retrying it just makes the user wait longer
    /// for the same answer.
    static func resolveURLRetrying(
        for request: DownloadRequest, using provider: any DebridProvider,
        delays: [TimeInterval] = [2, 5, 10]
    ) async throws -> URL {
        var attempt = 0
        while true {
            do {
                return try await resolveURL(for: request, using: provider)
            } catch {
                guard attempt < delays.count, isWorthRetrying(error) else { throw error }
                try await Task.sleep(nanoseconds: UInt64(delays[attempt] * 1_000_000_000))
                attempt += 1
            }
        }
    }

    /// Whether waiting could plausibly change the answer.
    static func isWorthRetrying(_ error: any Error) -> Bool {
        switch error as? DebridError {
        case .network: true
        // The service said no in its own words. Some of those are transient
        // ("DATABASE_ERROR"), and the ones that are not — an unknown id, a
        // rejected magnet — fail again identically a few seconds later, which
        // costs the user ten seconds and no correctness.
        case .providerRejected: true
        case .unauthorized, .fileNotFound, .linkExpired, .unsupportedOperation: false
        // Not a debrid error at all — a direct download's URL is already the
        // answer and cannot fail to resolve.
        case .torrentFailed, .none: false
        }
    }

    static func resolveURL(
        for request: DownloadRequest, using provider: any DebridProvider
    ) async throws -> URL {
        switch request.source {
        case .directHTTP(let url):
            // Already the answer. Asking the debrid would be both pointless
            // and wrong: stage 7b's whole claim is that this path works with
            // no debrid configured at all.
            return url
        case .debridTorrent(_, let torrent, let file):
            return try await provider.downloadURL(torrent: torrent, file: file)
        case .debridHosted(_, let download):
            return try await provider.downloadURL(web: download)
        }
    }
}
