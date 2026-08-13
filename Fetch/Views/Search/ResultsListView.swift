import SwiftUI
import FetchKit

/// The results list (§12.1), grouped by content or flat.
///
/// A `List` with `DisclosureGroup` rather than the `Table` this replaces:
/// `Table` cannot express a row that expands into child rows, and grouping is
/// the whole point — a query for "dune" returns the same handful of films a
/// dozen times over, and a flat list buries the REMUX under three webrips of
/// the same title.
struct ResultsListView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var isListFocused: Bool
    let onActivate: (SearchResult) -> Void

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedResultID) {
            if !model.isGrouped {
                // **A plain row, and that is the whole point.** Four previous
                // attempts put the header somewhere that had *nearly* the
                // rows' geometry — beside the list, in a `Section`, in a
                // safe-area inset — and each time the list applied something
                // to the rows that the header never saw: its style's inset,
                // then a section's content indent. Every fix removed one
                // disagreement and revealed the next.
                //
                // The header is a row now. Not a row-like thing: the same
                // construct, in the same container, through the same
                // `resultsColumnLayout()` both apply. There is no geometry
                // left for one to have and the other to miss. It scrolls away
                // with the list, which is the price, and cheaper than a fifth
                // attempt at pinning something that will not line up.
                ResultsHeaderView()
                    .resultsColumnLayout()
                    .listRowSeparator(.hidden)
                    .selectionDisabled()
                rows
            } else {
                ForEach(model.contentGroups) { group in
                    if group.releaseCount == 1, let only = group.best {
                        // A lone release needs no disclosure triangle to hide
                        // one child behind.
                        row(only, showsTitle: true)
                    } else {
                        DisclosureGroup {
                            ForEach(group.releases) { release in
                                row(release, showsTitle: false)
                            }
                        } label: {
                            GroupRow(group: group)
                        }
                    }
                }
                paginationFooter
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .focused($isListFocused)
        // ↑/↓ come free from the selection binding. Return does not — and a
        // list you can walk with the keyboard but not open is worse than one
        // you cannot walk at all.
        .onKeyPress(.return) {
            guard let id = model.selectedResultID,
                  let result = model.visibleResults.first(where: { $0.id == id })
            else { return .ignored }
            onActivate(result)
            return .handled
        }
    }

    /// The flat list's rows.
    ///
    /// Enumerated so a row can say how far down the list it is, which is what
    /// lets the cache check follow the reader rather than the order the
    /// indexer happened to return things in.
    @ViewBuilder
    private var rows: some View {
        ForEach(Array(model.visibleResults.enumerated()), id: \.element.id) { index, result in
            row(result, showsTitle: true)
                .onAppear { model.requestCacheChecks(throughIndex: index) }
        }
        paginationFooter
    }

    /// Fetches the next page when the bottom of the list comes into view.
    ///
    /// A search was one page deep and stopped there: `SearchQuery` has carried
    /// an offset since M2 and every provider honours it, but nothing ever sent
    /// one. Scrolling to the end simply ran out of results with no indication
    /// that more existed.
    ///
    /// **A failed page shows Retry rather than re-arming.** `.onAppear` fires
    /// again every time the footer is scrolled back into view, so a footer that
    /// retries by itself is an unbounded request loop against every configured
    /// indexer — `AppModel.loadMoreResults` guards the same thing from its
    /// side, and this is the half the user can see.
    @ViewBuilder
    private var paginationFooter: some View {
        if model.isLoadingMore {
            HStack(spacing: Spacing.s8) {
                ProgressView().controlSize(.small)
                Text("Loading more…")
                    .font(FetchFont.footnote)
                    .foregroundStyle(Palette.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, Spacing.s8)
            .selectionDisabled()
        } else if model.loadMoreFailed {
            Button("Retry loading more") {
                Task { await model.loadMoreResults() }
            }
            .buttonStyle(.link)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, Spacing.s8)
            .selectionDisabled()
        } else if model.canLoadMore {
            // An empty marker rather than a visible control: reaching it *is*
            // the request. It still carries a height, because a zero-height row
            // may never be laid out and so may never appear.
            Color.clear
                .frame(height: 1)
                .selectionDisabled()
                .onAppear { Task { await model.loadMoreResults() } }
        }
    }

    /// The book variant (Figma `BookResultRow`) whenever a result actually is
    /// one — `SearchResultRowView` otherwise. Both carry the same selection
    /// contract, so a click paints either kind of row the same way.
    ///
    /// Selection is `List`'s, via `.tag` — no click handler of our own.
    /// The rows briefly carried a count-1 gesture beside their count-2 one,
    /// which made every click wait out the double-click interval before the
    /// row lit up: SwiftUI has to see the double tap fail before it can fire
    /// the single.
    @ViewBuilder
    private func row(_ result: SearchResult, showsTitle: Bool) -> some View {
        Group {
            if result.metadata.mediaKind == .book {
                BookResultRowView(
                    result: result,
                    showsTitle: showsTitle,
                    isSelected: model.selectedResultID == result.id,
                    isListFocused: isListFocused,
                    onActivate: { onActivate(result) },
                    onCopyMagnet: { model.copyMagnet(result) })
            } else {
                SearchResultRowView(
                    result: result,
                    showsTitle: showsTitle,
                    isSelected: model.selectedResultID == result.id,
                    isListFocused: isListFocused,
                    onActivate: { onActivate(result) },
                    onCopyMagnet: { model.copyMagnet(result) })
            }
        }
        // The tag is the whole selection mechanism: `List` writes
        // `selectedResultID` on mouse-down, and drives ↑/↓ from it too.
        .tag(result.id)
        .resultsColumnLayout()
        .padding(.vertical, Spacing.s4)
    }

}

