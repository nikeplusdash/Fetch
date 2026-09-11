import Foundation
import FetchKit
import FetchPluginAPI

/**
 What the Cloud pill knows: what each configured service holds, and how to
 reach one item's bytes.

 Nothing here is persisted. A cloud listing is true only for as long as the
 service says so — an item can be deleted from the account in another tab —
 so it is fetched when the pill is opened, kept for the session, and
 refetched on Refresh. Writing it to `DownloadStore` would give the user a
 list that outlives the thing it describes.
 */
extension AppModel {
    enum CloudLoadState: Equatable {
        case idle, loading, loaded
        case failed(String)
    }

    func provider(_ id: DebridProviderID) -> (any DebridProvider)? {
        providers.first { $0.id == id }
    }

    /**
     Fills `cloudRows` from every configured service at once.

     One service being down does not empty the screen: each listing is
     awaited independently, failures are collected and named in a single
     notice, and whatever did come back is still shown. Only when every
     service failed is this a failed load — with nothing to show, saying so
     beats an empty list that looks like an empty account.

     Results are reassembled in `providers` order before aggregation, not
     in the order the task group happened to finish, so a deduped row keeps
     the preferred service as its representative.
     */
    func refreshCloud() async {
        guard !providers.isEmpty else {
            cloudRows = []
            cloudLoadState = .idle
            return
        }

        cloudLoadState = .loading
        let asked = providers

        var byProvider: [String: [DebridCloudItem]] = [:]
        var failed: [DebridProviderID] = []
        await withTaskGroup(of: (DebridProviderID, [DebridCloudItem]?).self) { group in
            for service in asked {
                group.addTask { (service.id, try? await service.listAccountContents()) }
            }
            for await (id, items) in group {
                if let items { byProvider[id.rawValue] = items } else { failed.append(id) }
            }
        }

        cloudRows = CloudLibrary.rows(
            from: asked.flatMap { byProvider[$0.id.rawValue] ?? [] })

        let names = failed.map { provider($0)?.displayName ?? $0.rawValue }.sorted()
        if failed.count == asked.count {
            cloudLoadState = .failed(
                "Could not reach \(names.joined(separator: ", ")).")
        } else {
            cloudLoadState = .loaded
            if !failed.isEmpty {
                report("Could not reach \(names.joined(separator: ", ")). "
                       + "Showing what your other services returned.")
            }
        }
    }

    /**
     Ensures an item carries its files.

     Real-Debrid's listing omits them, so the first time a row is opened,
     played or downloaded its files are fetched once and the caller keeps
     the returned copy. An item that already has files is returned
     untouched, which is what keeps this safe to call on every path that
     needs files without any of them checking first.
     */
    func hydrateFiles(_ item: DebridCloudItem) async -> DebridCloudItem {
        guard item.files.isEmpty, let service = provider(item.provider) else { return item }

        switch item.origin {
        case .torrent(let torrent):
            return item.replacingFiles((try? await service.files(in: torrent)) ?? [])
        case .web(let web):
            let download = try? await service.webDownload(id: web)
            return item.replacingFiles(download?.files ?? [])
        }
    }

    /**
     The same, for a whole row: hydrates the member a play or download will
     resolve through, and hands back the row with that member replaced.
     */
    func hydrated(_ row: CloudRow) async -> CloudRow {
        guard let first = row.members.first, first.files.isEmpty else { return row }
        let full = await hydrateFiles(first)
        guard full.files != first.files else { return row }

        return CloudRow(
            key: row.key, name: row.name,
            size: row.size > 0 ? row.size : full.files.reduce(0) { $0 + $1.size },
            kind: TorrentContentKind.kind(files: full.files.map(\.name), name: full.name)
                ?? row.kind,
            providers: row.providers,
            members: [full] + row.members.dropFirst())
    }
}

