import Testing
import Foundation
import FetchPluginAPI
@testable import FetchKit

/// A one-shot gate a suspended caller can wait on until the test releases
/// it. Same shape as `TorznabCapsStoreTests`' `Signal` — a continuation-based
/// wait is deterministic where a fixed sleep could never be proven long
/// enough under an unlucky scheduler.
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

/// Releases every caller only once `target` callers have all arrived.
///
/// A caller run under a sequential filter can never reach the target: caller
/// 2 is never invoked until caller 1's `await` returns, and caller 1's
/// `await` never returns because it is one arrival short. So a sequential
/// `participants(for:)` leaves every `arrive()` suspended forever — the test
/// that uses this races the whole call against
/// `SearchAggregator.withTimeout` rather than trusting this suspension to be
/// cancellable, since it isn't (see that test's doc comment).
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

/// Records the order in which providers' `capabilities()` calls actually
/// resolved, so a test can assert that order differs from — and does not
/// leak into — the order `participants(for:)` returns.
private actor CompletionLog {
    private(set) var order: [String] = []
    func record(_ id: String) { order.append(id) }
}

private actor ResultBox<T: Sendable> {
    private(set) var value: T?
    func set(_ value: T) { self.value = value }
}

/// Runs `operation` on its own, unstructured `Task` and returns its result
/// if it lands within `timeoutSeconds`, else `nil`.
///
/// Both `withThrowingTaskGroup`-based timeouts (including
/// `SearchAggregator.withTimeout`, checked directly against this scenario)
/// and swift-testing's `.timeLimit` trait were tried here first and both
/// failed to bound the sequential-`participants(for:)` hang: Swift task
/// groups and `async let` implicitly *join* every child at scope exit, even
/// a cancelled one, so leaving the scope still blocks until a
/// non-cancellation-aware suspension (this file's `Barrier`/`Signal`, both
/// bare `withCheckedContinuation`) actually resumes — which, under the bug
/// this test targets, it never does. An unstructured `Task {}` is not joined
/// by anything, so its caller can walk away from it; polling `ResultBox`
/// with `Task.sleep` (itself always cancellable and self-terminating) is
/// what actually enforces the deadline.
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

    /// Advertises nothing (so it always participates once asked) and reports
    /// its own `capabilities()` call to a shared `Barrier` before returning —
    /// used to prove `participants(for:)` fetches capabilities concurrently.
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

    /// Advertises nothing, optionally waits on `waitFor` before resolving,
    /// logs the moment it resolves, and optionally signals `announce`
    /// afterward — used to show that the order `participants(for:)` returns
    /// is the input order, not completion order.
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
    /// Advertises nothing, so it is asked for everything.
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

    /// The point of filtering before the fan-out: the readout must count what
    /// was asked, not what was configured.
    @Test func startedCountsOnlyParticipants() async {
        let aggregator = SearchAggregator(providers: [books, films, unknown])
        let query = SearchQuery(
            text: "dune", categories: SearchCategory.books.torznabCategories)

        var announced: Int?
        for await event in aggregator.stream(query) {
            if case .started(let count) = event { announced = count }
        }
        #expect(announced == 2)
    }

    /// `participants(for:)` must fetch capabilities concurrently, the way
    /// `search(_:)`'s own task group always has: three providers each block
    /// on a `Barrier` that only opens once all three have arrived. A
    /// sequential filter calls provider 1, which then waits forever for
    /// arrivals 2 and 3 that a sequential loop can never produce — an
    /// unbounded hang, not a slow pass.
    ///
    /// A hang like that cannot be caught with `.timeLimit`, nor with
    /// `SearchAggregator.withTimeout` — both only *request* cancellation, and
    /// a Swift task group implicitly joins every child (cancelled or not) at
    /// scope exit, so leaving the scope still blocks until
    /// `Barrier.arrive()`'s bare `withCheckedContinuation` actually resumes,
    /// which under the bug this test targets it never does. Confirmed
    /// empirically: both were tried here first, and both left the test
    /// process alive for minutes against a sequential `participants(for:)`.
    /// `firstToFinish` sidesteps this by running the call on its own
    /// unstructured `Task`, which nothing joins, and polling for its result
    /// against a deadline instead — see its doc comment.
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

    /// The batch path re-sorts by provider id before folding, so nothing
    /// downstream depends on `participants(for:)`'s own order today — but a
    /// filter that silently reorders is a trap for whatever reads it next.
    /// `alpha` is held behind a gate and resolves after `beta`, yet the
    /// returned list must still read `[alpha, beta]`, matching the order the
    /// providers were given in, not the order their capability checks
    /// finished in.
    ///
    /// A sequential `participants(for:)` regression is a two-way deadlock
    /// here, not just a slow pass: it calls `alpha` first, which blocks in
    /// `capabilities()` on `alphaGate.wait()`; `beta` is never reached, so
    /// `betaDone` is never set; and this test's own `await betaDone.wait()`
    /// then blocks forever too, one line before the `alphaGate.set()` that
    /// could have unblocked `alpha`. Same shape as
    /// `participantsFetchesCapabilitiesConcurrently`'s hang, so it gets the
    /// same fix: the whole wait-then-release-then-collect sequence runs
    /// inside `firstToFinish` rather than as a bare top-level `await`, so a
    /// regression here fails in seconds instead of stalling the run.
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

            // Beta has no gate, so it resolves and signals `betaDone` on its
            // own; only once that has definitely happened do we release
            // alpha — so beta is provably logged first without any sleep or
            // poll of our own. (`firstToFinish` itself polls, but only to
            // enforce the outer deadline, not to order these two.)
            await betaDone.wait()
            await alphaGate.set()

            return await resultIDs
        }
        #expect(ids == ["alpha", "beta"])
        #expect(await log.order == ["beta", "alpha"])
    }
}
