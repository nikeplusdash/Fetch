import AppKit
import Foundation
import Observation
import FetchKit

// `DownloadItem` and `SearchScreenState` moved to FetchKit, where their
// arithmetic and their state ladder can be tested. They are re-exported by
// `import FetchKit`, so no call site changed.

/// Errors surfaced by `AppModel` itself, as opposed to ones forwarded from
/// FetchKit (`DownloadError`, `DebridError`, ...).
enum AppModelError: LocalizedError, Sendable {
    case notConfigured
    /// Thrown by `saveDebridKey` when the current engine still has
    /// non-terminal rows — see the doc comment on
    /// `AppModel.hasActiveDownloads`.
    case activeDownloadsPreventReconfigure
    /// Removing a provider whose downloads are still running.
    case providerHasActiveDownloads(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Add a TorBox API key in Settings before adding downloads."
        case .providerHasActiveDownloads(let name):
            "\(name) still has downloads in progress. Pause or cancel them "
            + "before removing it, or its rows would be left with no engine "
            + "to control them."
        case .activeDownloadsPreventReconfigure:
            "Pause or cancel all downloads before changing your API key. "
            + "Saving a new key replaces the download engine, which would "
            + "leave existing rows uncontrollable."
        }
    }
}

@MainActor
@Observable
final class AppModel {
    private(set) var items: [DownloadItem] = []
    /// Surfaced by the window's banner. Was written in five places and
    /// displayed in none, so every download failure recorded a message nothing
    /// ever showed — the same silence that hid five separate bugs this session.
    var errorMessage: String?

    /// Records something the user needs to know about. Never for conditions
    /// they can neither see nor act on.
    private func report(_ message: String) {
        errorMessage = message
    }

    /// Which screen the window shows. Held here rather than in `FetchApp` so a
    /// banner deep in the Search screen can navigate without threading a
    /// binding through every view between them.
    var sidebarSection: SidebarSection = .search
    /// Appearance, which is the first pane in the row — a Settings screen that
    /// opens on its second tab reads as one you left mid-task. Debrid was the
    /// default because it is the pane a new install has to visit; but that is an
    /// argument for sending someone there once, which `navigate(to:)` already
    /// does, not for landing there every time.
    var settingsTab: SettingsTab = .appearance

    // MARK: - The UI pass, declared once
    //
    // Three plans are built in parallel worktrees, and each needs state on this
    // object. Swift will not let a stored property live in an extension, so
    // three branches adding their own would each edit this 2,800-line file at
    // roughly the same place — three conflicts, in the worst file to resolve
    // them in. They are declared here instead, in the foundation commit, unused
    // until the plan that owns each one arrives. The *behaviour* goes in
    // `AppModel+Library`, `+Destination` and `+Appearance`, which are three new
    // files that cannot collide.

    /// Plan 1. Which filter the Downloads list is narrowed to.
    ///
    /// View state that outlives the view: switching to Settings and back should
    /// not silently widen a list the user had narrowed.
    var downloadFilter: DownloadFilter = .downloads
    /// Plan 1. Which kind the Library is narrowed to, or nil for all of them.
    var libraryKind: MediaKind?

    /// Plan 2. Where a single download should land, overriding the rules, keyed
    /// by the group it belongs to. Not persisted: an override is a thing you do
    /// once, and the rules in Settings are what persist.
    var destinationOverrides: [String: URL] = [:]
    /// How long an indexer may take before the request is given up on.
    ///
    /// A self-hosted Jackett asking a dozen trackers can take far longer than a
    /// hosted Prowlarr, and a timeout looks exactly like an indexer being down
    /// — so how long to wait is the user's call rather than a constant.
    var indexerTimeout: TimeInterval = HTTPClient.defaultIndexerTimeout {
        didSet {
            UserDefaults.standard.set(indexerTimeout, forKey: Self.indexerTimeoutKey)
            // Nothing to rebuild: `configuredSearchProviders()` constructs a
            // client per search, so the next one picks this up. A
            // `URLSession`'s timeout is fixed at construction, so a cached
            // client would have kept the old value and the setting would have
            // appeared to do nothing until relaunch.
        }
    }
    private static let indexerTimeoutKey = "app.fetch.indexerTimeout"

    /// Whether each configured service answered when asked to validate.
    ///
    /// Not `hostCoverage`, which the dot and the rail used to read: that is the
    /// list of file hosts a service can unrestrict, so a revoked key could
    /// still show green off a list fetched before it was revoked, and a healthy
    /// service with no web downloads reported an empty list and looked no
    /// different from one that had failed.
    var serviceHealth: [DebridProviderID: ServiceHealth] = [:]

    /// Plan 3. Which of Glass, Blizzard and Midnight the window is made of.
    ///
    /// **Blizzard, not Glass.** Glass is what the app looked like before it had
    /// themes, which made it the obvious default and the wrong one: it is a
    /// lens, so its contrast depends on the wallpaper behind it, and the first
    /// thing anyone sees should not be the one surface whose legibility this
    /// app does not control.
    var appearanceTheme: AppearanceTheme = .blizzard

    /// Deep-links to a Settings pane. "Add a Torznab endpoint in Settings"
    /// should land on Search, not on whichever tab happened to be open.
    func navigate(to tab: SettingsTab) {
        settingsTab = tab
        sidebarSection = .settings
    }

    /// What closing the window does. `.ask` until the user says.
    ///
    /// A download manager is the archetypal app whose window closing is not
    /// the app finishing — but deciding that for the user is its own trap, so
    /// it is asked once and remembered.
    var windowCloseBehaviour: WindowCloseBehaviour = .ask {
        didSet {
            UserDefaults.standard.set(
                windowCloseBehaviour.rawValue, forKey: Self.closeBehaviourKey)
        }
    }

    /// What the menu bar shows: how much of everything running is done.
    var activeProgress: ActiveProgress? {
        ActiveProgress.of(items.map {
            (state: $0.state, downloaded: $0.bytesDownloaded, total: $0.totalBytes)
        })
    }

    /// Where finished files land by default. A genuine stored property (not
    /// a UserDefaults-backed computed one) so `@Observable` tracks writes to
    /// it and `SettingsView`'s directory row updates immediately after the
    /// user picks a new folder.
    private(set) var downloadDirectory: URL

    private var engine: DownloadEngine?
    private let credentialStore: any CredentialStore

    /// Every enabled debrid, in preference order — the order `DebridRouter`
    /// applies when several could serve a download.
    private(set) var providers: [any DebridProvider] = []

    /// One engine per provider. A download runs on the engine belonging to the
    /// debrid it was routed to, so `pause`/`resume`/`cancel` must reach that
    /// same engine — an engine has no record of another's jobs, and calling
    /// the wrong one silently no-ops.
    /// Persists rows so a quit does not lose them. Nil only if SwiftData
    /// itself fails to open, in which case the app runs exactly as it did
    /// before — degraded, not broken.
    private let downloadStore: DownloadStore?

    /// The request behind each row, needed to persist progress and to restore
    /// after a relaunch. `DownloadEngine` owns its own copy but does not
    /// expose it.
    private var requestForDownload: [DownloadID: DownloadRequest] = [:]

    /// The whole torrent's contents by info hash, so a row can show what was
    /// skipped and not just what was taken. Populated when the file picker
    /// knew the list; absent for a magnet added without one.
    private(set) var torrentFiles: [String: [TorrentMetadata.File]] = [:]

    /// Records the full contents of a torrent the user is choosing from.
    func rememberTorrentFiles(_ files: [DebridFile], forHash hash: String) {
        guard !files.isEmpty else { return }
        invalidateGroups()
        torrentFiles[hash.lowercased()] = files.map {
            TorrentMetadata.File(path: $0.name, length: $0.size)
        }
    }

    /// Files in this torrent that were never queued.
    ///
    /// Keyed on `contentKey`, not `id`: the file list belongs to the torrent,
    /// and every attempt at it sees the same one.
    func skippedFiles(for group: TorrentGroup) -> [TorrentMetadata.File] {
        let queued = Set(group.items.compactMap { requestForDownload[$0.id]?.file.name })
        return DownloadGrouping.skippedFiles(
            allFiles: torrentFiles[group.contentKey.lowercased()] ?? [], queuedPaths: queued)
    }

    /// Where a restored row's file landed, held only until `.enqueued` builds
    /// the row and takes it — `restoreDownloads` runs before any event does.
    private var restoredFinalURLs: [DownloadID: URL] = [:]

    /// Same handover as `restoredFinalURLs`, for the reason a failed row
    /// stored: without it a relaunch turns "failed because the link expired"
    /// back into a bare "Failed".
    private var restoredErrors: [DownloadID: String] = [:]

    /// When each restored download finished, handed to the row the same way
    /// its landing path is — the live `.finished` event is otherwise the only
    /// thing that sets it, so a relaunched library would sort as if nothing
    /// had ever completed.
    private var restoredCompletionDates: [DownloadID: Date] = [:]

    /// When each restored download was *added*, handed over the same way.
    ///
    /// `DownloadItem.addedAt` defaults to now, which is right for something
    /// queued this second and wrong for all 415 rows a relaunch rebuilds:
    /// without this every one of them would claim it arrived at launch, and
    /// the list sorted newest-first would be in an arbitrary order that looked
    /// deliberate.
    private var restoredCreationDates: [DownloadID: Date] = [:]

    private var engines: [String: DownloadEngine] = [:]
    private var engineForDownload: [DownloadID: DownloadEngine] = [:]

    /// What to call the debrid behind each engine.
    ///
    /// Needed because a row can now appear from an event alone — the files a
    /// background preparation resolves to are enqueued by the engine itself,
    /// with no call site left to `remember` them afterwards. The event's own
    /// engine is the authoritative answer to "whose row is this?", and reading
    /// it off the pump beats the `?? engine` fallbacks that used to guess the
    /// primary debrid.
    private var engineNames: [ObjectIdentifier: String] = [:]
    private var pumps: [Task<Void, Never>] = []

    /// Which debrid each row is downloading through, for the UI to name.
    private(set) var providerForDownload: [DownloadID: String] = [:]

    /// Which debrids are configured, and in what preference order.
    private(set) var debridConfigs: [DebridConfig] = []

    private static let debridConfigsDefaultsKey = "app.fetch.debridConfigs"
    private static let maxConcurrentKey = "app.fetch.maxConcurrentDownloads"
    private static let segmentsKey = "app.fetch.segmentsPerFile"

    /// How many files download at once (§12.4, 1–10).
    ///
    /// Note this only matters for multi-file torrents. A single movie file is
    /// one job however high this goes — `segmentsPerFile` is the dial that
    /// speeds *that* up.
    var maxConcurrentDownloads = 3 {
        didSet {
            UserDefaults.standard.set(maxConcurrentDownloads, forKey: Self.maxConcurrentKey)
            let value = maxConcurrentDownloads
            for engine in engines.values { Task { await engine.setMaxConcurrent(value) } }
        }
    }

    /// Parallel byte ranges per file. This is what saturates a debrid link;
    /// no provider documents a limit, so the ceiling is ours (16).
    var segmentsPerFile = SegmentedTransfer.defaultSegments {
        didSet {
            UserDefaults.standard.set(segmentsPerFile, forKey: Self.segmentsKey)
            let value = segmentsPerFile
            for engine in engines.values { Task { await engine.setSegmentsPerFile(value) } }
            // The direct engine is not in `engines` — it has no provider to
            // key on — so it needs saying separately or the setting silently
            // stops applying to Archive.org downloads.
            if let direct = _directEngine {
                Task { await direct.setSegmentsPerFile(value) }
            }
        }
    }

    // MARK: - Search (M2)

    private(set) var searchResults: [SearchResult] = []
    /// Non-blocking "N of M indexers failed" banner text (§7's partial-
    /// failure sidecar) — `nil` when every enabled provider answered.
    private(set) var searchBanner: String?

    /// Why the failing indexers failed, named one per line. The counts alone
    /// ("2 of 3 indexers failed") say nothing actionable, and the single most
    /// common cause — a saved URL that points at the indexer's web UI rather
    /// than its Torznab API — is entirely fixable once it is stated.
    private(set) var searchFailureDetail: String?
    private(set) var searchScreenState: SearchScreenState = .noQuery

    /// What is in the search field right now.
    ///
    /// **Here rather than as `@State` in the view**, because the Search screen
    /// is destroyed and rebuilt every time the sidebar changes section — so a
    /// query typed, searched, and then briefly left for Settings came back to
    /// an empty field with its own results still on screen underneath. Screen
    /// state that outlives its screen belongs with `sidebarSection`, which is
    /// here for exactly the same reason.
    ///
    /// Distinct from `lastSearchQuery`: that one is the query behind the
    /// results and only changes when a search runs, which is what makes a
    /// category pill re-run the right thing. This one is whatever has been
    /// typed, submitted or not.
    var searchFieldText = ""

    /// The trimmed query behind whatever `searchResults` currently holds.
    /// Set only when a search actually starts (`runSearch`), never from a
    /// live text field — so anything that re-runs "the current search"
    /// (`selectCategory`) re-runs the query that produced what is on screen,
    /// not whatever happens to be typed at the moment.
    private(set) var lastSearchQuery = ""

    // `SearchSort` lived here as a nested enum with a private `sorted(_:)`
    // beside it — ordering logic in a target with no test bundle, for the
    // third time in this repo. Both moved to `ResultSort`/`ResultSorting` in
    // FetchKit, keeping the same raw values so a persisted choice survives.

    /// Seeders by default, at the user's request.
    ///
    /// Not the obvious default — `.bestMatch` weighs name match, per-kind
    /// quality and popularity together, and seeder count alone reliably
    /// surfaces the wrong thing, which is the whole reason that ladder was
    /// built. But it is the user's list, they asked for it, and best match is
    /// one click away in the headings.
    private(set) var searchSort: ResultSort = .seeders
    /// Which way the active column points. Its own property rather than a
    /// pair of enum cases per column, because every column can go both ways
    /// and doubling the enum to say so would be fourteen cases describing
    /// seven things.
    private(set) var sortDescending = true

    /// A click on a column header. The same column again flips it; a
    /// different one adopts that column's natural direction — nobody clicking
    /// Size wants the smallest file first, and nobody clicking Name wants Z.
    func applySort(_ sort: ResultSort) {
        if searchSort == sort {
            sortDescending.toggle()
        } else {
            searchSort = sort
            sortDescending = sort.defaultsToDescending
        }
        UserDefaults.standard.set(searchSort.rawValue, forKey: Self.sortDefaultsKey)
        UserDefaults.standard.set(sortDescending, forKey: Self.sortDirectionKey)
    }

    /// Which category the next search asks for.
    ///
    /// **Not persisted — every launch starts on All.** It used to be restored,
    /// on the reasoning that the pill someone left selected is the one they
    /// meant. Across sessions that is the wrong bet: a narrowing chosen for one
    /// search is silently still in force days later, and a search that quietly
    /// returns a fraction of its results is worse than one that asks you to
    /// narrow it again.
    var searchCategory: SearchCategory = .all

    /// The live "cached only" switch, seeded from the Settings default.
    var cachedOnly = false

    /// The persisted default for that switch (Settings § Search).
    var cachedOnlyDefault = false {
        didSet {
            UserDefaults.standard.set(cachedOnlyDefault, forKey: Self.cachedOnlyKey)
        }
    }
    private static let cachedOnlyKey = "app.fetch.cachedOnlyDefault"

    /// Whether the filters inspector is open. Closed by default — it used to
    /// open on every search, taking a column of the results list to show
    /// facets nobody had asked for.
    var showsFilters = false {
        didSet { UserDefaults.standard.set(showsFilters, forKey: Self.filtersKey) }
    }
    private static let filtersKey = "app.fetch.showsFilters"

    /// What the active `QualityProfile` refused. Shown behind a "show N
    /// filtered" affordance rather than dropped, so an over-strict profile is
    /// discoverable instead of mystifying (§12.1).
    private(set) var filteredOutResults: [SearchResult] = []
    var showsFilteredResults = false

    var facetSelection = FacetSelection()

    /// Which row is selected. A `ResultID`, so it survives the list being
    /// re-sorted or re-faceted — an index would select a different release.
    var selectedResultID: ResultID?

    /// Hide results an indexer files under Torznab's XXX categories.
    ///
    /// On by default. A debrid search fans out to whatever the user's indexers
    /// carry, and a setting someone has to find *before* their first search
    /// protects nobody. Matching is on the declared category only — see
    /// `AdultContentFilter` for why a title blocklist was rejected.
    var safeSearch = true {
        didSet {
            UserDefaults.standard.set(safeSearch, forKey: Self.safeSearchKey)
            // Turning it back on takes the Adult pill away, and leaving the
            // search scoped to a category with no pill would filter every
            // result out of a screen with nothing on it explaining why.
            if safeSearch, searchCategory == .adult {
                searchCategory = .all
                if !lastSearchQuery.isEmpty {
                    Task { await runSearch(lastSearchQuery) }
                }
            }
        }
    }
    private static let safeSearchKey = "app.fetch.safeSearch"