/**
 Streaming a cloud item, which is the default way to open one.

 Everything a service holds can be streamed, so opening a file, a folder or
 a whole torrent builds one playlist of credentialed URLs and hands it over
 in a single open. Downloading is the explicit alternative, not the default.
 */
extension AppModel {
    /**
     Every file of a cloud item as a playlist candidate.

     The path is the file's full name inside the torrent, so `PlaylistPlan`
     orders subfolders the way the picker showed them rather than the way
     the service listed them. The source carries a token, not a URL: links
     are minted per request and expire, so resolving one for a file nobody
     plays would be a wasted call and a stale link by the time it mattered.
     */
    func cloudCandidates(for item: DebridCloudItem) -> [PlaylistCandidate] {
        item.files.map { file in
            PlaylistCandidate(
                path: file.name,
                source: .cloud(token: CloudPlaybackToken(
                    provider: item.provider, origin: item.origin, file: file.id).encoded()))
        }
    }

    /**
     The candidates under one folder of a cloud item, however deep.
     `PlaylistPlan` owns the prefix rule, which is the one that has to know
     "Season 1" is not a prefix of "Season 10".
     */
    func cloudCandidates(for item: DebridCloudItem, under folder: String) -> [PlaylistCandidate] {
        PlaylistPlan.candidates(cloudCandidates(for: item), under: folder)
    }

    func playlistOffer(forCloud item: DebridCloudItem) -> PlaylistPlan.Offer? {
        PlaylistPlan.offer(
            candidates: cloudCandidates(for: item),
            defaultPlayer: defaultExternalPlayer,
            installed: installedPlayers)
    }

    /**
     Turns each cloud token into a credentialed URL, asking the right method
     of the right provider.

     A lookup that fails is simply absent from the map, which is what
     `PlaylistPlan.resolution` narrates as "Playing 9 of 12" — the playlist
     closes up rather than stopping at the bad link.

     Sequential on purpose. These are per-file link mints against one
     account, and a season pack fanned out concurrently is thirty requests
     arriving at a rate limiter at once; the player cannot start before the
     list is whole either way.
     */
    func resolveCloudURLs(_ tokens: [String]) async -> [String: URL] {
        var resolved: [String: URL] = [:]
        for token in tokens {
            guard let parsed = CloudPlaybackToken(encoded: token),
                  let service = provider(parsed.provider)
            else { continue }
            do {
                switch parsed.origin {
                case .torrent(let torrent):
                    resolved[token] = try await service.downloadURL(
                        torrent: torrent, file: parsed.file)
                case .web(let web):
                    resolved[token] = try await service.downloadURL(web: web)
                }
            } catch { continue }
        }
        return resolved
    }

    /**
     Plays a cloud playlist, resolving every link first.

     The async sibling of `playPlaylist`, which stays local-only. This is
     the first caller that actually fills the `resolved:` map
     `PlaylistPlan.resolution` was written to take — until now every cloud
     item was handed an empty map and dropped as unreachable.
     */
    func playCloud(_ items: [PlaylistItem], in player: ExternalPlayer) async {
        let tokens = items.compactMap { item -> String? in
            guard case .cloud(let token) = item.source else { return nil }
            return token
        }
        let resolution = PlaylistPlan.resolution(
            for: items, resolved: await resolveCloudURLs(tokens))

        if let notice = resolution.notice { report(AppAlert(message: notice)) }
        guard resolution.opens else { return }
        stream(resolution.urls, in: player)
    }

    /**
     Plays one file of a cloud item. No offer gate: that exists to decide
     whether a *playlist* menu is worth showing, and one file is a Play.

     Still built through `PlaylistPlan.items(from:)` rather than by hand, so
     a file no player can take is refused here by the same rule that refuses
     it in a playlist, instead of opening a player on nothing.
     */
    func playCloudFile(
        _ file: DebridFile, of item: DebridCloudItem, in player: ExternalPlayer
    ) async {
        let candidate = PlaylistCandidate(
            path: file.name,
            source: .cloud(token: CloudPlaybackToken(
                provider: item.provider, origin: item.origin, file: file.id).encoded()))
        await playCloud(PlaylistPlan.items(from: [candidate]), in: player)
    }

