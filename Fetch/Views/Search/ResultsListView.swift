import AppKit
import SwiftUI
import FetchKit

/**
 The results list (§12.1).

 A `TableContainer` rather than a `List`: the native list painted AppKit's
 accent slab under the row's own themed fill, and its header had to be hosted
 in a second scroll-disabled list to share the rows' inset. The container
 measures the width once and hands it to the header and every row, so all of
 them lay out from `TableColumns.results`.
 */
struct ResultsListView: View {
    @Environment(AppModel.self) private var model
    let onActivate: (SearchResult) -> Void

    var body: some View {
        @Bindable var model = model
        return TableContainer(
            ids: model.visibleResults.map(\.id),
            policy: .results,
            selection: $model.resultSelection,
            onActivate: activate
        ) { width in
            TableHeader(
                set: TableColumns.results,
                width: width,
                activeSort: model.searchSort.rawValue,
                ascending: !model.sortDescending,
                onSort: { key in
                    guard let sort = ResultSort(rawValue: key) else { return }
                    model.applySort(sort)
                })
        } rows: { width in
            rows(width: width)
        }
    }

    @ViewBuilder
    private func rows(width: CGFloat) -> some View {
        ForEach(Array(model.visibleResults.enumerated()), id: \.element.id) { index, result in
            row(result, width: width)
                .id(result.id)
                .selectableRow(
                    isSelected: model.resultSelection.isSelected(result.id),
                    onSelect: { model.resultSelection.click(result.id) },
                    onActivate: { onActivate(result) })
                .contextMenu { menu(for: result) }
                .onAppear { model.requestCacheChecks(throughIndex: index) }
        }
        paginationFooter
    }

    @ViewBuilder
    private func row(_ result: SearchResult, width: CGFloat) -> some View {
        if result.metadata.mediaKind == .book {
            BookResultRowView(
                result: result,
                showsTitle: true,
                width: width,
                onActivate: { onActivate(result) },
                onCopyMagnet: { model.copyMagnet(result) })
        } else {
            SearchResultRowView(
                result: result,
                showsTitle: true,
                width: width,
                onActivate: { onActivate(result) },
                onCopyMagnet: { model.copyMagnet(result) })
        }
    }

    @ViewBuilder
    private func menu(for result: SearchResult) -> some View {
        Button("Download…") { onActivate(result) }
        if let page = SourcePage.url(for: result) {
            Button("Open on the Web…") { NSWorkspace.shared.open(page) }
        }
        if result.magnetURI != nil {
            Button("Copy Magnet Link") { model.copyMagnet(result) }
        }
    }

    private func activate(_ id: ResultID) {
        guard let result = model.visibleResults.first(where: { $0.id == id }) else { return }
        onActivate(result)
    }

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
        } else if model.loadMoreFailed {
            Button("Retry loading more") {
                Task { await model.loadMoreResults() }
            }
            .buttonStyle(.link)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, Spacing.s8)
        } else if model.canLoadMore {
            Color.clear
                .frame(height: 1)
                .onAppear { Task { await model.loadMoreResults() } }
        }
    }
}

enum QualitySummary {
    struct Chip {
        let label: String
        let emphasis: QualityChipView.Emphasis
        let field: MetadataField
    }

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

    static func parts(of metadata: ReleaseMetadata) -> [String] {
        chips(of: metadata).map(\.label)
    }
}