    /// Internet Archive is on by default: it needs no key, no account, and no
    /// debrid, so unlike every other source it has nothing to configure first.
    var searchesInternetArchive = true {
        didSet {
            UserDefaults.standard.set(searchesInternetArchive, forKey: Self.internetArchiveKey)
        }
    }
    private static let internetArchiveKey = "app.fetch.searchesInternetArchive"

    /// Archive.org generates extra formats from each upload. Off by default so
    /// a picker is not every episode twice; this is the *default* for the
    /// sheet's toggle, not a replacement for it.
    var archiveShowsDerivedByDefault = false {
        didSet {
            UserDefaults.standard.set(archiveShowsDerivedByDefault, forKey: Self.archiveDerivedKey)
        }
    }
    private static let archiveDerivedKey = "app.fetch.archiveShowsDerivedByDefault"

    /// Gutenberg is on by default for the same reason Internet Archive is: no
    /// key, no account, no debrid, nothing to configure first.
    var searchesGutenberg = true {
        didSet { UserDefaults.standard.set(searchesGutenberg, forKey: Self.gutenbergKey) }
    }
    private static let gutenbergKey = "app.fetch.searchesGutenberg"

    // Book format preference used to live here as a Gutenberg-only
    // `[BookFormat]`, applied inside the provider at parse time. 7d moved it
    // to `qualityProfile.documentFormatOrder`, where it also covers Internet
    // Archive, and where changing it reorders results already on screen.
    // `migrateBookFormatPreference` carries the saved value across once.
    private static let gutenbergFormatsKey = "app.fetch.gutenbergFormatPriority"

    /// Following the system's languages is implicit — results change based on
    /// state the user is not looking at. The Settings row states what it
    /// resolved to, and turning this off means the whole catalogue answers.
    var gutenbergFollowsSystemLanguages = true {
        didSet {
            UserDefaults.standard.set(
                gutenbergFollowsSystemLanguages, forKey: Self.gutenbergLanguagesKey)
        }
    }
    private static let gutenbergLanguagesKey = "app.fetch.gutenbergFollowsSystemLanguages"

    /// Cover art and catalogue metadata. It is a downloader; there is no harm
    /// in fetching a cover when asked. Off by default because it is not the
    /// book.
    var gutenbergIncludesSupplementary = false {
        didSet {
            UserDefaults.standard.set(
                gutenbergIncludesSupplementary, forKey: Self.gutenbergExtrasKey)
        }
    }
    private static let gutenbergExtrasKey = "app.fetch.gutenbergIncludesSupplementary"

    /// What will actually be sent as `languages`. Empty means no filter.
    var gutenbergLanguageCodes: [String] {
        gutenbergFollowsSystemLanguages ? GutenbergLanguages.systemPreferred() : []
    }

    /// Where downloads are filed, and what they are named (§9).
    var routingRules: [RoutingRule] = RoutingRule.defaults {
        didSet { persistOrganization() }
    }
    /// Off by default: renaming is confidence-gated, but a user who never
    /// asked for it should not find their filenames changed.
    var renamesFiles = false {
        didSet { persistOrganization() }
    }

    private static let routingRulesKey = "app.fetch.routingRules"
    private static let renamesFilesKey = "app.fetch.renamesFiles"

    private func persistOrganization() {
        UserDefaults.standard.set(renamesFiles, forKey: Self.renamesFilesKey)
        guard let data = try? JSONEncoder().encode(routingRules) else {
            report("Your routing rules could not be saved and will be lost when Fetch quits.")
            return
        }
        UserDefaults.standard.set(data, forKey: Self.routingRulesKey)
    }

    // MARK: - Plugins (§3)

    /// Installed Tier-1 plugins. Resolution goes through the registry even
    /// when it is empty — that is the dogfooding claim in §3, and it only
    /// holds if the app actually calls it.
    /// Loaded once in `init`. There is no reload and no per-plugin disable
    /// while Settings § Plugins is hidden — both existed only as that pane's
    /// buttons, and §3 rule 5's "surface the reason" needs somewhere to
    /// surface it. Restoring the pane restores them; see HANDOFF.
    private(set) var pluginRegistry = PluginRegistry(plugins: [])

    /// The subfolder a result belongs in, from the active rules.
    ///
    /// Plugin rules follow the user's own, so they can fill gaps but never
    /// pre-empt a choice the user made explicitly.
    func subfolder(for metadata: ReleaseMetadata) -> String {
        Routing.subfolder(
            for: metadata,
            rules: pluginRegistry.routingRules(builtIn: routingRules))
    }

    /// The naming strategy for a media kind, honouring the global switch.
    func namingStrategy(for kind: MediaKind) -> NamingStrategy {
        guard renamesFiles else { return .preserveOriginal }
        return .template(pluginRegistry.namingTemplate(
            for: kind, builtIn: NamingStrategy.defaultTemplate(for: kind)))
    }

    /// Whether this download's file was renamed and can be put back.
    func canRevertRename(_ id: DownloadID) -> Bool {
        guard let request = requestForDownload[id],
              items.first(where: { $0.id == id })?.state == .completed
        else { return false }
        return RenameReversal.plan(for: request) != nil
    }