    /**
     The files of an `.onCloud` / `.cloudQueued` Downloads row as stream
     candidates — one debrid token per file, resolved against the account at
     play time. The cloud sibling of `playlistCandidates(for:)`, which
     sources from local disk; an `.onCloud` row has no local bytes, so that
     one yields nothing for it.
     */
    func cloudGroupCandidates(for group: TorrentGroup) -> [PlaylistCandidate] {
        group.items.compactMap { item in
            guard item.state.isCloudOnly, let request = requestForDownload[item.id]
            else { return nil }
            return PlaylistCandidate(
                path: request.file.name,
                source: .cloud(token: CloudPlaybackToken(
                    provider: request.providerID,
                    origin: .torrent(request.torrentID),
                    file: request.file.id).encoded()))
        }
    }

    /**
     Whether a cloud row has anything a player would take — the gate for
     showing a Play item on its menu.
     */
    func cloudGroupIsPlayable(_ group: TorrentGroup) -> Bool {
        !installedPlayers.isEmpty
            && cloudGroupCandidates(for: group).contains {
                ExternalPlayer.canPlay(fileNamed: $0.path)
            }
    }

    /**
     Streams every playable file of a cloud row as one playlist. No offer
     gate: that decides whether a playlist *menu* is worth showing, and a
     double-click on a folder is always a Play.
     */
    func streamCloudGroup(_ group: TorrentGroup, in player: ExternalPlayer) async {
        await playCloud(
            PlaylistPlan.items(from: cloudGroupCandidates(for: group)), in: player)
    }

    /**
     Streams one file row of a cloud row.
     */
    func streamCloudGroupFile(_ item: DownloadItem, in player: ExternalPlayer) async {
        guard item.state.isCloudOnly, let request = requestForDownload[item.id] else { return }
        let candidate = PlaylistCandidate(
            path: request.file.name,
            source: .cloud(token: CloudPlaybackToken(
                provider: request.providerID,
                origin: .torrent(request.torrentID),
                file: request.file.id).encoded()))
        await playCloud(PlaylistPlan.items(from: [candidate]), in: player)
    }

    /**
     Remembers which installed player a plain double-click uses. `nil` goes
     back to "first installed", which is what `DefaultPlayer.resolve` does
     with no stored value.
     */
    func setDefaultPlayer(_ player: ExternalPlayer?) {
        if let player {
            UserDefaults.standard.set(player.rawValue, forKey: DefaultPlayer.defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: DefaultPlayer.defaultsKey)
        }
    }
}

/**
 Downloading a cloud item, which is the explicit alternative to streaming.
 */
extension AppModel {
    /**
     Downloads the chosen files of a cloud item through the same engine call
     a re-download uses.

     The item is already on the service, so there is no magnet to submit and
     no provider to route to — this enters the existing flow lower down,
     with only the files left to select. Hydration happens first because
     Real-Debrid's listing carries no files and `enqueueSelected` needs the
     authoritative list to match the chosen paths against.

     The item's own name becomes the subfolder, which is what keeps a season
     pack's episodes together on disk the way the picker path already does.
     */
    func downloadCloudFiles(_ paths: Set<String>, from item: DebridCloudItem) async {
        let item = await hydrateFiles(item)

        guard let service = provider(item.provider) else {
            report("The service “\(item.name)” came from is no longer configured.")
            return
        }
        guard let engine = engines[item.provider.rawValue] ?? self.engine else {
            report("The service “\(item.name)” came from can no longer download.")
            return
        }

        switch item.origin {
        case .torrent(let torrent):
            guard !item.files.isEmpty else {
                report("“\(item.name)” no longer lists any files on \(service.displayName).")
                return
            }
            let outcome = await engine.enqueueSelected(
                torrentID: torrent,
                infoHashHex: item.infoHashHex ?? "",
                files: item.files,
                selecting: paths.isEmpty ? nil : paths,
                subfolder: item.name,
                destinationRoot: downloadDirectory,
                rename: renamePlan(torrentMetadata: ReleaseMetadata.unparsed),
                groupName: item.name,
                metadata: ReleaseMetadata.unparsed)

            for id in outcome.downloadIDs {
                remember(id, Routed(provider: service, engine: engine))
            }
            if !outcome.missingPaths.isEmpty {
                report("\(outcome.missingPaths.count) of the files chosen are no longer "
                       + "in this item and were skipped.")
            }

        case .web(let web):
            guard let url = try? await service.downloadURL(web: web) else {
                report("Could not get a download link for “\(item.name)”.")
                return
            }
            _ = await enqueueDirect(
                [(name: item.name, size: item.size, url: url)],
                contentKey: item.id, groupName: item.name)
        }
    }

