import SwiftUI
import FetchKit

/// The Downloads screen: **one list, newest first**.
///
/// It has been three shapes. A flat list of *files*, so three files chosen from
/// one torrent were three unrelated rows. Then one list behind a four-case
/// lifecycle filter. Then two modes — In progress and Library — which split the
/// screen down the middle of a distinction nobody arrives with: you do not open
/// a download manager wondering which lifecycle stage a thing is at, you open it
/// wondering what you got and whether it worked.
///
/// So: everything in one list, ordered by when it was added, most recent first,
/// with no group headings anywhere. Preparing, downloading, queued, paused,
/// failed, cancelled, missing and completed all sit in it together and are told
/// apart by the glyph at the head of the row. The three pills narrow that list
/// and none of them re-sorts it.
struct DownloadsView: View {
    @Environment(AppModel.self) private var model
    @State private var expanded: Set<String> = []
    @State private var confirmingClear = false
    /// The selected row. A `DownloadGroupKey.rawValue` — content plus attempt —
    /// so a second go at the same torrent is a different row and cannot inherit
    /// the first one's selection.
    @State private var selectedGroup: String?

    /// The one animation on this screen, shared by the pills, the category bar
    /// and the rows, so a pill's fill never moves ahead of the list it governs.
    private static let narrowing = Animation.snappy(duration: 0.28)

    var body: some View {
        @Bindable var model = model
        Group {
            // **No debrid does not empty this screen.** It used to: the whole
            // view was replaced by "add an API key", which hid every download
            // the user already had. Two things are wrong with that. Finished
            // downloads are on disk and stay listed whatever happens to a key
            // afterwards — the library is a record, not a live connection. And
            // the Internet Archive and Project Gutenberg download over plain
            // HTTPS through `directEngine()`, which is built lazily and never
            // torn down by `configureProviders()`; so with no debrid at all a
            // transfer can be *running* while the screen claimed there was
            // nothing to download with.
            //
            // What genuinely needs a debrid still says so where it is: Add Link
            // is disabled, and a dropped torrent is refused at the drop.
            VStack(spacing: 0) {
                filterBar
                    // Lifted into the strip's gap, then clear beneath. Negative
                    // padding rather than an offset: an offset would move the
                    // pills and leave their space behind, so the gap below
                    // would be the old one plus this one and the row would
                    // drift out of its own band. Shared with Settings — see
                    // `pillBarLift`.
                    .padding(.top, -WindowMetrics.pillBarLift)
                    .padding(.bottom, WindowMetrics.pillBarGap)
                if model.downloadFilter.showsCategories { categoryBar }
                ThemedDivider()
                list
                RailBar(
                    leading: model.downloadRailText,
                    trailing: model.configuredServicesText)
            }
        }
        // A file deleted in Finder while Fetch was open would otherwise keep
        // reading "Completed" until the next relaunch, which is where
        // `LaunchRecovery` asks the same question.
        .task { model.refreshMissingFiles() }
        // Same reason as Search: the column that used to stretch its content
        // is gone, so each screen has to ask for the width itself.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Downloads")
    }

    // MARK: - The bars

    /// All / Failed / Library, and the two buttons that act on what they show.
    ///
    /// Counts come from the unfiltered set (`AppModel.downloadCount`), so
    /// choosing one pill never makes the others look empty.
    private var filterBar: some View {
        FilterPillBar(
            items: DownloadFilter.allCases,
            title: \.title,
            count: { model.downloadCount(for: $0) },
            isSelected: { $0 == model.downloadFilter },
            select: { filter in
                withAnimation(Self.narrowing) {
                    model.downloadFilter = filter
                    // Leaving the Library with a kind still chosen would mean
                    // coming back to a shelf that is narrowed for a reason
                    // nothing on screen explains.
                    if !filter.showsCategories { model.libraryKind = nil }
                }
            },
            height: WindowMetrics.barHeight,
            // The same height as Search's field across the divider: this row is
            // what Downloads has in that slot, and two screens whose primary
            // control is a different size read as two different apps when you
            // switch between them.
            pillHeight: RowHeight.searchField
        ) {
            clearButton
        }

    }

