import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

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

private actor FetchCounter {
    private(set) var count = 0
    func increment() -> Int {
        count += 1
        return count
    }
}

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

        #expect(try await staleResult == stale)

        let next = try await store.capabilities(for: idA) {
            _ = await counter.increment()
            return fresh
        }
        #expect(next == fresh)
        #expect(await counter.count == 2)
    }
}