/// A content group's header: what it is, how many releases, and the best
/// available cache state among them.
private struct GroupRow: View {
    @Environment(AppModel.self) private var model
    let group: ContentGroup

    var body: some View {
        HStack(spacing: Spacing.s8) {
            CacheBadgeView(state: model.cacheState(for: group))

            VStack(alignment: .leading, spacing: Spacing.s2) {
                Text(group.year.map { "\(group.displayTitle) (\($0))" } ?? group.displayTitle)
                    .font(FetchFont.body)
                    .lineLimit(1)
                Text(summary)
                    .font(FetchFont.footnote)
                    .foregroundStyle(Palette.textSecondary)
            }

            Spacer()

            Text("\(group.maxSeeders)")
                .font(FetchFont.calloutMono)
                .foregroundStyle(Palette.textSecondary)
                .help("Best seeder count in this group")
        }
        .padding(.vertical, Spacing.s2)
    }

    /// The best release's quality, which is what the group is really offering —
    /// the count alone says nothing about whether any of them is worth having.
    private var summary: String {
        var parts = ["\(group.releaseCount) releases"]
        if let best = group.best {
            let quality = QualitySummary.parts(of: best.metadata)
            if !quality.isEmpty { parts.append(quality.joined(separator: " · ")) }
        }
        return parts.joined(separator: " — ")
    }
}

enum QualitySummary {
    struct Chip {
        let label: String
        let emphasis: QualityChipView.Emphasis
        let field: MetadataField
    }

    /// Ordered most to least distinguishing, so a truncated line still says
    /// the useful part.
    ///
    /// Each chip carries where its value came from. `ReleaseMetadata.provenance`
    /// records `.attribute` for a value an indexer stated and `.titleParse` for
    /// one the parser inferred — the same distinction that decides routing, and
    /// the one `QualityChip.Emphasis` exists to render.
    static func chips(of metadata: ReleaseMetadata) -> [Chip] {
        var chips: [Chip] = []
        func add(_ value: String?, _ field: MetadataField) {
            guard let value, !value.isEmpty else { return }
            chips.append(Chip(
                label: value,
                emphasis: metadata.provenance[field] == .attribute ? .known : .guessed,
                field: field))
        }
        add(metadata.resolution?.name, .resolution)
        add(metadata.source?.name.uppercased(), .source)
        add(metadata.videoCodec?.name, .videoCodec)
        add(metadata.hdr?.name.uppercased(), .hdr)
        add(metadata.releaseGroup.map { "-\($0)" }, .releaseGroup)
        return chips
    }

    /// The same values as one string, for the group header where chips would
    /// compete with the title.
    static func parts(of metadata: ReleaseMetadata) -> [String] {
        chips(of: metadata).map(\.label)
    }

}


/// The horizontal geometry the results list's header and its rows share.
///
/// One modifier applied to both, rather than two call sites that happen to use
/// the same constant. The header and the rows disagreed four times running —
/// the list's style inset the rows, a section indented them, a safe-area inset
/// sat outside all of it — and every fix was a number matched by hand against
/// a number the list chose. Zeroing the row inset takes the list out of the
/// decision entirely; the padding inside is then the only thing either of them
/// has, and it is literally the same code.
extension View {
    func resultsColumnLayout() -> some View {
        listRowInsets(EdgeInsets())
            .padding(.horizontal, ColumnWidth.rowInset)
    }
}