    /// **Only under Failed, and it only says Clear.** It acts on exactly what
    /// that filter is showing, which is the whole argument for it living beside
    /// the filter rather than in the bar of every screen.
    @ViewBuilder
    private var clearButton: some View {
        if model.downloadFilter == .downloads, model.clearableCount > 0 {
            Button("Clear") { confirmingClear = true }
                .help("Remove these rows. Files stay on disk.")
                .confirmationDialog(
                    "Clear \(model.clearableCount) row"
                    + "\(model.clearableCount == 1 ? "" : "s")?",
                    isPresented: $confirmingClear, titleVisibility: .visible
                ) {
                    Button("Clear", role: .destructive) { model.clearFailed() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    // Said explicitly, because "clear" next to a list of
                    // downloads reads as "delete what I downloaded" to anyone
                    // who has not read the code.
                    Text("Removes the rows. Files stay on disk.")
                }
        }
    }


    /// The Library's kinds, on the second bar.
    ///
    /// **It exists only while Library is chosen.** It is not a permanent line
    /// of chrome on a screen whose other two filters have nothing to narrow by.
    /// Pills are built from the kinds actually present, and their counts come
    /// from the whole library — choosing Books must not erase the pill that
    /// chooses Movies.
    private var categoryBar: some View {
        let kinds = model.libraryKinds
        // `nil` is the All pill, so one bar drives one optional rather than a
        // separate control for "no kind".
        let items: [MediaKind?] = [nil] + kinds.map { Optional($0.kind) }

        return FilterPillBar(
            items: items,
            title: { $0.map { DownloadLibrary.title(for: $0) } ?? "All" },
            count: { kind in
                guard let kind else { return kinds.reduce(0) { $0 + $1.count } }
                return kinds.first { $0.kind == kind }?.count
            },
            isSelected: { $0 == model.libraryKind },
            select: { kind in
                withAnimation(Self.narrowing) {
                    // Tapping the active pill clears it, so the bar never
                    // becomes a mode you cannot leave.
                    model.libraryKind = (model.libraryKind == kind) ? nil : kind
                }
            },
            height: WindowMetrics.subBarHeight)
            .background(Palette.rowAlternate)
            // **Fades in place; it does not fly in from above.**
            // `.move(edge: .top)` animates the bar in from off the top of its
            // own slot, which means it is drawn *over* the filter pills for the
            // length of the animation — a second row of pills sliding across
            // the first, which reads as a mistake rather than as a reveal. The
            // stack still animates its height, so the rows below move down to
            // let it in; the bar itself only appears.
            .transition(.opacity)
    }

    // MARK: - The list

    @ViewBuilder
    private var list: some View {
        let rows = model.visibleDownloadRows
        // A preparation is neither failed nor finished, so it belongs under
        // All and nowhere else. Showing it under Library would put a torrent
        // that has not arrived on the shelf of things that have.
        let preparing = model.downloadFilter == .downloads ? model.preparations : []
        if rows.isEmpty && preparing.isEmpty {
            emptyState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                ColumnHeaderRow {
                    HStack(spacing: RowHeight.columnGap) {
                        // The glyph column has no heading. "State" over a
                        // column of symbols is a label for something the
                        // symbols already say.
                        Color.clear.frame(width: ColumnWidth.status, height: 1)
                        Text("Name").frame(maxWidth: .infinity, alignment: .leading)
                        Text("Size")
                            .frame(width: ColumnWidth.downloadSize, alignment: .trailing)
                        Text("Rate").frame(width: ColumnWidth.rate, alignment: .trailing)
                        Text("Added").frame(width: ColumnWidth.added, alignment: .trailing)
                    }
                }
                ThemedDivider()

                List(selection: $selectedGroup) {
                    // Above the transfers, because that is the order things
                    // happen in: the debrid fetches the torrent, then this
                    // machine fetches the files. They are also, by definition,
                    // the newest things on the screen.
                    ForEach(preparing) { preparation in
                        PreparingRow(preparation: preparation)
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.visible)
                    }
                    ForEach(rows) { group in
                        TorrentRow(
                            group: group,
                            isExpanded: expanded.contains(group.id),
                            isSelected: selectedGroup == group.id,
                            onToggleExpanded: { toggle(group.id) })
                            .tag(group.id)
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.visible)
                            // **One click opens it.** The chevron was the only
                            // way in, which is a 14-point target on a 56-point
                            // row, and double-click was spent on Finder — the
                            // rarer of the two by far. Reveal moves to the
                            // context menu, where the file rows already keep
                            // theirs, and the whole row becomes the control.
                            .contentShape(Rectangle())
                            .onTapGesture { toggle(group.id) }
                            .contextMenu {
                                Button("Show in Finder") { model.revealInFinder(group) }
                            }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                // Driven by what is being shown, so SwiftUI diffs the narrowed
                // list against the wide one rather than replacing it wholesale:
                // rows that survive stay put, and only the ones leaving animate
                // away.
                .animation(Self.narrowing, value: model.downloadFilter)
                .animation(Self.narrowing, value: model.libraryKind)
            }
        }
    }