    /// Moves a renamed file back to the debrid's own path (§9: renaming is
    /// always reversible).
    ///
    /// Reported rather than silent on failure: the file is on disk either way,
    /// and a menu item that appears to do nothing is worse than an explanation.
    func revertRename(_ id: DownloadID) {
        guard let request = requestForDownload[id],
              let plan = RenameReversal.plan(for: request)
        else { return }

        do {
            try FileManager.default.createDirectory(
                at: plan.to.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Never clobber: a file already sitting at the original path is
            // someone else's, and overwriting it would lose data to undo a
            // cosmetic change.
            guard !FileManager.default.fileExists(atPath: plan.to.path) else {
                report("Could not revert the rename. A file already exists at "
                       + plan.to.lastPathComponent + ".")
                return
            }
            try FileManager.default.moveItem(at: plan.from, to: plan.to)
            update(id) { $0.finalURL = plan.to }
            persist(id)
        } catch {
            report("Could not revert the rename: \(error.localizedDescription)")
        }
    }

    /// The per-file rename the engine applies, or nil when renaming is off.
    func renamePlan(
        torrentMetadata: ReleaseMetadata
    ) -> (@Sendable (DebridFile) -> String?)? {
        guard renamesFiles else { return nil }
        return FileRenamer.plan(
            torrentMetadata: torrentMetadata,
            strategy: namingStrategy(for: torrentMetadata.mediaKind))
    }


    /// The active ranking profile. Persisted as JSON, which is also the
    /// Tier-1 plugin format (§8) — a profile a user edits here is the same
    /// artefact they could ship as a file.
    var qualityProfile: QualityProfile = .default {
        didSet {
            guard let data = try? JSONEncoder().encode(qualityProfile) else {
            // Encoding a Codable value type should not fail, but if it does the
            // change is lost on quit and the user has no way to know.
            report("Your quality profile could not be saved and will be lost when Fetch quits.")
            return
        }
            UserDefaults.standard.set(data, forKey: Self.qualityProfileKey)
        }
    }

    private static let qualityProfileKey = "app.fetch.qualityProfile"

    private static let sortDefaultsKey = "app.fetch.searchSort"
    private static let sortDirectionKey = "app.fetch.searchSortDescending"
    private static let sortDefaultAdoptedKey = "app.fetch.searchSortDefaultAdopted"

    /// Results after facets, in the chosen order. Everything the table shows
    /// derives from this.
    /// Results after facets, in the chosen order. Everything the table shows
    /// derives from this — and so does the cache-check window, the count
    /// label, the keyboard activation and `contentGroups`, which is why it is
    /// memoised.
    ///
    /// **It became hot when the page size did.** Faceting and sorting are
    /// linear-ish and were free at 50 results. At 473 they are not, and this
    /// recomputes on *every* observed change — including each of the 473 cache
    /// badges arriving one at a time, each invalidating the view that reads
    /// this, each re-faceting and re-sorting all 473. That is the shape of the
    /// stall, and it is quadratic.
    ///
    /// The key is every input by value, plus a counter for the two collections
    /// too big to compare. A memo that can go stale is worse than a slow one —
    /// it shows the wrong list — so the counters are bumped at the only two
    /// places those collections are assigned.
    var visibleResults: [SearchResult] {
        let key = VisibleKey(
            resultsVersion: resultsVersion,
            cacheVersion: cacheStatesVersion,
            selection: facetSelection,
            sort: searchSort,
            descending: sortDescending,
            cachedOnly: cachedOnly,
            showsFiltered: showsFilteredResults)
        if let memo = visibleMemo, memo.key == key { return memo.value }

        let base = showsFilteredResults ? searchResults + filteredOutResults : searchResults
        let faceted = Faceting.filter(base, selection: facetSelection)
        let available = cachedOnly
            ? CachedOnlyFilter.apply(faceted, states: cacheStates, readiness: cacheReadiness)
            : faceted
        let ordered = sorted(available)
        visibleMemo = (key, ordered)
        return ordered
    }

    private struct VisibleKey: Equatable {
        let resultsVersion: Int
        let cacheVersion: Int
        let selection: FacetSelection
        let sort: ResultSort
        let descending: Bool
        let cachedOnly: Bool
        let showsFiltered: Bool
    }

    /// Deliberately not `@Observable`-tracked state anyone reads — it is a
    /// cache, and observing it would invalidate the view that filled it.
    @ObservationIgnored private var visibleMemo: (key: VisibleKey, value: [SearchResult])?
    @ObservationIgnored private var resultsVersion = 0
    @ObservationIgnored private var cacheStatesVersion = 0

    /// Facet options, counted against the unfaceted set — `Faceting.options`
    /// applies each dimension's own exclusion so a facet cannot become a
    /// one-way door.
    var facetOptions: [FacetDimension: [FacetOption]] {
        Faceting.options(for: searchResults, selection: facetSelection)
    }

    var contentGroups: [ContentGroup] {
        ContentGrouping.group(visibleResults)
    }

    private func sorted(_ results: [SearchResult]) -> [SearchResult] {
        ResultSorting.sort(
            results, by: searchSort, descending: sortDescending, cacheStates: cacheStates)
    }

    /// Union of a group's members' cache states — a group badges cached if
    /// **any** member is, since that is the one the user will pick (§8).
    func cacheState(for group: ContentGroup) -> CacheCheckState {
        let states = group.infoHashes.compactMap { hash in
            cacheStates[hash].map { (DebridProviderID(rawValue: hash), $0) }
        }
        return DebridRouter.mergeCacheStates(Dictionary(
            states, uniquingKeysWith: { first, _ in first }))
    }

    /// How many indexers have reported, while a search is running; `nil` when
    /// nothing is in flight. Drives the "4 of 7 indexers" progress readout.
    private(set) var searchProgress: (completed: Int, total: Int)?

    private var searchTask: Task<Void, Never>?

    // MARK: - Paging
    //
    // `SearchQuery` has carried `limit`/`offset` since M2 and every provider
    // honours them; `runSearch` simply never sent an offset, and the
    // accumulator was local to its `Task` and gone the moment it returned. So
    // a search was always exactly one page deep and there was nothing left
    // alive to ask for a second.

    /// How many results each page asks each provider for.
    ///
    /// **Not 50, and not a page size in the usual sense.** Measured against a
    /// real Jackett `/all/` aggregate: `offset` is not implemented — any
    /// offset above zero returns an empty feed in 21ms — while `limit` is
    /// honoured up to the 1000 its own caps advertise, and the query takes the
    /// same ~14 seconds whether it asks for 50 results or 473, because the
    /// cost is the fan-out behind it and not the size of the reply.
    ///
    /// So against the most common Torznab setup there is exactly one page, and
    /// asking for a small one throws away results the indexer has already
    /// found. A search for "Dua Lipa" returned 473 results; Fetch asked for 50,
    /// showed 20 after dedupe and the quality profile, and had no way to reach
    /// the rest — scrolling asked for offset 50, got the empty feed, and
    /// correctly concluded it had reached the end.
    ///
    /// Each provider clamps this to what it will actually serve
    /// (`ProviderCapabilities.maxLimit` for Torznab, its own page maths for
    /// Gutenberg), so this is a ceiling rather than a demand. Paging still
    /// exists for the sources that genuinely page.
    static let searchPageSize = 500

    /// The accumulator behind what is on screen, kept alive after the search
    /// finishes so a second page can fold into the same dedupe and ranking
    /// rather than being appended raw. `SearchAggregator`'s merge is
    /// order-sensitive — see `StreamedResultAccumulator` — so a page cannot
    /// just be concatenated.
    private var searchAccumulator: StreamedResultAccumulator?
    /// The category the loaded pages were fetched under, so a page 2 is
    /// fetched under the same one even if the pill has since changed.
    private var pagedCategory: SearchCategory = .all
    private var pagesLoaded = 0

    private(set) var isLoadingMore = false

    /// Whether asking for another page could produce anything.
    ///
    /// Goes false when a page adds nothing new. No source reliably says "that
    /// was the last one" — Torznab indexers differ, Gutendex's `next` is
    /// per-provider — so "a page that told us nothing" is the honest end
    /// condition, and it is also the one that stops an endless scroll from
    /// hammering seven indexers for results that do not exist.
    private(set) var canLoadMore = false

    /// Set when a page fails outright, so the footer offers Retry instead of
    /// arming itself again — a footer that retries on appear is an infinite
    /// request loop.
    private(set) var loadMoreFailed = false

    private var loadMoreTask: Task<Void, Never>?

    /// Indexer servers configured in Settings § Search, each owning its
    /// indexers. Persisted (minus the API key, which lives only in the
    /// credential store, one entry per server) so they survive relaunch.
    private(set) var indexerServers: [IndexerServerConfig] = []

    /// Every sub-indexer that a search will actually query, flattened.
    var activeIndexers: [(server: IndexerServerConfig, indexer: SubIndexer)] {
        indexerServers.flatMap { server in
            server.activeIndexers.map { (server, $0) }
        }
    }

    /// The same, narrowed to the indexers reserved for one pill.
    ///
    /// A search fans out over this rather than `activeIndexers`, so an indexer
    /// the user has reserved for Anime is never asked a Software query — and,
    /// because the narrowing happens before the aggregator is built, is never
    /// counted in "3 of 7 indexers" either.
    func activeIndexers(
        for category: SearchCategory
    ) -> [(server: IndexerServerConfig, indexer: SubIndexer)] {
        indexerServers.flatMap { server in
            server.activeIndexers(for: category).map { (server, $0) }
        }
    }

    /// Display name for a `SearchResult.sources` entry.
    ///
    /// **The indexer, not the server that fronts it.** This read
    /// "Jackett · 1337x", and in a column narrow enough to truncate, the half
    /// that survived was the half every row shares. Which of eleven trackers a
    /// result came from is the entire question the column answers; that they
    /// all arrive through Jackett is not.
    ///
    /// A lone endpoint has no separate indexer name to use, so it keeps the
    /// server's.
    func indexerName(for id: SearchProviderID) -> String? {
        for server in indexerServers {
            if let indexer = server.indexers.first(where: { $0.id == id }) {
                return server.indexers.count > 1 ? indexer.name : server.displayName
            }
        }
        return nil
    }

    /// Cache badge state per lowercase info hash, folded from
    /// `CacheStatusStore.updates` the same way `items` is folded from
    /// `engine.events`.
    private(set) var cacheStates: [String: CacheCheckState] = [:]
    private var cacheStatusStore: CacheStatusStore?
    private var cachePump: Task<Void, Never>?

    /// Whether cache badges mean anything right now. Keyed off the store
    /// rather than `isConfigured` because the store is what actually answers
    /// cache questions.
    ///
    /// This is exposed rather than left implicit because its absence used to
    /// be invisible: `runSearch` skipped its bulk check behind a bare
    /// `guard let ... else { return }`, every badge stayed `.unchecked`, and
    /// the file picker read that silence as a definite "not cached". A
    /// missing API key presented itself as a broken cache badge.
    var cacheReadiness: CacheReadiness {
        CacheReadiness(providers: providers)
    }

    private static let indexerServersDefaultsKey = "app.fetch.indexerServers"
    /// The pre-server flat list. Read by migration, never written or cleared.
    private static let searchProvidersDefaultsKey = "app.fetch.searchProviderConfigs"

    /// One smoothing estimator per in-flight download, used only as a
    /// fallback when the engine's own reported rate is non-positive.
    /// `DownloadEngine` currently always emits `bytesPerSecond: 0` in its
    /// `.progress` events (see `DownloadEngine.report`), so reading that
    /// field straight through would leave `DownloadItem.etaText` permanently
    /// nil. `RateEstimator` derives a smoothed rate from consecutive samples
    /// (EMA + a refresh floor) so the ETA it feeds doesn't flip between
    /// values like "about 3 minutes" and "2 minutes" on every ~100ms
    /// progress tick; if the engine ever starts reporting a genuine rate,
    /// that value is preferred and this fallback stops being exercised.
    private var rateEstimators: [DownloadID: RateEstimator] = [:]

    /// Big Buck Bunny — Blender Foundation, CC-BY. Freely distributable and
    /// large enough that pause/resume is genuinely exercised.
    static let testMagnet =
        "magnet:?xt=urn:btih:dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c"
        + "&dn=Big+Buck+Bunny"

    /// The pre-list TorBox credential slot, from before debrids were a
    /// configurable set. `loadDebridConfigs` is its only remaining reader: a
    /// user who saved a key under the old single-provider model still has it
    /// here, and adopting it is what stops their app coming up unconfigured.
    ///
    /// It is not a *separate* slot — `saveDebridKey` builds the identical
    /// account for `DebridProviderID("torbox")`, which is why adopting the
    /// legacy key needs no copy. Kept named so the migration reads as one.
    static let credentialAccount = CredentialAccount(layer: "debrid", providerID: "torbox")

    private static let downloadDirectoryDefaultsKey = "app.fetch.downloadDirectoryPath"
    private static let closeBehaviourKey = "app.fetch.windowCloseBehaviour"
    /// Marks that any answer stored by the pre-ticked checkbox has been
    /// cleared. Outlives the value it clears, so it only happens once.
    private static let closeBehaviourResetKey = "app.fetch.windowCloseBehaviourReset"

    /// True once `configureProviders()` has built a provider/engine — i.e.
    /// there is something to download with. Drives the Downloads empty
    /// state and gates the Add Magnet toolbar button.
    var isConfigured: Bool { engine != nil }

    /// True when any row refers to a job the *current* engine still owns —
    /// i.e. `configureProviders()` swapping in a fresh `DownloadEngine` would
    /// orphan it: its pause/resume/cancel controls would silently no-op
    /// against an engine that has no record of its `DownloadID`. Terminal
    /// rows (`.completed`, `.cancelled`) are inert and don't block
    /// reconfiguration. Drives `saveDebridKey`'s guard and `SettingsView`'s
    /// disabled Save button.
    var hasActiveDownloads: Bool {
        // A preparation counts: it is a live poll owned by one engine, and
        // swapping the engine out from under it strands the row exactly as it
        // strands a download's controls.
        items.contains { !$0.state.isTerminal } || !preparations.isEmpty
    }

    /// Defaults to `FileCredentialStore` — the only store, since the Keychain
    /// one was removed: this app is ad-hoc signed, so its signature changes on
    /// every rebuild and macOS re-prompted for Keychain access each launch.
    /// See `FileCredentialStore` for the security tradeoff that accepts.
    ///
    /// A key stored before that switch stayed in the Keychain while this read
    /// an empty file store, leaving the app silently unconfigured. If a second
    /// store is ever reintroduced, it must migrate on read.
    init(credentialStore: any CredentialStore = FileCredentialStore()) {
        self.credentialStore = credentialStore
        self.downloadDirectory = Self.loadDownloadDirectory()


        self.downloadStore = try? DownloadStore()
        self.pluginRegistry = PluginRegistry(
            plugins: PluginLoader.load(from: PluginLoader.defaultDirectory).loaded)
        if let data = UserDefaults.standard.data(forKey: Self.routingRulesKey),
           let rules = try? JSONDecoder().decode([RoutingRule].self, from: data) {
            self.routingRules = rules
        }
        self.renamesFiles = UserDefaults.standard.bool(forKey: Self.renamesFilesKey)
        // `bool(forKey:)` returns false for an absent key, so a default-on
        // setting must check the key exists before reading it — otherwise the
        // first launch turns safe search off.
        if UserDefaults.standard.object(forKey: Self.safeSearchKey) != nil {
            self.safeSearch = UserDefaults.standard.bool(forKey: Self.safeSearchKey)
        }
        if UserDefaults.standard.object(forKey: Self.internetArchiveKey) != nil {
            self.searchesInternetArchive =
                UserDefaults.standard.bool(forKey: Self.internetArchiveKey)
        }
        self.archiveShowsDerivedByDefault =
            UserDefaults.standard.bool(forKey: Self.archiveDerivedKey)
        if UserDefaults.standard.object(forKey: Self.gutenbergKey) != nil {
            self.searchesGutenberg = UserDefaults.standard.bool(forKey: Self.gutenbergKey)
        }
        if UserDefaults.standard.object(forKey: Self.gutenbergLanguagesKey) != nil {
            self.gutenbergFollowsSystemLanguages =
                UserDefaults.standard.bool(forKey: Self.gutenbergLanguagesKey)
        }
        self.gutenbergIncludesSupplementary =
            UserDefaults.standard.bool(forKey: Self.gutenbergExtrasKey)
        if let data = UserDefaults.standard.data(forKey: Self.qualityProfileKey),
           let profile = try? JSONDecoder().decode(QualityProfile.self, from: data) {
            self.qualityProfile = profile
        }
        migrateBookFormatPreference()
        if UserDefaults.standard.object(forKey: Self.maxConcurrentKey) != nil {
            self.maxConcurrentDownloads =
                UserDefaults.standard.integer(forKey: Self.maxConcurrentKey)
        }
        if UserDefaults.standard.object(forKey: Self.segmentsKey) != nil {
            self.segmentsPerFile = UserDefaults.standard.integer(forKey: Self.segmentsKey)
        }
        // A stored `bestMatch` is almost certainly the *old* default rather
        // than a choice, since it was the default for this key's whole life.
        // Adopting the new one once — and recording that it happened, so a
        // deliberate return to best match is never overwritten a second time.
        if !UserDefaults.standard.bool(forKey: Self.sortDefaultAdoptedKey) {
            UserDefaults.standard.set(true, forKey: Self.sortDefaultAdoptedKey)
            if UserDefaults.standard.string(forKey: Self.sortDefaultsKey) == "bestMatch" {
                UserDefaults.standard.removeObject(forKey: Self.sortDefaultsKey)
                UserDefaults.standard.removeObject(forKey: Self.sortDirectionKey)
            }
        }
        if let raw = UserDefaults.standard.string(forKey: Self.sortDefaultsKey),
           let sort = ResultSort(rawValue: raw) {
            self.searchSort = sort
            self.sortDescending = UserDefaults.standard.object(forKey: Self.sortDirectionKey) != nil
                ? UserDefaults.standard.bool(forKey: Self.sortDirectionKey)
                : sort.defaultsToDescending
        }
        if UserDefaults.standard.object(forKey: Self.cachedOnlyKey) != nil {
            self.cachedOnlyDefault = UserDefaults.standard.bool(forKey: Self.cachedOnlyKey)
        }
        self.cachedOnly = self.cachedOnlyDefault
        if UserDefaults.standard.object(forKey: Self.filtersKey) != nil {
            self.showsFilters = UserDefaults.standard.bool(forKey: Self.filtersKey)
        }
        // **Any stored answer is discarded, once.** The dialog offering to
        // remember the choice arrived with its checkbox already ticked, so
        // reading the three buttons and pressing one also answered a second
        // question nobody had read — and the dialog never came back. A
        // preference set that way cannot be told from one set deliberately, so
        // they all go and the question is asked again with the box off.
        if let stored = UserDefaults.standard.object(forKey: Self.indexerTimeoutKey) as? Double,
           stored > 0 {
            self.indexerTimeout = stored
        }
        if !UserDefaults.standard.bool(forKey: Self.closeBehaviourResetKey) {
            UserDefaults.standard.removeObject(forKey: Self.closeBehaviourKey)
            UserDefaults.standard.set(true, forKey: Self.closeBehaviourResetKey)
        }
        if let raw = UserDefaults.standard.string(forKey: Self.closeBehaviourKey),
           let behaviour = WindowCloseBehaviour(rawValue: raw) {
            self.windowCloseBehaviour = behaviour
        }
        self.indexerServers = loadIndexerServers()
        loadDebridCacheStats()
        self.debridConfigs = loadDebridConfigs()

        // Keys saved in a prior launch must make the app usable immediately —
        // never force the user back into Settings to re-enter what is stored.
        configureProviders()
        // Before the first download finishes, so the prompt appears while the
        // user is still doing the thing that will produce a notification.
        notifier.prepare()

        // **Nothing here may touch the file system.** `restoreDownloads` used
        // to run inline, and it measures every restored download against what
        // is on disk — so `AppModel.init`, called from `FetchApp.init`, could
        // block in `getxattr` before the scene body was ever evaluated. The
        // app started and drew no window at all; sampled and confirmed twice,
        // 60 seconds in one call. The measurement is cheap now (`FileSize`
        // uses `stat`, not the extended-attribute read that wedged), but the
        // rule stands regardless: no file system on the launch path. A `Task`
        // from a synchronous initialiser does not run until this returns, so
        // the window is drawn first and the rows arrive a moment later.
        Task { await restoreDownloads() }
    }

    /// Rebuilds every configured debrid from the credential store.
    ///
    /// `providers` is in the user's preference order, which `DebridRouter`
    /// consults when choosing where a download goes. The **first** one drives
    /// `DownloadEngine`, since the engine is still single-provider; routing a
    /// download to a non-preferred debrid is the remaining gap.
    func configureProviders() {
        let built = debridConfigs.filter(\.isEnabled).compactMap { config in
            makeProvider(config.id)
        }
        providers = built

        guard let primary = built.first else {
            engine = nil
            engines = [:]
            engineForDownload = [:]
            cacheStatusStore = nil
            pumps.forEach { $0.cancel() }
            pumps = []
            cachePump?.cancel()
            cacheStates = [:]
            return
        }

        // Reconfiguring (the user saves a new key later in the session) must
        // not leave previous pump loops running alongside the new ones,
        // feeding events from engines nothing else references.
        pumps.forEach { $0.cancel() }
        pumps = []
        engines = [:]
        engineForDownload = [:]

        for built in built {
            let engine = DownloadEngine(
                provider: built,
                segmented: SegmentedTransfer(maxSegments: segmentsPerFile),
                segmentsPerFile: segmentsPerFile,
                maxConcurrent: maxConcurrentDownloads)
            engines[built.id.rawValue] = engine
            engineNames[ObjectIdentifier(engine)] = built.displayName
            pumps.append(Task { [weak self] in
                for await event in engine.events {
                    await self?.apply(event, from: engine)
                }
            })
        }
        self.engine = engines[primary.id.rawValue]

        let statusStore = CacheStatusStore(providers: built)
        self.cacheStatusStore = statusStore
        cacheStates = [:]
        cachePump?.cancel()
        cachePump = Task { [weak self] in
            for await snapshot in statusStore.updates {
                await self?.applyCacheSnapshot(snapshot)
                // Drained here because this loop already runs for every
                // resolved hash, and because the store is rebuilt whenever the
                // user's providers change — anything it kept would be lost at
                // exactly the moment a long-run statistic becomes worth having.
                await self?.foldCacheStats(from: statusStore)
            }
        }
    }

    private func applyCacheSnapshot(_ snapshot: CacheStatusStore.Snapshot) {
        cacheStates[snapshot.hash] = snapshot.state
        // Bumped here because `cacheStates` feeds the cached-only filter and
        // the Cached column. Comparing the dictionary itself on every read
        // would cost more than the work it is meant to skip.
        cacheStatesVersion &+= 1
    }

    // MARK: - Download directory

    func setDownloadDirectory(_ url: URL) {
        downloadDirectory = url
        UserDefaults.standard.set(url.path, forKey: Self.downloadDirectoryDefaultsKey)
    }

    private static func loadDownloadDirectory() -> URL {
        if let path = UserDefaults.standard.string(forKey: downloadDirectoryDefaultsKey),
           !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        let downloads = FileManager.default
            .urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        let fallback = downloads.appendingPathComponent("Fetch", isDirectory: true)
        try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }

    // `addMagnet` lived here: submit, then poll until the debrid held the
    // whole torrent, then enqueue. Its doc comment argued that the `await`
    // suspends rather than blocks, which was true and beside the point — the
    // *sheet* was waiting on it. `prepareInBackground` replaced it at both
    // call sites and the blocking version had no producer left.

    // MARK: - Hosted links (7e)

    /// What each configured debrid can unrestrict, as far as Fetch has asked.
    ///
    /// Empty until `refreshHostCoverage()` has answered — `PastedLink`
    /// distinguishes that from "nobody covers this host", so a link pasted
    /// before the first answer says "checking" rather than being refused.
    private(set) var hostCoverage: [DebridProviderID: [DebridHost]] = [:]

    private let hostsCache = SupportedHostsCache()

    /// Torznab `t=caps` answers, shared across every search for the
    /// session. `torznabProviders()` builds a fresh `TorznabProvider` per
    /// indexer on every call — one instance is one search — so this store
    /// has to live here, not on the provider, or nothing survives between
    /// searches (Task 3b).
    private let torznabCapsStore = TorznabCapsStore()

    /// Forgets every cached `t=caps` answer. Called from every indexer-server
    /// mutation that persists — a saved endpoint or key change makes the
    /// cached answer wrong immediately, and six hours is a long time to be
    /// wrong about a server the user just edited.
    private func clearTorznabCaps() {
        Task { await torznabCapsStore.clear() }
    }

    /// Asks every configured debrid what it covers, honouring the cache's TTL.
    func refreshHostCoverage(force: Bool = false) async {
        if force { await hostsCache.invalidate() }
        hostCoverage = await hostsCache.hosts(for: providers)
    }

    /// What a pasted string is, given what Fetch currently knows.
    func resolvePastedLink(_ text: String) -> PastedLink {
        PastedLink.resolve(
            text, configured: providers.map(\.id), coverage: hostCoverage)
    }

    /// Submits a hoster link to the debrid that covers it and queues the file.
    func addHostedLink(_ url: URL, using provider: DebridProviderID) async throws {
        guard let debrid = providers.first(where: { $0.id == provider }),
              let engine = engines[provider.rawValue]
        else { throw AppModelError.notConfigured }

        let request = try await engine.prepareHostedLink(
            url, subfolder: nil, destinationRoot: downloadDirectory)
        let id = await engine.enqueue(request)
        remember(id, Routed(provider: debrid, engine: engine))
    }

    /// Picks the debrid for a magnet and returns its engine.
    ///
    /// A provider that already has the torrent cached beats a more-preferred
    /// one that would have to fetch it — the difference is an instant download
    /// versus a wait — which is what `DebridRouter` encodes. Cache answers come
    /// from `CacheStatusStore`, which records them per provider precisely so
    /// this decision can be made.
    /// The debrid the user has pinned for the next download, overriding the
    /// automatic choice.
    ///
    /// Routing picks whichever service already holds the torrent, falling back
    /// to the first in preference order — a good default and the wrong answer
    /// whenever the user has a reason of their own: one account near its slot
    /// limit, one with the faster CDN today, one they are deliberately
    /// spending. There was no way to say so; the choice was announced
    /// ("Downloading via TorBox") and not offered.
    ///
    /// Cleared after each add, so a one-off choice does not silently become a
    /// setting.
    private(set) var pinnedProvider: DebridProviderID?

    func pinProvider(_ id: DebridProviderID?) { pinnedProvider = id }

    private func route(_ rawMagnet: String) async throws -> Routed {
        guard !providers.isEmpty else { throw AppModelError.notConfigured }

        // The user's choice beats the router's. Only for a provider that is
        // actually configured and enabled — a pin left over from a service
        // since removed falls back to routing rather than failing the add.
        if let pinnedProvider,
           let chosen = providers.first(where: { $0.id == pinnedProvider }),
           let engine = engines[chosen.id.rawValue] {
            return Routed(provider: chosen, engine: engine)
        }

        let hash = MagnetLink(rawMagnet)?.infoHash.hex ?? ""
        // Ask, do not merely read. The map is populated by search badge
        // checks, so a *pasted* magnet's hash was never in it — the
        // cached-provider-wins rule above applied only to results the user had
        // searched for, and silently not to anything they added by hand.
        if let store = cacheStatusStore, !hash.isEmpty {
            await store.check(hashes: [hash])
        }
        let cached = await cacheStatusStore?.cachedProviderMap() ?? [:]

        guard let chosen = DebridRouter.provider(
            for: hash, providers: providers, cachedOn: cached),
              let engine = engines[chosen.id.rawValue]
        else { throw AppModelError.notConfigured }

        return Routed(provider: chosen, engine: engine)
    }

    /// Whether a torrent is already on one of the configured debrids, and
    /// which one would serve it — what the add sheet shows before committing.
    func availability(forMagnet rawMagnet: String) async -> LinkAvailability {
        guard let store = cacheStatusStore,
              let hash = MagnetLink(rawMagnet)?.infoHash.hex
        else { return providers.isEmpty ? .noProviders : .unknowable(providers[0].id) }

        return await LinkAvailability.resolve(
            hash: hash, providers: providers, store: store)
    }

    /// Reads a `.torrent` from disk and returns the magnet to add.
    ///
    /// Parsing is local: no peer is contacted and no announce is made. The
    /// magnet goes to a debrid exactly as a pasted one does.
    func magnet(fromTorrentFileAt url: URL) -> MagnetLink? {
        // A security-scoped resource, because a dropped or chosen file is
        // outside the sandbox until asked for.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url) else { return nil }
        return TorrentFile.parse(data)?.magnet
    }

    /// The whole parse, not just the magnet.
    ///
    /// Same file, same read; the caller that wants the file list should not
    /// have to open it twice. No peer is contacted either way — this is
    /// bencode on disk.
    func torrent(fromFileAt url: URL) -> TorrentFile? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return TorrentFile.parse(data)
    }

