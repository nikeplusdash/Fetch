import SwiftUI
import FetchKit

/**
 One row of the Downloads list: a glyph, a name with one line under it, and
 three numbers.

 **Five columns, and the widths are the point.** `ColumnWidth.status`,
 `.downloadSize`, `.rate` and `.added` are fixed and must stay fixed: every
 value in them changes length as a download runs — bytes gaining a digit, a
 rate crossing a unit, an ETA going from "45s" to "about 3 minutes" — and an
 unconstrained `Text` reflows the whole row each time, ten times a second.
 A column that does not fit in a narrow window should be *dropped* at a
 breakpoint, never made flexible.

 **The word beside the glyph is gone.** `StateLabel` drew an icon and a word
 together in a 92-point column, so nine downloads carried nine repetitions of
 eight strings on a screen whose title column was the thing being squeezed.
 Those points are the Added column now, and the word survives as the glyph's
 tooltip and accessibility label, which is the only place it was ever
 load-bearing.
 */
struct DownloadRowView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.rowState) private var rowState
    let group: AppModel.TorrentGroup
    let isExpanded: Bool
    let width: CGFloat
    let columns: ColumnSet<DownloadColumn>
    let onToggleExpanded: () -> Void

    private var placement: SublinePlacement {
        var facts = model.facts(for: group)
        if group.rowState == .cloudQueued, let id = group.items.first?.id {
            facts.cloudDiagnosis = model.cloudDiagnoses[id]
        }
        return DownloadSubline.placement(facts)
    }

    private var rowHelp: String {
        var lines = [group.displayName]
        if case .tooltip(let status) = placement { lines.append(status) }
        if let destination = model.destinationText(for: group), !destination.isEmpty {
            lines.append(destination)
        }
        return lines.joined(separator: "\n")
    }

    var body: some View {
        ColumnRow(set: columns, width: width, layout: layout) { spec in
            switch spec.id {
            case .status:
                StateGlyph(state: group.rowState)
            case .name:
                VStack(alignment: .leading, spacing: RowHeight.subLineGap) {
                    HStack(spacing: Spacing.s4) {
                        DisclosureChevron(
                            isExpanded: isExpanded,
                            isExpandable: isExpandable,
                            onToggle: onToggleExpanded)
                        RevealingText(text: group.displayName, isRevealing: rowState.isSelected)
                    }
                    if case .underName(let subline) = placement {
                        Text(subline)
                            .font(FetchFont.subheadline)
                            .foregroundStyle(rowState.ink(Palette.textSecondary))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .padding(.leading, IconSize.sm + Spacing.s4)
                    }
                    if group.isMoving, let fraction = group.fraction {
                        ProgressTrack(fraction: fraction)
                            .padding(.top, RowHeight.trackTopGap - RowHeight.subLineGap)
                            .padding(.leading, IconSize.sm + Spacing.s4)
                    }
                }
            case .size:
                Text(ByteCount.format(group.totalBytes))
            case .rate:
                Text(group.rowState == .downloading && group.bytesPerSecond > 0
                     ? ByteCount.rate(Int64(group.bytesPerSecond))
                     : Self.noValue)
            case .added:
                trailingCell
            }
        }
        .font(FetchFont.calloutMono)
        .foregroundStyle(rowState.ink(Palette.textTertiary))
        .padding(.vertical, RowHeight.rowPaddingV)
        .help(rowHelp)
    }

    /**
     A row that has stopped moving is one line: its glyph already says how it
     ended, and a library of finished entries would otherwise be twice as
     tall for a line nobody reads twice. What that line said is in the
     tooltip instead.
     */
    private var layout: RowLayout {
        placement.isUnderName || (group.isMoving && group.fraction != nil)
            ? .stacked(firstLineHeight: RowMetrics.firstLine)
            : .single
    }

    private static let noValue = "—"

    private var isExpandable: Bool {
        group.items.count > 1 || !model.skippedFiles(for: group).isEmpty
    }

    @ViewBuilder
    private var trailingCell: some View {
        if rowState.isHovered, hasControls {
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

    private var canCancel: Bool {
        DownloadFilter.isCancellable(group.rowState) && !group.rowState.isCloudOnly
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
