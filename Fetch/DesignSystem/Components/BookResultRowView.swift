import SwiftUI
import FetchKit
import FetchPluginAPI

/**
 The book variant of a search result row (Figma `BookResultRow`): cache badge
 · title · author · format chip · size · language · source.

 The same `TableColumns.results` set as `SearchResultRowView`, with the seeds
 slot carrying a language instead of a meter — which is why the two rows can
 sit in one list under one header without either knowing about the other.
 Muted fields take their ink from `\\.rowState` rather than from a flag passed
 down by hand, so a selected book row cannot end up with grey text on its
 own fill again.
 */
struct BookResultRowView: View {
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
                HStack(spacing: Spacing.s6) {
                    if showsTitle {
                        RevealingText(text: result.title, isRevealing: rowState.isSelected)
                            .layoutPriority(1)
                    }
                    Text(author)
                        .font(FetchFont.footnote)
                        .foregroundStyle(rowState.ink(Palette.textSecondary))
                        .lineLimit(1)
                    if let format = result.metadata.documentFormat {
                        QualityChipView(
                            label: format.displayName,
                            emphasis: result.metadata.provenance[.documentFormat] == .attribute
                                ? .known : .guessed,
                            isOnFill: rowState.isOnFill)
                    }
                    Spacer(minLength: 0)
                    ResultRowActions(
                        title: result.title,
                        isSelected: rowState.isSelected,
                        isHovered: rowState.isHovered,
                        hasMagnet: result.magnetURI != nil,
                        infoHelp: "Choose format…",
                        infoAccessibilityLabel: "Formats for \(result.title)",
                        onCopyMagnet: onCopyMagnet,
                        onActivate: onActivate)
                }
            case .size:
                Text(result.size.map(ByteCount.format) ?? "—")
                    .font(FetchFont.calloutMono)
                    .foregroundStyle(rowState.ink(Palette.textSecondary))
            case .seeds:
                Text(language)
                    .font(FetchFont.footnote)
                    .foregroundStyle(rowState.ink(Palette.textSecondary))
                    .lineLimit(1)
            case .source:
                Text(sourceLabel)
                    .font(FetchFont.footnote)
                    .foregroundStyle(rowState.ink(Palette.textTertiary))
                    .lineLimit(1)
            }
        }
        .padding(.vertical, Spacing.s2)
        .frame(minHeight: RowMetrics.single)
        .help(result.title)
    }

    private var author: String {
        result.metadata.author ?? result.rawAttributes["author"] ?? "—"
    }

    private var language: String {
        if let first = result.metadata.languages.first { return first }
        if let raw = result.rawAttributes["languages"] ?? result.rawAttributes["language"] {
            return raw.split(separator: ",").first.map(String.init) ?? raw
        }
        return "—"
    }

    private var sourceLabel: String {
        IndexerLabel.text(for: result.sources, naming: model.indexerName)
    }
}
