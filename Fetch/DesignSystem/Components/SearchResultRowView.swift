import SwiftUI
import FetchKit

/// One release in the results list (Figma `SearchResultRow`).
///
/// Selection paints the row and reveals its actions. Before this, a click did
/// nothing visible and the only way to open a result was a double-click no
/// affordance advertised — which is the complaint this closes.
///
/// Carries the same selection contract as `BookResultRowView` — `isSelected`,
/// `isListFocused`, and an action cluster that reserves its width whether or
/// not it is shown — via the shared `ResultRowChrome`/`ResultRowActions` both
/// rows apply, so the two cannot drift the way they did before (Task 13
/// review).
struct SearchResultRowView: View {
    @Environment(AppModel.self) private var model

    let result: SearchResult
    /// False inside a group, where the heading already carries the title and
    /// repeating it would bury the thing that actually differs: the quality.
    let showsTitle: Bool
    let isSelected: Bool
    /// A selected row in an unfocused list uses the muted fill. Painting full
    /// accent blue would claim focus the list does not have.
    let isListFocused: Bool
    let onActivate: () -> Void
    let onCopyMagnet: () -> Void
    /// Single click selects. Wired into `ResultRowChrome` alongside
    /// `onActivate`'s double-click on the same view, so the two gestures
    /// arbitrate reliably instead of both firing on a double-click.

    @State private var isHovered = false

    var body: some View {
        // `ResultColumns` — the same container the header uses, so the widths,
        // the gaps and the alignments are declared once. Six attempts at
        // making two separate `HStack`s agree preceded it, and each fixed one
        // mismatch and revealed the next.
        ResultColumns(
            alignment: .top,
            ready: {
                // "Does this start when I click it?" — not "is it cached",
                // which only torrents can answer and left every Archive.org
                // file and every Gutenberg book with a blank column.
                ReadinessBadgeView(
                    readiness: ResultReadiness.of(result, cacheStates: model.cacheStates),
                    isOnFill: isSelected && isListFocused,
                    onRetry: result.infoHashHex.map { hash in
                        { model.retryCacheCheck(hash: hash) }
                    })
            },
            kind: {
                KindPillView(
                    kind: result.metadata.mediaKind, isOnFill: isSelected && isListFocused)
            },
            name: {
                // One line: stacking the chips under the title made each row's
                // height depend on whether its release had any, so the list
                // had ragged rows and nothing could sit level with anything.
                HStack(spacing: Spacing.s6) {
                    if showsTitle {
                        RevealingText(text: result.title, isRevealing: isSelected)
                            .layoutPriority(1)
                    }
                    qualityChips
                    Spacer(minLength: 0)
                }
            },
            size: {
                // An em dash, not "0 bytes": the source did not say, which is
                // a different fact from a zero-byte file.
                Text(result.size.map(ByteCount.format) ?? "—")
                    .font(FetchFont.calloutMono)
                    .foregroundStyle(mutedRowForeground(
                        Palette.textSecondary,
                        isSelected: isSelected, isListFocused: isListFocused))
            },
            seeds: {
                SeederMeterView(
                    seeders: result.seeders, isOnFill: isSelected && isListFocused)
            },
            source: {
                Text(indexerLabel)
                    .font(FetchFont.footnote)
                    .foregroundStyle(mutedRowForeground(
                        Palette.textTertiary,
                        isSelected: isSelected, isListFocused: isListFocused))
                    .lineLimit(1)
            },
            trailing: {
                ResultRowActions(
                    title: result.title,
                    isSelected: isSelected,
                    isHovered: isHovered,
                    hasMagnet: result.magnetURI != nil,
                    infoHelp: "Choose files…",
                    infoAccessibilityLabel: "Details for \(result.title)",
                    onCopyMagnet: onCopyMagnet,
                    onActivate: onActivate)
            })
        .resultRowChrome(
            isSelected: isSelected, isListFocused: isListFocused,
            hasMagnet: result.magnetURI != nil,
            sourcePage: SourcePage.url(for: result), isHovered: $isHovered,
            onActivate: onActivate, onCopyMagnet: onCopyMagnet)
        // On the whole row, not on the title stack. Hovering the size, the
        // seeder meter or the empty space between them is still hovering this
        // release, and the name is what you wanted when you pointed at it.
        .help(result.title)
    }

    /// Provenance made visible: a value an indexer stated reads `known`, one
    /// the release-name parser inferred reads `guessed`.
    private var qualityChips: some View {
        HStack(spacing: Spacing.s4) {
            // `id: \.field` rather than `\.label` — two chips can share a
            // label (an empty release group and a genuinely empty string
            // both surface as "", or two differently-cased sources collapse
            // once uppercased), and `MetadataField` is the actual identity
            // each chip carries.
            ForEach(QualitySummary.chips(of: result.metadata), id: \.field) { chip in
                QualityChipView(
                    label: chip.label, emphasis: chip.emphasis,
                    isOnFill: isSelected && isListFocused)
            }
        }
    }

    private var indexerLabel: String {
        IndexerLabel.text(for: result.sources, naming: model.indexerName)
    }
}
