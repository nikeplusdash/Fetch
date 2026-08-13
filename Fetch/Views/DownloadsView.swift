import SwiftUI
import FetchKit

/// The Downloads screen (§12.3) — one row per **torrent**, expanding to its
/// files, in two modes: **In progress** (`Active` / `Queued` / `Failed`
/// sections, for work still in flight) and **Library** (completed downloads
/// grouped by media kind, in `DownloadLibrary.sectionOrder`).
///
/// It was previously one flat list of files with no sections at all, so
/// choosing three files from a torrent produced three unrelated rows and the
/// ones waiting behind the concurrency limit looked stalled rather than
/// queued. It was then one lifecycle list behind a four-case filter; that
/// filter collapsed into these two modes because "completed" is a different
/// kind of question from "active or queued or failed" — one is a lifecycle
/// still resolving, the other is a shelf of what landed.
struct DownloadsView: View {
    @Environment(AppModel.self) private var model
    @State private var showingAddMagnet = false
    @State private var expanded: Set<String> = []
    @State private var mode: Mode = .inProgress
    @State private var confirmingClear = false
    /// Which kind the Library is narrowed to, or nil for all of them.
    /// View state: it survives no longer than the screen, and narrowing a
    /// shelf is not a preference.
    @State private var libraryFilter: MediaKind?
    /// Sections the user has folded away. Collapsed rather than expanded is
    /// the stored set, so a kind that appears for the first time arrives open.
    @State private var collapsedKinds: Set<MediaKind> = []
    /// The selected row, in either mode. A `DownloadGroupKey.rawValue` —
    /// content plus attempt — so a second go at the same torrent is a
    /// different row and cannot inherit the first one's selection.
    @State private var selectedGroup: String?

    /// Two modes, not four filters. `.all` was a view over both halves of a
    /// distinction this control now makes structural: work in flight, and
    /// what has landed.
    private enum Mode: String, CaseIterable, Identifiable {
        case inProgress, library
        var id: String { rawValue }
        var title: String {
            switch self {
            case .inProgress: "In progress"
            case .library: "Library"
            }
        }
    }

