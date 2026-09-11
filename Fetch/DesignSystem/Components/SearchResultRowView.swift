import SwiftUI
import FetchKit

/**
 One release in the results list (Figma `SearchResultRow`).

 Renders `TableColumns.results` through `ColumnRow`, the same value the
 header renders, so a cell cannot land under the wrong heading. It paints
 nothing: selection, hover and the focus-lost fill belong to `SelectableRow`,
 which publishes what it painted through `\\.rowState` — that is where the
 fields learn whether they are sitting on a filled row and need a lighter ink.
 */
struct SearchResultRowView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.rowState) private var rowState

    let result: SearchResult
    let showsTitle: Bool
    let width: CGFloat
    let onActivate: () -> Void
    let onCopyMagnet: () -> Void

    var body: some View {
        ColumnRow(set: TableColumns.results, width: width) { spec in
            switch spec.id {
            case .cache:
                ReadinessBadgeView(
                    readiness: ResultReadiness.of(result, cacheStates: model.cacheStates),
                    isOnFill: rowState.isOnFill,
                    onRetry: result.infoHashHex.map { hash in
                        { model.retryCacheCheck(hash: hash) }
                    })
            case .kind:
                KindPillView(kind: result.metadata.mediaKind, isOnFill: rowState.isOnFill)
            case .name:
                HStack(spacing: Spacing.s4) {
                    if showsTitle {
                        RevealingText(text: result.title, isRevealing: rowState.isSelected)
                    }
                    Spacer(minLength: 0)
                    ResultRowActions(
                        title: result.title,
                        isSelected: rowState.isSelected,
                        isHovered: rowState.isHovered,
                        hasMagnet: result.magnetURI != nil,
                        infoHelp: "Choose files…",
                        infoAccessibilityLabel: "Details for \(result.title)",
                        onCopyMagnet: onCopyMagnet,
                        onActivate: onActivate)
                }
            case .size:
                Text(result.size.map(ByteCount.format) ?? "—")
                    .font(FetchFont.calloutMono)
                    .foregroundStyle(rowState.ink(Palette.textSecondary))
            case .seeds:
                SeederMeterView(seeders: result.seeders, isOnFill: rowState.isOnFill)
            case .source:
                Text(indexerLabel)
                    .font(FetchFont.footnote)
                    .foregroundStyle(rowState.ink(Palette.textTertiary))
                    .lineLimit(1)
            }
        }
        .padding(.vertical, Spacing.s2)
        .frame(minHeight: RowMetrics.single)
        .help(result.title)
    }

    private var indexerLabel: String {
        IndexerLabel.text(for: result.sources, naming: model.indexerName)
    }
}