    /// **The filters stay.** They are the screen's only structure, and removing
    /// them on an empty list means the screen changes shape the moment the
    /// first download lands.
    @ViewBuilder
    private var emptyState: some View {
        switch model.downloadFilter {
        case .downloads:
            // The offer changes with what is actually configured: the two
            // keyless sources work with or without a debrid and a torrent
            // needs one, so a single line would be half true either way.
            if model.isConfigured {
                EmptyStateView(
                    symbol: "arrow.down.circle",
                    title: "No downloads queued",
                    message: "Pick something from Search, or drop a torrent on "
                        + "the window.")
            } else {
                EmptyStateView(
                    symbol: "arrow.down.circle",
                    title: "No downloads queued",
                    message: "Search the Internet Archive and Project Gutenberg, "
                        + "which need no service. Add a debrid service for "
                        + "torrents and file hosts.",
                    actionTitle: "Open Settings",
                    action: { model.navigate(to: .debrid) })
            }
        case .library:
            EmptyStateView(
                symbol: "books.vertical",
                title: model.libraryKind == nil
                    ? "Nothing here yet"
                    : "Nothing here of that kind",
                message: "Finished downloads collect here, newest first.")
        }
    }

    private func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }
}

/// A torrent the debrid is still fetching into its own cloud.
///
/// It shares the list's grid so it reads as one of the rows, and it is
/// deliberately **not** a `DownloadRowView`: nothing here is a local transfer.
/// The percentage is the *service's* progress pulling from the swarm, no bytes
/// have reached this machine, there is nothing to pause, and there is no date,
/// because a preparation is a live poll rather than something that was added.
///
/// This exists because the wait it represents used to happen inside a modal
/// sheet — submit an uncached magnet, then watch a spinner for as long as the
/// debrid took, with nothing in Downloads and no way to leave.
private struct PreparingRow: View {
    @Environment(AppModel.self) private var model
    let preparation: AppModel.Preparation