    /**
     Downloads a whole cloud row through its preferred member — the service
     the row's badges list first.
     */
    func downloadCloud(_ row: CloudRow) async {
        guard let member = row.members.first else { return }
        await downloadCloudFiles([], from: member)
    }
}

/**
 Keeping the fetched rows current as the screen asks for more of them.
 */
extension AppModel {
    /**
     Hydrates one row in place, once.

     Expanding a Real-Debrid row is the first moment its files are needed,
     and the row is the only thing that knows it has been opened. Matching
     on `key` rather than an index because the list can be replaced by a
     Refresh while the fetch is in flight, and writing back to a stale
     index would rewrite somebody else's row.
     */
    func hydrateRow(_ row: CloudRow) async {
        guard row.members.first?.files.isEmpty == true else { return }
        let full = await hydrated(row)
        guard let index = cloudRows.firstIndex(where: { $0.key == row.key }) else { return }
        cloudRows[index] = full
    }
}

/**
 Queue on Cloud: adding a magnet or hoster link to the debrid account as a
 persisted row that transfers nothing, and pumping the ones the service has
 not finished until it has the files.

 A ready torrent becomes one `.onCloud` row per file. An unready one becomes
 a single `.cloudQueued` placeholder for the whole torrent, replaced in the
 same group by real file rows once `CloudPromotion` says the service has
 them — which is what lets the row move Downloads → Library without jumping.
 Nothing here calls `engine.enqueue`; a cloud row is created inert through
 `engine.restore` and reaches `items` by the same `.enqueued` → `.stateChanged`
 event fold every restored row uses.
 */
extension AppModel {
    /**
     Submits a magnet to the routed service and writes its cloud rows.

     A torrent the service already has lands as `.onCloud` file rows
     immediately; one it has only accepted lands as a single placeholder and
     starts the promotion pump.
     */
    func addToCloud(magnet: MagnetLink) async throws {
        let routed = try await route(magnet.raw)
        guard engines[routed.provider.id.rawValue] != nil else {
            throw AppModelError.notConfigured
        }
        pinProvider(nil)
        let hash = magnet.infoHash.hex

        let existing = items.filter {
            requestForDownload[$0.id]?.infoHashHex.lowercased() == hash.lowercased()
        }
        if !existing.isEmpty {
            if existing.contains(where: { !$0.state.isCloudOnly }) {
                report("You are already downloading this.")
            } else {
                report("Already in your cloud.")
            }
            return
        }

        let torrentID = try await routed.provider.submitMagnet(rawMagnet: magnet.raw)
        let answer = try? await routed.provider.torrent(id: torrentID)

        let groupKey = DownloadGroupKey(content: hash)
        let name = answer?.name ?? magnet.displayName ?? hash

        let files: [DebridFile]
        let state: DownloadState
        let message: String
        if answer?.isReady == true {
            files = answer!.files
            state = .onCloud
            message = "Already in your cloud."
        } else {
            files = [CloudPromotion.placeholderFile(name: name, size: answer?.size ?? 0)]
            state = .cloudQueued
            message = "Queued on \(routed.provider.displayName)."
        }

        for file in files {
            let request = DownloadRequest(
                providerID: routed.provider.id, torrentID: torrentID,
                file: file, infoHashHex: hash,
                subfolder: nil, destinationRoot: downloadDirectory,
                groupKey: groupKey, groupName: name)
            persistCloudRow(request, state: state, reAddSource: magnet.raw)
        }

        report(message)
        if state == .cloudQueued { startCloudPollIfNeeded() }
    }