    var body: some View {
        Group {
            if !model.isConfigured {
                EmptyStateView(
                    symbol: "key",
                    title: "No debrid provider",
                    message: "Add an API key in Settings to start downloading.",
                    actionTitle: "Open Settings",
                    action: { model.navigate(to: .debrid) }
                )
            } else if model.items.isEmpty && model.preparations.isEmpty {
                EmptyStateView(
                    symbol: "arrow.down.circle",
                    title: "No downloads",
                    message: "Add a magnet or pick something from Search."
                )
            } else {
                VStack(spacing: 0) {
                    modeBar
                    list
                }
            }
        }
        // A file deleted in Finder while Fetch was open would otherwise keep
        // reading "Completed" until the next relaunch, which is where
        // `LaunchRecovery` asks the same question.
        .task { model.refreshMissingFiles() }
        .navigationTitle("Downloads")
        .toolbar {
            ToolbarItem {
                Button {
                    showingAddMagnet = true
                } label: {
                    Label("Add Link", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(!model.isConfigured)
                .help("Add a magnet, a .torrent, or a hoster link (⌘N)")
            }
        }
        .sheet(isPresented: $showingAddMagnet, onDismiss: { droppedText = "" }) {
            AddLinkSheet(initialText: droppedText)
        }
        // Both a dropped magnet and a dropped .torrent open the same sheet, so
        // the availability answer and the confirm-if-uncached rule are reached
        // by one path rather than two that can drift apart.
        //
        // A dragged magnet link and a dragged file both arrive as `URL`, so
        // the scheme tells them apart — no custom `Transferable` needed.
        .dropDestination(for: URL.self) { urls, _ in
            guard model.isConfigured, let url = urls.first else { return false }

            if url.isFileURL {
                // Parsed here rather than in the sheet because a file that is
                // not a torrent should be refused *at the drop*, so the sheet
                // never opens on nothing.
                guard url.pathExtension.lowercased() == "torrent",
                      let magnet = model.magnet(fromTorrentFileAt: url)
                else { return false }
                droppedText = magnet.raw
            } else {
                guard url.scheme?.lowercased() == "magnet" else { return false }
                droppedText = url.absoluteString
            }
            showingAddMagnet = true
            return true
        }
    }

    /// What a drop put in the field, cleared when the sheet closes so a
    /// second ⌘N opens empty rather than repeating the last drop.
    @State private var droppedText = ""

    /// The mode row, with Clear Failed beside it rather than in the toolbar:
    /// it acts on what In progress is showing, and a destructive action
    /// belongs next to the thing it destroys — so it only makes sense there.
    private var modeBar: some View {
        HStack(spacing: Spacing.s8) {
            Picker("Show", selection: $mode) {
                ForEach(Mode.allCases) { option in
                    // The count rides on In progress only, and only while
                    // there is something failed to clear — on Library it
                    // would be noise unrelated to what that mode shows.
                    if option == .inProgress, model.failedGroupCount > 0 {
                        Text("\(option.title) \(model.failedGroupCount)").tag(option)
                    } else {
                        Text(option.title).tag(option)
                    }
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Spacer()

            if mode == .inProgress, model.failedGroupCount > 0 {
                Button("Clear Failed") { confirmingClear = true }
                    .help("Remove every cancelled, failed and missing row. "
                          + "Downloaded files are not deleted.")
            }
        }
        .padding(.horizontal, Spacing.s12)
        .frame(height: 36)
        .confirmationDialog(
            "Clear \(model.failedGroupCount) failed download\(model.failedGroupCount == 1 ? "" : "s")?",
            isPresented: $confirmingClear, titleVisibility: .visible
        ) {
            Button("Clear", role: .destructive) { model.clearFailed() }
            Button("Cancel", role: .cancel) {}
        } message: {
            // Said explicitly, because "clear" next to a list of downloads
            // reads as "delete what I downloaded" to anyone who has not read
            // the code.
            Text("This removes the rows only. Files already downloaded stay on disk.")
        }
    }

    @ViewBuilder
    private var list: some View {
        switch mode {
        case .inProgress:
            let sections = model.torrentGroups.filter { $0.section != .completed }
            if sections.isEmpty && model.preparations.isEmpty {
                EmptyStateView(
                    symbol: "checkmark.circle",
                    title: "Nothing in progress",
                    message: "Finished downloads are in the Library.")
            } else {
                List(selection: $selectedGroup) {
                    // Above the transfers, because that is the order things
                    // happen in: the debrid fetches the torrent, then this
                    // machine fetches the files. An uncached magnet used to
                    // spend this whole stage as a spinner in a modal sheet.
                    if !model.preparations.isEmpty {
                        Section {
                            ForEach(model.preparations) { preparation in
                                PreparingRow(preparation: preparation)
                            }
                        } header: {
                            SectionHeader(
                                title: "Preparing", count: model.preparations.count)
                        }
                    }
                    ForEach(sections, id: \.section) { section, groups in
                        Section {
                            ForEach(groups) { group in
                                TorrentRow(
                                    group: group,
                                    isExpanded: expanded.contains(group.id),
                                    isSelected: selectedGroup == group.id,
                                    onToggleExpanded: { toggle(group.id) })
                                    .tag(group.id)
                                    .onTapGesture(count: 2) { model.revealInFinder(group) }
                            }
                        } header: {
                            SectionHeader(title: section.title, count: groups.count)
                        }
                    }
                }
                .listStyle(.inset)
        .scrollContentBackground(.hidden)
            }
        case .library:
            let all = model.librarySections
            if all.isEmpty {
                EmptyStateView(
                    symbol: "books.vertical",
                    title: "Nothing here yet",
                    message: "Finished downloads collect here, newest first.")
            } else {
                VStack(spacing: 0) {
                    libraryKindBar(all)
                    // One newest-first list, not eight alphabetised headings.
                    // Grouping by kind is the right shape when you are looking
                    // *for* a kind — which is what the bar above is for. When
                    // you are looking at everything, the useful question is
                    // "what did I get recently", and that answer was buried.
                    List(selection: $selectedGroup) {
                        ForEach(model.libraryRows(kind: libraryFilter)) { group in
                            TorrentRow(
                                group: group,
                                isExpanded: expanded.contains(group.id),
                                isSelected: selectedGroup == group.id,
                                onToggleExpanded: { toggle(group.id) })
                                .tag(group.id)
                                .onTapGesture(count: 2) { model.revealInFinder(group) }
                        }
                    }
                    .listStyle(.inset)
        .scrollContentBackground(.hidden)
                    // Driven by the filter, so SwiftUI diffs the narrowed list
                    // against the wide one rather than replacing it wholesale:
                    // rows that survive stay put, and only the ones leaving
                    // animate away.
                    .animation(.snappy(duration: 0.28), value: libraryFilter)
                }
            }
        }
    }

    /// The library's kind filter, built from the kinds actually present —
    /// the same shape as the search screen's category bar, and for the same
    /// reason: a shelf you cannot narrow is a shelf you scroll.
    ///
    /// Counts come from the unfiltered set, so choosing one kind never erases
    /// the pill that chooses another. That is the one-way-door rule the facet
    /// panel already follows.
    private func libraryKindBar(
        _ sections: [(kind: MediaKind, rows: [AppModel.TorrentGroup])]
    ) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: Spacing.s6) {
                libraryPill(title: "All", count: sections.reduce(0) { $0 + $1.rows.count },
                            isSelected: libraryFilter == nil) {
                    withAnimation(.snappy(duration: 0.28)) { libraryFilter = nil }
                }
                ForEach(sections, id: \.kind) { kind, rows in
                    libraryPill(title: DownloadLibrary.title(for: kind), count: rows.count,
                                isSelected: libraryFilter == kind) {
                        // Tapping the active pill clears it, so the bar never
                        // becomes a mode you cannot leave.
                        // Animated at the source as well as on the list, so
                        // the pill's own fill moves with the rows instead of
                        // snapping ahead of them.
                        withAnimation(.snappy(duration: 0.28)) {
                            libraryFilter = (libraryFilter == kind) ? nil : kind
                        }
                    }
                }
            }
            .padding(.horizontal, Spacing.s12)
            .padding(.vertical, Spacing.s6)
        }
        .scrollIndicators(.never)
    }

    private func libraryPill(
        title: String, count: Int, isSelected: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: Spacing.s4) {
                Text(title).font(FetchFont.footnote)
                Text("\(count)")
                    .font(FetchFont.footnoteMono)
                    .foregroundStyle(isSelected ? Palette.textOnAccent : Palette.textTertiary)
            }
            .padding(.horizontal, Spacing.s8)
            .padding(.vertical, Spacing.s4)
            .foregroundStyle(isSelected ? Palette.textOnAccent : Palette.textPrimary)
            .background(
                RoundedRectangle(cornerRadius: Radius.r6)
                    .fill(isSelected ? Palette.accent : Palette.fillQuaternary))
            .contentShape(RoundedRectangle(cornerRadius: Radius.r6))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(count) downloads")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }
}

/// A torrent the debrid is still fetching into its own cloud.
///
/// Deliberately not a `DownloadRowView`. Nothing here is a local transfer:
/// the percentage is the *service's* progress pulling from the swarm, no bytes
/// have reached this machine, and there is nothing to pause. A row that looked
/// like a download would be a progress bar meaning something different from
/// every other progress bar on the screen.
///
/// This exists because the wait it represents used to happen inside a modal
/// sheet — submit an uncached magnet, then watch a spinner for as long as the
/// debrid took, with nothing in Downloads and no way to leave.
private struct PreparingRow: View {
    @Environment(AppModel.self) private var model
    let preparation: AppModel.Preparation

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s4) {
            HStack(spacing: Spacing.s8) {
                Spacer().frame(width: 12)

                VStack(alignment: .leading, spacing: Spacing.s2) {
                    Text(preparation.name)
                        .font(FetchFont.body)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(preparation.name)
                    details
                }

                Spacer()

                Button { model.cancelPreparation(preparation.id) } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Stop watching. The torrent stays on your debrid account.")
            }

            // Indeterminate until the service has said anything, because 0%
            // claims a measurement nobody has taken yet.
            if let fraction = preparation.progress?.fraction {
                ProgressTrack(fraction: fraction)
                    .padding(.leading, Spacing.s20)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .padding(.leading, Spacing.s20)
            }
        }
        .padding(.vertical, Spacing.s8)
    }

    private var details: some View {
        HStack(spacing: Spacing.s8) {
            // The service's own words — "Stalled — waiting for seeds" is the
            // difference between a torrent that is working and one that never
            // will, and a spinner says neither.
            Text(preparation.progress?.statusText ?? "Submitting…")
                .frame(width: ColumnWidth.byteCount, alignment: .leading)

            if let progress = preparation.progress {
                Text("\(Int(progress.fraction * 100))%")
                    .frame(width: ColumnWidth.rate, alignment: .leading)
                if let rate = progress.bytesPerSecond, rate > 0 {
                    Text("\(ByteCount.format(rate))/s")
                        .frame(width: ColumnWidth.rate, alignment: .leading)
                }
                if let seeds = progress.seeds {
                    Text("\(seeds) seeds")
                        .foregroundStyle(Palette.textTertiary)
                }
            }
            if !preparation.providerName.isEmpty, model.providers.count > 1 {
                Text("via \(preparation.providerName)")
                    .foregroundStyle(Palette.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .font(FetchFont.footnoteMono)
        .foregroundStyle(Palette.textSecondary)
        .lineLimit(1)
    }
}

/// One torrent: combined progress, speed and ETA, with its files underneath.
private struct TorrentRow: View {
    @Environment(AppModel.self) private var model
    let group: AppModel.TorrentGroup
    let isExpanded: Bool
    let isSelected: Bool
    let onToggleExpanded: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s4) {
            DownloadRowView(
                group: group, isExpanded: isExpanded, isSelected: isSelected,
                onToggleExpanded: onToggleExpanded)

            if isExpanded {
                // The child block is drawn as a block — a rule down its left
                // edge and a tinted background — rather than left to a 20pt
                // indent alone. Indentation by itself does not survive rows of
                // varying length; the eye needs an edge to follow, or a
                // torrent's files read as more torrents.
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(Palette.separator)
                        .frame(width: 1)
                        .padding(.vertical, Spacing.s4)

                    VStack(spacing: 0) {
                        ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { Divider().opacity(0.4) }
                            FileRow(
                                item: item, group: group,
                                path: model.relativePath(of: item.id),
                                checked: $checked)
                        }
                        // Files in the torrent that were never queued. Without
                        // them the row describes the selection rather than the
                        // torrent, and a file skipped by mistake is invisible.
                        let skipped = model.skippedFiles(for: group)
                        if !skipped.isEmpty {
                            if !group.items.isEmpty { Divider().opacity(0.4) }
                            ForEach(skipped, id: \.path) { file in
                                SkippedFileRow(file: file, group: group, checked: $checked)
                            }
                        }
                        if !checked.isEmpty {
                            Divider().opacity(0.4)
                            selectionBar
                        }
                    }
                    .padding(.leading, Spacing.s12)
                }
                .padding(.leading, Spacing.s16)
                .padding(.top, Spacing.s4)
                .background(
                    RoundedRectangle(cornerRadius: Radius.r6)
                        .fill(Palette.rowAlternate.opacity(0.6)))
            }
        }
        // Roomier than s4. Every row carries a title, a stats line and often a
        // progress bar; at 4pt those three lines of three different downloads
        // ran together into one block of text.
        .padding(.vertical, Spacing.s8)
        // A selection belongs to a visible list. Collapsing the row hides the
        // checkboxes but would leave the count armed, so re-expanding it later
        // would offer to download files the user last thought about minutes ago.
        .onChange(of: isExpanded) { _, expanded in
            if !expanded { checked = [] }
        }
    }

    /// Which files inside this row are ticked, by relative path — the key
    /// every selection is re-resolved against (§6), and the one thing that is
    /// stable whether a file has a download behind it or was never queued at
    /// all. Row-local state: a selection is a thing you are doing right now,
    /// not a preference, and it should not outlive the row being open.
    @State private var checked: Set<String> = []

    /// Appears only once something is ticked. A permanently visible bar with a
    /// disabled button would be a line of chrome under every expanded torrent,
    /// most of the time saying nothing.
    private var selectionBar: some View {
        HStack(spacing: Spacing.s8) {
            Text("\(checked.count) selected")
                .font(FetchFont.footnote)
                .foregroundStyle(Palette.textSecondary)
            Spacer()
            Button("Clear") { checked = [] }
                .buttonStyle(.link)
                .font(FetchFont.footnote)
            Button("Download \(checked.count)") {
                let paths = checked
                checked = []
                Task { await model.startOrRedownload(paths: paths, from: group) }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.vertical, Spacing.s6)
        .padding(.trailing, Spacing.s8)
    }
}

