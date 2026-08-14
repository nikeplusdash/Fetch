import SwiftUI
import FetchKit
import FetchPluginAPI

/// The book variant of a search result row (Figma `BookResultRow`): cache
/// badge · title · author · format chip · size · language · source, in
/// `default / alt / selected`.
///
/// Carries the same selection contract as `SearchResultRowView` (Task 13) —
/// `isSelected`, `isListFocused`, and an action cluster that reserves its
/// width whether or not it is shown — via the shared `ResultRowChrome`/
/// `ResultRowActions` both rows apply, so the two cannot drift the way they
/// did before (Task 13 review). `ResultsListView` wires `isSelected`/
/// `isListFocused` to `AppModel.selectedResultID` and the list's own focus
/// state, same as the plain row it sits beside.
struct BookResultRowView: View {
    @Environment(AppModel.self) private var model

    let result: SearchResult
    /// False inside a group, where the heading already carries the title and
    /// repeating it would bury the thing that actually differs. Previously
    /// accepted and silently dropped — every book row showed its title even
    /// nested under a `DisclosureGroup` whose header already said it.
    let showsTitle: Bool
    let isSelected: Bool
    let isListFocused: Bool
    let onActivate: () -> Void
    /// Distinct from `onActivate`: this queues the best candidate directly —
    /// the top-ranked format Gutenberg or Internet Archive offered — with no
    /// sheet. `onActivate` always opens the format picker. Previously both
    /// closures resolved to the same call at the `ResultsListView` call site,
    /// so the Download button and the "Choose format…" button did the
    /// identical thing (Task 13 review).
    let onCopyMagnet: () -> Void
    /// Selects this row. The row handles its own selection click — see
    /// `ResultRowChrome`.
    let onSelect: () -> Void
    /// Single click selects. Wired into `ResultRowChrome` alongside
    /// `onActivate`'s double-click on the same view, so the two gestures
    /// arbitrate reliably instead of both firing on a double-click.

    @State private var isHovered = false

    var body: some View {
        // The same container the header and the plain row use, so a book and a
        // film in one list put every column at the same x.
        ResultColumns(
            alignment: .top,
            ready: {
                // A book is almost always a direct download, which is the case
                // the old cache-only badge had no answer for.
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
                HStack(spacing: Spacing.s6) {
                    if showsTitle {
                        RevealingText(text: result.title, isRevealing: isSelected)
                            .layoutPriority(1)
                    }
                    Text(author)
                        .font(FetchFont.footnote)
                        .foregroundStyle(mutedRowForeground(
                            Palette.textSecondary,
                            isSelected: isSelected, isListFocused: isListFocused))
                        .lineLimit(1)
                    if let format = result.metadata.documentFormat {
                        QualityChipView(
                            label: format.displayName,
                            emphasis: result.metadata.provenance[.documentFormat] == .attribute
                                ? .known : .guessed,
                            isOnFill: isSelected && isListFocused)
                    }
                    Spacer(minLength: 0)
                    // At the end of the name rather than over Source — see
                    // `SearchResultRowView` for why.
                    ResultRowActions(
                        title: result.title,
                        isSelected: isSelected,
                        isHovered: isHovered,
                        hasMagnet: result.magnetURI != nil,
                        infoHelp: "Choose format…",
                        infoAccessibilityLabel: "Formats for \(result.title)",
                        onCopyMagnet: onCopyMagnet,
                        onActivate: onActivate)
                }
            },
            size: {
                Text(result.size.map(ByteCount.format) ?? "—")
                    .font(FetchFont.calloutMono)
                    .foregroundStyle(mutedRowForeground(
                        Palette.textSecondary,
                        isSelected: isSelected, isListFocused: isListFocused))
            },
            seeds: {
                Text(language)
                    .font(FetchFont.footnote)
                    .foregroundStyle(mutedRowForeground(
                        Palette.textSecondary,
                        isSelected: isSelected, isListFocused: isListFocused))
                    .lineLimit(1)
            },
            source: {
                Text(sourceLabel)
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
        // On the whole row, not on the title stack — see `SearchResultRowView`.
        .help(result.title)
    }

    /// The source did not always say — an em dash beats a blank line or a
    /// fabricated "Unknown".
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
