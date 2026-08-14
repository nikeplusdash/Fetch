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
    /// The magnet currently in the field, if that is what it is holding.
    @State private var magnetOffer: MagnetOffer?
    @State private var structuredTokenDismissed = false
    /// Measured widths of the category row's content and of the space it has.
    /// How much of the category row is off each edge at the current scroll
    /// position — `x` behind the leading edge, `y` past the trailing one.
    /// Drives the fades; see `categoryBarMask`.
    @State private var pillsHidden: CGPoint = .zero
    /// Said once per session. See the `onChange` that raises it.
    @State private var readinessBannerDismissed = false
    /// The pop-up outside the window. Nil in previews, where there is no
    /// window to hang one from.
    @Environment(\.errorPresenter) private var errorPresenter

    /// Long enough to type a word without being interrupted, short enough that
    /// stopping feels like submitting. Tuned by feel; there is no measurement
    /// to appeal to here.
    private static let typingDelay = Duration.milliseconds(450)

    private struct MagnetSheetItem: Identifiable {
        let id = UUID()
        let text: String
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            magnetOfferRow
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
        // **Both banners leave the window.** They were floating cards at the
        // foot of the content, which still covered the results nearest the
        // controls, and two of them stacked covered twice as many. They are
        // one-sentence pop-ups outside the window's frame now, so the layout
        // never learns a search went partly wrong. See `ErrorPanel`.
        //
        // Cleared as they are handed over: an alert is an event, and leaving
        // the model's copy set would mean the next render raising it again.
        .onChange(of: model.searchBanner) { _, banner in
            guard let banner else { return }
            errorPresenter?.present(AppAlert(message: banner))
            model.dismissSearchBanner()
        }
        // **Editing the query is submitting it, once you stop.** Return still
        // works and still supersedes; this is for the case the field could not
        // handle at all — changing your mind about a word and having the
        // results keep answering the old question until you remembered to press
        // it again.
        //
        // `.task(id:)` rather than a `Task` held in `@State`: SwiftUI cancels
        // and restarts it as the text changes, which is exactly the debounce,
        // and nothing writes view state on every keystroke to get it.
        //
        // 450ms, tuned by feel. Each search is a fan-out to every indexer that
        // is cancelled the moment the next one starts, so firing per character
        // would spend a request a letter to show results for a prefix nobody
        // meant to search for.
        .task(id: model.searchFieldText) {
            let trimmed = model.searchFieldText
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Empty is handled immediately above; a query identical to the one
            // already on screen has nothing to re-ask.
            guard !trimmed.isEmpty, trimmed != model.lastSearchQuery else { return }
            // A magnet or a URL is not a query, and both have their own route.
            guard PastedLink.magnetOffer(from: trimmed) == nil else { return }
            let lowered = trimmed.lowercased()
            guard !lowered.hasPrefix("http://"), !lowered.hasPrefix("https://") else { return }

            guard (try? await Task.sleep(for: Self.typingDelay)) != nil else { return }
            await model.runSearch(trimmed)
        }
        .onChange(of: model.cacheReadiness.searchBannerText, initial: true) { _, message in
            // Once per session, not once per search: the answer does not
            // change until the user changes their providers, and a pop-up on
            // every Return would be a metronome.
            guard let message, !readinessBannerDismissed else { return }
            readinessBannerDismissed = true
            // Title and action come from the readiness itself, so a state
            // nobody can act on does not get a button that leads to a pane
            // where the problem is not.
            let title = model.cacheReadiness.searchBannerActionTitle
            errorPresenter?.present(AppAlert(
                message: message,
                actionTitle: title,
                action: title == nil ? nil : { model.navigate(to: .debrid) }))
        }
        // Escape closes the panel wherever focus happens to be — the results
        // list, the field, or the panel itself.
        // **Greedy, because nothing above it is any more.** A
        // `NavigationSplitView` detail column stretched whatever it was given;
        // an `HStack` column does not, so this sized to its own ideal width —
        // roughly 410 points of an 850-point pane — and sat in a corner of it
        // with the search field a third of the width of the window.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onExitCommand {
            guard model.showsFilters else { return }
            model.showsFilters = false
        }
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
            // A circle rather than a capsule: with the word gone, a
            // capsule around one glyph is a pill that lost its label, and it
            // read as a category that had somehow emptied itself.
            // **The circle is the shape and the glyph rides on it**, rather
            // than the glyph being the view with a circle painted behind. A
            // symbol sizes to its own bearings, which are not symmetric — the
            // three lines sat low and left of the centre of a frame fitted
            // around them. Laid over a circle it is centred by construction.
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

    // MARK: - Search bar

    private var searchBar: some View {
        @Bindable var model = model
        // **Two bands, ruled apart.** The field and the pills used to share
        // one padded block, so the field read as the first of several controls
        // rather than as the thing the screen is for. A field alone above a
        // full-width rule, and everything that narrows its results below,
        // says which is which before anything is read.
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
            // **Fixed, not padded.** While a search runs the field also holds
            // the indexer count and a progress bar, and the bar is taller than
            // a line of text — so a field sized by its padding grew the moment
            // you pressed Return and shrank again when the last one answered.
            .frame(height: RowHeight.searchField)
            // Thin, over the window's material rather than instead of it —
            // a field needs to read as inset, which a slightly denser frost
            // does without becoming a solid box. The hairline is what makes it
            // a *field* rather than a tinted patch: on a frosted window a fill
            // alone has no edge of its own to be seen against.
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Radius.r10))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.r10)
                    .strokeBorder(Palette.separator, lineWidth: 1))
            .padding(.horizontal, WindowMetrics.contentInset)
            // Outside the background and the border, so the frost and the
            // hairline keep the field's own bounds and the gap below the title
            // bar is margin rather than a taller field.
            .padding(.top, Spacing.s2)
            // .padding(.bottom, Spacing.s)

            // Full width, outside the horizontal padding — a rule that stops
            // short of the edges reads as an underline for the field rather
            // than as the seam between two bands.
            // Divider()

            VStack(alignment: .leading, spacing: Spacing.s6) {
                if let extraction = structuredExtraction {
                    structuredQueryToken(extraction)
                }
                HStack(spacing: Spacing.s12) {
                    categoryBar
                        // **The row fades out rather than being sliced, but
                        // only when there is something to fade.** The
                        // categories scroll and Filters does not, so on a
                        // narrow window the last pill met the Filters pill and
                        // was cut through the middle of a word. A few points
                        // of fade at the trailing edge says the row continues.
                        //
                        // It used to fade unconditionally, over the last 6% of
                        // the row's width. With every pill fitting there is
                        // nothing beyond the edge to hint at, so the fade was
                        // washing out the last pill — Adult, on a wide window
                        // — for no reason, and the wider the window the more
                        // of it went. `pillsOverflow` is measured, so the hint
                        // appears exactly when it means something.
                        .mask(categoryBarMask)
                    filtersToggle
                }
            }
            .padding(.horizontal, WindowMetrics.contentInset)
            .padding(.top, Spacing.s10)
            // Tighter below than above: the headings sit directly under this
            // now that they no longer scroll, and the pills and the column
            // they narrow read as one block rather than two.
            .padding(.bottom, Spacing.s6)
        }
        .onChange(of: model.searchFieldText) { _, newValue in
            structuredTokenDismissed = false
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)

            // **A magnet stays in the field and offers itself.** It used to be
            // snatched out of the field the instant it was recognised, into a
            // sheet the user had not asked for, with the field left empty
            // behind it — so a mis-paste was a modal to dismiss and there was
            // no way to check the hash before committing an account slot to
            // it. Now the field says what it is holding and offers the one
            // thing there is to do with it. No indexer is asked either way: a
            // magnet is not a query and searching for one returns nothing.
            if let offer = PastedLink.magnetOffer(from: trimmed) {
                guard offer.id != magnetOffer?.id else { return }
                magnetOffer = offer
                // Started on the paste, so the pill in the sheet is usually
                // resolved by the time the sheet appears. This is the
                // difference between this and typing the same hash into Add
                // Link.
                model.beginAvailabilityCheck(
                    for: .pastedMagnet(offer.magnet, source: AppModel.droppedSource))
                return
            }
            magnetOffer = nil

            // A web address is still handed straight to the add-link sheet:
            // whether a debrid covers the host is a question only that sheet
            // can answer, and searching *for* a URL is never what anyone meant.
            let lowered = trimmed.lowercased()
            if lowered.hasPrefix("https://") || lowered.hasPrefix("http://") {
                magnetSheetItem = MagnetSheetItem(text: trimmed)
                return
            }

            // An emptied field is not a search, and it clears at once: waiting
            // half a second to remove results the user has just deleted the
            // query for is the one place the delay reads as lag. Everything
            // else is debounced by the `.task(id:)` below.
            guard trimmed.isEmpty else { return }
            Task { await model.runSearch("") }
            model.searchFieldText = ""
        }
    }

    /// The one row a pasted magnet produces, under the field and above
    /// whatever the results list was showing.
    ///
    /// The magnet's own display name and a shortened infohash, so a wrong paste
    /// is visible before it costs anything, and `Open` rather than `Download`
    /// because it opens the same sheet everything else opens. There is one path
    /// into a download and this is not a second one.
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
                // **A way out of a search that will not end.** The fan-out
                // finishes when the last indexer does, so one unreachable
                // server held the screen with everyone else's results already
                // on it. Stopping keeps them.
                Button {
                    model.cancelSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: IconSize.md))
                        .foregroundStyle(Palette.textTertiary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // **It appears while you are typing, so it must not be
                // focusable.** This button arrives the moment a search starts,
                // which is mid-sentence — and a focusable control appearing
                // inside the field's own row moves first responder, and an
                // `NSTextField` that becomes first responder selects all of its
                // text. The next keystroke then replaces the query instead of
                // extending it, which is what "I cannot type any more" was.
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
                // Adult only when safe search is off — see `offered(safeSearch:)`.
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
        // Reads the scroll itself rather than two measured widths: the question
        // is what is past the edge *now*, and only the scroll geometry knows.
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

    /// How much of the trailing edge fades when the row runs past it.
    private static let pillFadeWidth: CGFloat = 16

    /// Opaque when everything fits, and a short fade at the trailing edge when
    /// it does not.
    ///
    /// The slack is the fade's own width rather than a pixel. Below that there
    /// is nothing behind the edge worth hinting at, and the hint would cost
    /// more of the last pill than the overflow is hiding — which is exactly
    /// what a row overflowing by a couple of points looked like.
    /// **Not "is the row wider than the window" — "is there anything past this
    /// edge right now".** Measuring the two widths fades whenever the row
    /// overflows at all, including once it has been scrolled to its end: Adult
    /// is the last pill, so scrolling over to reach it put it under the
    /// gradient and washed out the one thing that scroll was for. The scroll
    /// geometry knows what is actually past each edge; two widths cannot.
    private var pillsFadesLeading: Bool { pillsHidden.x > 1 }
    private var pillsFadesTrailing: Bool { pillsHidden.y > 1 }

    /// **A fixed band, not a percentage.** The fade was the last 6% of the
    /// row's *width*, so the wider the window the more of the row it ate: at
    /// 700 points that is 42, which is most of a pill. A hint that the row
    /// continues needs to be the same few points whatever the window is doing.
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
        Text(text)
            .font(FetchFont.caption2)
            .padding(.horizontal, Spacing.s8)
            .padding(.vertical, Spacing.s2)
            .background(.thinMaterial)
            .clipShape(Capsule())
    }

    // MARK: - Content states

    /// The screen below the search band, with the filters panel hanging off
    /// its top-right corner.
    ///
    /// **Off this, not off the whole screen.** As an overlay on the outer
    /// stack the panel covered the top-right of the view — which is where the
    /// Filters pill now lives, so opening the panel hid the only control that
    /// closes it, and clipped the end of the category row while it was there.
    /// Anchored here it drops out of the pill rather than over it.
    private var content: some View {
        contentBody
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
                // **An explicit `ZStack`, and that is not a detail.** Two views
                // in an overlay's builder are a group whose *own* alignment is
                // centre; the modifier's `.topTrailing` then places that group,
                // and the panel centres itself inside it. Adding the catcher
                // below is what silently moved the panel to the middle of the
                // screen, and stating the stack's alignment is what pins it
                // back under the button that opens it.
                ZStack(alignment: .topTrailing) {
                    // **A catcher behind the panel, not a modal.** The panel is
                    // a layer inside the window rather than a `.popover` — a
                    // popover is its own OS window, and on a frosted one it
                    // samples the wallpaper instead of the app behind it — so
                    // the dismissals a popover gives away have to be spelled
                    // out. This transparent sheet is what makes a click
                    // anywhere else close it; it sits under the panel, so
                    // clicks on the panel itself still land.
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { model.showsFilters = false }
                        .accessibilityHidden(true)

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
            // The quality-profile notice used to sit here as a permanent bar
            // under every result list. It is a filter, so it lives with the
            // filters — see `FacetSidebarView`.
            ResultsListView(onActivate: { activate($0) })
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

    // MARK: - Results table

    private func indexerLabel(for result: SearchResult) -> String {
        IndexerLabel.text(for: result.sources, naming: model.indexerName)
    }

    // MARK: - Actions

    private func runSearch() {
        // Return on a magnet opens it rather than asking every indexer for a
        // hash none of them index. `onSubmit` fires whatever the offer row's
        // default-action button does, so the guard has to be here too.
        if let offer = magnetOffer {
            pickerResult = .pastedMagnet(offer.magnet, source: AppModel.droppedSource)
            model.searchFieldText = ""
            magnetOffer = nil
            return
        }
        // **No guard on `.searching`.** Pressing Return while a search ran did
        // nothing at all, which is the opposite of what a second Return means:
        // `runSearch` already cancels the one in flight, so the new query
        // supersedes it rather than queueing behind it.
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