    struct Routed {
        let provider: any DebridProvider
        let engine: DownloadEngine
    }

    // MARK: - Preparing (the uncached path)

    /// A magnet the debrid is still fetching into its own cloud.
    ///
    /// Its own type rather than a `DownloadItem` in a `.preparing` state,
    /// because nothing about it is a local transfer: the percentage is the
    /// *service's* progress pulling from the swarm, there are no bytes on this
    /// machine, and there is nothing to pause or resume. Presenting it as a
    /// download would mean a progress bar that means something different from
    /// every other progress bar on the screen.
    struct Preparation: Identifiable {
        let id: PreparationID
        let name: String
        /// The row the resulting files will land in — announced by the engine
        /// before they exist, so the row does not jump when they arrive.
        let groupKey: DownloadGroupKey
        var progress: PreparationProgress?
        var providerName: String
    }

    /// Torrents being fetched by a debrid right now, oldest first.
    ///
    /// This is what the uncached path used to be: an `await` held by a modal
    /// sheet for as long as the debrid took, with nothing in Downloads and no
    /// way to leave. The magnet was committed to the account the moment it was
    /// submitted; only the evidence was trapped.
    private(set) var preparations: [Preparation] = []

    private var engineForPreparation: [PreparationID: DownloadEngine] = [:]

    /// Submits an uncached magnet and returns as soon as the debrid has
    /// accepted it — the wait becomes a row, not a spinner.
    ///
    /// Throws only for a submission the service refuses outright, which is
    /// worth reporting while the user is still looking at the sheet. Anything
    /// that goes wrong afterwards arrives as `.preparationFailed` on the row.
    func prepareInBackground(
        _ rawMagnet: String, selecting: Set<String>? = nil, subfolder: String? = nil,
        metadata: ReleaseMetadata = .unparsed, displayName: String? = nil
    ) async throws {
        let routed = try await route(rawMagnet)
        let id = try await routed.engine.beginPreparation(
            rawMagnet, selecting: selecting, subfolder: subfolder,
            destinationRoot: downloadDirectory,
            rename: renamePlan(torrentMetadata: metadata),
            groupName: metadata.title, metadata: metadata,
            displayName: displayName ?? metadata.title)
        engineForPreparation[id] = routed.engine
        // A pin is for the download you just started, not for every one after
        // it. Left set, one deliberate choice quietly becomes a policy.
        pinnedProvider = nil
        // Recorded per preparation, so the file rows that follow reach the
        // engine that actually holds them — the same reason `remember` exists
        // for a download.
        preparingProvider[id] = routed
    }

    private var preparingProvider: [PreparationID: Routed] = [:]

    /// Stops watching. The torrent stays on the debrid account: the user has
    /// already paid the wait for it, and throwing that away is a separate
    /// decision from clearing a row.
    func cancelPreparation(_ id: PreparationID) {
        guard let engine = engineForPreparation[id] else {
            preparations.removeAll { $0.id == id }
            return
        }
        Task { await engine.cancelPreparation(id) }
    }

    /// Records which engine owns a download, so its pause/resume/cancel reach
    /// the right one, and which debrid served it, so the UI can say.
    private func remember(_ id: DownloadID, _ routed: Routed) {
        engineForDownload[id] = routed.engine
        providerForDownload[id] = routed.provider.displayName
    }

    /// Which debrid would serve this hash — what the file picker shows before
    /// the user commits, so the choice is never invisible.
    func routedProviderName(forHash hash: String) async -> String? {
        guard !providers.isEmpty else { return nil }
        let cached = await cacheStatusStore?.cachedProviderMap() ?? [:]
        return DebridRouter.provider(
            for: hash, providers: providers, cachedOn: cached)?.displayName
    }

    // MARK: - Torrent grouping (Settings-free, §12.3)

    /// A torrent and the files being downloaded from it.
    struct TorrentGroup: Identifiable {
        /// One attempt at one thing — `DownloadGroupKey.rawValue`, not the
        /// infohash. Two goes at the same torrent are two rows.
        let id: String
        /// The infohash (or item id) behind the row, shared across attempts.
        /// Anything looked up *by content* — the torrent's file list, its cache
        /// badge — uses this, never `id`.
        let contentKey: String
        let displayName: String
        let items: [DownloadItem]
        let section: DownloadSection
        /// What this row is, for the library's sections. Read from the
        /// persisted `ReleaseMetadata` rather than re-parsed from the name:
        /// a provider's stated kind beats a guess from the title, which is why
        /// every Gutenberg EPUB used to file under Other.
        let mediaKind: MediaKind

        /// When the row finished — its last file to land. Nil while anything
        /// is still going, and for rows saved before the store recorded it.
        var completedAt: Date? { items.compactMap(\.completedAt).max() }

        var totalBytes: Int64 { items.reduce(0) { $0 + $1.totalBytes } }
        var bytesDownloaded: Int64 { items.reduce(0) { $0 + $1.bytesDownloaded } }
        /// Summed across files, which is what the user's connection is
        /// actually doing — a per-file figure understates a multi-file torrent.
        var bytesPerSecond: Double { items.reduce(0) { $0 + $1.bytesPerSecond } }

        var fraction: Double? {
            guard totalBytes > 0 else { return nil }
            return Double(bytesDownloaded) / Double(totalBytes)
        }

        var etaText: String? {
            ByteCount.eta(
                remaining: totalBytes - bytesDownloaded, bytesPerSecond: bytesPerSecond)
        }

        /// Queued files are waiting on the concurrency limit, not stuck. The
        /// row says so, because a 0% bar reads as broken.
        var queuedCount: Int { items.filter { $0.state == .queued }.count }

        /// Chosen once from the total, then reused for every progress tick.
        ///
        /// Without it `ByteCount.format` re-picks the "best" unit per value, so
        /// a transfer crossing 999 MB → 1.0 GB changes the string's length and
        /// reflows the row — ten times a second. `DownloadItem` already does
        /// this per file; a group needs its own, from its own total.
        var pinnedUnit: ByteCountFormatter.Units {
            ByteCount.pinnedUnit(for: totalBytes)
        }
    }

    /// Opens the folder a finished group landed in, with its files selected.
    ///
    /// One implementation for the row's Finder button and for double-clicking
    /// the row, because two spellings of "show me this on disk" is how they
    /// drift into disagreeing about which path they mean.
    ///
    /// Nothing happens when no file has a landing path: a group still
    /// downloading, or one whose files were deleted, has no folder to open,
    /// and guessing the destination root would open somewhere the user never
    /// put anything.
    @discardableResult
    func revealInFinder(_ group: TorrentGroup) -> Bool {
        let urls = group.items.compactMap(\.finalURL)
        guard !urls.isEmpty else { return false }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
        return true
    }

    /// Rows grouped by attempt, in lifecycle order.
    ///
    /// Grouped on `DownloadGroupKey` from the request rather than on a stored
    /// torrent id, because a debrid's per-file links carry no torrent name.
    /// The key is content **plus attempt**: keying on content alone meant a
    /// download cancelled and started again joined its own corpses, so the row
    /// summed six copies of one file into 6.9 GB, divided its progress by that
    /// same total, and moved to Failed the moment the live file finished.
    /// Memoised, for the same reason `visibleResults` is.
    ///
    /// It rebuilds every row from every item, and it is read several times per
    /// render — the list, the failed count, the library sections, each row's
    /// skipped-file lookup. At a handful of downloads that is free. At the 415
    /// this install carries, with a progress event arriving ten times a second
    /// per active file, it is the lag.
    ///
    /// Keyed on a counter bumped wherever `items` or the request map changes,
    /// rather than on the items themselves: comparing 415 rows to decide
    /// whether to rebuild 415 rows saves nothing.
    var torrentGroups: [(section: DownloadSection, groups: [TorrentGroup])] {
        if let memo = groupsMemo, memo.key == itemsVersion { return memo.value }
        let value = buildTorrentGroups()
        groupsMemo = (itemsVersion, value)
        return value
    }

    @ObservationIgnored
    private var groupsMemo: (key: Int, value: [(section: DownloadSection, groups: [TorrentGroup])])?
    @ObservationIgnored private var itemsVersion = 0

    /// Bumped by every mutation the grouping reads. Missing one shows a stale
    /// list, so it is called from `update`, from the two `items` mutations,
    /// and wherever `requestForDownload` changes.
    private func invalidateGroups() { itemsVersion &+= 1 }

    private func buildTorrentGroups() -> [(section: DownloadSection, groups: [TorrentGroup])] {
        let rows = DownloadGrouping.rows(items) { item in
            // A row whose request has not arrived yet gets a key of its own,
            // so it renders alone rather than joining an unrelated group.
            requestForDownload[item.id]?.groupKey
                ?? .unattempted(item.id.rawValue.uuidString)
        }

        let groups = rows.compactMap { key, members -> TorrentGroup? in
            guard !members.isEmpty,
                  let section = DownloadGrouping.section(for: members.map(\.state))
            else { return nil }

            let paths = members.compactMap { requestForDownload[$0.id]?.file.name }
            let displayName = DownloadGrouping.displayName(
                stated: members.compactMap { requestForDownload[$0.id]?.groupName }.first,
                forPaths: paths)
                ?? "\(members.count) files"
            return TorrentGroup(
                id: key.rawValue,
                contentKey: key.content,
                displayName: displayName,
                items: members,
                section: section,
                mediaKind: requestForDownload[members[0].id]?.metadata.mediaKind ?? .other)
        }

        return DownloadSection.allCases.compactMap { section in
            let matching = groups.filter { $0.section == section }
            return matching.isEmpty ? nil : (section, matching)
        }
    }

    /// How many rows are sitting in Failed — the badge on the Downloads
    /// filter, and what `clearFailed()` would remove.
    var failedGroupCount: Int {
        torrentGroups.first { $0.section == .failed }?.groups.count ?? 0
    }

    /// Completed downloads, grouped by what they are. Still used for the kind
    /// bar's counts, which are per kind by definition.
    var librarySections: [(kind: MediaKind, rows: [TorrentGroup])] {
        DownloadLibrary.sections(
            completedGroups, kind: \.mediaKind, name: \.displayName)
    }

    private var completedGroups: [TorrentGroup] {
        torrentGroups.filter { $0.section == .completed }.flatMap(\.groups)
    }

    /// The shelf as one newest-first list, narrowed to a kind or not.
    ///
    /// Grouping by kind is the right shape when you are looking *for* a kind,
    /// which is what the bar above it is for. Looking at everything, the useful
    /// question is "what did I get recently" — and that answer was buried under
    /// eight alphabetised headings.
    func libraryRows(kind: MediaKind?) -> [TorrentGroup] {
        let rows = kind.map { wanted in
            completedGroups.filter { $0.mediaKind == wanted }
        } ?? completedGroups
        return DownloadLibrary.newestFirst(
            rows, date: \.completedAt, name: \.displayName)
    }

    // MARK: - Torrent-level controls
    //
    // Both levels act, per the design decision: a torrent row controls every
    // file under it, and each file keeps its own controls when expanded.

    func pauseTorrent(_ group: TorrentGroup) {
        for item in group.items where item.state == .downloading { pause(item.id) }
    }

    func resumeTorrent(_ group: TorrentGroup) {
        for item in group.items where item.state.canBeStarted { resume(item.id) }
    }

    /// Cancels every file still in flight **and** removes the torrent from the
    /// debrid account.
    ///
    /// The remote half is the point. Cancelling an uncached torrent used to
    /// stop the local transfer and leave the service fetching it — so the
    /// account went on downloading something nobody wanted, holding a slot
    /// until it finished. Cancel should cancel.
    ///
    /// Only for a torrent Fetch put there: a direct download has no torrent,
    /// and a row whose request is gone has no id to delete by.
    func cancelTorrent(_ group: TorrentGroup) {
        // Read before anything is cancelled: `remove` clears the request map,
        // and the torrent id lives in it.
        let remote = remoteTorrent(of: group)
        for item in group.items where !item.state.isTerminal { cancel(item.id) }
        deleteRemotely(remote)
    }

    /// The debrid torrent behind a row, if there is one.
    ///
    /// Nil for a direct download, which has no torrent, and for a row whose
    /// request Fetch no longer holds — there is nothing to delete by.
    private func remoteTorrent(of group: TorrentGroup) -> (DownloadEngine, DebridTorrentID)? {
        guard let request = group.items.compactMap({ requestForDownload[$0.id] }).first,
              case .debridTorrent(_, let torrentID, _) = request.source,
              let engine = group.items.compactMap({ engineForDownload[$0.id] }).first ?? engine
        else { return nil }
        return (engine, torrentID)
    }

    /// Detached from whatever asked for it: the row goes now, and a service
    /// slow to answer must not hold it on screen. A delete that fails leaves a
    /// torrent on the account, recoverable in the service's own UI; a UI that
    /// waits on it is not recoverable at all.
    private func deleteRemotely(_ remote: (DownloadEngine, DebridTorrentID)?) {
        guard let (engine, torrentID) = remote else { return }
        Task { await engine.deleteRemoteTorrent(torrentID) }
    }

    /// Takes a row off the Downloads screen for good.
    ///
    /// Bookkeeping only — a completed download's file stays exactly where it
    /// is. An unfinished one's `.fetchpart` goes with it, since nothing can
    /// resume a row that no longer exists.
    func removeTorrent(_ group: TorrentGroup) {
        // **Only when nothing here finished.** Removing a row is bookkeeping,
        // and a completed download's copy on the debrid is the user's — they
        // may well want it there. But a row where nothing landed is a torrent
        // the service is holding for a download that is not going to happen,
        // and clearing the row while leaving it is how an account fills up
        // with things nobody asked it to keep.
        let landed = group.items.contains { $0.state == .completed }
        let remote = landed ? nil : remoteTorrent(of: group)
        for item in group.items { remove(item.id) }
        deleteRemotely(remote)
    }

    // MARK: - Downloading a torrent's other files

    /// Queues files from a torrent that is already on a Downloads row —
    /// the ones that were skipped at selection time, or that failed.
    ///
    /// **Why this is not "resume".** `DownloadEngine.resume` restarts a job the
    /// engine still holds. A file that was never selected has no job at all,
    /// and a `.missing` one is terminal by design. Both cases were dead ends on
    /// the row: `SkippedFileRow` rendered greyed and inert, and a failed file's
    /// context menu offered Show in Finder and nothing else.
    ///
    /// **It is a new row, not more files in the old one.** `DownloadGroupKey`
    /// is content *plus attempt*, and this call is an attempt — the same rule
    /// that stopped a cancelled-and-retried download from joining its own
    /// corpses. The content key is unchanged, so the two rows are visibly the
    /// same torrent.
    ///
    /// Nothing is submitted when the debrid still has the torrent: only the
    /// file **ids** have gone stale, and §6's by-path re-resolution is exactly
    /// what fixes that. An account that has since evicted it falls through to
    /// `prepareInBackground`, so an evicted torrent shows a preparing row
    /// rather than an error — no peer is contacted either way, the debrid does
    /// the swarm work.
    /// What a ticked file's Download button does.
    ///
    /// Split by state, because the two halves are different verbs. A file that
    /// is queued, paused or failed already has a job in the engine and only
    /// needs starting; one that finished, was cancelled or went missing has no
    /// job at all and has to be fetched again. Sending both down the
    /// re-download path would queue a second copy of something already waiting
    /// to run.
    func startOrRedownload(paths: Set<String>, from group: TorrentGroup) async {
        var toStart: [DownloadID] = []
        var toFetch: Set<String> = []
        for path in paths {
            let item = group.items.first { relativePath(of: $0.id) == path }
            if let item, item.state.canBeStarted {
                toStart.append(item.id)
            } else {
                toFetch.insert(path)
            }
        }
        for id in toStart { resume(id) }
        if !toFetch.isEmpty { await redownload(paths: toFetch, from: group) }
    }

