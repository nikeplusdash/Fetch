import SwiftUI
import FetchKit

/**
 The Search screen (design spec §12.1) — search field, facet sidebar,
 results grouped by content, and the states from the M2 brief: no query, no
 results, no providers configured, and all-providers-failed.

 Grouping, faceting, and sort all recompute from results already in memory,
 so none of the three re-runs the search.
 */
struct SearchView: View {
    @Environment(AppModel.self) private var model

    @State private var pickerResult: SearchResult?
    @State private var magnetSheetItem: MagnetSheetItem?
    @State private var magnetOffer: MagnetOffer?
    @State private var structuredTokenDismissed = false
    @State private var pillsHidden: CGPoint = .zero
    @State private var readinessBannerDismissed = false
    @Environment(\.errorPresenter) private var errorPresenter

    private static let typingDelay = Duration.milliseconds(450)

    private struct MagnetSheetItem: Identifiable {
        let id = UUID()
        let text: String
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            magnetOfferRow
            content
        }
        .onChange(of: model.searchBanner) { _, banner in
            guard let banner else { return }
            errorPresenter?.present(AppAlert(message: banner))
            model.dismissSearchBanner()
        }
        .task(id: model.searchFieldText) {
            let trimmed = model.searchFieldText
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != model.lastSearchQuery else { return }
            guard PastedLink.magnetOffer(from: trimmed) == nil else { return }
            let lowered = trimmed.lowercased()
            guard !lowered.hasPrefix("http://"), !lowered.hasPrefix("https://") else { return }

            guard (try? await Task.sleep(for: Self.typingDelay)) != nil else { return }
            await model.runSearch(trimmed)
        }
        .onChange(of: model.cacheReadiness.searchBannerText, initial: true) { _, message in
            guard let message, !readinessBannerDismissed else { return }
            readinessBannerDismissed = true
            let title = model.cacheReadiness.searchBannerActionTitle
            errorPresenter?.present(AppAlert(
                message: message,
                actionTitle: title,
                action: title == nil ? nil : { model.navigate(to: .debrid) }))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onExitCommand {
            guard model.showsFilters else { return }
            model.showsFilters = false
        }
        .navigationTitle("Search")
        .sheet(item: $pickerResult) { result in
            switch ResultPresentation.of(result) {
            case .torrentPicker:
                FilePickerSheet(result: result, indexerLabel: indexerLabel(for: result))
            case .archiveItem:
                ArchiveItemSheet(result: result)
            case .bookFormats:
                BookItemSheet(result: result)
            case .directDownload:
                VStack(spacing: Spacing.s8) {
                    Text("Nothing to choose")
                        .font(FetchFont.title3)
                    Text("This result is a single file and downloads directly.")
                        .foregroundStyle(Palette.textSecondary)
                    Button("Close") { pickerResult = nil }
                }
                .padding(Spacing.s24)
                .frame(width: 360)
            }
        }
        .sheet(item: $magnetSheetItem) { item in
            AddLinkSheet(initialText: item.text)
        }
        .animation(.snappy(duration: 0.22), value: model.showsFilters)
    }

    private var filtersToggle: some View {
        @Bindable var model = model
        return Button {
            model.showsFilters.toggle()
        } label: {
            Circle()
                .fill(model.showsFilters ? Palette.accent : .clear)
                .overlay(
                    Circle().strokeBorder(
                        model.showsFilters ? .clear : Palette.separator, lineWidth: 1))
                .overlay(
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.system(size: IconSize.md))
                        .foregroundStyle(
                            model.showsFilters ? Palette.textOnAccent : Palette.textPrimary))
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(model.showsFilters ? "Hide filters" : "Show filters")
        .accessibilityLabel("Filters")
        .accessibilityAddTraits(model.showsFilters ? [.isButton, .isSelected] : .isButton)
    }