    var body: some View {
        HStack(spacing: RowHeight.columnGap) {
            StateGlyph(state: .preparing)

            VStack(alignment: .leading, spacing: RowHeight.subLineGap) {
                Text(preparation.name)
                    .font(FetchFont.body)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(DownloadSubline.text(DownloadRowFacts(
                    state: .preparing, preparingStatus: statusText)) ?? "")
                    .font(FetchFont.subheadline)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                // Indeterminate until the service has said anything, because
                // 0% claims a measurement nobody has taken yet.
                if let fraction = preparation.progress?.fraction {
                    ProgressTrack(fraction: fraction)
                        .padding(.top, RowHeight.trackTopGap - RowHeight.subLineGap)
                } else {
                    ProgressTrack(fraction: nil)
                        .padding(.top, RowHeight.trackTopGap - RowHeight.subLineGap)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(Self.noValue)
                .frame(width: ColumnWidth.downloadSize, alignment: .trailing)
            Text(rateText)
                .frame(width: ColumnWidth.rate, alignment: .trailing)
            Button {
                model.cancelPreparation(preparation.id)
            } label: {
                Image(systemName: "xmark").font(.system(size: IconSize.sm))
            }
            .buttonStyle(.borderless)
            .help("Stop watching. The torrent stays on your debrid account.")
            .frame(width: ColumnWidth.added, alignment: .trailing)
        }
        .font(FetchFont.calloutMono)
        .foregroundStyle(Palette.textTertiary)
        .padding(.vertical, RowHeight.rowPaddingV)
        .padding(.horizontal, WindowMetrics.contentInset)
        .help(preparation.name)
    }

    private static let noValue = "—"

    /// The service's own words, with its name and its percentage, which is the
    /// one line this row gets. "Stalled, waiting for seeds" is the difference
    /// between a torrent that is working and one that never will.
    private var statusText: String {
        guard let progress = preparation.progress else {
            return preparation.providerName.isEmpty
                ? "Submitting."
                : "\(preparation.providerName) is fetching it."
        }
        let percent = Int((progress.fraction * 100).rounded())
        return "\(progress.statusText). \(percent)%"
    }

    private var rateText: String {
        guard let rate = preparation.progress?.bytesPerSecond, rate > 0
        else { return Self.noValue }
        return ByteCount.rate(rate)
    }
}

/// One torrent: the row, and its files underneath when it is open.
private struct TorrentRow: View {
    @Environment(AppModel.self) private var model
    let group: AppModel.TorrentGroup
    let isExpanded: Bool
    let isSelected: Bool
    let onToggleExpanded: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DownloadRowView(
                group: group, isExpanded: isExpanded, isSelected: isSelected,
                onToggleExpanded: onToggleExpanded)

            if isExpanded {
                // **The tint is the block; the rule is gone.** A rule down the
                // left edge says "these belong to a level above" — which is
                // worth saying inside a folder, where a file three levels deep
                // needs an edge to trace back. At the root there is only one
                // level to belong to, the indent and the tinted ground already
                // say so, and a vertical line beside every expanded download
                // reads as a second kind of structure that does not exist.
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { ThemedDivider().opacity(0.4) }
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
                            if !group.items.isEmpty { ThemedDivider().opacity(0.4) }
                            ForEach(skipped, id: \.path) { file in
                                SkippedFileRow(file: file, group: group, checked: $checked)
                            }
                        }
                        if !checked.isEmpty {
                            ThemedDivider().opacity(0.4)
                            selectionBar
                        }
                    }
                }
                .padding(.leading, WindowMetrics.contentInset + ColumnWidth.status)
                .padding(.trailing, WindowMetrics.contentInset)
                .padding(.bottom, Spacing.s8)
                .background(
                    RoundedRectangle(cornerRadius: Radius.r6)
                        .fill(Palette.rowAlternate.opacity(0.6)))
            }
        }
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
                    // **The target, not the glyph.** A 14-point square is
                    // under half the 44 points a pointing device wants, and
                    // this one sits in a dense list where the row above and
                    // below are both a miss. The tick stays its own size; what
                    // grows is the area that answers the click.
                    .frame(width: IconSize.xl, height: IconSize.xl)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(checked.contains(path) ? "selected" : "not selected")
        } else {
            // A file with no known path cannot be re-resolved against the
            // torrent, so it cannot be re-queued — the space is held rather
            // than closed up, so the names below it stay in one column.
            Color.clear.frame(width: IconSize.xl, height: 1)
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

            // The glyph, without the word beside it, for the same reason the
            // row above lost it: eight strings repeated down a column are the
            // column, and the tooltip is where a word is actually read.
            StateGlyph(state: item.state)

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
        .padding(.vertical, RowHeight.fileRowPaddingV)
        // **The row is the checkbox.** A 20-point target in a list of files is
        // still a small thing to hit, and every one of these rows exists to be
        // ticked — so clicking anywhere on one does what clicking its box does.
        // Only where there is a path to tick: a file Fetch can no longer
        // resolve against the torrent cannot be re-queued, and a row that
        // silently ignores a click is worse than one that never invited it.
        .contentShape(Rectangle())
        .onTapGesture {
            guard let path, item.state.isSelectableForAction else { return }
            if checked.contains(path) { checked.remove(path) } else { checked.insert(path) }
        }
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

            // Holds the glyph column's width without drawing one: this file has
            // no state, because it never became a download.
            Color.clear.frame(width: ColumnWidth.status, height: 1)

            Text((file.path as NSString).lastPathComponent)
                .font(FetchFont.footnote)
                .foregroundStyle(Palette.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(file.path)

            Spacer()

            Text("Not selected")
                .font(FetchFont.footnote)
                .foregroundStyle(Palette.textTertiary)

            Text(ByteCount.format(file.length))
                .font(FetchFont.calloutMono)
                // Tertiary, not quaternary: quaternary is 10% opacity —
                // roughly 1.2:1 — which is for separators and disabled fills,
                // not a number the user is meant to read (§4.3 wants 4.5:1).
                .foregroundStyle(Palette.textTertiary)
                .frame(width: ColumnWidth.fileSize, alignment: .trailing)
        }
        .padding(.vertical, RowHeight.fileRowPaddingV)
        // Tickable by the row, like the queued ones above. These are the files
        // someone most often wants back, so they are the last place to make
        // the target the glyph rather than the row.
        .contentShape(Rectangle())
        .onTapGesture {
            if checked.contains(file.path) {
                checked.remove(file.path)
            } else {
                checked.insert(file.path)
            }
        }
    }
}