    /**
     Submits a hoster link to a named service and writes its one cloud row.

     A hoster link is always a single file, so there is no per-file
     fan-out. For Real-Debrid and Premiumize the download is essentially
     always ready by the time it is looked up, which the `.onCloud` path
     handles.
     */
    func addToCloud(hostedLink url: URL, using providerID: DebridProviderID) async throws {
        guard let provider = providers.first(where: { $0.id == providerID }),
              engines[providerID.rawValue] != nil
        else {
            throw AppModelError.notConfigured
        }

        if let existing = (try? downloadStore?.loadAll())?
            .first(where: { $0.cloudReAddSource == url.absoluteString }) {
            let liveState = items.first { $0.id.rawValue == existing.id }?.state
            let onCloud = (liveState ?? existing.state).isCloudOnly
            report(onCloud ? "Already in your cloud." : "You are already downloading this.")
            return
        }

        let downloadID = try await provider.submitLink(url)
        let web = try? await provider.webDownload(id: downloadID)

        let name = (web?.name).flatMap { $0.isEmpty ? nil : $0 } ?? url.lastPathComponent
        let ready = web?.state.isReady ?? false
        let file = web?.files.first ?? DebridFile(
            id: DebridFileID(rawValue: downloadID.rawValue),
            name: name, shortName: name, size: web?.size ?? 0, mimeType: nil)

        let request = DownloadRequest(
            source: .debridHosted(provider: providerID, download: downloadID),
            file: file, subfolder: nil, destinationRoot: downloadDirectory,
            groupKey: DownloadGroupKey(content: "hosted:\(downloadID.rawValue)"),
            groupName: name)
        persistCloudRow(
            request, state: ready ? .onCloud : .cloudQueued,
            reAddSource: url.absoluteString)

        report(ready ? "Already in your cloud." : "Queued on \(provider.displayName).")
        if !ready { startCloudPollIfNeeded() }
    }

    /**
     Writes one persisted, inert cloud row and registers it the way a
     restored row is registered: saved to `DownloadStore`, handed to the
     engine through `restore` (which starts no transfer), and remembered so
     the pump can read its torrent and file ids back.
     */
    @discardableResult
    func persistCloudRow(
        _ request: DownloadRequest, state: DownloadState, reAddSource: String?
    ) -> DownloadID {
        let id = DownloadID()
        guard let engine = engines[request.providerID.rawValue] else { return id }
        try? downloadStore?.save(
            id: id, request: request, state: state, bytesDownloaded: 0,
            cloudReAddSource: reAddSource)
        Task { await engine.restore(id: id, request: request, state: state, bytesDownloaded: 0) }
        if let provider = providers.first(where: { $0.id == request.providerID }) {
            remember(id, Routed(provider: provider, engine: engine))
        }
        requestForDownload[id] = request
        return id
    }

