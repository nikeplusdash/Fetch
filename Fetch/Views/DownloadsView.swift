import SwiftUI
import FetchKit

/**
 The Downloads screen: **one list, newest first**.

 It has been three shapes. A flat list of *files*, so three files chosen from
 one torrent were three unrelated rows. Then one list behind a four-case
 lifecycle filter. Then two modes — In progress and Library — which split the
 screen down the middle of a distinction nobody arrives with: you do not open
 a download manager wondering which lifecycle stage a thing is at, you open it
 wondering what you got and whether it worked.

 So: everything in one list, ordered by when it was added, most recent first,
 with no group headings anywhere. Preparing, downloading, queued, paused,
 failed, cancelled, missing and completed all sit in it together and are told
 apart by the glyph at the head of the row. The three pills narrow that list
 and none of them re-sorts it.
 */
struct DownloadsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmingClear = false
    @State private var confirmingCancelAll = false

    private static let narrowing = Animation.snappy(duration: 0.28)

    var body: some View {
        @Bindable var model = model
        Group {
            VStack(spacing: 0) {
                filterBar
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
        .task { model.refreshMissingFiles() }
        .task(id: model.downloadFilter) {
            guard model.downloadFilter == .cloud, model.cloudLoadState == .idle else { return }
            await model.refreshCloud()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Downloads")
    }


    private var filterBar: some View {
        FilterPillBar(
            items: DownloadFilter.allCases,
            title: \.title,
            count: { model.pillCount(for: $0) },
            isSelected: { $0 == model.downloadFilter },
            select: { filter in
                withAnimation(Self.narrowing) {
                    model.downloadFilter = filter
                    if !filter.showsCategories { model.libraryKind = nil }
                }
            },
            height: WindowMetrics.barHeight,
            pillHeight: RowHeight.searchField
        ) {
            HStack(spacing: Spacing.s8) {
                refreshCloudButton
                cancelAllButton
                clearButton
            }
        }

    }

    /**
     **Two buttons, because emptying the list is two decisions.**

     `Clear` alone could never empty a queued list: it takes the three dead
     ends (`DownloadFilter.isClearable`) and a queued row is not one of
     them, so the only way to be rid of one was to hover it and hit its own
     xmark, row by row. Cancel-then-clear is the pair that finishes the job
     — the first stops what is moving and leaves it cancelled, which is
     exactly the state the second takes.

     Each appears only when it has rows to act on, and the two sets are
     disjoint by construction, so an idle list shows neither and a list
     mid-transfer shows only Cancel.
     */
    @ViewBuilder
    private var cancelAllButton: some View {
        if model.downloadFilter == .downloads, model.cancellableCount > 0 {
            toolbarButton("xmark.circle", "Cancel \(model.cancellableCount) in progress") {
                confirmingCancelAll = true
            }
            .confirmationDialog(
                "Cancel \(model.cancellableCount) download"
                + "\(model.cancellableCount == 1 ? "" : "s")?",
                isPresented: $confirmingCancelAll, titleVisibility: .visible
            ) {
                Button("Cancel Downloads", role: .destructive) { model.cancelAllInFlight() }
                Button("Keep Downloading", role: .cancel) {}
            } message: {
                Text("Stops the transfers and drops them at the service they came "
                     + "from, so they cannot be resumed — only fetched again. "
                     + "The rows stay until you clear them.")
            }
        }
    }

    @ViewBuilder
    private var refreshCloudButton: some View {
        if model.downloadFilter == .cloud, model.cloudLoadState != .loading {
            toolbarButton("arrow.clockwise", "Ask your services again") {
                Task { await model.refreshCloud() }
            }
        }
    }

    @ViewBuilder
    private var clearButton: some View {
        if model.downloadFilter == .downloads, model.clearableCount > 0 {
            toolbarButton("trash", "Clear \(model.clearableCount) stopped row"
                          + "\(model.clearableCount == 1 ? "" : "s"). Files stay on disk.") {
                confirmingClear = true
            }
            .confirmationDialog(
                "Clear \(model.clearableCount) row"
                + "\(model.clearableCount == 1 ? "" : "s")?",
                isPresented: $confirmingClear, titleVisibility: .visible
            ) {
                Button("Clear", role: .destructive) { model.clearFailed() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Removes the rows. Files stay on disk.")
            }
        }
    }

    private func toolbarButton(
        _ symbol: String, _ label: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: IconSize.md))
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
    }


    private var categoryBar: some View {
        let kinds = model.downloadFilter == .cloud ? model.cloudKinds : model.libraryKinds
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
                    model.libraryKind = (model.libraryKind == kind) ? nil : kind
                }
            },
            height: WindowMetrics.subBarHeight)
            .background(Palette.rowAlternate)
            .transition(.opacity)
    }


    @ViewBuilder
    private var list: some View {
        if model.downloadFilter == .cloud {
            cloudList
        } else {
            let rows = model.visibleDownloadRows
            let preparing = model.downloadFilter == .downloads ? model.preparations : []
            if rows.isEmpty && preparing.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                table(rows: rows, preparing: preparing)
            }
        }
    }

    @ViewBuilder
    private var cloudList: some View {
        let rows = model.visibleCloudRows
        if rows.isEmpty {
            emptyState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            cloudTable(rows: rows)
        }
    }

    /**
     Cloud rows carry no transfer rate, so they take the same column set
     without one rather than a grid of their own.
     */
    private var cloudColumns: ColumnSet<DownloadColumn> {
        TableColumns.downloads(showsRate: false)
    }

    @ViewBuilder
    private func cloudTable(rows: [CloudRow]) -> some View {
        @Bindable var model = model
        TableContainer(
            ids: rows.map(\.id),
            policy: .downloads,
            selection: $model.downloadSelection,
            onSideArrow: { effect in
                guard let id = model.downloadSelection.selected else { return }
                switch effect {
                case .collapse: model.expandedDownloads.remove(id)
                case .expand: model.expandedDownloads.insert(id)
                default: break
                }
            },
            onActivate: { id in
                guard let row = rows.first(where: { $0.id == id }) else { return }
                play(row)
            }
        ) { width in
            TableHeader(set: cloudColumns, width: width)
        } rows: { width in
            ForEach(rows) { row in
                CloudTorrentRow(
                    row: row,
                    width: width,
                    columns: cloudColumns,
                    isExpanded: model.expandedDownloads.contains(row.id),
                    onToggleExpanded: { toggle(row.id) },
                    onSelect: { model.downloadSelection.click(row.id) },
                    onActivate: { play(row) })
                    .id(row.id)
                ThemedDivider()
            }
        }
        .animation(Self.narrowing, value: model.downloadFilter)
        .animation(Self.narrowing, value: model.libraryKind)
    }

    /**
     Opening a cloud row streams it, which is the default this screen was
     added for. Hydration first, because a Real-Debrid row knows none of
     its files until something asks.
     */
    private func play(_ row: CloudRow) {
        Task {
            await model.hydrateRow(row)
            guard let member = model.cloudRows.first(where: { $0.key == row.key })?
                .members.first else { return }
            if let offer = model.playlistOffer(forCloud: member),
               let player = offer.defaultPlayer {
                await model.playCloud(offer.items, in: player)
            } else if let file = member.files.first,
                      let player = model.defaultExternalPlayer {
                await model.playCloudFile(file, of: member, in: player)
            }
        }
    }

    private var columns: ColumnSet<DownloadColumn> { TableColumns.downloads }

    @ViewBuilder
    private func table(
        rows: [AppModel.TorrentGroup], preparing: [AppModel.Preparation]
    ) -> some View {
        @Bindable var model = model
        TableContainer(
            ids: rows.map(\.id),
            policy: .downloads,
            selection: $model.downloadSelection,
            onSideArrow: { effect in
                guard let id = model.downloadSelection.selected else { return }
                switch effect {
                case .collapse: model.expandedDownloads.remove(id)
                case .expand: model.expandedDownloads.insert(id)
                default: break
                }
            },
            onActivate: { id in
                guard let group = rows.first(where: { $0.id == id }) else { return }
                activate(group)
            }
        ) { width in
            TableHeader(set: columns, width: width)
        } rows: { width in
            ForEach(preparing) { preparation in
                PreparingRow(preparation: preparation, width: width, columns: columns)
                ThemedDivider()
            }
            ForEach(rows) { group in
                TorrentRow(
                    group: group,
                    width: width,
                    columns: columns,
                    isExpanded: model.expandedDownloads.contains(group.id),
                    onToggleExpanded: { toggle(group.id) },
                    onSelect: { apply(.singleClick(group.id)) },
                    onActivate: { activate(group) })
                    .id(group.id)
                ThemedDivider()
            }
        }
        .animation(Self.narrowing, value: model.downloadFilter)
        .animation(Self.narrowing, value: model.libraryKind)
    }

    /**
     Double-click on a downloads row: a cloud row streams from the service to
     the default player when there is one and something playable to send it,
     and otherwise opens the service's web page; every other row opens what
     it downloaded.
     */
    private func activate(_ group: AppModel.TorrentGroup) {
        if group.rowState.isCloudOnly {
            if let player = model.defaultExternalPlayer, model.cloudGroupIsPlayable(group) {
                Task { await model.streamCloudGroup(group, in: player) }
            } else if let id = group.items.first?.id,
                      let url = model.serviceHomePage(for: id) {
                NSWorkspace.shared.open(url)
            }
        } else {
            model.openOnDisk(group)
        }
    }

    /**
     A click on a downloads row both selects it and opens it — the policy
     says so, and this is the one place that carries the answer out.
     */
    private func apply(_ gesture: RowGesture<String>) {
        for effect in RowInteraction.effects(for: gesture, policy: .downloads) {
            switch effect {
            case .select(let id): model.downloadSelection.click(id)
            case .toggleExpansion(let id): toggle(id)
            case .activate, .collapse, .expand: break
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        switch model.downloadFilter {
        case .downloads:
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
        case .cloud:
            cloudEmptyState
        }
    }

    @ViewBuilder
    private var cloudEmptyState: some View {
        switch model.cloudLoadState {
        case .loading:
            EmptyStateView(progress: true, message: "Asking your services what they hold…")
        case .failed(let reason):
            EmptyStateView(
                symbol: "exclamationmark.icloud",
                title: "Could not reach your services",
                message: reason,
                actionTitle: "Try Again",
                action: { Task { await model.refreshCloud() } })
        case .idle where !model.isConfigured:
            EmptyStateView(
                symbol: "icloud",
                title: "No services configured",
                message: "Add a debrid service and whatever it already holds "
                    + "will be listed here.",
                actionTitle: "Open Settings",
                action: { model.navigate(to: .debrid) })
        case .idle, .loaded:
            EmptyStateView(
                symbol: "icloud",
                title: model.libraryKind == nil
                    ? "Nothing in your services"
                    : "Nothing here of that kind",
                message: "Anything your debrid services already hold shows up "
                    + "here, ready to stream or download.")
        }
    }

    private func toggle(_ id: String) {
        if model.expandedDownloads.contains(id) {
            model.expandedDownloads.remove(id)
        } else {
            model.expandedDownloads.insert(id)
        }
    }
}

private struct PreparingRow: View {
    @Environment(AppModel.self) private var model
    let preparation: AppModel.Preparation
    let width: CGFloat
    let columns: ColumnSet<DownloadColumn>

    var body: some View {
        ColumnRow(set: columns, width: width,
                  layout: .stacked(firstLineHeight: RowMetrics.firstLine)) { spec in
            switch spec.id {
            case .status:
                StateGlyph(state: .preparing)
            case .name:
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
                if let fraction = preparation.progress?.fraction {
                    ProgressTrack(fraction: fraction)
                        .padding(.top, RowHeight.trackTopGap - RowHeight.subLineGap)
                } else {
                    ProgressTrack(fraction: nil)
                        .padding(.top, RowHeight.trackTopGap - RowHeight.subLineGap)
                }
                }
            case .size:
                Text(Self.noValue)
            case .rate:
                Text(rateText)
            case .added:
                Button {
                    model.cancelPreparation(preparation.id)
                } label: {
                    Image(systemName: "xmark").font(.system(size: IconSize.sm))
                }
                .buttonStyle(.borderless)
                .help("Stop watching. The torrent stays on your debrid account.")
            }
        }
        .font(FetchFont.calloutMono)
        .foregroundStyle(Palette.textTertiary)
        .padding(.vertical, RowHeight.rowPaddingV)
        .help(preparation.name)
    }

    private static let noValue = "—"

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

private struct TorrentRow: View {
    @Environment(AppModel.self) private var model
    let group: AppModel.TorrentGroup
    let width: CGFloat
    let columns: ColumnSet<DownloadColumn>
    let isExpanded: Bool
    let onToggleExpanded: () -> Void
    let onSelect: () -> Void
    let onActivate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DownloadRowView(
                group: group, isExpanded: isExpanded,
                width: width, columns: columns,
                onToggleExpanded: onToggleExpanded)
                .selectableRow(
                    isSelected: model.downloadSelection.isSelected(group.id),
                    onSelect: onSelect,
                    onActivate: onActivate)
                .contextMenu {
                    if group.rowState.isCloudOnly {
                        cloudMenu
                    } else {
                        if let offer = model.playlistOffer(for: group),
                           let player = offer.defaultPlayer {
                            Button(offer.title) {
                                model.playPlaylist(offer.items, in: player)
                            }
                        }
                        Button("Show in Finder") { model.revealInFinder(group) }
                    }
                }

            if isExpanded {
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        selectionHeader
                        ThemedDivider().opacity(0.4)
                        ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { ThemedDivider().opacity(0.4) }
                            FileRow(
                                item: item, group: group,
                                path: model.relativePath(of: item.id),
                                width: width, order: selectableOrder, checked: $checked)
                        }
                        let skipped = model.skippedFiles(for: group)
                        if !skipped.isEmpty {
                            if !group.items.isEmpty { ThemedDivider().opacity(0.4) }
                            ForEach(skipped, id: \.path) { file in
                                SkippedFileRow(
                                    file: file, group: group,
                                    width: width, order: selectableOrder, checked: $checked)
                            }
                        }
                        if !checked.chosen.isEmpty {
                            ThemedDivider().opacity(0.4)
                            selectionBar
                        }
                    }
                }
                .padding(.leading, WindowMetrics.contentInset + (columns.width(of: .status) ?? 0))
                .padding(.trailing, WindowMetrics.contentInset)
                .padding(.bottom, Spacing.s8)
                .background(
                    RoundedRectangle(cornerRadius: Radius.r6)
                        .fill(Palette.rowAlternate.opacity(0.6)))
            }
        }
        .onChange(of: isExpanded) { _, expanded in
            if !expanded { checked.clear() }
        }
        .background(selectAllShortcut)
        .confirmationDialog(
            "Delete this from your debrid account?",
            isPresented: $confirmingCancelCloud, titleVisibility: .visible
        ) {
            Button("Delete from Service", role: .destructive) {
                Task { for item in group.items { await model.cancelCloudQueued(item.id) } }
            }
            Button("Keep Fetching", role: .cancel) {}
        } message: {
            Text("This deletes the copy on your debrid account. Nothing has been "
                 + "downloaded to this Mac.")
        }
    }

    @State private var checked = MultiSelection<String>()
    @State private var confirmingCancelCloud = false

    /**
     Open on <service> / Download / Cancel / Remove for a whole cloud group,
     built from `RowActions` so the same rule drives the row and its files.
     */
    @ViewBuilder
    private var cloudMenu: some View {
        let actions = RowActions.available(
            for: group.rowState, hasLocalFile: false, isPlayable: false)
        if model.cloudGroupIsPlayable(group) {
            if let player = model.defaultExternalPlayer {
                Button("Play in \(player.displayName)") {
                    Task { await model.streamCloudGroup(group, in: player) }
                }
            }
            if model.installedPlayers.count > 1 {
                Menu("Play in…") {
                    ForEach(model.installedPlayers, id: \.self) { player in
                        Button(player.displayName) {
                            Task { await model.streamCloudGroup(group, in: player) }
                        }
                    }
                }
            }
            Divider()
        }
        if actions.contains(.openOnService), let id = group.items.first?.id {
            Button("Open on \(model.serviceName(for: id))") {
                if let url = model.serviceHomePage(for: id) { NSWorkspace.shared.open(url) }
            }
        }
        if actions.contains(.download) {
            Button("Download") {
                Task { for item in group.items { await model.downloadFromCloud(item.id) } }
            }
        }
        if actions.contains(.cancel) {
            Button("Delete from Service", role: .destructive) { confirmingCancelCloud = true }
        }
        if actions.contains(.remove) {
            Button("Remove") { for item in group.items { model.remove(item.id) } }
        }
    }

    /**
     Every file in this torrent that an action can be taken on, in the order
     they are drawn. Shift-click measures its range against this, so it has to
     be the order on screen rather than the order they arrived in.
     */
    private var selectableOrder: [String] {
        let live = group.items.compactMap { item in
            item.state.isSelectableForAction ? model.relativePath(of: item.id) : nil
        }
        return live + model.skippedFiles(for: group).map(\.path)
    }

    private var selectionHeader: some View {
        HStack(spacing: Spacing.s8) {
            Checkbox(state: checked.state(in: selectableOrder), size: IconSize.md) {
                if checked.state(in: selectableOrder) == .on {
                    checked.clear()
                } else {
                    checked.selectAll(selectableOrder)
                }
            }
            Text(headerText)
                .font(FetchFont.footnote)
                .foregroundStyle(Palette.textSecondary)
            Spacer()
        }
        .padding(.vertical, Spacing.s6)
        .padding(.trailing, Spacing.s8)
        .contextMenu { selectionMenu }
    }

    private var headerText: String {
        let total = selectableOrder.count
        let count = checked.chosen(in: selectableOrder).count
        let files = total == 1 ? "1 file" : "\(total) files"
        return count == 0 ? files : "\(files) · \(count) selected"
    }

    @ViewBuilder
    private var selectionMenu: some View {
        Button("Select All") { checked.selectAll(selectableOrder) }
            .disabled(checked.state(in: selectableOrder) == .on)
        Button("Select None") { checked.clear() }
            .disabled(checked.chosen(in: selectableOrder).isEmpty)
        Button("Invert Selection") { checked.invert(in: selectableOrder) }
    }

    /**
     Command-A over the torrent the list has selected.

     A hidden shortcut button rather than a second focusable region: the
     expanded card taking focus would take it from the table, and the table's
     focus is what tells a selected row to paint as the live one. Scoping the
     shortcut to the selected torrent is also what keeps two open torrents
     from both answering the same key.
     */
    @ViewBuilder
    private var selectAllShortcut: some View {
        if isExpanded, model.downloadSelection.isSelected(group.id) {
            Button("") { checked.selectAll(selectableOrder) }
                .keyboardShortcut("a", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    private var selectionBar: some View {
        HStack(spacing: Spacing.s8) {
            Text("\(checked.chosen(in: selectableOrder).count) selected")
                .font(FetchFont.footnote)
                .foregroundStyle(Palette.textSecondary)
            Spacer()
            Button("Clear") { checked.clear() }
                .buttonStyle(.link)
                .font(FetchFont.footnote)
            Button("Download \(checked.chosen(in: selectableOrder).count)") {
                let paths = checked.chosen(in: selectableOrder)
                checked.clear()
                Task { await model.startOrRedownload(paths: paths, from: group) }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.vertical, Spacing.s6)
        .padding(.trailing, Spacing.s8)
    }
}

private struct FileCheckbox: View {
    let path: String?
    @Binding var checked: MultiSelection<String>

    var body: some View {
        if let path {
            Checkbox(state: checked.isSelected(path) ? .on : .off) {
                checked.toggle(path)
            }
        } else {
            Color.clear
        }
    }
}

/**
 The three ways a click means something different in a list you can choose
 from: plain takes this row alone, command adds or removes it, shift takes
 everything back to the last row you touched. The arithmetic is
 `MultiSelection`'s; this only says which question the modifiers asked.
 */
private struct FileRowSelectionGestures: ViewModifier {
    let path: String?
    let order: [String]
    @Binding var checked: MultiSelection<String>

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().modifiers(.shift).onEnded {
                guard let path else { return }
                checked.extend(to: path, in: order)
            })
            .simultaneousGesture(TapGesture().modifiers(.command).onEnded {
                guard let path else { return }
                checked.toggle(path)
            })
            .onTapGesture {
                guard let path else { return }
                checked.replace(with: path)
            }
    }
}

extension View {
    func fileRowSelection(
        path: String?, order: [String], checked: Binding<MultiSelection<String>>
    ) -> some View {
        modifier(FileRowSelectionGestures(path: path, order: order, checked: checked))
    }
}

private struct FileRow: View {
    @Environment(AppModel.self) private var model
    let item: DownloadItem
    let group: AppModel.TorrentGroup
    let path: String?
    let width: CGFloat
    let order: [String]
    @Binding var checked: MultiSelection<String>

    var body: some View {
        ColumnRow(set: TableColumns.files, width: width, inset: 0) { spec in
            switch spec.id {
            case .checkbox:
                FileCheckbox(
                    path: item.state.isSelectableForAction ? path : nil, checked: $checked)
            case .glyph:
                StateGlyph(state: item.state)
            case .name:
                Text(item.displayName)
                    .font(FetchFont.footnote)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(item.displayName)
            case .percent:
                if item.state == .downloading, let fraction = item.fraction {
                    Text("\(Int(fraction * 100))%")
                        .font(FetchFont.calloutMono)
                        .foregroundStyle(Palette.textSecondary)
                } else {
                    Color.clear
                }
            case .size:
                Text(ByteCount.format(item.totalBytes))
                    .font(FetchFont.calloutMono)
                    .foregroundStyle(Palette.textTertiary)
            case .control:
                control
            }
        }
        .fileRowSelection(
            path: item.state.isSelectableForAction ? path : nil,
            order: order, checked: $checked)
        .onTapGesture(count: 2) {
            if item.state.isCloudOnly, let player = model.defaultExternalPlayer,
               ExternalPlayer.canPlay(fileNamed: item.displayName) {
                Task { await model.streamCloudGroupFile(item, in: player) }
            }
        }
        .contextMenu {
            if item.state.isCloudOnly {
                cloudMenu
            } else {
                if let url = item.finalURL {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                if item.state.needsAttention, let path = model.relativePath(of: item.id) {
                    Button("Download Again") {
                        Task { await model.redownload(paths: [path], from: group) }
                    }
                }
                if model.canRevertRename(item.id) {
                    Button("Revert Rename") { model.revertRename(item.id) }
                }
            }
        }
        .confirmationDialog(
            "Delete this from your debrid account?",
            isPresented: $confirmingCancelCloud, titleVisibility: .visible
        ) {
            Button("Delete from Service", role: .destructive) {
                Task { await model.cancelCloudQueued(item.id) }
            }
            Button("Keep Fetching", role: .cancel) {}
        } message: {
            Text("This deletes the copy on your debrid account. Nothing has been "
                 + "downloaded to this Mac.")
        }
    }

    @State private var confirmingCancelCloud = false

    /**
     Open on <service> / Download / Cancel / Remove for one cloud file row,
     built from `RowActions.available`.
     */
    @ViewBuilder
    private var cloudMenu: some View {
        let actions = RowActions.available(
            for: item.state, hasLocalFile: item.finalURL != nil, isPlayable: false)
        if !model.installedPlayers.isEmpty, ExternalPlayer.canPlay(fileNamed: item.displayName) {
            if let player = model.defaultExternalPlayer {
                Button("Play in \(player.displayName)") {
                    Task { await model.streamCloudGroupFile(item, in: player) }
                }
            }
            if model.installedPlayers.count > 1 {
                Menu("Play in…") {
                    ForEach(model.installedPlayers, id: \.self) { player in
                        Button(player.displayName) {
                            Task { await model.streamCloudGroupFile(item, in: player) }
                        }
                    }
                }
            }
            Divider()
        }
        if actions.contains(.openOnService) {
            Button("Open on \(model.serviceName(for: item.id))") {
                if let u = model.serviceHomePage(for: item.id) { NSWorkspace.shared.open(u) }
            }
        }
        if actions.contains(.download) {
            Button("Download") { Task { await model.downloadFromCloud(item.id) } }
        }
        if actions.contains(.cancel) {
            Button("Delete from Service", role: .destructive) { confirmingCancelCloud = true }
        }
        if actions.contains(.remove) {
            Button("Remove") { model.remove(item.id) }
        }
    }

    @ViewBuilder
    private var control: some View {
        if item.state == .downloading {
            Button { model.pause(item.id) } label: { Image(systemName: "pause.fill") }
                .buttonStyle(.borderless)
        } else if item.state.canBeStarted {
            Button { model.resume(item.id) } label: { Image(systemName: "play.fill") }
                .buttonStyle(.borderless)
        } else {
            Color.clear
        }
    }
}

private struct SkippedFileRow: View {
    @Environment(AppModel.self) private var model
    let file: TorrentMetadata.File
    let group: AppModel.TorrentGroup
    let width: CGFloat
    let order: [String]
    @Binding var checked: MultiSelection<String>

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
        ColumnRow(set: TableColumns.files, width: width, inset: 0) { spec in
            switch spec.id {
            case .checkbox:
                FileCheckbox(path: file.path, checked: $checked)
            case .name:
                HStack(spacing: Spacing.s8) {
                    Text((file.path as NSString).lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(file.path)
                    Spacer(minLength: Spacing.s8)
                    Text("Not selected")
                }
                .font(FetchFont.footnote)
                .foregroundStyle(Palette.textTertiary)
            case .size:
                Text(ByteCount.format(file.length))
                    .font(FetchFont.calloutMono)
                    .foregroundStyle(Palette.textTertiary)
            case .glyph, .percent, .control:
                Color.clear
            }
        }
        .fileRowSelection(path: file.path, order: order, checked: $checked)
    }
}

/**
 One Cloud row and, when it is open, the files inside it.

 **Expansion is what triggers hydration.** A Real-Debrid row arrives
 knowing nothing but its own name, and opening it is the first moment
 anyone has asked what is in it — so the fetch hangs off `isExpanded`
 rather than off the listing, which would have been one request per row on
 every open of the screen.
 */
private struct CloudTorrentRow: View {
    @Environment(AppModel.self) private var model
    let row: CloudRow
    let width: CGFloat
    let columns: ColumnSet<DownloadColumn>
    let isExpanded: Bool
    let onToggleExpanded: () -> Void
    let onSelect: () -> Void
    let onActivate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CloudRowView(
                row: row, width: width, columns: columns,
                isExpanded: isExpanded, onToggle: onToggleExpanded)
            .selectableRow(
                isSelected: model.downloadSelection.isSelected(row.id),
                onSelect: onSelect,
                onActivate: onActivate)
            .contextMenu { menu }

            if isExpanded {
                expandedFiles
            }
        }
        .task(id: isExpanded) {
            guard isExpanded else { return }
            await model.hydrateRow(row)
        }
    }

    private var member: DebridCloudItem? { row.members.first }

    private var serviceName: String {
        guard let provider = row.providers.first else { return "the service" }
        return model.provider(provider)?.displayName ?? provider.rawValue
    }

    @State private var checked = MultiSelection<String>()

    @ViewBuilder
    private var menu: some View {
        if let member {
            if let offer = model.playlistOffer(forCloud: member),
               let player = offer.defaultPlayer {
                Button(offer.title) {
                    Task { await model.playCloud(offer.items, in: player) }
                }
            }
            Button(checked.chosen.isEmpty
                   ? "Download"
                   : "Download \(checked.chosen.count)") {
                Task { await model.downloadCloudFiles(checked.chosen, from: member) }
            }
        }
    }

    @ViewBuilder
    private var expandedFiles: some View {
        VStack(spacing: 0) {
            if let member, !member.files.isEmpty {
                ForEach(Array(member.files.enumerated()), id: \.element.id) { index, file in
                    if index > 0 { ThemedDivider().opacity(0.4) }
                    CloudFileRow(file: file, item: member, checked: $checked)
                }
                if !checked.chosen.isEmpty {
                    ThemedDivider().opacity(0.4)
                    HStack(spacing: Spacing.s12) {
                        Text("\(checked.chosen.count) selected")
                            .font(FetchFont.footnote)
                            .foregroundStyle(Palette.textSecondary)
                        Spacer()
                        Button("Clear") { checked.clear() }
                        Button("Download \(checked.chosen.count)") {
                            Task { await model.downloadCloudFiles(checked.chosen, from: member) }
                        }
                    }
                    .padding(.vertical, Spacing.s8)
                }
            } else {
                EmptyStateView(
                    progress: true,
                    message: "Asking \(serviceName) what is inside…",
                    size: .inline)
            }
        }
        .padding(.leading, WindowMetrics.contentInset + (columns.width(of: .status) ?? 0))
        .padding(.trailing, WindowMetrics.contentInset)
        .padding(.bottom, Spacing.s8)
        .background(
            RoundedRectangle(cornerRadius: Radius.r6)
                .fill(Palette.rowAlternate.opacity(0.6)))
        .onChange(of: isExpanded) { _, open in if !open { checked.clear() } }
    }
}

