import SwiftUI
import FetchKit

/// The Search screen (design spec §12.1) — search field, facet sidebar,
/// results grouped by content, and the states from the M2 brief: no query, no
/// results, no providers configured, and all-providers-failed.
///
/// Grouping, faceting, and sort all recompute from results already in memory,
/// so none of the three re-runs the search.
struct SearchView: View {
    @Environment(AppModel.self) private var model

    @State private var pickerResult: SearchResult?
    @State private var magnetSheetItem: MagnetSheetItem?
    @State private var structuredTokenDismissed = false
    @State private var readinessBannerDismissed = false

    private struct MagnetSheetItem: Identifiable {
        let id = UUID()
        let text: String
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            // Shown above the indexer-failure banner: a missing debrid key
            // is the more fundamental problem of the two, and it used to be
            // reported nowhere at all.
            // The filters panel used to be an `.inspector`, which is a column:
            // it took a permanent bite out of the results list's width, on a
            // screen whose horizontal budget was already the tightest in the
            // app, and it animated in by shoving everything sideways. It is a
            // popover over the window now — it costs the layout nothing, it
            // appears anchored to the control that opened it, and closing it
            // is a click anywhere.
            content
        }
        // Floating, for the reason the app-level one is: a banner that takes
        // a row of the layout moves the search field and every result under
        // it, and two of them stacked moved the whole screen twice.
        .overlay(alignment: .bottom) {
            VStack(spacing: Spacing.s6) {
                if let banner = model.searchBanner {
                    InlineBannerView(
                        message: banner,
                        onDismiss: { model.dismissSearchBanner() })
                }
                if !readinessBannerDismissed,
                   let message = model.cacheReadiness.searchBannerText {
                    InlineBannerView(
                        message: message,
                        onRetry: { model.navigate(to: .debrid) },
                        retryTitle: "Open Settings…",
                        onDismiss: { readinessBannerDismissed = true })
                }
            }
            .padding(Spacing.s12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
        .animation(.snappy(duration: 0.25), value: model.searchBanner)
        .navigationTitle("Search")
        .sheet(item: $pickerResult) { result in
            // Chosen by what the result *is*. This used to test
            // `infoHashHex == nil`, which every Gutenberg result and every
            // future hoster result also satisfies — so a book opened the
            // Internet Archive picker and failed on a missing identifier.
            switch ResultPresentation.of(result) {
            case .torrentPicker:
                FilePickerSheet(result: result, indexerLabel: indexerLabel(for: result))
            case .archiveItem:
                ArchiveItemSheet(result: result)
            case .bookFormats:
                BookItemSheet(result: result)
            case .directDownload:
                // Unreachable in normal flow — `onActivate` queues these
                // without presenting a sheet. Rendering the reason beats
                // rendering an empty sheet if that ever stops being true.
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
        // Present in every state, not just `.results` — the filters panel it
        // toggles can be open regardless of what screen state produced that,
        // so the only control that closes it has to be reachable from all of
        // them. Previously lived inside `resultsToolbar`, reachable only from
        // `.results`; a user who opened Filters and then landed anywhere else
        // (including `.noProviders`, unreachable from `.results` at all on a
        // first run) had no way to close it.
        .toolbar {
            ToolbarItem {
                filtersToggle
            }
        }
        // **A layer over the window, not a popover.** A popover is its own
        // OS window: it escapes the frame, casts its own shadow onto the
        // desktop, and on a frosted window it samples the *wallpaper* rather
        // than the app behind it — which is why it appeared to be floating
        // outside the app entirely.
        //
        // An overlay is inside the window, clipped by it, and frosts against
        // the content it covers. This is what "a layer that pops up on top of
        // the window" meant, and the inspector column and the popover were
        // both the wrong reading of it.
        .overlay(alignment: .topTrailing) {
            if model.showsFilters {
                filtersContent
                    // Bounded rather than intrinsic: the facet list grows with
                    // the result set, and a panel sized to its content would
                    // run off the bottom of a broad search.
                    .frame(width: 280)
                    .frame(maxHeight: 460)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.r12))
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.r12)
                            .strokeBorder(Palette.separator, lineWidth: 1))
                    .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
                    .padding(Spacing.s12)
                    .transition(.scale(scale: 0.96, anchor: .topTrailing)
                        .combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.22), value: model.showsFilters)
    }

