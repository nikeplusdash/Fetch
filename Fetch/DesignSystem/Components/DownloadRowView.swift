import SwiftUI
import FetchKit

/// One row of the Downloads list: a glyph, a name with one line under it, and
/// three numbers.
///
/// **Five columns, and the widths are the point.** `ColumnWidth.status`,
/// `.downloadSize`, `.rate` and `.added` are fixed and must stay fixed: every
/// value in them changes length as a download runs — bytes gaining a digit, a
/// rate crossing a unit, an ETA going from "45s" to "about 3 minutes" — and an
/// unconstrained `Text` reflows the whole row each time, ten times a second.
/// A column that does not fit in a narrow window should be *dropped* at a
/// breakpoint, never made flexible.
///
/// **The word beside the glyph is gone.** `StateLabel` drew an icon and a word
/// together in a 92-point column, so nine downloads carried nine repetitions of
/// eight strings on a screen whose title column was the thing being squeezed.
/// Those points are the Added column now, and the word survives as the glyph's
/// tooltip and accessibility label, which is the only place it was ever
/// load-bearing.
struct DownloadRowView: View {
    @Environment(AppModel.self) private var model
    let group: AppModel.TorrentGroup
    let isExpanded: Bool
    /// Threaded down from the list's own selection, so a long torrent name
    /// reveals itself here the same way a search result's does. `List` paints
    /// selection by tag and tells the row nothing, so it has to be passed.
    var isSelected: Bool = false
    let onToggleExpanded: () -> Void

    /// Whether the pointer is on this row, which is the only thing that swaps
    /// the Added column for the controls. See `trailingCell`.
    @State private var isHovering = false

    private var rowHelp: String {
        guard let destination = model.destinationText(for: group), !destination.isEmpty
        else { return group.displayName }
        return "\(group.displayName)\n\(destination)"
    }

