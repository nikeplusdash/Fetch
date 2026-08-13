import SwiftUI
import FetchKit

/// The file-selection sheet (design spec §12.2) — opens on activating a
/// search result.
///
/// **The subtle part (§6, "Two kinds of file list"):** a cached result's
/// preview comes from `checkCached(listFiles: true)`, which has no side
/// effects and does not touch the user's account — but its file IDs are
/// not authoritative. This sheet never submits a magnet just from being
/// opened; it submits when the user confirms, and the selection is
/// re-resolved by relative path against the authoritative list, which is
/// what makes a preview list usable at all.
///
/// **Nothing here waits for a debrid.** Every path used to `await` a
/// submit-then-poll that does not return until the service holds the whole
/// torrent, so an uncached result meant this sheet sat on screen for minutes
/// or hours with nothing in Downloads. It submits and closes now; the wait is
/// a Downloads row (`AppModel.prepareInBackground`).
struct FilePickerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let result: SearchResult
    let indexerLabel: String

    private enum Phase {
        case loadingPreview
        case notCachedChoice
        /// No debrid provider configured — every action below would throw
        /// `AppModelError.notConfigured`, so say that instead of offering them.
        case notConfigured
        // There was a `.preparing` case here, showing "<debrid> is preparing
        // this torrent…" with a spinner, for as long as the service took. It
        // is gone because the wait is: preparation is a Downloads row now.
        // There was an `authoritative:` payload here, carrying the
        // `PreparedMagnet` a blocking submit had returned. Nothing produces
        // one now: the submit does not block, so the sheet is closed long
        // before a torrent lands and has no use for its file ids.
        case picking(files: [DebridFile])
        case error(String)
    }

    @State private var phase: Phase = .loadingPreview
    @State private var selectedPaths: Set<String> = []
    @State private var expandedFolders: Set<String> = []
    @State private var videoOnly = false
    @State private var isSubmitting = false
    @State private var submitError: String?
    @State private var routedProvider: String?
    /// True when the chosen files still have to be prepared by the debrid
    /// first — the list came from the torrent's metadata, not from a debrid
    /// that already holds it.
    @State private var needsPreparing = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch phase {
                case .loadingPreview:
                    centered { ProgressView("Loading files…") }
                case .notCachedChoice:
                    notCachedChoiceView
                case .notConfigured:
                    notConfiguredView
                case .picking(let files):
                    pickingView(files: files)
                case .error(let message):
                    centered {
                        VStack(spacing: Spacing.s8) {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(Palette.miss)
                            Text(message)
                                .font(FetchFont.callout)
                                .foregroundStyle(Palette.textSecondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(width: 580, height: 460)
        .task { await loadInitialState() }
    }

    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.s2) {
            Text(result.title)
                .font(FetchFont.title3)
                // Three, and wrapping rather than truncating. This is the one
                // place with room to say the whole name, and a release name
                // cut off at two lines in the header of the sheet you opened
                // *to identify it* is the wrong economy. Three is the ceiling
                // because a fourth starts eating the file list below.
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Text("\(result.size.map(ByteCount.format) ?? "—") · \(indexerLabel)")
                .font(FetchFont.callout)
                .foregroundStyle(Palette.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.s16)
    }

    /// The debrid this download would go to. Falls back to a generic noun
    /// rather than naming TorBox, which stopped being the only option.
    private var providerName: String { routedProvider ?? "your debrid" }

    // MARK: - Not-cached choice (§12.2, "Uncached results are not dead ends")

    private var notCachedChoiceView: some View {
        VStack(spacing: Spacing.s16) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 32))
                .foregroundStyle(Palette.miss)
            Text(model.providers.count > 1
                 ? "No configured service has this yet"
                 : "Not cached — \(providerName) will fetch this first")
                .font(FetchFont.title3)
            Text(
                "Whichever service you choose adds the torrent to your account and "
                + "fetches it. It appears in Downloads straight away and shows what "
                + "the service is doing, so there is nothing to wait here for."
            )
            .font(FetchFont.callout)
            .foregroundStyle(Palette.textSecondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, Spacing.s24)

            // **Every configured service, not just the first one.** The screen
            // named one debrid and offered one button, which reads as "TorBox
            // is where this goes" — but nothing here is TorBox-specific. The
            // cache answer already covers every configured service (that is
            // what makes it "no configured service has this"), and any of them
            // can fetch it. Naming one and hiding the rest was the sheet
            // deciding on the user's behalf.
            if model.providers.count > 1 {
                providerPicker
            }

            if let submitError {
                Text(submitError).font(FetchFont.callout).foregroundStyle(Palette.miss)
            }

            HStack(spacing: Spacing.s12) {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(addButtonTitle) { prepareAndDownloadEverything() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSubmitting)
            }
        }
    }

    // MARK: - Not configured

    /// The screen this sheet used to show in place of the truthful one. With
    /// no provider there is nothing to preview and nothing to prepare, so
    /// both buttons would have thrown; the only useful action is Settings.
    private var notConfiguredView: some View {
        VStack(spacing: Spacing.s16) {
            Image(systemName: "key.slash")
                .font(.system(size: 32))
                .foregroundStyle(Palette.attention)
            Text("No debrid provider configured")
                .font(FetchFont.title3)
            Text(
                "Fetch downloads through a debrid service. Add an API key in "
                + "Settings to check what's cached and start downloading."
            )
            .font(FetchFont.callout)
            .foregroundStyle(Palette.textSecondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, Spacing.s24)

            HStack(spacing: Spacing.s12) {
                Button("Cancel") { dismiss() }
                Button("Open Settings…") {
                    dismiss()
                    model.navigate(to: .debrid)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Picking

    private func displayedFiles(_ files: [DebridFile]) -> [DebridFile] {
        videoOnly ? files.filter(SmartFileSelection.isVideoFile) : files
    }

    private func pickingView(files: [DebridFile]) -> some View {
        let tree = FileTree.build(from: displayedFiles(files))
        return VStack(spacing: 0) {
            pickerToolbar(files: files)
            Divider()
            ScrollView {
                // Not OutlineGroup: it only indents and draws chevrons inside
                // a List, and this is a ScrollView — so a season pack rendered
                // as a flat wall with its nesting invisible.
                FileTreeOutlineView(
                    nodes: tree,
                    checkState: { checkState(for: $0) },
                    onToggle: { toggle($0) },
                    expanded: $expandedFolders)
                    .padding(.horizontal, Spacing.s12)
            }
            Divider()
            footer(files: files)
        }
    }

    private func pickerToolbar(files: [DebridFile]) -> some View {
        HStack(spacing: Spacing.s12) {
            Button("All") { selectedPaths = Set(files.map(\.name)) }
            Button("None") { selectedPaths = [] }
            Button("Invert") {
                selectedPaths = Set(files.map(\.name)).symmetricDifference(selectedPaths)
            }
            Spacer()
            Toggle("Video files only", isOn: $videoOnly)
                .toggleStyle(.checkbox)
        }
        .font(FetchFont.callout)
        .padding(.horizontal, Spacing.s12)
        .padding(.vertical, Spacing.s8)
    }

    private func footer(files: [DebridFile]) -> some View {
        let selected = files.filter { selectedPaths.contains($0.name) }
        let totalSize = selected.reduce(Int64(0)) { $0 + $1.size }

        return HStack(alignment: .center, spacing: Spacing.s12) {
            VStack(alignment: .leading, spacing: Spacing.s2) {
                Text("\(selected.count) of \(files.count) files · \(ByteCount.format(totalSize))")
                    .font(FetchFont.calloutMono)
                Text(model.downloadDirectory.path)
                    .font(FetchFont.footnote)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                // With several debrids configured the download goes to
                // whichever already has it cached. That was announced and not
                // offered — a good default, and the wrong answer whenever the
                // user has a reason of their own (an account near its slot
                // limit, a faster CDN today, one they are deliberately
                // spending). Now it is a choice with the routed one preselected.
                if model.providers.count > 1 {
                    providerPicker
                }
                if needsPreparing {
                    Text("\(providerName) will prepare this first — "
                         + "the file list came from the torrent itself.")
                        .font(FetchFont.footnote)
                        .foregroundStyle(Palette.attention)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if let submitError {
                Text(submitError)
                    .font(FetchFont.callout)
                    .foregroundStyle(Palette.miss)
                    .lineLimit(2)
            }
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button {
                confirmDownload()
            } label: {
                if isSubmitting {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Download")
                }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(selectedPaths.isEmpty || isSubmitting)
        }
        .padding(Spacing.s12)
    }

    /// Names the service the download will actually go to, so the button and
    /// the picker above it cannot say different things.
    private var addButtonTitle: String {
        guard let pinned = model.pinnedProvider,
              let chosen = model.providers.first(where: { $0.id == pinned })
        else { return "Add to \(providerName)" }
        return "Add to \(chosen.displayName)"
    }

    /// "Auto" is not a provider — it is the absence of a pin, which lets
    /// `AppModel.route` do what it does: prefer whichever service already
    /// holds this torrent. Naming the service it picked keeps the default
    /// as informative as the sentence it replaced.
    private var providerPicker: some View {
        Picker(selection: Binding(
            get: { model.pinnedProvider },
            set: { model.pinProvider($0) }
        )) {
            Text(routedProvider.map { "Auto — \($0)" } ?? "Auto")
                .tag(DebridProviderID?.none)
            ForEach(model.providers, id: \.id) { provider in
                Text(provider.displayName).tag(DebridProviderID?.some(provider.id))
            }
        } label: {
            Text("Via")
        }
        .pickerStyle(.menu)
        .font(FetchFont.footnote)
        .fixedSize()
        .help("Which debrid service downloads this")
    }

    // MARK: - Tri-state selection

    // The logic lives in `FileTreeSelection` (FetchKit) so this sheet and
    // `ArchiveItemSheet` share one implementation, and so it is covered by
    // tests — the app target has none.

    private func checkState(for node: FileTreeNode) -> Bool? {
        FileTreeSelection.checkState(for: node, selected: selectedPaths)
    }

    private func toggle(_ node: FileTreeNode) {
        selectedPaths = FileTreeSelection.toggling(node, in: selectedPaths)
    }

    // MARK: - Loading

    /// The routing decision lives in `ResultActivation` (FetchKit) rather
    /// than here, because the app target has no test target and this is
    /// exactly the logic that was wrong: it read "no provider configured"
    /// as "definitely not cached".
    /// This sheet is the torrent flow end to end — cache badge, magnet
    /// submission, file picker. A result with no torrent candidate has none of
    /// those, so it is refused here rather than half-rendered.
    ///
    /// Nothing produces such a result yet; the direct-download flow arrives in
    /// stage 7b. This is the seam it will attach to, and until then the guard
    /// is what stops a direct result from silently reaching a magnet field.
    private var torrent: (hash: String, magnet: String)? {
        guard let hash = result.infoHashHex, let magnet = result.magnetURI else { return nil }
        return (hash, magnet)
    }

    private func loadInitialState() async {
        guard let torrent else {
            phase = .error("This result is not a torrent, and direct downloads "
                           + "are not wired up yet.")
            return
        }
        routedProvider = await model.routedProviderName(forHash: torrent.hash)

        let route = ResultActivation.route(
            readiness: model.cacheReadiness,
            cacheState: model.cacheStates[torrent.hash])

        switch route {
        case .configureDebrid:
            phase = .notConfigured
        case .previewCachedFiles, .offerPrepare:
            // Both routes try for a file list. An uncached torrent — and every
            // Real-Debrid result, since RD can never report cache — used to go
            // straight to a blind "Prepare and hope". The torrent's own
            // metadata lists its files whether or not any debrid holds it, so
            // the choice can be made before committing anything to an account.
            needsPreparing = (route == .offerPrepare)
            await loadPreview()
        }
    }

    private func loadPreview() async {
        guard let torrent else { return }
        do {
            let files = try await model.previewFiles(
                rawMagnet: torrent.magnet, hash: torrent.hash) ?? []

            // No preview is neither an error nor a dead end — Prepare still
            // works, and for Real-Debrid it is the only path there ever is.
            // An empty picker with a disabled Download button was reported as
            // "nothing there to download" for a magnet that downloads fine.
            guard ResultActivation.afterPreview(fileCount: files.count) == .previewCachedFiles else {
                phase = .notCachedChoice
                return
            }
            // Recorded before any selection, so the Downloads row can later
            // show what was skipped rather than only what was taken.
            model.rememberTorrentFiles(files, forHash: torrent.hash)
            selectedPaths = SmartFileSelection.defaultSelection(for: files)
            expandedFolders = Set(FileTree.build(from: files).filter(\.isFolder).map(\.id))
            phase = .picking(files: files)
        } catch {
            phase = .error(String(describing: error))
        }
    }

    // MARK: - Actions

    /// **Nothing here waits for the debrid any more.**
    ///
    /// All three actions below used to `await` a submit-then-poll that does not
    /// return until the service has fetched the entire torrent — minutes to
    /// hours for an uncached one — with this sheet on screen the whole time and
    /// nothing in Downloads to show for a magnet that was already on the user's
    /// account. They now submit, hand the wait to a Downloads row, and close.
    ///
    /// The submit itself is still awaited: a magnet the service refuses
    /// outright belongs in front of someone who is still looking at the thing
    /// they clicked, not in a row that appears and immediately fails.
    private func prepareAndDownloadEverything() {
        submitInBackground(selecting: nil)
    }

    private func submitInBackground(selecting: Set<String>?) {
        guard let torrent else { return }
        isSubmitting = true
        submitError = nil
        Task {
            do {
                try await model.prepareInBackground(
                    torrent.magnet, selecting: selecting,
                    subfolder: model.subfolder(for: result.metadata),
                    metadata: result.metadata,
                    displayName: result.title)
                isSubmitting = false
                dismiss()
            } catch {
                isSubmitting = false
                submitError = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }

    private func confirmDownload() {
        guard case .picking = phase, !selectedPaths.isEmpty, let torrent else { return }

        // `needsPreparing` means this list came from the torrent's own metadata
        // rather than from a debrid that already holds it — so confirming here
        // commits the debrid to fetching the whole thing first, which is the
        // wait that belongs in a row. This is where an uncached torrent is
        // usually confirmed, so it is most of what was reported: without this
        // branch the picker still blocked on the fetch.
        if needsPreparing {
            submitInBackground(selecting: selectedPaths)
            return
        }

        // Cached: the debrid already holds it, so its poll returns on the
        // first look and there is nothing to wait for.
        isSubmitting = true
        submitError = nil
        Task {
            do {
                let outcome = try await model.enqueueMagnetSelecting(
                    torrent.magnet, selecting: selectedPaths,
                    subfolder: model.subfolder(for: result.metadata),
                    metadata: result.metadata
                )
                isSubmitting = false
                if outcome.missingPaths.isEmpty {
                    dismiss()
                } else {
                    // Skipped, never silently dropped (§6) — the download(s)
                    // that DID match are already queued; this only reports
                    // what didn't.
                    submitError = "\(outcome.missingPaths.count) selected file(s) "
                        + "were not found in the torrent and were skipped."
                }
            } catch {
                isSubmitting = false
                submitError = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }
}