    private var searchBar: some View {
        @Bindable var model = model
        return VStack(spacing: 0) {
            ScreenTitleBar()
            HStack(spacing: Spacing.s8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: IconSize.md))
                    .foregroundStyle(Palette.textSecondary)
                TextField("Search…", text: $model.searchFieldText)
                    .textFieldStyle(.plain)
                    .font(FetchFont.body)
                    .onSubmit(runSearch)

                progressReadout
            }
            .padding(.horizontal, WindowMetrics.controlInset)
            .frame(height: RowHeight.searchField)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Radius.r10))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.r10)
                    .strokeBorder(Palette.separator, lineWidth: 1))
            .padding(.horizontal, WindowMetrics.contentInset)
            .padding(.top, Spacing.s2)


            VStack(alignment: .leading, spacing: Spacing.s6) {
                if let extraction = structuredExtraction {
                    structuredQueryToken(extraction)
                }
                HStack(spacing: Spacing.s12) {
                    categoryBar
                        .mask(categoryBarMask)
                    filtersToggle
                }
            }
            .padding(.horizontal, WindowMetrics.contentInset)
            .padding(.top, Spacing.s10)
            .padding(.bottom, Spacing.s6)
        }
        .onChange(of: model.searchFieldText) { _, newValue in
            structuredTokenDismissed = false
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)

            if let offer = PastedLink.magnetOffer(from: trimmed) {
                guard offer.id != magnetOffer?.id else { return }
                magnetOffer = offer
                model.beginAvailabilityCheck(
                    for: .pastedMagnet(offer.magnet, source: AppModel.droppedSource))
                return
            }
            magnetOffer = nil

            let lowered = trimmed.lowercased()
            if lowered.hasPrefix("https://") || lowered.hasPrefix("http://") {
                magnetSheetItem = MagnetSheetItem(text: trimmed)
                return
            }

            guard trimmed.isEmpty else { return }
            Task { await model.runSearch("") }
            model.searchFieldText = ""
        }
    }

    @ViewBuilder
    private var magnetOfferRow: some View {
        if let offer = magnetOffer {
            HStack(spacing: Spacing.s10) {
                Image(systemName: "link")
                    .font(.system(size: IconSize.md))
                    .foregroundStyle(Palette.accent)
                VStack(alignment: .leading, spacing: RowHeight.subLineGap) {
                    Text(offer.displayName)
                        .font(FetchFont.body)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(offer.shortHash)
                        .font(FetchFont.footnoteMono)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("Open") {
                    pickerResult = .pastedMagnet(
                        offer.magnet, source: AppModel.droppedSource)
                    model.searchFieldText = ""
                    magnetOffer = nil
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, WindowMetrics.controlInset)
            .padding(.vertical, RowHeight.rowPaddingV)
            .background(Palette.rowAlternate, in: RoundedRectangle(cornerRadius: Radius.r10))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.r10)
                    .strokeBorder(Palette.separator, lineWidth: 1))
            .padding(.horizontal, WindowMetrics.contentInset)
            .padding(.top, Spacing.s10)
        }
    }

    @ViewBuilder
    private var progressReadout: some View {
        if let progress = model.searchProgress {
            HStack(spacing: Spacing.s8) {
                if !model.searchResults.isEmpty {
                    Text("\(model.searchResults.count)")
                        .font(FetchFont.calloutMono)
                        .foregroundStyle(Palette.textSecondary)
                }
                Text("\(progress.completed) of \(progress.total) indexers")
                    .font(FetchFont.calloutMono)
                    .foregroundStyle(Palette.textTertiary)
                ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))
                    .progressViewStyle(.linear)
                    .frame(width: 60)
                Button {
                    model.cancelSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: IconSize.md))
                        .foregroundStyle(Palette.textTertiary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help("Stop waiting for the rest. Results already in stay.")
                .accessibilityLabel("Stop searching")
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "\(progress.completed) of \(progress.total) indexers answered, "
                + "\(model.searchResults.count) results so far")
        } else if !model.searchResults.isEmpty, model.searchScreenState == .results {
            Text("\(model.searchResults.count) results")
                .font(FetchFont.calloutMono)
                .foregroundStyle(Palette.textSecondary)
        }
    }

    private var structuredExtraction: SeasonEpisodeQueryParser.Extraction? {
        guard !structuredTokenDismissed else { return nil }
        let extraction = SeasonEpisodeQueryParser.extract(from: model.searchFieldText)
        guard extraction.season != nil, extraction.episode != nil else { return nil }
        return extraction
    }

    private func structuredQueryToken(_ extraction: SeasonEpisodeQueryParser.Extraction) -> some View {
        HStack(spacing: Spacing.s4) {
            chip(extraction.title)
            if let season = extraction.season, let episode = extraction.episode {
                chip(String(format: "S%02dE%02d", season, episode))
            }
            Button {
                structuredTokenDismissed = true
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Palette.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Drop structured search, use free text")
        }
    }

    private var categoryBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Spacing.s6) {
                ForEach(SearchCategory.offered(safeSearch: model.safeSearch)) { category in
                    CategoryPillView(
                        category: category,
                        isSelected: model.searchCategory == category
                    ) {
                        Task { await model.selectCategory(category) }
                    }
                }
            }
            .padding(.vertical, Spacing.s2)
        }
        .scrollIndicators(.never)
        .onScrollGeometryChange(for: CGPoint.self) { geometry in
            CGPoint(
                x: geometry.contentOffset.x,
                y: geometry.contentSize.width
                    - geometry.contentOffset.x
                    - geometry.containerSize.width)
        } action: { _, offsets in
            pillsHidden = offsets
        }
        .animation(.easeOut(duration: 0.15), value: pillsFadesLeading)
        .animation(.easeOut(duration: 0.15), value: pillsFadesTrailing)
    }

    private static let pillFadeWidth: CGFloat = 16

    private var pillsFadesLeading: Bool { pillsHidden.x > 1 }
    private var pillsFadesTrailing: Bool { pillsHidden.y > 1 }

    private var categoryBarMask: some View {
        HStack(spacing: 0) {
            if pillsFadesLeading {
                LinearGradient(
                    colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                    .frame(width: Self.pillFadeWidth)
            }
            Color.black
            if pillsFadesTrailing {
                LinearGradient(
                    colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: Self.pillFadeWidth)
            }
        }
    }

    private func chip(_ text: String) -> some View {
        Pill(style: .filled) {
            Text(text)
                .font(FetchFont.caption2)
        }
    }


    private var content: some View {
        contentBody
        .overlay(alignment: .topTrailing) {
            if model.showsFilters {
                ZStack(alignment: .topTrailing) {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { model.showsFilters = false }
                        .accessibilityHidden(true)

                    filtersContent
                        .frame(width: 280)
                        .frame(maxHeight: 460)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.r12))
                        .overlay(
                            RoundedRectangle(cornerRadius: Radius.r12)
                                .strokeBorder(Palette.separator, lineWidth: 1))
                        .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
                        .padding(.horizontal,Spacing.s12)
                        .padding(.vertical,Spacing.s20)
                        .transition(.scale(scale: 0.96, anchor: .topTrailing)
                            .combined(with: .opacity))
                }
            }
        }
    }

    @ViewBuilder
    private var contentBody: some View {
        switch model.searchScreenState {
        case .noQuery:
            EmptyStateView(
                symbol: "magnifyingglass",
                title: "Search for something",
                message: "Results from every enabled indexer appear here."
            )
        case .searching:
            EmptyStateView(progress: true, message: "Searching…")
        case .noResults:
            EmptyStateView(
                symbol: "questionmark.folder",
                title: "No results",
                message: "Try a different query."
            )
        case .noProviders:
            EmptyStateView(
                symbol: "gearshape",
                title: "No indexers configured",
                message: "Add a Torznab endpoint in Settings to start searching.",
                actionTitle: "Open Settings",
                action: { model.navigate(to: .search) }
            )
        case .noProvidersForArea:
            EmptyStateView(
                symbol: "line.3.horizontal.decrease.circle",
                title: "No indexers for \(model.searchCategory.title)",
                message: "Every configured indexer is reserved for other areas. "
                    + "Change that in Settings, or search a different category.",
                actionTitle: "Open Settings",
                action: { model.navigate(to: .search) }
            )
        case .allFailed:
            EmptyStateView(
                symbol: "exclamationmark.triangle",
                title: "All indexers failed",
                message: model.searchFailureDetail
                    ?? "Every configured indexer failed to respond.",
                actionTitle: "Retry",
                action: runSearch
            )
        case .results:
            ResultsListView(onActivate: { activate($0) })
        }
    }

    @ViewBuilder
    private var filtersContent: some View {
        if model.searchScreenState == .results {
            FacetSidebarView()
        } else {
            EmptyStateView(
                symbol: "line.3.horizontal.decrease.circle",
                title: "Nothing to filter yet",
                message: "Run a search and the facets for its results appear here.",
                size: .inline)
        }
    }


    private func indexerLabel(for result: SearchResult) -> String {
        IndexerLabel.text(for: result.sources, naming: model.indexerName)
    }


    private func runSearch() {
        if let offer = magnetOffer {
            pickerResult = .pastedMagnet(offer.magnet, source: AppModel.droppedSource)
            model.searchFieldText = ""
            magnetOffer = nil
            return
        }
        Task { await model.runSearch(model.searchFieldText) }
    }

    private func activate(_ result: SearchResult) {
        if ResultPresentation.of(result) == .directDownload {
            Task { await model.enqueueBestCandidate(result) }
        } else {
            pickerResult = result
        }
    }
}

