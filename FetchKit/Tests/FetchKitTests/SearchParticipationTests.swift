import Testing
import Foundation
import FetchPluginAPI
@testable import FetchKit

private actor Signal {
    private var isSet = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isSet { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func set() {
        isSet = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

private actor Barrier {
    private let target: Int
    private var arrivals = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(awaiting target: Int) { self.target = target }

    func arrive() async {
        arrivals += 1
        if arrivals == target {
            waiters.forEach { $0.resume() }
            waiters.removeAll()
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private actor CompletionLog {
    private(set) var order: [String] = []
    func record(_ id: String) { order.append(id) }
}

private actor ResultBox<T: Sendable> {
    private(set) var value: T?
    func set(_ value: T) { self.value = value }
}

private func firstToFinish<T: Sendable>(
    timeoutSeconds: Double, _ operation: @escaping @Sendable () async -> T
) async -> T? {
    let box = ResultBox<T>()
    Task {
        let result = await operation()
        await box.set(result)
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(timeoutSeconds))
    while ContinuousClock.now < deadline {
        if let value = await box.value { return value }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return await box.value
}

@Suite struct SearchParticipationTests {
    private struct StubProvider: SearchProvider {
        let id: SearchProviderID
        let displayName: String
        let advertised: [TorznabCategory]
        let results: [SearchResult]

        func capabilities() async throws -> ProviderCapabilities {
            ProviderCapabilities(
                categories: advertised, supportedModes: [.search],
                supportedAttributes: [], maxLimit: nil)
        }

        func search(_ query: SearchQuery) async throws -> [SearchResult] { results }
    }

    private struct GatedProvider: SearchProvider {
        let id: SearchProviderID
        let displayName: String
        let barrier: Barrier

        func capabilities() async throws -> ProviderCapabilities {
            await barrier.arrive()
            return ProviderCapabilities(
                categories: [], supportedModes: [.search],
                supportedAttributes: [], maxLimit: nil)
        }

        func search(_ query: SearchQuery) async throws -> [SearchResult] { [] }
    }

    private struct OrderedProvider: SearchProvider {
        let id: SearchProviderID
        let displayName: String
        let waitFor: Signal?
        let announce: Signal?
        let log: CompletionLog

        func capabilities() async throws -> ProviderCapabilities {
            if let waitFor { await waitFor.wait() }
            await log.record(id.rawValue)
            if let announce { await announce.set() }
            return ProviderCapabilities(
                categories: [], supportedModes: [.search],
                supportedAttributes: [], maxLimit: nil)
        }

        func search(_ query: SearchQuery) async throws -> [SearchResult] { [] }
    }

    private let books = StubProvider(
        id: SearchProviderID(rawValue: "books"),
        displayName: "Books",
        advertised: [TorznabCategory(id: 7000, name: "Books")],
        results: [])
    private let films = StubProvider(
        id: SearchProviderID(rawValue: "films"),
        displayName: "Films",
        advertised: [TorznabCategory(id: 2000, name: "Movies")],
        results: [])
    private let unknown = StubProvider(
        id: SearchProviderID(rawValue: "unknown"),
        displayName: "Unknown",
        advertised: [],
        results: [])

    @Test func participantsExcludeProvidersThatCarryNothingRequested() async {
        let aggregator = SearchAggregator(providers: [books, films, unknown])
        let ids = await aggregator
            .participants(for: SearchCategory.books.torznabCategories)
            .map(\.id.rawValue)
            .sorted()
        #expect(ids == ["books", "unknown"])
    }

    @Test func everyProviderParticipatesWhenNoCategoryIsRequested() async {
        let aggregator = SearchAggregator(providers: [books, films, unknown])
        let ids = await aggregator.participants(for: []).map(\.id.rawValue).sorted()
        #expect(ids == ["books", "films", "unknown"])
    }

    @Test func startedCountsOnlyParticipants() async {
        let aggregator = SearchAggregator(providers: [books, films, unknown])
        let query = SearchQuery(
            text: "dune", categories: SearchCategory.books.torznabCategories)

        var announced: [SearchProviderID]?
        for await event in aggregator.stream(query) {
            if case .started(let providers) = event { announced = providers }
        }
        #expect(announced?.count == 2)
        #expect(announced?.contains(unknown.id) == true)
        #expect(announced?.contains(films.id) == false)
    }

    @Test func participantsFetchesCapabilitiesConcurrently() async {
        let providerIDs = ["gated-0", "gated-1", "gated-2"]
        let barrier = Barrier(awaiting: providerIDs.count)
        let stubs = providerIDs.map {
            GatedProvider(
                id: SearchProviderID(rawValue: $0), displayName: $0, barrier: barrier)
        }
        let aggregator = SearchAggregator(providers: stubs)

        let ids = await firstToFinish(timeoutSeconds: 5) {
            await aggregator
                .participants(for: SearchCategory.books.torznabCategories)
                .map(\.id.rawValue)
                .sorted()
        }
        #expect(ids == providerIDs.sorted())
    }

    @Test func participantsPreserveInputOrderRegardlessOfCompletionOrder() async {
        let log = CompletionLog()
        let alphaGate = Signal()
        let betaDone = Signal()
        let alpha = OrderedProvider(
            id: SearchProviderID(rawValue: "alpha"), displayName: "Alpha",
            waitFor: alphaGate, announce: nil, log: log)
        let beta = OrderedProvider(
            id: SearchProviderID(rawValue: "beta"), displayName: "Beta",
            waitFor: nil, announce: betaDone, log: log)
        let aggregator = SearchAggregator(providers: [alpha, beta])

        let ids = await firstToFinish(timeoutSeconds: 5) {
            async let resultIDs = aggregator
                .participants(for: SearchCategory.books.torznabCategories)
                .map(\.id.rawValue)

            await betaDone.wait()
            await alphaGate.set()

            return await resultIDs
        }
        #expect(ids == ["alpha", "beta"])
        #expect(await log.order == ["beta", "alpha"])
    }
}
