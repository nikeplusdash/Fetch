import AppKit
import Foundation
import Observation
import FetchKit


enum AppModelError: LocalizedError, Sendable {
    case notConfigured
    case activeDownloadsPreventReconfigure
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
    var errorMessage: String?

    func report(_ message: String) {
        errorMessage = message
    }

    var sidebarSection: SidebarSection = .search
    var settingsTab: SettingsTab = .appearance


    var downloadFilter: DownloadFilter = .downloads
    var libraryKind: MediaKind?

    var cloudRows: [CloudRow] = []
    var cloudLoadState: CloudLoadState = .idle

    var destinationOverrides: [String: URL] = [:]
    var indexerTimeout: TimeInterval = HTTPClient.defaultIndexerTimeout {
        didSet {
            UserDefaults.standard.set(indexerTimeout, forKey: Self.indexerTimeoutKey)
        }
    }
    private static let indexerTimeoutKey = "app.fetch.indexerTimeout"

    var serviceHealth: [DebridProviderID: ServiceHealth] = [:]

    var appearanceTheme: AppearanceTheme = .blizzard

    func navigate(to tab: SettingsTab) {
        settingsTab = tab
        sidebarSection = .settings
    }

    var windowCloseBehaviour: WindowCloseBehaviour = .ask {
        didSet {
            UserDefaults.standard.set(
                windowCloseBehaviour.rawValue, forKey: Self.closeBehaviourKey)
        }
    }

    var activeProgress: ActiveProgress? {
        ActiveProgress.of(items.map {
            (state: $0.state, downloaded: $0.bytesDownloaded, total: $0.totalBytes)
        })
    }

    private(set) var downloadDirectory: URL

    var engine: DownloadEngine?
    private let credentialStore: any CredentialStore

    private(set) var providers: [any DebridProvider] = []

    let downloadStore: DownloadStore?

    var requestForDownload: [DownloadID: DownloadRequest] = [:]

    /**
     The backoff cadence for polling each `.cloudQueued` row's torrent id.
     In memory only, like `preparations`: a relaunch asks every unfinished
     torrent once immediately.
     */
    @ObservationIgnored var cloudPollSchedule = CloudPollSchedule()

    /**
     The single running promotion pump, or `nil` when nothing is queued on
     a service. `startCloudPollIfNeeded()` owns its lifecycle.
     */
    @ObservationIgnored var cloudPollTask: Task<Void, Never>?

    /**
     The failure sentence shown on a `.cloudQueued` row's sub-line, keyed by
     download id. Observed so the row redraws when a diagnosis lands or
     clears.
     */
    var cloudDiagnoses: [DownloadID: String] = [:]

    private(set) var torrentFiles: [String: [TorrentMetadata.File]] = [:]

    func rememberTorrentFiles(_ files: [DebridFile], forHash hash: String) {
        guard !files.isEmpty else { return }
        invalidateGroups()
        torrentFiles[hash.lowercased()] = files.map {
            TorrentMetadata.File(path: $0.name, length: $0.size)
        }
    }

    func skippedFiles(for group: TorrentGroup) -> [TorrentMetadata.File] {
        let queued = Set(group.items.compactMap { requestForDownload[$0.id]?.file.name })
        return DownloadGrouping.skippedFiles(
            allFiles: torrentFiles[group.contentKey.lowercased()] ?? [], queuedPaths: queued)
    }

    private var restoredFinalURLs: [DownloadID: URL] = [:]

    private var restoredErrors: [DownloadID: String] = [:]

    private var restoredCompletionDates: [DownloadID: Date] = [:]

    private var restoredCreationDates: [DownloadID: Date] = [:]

    var engines: [String: DownloadEngine] = [:]
    private var engineForDownload: [DownloadID: DownloadEngine] = [:]

    private var engineNames: [ObjectIdentifier: String] = [:]
    private var pumps: [Task<Void, Never>] = []

    private(set) var providerForDownload: [DownloadID: String] = [:]

    private(set) var debridConfigs: [DebridConfig] = []

    private static let debridConfigsDefaultsKey = "app.fetch.debridConfigs"
    private static let maxConcurrentKey = "app.fetch.maxConcurrentDownloads"
    private static let segmentsKey = "app.fetch.segmentsPerFile"

    var maxConcurrentDownloads = 3 {
        didSet {
            UserDefaults.standard.set(maxConcurrentDownloads, forKey: Self.maxConcurrentKey)
            let value = maxConcurrentDownloads
            for engine in engines.values { Task { await engine.setMaxConcurrent(value) } }
        }
    }

    var segmentsPerFile = SegmentedTransfer.defaultSegments {
        didSet {
            UserDefaults.standard.set(segmentsPerFile, forKey: Self.segmentsKey)
            let value = segmentsPerFile
            for engine in engines.values { Task { await engine.setSegmentsPerFile(value) } }
            if let direct = _directEngine {
                Task { await direct.setSegmentsPerFile(value) }
            }
        }
    }


    private(set) var searchResults: [SearchResult] = []
    private(set) var searchBanner: String?

    private(set) var searchFailureDetail: String?
    private(set) var searchScreenState: SearchScreenState = .noQuery

    var searchFieldText = ""

    private(set) var lastSearchQuery = ""


    private(set) var searchSort: ResultSort = .seeders
    private(set) var sortDescending = true

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

