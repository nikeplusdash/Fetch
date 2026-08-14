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
        VStack(spacing: 0) {
            header
            list
        }
    }

    /// The column headings, fixed above the list.
    ///
    /// **A `List` of its own, and that is the whole trick.** The rows'
    /// horizontal geometry is the list style's, not ours — `.plain` insets its
    /// content by around eight points that `listRowInsets(EdgeInsets())` does
    /// not reach — and five attempts at a pinned header have each been out by
    /// exactly that. Measuring it does not work either: `List` hosts its rows
    /// apart from the rest of the tree, so a `PreferenceKey` set inside one
    /// never reaches a view outside.
    ///
    /// A header laid out by the same style in the same kind of container
    /// cannot disagree with the rows, because nothing is being matched. It is
    /// the trick `SettingsView` already uses to line its segmented header up
    /// with the panes below it.
    private var header: some View {
        List {
            ResultsHeaderView()
                .resultsColumnLayout()
                // The rows are in a scrolling list and this is not, so on
                // legacy scrollers they end at two different right edges. See
                // `ScrollerInset`.
                .padding(.trailing, ScrollerInset.shared.width)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .selectionDisabled()
        }
        .listStyle(.plain)
        .scrollDisabled(true)
        .scrollContentBackground(.hidden)
        // Nothing may squeeze the headings shorter than they ask to be, and
        // the container takes exactly their height.
        .environment(\.defaultMinListRowHeight, ResultsHeaderView.height)
        .frame(height: ResultsHeaderView.height)
    }

    private var list: some View {
        @Bindable var model = model
        return List(selection: $model.selectedResultID) {
            // **Always flat.** Grouped/Items was a control with no counterpart
            // in the design, and the column headings — the thing that makes
            // this read as a table — only ever rendered in the flat half of
            // it. `ContentGroup` and `AppModel.contentGroups` are untouched;
            // nothing renders them for now.
            //
            rows
        }
        // **Plain, so the only horizontal inset is ours.** `.inset` adds one
        // of its own that `listRowInsets(EdgeInsets())` does not reach — which
        // is why a header outside the list could never line up with the rows,
        // and why measuring it is no help either: `List` hosts its rows apart
        // from the rest of the tree, so a `PreferenceKey` set inside one never
        // reaches a view outside. With that inset gone, both sides have only
        // `resultsColumnLayout()`, which is one modifier and one constant.
        .listStyle(.plain)
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
                    onCopyMagnet: { model.copyMagnet(result) },
                    onSelect: { model.selectedResultID = result.id })
            } else {
                SearchResultRowView(
                    result: result,
                    showsTitle: showsTitle,
                    isSelected: model.selectedResultID == result.id,
                    isListFocused: isListFocused,
                    onActivate: { onActivate(result) },
                    onCopyMagnet: { model.copyMagnet(result) },
                    onSelect: { model.selectedResultID = result.id })
            }
        }
        // The tag is the whole selection mechanism: `List` writes
        // `selectedResultID` on mouse-down, and drives ↑/↓ from it too.
        .tag(result.id)
        .resultsColumnLayout()
        .padding(.vertical, Spacing.s4)
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