    /// The Filters control, and the panel it opens.
    ///
    /// **A popover, not an inspector column.** The column version spent 200–320
    /// points of the results list permanently and animated in by pushing the
    /// whole screen sideways — on the one screen whose horizontal budget was
    /// already the tightest in the app. A popover is anchored to this button,
    /// floats over the window, costs the layout nothing, and dismisses on a
    /// click outside.
    ///
    /// **The chrome is the toolbar's, not ours.** This used to hand-set a
    /// symbol size, a 22×22 frame and a `foregroundStyle`, which is three
    /// guesses at what the toolbar was going to do anyway — the padding came
    /// out unlike every neighbouring control. `Label` in a plain toolbar
    /// `Button` gets the standard metrics; the open state is carried by the
    /// filled symbol variant and the accent tint rather than by geometry.
    private var filtersToggle: some View {
        @Bindable var model = model
        return Button {
            model.showsFilters.toggle()
        } label: {
            Label("Filters", systemImage: "line.3.horizontal.decrease.circle")
                .symbolVariant(model.showsFilters ? .fill : .none)
        }
        .labelStyle(.iconOnly)
        .foregroundStyle(model.showsFilters ? Palette.accent : Palette.textPrimary)
        .help(model.showsFilters ? "Hide filters" : "Show filters")

    }

    // MARK: - Search bar