    func redownload(paths: Set<String>, from group: TorrentGroup) async {
        guard !paths.isEmpty else { return }
        fetchLog(.info, "redownload", "asked for \(paths.count) file(s)")
        guard let request = group.items.compactMap({ requestForDownload[$0.id] }).first else {
            report("Fetch no longer knows where “\(group.displayName)” came from, "
                   + "so those files cannot be downloaded again from this row.")
            return
        }

        // A direct download has no torrent behind it — its URL *is* its
        // identity (§6), and it is already stored, so this is simply the same
        // request again under a new attempt.
        if case .directHTTP(let url) = request.source {
            await enqueueDirect(
                [(name: request.file.shortName, size: request.file.size, url: url)],
                contentKey: group.contentKey,
                groupName: request.groupName,
                subfolder: request.subfolder,
                metadata: request.metadata)
            return
        }

        guard let engine = group.items.compactMap({ engineForDownload[$0.id] }).first ?? engine
        else {
            report("The debrid provider this torrent came from is no longer configured.")
            return
        }

        do {
            let authoritative = try await engine.authoritativeFiles(in: request.torrentID)
            guard !authoritative.isEmpty else { throw DebridError.fileNotFound }

            let outcome = await engine.enqueueSelected(
                torrentID: request.torrentID, infoHashHex: request.infoHashHex,
                files: authoritative, selecting: paths,
                subfolder: request.subfolder, destinationRoot: downloadDirectory,
                rename: renamePlan(torrentMetadata: request.metadata),
                groupName: request.groupName, metadata: request.metadata)

            if !outcome.missingPaths.isEmpty {
                // Skipped, never silently dropped (§6). Whatever did match is
                // already queued.
                report("\(outcome.missingPaths.count) of the files chosen are no "
                       + "longer in this torrent and were skipped.")
            }
        } catch DebridError.fileNotFound {
            // The account no longer holds it. Re-submitting is the honest
            // answer, and it is cheap: a torrent the debrid has seen before is
            // usually still cached, so the preparing row is brief.
            await resubmit(paths: paths, from: request, name: group.displayName)
        } catch {
            // Anything else — a timeout, a rate limit, an expired key — is a
            // question that has not been answered, not an answer of "gone".
            // Re-submitting on those would put a torrent back on the account
            // because the network hiccuped, and hide the actual reason.
            report("Could not read this torrent's files from "
                   + (group.items.compactMap { providerForDownload[$0.id] }.first
                      ?? "your debrid") + ": "
                   + ((error as? LocalizedError)?.errorDescription
                      ?? error.localizedDescription))
        }
    }

    private func resubmit(
        paths: Set<String>, from request: DownloadRequest, name: String
    ) async {
        guard !request.infoHashHex.isEmpty else {
            report("“\(name)” is no longer on your debrid account, and Fetch has "
                   + "no magnet for it to add again.")
            return
        }
        do {
            try await prepareInBackground(
                "magnet:?xt=urn:btih:\(request.infoHashHex)",
                selecting: paths, subfolder: request.subfolder,
                metadata: request.metadata, displayName: name)
        } catch {
            report("Could not add “\(name)” again: "
                   + ((error as? LocalizedError)?.errorDescription
                      ?? error.localizedDescription))
        }
    }

    /// A download's path inside its torrent — the key every selection is
    /// re-resolved against (§6), and therefore what `redownload` needs to name
    /// one file. Not `displayName`, which is the last component and is not
    /// unique across a season pack's folders.
    func relativePath(of id: DownloadID) -> String? {
        requestForDownload[id]?.file.name
    }

    /// Every file in this torrent that has no live download — skipped at
    /// selection time, or failed, cancelled or deleted since. What the row's
    /// "Download Other Files…" acts on.
    func redownloadablePaths(for group: TorrentGroup) -> [TorrentMetadata.File] {
        DownloadGrouping.redownloadableFiles(
            allFiles: torrentFiles[group.contentKey.lowercased()] ?? [],
            paths: group.items.compactMap { item in
                requestForDownload[item.id].map { ($0.file.name, item.state) }
            })
    }

    /// Empties the Failed filter.
    ///
    /// Two limits, both deliberate. Only rows **already in that section** — a
    /// torrent still transferring stays Active even with a dead file under it
    /// (`DownloadGrouping.section`), and clearing must never reach into live
    /// work. And within those rows, only the files that actually need
    /// attention: a torrent where two files landed and one was cancelled keeps
    /// its two, loses the corpse, and moves to Completed where it belongs.
    /// Taking the whole row would throw away the record of a file the user
    /// successfully downloaded — and its "Show in Finder".
    func clearFailed() {
        let doomed = torrentGroups.first { $0.section == .failed }?.groups ?? []
        for group in doomed {
            // Same rule as `removeTorrent`: a row keeping a file it did land
            // keeps its torrent too.
            let landed = group.items.contains { $0.state == .completed }
            let remote = landed ? nil : remoteTorrent(of: group)
            for item in group.items where item.state.needsAttention { remove(item.id) }
            deleteRemotely(remote)
        }
    }

    /// Re-checks completed downloads against the disk, flipping rows whose
    /// file has been deleted or moved to `.missing` — and back to `.completed`
    /// if it reappears.
    ///
    /// Launch does this through `LaunchRecovery`; this is the same question
    /// asked again while the app is open, since a file deleted in Finder at
    /// 2pm should not still read "Completed" until the next relaunch.
    func refreshMissingFiles() {
        for item in items where item.state == .completed || item.state == .missing {
            guard let url = finalURL(for: item.id) else { continue }
            let exists = FileManager.default.fileExists(atPath: url.path)
            let next: DownloadState = exists ? .completed : .missing
            guard item.state != next else { continue }
            update(item.id) { $0.state = next }
            persist(item.id)
        }
    }

    /// Where a finished download's file actually landed.
    ///
    /// Set by the live `.finished` event, and seeded from the record's
    /// persisted `finalPath` for a row restored from a previous run. Rebuilding
    /// the path from the request instead would miss both a rename and the
    /// `(2)` suffix `PathSanitizer.disambiguate` may have added — and a file
    /// that is present but not where the guess looked reads as deleted.
    func finalURL(for id: DownloadID) -> URL? {
        items.first { $0.id == id }?.finalURL
    }

    /// True when at least one file can be paused — a torrent whose files are
    /// all queued has nothing to pause yet.
    func canPause(_ group: TorrentGroup) -> Bool {
        group.items.contains { $0.state == .downloading }
    }

    func canResume(_ group: TorrentGroup) -> Bool {
        // `.queued` counts. A restored download comes back queued and stays
        // there until something starts it, so a row of them offering no
        // Resume was a row of downloads with no way forward at all.
        group.items.contains(where: \.state.canBeStarted)
    }

    // MARK: - Controls
    //
    // `DownloadEngine.pause` and `.cancel` are `async` actor methods — they
    // must await the prior transfer task actually stopping (not just being
    // requested to cancel) before it is safe to mutate job state. See
    // `DownloadEngine.releasePath`. `DownloadRow`'s buttons are plain
    // `() -> Void` closures, so these wrappers bridge that gap with `Task {}`.

    func pause(_ id: DownloadID) {
        guard let engine = engineForDownload[id] ?? engine else {
            // The provider this row belongs to was removed or reconfigured, so
            // no engine owns it any more. Silently doing nothing left a button
            // that visibly did nothing.
            report("This download can no longer be paused. The service it was using "
                   + "is no longer configured, so remove the row and add it again.")
            return
        }
        Task { await engine.pause(id) }
    }

    func resume(_ id: DownloadID) {
        guard let engine = engineForDownload[id] ?? engine else {
            // The provider this row belongs to was removed or reconfigured, so
            // no engine owns it any more. Silently doing nothing left a button
            // that visibly did nothing.
            report("This download can no longer be resumed. The service it was using "
                   + "is no longer configured, so remove the row and add it again.")
            return
        }
        Task { await engine.resume(id) }
    }

    /// Deletes the partial file: a job cancelled through this button cannot
    /// later be resumed (`DownloadEngine.resume` only accepts `.paused` or
    /// `.failed`), so leaving an orphaned `.fetchpart` on disk serves no one.
    private func cancel(_ id: DownloadID) {
        guard let engine = engineForDownload[id] ?? engine else {
            // The provider this row belongs to was removed or reconfigured, so
            // no engine owns it any more. Silently doing nothing left a button
            // that visibly did nothing.
            report("This download can no longer be cancelled. The service it was using "
                   + "is no longer configured, so remove the row and add it again.")
            return
        }
        Task { await engine.cancel(id, deletePartial: true) }
    }

    /// Drops a row entirely. The engine answers with `.removed`, which is what
    /// takes it out of `items` and out of the database.
    ///
    /// A row whose engine is gone (its provider was removed or reconfigured)
    /// is dropped locally instead of left stuck: there is nothing left to ask,
    /// and refusing to clear it would leave the user with a row no button can
    /// touch — the exact dead end `remove` exists to end.
    private func remove(_ id: DownloadID) {
        guard let engine = engineForDownload[id] ?? engine else {
            apply(.removed(id))
            return
        }
        Task { await engine.remove(id) }
    }

    /// Mirrors a row into the store. Called for every event, so it must stay
    /// cheap — `DownloadStore.save` updates in place rather than inserting.
    private func persist(_ id: DownloadID) {
        guard let store = downloadStore,
              let request = requestForDownload[id],
              let item = items.first(where: { $0.id == id })
        else { return }
        // The map lives in the engine actor, so this hop is unavoidable.
        let engine = engineForDownload[id] ?? engine
        Task { [weak self] in
            let map = await engine?.segmentMap(for: id)
            guard self != nil else { return }
            try? store.save(
                id: id, request: request, state: item.state,
                bytesDownloaded: item.bytesDownloaded, segmentMap: map,
                allFiles: self?.torrentFiles[request.infoHashHex.lowercased()],
                // Where the file landed, so a later launch can tell "deleted"
                // from "never knew where to look" without re-deriving a path
                // that a rename or a `(2)` suffix has already moved.
                finalURL: item.finalURL,
                // Survives the relaunch, so "why did this fail?" is answerable
                // the next morning and not only in the banner that showed it.
                lastError: item.errorMessage)
        }
    }

    /// Progress arrives ~10 times a second per download; writing each one
    /// would pin the main thread on SwiftData for no benefit. A few seconds of
    /// lost progress on a crash costs nothing — the partial file on disk is
    /// the source of truth at recovery, not this number (`LaunchRecovery`).
    private static let progressPersistInterval: TimeInterval = 3
    private var lastPersistedProgress: [DownloadID: Date] = [:]

    private func persistProgressOccasionally(_ id: DownloadID) {
        let now = Date()
        if let last = lastPersistedProgress[id],
           now.timeIntervalSince(last) < Self.progressPersistInterval {
            return
        }
        lastPersistedProgress[id] = now
        persist(id)
    }

    /// Rebuilds rows saved by a previous run.
    ///
    /// `LaunchRecovery` decides each row's state against the partial file on
    /// disk, which is authoritative — a record claiming 400 MB whose file holds
    /// 120 MB comes back at 120 MB. Nothing is auto-resumed; an interrupted
    /// download returns paused and waits for the user.
    private func restoreDownloads() async {
        guard let store = downloadStore else {
            report("Could not open the downloads database, so previous downloads "
                   + "were not restored. New downloads will still work but will "
                   + "not survive quitting.")
            return
        }
        guard let records = try? store.loadAll() else {
            report("The downloads database could not be read, so previous "
                   + "downloads were not restored.")
            return
        }

        for record in records {
            guard let request = record.makeRequest(),
                  let engine = engines[record.providerID] ?? engine
            else { continue }

            // Resolve the same destination the engine would, then look for the
            // partial beside it. `DestinationResolver` is pure and creates
            // nothing, unlike the engine's own `partialURL`, which also
            // pre-checks disk space and makes directories — neither of which
            // belongs in a launch-time scan.
            //
            // `renamedPath` first, matching `DownloadEngine.partialURL`. The
            // engine writes to the renamed path, so resolving the original
            // name found neither the file nor its partial and reported a
            // perfectly present download as gone. The record's own
            // `finalPath`, when it has one, beats both — it is where the file
            // actually landed, `(2)` suffix and all.
            let resolved = record.finalURL ?? (try? DestinationResolver.resolve(
                root: request.destinationRoot, subfolder: request.subfolder,
                relativePath: request.renamedPath ?? request.file.name))

            // Both files are offered, and the final one wins when it is whole.
            // Checking only the partial is what marked every finished download
            // failed — a completed download has been *moved* to its final name,
            // so its `.fetchpart` is gone by definition.
            //
            // Measured off the main actor, and with `FileSize` rather than
            // `FileManager.attributesOfItem`: that call builds the whole
            // attribute dictionary, which reads every extended attribute, and
            // `getxattr` can block in the kernel forever. See `FileSize`.
            let partial = resolved?.appendingPathExtension("fetchpart")
            let measured = await Task.detached { (FileSize.of(resolved), FileSize.of(partial)) }.value

            let outcome = LaunchRecovery.reconcile(
                state: record.state,
                recordedBytes: record.bytesDownloaded,
                expectedSize: request.file.size,
                finalSize: measured.0,
                partialSize: measured.1,
                // The map, not the file's length. A segmented download
                // preallocates its `.fetchpart` to full size before it fetches
                // anything, so measuring the file reported downloads that had
                // transferred nothing at 100% — and at 100% the resume path
                // renames those zeroes into place. See `LaunchRecovery`.
                segmentMap: record.segmentMap)

            let id = DownloadID(rawValue: record.id)
            // Handed to the row when `.enqueued` builds it, a moment from now:
            // `finalURL` is otherwise only ever set by the live `.finished`
            // event, so every restored completed row had a "Show in Finder"
            // button with nothing to show.
            //
            // `resolved` covers rows saved before `finalPath` existed. It is
            // the path this reconcile just weighed the file at, so it is the
            // best answer available for them — and giving it to `.missing` rows
            // too is what lets a re-check notice the file coming back.
            if let landed = record.finalURL ?? (outcome.state == .completed
                                                || outcome.state == .missing ? resolved : nil) {
                restoredFinalURLs[id] = landed
            }
            if outcome.state == .failed, let reason = record.lastError, !reason.isEmpty {
                restoredErrors[id] = reason
            }
            if let finished = record.completedAt { restoredCompletionDates[id] = finished }
            restoredCreationDates[id] = record.createdAt
            requestForDownload[id] = request
            invalidateGroups()
            engineForDownload[id] = engine
            providerForDownload[id] = DebridKind.kind(
                for: DebridProviderID(rawValue: record.providerID))?.displayName

            let all = record.allFiles
            if !all.isEmpty {
                torrentFiles[record.infoHash.lowercased()] = all
                invalidateGroups()
            }
            let map = record.segmentMap
            Task {
                await engine.restore(
                    id: id, request: request,
                    state: outcome.state, bytesDownloaded: outcome.bytesDownloaded,
                    segmentMap: map)
            }
        }
    }