/**
 One file inside an open Cloud row: its name, its size, and — for a file a
 player can take — a Play that streams that file alone.
 */
private struct CloudFileRow: View {
    @Environment(AppModel.self) private var model
    let file: DebridFile
    let item: DebridCloudItem
    @Binding var checked: MultiSelection<String>

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: Spacing.s8) {
            FileCheckbox(path: file.name, checked: $checked)
            Text(file.shortName)
                .font(FetchFont.calloutMono)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .contentShape(Rectangle())
                .onTapGesture { checked.toggle(file.name) }
            Spacer(minLength: Spacing.s8)
            if isHovered, isPlayable, let player = model.defaultExternalPlayer {
                Button {
                    Task { await model.playCloudFile(file, of: item, in: player) }
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: IconSize.sm))
                }
                .buttonStyle(.borderless)
                .help("Stream in \(player.displayName)")
                .accessibilityLabel("Stream \(file.shortName) in \(player.displayName)")
            }
            Text(file.size > 0 ? ByteCount.format(file.size) : "—")
                .font(FetchFont.footnoteMono)
                .foregroundStyle(Palette.textTertiary)
        }
        .padding(.vertical, RowHeight.rowPaddingV)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2) { streamThisFile() }
        .contextMenu {
            if isPlayable, model.defaultExternalPlayer != nil {
                Button("Stream This File") { streamThisFile() }
            }
            Button("Download This File") {
                Task { await model.downloadCloudFiles([file.name], from: item) }
            }
        }
    }

    private func streamThisFile() {
        guard isPlayable, let player = model.defaultExternalPlayer else { return }
        Task { await model.playCloudFile(file, of: item, in: player) }
    }

    private var isPlayable: Bool {
        ExternalPlayer.canPlay(fileNamed: file.shortName)
    }
}
