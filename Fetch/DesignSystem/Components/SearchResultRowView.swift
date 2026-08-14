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
    /// Selects this row. The row handles its own selection click — see
    /// `ResultRowChrome`.
    let onSelect: () -> Void
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
                // **The name gets the whole column.** The quality chips used to
                // sit beside it, taking as much of the line as the release had
                // fields — so the one thing every row is identified by was the
                // one thing squeezed, and a long release name was cut in half
                // to make room for four capsules repeating what the name
                // already says. The chips are gone; what they carried is in the
                // name, and what the name cannot fit is revealed by selecting
                // the row.
                // **The actions live at the end of the name, not over the
                // Source column.** Laid over the trailing edge they covered
                // the indexer name — the one column a reader checks to see
                // *where* a result came from — and they sat a full table's
                // width away from the thing they act on. Inside the name
                // column they are next to the title, and the reserved 64
                // points simply make the name that much shorter instead of
                // hiding a column that was already there.
                HStack(spacing: Spacing.s4) {
                    if showsTitle {
                        RevealingText(text: result.title, isRevealing: isSelected)
                    }
                    Spacer(minLength: 0)
                    ResultRowActions(
                        title: result.title,
                        isSelected: isSelected,
                        isHovered: isHovered,
                        hasMagnet: result.magnetURI != nil,
                        infoHelp: "Choose files…",
                        infoAccessibilityLabel: "Details for \(result.title)",
                        onCopyMagnet: onCopyMagnet,
                        onActivate: onActivate)
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
            })
        .resultRowChrome(
            isSelected: isSelected, isListFocused: isListFocused,
            hasMagnet: result.magnetURI != nil,
            sourcePage: SourcePage.url(for: result), isHovered: $isHovered,
            onActivate: onActivate, onCopyMagnet: onCopyMagnet, onSelect: onSelect)
        // On the whole row, not on the title stack. Hovering the size, the
        // seeder meter or the empty space between them is still hovering this
        // release, and the name is what you wanted when you pointed at it.
        .help(result.title)
    }


    private var indexerLabel: String {
        IndexerLabel.text(for: result.sources, naming: model.indexerName)
    }
}