    var searchCategory: SearchCategory = .all

    var cachedOnly = false

    var cachedOnlyDefault = false {
        didSet {
            UserDefaults.standard.set(cachedOnlyDefault, forKey: Self.cachedOnlyKey)
        }
    }
    private static let cachedOnlyKey = "app.fetch.cachedOnlyDefault"

    var showsFilters = false {
        didSet { UserDefaults.standard.set(showsFilters, forKey: Self.filtersKey) }
    }
    private static let filtersKey = "app.fetch.showsFilters"

    private(set) var filteredOutResults: [SearchResult] = []
    var showsFilteredResults = false

    var facetSelection = FacetSelection()

    var resultSelection = RowSelection<ResultID>()

    var downloadSelection = RowSelection<String>()

    var expandedDownloads: Set<String> = []

    var selectedResultID: ResultID? { resultSelection.selected }

    var safeSearch = true {
        didSet {
            UserDefaults.standard.set(safeSearch, forKey: Self.safeSearchKey)
            if safeSearch, searchCategory == .adult {
                searchCategory = .all
                if !lastSearchQuery.isEmpty {
                    Task { await runSearch(lastSearchQuery) }
                }
            }
        }
    }
    private static let safeSearchKey = "app.fetch.safeSearch"

    var searchesInternetArchive = true {
        didSet {
            UserDefaults.standard.set(searchesInternetArchive, forKey: Self.internetArchiveKey)
        }
    }
    private static let internetArchiveKey = "app.fetch.searchesInternetArchive"

    var archiveShowsDerivedByDefault = false {
        didSet {
            UserDefaults.standard.set(archiveShowsDerivedByDefault, forKey: Self.archiveDerivedKey)
        }
    }
    private static let archiveDerivedKey = "app.fetch.archiveShowsDerivedByDefault"

    var searchesGutenberg = true {
        didSet { UserDefaults.standard.set(searchesGutenberg, forKey: Self.gutenbergKey) }
    }
    private static let gutenbergKey = "app.fetch.searchesGutenberg"

    private static let gutenbergFormatsKey = "app.fetch.gutenbergFormatPriority"

    var gutenbergFollowsSystemLanguages = true {
        didSet {
            UserDefaults.standard.set(
                gutenbergFollowsSystemLanguages, forKey: Self.gutenbergLanguagesKey)
        }
    }
    private static let gutenbergLanguagesKey = "app.fetch.gutenbergFollowsSystemLanguages"

    var gutenbergIncludesSupplementary = false {
        didSet {
            UserDefaults.standard.set(
                gutenbergIncludesSupplementary, forKey: Self.gutenbergExtrasKey)
        }
    }
    private static let gutenbergExtrasKey = "app.fetch.gutenbergIncludesSupplementary"

    var gutenbergLanguageCodes: [String] {
        gutenbergFollowsSystemLanguages ? GutenbergLanguages.systemPreferred() : []
    }

    var routingRules: [RoutingRule] = RoutingRule.defaults {
        didSet { persistOrganization() }
    }
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


    private(set) var pluginRegistry = PluginRegistry(plugins: [])

    func subfolder(for metadata: ReleaseMetadata) -> String {
        Routing.subfolder(
            for: metadata,
            rules: pluginRegistry.routingRules(builtIn: routingRules))
    }

    func namingStrategy(for kind: MediaKind) -> NamingStrategy {
        guard renamesFiles else { return .preserveOriginal }
        return .template(pluginRegistry.namingTemplate(
            for: kind, builtIn: NamingStrategy.defaultTemplate(for: kind)))
    }

    func canRevertRename(_ id: DownloadID) -> Bool {
        guard let request = requestForDownload[id],
              items.first(where: { $0.id == id })?.state == .completed
        else { return false }
        return RenameReversal.plan(for: request) != nil
    }

