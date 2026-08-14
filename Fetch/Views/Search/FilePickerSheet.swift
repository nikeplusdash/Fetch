import SwiftUI
import FetchKit

/// The file-selection sheet (design spec §12.2) — opens on activating a
/// search result, on a dropped `.torrent`, and on a pasted magnet.
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
///
/// **Everything true about the item is in the header block.** It used to be
/// scattered: size and source under the name, "via TorBox" in a row at the foot
/// level with Cancel and Download, the destination a bare grey `/Users/…` line,
/// and whether the service had to fetch it first as a full amber sentence below
/// the buttons. They are one block now, and the footer holds only actions.
struct FilePickerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let result: SearchResult
    /// Which indexer this came from, or empty for something the user added
    /// themselves.
    ///
    /// **Empty rather than "Added by hand".** That label sat in the slot an
    /// indexer name occupies, so a dropped magnet reported its provenance as
    /// though it were a source you could go back to. The user knows they just
    /// dropped it; the sheet saying so is a fact with no reader.
    let indexerLabel: String

    private enum Phase {
        /// Asking every capable service whether it already holds this.
        ///
        /// **A separate phase because the answer was being guessed.** Routing
        /// read `cacheStates[hash]` the instant the sheet opened, and a hash
        /// nobody had finished checking reads as nil — which routes to Prepare.
        /// So a torrent a debrid *did* hold was labelled **Queued** whenever
        /// the sheet won the race against the network, which for a magnet
        /// dropped or pasted by hand is most of the time. The pill is a claim
        /// about somebody's account; it waits until that claim is true.
        case checkingCache
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

    @State private var phase: Phase = .checkingCache
    @State private var selectedPaths: Set<String> = []
    @State private var expandedFolders: Set<String> = []
    @State private var videoOnly = false
    @State private var isSubmitting = false
    @State private var routedProvider: String?
    /// True when the chosen files still have to be prepared by the debrid
    /// first — the list came from the torrent's metadata, not from a debrid
    /// that already holds it.
    ///
    /// Nil until the availability answer lands, which is what keeps the pill
    /// from appearing before there is anything for it to say.
    @State private var needsPreparing: Bool?

    var body: some View {
        VStack(spacing: 0) {
            header
            ThemedDivider()
            Group {
                switch phase {
                case .checkingCache:
                    centered { ProgressView("Checking your services…") }
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
            ThemedDivider()
            footer
        }
        .frame(width: 580, height: 460)
        .task { await loadInitialState() }
        // An override belongs to one download, not to this torrent for ever.
        .onDisappear { model.forgetDestinationOverride(for: result) }
    }

    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - The header block

    private var header: some View {
        SheetHeaderBlock(title: result.title, tag: statusTag) {
            if let size = result.size {
                Text(ByteCount.format(size))
                SheetFactSeparator()
            }
            if !indexerLabel.isEmpty {
                Text(indexerLabel)
                SheetFactSeparator()
            }
            // **A fact, not an action.** "Via" had a row of its own at the
            // foot of the sheet, level with Cancel and Download, as though
            // choosing a debrid were a third thing you could do here. Which
            // service serves this download is something true about it.
            if model.providers.count > 1 {
                viaMenu
                SheetFactSeparator()
            }
            destinationReadout
        }
    }

    /// **Queued** or **Ready**, or nothing while the answer is out.
    ///
    /// It replaces a full amber sentence at the far corner of the sheet from
    /// the thing it described. One bit of information was wearing eleven words;
    /// the words survive as the tooltip.
    private var statusTag: TagPill? {
        guard let needsPreparing else { return nil }
        return needsPreparing
            ? TagPill(
                title: "Queued", tone: .waiting,
                explanation: "\(providerName) will prepare this first. The file "
                    + "list came from the torrent itself.")
            : TagPill(
                title: "Ready", tone: .ready,
                explanation: "\(providerName) already holds this, so it starts "
                    + "downloading immediately.")
    }

    /// Which debrid serves this download, as a fact that happens to be
    /// changeable.
    ///
    /// With several configured, the download goes to whichever already has it
    /// cached. That was announced and not offered — a good default, and the
    /// wrong answer whenever the user has a reason of their own (an account
    /// near its slot limit, a faster CDN today, one they are deliberately
    /// spending). "Auto" is not a provider: it is the absence of a pin, which
    /// is why it names the service the routing picked.
    private var viaMenu: some View {
        Menu {
            Picker("Via", selection: Binding(
                get: { model.pinnedProvider },
                set: { model.pinProvider($0) }
            )) {
                Text(routedProvider.map { "Auto, currently \($0)" } ?? "Auto")
                    .tag(DebridProviderID?.none)
                ForEach(model.providers, id: \.id) { provider in
                    Text(provider.displayName).tag(DebridProviderID?.some(provider.id))
                }
            }
            .pickerStyle(.inline)
        } label: {
            Text("via \(pinnedName ?? providerName)")
                .font(FetchFont.callout)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Which debrid service downloads this")
    }

    /// The pinned service's own name, so the readout and the download cannot
    /// say different things.
    private var pinnedName: String? {
        guard let pinned = model.pinnedProvider else { return nil }
        return model.providers.first { $0.id == pinned }?.displayName
    }

    private var destinationReadout: some View {
        DestinationReadoutButton(
            readout: model.destinationReadout(for: result),
            isOverridden: model.hasDestinationOverride(for: result),
            menu: destinationMenu)
    }

    /// Built once and handed to both the readout and the Download chevron, so
    /// the two cannot come to offer different places.
    private var destinationMenu: DestinationMenuItems {
        DestinationMenuItems(
            entries: model.destinationEntries(for: result),
            root: model.destinationRoot,
            selected: model.selectedDestinationEntry(for: result),
            onSelect: { model.selectDestination($0, for: result) })
    }

    /// The debrid this download would go to. Falls back to a generic noun
    /// rather than naming TorBox, which stopped being the only option.
    private var providerName: String { routedProvider ?? "your debrid" }

    // MARK: - Not-cached choice (§12.2, "Uncached results are not dead ends")

    private var notCachedChoiceView: some View {
        VStack(spacing: Spacing.s16) {
            Image(systemName: "arrow.down.circle")
                .font(FetchFont.largeTitle)
                .foregroundStyle(Palette.miss)
            Text(model.providers.count > 1
                 ? "No configured service has this yet"
                 : "Not cached. \(providerName) will fetch this first")
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Not configured

    /// The screen this sheet used to show in place of the truthful one. With
    /// no provider there is nothing to preview and nothing to prepare, so
    /// both buttons would have thrown; the only useful action is Settings.
    private var notConfiguredView: some View {
        VStack(spacing: Spacing.s16) {
            Image(systemName: "key.slash")
                .font(FetchFont.largeTitle)
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

            Button("Open Settings…") {
                dismiss()
                model.navigate(to: .debrid)
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Picking

    private func displayedFiles(_ files: [DebridFile]) -> [DebridFile] {
        videoOnly ? files.filter(SmartFileSelection.isVideoFile) : files
    }

    private func pickingView(files: [DebridFile]) -> some View {
        let tree = FileTree.build(from: displayedFiles(files))
        return VStack(spacing: 0) {
            pickerToolbar(files: files)
            ThemedDivider()
            ScrollView {
                // Not OutlineGroup: it only indents and draws chevrons inside
                // a List, and this is a ScrollView — so a season pack rendered
                // as a flat wall with its nesting invisible.
                //
                // No horizontal padding of its own: the rows carry
                // `sheetInset` themselves, so the file names line up with the
                // name in the header rather than nearly.
                FileTreeOutlineView(
                    nodes: tree,
                    checkState: { checkState(for: $0) },
                    onToggle: { toggle($0) },
                    expanded: $expandedFolders)
            }
            // Inside the list's border, because it counts that list.
            ListFooterBar(
                leading: selectionCount(files: files),
                trailing: ByteCount.format(selectedSize(files: files)))
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
        .padding(.horizontal, WindowMetrics.sheetInset)
        .padding(.vertical, RowHeight.rowPaddingV)
    }

    private func selectedFiles(_ files: [DebridFile]) -> [DebridFile] {
        files.filter { selectedPaths.contains($0.name) }
    }

    private func selectedSize(files: [DebridFile]) -> Int64 {
        selectedFiles(files).reduce(Int64(0)) { $0 + $1.size }
    }

    /// "1 of 6 files", and "1 of 1 file" — a count that says "1 files" is the
    /// kind of thing that makes the rest of a sheet look unfinished.
    private func selectionCount(files: [DebridFile]) -> String {
        let chosen = selectedFiles(files).count
        return "\(chosen) of \(files.count) \(files.count == 1 ? "file" : "files")"
    }

    // MARK: - The footer

    /// Cancel, then the split button. Nothing else: the count moved into the
    /// list's own footer, the path became a control in the header, and the
    /// amber sentence became the pill.
    private var footer: some View {
        HStack(spacing: Spacing.s12) {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            PrimaryActionButton(
                title: primaryTitle,
                isBusy: isSubmitting,
                isEnabled: isPrimaryEnabled,
                action: confirm)
        }
        .padding(.horizontal, WindowMetrics.sheetInset)
        .padding(.vertical, Spacing.s12)
    }

    private var primaryTitle: String {
        if case .notCachedChoice = phase { return "Add to \(providerName)" }
        return "Download"
    }

    private var isPrimaryEnabled: Bool {
        switch phase {
        case .picking: !selectedPaths.isEmpty
        case .notCachedChoice: true
        case .checkingCache, .loadingPreview, .notConfigured, .error: false
        }
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
        // **Waited on, not sampled.** `availability(forMagnet:)` asks every
        // service that can answer and does not return until they have — so the
        // routing below reads a settled fact rather than whatever had arrived
        // by the time the sheet opened. `CacheStatusStore` dedupes by TTL, so
        // a hash already checked for a search badge costs nothing here.
        //
        // Which service wins is `DebridRouter`'s existing rule and needs no
        // pin: whoever already holds it, in the user's own row order, and the
        // topmost when nobody does.
        _ = await model.availability(forMagnet: torrent.magnet)
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
            //
            // This is the moment the pill's fact becomes true, so this is the
            // moment it appears.
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
    private func confirm() {
        switch phase {
        case .notCachedChoice:
            submitInBackground(selecting: nil)
        case .picking:
            confirmDownload()
        default:
            break
        }
    }

    private func submitInBackground(selecting: Set<String>?) {
        guard let torrent else { return }
        isSubmitting = true
        Task {
            do {
                try await model.prepareInBackground(
                    torrent.magnet, selecting: selecting,
                    subfolder: model.plannedSubfolder(for: result),
                    metadata: result.metadata,
                    displayName: result.title)
                isSubmitting = false
                dismiss()
            } catch {
                isSubmitting = false
                report(error)
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
        if needsPreparing == true {
            submitInBackground(selecting: selectedPaths)
            return
        }

        // Cached: the debrid already holds it, so its poll returns on the
        // first look and there is nothing to wait for.
        isSubmitting = true
        Task {
            do {
                let outcome = try await model.enqueueMagnetSelecting(
                    torrent.magnet, selecting: selectedPaths,
                    subfolder: model.plannedSubfolder(for: result),
                    metadata: result.metadata
                )
                isSubmitting = false
                if outcome.missingPaths.isEmpty {
                    dismiss()
                } else {
                    // Skipped, never silently dropped (§6) — the download(s)
                    // that DID match are already queued; this only reports
                    // what didn't. It goes to the error presenter rather than
                    // to a red line in the footer: the sheet is about to
                    // close, and the downloads it started are real.
                    model.report(AppAlert(
                        message: "\(outcome.missingPaths.count) selected file(s) were "
                            + "not found in the torrent and were skipped."))
                    dismiss()
                }
            } catch {
                isSubmitting = false
                report(error)
            }
        }
    }

    /// **Not a coloured line at the foot of the sheet.** The submit error used
    /// to render into the footer, where it pushed the buttons around and was
    /// gone the moment the sheet closed — which is exactly when it mattered.
    private func report(_ error: any Error) {
        model.report(AppAlert(
            message: (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription))
    }
}
