import SwiftUI
import FetchKit

/**
 The file-selection sheet (design spec §12.2) — opens on activating a
 search result, on a dropped `.torrent`, and on a pasted magnet.

 **The subtle part (§6, "Two kinds of file list"):** a cached result's
 preview comes from `checkCached(listFiles: true)`, which has no side
 effects and does not touch the user's account — but its file IDs are
 not authoritative. This sheet never submits a magnet just from being
 opened; it submits when the user confirms, and the selection is
 re-resolved by relative path against the authoritative list, which is
 what makes a preview list usable at all.

 **Nothing here waits for a debrid.** Every path used to `await` a
 submit-then-poll that does not return until the service holds the whole
 torrent, so an uncached result meant this sheet sat on screen for minutes
 or hours with nothing in Downloads. It submits and closes now; the wait is
 a Downloads row (`AppModel.prepareInBackground`).

 **Everything true about the item is in the header block.** It used to be
 scattered: size and source under the name, "via TorBox" in a row at the foot
 level with Cancel and Download, the destination a bare grey `/Users/…` line,
 and whether the service had to fetch it first as a full amber sentence below
 the buttons. They are one block now, and the footer holds only actions.
 */
struct FilePickerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let result: SearchResult
    let indexerLabel: String

    private enum Phase {
        case checkingCache
        case loadingPreview
        case notCachedChoice
        case notConfigured
        case picking(files: [DebridFile])
        case error(String)
    }

    @State private var phase: Phase = .checkingCache
    @State private var selectedPaths: Set<String> = []
    @State private var expandedFolders: Set<String> = []
    @State private var videoOnly = false
    @State private var isSubmitting = false
    @State private var routedProvider: String?
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
                    EmptyStateView(
                        symbol: "exclamationmark.triangle",
                        message: message,
                        tint: Palette.miss,
                        size: .inline)
                }
            }
            .frame(maxHeight: .infinity)
            ThemedDivider()
            footer
        }
        .frame(width: 580, height: 460)
        .task { await loadInitialState() }
        .onDisappear { model.forgetDestinationOverride(for: result) }
    }

    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().frame(maxWidth: .infinity, maxHeight: .infinity)
    }


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
            if model.providers.count > 1 {
                viaMenu
                SheetFactSeparator()
            }
            destinationReadout
        }
    }

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

    private var destinationMenu: DestinationMenuItems {
        DestinationMenuItems(
            entries: model.destinationEntries(for: result),
            root: model.destinationRoot,
            selected: model.selectedDestinationEntry(for: result),
            onSelect: { model.selectDestination($0, for: result) })
    }

    private var providerName: String { routedProvider ?? "your debrid" }


    private var notCachedChoiceView: some View {
        EmptyStateView(
            symbol: "arrow.down.circle",
            title: model.providers.count > 1
                ? "No configured service has this yet"
                : "Not cached. \(providerName) will fetch this first",
            message: "Whichever service you choose adds the torrent to your account and "
                + "fetches it. It appears in Downloads straight away and shows what "
                + "the service is doing, so there is nothing to wait here for.",
            tint: Palette.miss)
    }


    private var notConfiguredView: some View {
        EmptyStateView(
            symbol: "key.slash",
            title: "No debrid provider configured",
            message: "Fetch downloads through a debrid service. Add an API key in "
                + "Settings to check what's cached and start downloading.",
            tint: Palette.attention,
            actionTitle: "Open Settings…",
            action: {
                dismiss()
                model.navigate(to: .debrid)
            })
    }


    private func displayedFiles(_ files: [DebridFile]) -> [DebridFile] {
        videoOnly ? files.filter(SmartFileSelection.isVideoFile) : files
    }

    private func pickingView(files: [DebridFile]) -> some View {
        let tree = FileTree.build(from: displayedFiles(files))
        return VStack(spacing: 0) {
            pickerToolbar(files: files)
            ThemedDivider()
            ScrollView {
                FileTreeOutlineView(
                    nodes: tree,
                    checkState: { checkState(for: $0) },
                    onToggle: { toggle($0) },
                    expanded: $expandedFolders)
            }
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

    private func selectionCount(files: [DebridFile]) -> String {
        let chosen = selectedFiles(files).count
        return "\(chosen) of \(files.count) \(files.count == 1 ? "file" : "files")"
    }


    private var footer: some View {
        HStack(spacing: Spacing.s12) {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            if canOfferCloud {
                Button("Add to Cloud") { addToCloud() }
                    .disabled(isSubmitting)
                    .help("Adds the whole torrent to your debrid account and "
                          + "leaves it there. Nothing is downloaded to this Mac.")
            }
            PrimaryActionButton(
                title: primaryTitle,
                isBusy: isSubmitting,
                isEnabled: isPrimaryEnabled,
                action: confirm)
        }
        .padding(.horizontal, WindowMetrics.sheetInset)
        .padding(.vertical, Spacing.s12)
    }

    private var canOfferCloud: Bool {
        guard torrent != nil else { return false }
        switch phase {
        case .notConfigured, .error: return false
        default: return true
        }
    }

    private func addToCloud() {
        guard let torrent, let magnet = MagnetLink(torrent.magnet) else { return }
        isSubmitting = true
        Task {
            do {
                try await model.addToCloud(magnet: magnet)
                isSubmitting = false
                dismiss()
            } catch {
                isSubmitting = false
                report(error)
            }
        }
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


    private func checkState(for node: FileTreeNode) -> CheckState {
        CheckStateRule.state(of: node, selected: selectedPaths)
    }

    private func toggle(_ node: FileTreeNode) {
        selectedPaths = CheckStateRule.toggled(node, in: selectedPaths)
    }


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
        _ = await model.availability(forMagnet: torrent.magnet)
        routedProvider = await model.routedProviderName(forHash: torrent.hash)

        let route = ResultActivation.route(
            readiness: model.cacheReadiness,
            cacheState: model.cacheStates[torrent.hash])

        switch route {
        case .configureDebrid:
            phase = .notConfigured
        case .previewCachedFiles, .offerPrepare:
            needsPreparing = (route == .offerPrepare)
            await loadPreview()
        }
    }

    private func loadPreview() async {
        guard let torrent else { return }
        do {
            let files = try await model.previewFiles(
                rawMagnet: torrent.magnet, hash: torrent.hash) ?? []

            guard ResultActivation.afterPreview(fileCount: files.count) == .previewCachedFiles else {
                phase = .notCachedChoice
                return
            }
            model.rememberTorrentFiles(files, forHash: torrent.hash)
            selectedPaths = SmartFileSelection.defaultSelection(for: files)
            expandedFolders = Set(FileTree.build(from: files).filter(\.isFolder).map(\.id))
            phase = .picking(files: files)
        } catch {
            phase = .error(String(describing: error))
        }
    }


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

        if needsPreparing == true {
            submitInBackground(selecting: selectedPaths)
            return
        }

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

    private func report(_ error: any Error) {
        model.report(AppAlert(
            message: (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription))
    }
}