    func revertRename(_ id: DownloadID) {
        guard let request = requestForDownload[id],
              let plan = RenameReversal.plan(for: request)
        else { return }

        do {
            try FileManager.default.createDirectory(
                at: plan.to.deletingLastPathComponent(), withIntermediateDirectories: true)
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

    func renamePlan(
        torrentMetadata: ReleaseMetadata
    ) -> (@Sendable (DebridFile) -> String?)? {
        guard renamesFiles else { return nil }
        return FileRenamer.plan(
            torrentMetadata: torrentMetadata,
            strategy: namingStrategy(for: torrentMetadata.mediaKind))
    }


    var qualityProfile: QualityProfile = .default {
        didSet {
            guard let data = try? JSONEncoder().encode(qualityProfile) else {
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

    @ObservationIgnored private var visibleMemo: (key: VisibleKey, value: [SearchResult])?
    @ObservationIgnored private var resultsVersion = 0
    @ObservationIgnored private var cacheStatesVersion = 0

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

    func cacheState(for group: ContentGroup) -> CacheCheckState {
        let states = group.infoHashes.compactMap { hash in
            cacheStates[hash].map { (DebridProviderID(rawValue: hash), $0) }
        }
        return DebridRouter.mergeCacheStates(Dictionary(
            states, uniquingKeysWith: { first, _ in first }))
    }

    private(set) var searchProgress: (completed: Int, total: Int)?

    private var searchTask: Task<Void, Never>?


    static let searchPageSize = 500

    private var searchAccumulator: StreamedResultAccumulator?
    private var pagedCategory: SearchCategory = .all
    private var pagesLoaded = 0

    private(set) var isLoadingMore = false

    private(set) var canLoadMore = false

    private(set) var loadMoreFailed = false

    private var loadMoreTask: Task<Void, Never>?

    private(set) var indexerServers: [IndexerServerConfig] = []

    var activeIndexers: [(server: IndexerServerConfig, indexer: SubIndexer)] {
        indexerServers.flatMap { server in
            server.activeIndexers.map { (server, $0) }
        }
    }

    func activeIndexers(
        for category: SearchCategory
    ) -> [(server: IndexerServerConfig, indexer: SubIndexer)] {
        indexerServers.flatMap { server in
            server.activeIndexers(for: category).map { (server, $0) }
        }
    }

    func indexerName(for id: SearchProviderID) -> String? {
        for server in indexerServers {
            if let indexer = server.indexers.first(where: { $0.id == id }) {
                return server.indexers.count > 1 ? indexer.name : server.displayName
            }
        }
        return nil
    }

    private(set) var cacheStates: [String: CacheCheckState] = [:]
    private var cacheStatusStore: CacheStatusStore?
    private var cachePump: Task<Void, Never>?

    var cacheReadiness: CacheReadiness {
        CacheReadiness(providers: providers)
    }

    private static let indexerServersDefaultsKey = "app.fetch.indexerServers"
    private static let searchProvidersDefaultsKey = "app.fetch.searchProviderConfigs"

    private var rateEstimators: [DownloadID: RateEstimator] = [:]

    static let testMagnet =
        "magnet:?xt=urn:btih:dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c"
        + "&dn=Big+Buck+Bunny"

    static let credentialAccount = CredentialAccount(layer: "debrid", providerID: "torbox")

    private static let downloadDirectoryDefaultsKey = "app.fetch.downloadDirectoryPath"
    private static let closeBehaviourKey = "app.fetch.windowCloseBehaviour"
    private static let closeBehaviourResetKey = "app.fetch.windowCloseBehaviourReset"

    var isConfigured: Bool { engine != nil }

    var hasActiveDownloads: Bool {
        items.contains { !$0.state.isTerminal && !$0.state.isCloudOnly } || !preparations.isEmpty
    }

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

        configureProviders()
        notifier.prepare()

        Task { await restoreDownloads() }
    }

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
                await self?.foldCacheStats(from: statusStore)
            }
        }
    }

    private func applyCacheSnapshot(_ snapshot: CacheStatusStore.Snapshot) {
        cacheStates[snapshot.hash] = snapshot.state
        cacheStatesVersion &+= 1
    }


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


    private(set) var hostCoverage: [DebridProviderID: [DebridHost]] = [:]

    private let hostsCache = SupportedHostsCache()

    private let torznabCapsStore = TorznabCapsStore()

    private func clearTorznabCaps() {
        Task { await torznabCapsStore.clear() }
    }

    func refreshHostCoverage(force: Bool = false) async {
        if force { await hostsCache.invalidate() }
        hostCoverage = await hostsCache.hosts(for: providers)
    }

    func resolvePastedLink(_ text: String) -> PastedLink {
        PastedLink.resolve(
            text, configured: providers.map(\.id), coverage: hostCoverage)
    }

    func addHostedLink(_ url: URL, using provider: DebridProviderID) async throws {
        guard let debrid = providers.first(where: { $0.id == provider }),
              let engine = engines[provider.rawValue]
        else { throw AppModelError.notConfigured }

        let request = try await engine.prepareHostedLink(
            url, subfolder: nil, destinationRoot: downloadDirectory)
        let id = await engine.enqueue(request)
        remember(id, Routed(provider: debrid, engine: engine))
    }

    private(set) var pinnedProvider: DebridProviderID?

    func pinProvider(_ id: DebridProviderID?) { pinnedProvider = id }

    func route(_ rawMagnet: String) async throws -> Routed {
        guard !providers.isEmpty else { throw AppModelError.notConfigured }

        if let pinnedProvider,
           let chosen = providers.first(where: { $0.id == pinnedProvider }),
           let engine = engines[chosen.id.rawValue] {
            return Routed(provider: chosen, engine: engine)
        }

        let hash = MagnetLink(rawMagnet)?.infoHash.hex ?? ""
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

    func availability(forMagnet rawMagnet: String) async -> LinkAvailability {
        guard let store = cacheStatusStore,
              let hash = MagnetLink(rawMagnet)?.infoHash.hex
        else { return providers.isEmpty ? .noProviders : .unknowable(providers[0].id) }

        return await LinkAvailability.resolve(
            hash: hash, providers: providers, store: store)
    }

    func magnet(fromTorrentFileAt url: URL) -> MagnetLink? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url) else { return nil }
        return TorrentFile.parse(data)?.magnet
    }

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


    struct Preparation: Identifiable {
        let id: PreparationID
        let name: String
        let groupKey: DownloadGroupKey
        var progress: PreparationProgress?
        var providerName: String
    }

    private(set) var preparations: [Preparation] = []