    /// `from` is the engine whose stream produced the event, threaded through
    /// from the pump. It is how a row that nobody called `remember` for — the
    /// files a background preparation resolves to — still knows which engine
    /// controls it and which debrid to name.
    private func apply(_ event: DownloadEvent, from engine: DownloadEngine? = nil) {
        switch event {
        case .enqueued(let id, let filename, let totalBytes):
            if let engine {
                engineForDownload[id] = engine
                if providerForDownload[id] == nil {
                    providerForDownload[id] = engineNames[ObjectIdentifier(engine)]
                }
            }
            if !items.contains(where: { $0.id == id }) {
                invalidateGroups()
                items.append(DownloadItem(
                    id: id, displayName: filename, bytesDownloaded: 0,
                    totalBytes: totalBytes, bytesPerSecond: 0, state: .queued,
                    finalURL: restoredFinalURLs.removeValue(forKey: id),
                    errorMessage: restoredErrors.removeValue(forKey: id),
                    addedAt: restoredCreationDates.removeValue(forKey: id) ?? Date(),
                    completedAt: restoredCompletionDates.removeValue(forKey: id),
                    pinnedUnit: ByteCount.pinnedUnit(for: totalBytes)
                ))
            }
            // The engine holds the only copy of the request, and `.enqueued`
            // carries just a name and a size — not enough to resume from.
            if requestForDownload[id] == nil, let engine = engineForDownload[id] ?? engine {
                Task { [weak self] in
                    guard let request = await engine.request(for: id) else { return }
                    self?.requestForDownload[id] = request
                    self?.invalidateGroups()
                    self?.persist(id)
                }
            }
        case .stateChanged(let id, let state):
            update(id) {
                $0.state = state
                // A row that is moving again is no longer explained by why it
                // stopped. `.failed` arrives via the `.failed` case below,
                // which is what sets the reason in the first place.
                if state != .failed { $0.errorMessage = nil }
            }
            persist(id)
        case .progress(let id, let bytes, let total, let reportedRate):
            let rate = throughput(for: id, bytes: bytes, reportedRate: reportedRate)
            update(id) {
                $0.bytesDownloaded = bytes
                $0.totalBytes = total
                $0.bytesPerSecond = rate
            }
            persistProgressOccasionally(id)
        case .finished(let id, let url):
            update(id) { $0.state = .completed; $0.finalURL = url; $0.completedAt = Date() }
            notifier.downloadFinished(
                name: items.first { $0.id == id }?.displayName ?? url.lastPathComponent)
            rateEstimators[id] = nil
            persist(id)
        case .failed(let id, let error):
            // `DownloadError` is `LocalizedError` now, so this is a sentence
            // rather than "The operation couldn't be completed.
            // (FetchKit.DownloadError error 6.)" — which is what a failed
            // download used to say, in a banner that then scrolled away with
            // the only account of what happened.
            let reason = error.errorDescription ?? error.localizedDescription
            update(id) { $0.state = .failed; $0.errorMessage = reason }
            let name = items.first { $0.id == id }?.displayName ?? "A download"
            report("\(name) failed: \(reason)")
            rateEstimators[id] = nil
            persist(id)
        case .removed(let id):
            items.removeAll { $0.id == id }
            invalidateGroups()
            rateEstimators[id] = nil
            requestForDownload[id] = nil
            engineForDownload[id] = nil
            try? downloadStore?.remove(id: id)

        case .preparationStarted(let id, let name, let groupKey):
            guard !preparations.contains(where: { $0.id == id }) else { return }
            preparations.append(Preparation(
                id: id, name: name, groupKey: groupKey, progress: nil,
                providerName: preparingProvider[id]?.provider.displayName ?? ""))

        case .preparationProgress(let id, let progress):
            guard let index = preparations.firstIndex(where: { $0.id == id }) else { return }
            preparations[index].progress = progress

        case .preparationFinished(let id):
            // The row does not disappear so much as become its files: the
            // engine enqueues them under the same `groupKey` in the same turn,
            // so what the user sees is one row that stops preparing and starts
            // downloading.
            finishPreparation(id)

        case .preparationCancelled(let id):
            finishPreparation(id)

        case .preparationFailed(let id, let error):
            let name = preparations.first { $0.id == id }?.name ?? "A torrent"
            finishPreparation(id)
            report("\(name) could not be prepared: "
                   + (error.errorDescription ?? error.localizedDescription))
        }
    }

    private func finishPreparation(_ id: PreparationID) {
        preparations.removeAll { $0.id == id }
        engineForPreparation[id] = nil
        preparingProvider[id] = nil
    }

    private func throughput(for id: DownloadID, bytes: Int64, reportedRate: Double) -> Double {
        if reportedRate > 0 { return reportedRate }
        var estimator = rateEstimators[id] ?? RateEstimator()
        let rate = estimator.update(bytes: bytes)
        rateEstimators[id] = estimator
        return rate
    }

    private func update(_ id: DownloadID, _ mutate: (inout DownloadItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        mutate(&items[index])
        invalidateGroups()
    }

    // MARK: - Search

    /// Runs a query against every active sub-indexer that has a stored key,
    /// streaming results in as each one answers rather than blocking on the
    /// slowest.
    ///
    /// Cache badges are checked per arriving batch, not once at the end, so a
    /// fast indexer's rows resolve while a slow one is still running.
    func runSearch(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // Explicitly cleared, not just superseded — a pill tap afterward
            // must not resurrect it. See `selectCategory`.
            lastSearchQuery = ""
            resetSearch(to: .noQuery)
            return
        }

        let providers = configuredSearchProviders(for: searchCategory)
        guard !providers.isEmpty else {
            // "Add a Torznab endpoint" is the wrong advice for someone who has
            // three and has reserved all of them for other pills.
            resetSearch(to: configuredSearchProviders(for: .all).isEmpty
                ? .noProviders : .noProvidersForArea)
            return
        }

        // The query behind whatever is currently on screen — `selectCategory`
        // reads this rather than the live text field, so a pill tap re-runs
        // the search that actually produced the results being looked at, not
        // whatever happens to be typed (or not typed) at the moment.
        lastSearchQuery = trimmed

        // A new query supersedes one still in flight; without this its events
        // keep folding into state the user has moved on from.
        searchTask?.cancel()
        resetSearch(to: .searching)

        let serverByIndexer = Dictionary(
            activeIndexers.map { ($0.indexer.id, $0.server.id) },
            uniquingKeysWith: { first, _ in first })

        let aggregator = SearchAggregator(
            providers: providers,
            // **The one the user set.** There are two clocks on a search: the
            // URL session's, and this one, which cancels the provider from
            // outside. Raising only the first did nothing, because whichever is
            // shorter decides — so a 90-second setting still gave up at 20.
            perProviderTimeout: indexerTimeout,
            profile: qualityProfile,
            excludeAdult: safeSearch)
        let safeSearch = self.safeSearch
        let category = self.searchCategory
        pagedCategory = category
        pagesLoaded = 1
        let task = Task { [weak self] in
            // The query reaches the accumulator because 7d's primary sort
            // key is how closely a title answers it. Without it the streaming
            // path ranks on quality alone while the batch path does not, and
            // the two would silently disagree.
            var accumulator = StreamedResultAccumulator(
                profile: self?.qualityProfile ?? .default, query: trimmed,
                excludeAdult: safeSearch)

            for await event in aggregator.stream(SearchQuery(
                text: trimmed, categories: category.torznabCategories,
                limit: Self.searchPageSize)) {
                guard let self, !Task.isCancelled else { return }
                let fresh = accumulator.apply(event)
                // Held past this loop, so a second page folds into the same
                // dedupe and ranking instead of being appended raw.
                self.searchAccumulator = accumulator
                self.applySearch(accumulator, freshHashes: fresh)

                // Latency lands on the sub-indexer so Settings can show it
                // without running its own probe.
                switch event {
                case .succeeded(let id, _, let latency):
                    if let server = serverByIndexer[id] {
                        self.recordProbe(
                            server: server, indexer: id, latency: latency, failure: nil)
                    }
                case .failed(let id, let error, let latency):
                    if let server = serverByIndexer[id] {
                        self.recordProbe(
                            server: server, indexer: id, latency: latency,
                            failure: (error as? SearchError)?.errorDescription
                                ?? error.localizedDescription)
                    }
                default:
                    break
                }
            }
        }
        searchTask = task
        await task.value
    }

    /// Fetches the next page of the search on screen and folds it in.
    ///
    /// Called by the results list when the bottom comes into view. Safe to
    /// call repeatedly: it is a no-op while a page is in flight, once a page
    /// has come back empty, and after a failure until the user retries.
    func loadMoreResults() async {
        guard canLoadMore, !isLoadingMore, var accumulator = searchAccumulator,
              !lastSearchQuery.isEmpty
        else { return }

        // `pagedCategory`, not the lit pill: page 2 has to come from the same
        // set of indexers page 1 did, or an offset means nothing.
        let providers = configuredSearchProviders(for: pagedCategory)
        guard !providers.isEmpty else { return }

        isLoadingMore = true
        loadMoreFailed = false
        let before = accumulator.resultCount

        let aggregator = SearchAggregator(
            providers: providers,
            // **The one the user set.** There are two clocks on a search: the
            // URL session's, and this one, which cancels the provider from
            // outside. Raising only the first did nothing, because whichever is
            // shorter decides — so a 90-second setting still gave up at 20.
            perProviderTimeout: indexerTimeout,
            profile: qualityProfile,
            excludeAdult: safeSearch)
        // The category the loaded pages were fetched under, not whichever pill
        // is lit now: a pill tap re-runs the whole search from page 1
        // (`selectCategory`), so a page 2 under a different category would be
        // page 2 of a search nobody ran.
        let query = SearchQuery(
            text: lastSearchQuery, categories: pagedCategory.torznabCategories,
            limit: Self.searchPageSize)
        // Per provider, from what each has actually delivered — not
        // `page × pageSize`, which assumes every source handed over exactly
        // what it was asked for. They clamp, so it skipped whatever the
        // difference was. See `SearchAggregator.stream(_:offsets:)`.
        let offsets = accumulator.deliveredCounts

        loadMoreTask?.cancel()
        let task = Task { [weak self] in
            for await event in aggregator.stream(query, offsets: offsets) {
                guard let self, !Task.isCancelled else { return }
                let fresh = accumulator.apply(event, appending: true)
                self.searchAccumulator = accumulator
                self.applySearch(accumulator, freshHashes: fresh)
            }
        }
        loadMoreTask = task
        await task.value

        guard !task.isCancelled else { return }
        isLoadingMore = false
        pagesLoaded += 1

        let added = (searchAccumulator?.resultCount ?? before) - before
        // A page that told us nothing is the end of the list. Nothing else
        // says so reliably: Torznab indexers vary on whether they report a
        // total, and one source's `next` says nothing about the others.
        canLoadMore = added > 0
        // A page where every provider failed is not an empty page — it is a
        // page nobody answered, and the user should be able to ask again.
        if let accumulator = searchAccumulator,
           accumulator.failures.count == accumulator.total, accumulator.total > 0 {
            loadMoreFailed = true
            canLoadMore = true
            // Not counted: retrying must ask for the same offset again, not
            // skip past a page that never arrived.
            pagesLoaded -= 1
        }
    }

    /// Stops a search in flight and keeps whatever has already arrived.
    ///
    /// **The indexers are the slow part and some of them never answer.** A
    /// Torznab search fans out to every configured indexer and finishes when
    /// the last one does, so one unreachable server held the whole screen in
    /// `.searching` until its request timed out — with results from the others
    /// already on screen and no way to say "that is enough".
    ///
    /// Cancelling keeps the results rather than clearing them: they came from
    /// indexers that did answer, and throwing them away would make stopping a
    /// slow search cost more than waiting for it. The state settles on what is
    /// actually there, which is why it is not simply `.results`.
    func cancelSearch() {
        guard searchScreenState == .searching else { return }
        searchTask?.cancel()
        searchTask = nil
        searchProgress = nil
        searchScreenState = searchResults.isEmpty ? .noResults : .results
    }

    /// Selects a category, and re-runs the last query under it if there is
    /// one to re-run.
    ///
    /// The pill always repaints: `searchCategory` is assigned unconditionally
    /// once the tap is a real change, so the tapped pill is always the one
    /// that lights up, whether or not a search follows. Only *running* the
    /// search is conditional, on `lastSearchQuery` — reads that, never a live
    /// text field, because a field can be edited or cleared without
    /// re-submitting, and `searchResults` would then belong to a different
    /// query than whatever the pill sent. When it's empty there is nothing
    /// on screen for the new pill to disagree with, so there is nothing to
    /// go back to the sources for.
    func selectCategory(_ category: SearchCategory) async {
        guard category != searchCategory else { return }
        searchCategory = category
        guard !lastSearchQuery.isEmpty else { return }
        await runSearch(lastSearchQuery)
    }

    /// Carries the pre-7d Gutenberg format preference into the profile.
    ///
    /// Deleting the old key without this would silently reset a preference
    /// the user had set — the same failure the `QualityProfile` v1 migration
    /// exists to prevent, one setting over. Runs once: the key is removed
    /// after it is read.
    private func migrateBookFormatPreference() {
        guard let raw = UserDefaults.standard.stringArray(forKey: Self.gutenbergFormatsKey)
        else { return }
        defer { UserDefaults.standard.removeObject(forKey: Self.gutenbergFormatsKey) }

        // Only the winner was ever settable through the old picker, so only
        // the winner is carried. Promoting it keeps the rest of the profile's
        // order — which the user may also have set — rather than rebuilding
        // the tail from a Gutenberg-shaped list.
        guard let chosen = raw.compactMap(BookFormat.init(rawValue:)).first,
              let format = chosen.documentFormat else { return }

        var order = qualityProfile.documentFormatOrder
        guard let index = order.firstIndex(of: format), index != 0 else { return }
        order.remove(at: index)
        qualityProfile.documentFormatOrder = [format] + order
    }

    private func resetSearch(to state: SearchScreenState) {
        searchScreenState = state
        searchResults = []
        filteredOutResults = []
        resultsVersion &+= 1
        // A new query's pages are not this query's pages. Left behind, the
        // footer would fetch page 2 of a search that is no longer on screen.
        loadMoreTask?.cancel()
        loadMoreTask = nil
        searchAccumulator = nil
        pagesLoaded = 0
        isLoadingMore = false
        canLoadMore = false
        loadMoreFailed = false
        searchBanner = nil
        searchFailureDetail = nil
        searchProgress = nil
        // A new query's facets are about different content; carrying the old
        // selection over would silently hide most of the new results.
        facetSelection.clear()
        cachedOnly = cachedOnlyDefault
        showsFilteredResults = false
        // A selected row from the old result set is a dangling `ResultID`
        // once `searchResults` is replaced — same reasoning as clearing
        // `facetSelection` above, applied to a single row instead of a set
        // of filters.
        selectedResultID = nil
    }

    /// Folds one accumulator snapshot into published state.
    ///
    /// The screen leaves `.searching` as soon as *any* provider has answered
    /// with something, so results render while the rest are still running —
    /// the empty and all-failed verdicts can only be reached once every
    /// provider has reported.
    private func applySearch(_ accumulator: StreamedResultAccumulator, freshHashes: [String]) {
        searchResults = accumulator.results
        filteredOutResults = accumulator.filtered
        resultsVersion &+= 1

        searchProgress = accumulator.isFinished
            ? nil
            : (completed: accumulator.completed, total: accumulator.total)

        if !accumulator.results.isEmpty {
            searchScreenState = .results
            // Offered as soon as the first page settles. Whether there is
            // actually more is not knowable until a page comes back empty —
            // see `loadMoreResults`, which is what turns this off.
            if accumulator.isFinished, !isLoadingMore { canLoadMore = true }
        } else if accumulator.isFinished {
            searchScreenState = accumulator.failures.count == accumulator.total && accumulator.total > 0
                ? .allFailed
                : .noResults
        }

        if !accumulator.failures.isEmpty {
            searchFailureDetail = accumulator.failures
                .map { "\(indexerName(for: $0.key) ?? $0.key.rawValue): \($0.value.localizedDescription)" }
                .sorted()
                .joined(separator: "\n\n")

            // Only once the run is over: "2 of 7 failed" mid-flight would count
            // against indexers that simply have not answered yet.
            if accumulator.isFinished, accumulator.failures.count < accumulator.total {
                searchBanner =
                    "\(accumulator.failures.count) of \(accumulator.total) indexers failed"
            }
        }

        // No store means no debrid provider, which the Search screen reports
        // through `cacheReadiness` — the badges stay `.unchecked` rather than
        // being silently filled in with a guess.
        // **Only once the results have stopped arriving.** Checking during the
        // stream competed with the search for the same seconds and re-ordered
        // the window on every batch — and the answer for a row that has not
        // been ranked yet is an answer for a row nobody is looking at. The
        // list paints first; the badges fill in behind it.
        // `freshHashes` is deliberately *not* consulted. It is what the batch
        // that just arrived brought in, and the finishing event brings in
        // nothing — so requiring both it and `isFinished` was a condition that
        // could never hold, and no badge was ever checked at all. The window
        // below works from the ranked list and dedupes for itself; the hashes
        // this event happened to carry are none of its business.
        guard cacheStatusStore != nil, accumulator.isFinished else { return }
        requestCacheChecks(throughIndex: 0)
    }

    /// Builds a live `TorznabProvider` per active sub-indexer, keyed by its
    /// **server's** credential. A server whose key was deleted out from under
    /// it (or never saved) is silently excluded rather than sent keyless,
    /// matching `SearchProvider`'s "no auth" not being a supported state for
    /// Torznab.
    ///
    /// `category` is the pill the search is running under, because Torznab
    /// indexers can be reserved for particular areas in Settings. The two
    /// keyless built-ins are unscoped: they answer for what they carry through
    /// their own `participates(in:)`, and there is nothing in the edit sheet to
    /// reserve them with.
    private func configuredSearchProviders(
        for category: SearchCategory
    ) -> [any SearchProvider] {
        var built: [any SearchProvider] = []

        // Internet Archive needs no key and no debrid, so it is on unless the
        // user turns it off — the only source here that works out of the box.
        if searchesInternetArchive {
            built.append(InternetArchiveProvider(
                client: HTTPClient(allowedHosts: [InternetArchiveProvider.host])))
        }

        // Same terms as Internet Archive: no key, no account, no debrid.
        if searchesGutenberg {
            built.append(GutenbergProvider(
                client: HTTPClient(allowedHosts: [
                    GutenbergProvider.apiHost, GutenbergProvider.fileHost,
                ]),
                languages: gutenbergLanguageCodes,
                includesSupplementary: gutenbergIncludesSupplementary))
        }

        built.append(contentsOf: torznabProviders(for: category))
        return built
    }