    var body: some View {
        HStack(spacing: RowHeight.columnGap) {
            StateGlyph(state: group.rowState)

            VStack(alignment: .leading, spacing: RowHeight.subLineGap) {
                HStack(spacing: Spacing.s4) {
                    disclosure
                    RevealingText(text: group.displayName, isRevealing: isSelected)
                }
                if let subline = DownloadSubline.text(model.facts(for: group)) {
                    Text(subline)
                        .font(FetchFont.subheadline)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        // Level with the name rather than with the chevron
                        // gutter, so the two lines of the row read as one
                        // block instead of a stack with a ragged left edge.
                        .padding(.leading, IconSize.sm + Spacing.s4)
                }
                // While and only while the row is moving, and only when the
                // fraction is actually known: an indeterminate bar under a
                // paused download animates as though something is happening.
                if group.isMoving, let fraction = group.fraction {
                    ProgressTrack(fraction: fraction)
                        .padding(.top, RowHeight.trackTopGap - RowHeight.subLineGap)
                        .padding(.leading, IconSize.sm + Spacing.s4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(ByteCount.format(group.totalBytes))
                .frame(width: ColumnWidth.downloadSize, alignment: .trailing)
            // Only while bytes are arriving. A rate on a finished row is a
            // number about a minute that has passed.
            Text(group.rowState == .downloading && group.bytesPerSecond > 0
                 ? ByteCount.rate(Int64(group.bytesPerSecond))
                 : Self.noValue)
                .frame(width: ColumnWidth.rate, alignment: .trailing)
            trailingCell
                .frame(width: ColumnWidth.added, alignment: .trailing)
        }
        .font(FetchFont.calloutMono)
        .foregroundStyle(Palette.textTertiary)
        .padding(.vertical, RowHeight.rowPaddingV)
        .padding(.horizontal, WindowMetrics.contentInset)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .contextMenu { rowMenu }
        // On the whole row: hovering the byte counts or the date is still
        // hovering this download, and its name is what you wanted.
        // The name, and where it landed once it has. The destination used to be
        // the sub-line on every finished row; it is a real fact and not one
        // worth a second line on every entry in the library, so it comes here
        // — with Show in Finder a click away in the context menu.
        .help(rowHelp)
    }

    /// A dash, not an empty cell. A column that disappears on some rows and
    /// not others stops reading as a column.
    private static let noValue = "—"

    /// The chevron, in a slot that is reserved whether or not this row has
    /// anything to open.
    ///
    /// **Reserved, because a ragged left edge is worse than a gap.** Only a
    /// multi-file torrent expands, so drawing the chevron only where it
    /// applies would start half the names twelve points left of the other
    /// half. The mocks show no chevron at all, which is what a still picture of
    /// a single-file download looks like; the tree it opens is unchanged, and
    /// this is the control that opens it.
    @ViewBuilder
    private var disclosure: some View {
        if isExpandable {
            Button(action: onToggleExpanded) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: IconSize.xs, weight: .bold))
                    .foregroundStyle(Palette.textTertiary)
                    .frame(width: IconSize.sm)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Hide files" : "Show files")
        } else {
            Color.clear.frame(width: IconSize.sm, height: 1)
        }
    }

    private var isExpandable: Bool {
        group.items.count > 1 || !model.skippedFiles(for: group).isEmpty
    }

    /// The Added column, or the row's controls while the pointer is on it.
    ///
    /// **Swapped, not overlaid, and inside a column that is already a fixed
    /// width.** The controls used to sit permanently at the end of every row,
    /// which is four glyphs of chrome per download and the reason the name had
    /// no room. They cannot be a hover *overlay* either: an overlay lands on
    /// top of the numbers, and the numbers are what someone hovering a
    /// downloading row is most likely reading. This cell is the least
    /// load-bearing one on the row at the moment you reach for a button, and
    /// swapping its contents cannot move anything, because the column's width
    /// is stated rather than intrinsic.
    ///
    /// Show in Finder and Remove are not here. They are terminal actions on a
    /// row that has stopped, and a menu is the right place for a thing you
    /// should not be able to hit by accident.
    @ViewBuilder
    private var trailingCell: some View {
        if isHovering, hasControls {
            HStack(spacing: Spacing.s8) {
                if model.canPause(group) {
                    controlButton("pause.fill", "Pause") { model.pauseTorrent(group) }
                }
                if model.canResume(group) {
                    controlButton("play.fill", "Resume") { model.resumeTorrent(group) }
                }
                if canCancel {
                    controlButton("xmark", "Cancel") { model.cancelTorrent(group) }
                }
            }
        } else {
            Text(group.addedAt.map { RelativeDay.text(for: $0) } ?? Self.noValue)
        }
    }

    private var hasControls: Bool {
        model.canPause(group) || model.canResume(group) || canCancel
    }

    /// Cancel is for work still in flight. A row that has stopped has nothing
    /// left to cancel; it needs removing, which is a different verb and lives
    /// in the menu.
    private var canCancel: Bool {
        !group.rowState.isTerminal && group.rowState != .failed
    }

    private func controlButton(
        _ symbol: String, _ label: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: IconSize.sm))
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
    }

    /// The row's own menu. Everything here was previously reachable only by
    /// finding the release in Search again — a torrent already on a row knew
    /// its own contents the whole time (`torrentFiles`), and offered no way to
    /// act on the parts of it that were skipped or that failed.
    @ViewBuilder
    private var rowMenu: some View {
        let others = model.redownloadablePaths(for: group)
        if !others.isEmpty {
            Button("Download \(others.count) Other File\(others.count == 1 ? "" : "s")") {
                Task {
                    await model.redownload(paths: Set(others.map(\.path)), from: group)
                }
            }
        }
        if group.section == .completed {
            Button("Show in Finder") { model.revealInFinder(group) }
        }
        if model.canPause(group) {
            Button("Pause") { model.pauseTorrent(group) }
        }
        if model.canResume(group) {
            Button("Resume") { model.resumeTorrent(group) }
        }
        if canCancel {
            Button("Cancel") { model.cancelTorrent(group) }
        }
        if group.section == .failed || group.section == .completed {
            Button("Remove Row") { model.removeTorrent(group) }
        }
    }
}