    /**
     Starts the promotion pump if it is not already running.

     One task for every `.cloudQueued` row. Each pass asks
     `CloudPromotion.torrentsToPoll` which torrents are still incomplete,
     `CloudPollSchedule.due` which of those are due this tick, polls each by
     id — never the account listing — and stops itself once nothing is
     queued.
     */
    func startCloudPollIfNeeded() {
        guard cloudPollTask == nil else { return }
        cloudPollTask = Task { @MainActor [weak self] in
            defer { self?.cloudPollTask = nil }
            while !Task.isCancelled {
                guard let self else { return }
                let queuedRows: [(torrentID: DebridTorrentID, state: DownloadState)] = self.items
                    .filter { $0.state == .cloudQueued }
                    .compactMap { item in
                        guard let request = self.requestForDownload[item.id] else { return nil }
                        /**
                         Hosted rows are excluded: their `torrentID` is a
                         web-download id, which `provider.torrent(id:)`
                         cannot resolve, so polling one would fail every
                         pass with no diagnosis and no ceiling. A hosted
                         link that is not ready immediately stays
                         `.cloudQueued` until a manual touch, which is
                         acceptable for v1.
                         */
                        if case .debridHosted = request.source { return nil }
                        return (request.torrentID, item.state)
                    }
                let wanted = CloudPromotion.torrentsToPoll(rows: queuedRows)
                if wanted.isEmpty { return }
                self.cloudPollSchedule.retain(only: Set(wanted))
                for id in self.cloudPollSchedule.due(from: wanted) {
                    await self.pollOneCloudTorrent(id)
                }
                try? await Task.sleep(for: CloudPromotion.pollInterval)
            }
        }
    }

    /**
     Polls one torrent by id, records the answer for the backoff schedule,
     updates the row's diagnosis sub-line, and promotes the placeholder when
     `CloudPromotion` says the service has the files.
     */
    func pollOneCloudTorrent(_ id: DebridTorrentID) async {
        let owner = items.first {
            $0.state == .cloudQueued && requestForDownload[$0.id]?.torrentID == id
        }
        guard let owner,
              let providerID = requestForDownload[owner.id]?.providerID,
              let provider = providers.first(where: { $0.id == providerID })
        else { return }

        let answer = try? await provider.torrent(id: id)
        cloudPollSchedule.record(id, answer: answer)

        for item in items
        where item.state == .cloudQueued && requestForDownload[item.id]?.torrentID == id {
            cloudDiagnoses[item.id] = CloudPromotion.diagnosis(for: answer)
        }

        let stillThere = items.contains {
            $0.state == .cloudQueued && requestForDownload[$0.id]?.torrentID == id
        }
        guard case .promote(let files) = CloudPromotion.outcome(
            for: answer, placeholderStillPresent: stillThere)
        else { return }

        promotePlaceholder(id, into: files)
    }

    /**
     Replaces a whole-torrent placeholder with one `.onCloud` row per real
     file, **in the placeholder's own group** — same `groupKey`, `groupName`,
     `infoHashHex`, `subfolder`, `destinationRoot` and provider/torrent ids —
     so the promoted rows move to the Library without the row jumping. The
     placeholder row and its diagnosis are then cleared.
     */
    func promotePlaceholder(_ id: DebridTorrentID, into files: [DebridFile]) {
        guard let placeholder = items.first(where: { item in
            guard item.state == .cloudQueued,
                  let request = requestForDownload[item.id] else { return false }
            return request.torrentID == id && CloudPromotion.isPlaceholder(request.file.id)
        }), let ph = requestForDownload[placeholder.id] else { return }

        let reAddSource = (try? downloadStore?.loadAll())?
            .first { $0.id == placeholder.id.rawValue }?.cloudReAddSource

        for file in files {
            let request = DownloadRequest(
                providerID: ph.providerID, torrentID: ph.torrentID,
                file: file, infoHashHex: ph.infoHashHex,
                subfolder: ph.subfolder, destinationRoot: ph.destinationRoot,
                renamedPath: ph.renamedPath,
                groupKey: ph.groupKey, groupName: ph.groupName, metadata: ph.metadata)
            persistCloudRow(request, state: .onCloud, reAddSource: reAddSource)
        }

        remove(placeholder.id)
        cloudDiagnoses[placeholder.id] = nil
    }
}