    private var engineForPreparation: [PreparationID: DownloadEngine] = [:]

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
        pinnedProvider = nil
        preparingProvider[id] = routed
    }

    private var preparingProvider: [PreparationID: Routed] = [:]

    func cancelPreparation(_ id: PreparationID) {
        guard let engine = engineForPreparation[id] else {
            preparations.removeAll { $0.id == id }
            return
        }
        Task { await engine.cancelPreparation(id) }
    }

    func remember(_ id: DownloadID, _ routed: Routed) {
        engineForDownload[id] = routed.engine
        providerForDownload[id] = routed.provider.displayName
    }

    func routedProviderName(forHash hash: String) async -> String? {
        guard !providers.isEmpty else { return nil }
        let cached = await cacheStatusStore?.cachedProviderMap() ?? [:]
        return DebridRouter.provider(
            for: hash, providers: providers, cachedOn: cached)?.displayName
    }


    struct TorrentGroup: Identifiable {
        let id: String
        let contentKey: String
        let displayName: String
        let items: [DownloadItem]
        let section: DownloadSection
        let mediaKind: MediaKind

        var completedAt: Date? { items.compactMap(\.completedAt).max() }

        var totalBytes: Int64 { items.reduce(0) { $0 + $1.totalBytes } }
        var bytesDownloaded: Int64 { items.reduce(0) { $0 + $1.bytesDownloaded } }
        var bytesPerSecond: Double { items.reduce(0) { $0 + $1.bytesPerSecond } }

        var fraction: Double? {
            guard totalBytes > 0 else { return nil }
            return Double(bytesDownloaded) / Double(totalBytes)
        }

        var etaText: String? {
            ByteCount.eta(
                remaining: totalBytes - bytesDownloaded, bytesPerSecond: bytesPerSecond)
        }

        var queuedCount: Int { items.filter { $0.state == .queued }.count }

        var pinnedUnit: ByteCountFormatter.Units {
            ByteCount.pinnedUnit(for: totalBytes)
        }
    }

    /**
     What a double-click on a row does: open what is on disk. A single file
     opens in whatever the system opens it with; several files open their
     containing folder, because there is no one file to mean. A row with
     nothing on disk yet has nothing to open and says so by doing nothing.
     */
    @discardableResult
    func openOnDisk(_ group: TorrentGroup) -> Bool {
        let urls = group.items.compactMap(\.finalURL)
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard let first = urls.first else { return false }
        if urls.count == 1 {
            NSWorkspace.shared.open(first)
        } else {
            NSWorkspace.shared.open(first.deletingLastPathComponent())
        }
        return true
    }

    @discardableResult
    func revealInFinder(_ group: TorrentGroup) -> Bool {
        let urls = group.items.compactMap(\.finalURL)
        guard !urls.isEmpty else { return false }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
        return true
    }

    /**
     The players actually on this Mac, in the order `ExternalPlayer` lists.

     **Asked of `NSWorkspace`, not searched for.** Fetch does not scan
     `/Applications` or guess at paths; it asks the system whether a bundle
     identifier resolves, which is the same question Launch Services answers
     when you double-click a file. A player installed while Fetch is running
     appears the next time this is read — it is computed, not cached, because
     the list is four lookups and is read when a menu opens.
     */
    var installedPlayers: [ExternalPlayer] {
        ExternalPlayer.allCases.filter { player in
            NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: player.bundleIdentifier) != nil
        }
    }

    /**
     Which player one click means: the stored choice while its app is here,
     the first installed one otherwise, and nil when there is no player at all
     — which is a menu that must not offer to play anything.
     */
    var defaultExternalPlayer: ExternalPlayer? {
        DefaultPlayer.resolve(
            stored: UserDefaults.standard.string(forKey: DefaultPlayer.defaultsKey),
            installed: installedPlayers)
    }

    /**
     A torrent on the Downloads screen, as playlist candidates.

     **Every file the torrent has, not every file that has a row.** The files
     that finished are where their bytes landed; the ones still queued, failed
     or never asked for are candidates with nowhere to play from — they carry
     no source and are counted, so `PlaylistPlan.Offer` can say "Play 9 of 12"
     rather than quietly calling nine files the whole season.
     */
    func playlistCandidates(for group: TorrentGroup) -> [PlaylistCandidate] {
        let queued = group.items.map { item in
            PlaylistCandidate(
                path: relativePath(of: item.id) ?? item.displayName,
                source: item.state == .completed
                    ? item.finalURL.map { .local($0) } : nil)
        }
        return queued + skippedFiles(for: group).map {
            PlaylistCandidate(path: $0.path, source: nil)
        }
    }

    /**
     Everything playable in this torrent, or nil when there is no playlist
     worth offering: fewer than two playable files, or no installed player
     that can take a list of this shape. Every decision in it is
     `PlaylistPlan`'s, under test in FetchKit.
     */
    func playlistOffer(for group: TorrentGroup) -> PlaylistPlan.Offer? {
        PlaylistPlan.offer(
            candidates: playlistCandidates(for: group),
            defaultPlayer: defaultExternalPlayer,
            installed: installedPlayers)
    }

    /**
     Plays a whole torrent, in the torrent's own order.

     What each item resolves to and what a shortfall means are
     `PlaylistPlan.resolution`'s; this hands over the answer. A notice is
     shown only when there is something to say, because a playlist that
     silently arrives two episodes short is the failure the user discovers at
     the gap, an hour later, with nothing to explain it.
     */
    func playPlaylist(_ items: [PlaylistItem], in player: ExternalPlayer) {
        let resolution = PlaylistPlan.resolution(for: items, resolved: [:])
        if let notice = resolution.notice { report(AppAlert(message: notice)) }
        guard resolution.opens else { return }
        stream(resolution.urls, in: player)
    }

    /**
     Hands a player the whole list in one open.

     **No `openTarget` here.** That wraps a URL in IINA's own scheme, which
     carries exactly one address — and `ExternalPlayer.acceptsPlaylist` has
     already refused every player and every mix that would need it, so what
     reaches this is always URLs the application takes directly. One open with
     N URLs is what dropping N files on an app's icon does, and it is what
     makes VLC and mpv build a playlist instead of N windows.
     */
    func stream(_ playlist: [URL], in player: ExternalPlayer) {
        guard !playlist.isEmpty else { return }
        guard let app = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: player.bundleIdentifier)
        else {
            fetchLog(.warn, "stream", "\(player.displayName) is not on this Mac")
            return
        }
        NSWorkspace.shared.open(
            playlist, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    var torrentGroups: [(section: DownloadSection, groups: [TorrentGroup])] {
        if let memo = groupsMemo, memo.key == itemsVersion { return memo.value }
        let value = buildTorrentGroups()
        groupsMemo = (itemsVersion, value)
        return value
    }

    @ObservationIgnored
    private var groupsMemo: (key: Int, value: [(section: DownloadSection, groups: [TorrentGroup])])?

    /**
     Observed, not ignored. A memo hit returns without touching `items`, so if
     the version counter were ignored too, that call would register no
     dependency at all and the list would stop redrawing until something else
     happened to invalidate it.
     */
    private var itemsVersion = 0

    private func invalidateGroups() { itemsVersion &+= 1 }

    private func buildTorrentGroups() -> [(section: DownloadSection, groups: [TorrentGroup])] {
        let rows = DownloadGrouping.rows(items) { item in
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

    var failedGroupCount: Int {
        torrentGroups.first { $0.section == .failed }?.groups.count ?? 0
    }

    var librarySections: [(kind: MediaKind, rows: [TorrentGroup])] {
        DownloadLibrary.sections(
            completedGroups, kind: \.mediaKind, name: \.displayName)
    }

    private var completedGroups: [TorrentGroup] {
        torrentGroups.filter { $0.section == .completed }.flatMap(\.groups)
    }

    func libraryRows(kind: MediaKind?) -> [TorrentGroup] {
        let rows = kind.map { wanted in
            completedGroups.filter { $0.mediaKind == wanted }
        } ?? completedGroups
        return DownloadLibrary.newestFirst(
            rows, date: \.completedAt, name: \.displayName)
    }


    func pauseTorrent(_ group: TorrentGroup) {
        for item in group.items where item.state == .downloading { pause(item.id) }
    }

    func resumeTorrent(_ group: TorrentGroup) {
        for item in group.items where item.state.canBeStarted { resume(item.id) }
    }

    func cancelTorrent(_ group: TorrentGroup) {
        let remote = remoteTorrent(of: group)
        for item in group.items where !item.state.isTerminal { cancel(item.id) }
        deleteRemotely(remote)
    }

    private func remoteTorrent(of group: TorrentGroup) -> (DownloadEngine, DebridTorrentID)? {
        guard let request = group.items.compactMap({ requestForDownload[$0.id] }).first,
              case .debridTorrent(_, let torrentID, _) = request.source,
              let engine = group.items.compactMap({ engineForDownload[$0.id] }).first ?? engine
        else { return nil }
        return (engine, torrentID)
    }

    private func deleteRemotely(_ remote: (DownloadEngine, DebridTorrentID)?) {
        guard let (engine, torrentID) = remote else { return }
        Task { await engine.deleteRemoteTorrent(torrentID) }
    }

    func removeTorrent(_ group: TorrentGroup) {
        let landed = group.items.contains { $0.state == .completed }
        let remote = landed ? nil : remoteTorrent(of: group)
        for item in group.items { remove(item.id) }
        deleteRemotely(remote)
    }


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
                report("\(outcome.missingPaths.count) of the files chosen are no "
                       + "longer in this torrent and were skipped.")
            }
        } catch DebridError.fileNotFound {
            await resubmit(paths: paths, from: request, name: group.displayName)
        } catch {
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

    func relativePath(of id: DownloadID) -> String? {
        requestForDownload[id]?.file.name
    }

    func redownloadablePaths(for group: TorrentGroup) -> [TorrentMetadata.File] {
        DownloadGrouping.redownloadableFiles(
            allFiles: torrentFiles[group.contentKey.lowercased()] ?? [],
            paths: group.items.compactMap { item in
                requestForDownload[item.id].map { ($0.file.name, item.state) }
            })
    }

    /**
     Stop everything still moving, in one go.

     Iterates a snapshot of `allDownloadRows`, not the live list, because
     `cancelTorrent` feeds events back into `items` and mutating the
     sequence being walked is the classic way this loop misses a row.

     Rows are left in place, cancelled, rather than removed: cancelling and
     clearing are two toolbar buttons because they are two decisions, and
     collapsing them here would make the trash button unreachable for
     anything that was in flight a moment ago.
     */
    func cancelAllInFlight() {
        for group in allDownloadRows
        where DownloadFilter.isCancellable(group.rowState) && !group.rowState.isCloudOnly {
            cancelTorrent(group)
        }
        for preparation in preparations { cancelPreparation(preparation.id) }
    }

    func clearFailed() {
        let doomed = torrentGroups.first { $0.section == .failed }?.groups ?? []
        for group in doomed {
            let landed = group.items.contains { $0.state == .completed }
            let remote = landed ? nil : remoteTorrent(of: group)
            for item in group.items where item.state.needsAttention { remove(item.id) }
            deleteRemotely(remote)
        }
    }

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

    func finalURL(for id: DownloadID) -> URL? {
        items.first { $0.id == id }?.finalURL
    }

    func canPause(_ group: TorrentGroup) -> Bool {
        group.items.contains { $0.state == .downloading }
    }

    func canResume(_ group: TorrentGroup) -> Bool {
        group.items.contains(where: \.state.canBeStarted)
    }


    func pause(_ id: DownloadID) {
        guard let engine = engineForDownload[id] ?? engine else {
            report("This download can no longer be paused. The service it was using "
                   + "is no longer configured, so remove the row and add it again.")
            return
        }
        Task { await engine.pause(id) }
    }

    func resume(_ id: DownloadID) {
        guard let engine = engineForDownload[id] ?? engine else {
            report("This download can no longer be resumed. The service it was using "
                   + "is no longer configured, so remove the row and add it again.")
            return
        }
        Task { await engine.resume(id) }
    }

    private func cancel(_ id: DownloadID) {
        guard let engine = engineForDownload[id] ?? engine else {
            report("This download can no longer be cancelled. The service it was using "
                   + "is no longer configured, so remove the row and add it again.")
            return
        }
        Task { await engine.cancel(id, deletePartial: true) }
    }

    func remove(_ id: DownloadID) {
        guard let engine = engineForDownload[id] ?? engine else {
            apply(.removed(id))
            return
        }
        Task { await engine.remove(id) }
    }

    private func persist(_ id: DownloadID) {
        guard let store = downloadStore,
              let request = requestForDownload[id],
              let item = items.first(where: { $0.id == id })
        else { return }
        let engine = engineForDownload[id] ?? engine
        Task { [weak self] in
            let map = await engine?.segmentMap(for: id)
            guard self != nil else { return }
            try? store.save(
                id: id, request: request, state: item.state,
                bytesDownloaded: item.bytesDownloaded, segmentMap: map,
                allFiles: self?.torrentFiles[request.infoHashHex.lowercased()],
                finalURL: item.finalURL,
                lastError: item.errorMessage)
        }
    }

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

    private func restoreDownloads() async {
        var restored: [DownloadState] = []
        defer { applyLaunchLanding(restored: restored) }

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

            let resolved: URL?
            let outcome: LaunchRecovery.Outcome
            if record.state.isCloudOnly {
                resolved = nil
                outcome = LaunchRecovery.reconcile(
                    state: record.state, recordedBytes: 0,
                    partialExists: false, partialSize: 0)
            } else {
                resolved = record.finalURL ?? (try? DestinationResolver.resolve(
                    root: request.destinationRoot, subfolder: request.subfolder,
                    relativePath: request.renamedPath ?? request.file.name))

                let partial = resolved?.appendingPathExtension("fetchpart")
                let measured = await Task.detached { (FileSize.of(resolved), FileSize.of(partial)) }.value

                outcome = LaunchRecovery.reconcile(
                    state: record.state,
                    recordedBytes: record.bytesDownloaded,
                    expectedSize: request.file.size,
                    finalSize: measured.0,
                    partialSize: measured.1,
                    segmentMap: record.segmentMap)
            }

            restored.append(outcome.state)

            let id = DownloadID(rawValue: record.id)
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

    /**
     Where the window opens, decided once the restore knows what it found.

     **Off the reconciled records, not off `items`.** The engine is handed
     each restored download and feeds its row back as an event, so `items`
     is still empty when this loop ends — asking it would land every launch
     on the Library, including the one where three things are downloading.

     "Active" is `isCancellable`, not `!isTerminal`: a failed row is
     stopped, and opening on the in-flight list to show a download that is
     not moving would be the wrong half of the answer.
     */
    private func applyLaunchLanding(restored states: [DownloadState]) {
        downloadFilter = LaunchLanding.filter(
            hasActiveDownloads: states.contains { DownloadFilter.isCancellable($0) })
        sidebarSection = .downloads
    }

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
                if state != .failed { $0.errorMessage = nil }
            }
            persist(id)
            if state == .cloudQueued { startCloudPollIfNeeded() }
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


    func runSearch(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastSearchQuery = ""
            resetSearch(to: .noQuery)
            return
        }

        let providers = configuredSearchProviders(for: searchCategory)
        guard !providers.isEmpty else {
            resetSearch(to: configuredSearchProviders(for: .all).isEmpty
                ? .noProviders : .noProvidersForArea)
            return
        }

        lastSearchQuery = trimmed

        searchTask?.cancel()
        resetSearch(to: .searching)

        let serverByIndexer = Dictionary(
            activeIndexers.map { ($0.indexer.id, $0.server.id) },
            uniquingKeysWith: { first, _ in first })

        let aggregator = SearchAggregator(
            providers: providers,
            perProviderTimeout: indexerTimeout,
            profile: qualityProfile,
            excludeAdult: safeSearch)
        let safeSearch = self.safeSearch
        let category = self.searchCategory
        pagedCategory = category
        pagesLoaded = 1
        let task = Task { [weak self] in
            var accumulator = StreamedResultAccumulator(
                profile: self?.qualityProfile ?? .default, query: trimmed,
                excludeAdult: safeSearch)

            for await event in aggregator.stream(SearchQuery(
                text: trimmed, categories: category.torznabCategories,
                limit: Self.searchPageSize)) {
                guard let self, !Task.isCancelled else { return }
                let fresh = accumulator.apply(event)
                self.searchAccumulator = accumulator
                self.applySearch(accumulator, freshHashes: fresh)

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

    func loadMoreResults() async {
        guard canLoadMore, !isLoadingMore, var accumulator = searchAccumulator,
              !lastSearchQuery.isEmpty
        else { return }

        let providers = configuredSearchProviders(for: pagedCategory)
        guard !providers.isEmpty else { return }

        isLoadingMore = true
        loadMoreFailed = false
        let before = accumulator.resultCount

        let aggregator = SearchAggregator(
            providers: providers,
            perProviderTimeout: indexerTimeout,
            profile: qualityProfile,
            excludeAdult: safeSearch)
        let query = SearchQuery(
            text: lastSearchQuery, categories: pagedCategory.torznabCategories,
            limit: Self.searchPageSize)
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
        canLoadMore = added > 0
        if let accumulator = searchAccumulator,
           accumulator.failures.count == accumulator.total, accumulator.total > 0 {
            loadMoreFailed = true
            canLoadMore = true
            pagesLoaded -= 1
        }
    }

    func cancelSearch() {
        guard searchScreenState == .searching else { return }
        searchTask?.cancel()
        searchTask = nil
        searchProgress = nil
        searchScreenState = searchResults.isEmpty ? .noResults : .results
    }

    func selectCategory(_ category: SearchCategory) async {
        guard category != searchCategory else { return }
        searchCategory = category
        guard !lastSearchQuery.isEmpty else { return }
        await runSearch(lastSearchQuery)
    }

    private func migrateBookFormatPreference() {
        guard let raw = UserDefaults.standard.stringArray(forKey: Self.gutenbergFormatsKey)
        else { return }
        defer { UserDefaults.standard.removeObject(forKey: Self.gutenbergFormatsKey) }

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
        facetSelection.clear()
        cachedOnly = cachedOnlyDefault
        showsFilteredResults = false
        resultSelection.clear()
    }

    private func applySearch(_ accumulator: StreamedResultAccumulator, freshHashes: [String]) {
        searchResults = accumulator.results
        filteredOutResults = accumulator.filtered
        resultsVersion &+= 1

        searchProgress = accumulator.isFinished
            ? nil
            : (completed: accumulator.completed, total: accumulator.total)

        if !accumulator.results.isEmpty {
            searchScreenState = .results
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

            if accumulator.isFinished, accumulator.failures.count < accumulator.total {
                searchBanner =
                    "\(accumulator.failures.count) of \(accumulator.total) indexers failed"
            }
        }

        guard cacheStatusStore != nil, accumulator.isFinished else { return }
        requestCacheChecks(throughIndex: 0)
    }

    private func configuredSearchProviders(
        for category: SearchCategory
    ) -> [any SearchProvider] {
        var built: [any SearchProvider] = []

        if searchesInternetArchive {
            built.append(InternetArchiveProvider(
                client: HTTPClient(allowedHosts: [InternetArchiveProvider.host])))
        }

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

    private var indexerSessions: [IndexerServerID: (timeout: TimeInterval, session: URLSession)] = [:]

    private func indexerSession(for server: IndexerServerID) -> URLSession {
        if let existing = indexerSessions[server], existing.timeout == indexerTimeout {
            return existing.session
        }
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
                client: HTTPClient(session: indexerSession(for: server.id)),
                capsStore: torznabCapsStore
            )
        }
    }

    private func serverAccount(_ id: IndexerServerID) -> CredentialAccount {
        CredentialAccount(layer: "search", providerID: id.rawValue)
    }


    private static let cacheLookahead = 60

    private var requestedCacheHashes: Set<String> = []
    private var cacheCheckedThrough = -1

    func requestCacheChecks(throughIndex index: Int) {
        guard let cacheStatusStore else { return }
        let horizon = index + Self.cacheLookahead
        guard horizon > cacheCheckedThrough else { return }
        cacheCheckedThrough = horizon

        let wanted = visibleResults.prefix(horizon)
            .compactMap { $0.infoHashHex?.lowercased() }
            .filter { requestedCacheHashes.insert($0).inserted }
        guard !wanted.isEmpty else { return }
        Task { await cacheStatusStore.check(hashes: wanted) }
    }

    func retryCacheCheck(hash: String) {
        guard let cacheStatusStore else { return }
        Task { await cacheStatusStore.retry(hash: hash) }
    }

    func dismissSearchBanner() {
        searchBanner = nil
    }

    func previewFiles(rawMagnet: String, hash: String) async throws -> [DebridFile]? {
        guard !providers.isEmpty else { throw AppModelError.notConfigured }
        let cached = await cacheStatusStore?.cachedProviderMap() ?? [:]
        guard let chosen = DebridRouter.provider(
            for: hash, providers: providers, cachedOn: cached)
        else { throw AppModelError.notConfigured }

        if let files = try await chosen.previewFiles(rawMagnet: rawMagnet, infoHashHex: hash) {
            return files
        }

        guard let files = await metadataFetcher.files(forInfoHash: hash), !files.isEmpty
        else { return nil }

        return files.map { file in
            DebridFile(
                id: DebridFileID(rawValue: file.path),
                name: file.path,
                shortName: (file.path as NSString).lastPathComponent,
                size: file.length,
                mimeType: nil)
        }
    }

    private let metadataFetcher = TorrentMetadataFetcher()

    private let notifier = DownloadNotifier()


    private var _directEngine: DownloadEngine?
    private var directPump: Task<Void, Never>?

    private func directEngine() -> DownloadEngine {
        if let _directEngine { return _directEngine }
        let engine = DownloadEngine(
            provider: NoDebridProvider(),
            segmented: SegmentedTransfer(maxSegments: segmentsPerFile),
            segmentsPerFile: segmentsPerFile,
            maxConcurrent: maxConcurrentDownloads)
        _directEngine = engine
        directPump = Task { [weak self] in
            for await event in engine.events {
                await self?.apply(event, from: engine)
            }
        }
        engineNames[ObjectIdentifier(engine)] = "Direct"
        return engine
    }

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
            requestForDownload[id] = request
            invalidateGroups()
            persist(id)
            ids.append(id)
        }
        return ids
    }

    func enqueueBestCandidate(_ result: SearchResult) async {
        guard let url = result.candidates.first(where: \.isUsable)?.url else {
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
        copyToast.show("Magnet link copied")
    }

    let copyToast = CopyToast()


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


    private func makeProvider(_ id: DebridProviderID) -> (any DebridProvider)? {
        guard let key = try? credentialStore.read(
            for: CredentialAccount(layer: "debrid", providerID: id.rawValue)),
              !key.isEmpty
        else { return nil }

        return DebridKind.kind(for: id)?.makeProvider(Redacted(key), HTTPClient())
    }

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
        Task {
            await refreshServiceHealth()
            await refreshHostCoverage(force: true)
        }
    }

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

    func hasActiveDownloads(on id: DebridProviderID) -> Bool {
        let name = DebridKind.kind(for: id)?.displayName
        return items.contains { item in
            guard !item.state.isTerminal, !item.state.isCloudOnly else { return false }
            guard let owner = providerForDownload[item.id] else { return true }
            return owner == name
        }
    }

    func setDebridEnabled(_ id: DebridProviderID, isEnabled: Bool) {
        guard let index = debridConfigs.firstIndex(where: { $0.id == id }) else { return }
        debridConfigs[index].isEnabled = isEnabled
        persistDebridConfigs()
        configureProviders()
        Task { await refreshServiceHealth() }
    }

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
            report("Your debrid providers could not be saved and will be lost when Fetch quits.")
            return
        }
        UserDefaults.standard.set(data, forKey: Self.debridConfigsDefaultsKey)
    }

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

    func reconcileIndexers(id: IndexerServerID, discovered: [SubIndexer]) {
        guard let index = indexerServers.firstIndex(where: { $0.id == id }) else { return }

        let discoveredByURL = Dictionary(
            discovered.map { ($0.torznabURL, $0) }, uniquingKeysWith: { first, _ in first })
        var merged: [SubIndexer] = []

        let supersedesAggregate = discovered.contains { !JackettDirectory.isAggregate($0.torznabURL) }
            && discovered.contains { JackettDirectory.isJackettShaped($0.torznabURL) }

        for var existing in indexerServers[index].indexers {
            if supersedesAggregate, JackettDirectory.isAggregate(existing.torznabURL) { continue }
            if let match = discoveredByURL[existing.torznabURL] {
                existing.name = match.name
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

    var indexerHealthRows: [HealthReport.IndexerRow] {
        HealthReport.indexerRows(indexerServers)
    }

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

    func refreshIndexerRosters() async {
        for server in indexerServers where server.isEnabled {
            guard let key = try? credentialStore.read(for: serverAccount(server.id)),
                  !key.isEmpty,
                  let plan = try? await IndexerSetup.plan(
                    url: server.rootURL, apiKey: Redacted(key),
                    client: HTTPClient(session: indexerSession(for: server.id)))
            else { continue }
            guard case .single = plan else {
                reconcileIndexers(
                    id: server.id,
                    discovered: Self.subIndexers(from: plan, serverName: server.displayName))
                continue
            }
        }
    }

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

    func setIndexerAreas(
        server: IndexerServerID, indexer: SearchProviderID, areas: Set<SearchCategory>?
    ) {
        guard let s = indexerServers.firstIndex(where: { $0.id == server }),
              let i = indexerServers[s].indexers.firstIndex(where: { $0.id == indexer })
        else { return }
        indexerServers[s].indexers[i].areas = (areas?.isEmpty ?? true) ? nil : areas
        persistIndexerServers()
    }

    func indexerServerAPIKey(for id: IndexerServerID) -> String? {
        try? credentialStore.read(for: serverAccount(id))
    }


    private func persistIndexerServers() {
        guard let data = try? JSONEncoder().encode(indexerServers) else {
            report("Your indexer servers could not be saved and will be lost when Fetch quits.")
            return
        }
        UserDefaults.standard.set(data, forKey: Self.indexerServersDefaultsKey)
    }

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