    /// One `URLSession` per indexer server, reused across searches.
    ///
    /// Keyed by server so two servers cannot share a connection pool, and
    /// rebuilt when the timeout changes because a session's timeout is fixed at
    /// construction.
    private var indexerSessions: [IndexerServerID: (timeout: TimeInterval, session: URLSession)] = [:]

    private func indexerSession(for server: IndexerServerID) -> URLSession {
        if let existing = indexerSessions[server], existing.timeout == indexerTimeout {
            return existing.session
        }
        // Headroom over `perProviderTimeout`, which is the same number. Equal
        // clocks race, and the session winning turns an honest "gave up after
        // 60s" into a retried transport error — see
        // `HTTPClient.sessionTimeout(outlasting:)`.
        let session = HTTPClient.makeIndexerSession(
            requestTimeout: HTTPClient.sessionTimeout(outlasting: indexerTimeout))
        indexerSessions[server] = (indexerTimeout, session)
        return session
    }

    private func torznabProviders(for category: SearchCategory) -> [any SearchProvider] {
        activeIndexers(for: category).compactMap { server, indexer in
            guard let key = try? credentialStore.read(for: serverAccount(server.id)),
                  !key.isEmpty else { return nil }
            return TorznabProvider(
                id: indexer.id,
                displayName: "\(server.displayName) · \(indexer.name)",
                baseURL: indexer.torznabURL, apiKey: Redacted(key),
                // **One session for the whole server**, not one per indexer.
                // Eleven indexers meant eleven connection pools, so the
                // per-host connection limit applied eleven times over and
                // bounded nothing — eleven handshakes per search against a
                // server that is often a Raspberry Pi.
                client: HTTPClient(session: indexerSession(for: server.id)),
                capsStore: torznabCapsStore
            )
        }
    }

    private func serverAccount(_ id: IndexerServerID) -> CredentialAccount {
        CredentialAccount(layer: "search", providerID: id.rawValue)
    }

    // MARK: - Cache badges, in the order they are read

    /// How far past the last row anyone has looked to keep checking.
    ///
    /// Roughly two screenfuls, and one TorBox request: `checkCached` batches
    /// 50 hashes per call, so a window of this size is a single round trip
    /// rather than a queue of them.
    private static let cacheLookahead = 60

    /// Hashes already handed to the store, so scrolling does not ask twice.
    private var requestedCacheHashes: Set<String> = []
    /// How far down the displayed list the badges have been asked for.
    private var cacheCheckedThrough = -1

    /// Asks for cache status down to `index`, plus a lookahead.
    ///
    /// **Why this is not "check everything that arrived".** It was, and the
    /// hashes went over in the order the *indexer* returned them, which has
    /// nothing to do with the order they are ranked into on screen. At 50
    /// results that was one batch and invisible. Asking the indexer for
    /// everything it has made it 473, ten batches four at a time — and the
    /// badge for the top row could genuinely be in the last one. The whole
    /// list resolved before the part anyone was looking at.
    ///
    /// Now it goes in display order and stops at the horizon, extending as
    /// rows come into view.
    func requestCacheChecks(throughIndex index: Int) {
        guard let cacheStatusStore else { return }
        let horizon = index + Self.cacheLookahead
        // Only when the horizon actually moves. `visibleResults` re-facets and
        // re-sorts the whole set, and this is called from rows appearing —
        // recomputing it once per row at 473 rows is its own stall.
        guard horizon > cacheCheckedThrough else { return }
        cacheCheckedThrough = horizon

        let wanted = visibleResults.prefix(horizon)
            .compactMap { $0.infoHashHex?.lowercased() }
            .filter { requestedCacheHashes.insert($0).inserted }
        guard !wanted.isEmpty else { return }
        Task { await cacheStatusStore.check(hashes: wanted) }
    }

    /// Re-runs the cache check for one hash, ignoring the TTL — what an
    /// `.error` badge's click-to-retry calls (§12.1).
    func retryCacheCheck(hash: String) {
        guard let cacheStatusStore else { return }
        Task { await cacheStatusStore.retry(hash: hash) }
    }

    /// Dismisses the "N of M indexers failed" banner without affecting the
    /// loaded results — the failure is non-blocking by design (§7).
    func dismissSearchBanner() {
        searchBanner = nil
    }

    /// The file picker's preview list for a cached result — a single-hash
    /// `listFiles: true` call, deliberately made directly against the
    /// provider (not `CacheStatusStore`, which always uses the cheap
    /// `listFiles: false` badge form, and not `DownloadEngine`, which has
    /// no side-effect-free preview operation). No side effects: this does
    /// not add anything to the user's account (§6).
    /// Asks the provider the download would actually go to, using **that**
    /// service's own preview mechanism.
    ///
    /// It used to call `checkCached(listFiles: true)` on the primary provider,
    /// which is the TorBox shape and only the TorBox shape. Premiumize's
    /// `/cache/check` carries no file list at all, so every Premiumize result
    /// produced an empty picker — a cached hit, zero files, and a disabled
    /// Download button for a magnet that was plainly there.
    ///
    /// Returns nil when this service cannot preview without side effects, which
    /// is a legitimate answer (Real-Debrid always) and routes to Prepare.
    func previewFiles(rawMagnet: String, hash: String) async throws -> [DebridFile]? {
        guard !providers.isEmpty else { throw AppModelError.notConfigured }
        let cached = await cacheStatusStore?.cachedProviderMap() ?? [:]
        guard let chosen = DebridRouter.provider(
            for: hash, providers: providers, cachedOn: cached)
        else { throw AppModelError.notConfigured }

        if let files = try await chosen.previewFiles(rawMagnet: rawMagnet, infoHashHex: hash) {
            return files
        }

        // The debrid could not preview — Real-Debrid never can, and the others
        // cannot for an uncached torrent. The torrent's own metadata still
        // lists its files, and fetching it is a plain HTTPS GET rather than
        // joining the swarm, which would announce the user's IP to every peer
        // sharing it. Best-effort: a miss simply routes to Prepare as before.
        guard let files = await metadataFetcher.files(forInfoHash: hash), !files.isEmpty
        else { return nil }

        return files.map { file in
            DebridFile(
                // No debrid ids exist yet — nothing has been added anywhere.
                // Selections resolve by relative path anyway (§6), which is
                // exactly what makes this list usable.
                id: DebridFileID(rawValue: file.path),
                name: file.path,
                shortName: (file.path as NSString).lastPathComponent,
                size: file.length,
                mimeType: nil)
        }
    }

    private let metadataFetcher = TorrentMetadataFetcher()

    /// Announces a finished download when Fetch is not frontmost. See
    /// `DownloadNotifier` for why this may silently do nothing.
    private let notifier = DownloadNotifier()

    // `prepareMagnet` and the `preparedRoute` it stashed lived here, backing
    // the picker's "Prepare & choose files": submit, block until the debrid
    // had the torrent, then show a picker against its real file ids. The
    // blocking is what was reported, and §6's by-path re-resolution means the
    // real ids were never needed — a selection made against any list resolves
    // against the authoritative one at enqueue time. Both went with it.

    // MARK: - Direct downloads (amendment §2)

    /// The engine for downloads that have no debrid.
    ///
    /// Separate from the per-provider engines because there is no provider to
    /// key it on — and separate on purpose: a direct download must not queue
    /// behind a debrid transfer, since its whole advantage is skipping the
    /// wait.
    private var _directEngine: DownloadEngine?
    private var directPump: Task<Void, Never>?

    private func directEngine() -> DownloadEngine {
        if let _directEngine { return _directEngine }
        let engine = DownloadEngine(
            provider: NoDebridProvider(),
            // Was omitted, so this engine kept the built-in segment ceiling
            // regardless of the user's setting.
            segmented: SegmentedTransfer(maxSegments: segmentsPerFile),
            segmentsPerFile: segmentsPerFile,
            maxConcurrent: maxConcurrentDownloads)
        _directEngine = engine
        // Its own pump. The per-provider pumps are torn down whenever the
        // user edits their debrid list; a direct download must survive that,
        // since it never depended on a debrid in the first place.
        directPump = Task { [weak self] in
            for await event in engine.events {
                await self?.apply(event, from: engine)
            }
        }
        engineNames[ObjectIdentifier(engine)] = "Direct"
        return engine
    }

    /// Queues one or more public HTTPS files. No debrid is contacted.
    ///
    /// Returns the ids so the caller can report them; each file is its own
    /// download, matching how a torrent's files are queued individually.
    ///
    /// `contentKey` identifies *what* is being downloaded — an item id, a book
    /// id. The row's key is that plus a fresh attempt minted here, because
    /// this call is one queueing action: its files share a row, and a later
    /// call for the same content gets a row of its own rather than joining
    /// whatever the last attempt left behind.
    @discardableResult
    func enqueueDirect(
        _ files: [(name: String, size: Int64?, url: URL)],
        contentKey: String,
        groupName: String? = nil,
        subfolder: String? = nil,
        metadata: ReleaseMetadata = .unparsed
    ) async -> [DownloadID] {
        let engine = directEngine()
        let group = DownloadGroupKey(content: contentKey)
        var ids: [DownloadID] = []

        for file in files {
            let request = DownloadRequest(
                providerID: DebridProviderID(rawValue: "direct"),
                torrentID: DebridTorrentID(rawValue: "direct"),
                // A nil size is carried as 0: the engine treats 0 as "the
                // source never declared a length", which is exactly right —
                // Content-Length settles it and the bar stays indeterminate
                // until it does.
                file: DebridFile(
                    id: DebridFileID(rawValue: file.url.absoluteString),
                    name: file.name, shortName: file.name,
                    size: file.size ?? 0, mimeType: nil),
                infoHashHex: "",
                subfolder: subfolder,
                destinationRoot: downloadDirectory,
                directURL: file.url,
                groupKey: group,
                groupName: groupName,
                metadata: metadata)

            let id = await engine.enqueue(request)
            engineForDownload[id] = engine
            providerForDownload[id] = "Direct"
            // Recorded here rather than left to the lazy fill on `.enqueued`:
            // that fill asks `engineForDownload[id]`, which is not set until
            // this line, so it fell through to the primary debrid engine and
            // found nothing. The row then had no filename and rendered as
            // "1 files".
            requestForDownload[id] = request
            invalidateGroups()
            persist(id)
            ids.append(id)
        }
        return ids
    }

    /// Queues a direct result's best candidate with no sheet.
    ///
    /// The `.directDownload` presentation: a source Fetch has no picker for is
    /// still downloadable, and `candidates` is already ordered best-first.
    func enqueueBestCandidate(_ result: SearchResult) async {
        guard let url = result.candidates.first(where: \.isUsable)?.url else {
            // Not silent: a result that reached the UI with nothing reachable
            // is a parser bug, and the user is the one who can report it.
            searchBanner = "“\(result.title)” has no downloadable link."
            return
        }
        await enqueueDirect(
            [(name: url.lastPathComponent, size: result.size, url: url)],
            contentKey: result.id.rawValue,
            groupName: result.title,
            subfolder: subfolder(for: result.metadata),
            metadata: result.metadata)
    }

    func copyMagnet(_ result: SearchResult) {
        guard let magnet = result.magnetURI else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(magnet, forType: .string)
        // Copying changed nothing on screen, so the only way to find out
        // whether the click had registered was to paste it somewhere.
        copyToast.show("Magnet link copied")
    }

    /// The fading confirmation for actions with nothing else to show for
    /// themselves. Owned here rather than by a view so the model can announce
    /// a copy made from a context menu, a button, or a keyboard shortcut
    /// without three of them each keeping their own.
    let copyToast = CopyToast()

    // `enqueueSelected(prepared:)` lived here, the second half of the picker's
    // submit-then-choose flow. It went with `prepareMagnet`: nothing produces
    // a `PreparedMagnet` in the app any more, because nothing blocks waiting
    // for one.

    /// Submits a magnet and resolves `selecting` (paths chosen against a
    /// **preview** file list) against the authoritative one by relative
    /// path (§6) — the cached-result path through the file picker, where
    /// there is no `PreparedMagnet` yet because the magnet has not been
    /// submitted before this call.
    func enqueueMagnetSelecting(
        _ rawMagnet: String, selecting: Set<String>?, subfolder: String? = nil,
        metadata: ReleaseMetadata = .unparsed
    ) async throws -> SelectiveEnqueueResult {
        let routed = try await route(rawMagnet)
        let outcome = try await routed.engine.enqueueMagnet(
            rawMagnet, subfolder: subfolder, destinationRoot: downloadDirectory,
            selecting: selecting, rename: renamePlan(torrentMetadata: metadata),
            groupName: metadata.title,
            metadata: metadata
        )
        for id in outcome.downloadIDs { remember(id, routed) }
        return outcome
    }

    // MARK: - Debrid configuration (Settings § Debrid)

    /// Builds a live provider for a configured debrid, or nil when its key is
    /// missing — the same rule the search layer uses: no key means excluded,
    /// never sent unauthenticated.
    private func makeProvider(_ id: DebridProviderID) -> (any DebridProvider)? {
        guard let key = try? credentialStore.read(
            for: CredentialAccount(layer: "debrid", providerID: id.rawValue)),
              !key.isEmpty
        else { return nil }

        // The service table builds it. This used to be a switch on the raw id
        // string, spelled again in `SettingsView.testConnection` — two places
        // to edit for a fourth debrid, and two that could disagree.
        return DebridKind.kind(for: id)?.makeProvider(Redacted(key), HTTPClient())
    }

    /// Stores a debrid's key and rebuilds the provider set.
    ///
    /// Refuses while downloads are active: rebuilding replaces
    /// `DownloadEngine`, orphaning existing rows against an engine that has
    /// no record of them.
    func saveDebridKey(_ apiKey: String, for id: DebridProviderID) throws {
        guard !hasActiveDownloads else {
            throw AppModelError.activeDownloadsPreventReconfigure
        }
        try credentialStore.store(
            apiKey, for: CredentialAccount(layer: "debrid", providerID: id.rawValue))
        if !debridConfigs.contains(where: { $0.id == id }) {
            debridConfigs.append(DebridConfig(id: id))
        }
        persistDebridConfigs()
        configureProviders()
        // **Ask it something straight away.** Coverage is what the status dot
        // and the rail read, and nothing refreshed it after a key was saved —
        // so a service tested and accepted a second ago stayed amber, and the
        // rail said "2 of 3", until Settings was left and re-entered. Forced,
        // because the six-hour cache would otherwise answer for the provider
        // this key just replaced.
        Task {
            // Health first, because it is what the dot and the rail read. Both
            // were left stale by a saved key, so a service tested and accepted
            // a second ago kept whatever it was showing until Settings was left
            // and re-entered.
            await refreshServiceHealth()
            await refreshHostCoverage(force: true)
        }
    }

    /// Removes a provider and its key.
    ///
    /// Throws rather than returning quietly: this used to be
    /// `guard !hasActiveDownloads else { return }`, so with any download
    /// anywhere in a non-terminal state the Remove button did nothing at all
    /// and said nothing about why.
    ///
    /// The check is also scoped to *this* provider now. A queued download on
    /// TorBox is no reason to refuse removing Premiumize — its rows do not
    /// belong to the engine being torn down.
    func removeDebrid(_ id: DebridProviderID) throws {
        guard !hasActiveDownloads(on: id) else {
            throw AppModelError.providerHasActiveDownloads(
                DebridKind.kind(for: id)?.displayName ?? id.rawValue)
        }
        debridConfigs.removeAll { $0.id == id }
        try? credentialStore.delete(
            for: CredentialAccount(layer: "debrid", providerID: id.rawValue))
        persistDebridConfigs()
        configureProviders()
    }

    /// Whether this provider owns any row that is still going.
    func hasActiveDownloads(on id: DebridProviderID) -> Bool {
        let name = DebridKind.kind(for: id)?.displayName
        return items.contains { item in
            guard !item.state.isTerminal else { return false }
            // Rows are tagged with the provider they were routed to; an
            // untagged one predates routing and is conservatively counted.
            guard let owner = providerForDownload[item.id] else { return true }
            return owner == name
        }
    }

    func setDebridEnabled(_ id: DebridProviderID, isEnabled: Bool) {
        guard let index = debridConfigs.firstIndex(where: { $0.id == id }) else { return }
        debridConfigs[index].isEnabled = isEnabled
        persistDebridConfigs()
        configureProviders()
        // Switching one on adds a service nobody has asked anything yet.
        Task { await refreshServiceHealth() }
    }