/**
 Queue on Cloud, the row's own actions: what "Open on <service>", "Download"
 and "Cancel" on a `.cloudQueued` / `.onCloud` row actually do.
 */
extension AppModel {
    /**
     The provider a cloud row belongs to, from the live request if it is
     still in memory, otherwise from its persisted record.
     */
    private func cloudProviderID(for id: DownloadID) -> DebridProviderID? {
        if let live = requestForDownload[id]?.providerID { return live }
        guard let raw = (try? downloadStore?.loadAll())?
            .first(where: { $0.id == id.rawValue })?.providerID
        else { return nil }
        return DebridProviderID(rawValue: raw)
    }

    /**
     The debrid's own web page, for a cloud row's "Open on <service>".
     No service documents a per-torrent URL, so it is the home page.
     */
    func serviceHomePage(for id: DownloadID) -> URL? {
        guard let providerID = cloudProviderID(for: id) else { return nil }
        return DebridKind.kind(for: providerID)?.homePageURL
    }

    /**
     The service name a cloud row's menu says, e.g. "Open on Real-Debrid".
     Falls back to a generic phrase when the provider can no longer be named.
     */
    func serviceName(for id: DownloadID) -> String {
        guard let providerID = cloudProviderID(for: id) else { return "your debrid" }
        return DebridKind.kind(for: providerID)?.displayName ?? "your debrid"
    }

    /**
     Starts the ordinary local download an `.onCloud` row stands for.

     Re-resolved by relative path, not by the stored file id: a service that
     re-fetched the torrent mints new ids and only the path survives. If the
     service has dropped it, the stored magnet is re-submitted once first.
     */
    func downloadFromCloud(_ id: DownloadID) async {
        guard let record = (try? downloadStore?.loadAll())?
                .first(where: { $0.id == id.rawValue }),
              let engine = engines[record.providerID],
              let provider = providers.first(where: { $0.id.rawValue == record.providerID })
        else { report("That download's service is no longer configured."); return }

        var torrentID = DebridTorrentID(rawValue: record.debridTorrentID)
        var files = (try? await provider.files(in: torrentID)) ?? []
        if files.isEmpty, let reAdd = record.cloudReAddSource, !reAdd.isEmpty,
           let fresh = try? await provider.submitMagnet(rawMagnet: reAdd) {
            torrentID = fresh
            files = (try? await provider.files(in: fresh)) ?? []
        }

        guard let match = FileSelectionResolver.resolve(
            selectedPaths: [record.relativePath], authoritative: files).matched.first
        else {
            report("Your debrid service no longer has this file.")
            return
        }

        let request = DownloadRequest(
            providerID: provider.id, torrentID: torrentID, file: match,
            infoHashHex: record.infoHash, subfolder: record.subfolder,
            destinationRoot: URL(fileURLWithPath: record.destinationPath),
            groupKey: record.groupKeyRaw.map { DownloadGroupKey(rawValue: $0) },
            groupName: record.groupName)
        let newID = await engine.enqueue(request)
        remember(newID, Routed(provider: provider, engine: engine))
        requestForDownload[newID] = request
        cloudDiagnoses[id] = nil
        remove(id)
    }

    /**
     Deletes the account's copy of a torrent it has not finished fetching.
     The row IS that copy, so leaving the torrent on the account would make
     Cancel mean nothing. The row goes only if the delete succeeded.
     */
    func cancelCloudQueued(_ id: DownloadID) async {
        guard let record = (try? downloadStore?.loadAll())?
                .first(where: { $0.id == id.rawValue }),
              let provider = providers.first(where: { $0.id.rawValue == record.providerID })
        else { return }

        do {
            try await provider.delete(
                torrent: DebridTorrentID(rawValue: record.debridTorrentID))
        } catch {
            report("Your debrid service would not delete this: "
                   + ((error as? LocalizedError)?.errorDescription
                      ?? error.localizedDescription))
            return
        }
        cloudDiagnoses[id] = nil
        remove(id)
    }
}