    private var searchBar: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: Spacing.s6) {
            HStack(spacing: Spacing.s8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Palette.textSecondary)
                TextField("Search…", text: $model.searchFieldText)
                    .textFieldStyle(.plain)
                    .onSubmit(runSearch)

                progressReadout
            }
            .padding(.horizontal, Spacing.s8)
            .padding(.vertical, Spacing.s6)
            // Thin, over the window's material rather than instead of it —
            // a field needs to read as inset, which a slightly denser frost
            // does without becoming a solid box.
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Radius.r8))

            if let extraction = structuredExtraction {
                structuredQueryToken(extraction)
            }

            categoryBar
        }
        .padding(Spacing.s12)
        .onChange(of: model.searchFieldText) { _, newValue in
            structuredTokenDismissed = false
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            // Link detection: pasting a magnet or a web address skips search
            // entirely and opens the add-flow directly. Searching *for* a URL
            // is never what anyone meant.
            //
            // The host check happens in the sheet, not here, so an unsupported
            // host lands somewhere that explains itself rather than silently
            // falling through to a search that returns nothing.
            let lowered = trimmed.lowercased()
            guard lowered.hasPrefix("magnet:")
                || lowered.hasPrefix("https://")
                || lowered.hasPrefix("http://")
            else { return }
            magnetSheetItem = MagnetSheetItem(text: trimmed)
            model.searchFieldText = ""
        }
    }

    /// Results stream in per indexer, so the readout says how many have
    /// reported rather than showing an indeterminate spinner that conveys only
    /// "something is happening". A determinate bar is possible here precisely
    /// because the total is known up front.
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

    /// The season/episode "structured query" feedback token (§12.1): when
    /// the query text parses as `S03E05`-shaped, show a removable chip so
    /// the user can see a structured search is being issued. Reuses
    /// `SeasonEpisodeQueryParser` directly — the same extraction
    /// `TorznabProvider.search` performs — so the chip can never disagree
    /// with what is actually sent.
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

    /// Figma's `CategoryPill` bar. It scopes the query — changing it re-runs
    /// the search — which is the difference between this and a filter, and why
    /// the progress readout comes back when it is touched.
    private var categoryBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Spacing.s6) {
                ForEach(SearchCategory.allCases) { category in
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
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(FetchFont.caption2)
            .padding(.horizontal, Spacing.s8)
            .padding(.vertical, Spacing.s2)
            .background(.thinMaterial)
            .clipShape(Capsule())
    }

    // MARK: - Content states

    @ViewBuilder
    private var content: some View {
        switch model.searchScreenState {
        case .noQuery:
            EmptyStateView(
                symbol: "magnifyingglass",
                title: "Search for something",
                message: "Results from every enabled indexer appear here."
            )
        case .searching:
            VStack(spacing: Spacing.s8) {
                ProgressView()
                Text("Searching…")
                    .font(FetchFont.callout)
                    .foregroundStyle(Palette.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            VStack(spacing: 0) {
                resultsToolbar
                Divider()
                ResultsListView(onActivate: { activate($0) })
                if !model.filteredOutResults.isEmpty {
                    Divider()
                    filteredNotice
                }
            }
        }
    }

    /// What the panel shows, decoupled from whether it is *open* — the toggle
    /// is reachable from every screen state, so it can be opened over one with
    /// nothing to facet.
    ///
    /// It says so, rather than rendering nothing. As an inspector column an
    /// empty panel was merely a blank stripe; a popover the user just clicked
    /// open has to account for itself, or the control reads as broken.
    @ViewBuilder
    private var filtersContent: some View {
        if model.searchScreenState == .results {
            FacetSidebarView()
        } else {
            VStack(spacing: Spacing.s8) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: IconSize.xl))
                    .foregroundStyle(Palette.textTertiary)
                Text("Nothing to filter yet")
                    .font(FetchFont.body)
                Text("Run a search and the facets for its results appear here.")
                    .font(FetchFont.footnote)
                    .foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(Spacing.s24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Grouped/Items, count. Filters has moved to the window toolbar (present
    /// in every state, see `filtersToggle`); sort has moved into the filters
    /// panel, which is what freed the 300pt this bar was spending on it.
    private var resultsToolbar: some View {
        @Bindable var model = model
        return HStack(alignment: .center, spacing: Spacing.s12) {
            Picker("Group by title", selection: $model.isGrouped) {
                Text("Grouped").tag(true)
                Text("Items").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Spacer()

            Text(countLabel)
                .font(FetchFont.calloutMono)
                .foregroundStyle(Palette.textSecondary)
        }
        .padding(.horizontal, Spacing.s12)
        .frame(height: 32)
    }

    private var countLabel: String {
        let visible = model.visibleResults.count
        return model.isGrouped
            ? "\(model.contentGroups.count) titles · \(visible) releases"
            : "\(visible) releases"
    }

    /// §12.1: releases the quality profile rejected are hidden behind an
    /// affordance rather than silently dropped, so a profile that is too
    /// strict is discoverable rather than mystifying.
    private var filteredNotice: some View {
        @Bindable var model = model
        return HStack(spacing: Spacing.s8) {
            Image(systemName: "line.3.horizontal.decrease")
                .foregroundStyle(Palette.textTertiary)
            Text("\(model.filteredOutResults.count) releases hidden by your quality profile")
                .font(FetchFont.footnote)
                .foregroundStyle(Palette.textSecondary)
            Spacer()
            Toggle("Show", isOn: $model.showsFilteredResults)
                .toggleStyle(.checkbox)
                .font(FetchFont.footnote)
        }
        .padding(.horizontal, Spacing.s12)
        .padding(.vertical, Spacing.s6)
        .background(Palette.rowAlternate)
    }

    // MARK: - Results table

    private func indexerLabel(for result: SearchResult) -> String {
        IndexerLabel.text(for: result.sources, naming: model.indexerName)
    }

    // MARK: - Actions

    private func runSearch() {
        guard model.searchScreenState != .searching else { return }
        Task { await model.runSearch(model.searchFieldText) }
    }

    /// A `.directDownload` result has nothing to choose, so presenting a
    /// sheet to choose it would be a dialog with one button.
    private func activate(_ result: SearchResult) {
        if ResultPresentation.of(result) == .directDownload {
            Task { await model.enqueueBestCandidate(result) }
        } else {
            pickerResult = result
        }
    }
}