    /// Reorders preference. Lower index wins in `DebridRouter`, all else equal.
    /// Makes one service the preferred one by moving it to the top.
    ///
    /// **The order already was the preference** — `DebridRouter` walks
    /// `providers` in order and takes the first that will do — and nothing on
    /// screen said so, so the service that wins a tie was invisible unless you
    /// guessed that dragging the list meant something. A star that reorders
    /// says it out loud without inventing a second notion of "primary" that
    /// could then disagree with the order.
    func makePrimaryDebrid(_ id: DebridProviderID) {
        guard let index = debridConfigs.firstIndex(where: { $0.id == id }), index != 0 else {
            return
        }
        let config = debridConfigs.remove(at: index)
        debridConfigs.insert(config, at: 0)
        persistDebridConfigs()
        configureProviders()
    }

    func moveDebrid(from source: IndexSet, to destination: Int) {
        debridConfigs.move(fromOffsets: source, toOffset: destination)
        persistDebridConfigs()
        configureProviders()
    }

    func hasStoredKey(for id: DebridProviderID) -> Bool {
        let key = try? credentialStore.read(
            for: CredentialAccount(layer: "debrid", providerID: id.rawValue))
        return !(key ?? "").isEmpty
    }

    private func persistDebridConfigs() {
        guard let data = try? JSONEncoder().encode(debridConfigs) else {
            // Encoding a Codable value type should not fail, but if it does the
            // change is lost on quit and the user has no way to know.
            report("Your debrid providers could not be saved and will be lost when Fetch quits.")
            return
        }
        UserDefaults.standard.set(data, forKey: Self.debridConfigsDefaultsKey)
    }

    /// Reads the configured list; on a miss, adopts a stored TorBox key from
    /// before this list existed. Same rule as the indexer migration: read the
    /// old location, never destroy it.
    private func loadDebridConfigs() -> [DebridConfig] {
        if let data = UserDefaults.standard.data(forKey: Self.debridConfigsDefaultsKey),
           let configs = try? JSONDecoder().decode([DebridConfig].self, from: data) {
            return configs
        }
        let torbox = Self.credentialAccount
        if let key = try? credentialStore.read(for: torbox), !(key ?? "").isEmpty {
            return [DebridConfig(id: DebridProviderID(rawValue: "torbox"))]
        }
        return []
    }

    // MARK: - Indexer server configuration (Settings § Search)

    /// Adds a whole server. A standalone Torznab endpoint is stored the same
    /// way — as a server with exactly one sub-indexer — so the search path
    /// never branches on which kind it is.
    ///
    /// The key is written **once**, under the server's id, before the config
    /// is persisted: if that write fails, nothing is added. The flat model this
    /// replaces wrote one copy per indexer inside a loop, so a failure midway
    /// left orphaned secrets and no config at all.
    @discardableResult
    func addIndexerServer(
        displayName: String,
        rootURL: URL,
        indexers: [SubIndexer],
        apiKey: String,
        replacing: IndexerServerID? = nil
    ) throws -> IndexerServerID {
        let id = IndexerServerID(rawValue: UUID().uuidString)
        try credentialStore.store(apiKey, for: serverAccount(id))

        if let replacing { removeIndexerServer(id: replacing) }
        indexerServers.append(IndexerServerConfig(
            id: id, displayName: displayName, rootURL: rootURL,
            isEnabled: true, indexers: indexers
        ))
        persistIndexerServers()
        clearTorznabCaps()
        return id
    }

    /// Edits a server's non-secret fields; rotates its stored key only when
    /// `apiKey` is non-nil (the edit sheet leaves it blank to mean "keep the
    /// current key" — never re-rendering a saved secret back into a field).
    func updateIndexerServer(
        id: IndexerServerID, displayName: String, rootURL: URL, apiKey: String?
    ) throws {
        guard let index = indexerServers.firstIndex(where: { $0.id == id }) else { return }
        if let apiKey, !apiKey.isEmpty {
            try credentialStore.store(apiKey, for: serverAccount(id))
        }
        indexerServers[index].displayName = displayName
        indexerServers[index].rootURL = rootURL
        persistIndexerServers()
        clearTorznabCaps()
    }

    /// Reconciles a server against a fresh discovery. Indexers the server no
    /// longer lists are **marked**, not deleted: one switched off in Prowlarr
    /// for an afternoon must not lose its toggle state here.
    func reconcileIndexers(id: IndexerServerID, discovered: [SubIndexer]) {
        guard let index = indexerServers.firstIndex(where: { $0.id == id }) else { return }

        let discoveredByURL = Dictionary(
            discovered.map { ($0.torznabURL, $0) }, uniquingKeysWith: { first, _ in first })
        var merged: [SubIndexer] = []

        // **The aggregate is retired, not marked missing.** A Jackett saved
        // before discovery existed is one row pointing at
        // `…/indexers/all/…` — the same eleven trackers wearing one name. Once
        // they arrive individually that row is superseded, and keeping it would
        // park a permanent "no longer on this server" warning under a server
        // that is working fine. Only when the replacements are actually in
        // hand: a discovery that returned nothing must not delete anything.
        let supersedesAggregate = discovered.contains { !JackettDirectory.isAggregate($0.torznabURL) }
            && discovered.contains { JackettDirectory.isJackettShaped($0.torznabURL) }

        for var existing in indexerServers[index].indexers {
            if supersedesAggregate, JackettDirectory.isAggregate(existing.torznabURL) { continue }
            if let match = discoveredByURL[existing.torznabURL] {
                existing.name = match.name
                // Re-recorded, because the user changes what an indexer covers
                // in Jackett and then comes back here. `areas` is *not* touched
                // — that is the user's own answer and rediscovery has no
                // opinion on it.
                if let categories = match.advertisedCategories {
                    existing.advertisedCategories = categories
                }
                existing.isMissingFromServer = false
            } else {
                existing.isMissingFromServer = true
            }
            merged.append(existing)
        }

        let knownURLs = Set(merged.map(\.torznabURL))
        merged.append(contentsOf: discovered.filter { !knownURLs.contains($0.torznabURL) })

        indexerServers[index].indexers = merged
        persistIndexerServers()
        clearTorznabCaps()
    }

    /// Records what a probe query measured, so the edit sheet has numbers to
    /// show without re-running Test All every time it opens.
    func recordProbe(
        server: IndexerServerID, indexer: SearchProviderID,
        latency: TimeInterval, failure: String?
    ) {
        guard let s = indexerServers.firstIndex(where: { $0.id == server }),
              let i = indexerServers[s].indexers.firstIndex(where: { $0.id == indexer })
        else { return }
        indexerServers[s].indexers[i].recordProbe(latency: latency, failure: failure)
        persistIndexerServers()
    }

    func removeIndexerServer(id: IndexerServerID) {
        indexerServers.removeAll { $0.id == id }
        try? credentialStore.delete(for: serverAccount(id))
        persistIndexerServers()
        clearTorznabCaps()
    }

    func setServerEnabled(id: IndexerServerID, isEnabled: Bool) {
        guard let index = indexerServers.firstIndex(where: { $0.id == id }) else { return }
        indexerServers[index].isEnabled = isEnabled
        persistIndexerServers()
        clearTorznabCaps()
    }

    func setIndexerEnabled(
        server: IndexerServerID, indexer: SearchProviderID, isEnabled: Bool
    ) {
        guard let s = indexerServers.firstIndex(where: { $0.id == server }),
              let i = indexerServers[s].indexers.firstIndex(where: { $0.id == indexer })
        else { return }
        indexerServers[s].indexers[i].isEnabled = isEnabled
        persistIndexerServers()
        clearTorznabCaps()
    }

    // MARK: - Health

    /// Cumulative cache answers per debrid service, across sessions.
    ///
    /// Persisted because the interesting version of "how much does this
    /// service actually hold" is measured in weeks, not in the twenty minutes
    /// since launch.
    private(set) var debridCacheStats: [DebridProviderID: DebridCacheStats] = [:]
    private static let debridCacheStatsKey = "app.fetch.debridCacheStats"

    private func foldCacheStats(from store: CacheStatusStore) async {
        let drained = await store.drainHitStats()
        guard !drained.isEmpty else { return }
        for (id, delta) in drained {
            debridCacheStats[id] = (debridCacheStats[id] ?? DebridCacheStats()) + delta
        }
        persistDebridCacheStats()
    }

    private func persistDebridCacheStats() {
        let keyed = Dictionary(
            uniqueKeysWithValues: debridCacheStats.map { ($0.key.rawValue, $0.value) })
        guard let data = try? JSONEncoder().encode(keyed) else { return }
        UserDefaults.standard.set(data, forKey: Self.debridCacheStatsKey)
    }

    func loadDebridCacheStats() {
        guard let data = UserDefaults.standard.data(forKey: Self.debridCacheStatsKey),
              let keyed = try? JSONDecoder().decode([String: DebridCacheStats].self, from: data)
        else { return }
        debridCacheStats = Dictionary(
            uniqueKeysWithValues: keyed.map { (DebridProviderID(rawValue: $0.key), $0.value) })
    }

    /// Indexer rows for the Health pane, worst first.
    var indexerHealthRows: [HealthReport.IndexerRow] {
        HealthReport.indexerRows(indexerServers)
    }

    /// Debrid rows for the Health pane, best hit rate first.
    var debridHealthRows: [HealthReport.DebridRow] {
        HealthReport.debridRows(
            providers: debridConfigs.compactMap { config in
                guard let kind = DebridKind.kind(for: config.id) else { return nil }
                return (
                    id: config.id,
                    name: kind.displayName,
                    canReport: kind.canReportCacheStatus,
                    isEnabled: config.isEnabled)
            },
            stats: debridCacheStats)
    }

    /// Clears every recorded measurement, indexer and debrid alike.
    ///
    /// **One button, not two.** The reason to reset is always the same — the
    /// numbers describe a setup that no longer exists — and clearing half of
    /// them would leave a pane comparing this week's indexers against last
    /// month's debrid.
    func resetHealthStatistics() {
        for serverIndex in indexerServers.indices {
            for indexerIndex in indexerServers[serverIndex].indexers.indices {
                indexerServers[serverIndex].indexers[indexerIndex].health = nil
                indexerServers[serverIndex].indexers[indexerIndex].lastLatency = nil
                indexerServers[serverIndex].indexers[indexerIndex].lastProbeFailure = nil
                indexerServers[serverIndex].indexers[indexerIndex].lastTestedAt = nil
            }
        }
        persistIndexerServers()
        debridCacheStats = [:]
        UserDefaults.standard.removeObject(forKey: Self.debridCacheStatsKey)
    }

    /// Re-asks every configured server which indexers it has.
    ///
    /// **Because indexers are added and removed in the other app.** A tracker
    /// switched on in Jackett appeared in Fetch only if the user happened to
    /// open that server's edit sheet afterwards — and one switched off went on
    /// being queried, failing, and counting toward "1 of 11 indexers failed",
    /// until they did. Neither is something anybody would think to come here
    /// and do.
    ///
    /// Cheap enough to be automatic: one request per server, answered in 52ms
    /// by Jackett's `t=indexers` and comparably by Prowlarr's `/api/v1/indexer`
    /// — less than the caps fetch a single search already makes.
    ///
    /// Failures are silent by design. A server that is down when Fetch launches
    /// should leave the saved indexer list exactly as it is, not empty it and
    /// not raise an alarm about a search nobody has run yet. `reconcileIndexers`
    /// marks rather than deletes for the same reason.
    func refreshIndexerRosters() async {
        for server in indexerServers where server.isEnabled {
            guard let key = try? credentialStore.read(for: serverAccount(server.id)),
                  !key.isEmpty,
                  let plan = try? await IndexerSetup.plan(
                    url: server.rootURL, apiKey: Redacted(key),
                    client: HTTPClient(session: indexerSession(for: server.id)))
            else { continue }
            // A one-endpoint answer is not news for a one-endpoint server, and
            // reconciling it would rewrite the stored config on every launch.
            guard case .single = plan else {
                reconcileIndexers(
                    id: server.id,
                    discovered: Self.subIndexers(from: plan, serverName: server.displayName))
                continue
            }
        }
    }

    /// The `SubIndexer` list a discovery plan describes.
    ///
    /// Shared with the edit sheet so a roster refreshed in the background and
    /// one refreshed by pressing Save cannot describe the same server
    /// differently.
    static func subIndexers(
        from plan: IndexerSetup.Plan, serverName: String
    ) -> [SubIndexer] {
        switch plan {
        case .single(let url, _):
            [SubIndexer(
                id: SearchProviderID(rawValue: UUID().uuidString),
                name: serverName, torznabURL: url)]
        case .prowlarr(let root, let indexers):
            indexers.map { indexer in
                SubIndexer(
                    id: SearchProviderID(rawValue: UUID().uuidString),
                    name: indexer.name, torznabURL: indexer.torznabURL(root: root))
            }
        // Jackett's roster carries each indexer's own caps, so what it covers
        // is known here without asking eleven endpoints for it.
        case .jackett(let root, let indexers):
            indexers.map { indexer in
                SubIndexer(
                    id: SearchProviderID(rawValue: UUID().uuidString),
                    name: indexer.name,
                    torznabURL: indexer.torznabURL(root: root),
                    advertisedCategories: indexer.categories)
            }
        }
    }

    /// Reserves an indexer for particular pills, or for all of them when
    /// `areas` is nil.
    ///
    /// Caps are **not** cleared: an indexer's advertised categories are a fact
    /// about the server, and which of them Fetch chooses to ask for is not.
    func setIndexerAreas(
        server: IndexerServerID, indexer: SearchProviderID, areas: Set<SearchCategory>?
    ) {
        guard let s = indexerServers.firstIndex(where: { $0.id == server }),
              let i = indexerServers[s].indexers.firstIndex(where: { $0.id == indexer })
        else { return }
        // Empty reads as "every area" everywhere else, so it is stored as the
        // nil that actually means it rather than as a second spelling.
        indexerServers[s].indexers[i].areas = (areas?.isEmpty ?? true) ? nil : areas
        persistIndexerServers()
    }

    /// Never rendered back into a text field once saved — same rule as the
    /// TorBox key — but Test needs it to re-validate an already-saved server.
    func indexerServerAPIKey(for id: IndexerServerID) -> String? {
        try? credentialStore.read(for: serverAccount(id))
    }

    // MARK: - Persistence and migration

    private func persistIndexerServers() {
        guard let data = try? JSONEncoder().encode(indexerServers) else {
            // Encoding a Codable value type should not fail, but if it does the
            // change is lost on quit and the user has no way to know.
            report("Your indexer servers could not be saved and will be lost when Fetch quits.")
            return
        }
        UserDefaults.standard.set(data, forKey: Self.indexerServersDefaultsKey)
    }

    /// Reads the current key; on a miss, folds the legacy flat list forward.
    ///
    /// **The legacy key is never cleared.** Two data-loss incidents on
    /// 2026-08-01 — a credential store switch and a bundle-identifier change
    /// that moved the UserDefaults domain — both stranded live state by writing
    /// somewhere new and never reading the old location again. Leaving the old
    /// key means rolling back to an earlier build still finds its data.
    private func loadIndexerServers() -> [IndexerServerConfig] {
        if let data = UserDefaults.standard.data(forKey: Self.indexerServersDefaultsKey),
           let servers = try? JSONDecoder().decode([IndexerServerConfig].self, from: data) {
            return servers
        }

        guard let legacyData = UserDefaults.standard.data(forKey: Self.searchProvidersDefaultsKey),
              let legacy = try? JSONDecoder().decode([SearchProviderConfig].self, from: legacyData),
              !legacy.isEmpty
        else { return [] }

        let migrated = IndexerServerMigration.migrate(legacy: legacy, credentials: credentialStore)
        if let data = try? JSONEncoder().encode(migrated) {
            UserDefaults.standard.set(data, forKey: Self.indexerServersDefaultsKey)
        }
        return migrated
    }

    /// Credential entries matching no current server — left behind by
    /// migration, which copies keys forward without deleting the originals.
    /// Surfaced as an explicit Settings action rather than deleted as an
    /// invisible side effect of launch.
    var unusedCredentialCount: Int {
        guard let store = credentialStore as? FileCredentialStore else { return 0 }
        return store.countSecrets(inLayer: "search", keeping: liveSearchAccounts)
    }

    func removeUnusedCredentials() {
        guard let store = credentialStore as? FileCredentialStore else { return }
        try? store.removeSecrets(inLayer: "search", keeping: liveSearchAccounts)
    }

    private var liveSearchAccounts: [CredentialAccount] {
        indexerServers.map { serverAccount($0.id) }
    }
}