/// The checkbox on a file inside an expanded torrent.
///
/// Its own view because both kinds of row carry one and they had nothing else
/// in common: one describes a download, the other describes a file that never
/// became one.
private struct FileCheckbox: View {
    let path: String?
    @Binding var checked: Set<String>

    var body: some View {
        if let path {
            Button {
                if checked.contains(path) { checked.remove(path) } else { checked.insert(path) }
            } label: {
                Image(systemName: checked.contains(path) ? "checkmark.square.fill" : "square")
                    .foregroundStyle(checked.contains(path) ? Palette.accent : Palette.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(checked.contains(path) ? "selected" : "not selected")
        } else {
            // A file with no known path cannot be re-resolved against the
            // torrent, so it cannot be re-queued — the space is held rather
            // than closed up, so the names below it stay in one column.
            Color.clear.frame(width: IconSize.md, height: 1)
        }
    }
}

/// One file inside an expanded torrent, keeping its own controls — the design
/// decision was both levels act, not one.
private struct FileRow: View {
    @Environment(AppModel.self) private var model
    let item: DownloadItem
    let group: AppModel.TorrentGroup
    /// This file's path inside the torrent, when Fetch still knows it.
    let path: String?
    @Binding var checked: Set<String>

    var body: some View {
        HStack(spacing: Spacing.s8) {
            // Anything not actually transferring. A queued file is tickable
            // because "queued" turned out not to mean "on its way" — a
            // restored one sits there until someone starts it.
            FileCheckbox(path: item.state.isSelectableForAction ? path : nil, checked: $checked)

            StateLabel(state: item.state)
                // Wide enough for the longest label ("Cancelled") — at 72 it
                // wrapped to two lines and every file row grew to match.
                .frame(width: ColumnWidth.state, alignment: .leading)
                .lineLimit(1)

            Text(item.displayName)
                .font(FetchFont.footnote)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(item.displayName)

            Spacer()

            if item.state == .downloading, let fraction = item.fraction {
                Text("\(Int(fraction * 100))%")
                    .font(FetchFont.calloutMono)
                    .foregroundStyle(Palette.textSecondary)
            }

            Text(ByteCount.format(item.totalBytes))
                .font(FetchFont.calloutMono)
                .foregroundStyle(Palette.textTertiary)
                .frame(width: ColumnWidth.fileSize, alignment: .trailing)

            if item.state == .downloading {
                Button { model.pause(item.id) } label: { Image(systemName: "pause.fill") }
                    .buttonStyle(.borderless)
            } else if item.state.canBeStarted {
                Button { model.resume(item.id) } label: { Image(systemName: "play.fill") }
                    .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, Spacing.s2)
        .contextMenu {
            if let url = item.finalURL {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
            // A file that failed, was cancelled, or whose file has been
            // deleted has nothing left for Resume to act on — `.missing` is
            // terminal by design and a cancelled job is gone from the engine.
            // Downloading it again is a new decision, and this is where the
            // user makes it; before this the row was a dead end.
            if item.state.needsAttention, let path = model.relativePath(of: item.id) {
                Button("Download Again") {
                    Task { await model.redownload(paths: [path], from: group) }
                }
            }
            // Only offered when there is actually a rename to undo, rather
            // than shown greyed or as a no-op (§9).
            if model.canRevertRename(item.id) {
                Button("Revert Rename") { model.revertRename(item.id) }
            }
        }
    }
}

/// A file that is in the torrent but was not queued.
///
/// Greyed, because it is context for what the torrent contains rather than
/// work in flight — but no longer inert. It used to have no menu at all, so a
/// file skipped by mistake could be seen and not acted on; the only way back
/// was to find the release in Search again.
private struct SkippedFileRow: View {
    @Environment(AppModel.self) private var model
    let file: TorrentMetadata.File
    let group: AppModel.TorrentGroup
    @Binding var checked: Set<String>

    var body: some View {
        content
            .contextMenu {
                Button("Download This File") {
                    Task { await model.redownload(paths: [file.path], from: group) }
                }
                Button("Download All Skipped Files") {
                    Task {
                        await model.redownload(
                            paths: Set(model.skippedFiles(for: group).map(\.path)),
                            from: group)
                    }
                }
            }
    }

    private var content: some View {
        HStack(spacing: Spacing.s8) {
            FileCheckbox(path: file.path, checked: $checked)

            Text("Not selected")
                .font(FetchFont.footnote)
                .foregroundStyle(Palette.textTertiary)
                .frame(width: ColumnWidth.state, alignment: .leading)
                .lineLimit(1)

            Text((file.path as NSString).lastPathComponent)
                .font(FetchFont.footnote)
                .foregroundStyle(Palette.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(file.path)

            Spacer()

            Text(ByteCount.format(file.length))
                .font(FetchFont.calloutMono)
                // Tertiary, not quaternary: quaternary is 10% opacity —
                // roughly 1.2:1 — which is for separators and disabled fills,
                // not a number the user is meant to read (§4.3 wants 4.5:1).
                .foregroundStyle(Palette.textTertiary)
                .frame(width: ColumnWidth.fileSize, alignment: .trailing)
        }
        .padding(.vertical, Spacing.s2)
    }
}
