import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

/// Mutable injectable clock — `TorznabCapsStore`'s TTL memoization needs to
/// be tested without actually waiting six hours. Same shape as
/// `CacheStatusStoreTests`' `MutableClock`.
private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date = Date(timeIntervalSince1970: 0)) { self.date = date }
    func advance(by seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        date = date.addingTimeInterval(seconds)
    }
    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return date
    }
}

/// Counts invocations so "did it re-fetch?" is an assertion, not an
/// inference from timing.
private actor FetchCounter {
    private(set) var count = 0
    func increment() -> Int {
        count += 1
        return count
    }
}

/// A one-shot gate a fetch closure can suspend on until the test releases
/// it, and that the test can suspend on until the fetch closure has actually
/// started — so tests that need a fetch to still be in flight at a specific
/// moment control that with a continuation instead of a fixed sleep, which
/// could never be proven long enough under an unlucky scheduler.
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

private struct TestError: Error, Equatable {}

/// `named` is folded into a category name so two calls can be told apart by
/// equality — a helper that always returned the same fixed value could not
/// catch a bug that handed one id's answer to another id's caller.
private func makeCapabilities(named name: String = "caps") -> ProviderCapabilities {
    ProviderCapabilities(
        categories: [TorznabCategory(id: 2000, name: name)],
        supportedModes: [.search],
        supportedAttributes: [],
        maxLimit: nil
    )
}

@Suite struct TorznabCapsStoreTests {
    private let idA = SearchProviderID(rawValue: "indexer-a")
    private let idB = SearchProviderID(rawValue: "indexer-b")

    @Test func secondCallForSameIDDoesNotRefetch() async throws {
        let store = TorznabCapsStore()
        let counter = FetchCounter()

        _ = try await store.capabilities(for: idA) {
            _ = await counter.increment()
            return makeCapabilities()
        }
        _ = try await store.capabilities(for: idA) {
            _ = await counter.increment()
            return makeCapabilities()
        }

        #expect(await counter.count == 1)
    }

    /// Distinct answers per id, so a bug that handed idB's caller idA's
    /// (memoized, or in-flight-joined) value would fail this rather than
    /// pass by coincidence.
    @Test func twoDifferentIDsFetchIndependently() async throws {
        let store = TorznabCapsStore()
        let counter = FetchCounter()
        let capsA = makeCapabilities(named: "a")
        let capsB = makeCapabilities(named: "b")

        let resultA = try await store.capabilities(for: idA) {
            _ = await counter.increment()
            return capsA
        }
        let resultB = try await store.capabilities(for: idB) {
            _ = await counter.increment()
            return capsB
        }

        #expect(resultA == capsA)
        #expect(resultB == capsB)
        #expect(await counter.count == 2)
    }

    @Test func aFailedFetchIsNotMemoizedAndIsRetried() async throws {
        let store = TorznabCapsStore()
        let counter = FetchCounter()

        await #expect(throws: TestError.self) {
            _ = try await store.capabilities(for: idA) {
                _ = await counter.increment()
                throw TestError()
            }
        }

        let value = try await store.capabilities(for: idA) {
            _ = await counter.increment()
            return makeCapabilities()
        }

        #expect(value == makeCapabilities())
        #expect(await counter.count == 2)
    }

    /// `inFlight[id]` is set before `capabilities(for:)`'s only suspension
    /// point, so a second concurrent caller finds it there deterministically
    /// — no delay needed for the second caller to "catch" the first.
    @Test func concurrentCallsForOneIDCoalesceAndBothReceiveTheAnswer() async throws {
        let store = TorznabCapsStore()
        let counter = FetchCounter()
        let expected = makeCapabilities()

        async let first = store.capabilities(for: idA) {
            _ = await counter.increment()
            return expected
        }
        async let second = store.capabilities(for: idA) {
            _ = await counter.increment()
            return expected
        }

        let (a, b) = try await (first, second)
        #expect(a == expected)
        #expect(b == expected)
        #expect(await counter.count == 1)
    }

    @Test func concurrentPairAgainstAFailingFetchBothThrowFromOneAttempt() async throws {
        let store = TorznabCapsStore()
        let counter = FetchCounter()

        async let first: ProviderCapabilities = store.capabilities(for: idA) {
            _ = await counter.increment()
            throw TestError()
        }
        async let second: ProviderCapabilities = store.capabilities(for: idA) {
            _ = await counter.increment()
            throw TestError()
        }

        var firstThrew = false
        var secondThrew = false
        do { _ = try await first } catch { firstThrew = true }
        do { _ = try await second } catch { secondThrew = true }

        #expect(firstThrew)
        #expect(secondThrew)
        #expect(await counter.count == 1)
    }

    @Test func aValueOlderThanTheTTLIsRefetched() async throws {
        let clock = MutableClock()
        let store = TorznabCapsStore(ttl: 100, now: { clock.now })
        let counter = FetchCounter()

        _ = try await store.capabilities(for: idA) {
            _ = await counter.increment()
            return makeCapabilities()
        }
        clock.advance(by: 101)
        _ = try await store.capabilities(for: idA) {
            _ = await counter.increment()
            return makeCapabilities()
        }

        #expect(await counter.count == 2)
    }

    @Test func clearForcesARefetch() async throws {
        let store = TorznabCapsStore()
        let counter = FetchCounter()

        _ = try await store.capabilities(for: idA) {
            _ = await counter.increment()
            return makeCapabilities()
        }
        await store.clear()
        _ = try await store.capabilities(for: idA) {
            _ = await counter.increment()
            return makeCapabilities()
        }

        #expect(await counter.count == 2)
    }

    /// The interleaving the review flagged: a fetch is in flight (started
    /// before an edit), `clear()` runs while it's still suspended, and only
    /// then does the fetch resolve. The stale answer it was chasing must not
    /// be written back — the next caller must re-fetch, not receive it.
    ///
    /// `started`/`release` make this deterministic instead of timing-based:
    /// the test does not call `clear()` until the fetch closure has proven
    /// (via `started.set()`) that it is actually running and therefore that
    /// `capabilities(for:)` has already registered it in `inFlight` — and
    /// the fetch does not resolve until the test calls `release.set()`,
    /// which happens only after `clear()` has already returned.
    @Test func clearWhileAFetchIsInFlightPreventsTheStaleAnswerFromBeingMemoized() async throws {
        let store = TorznabCapsStore()
        let counter = FetchCounter()
        let started = Signal()
        let release = Signal()
        let stale = makeCapabilities(named: "stale")
        let fresh = makeCapabilities(named: "fresh")

        async let staleResult: ProviderCapabilities = store.capabilities(for: idA) {
            _ = await counter.increment()
            await started.set()
            await release.wait()
            return stale
        }

        await started.wait()
        await store.clear()
        await release.set()

        // The caller already in flight when `clear()` ran still receives its
        // own answer — `clear()` doesn't cancel it, only stops it from being
        // trusted afterward.
        #expect(try await staleResult == stale)

        // But that answer must not have been memoized: the next call re-fetches
        // rather than returning the stale value `clear()` was meant to discard.
        let next = try await store.capabilities(for: idA) {
            _ = await counter.increment()
            return fresh
        }
        #expect(next == fresh)
        #expect(await counter.count == 2)
    }
}
