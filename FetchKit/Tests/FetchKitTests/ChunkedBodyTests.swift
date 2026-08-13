import Testing
import Foundation
@testable import FetchKit

/// Stage 7c §8. `ChunkedBody` built a fresh `URLSession` per request, so no
/// connection was ever reused. Sharing one session means one delegate serves
/// many tasks — and delivering task A's bytes into task B's stream is the bug
/// that refactor can introduce. It is invisible until two downloads run at
/// once, which is why this suite exists.
@Suite(.serialized, .usesStubURLProtocol) struct ChunkedBodyTests {
    private func drain(_ stream: ChunkedBody.Stream) async throws -> Data {
        var data = Data()
        for try await chunk in stream.chunks { data.append(chunk) }
        return data
    }

    @Test func aSingleFetchDeliversHeadAndBody() async throws {
        StubURLProtocol.reset(handler: { _ in
            StubURLProtocol.Response(
                status: 200, headers: ["Content-Length": "5"], body: Data("hello".utf8))
        })
        let body = ChunkedBody(configuration: StubURLProtocol.makeConfiguration())
        let stream = try await body.fetch(
            URLRequest(url: URL(string: "https://example.com/a")!))

        #expect(stream.head.statusCode == 200)
        #expect(stream.head.value(forHeader: "content-length") == "5")
        #expect(try await drain(stream) == Data("hello".utf8))
    }

    /// The assertion this refactor has to earn. Each caller must receive its
    /// own body — a shared delegate that mixes them up would still pass every
    /// single-request test.
    ///
    /// The interleaving this exercises is at request granularity, not
    /// mid-body: `StubURLProtocol.startLoading` emits one
    /// `urlProtocol(_:didLoad:)` per request, so eight concurrent fetches
    /// racing through the shared delegate is real, but a single response
    /// never arrives to the delegate as more than one `didReceive data:`
    /// call. This would fail against a single-slot delegate that has room
    /// for only one task's state at a time, but it would not catch a bug
    /// that only manifests when two tasks' *chunks* alternate mid-stream —
    /// this stub has no way to produce that.
    @Test func concurrentFetchesDoNotCrossStreams() async throws {
        StubURLProtocol.reset(handler: { request in
            let name = request.url?.lastPathComponent ?? "?"
            // The size is arbitrary padding, not an attempt at multi-chunk
            // delivery (the stub cannot do that — see the doc comment above).
            return StubURLProtocol.Response(
                status: 200, body: Data(String(repeating: name, count: 20_000).utf8))
        })
        let body = ChunkedBody(configuration: StubURLProtocol.makeConfiguration())

        let bodies = try await withThrowingTaskGroup(of: (String, Data).self) { group in
            for name in ["a", "b", "c", "d", "e", "f", "g", "h"] {
                group.addTask {
                    let stream = try await body.fetch(
                        URLRequest(url: URL(string: "https://example.com/\(name)")!))
                    var data = Data()
                    for try await chunk in stream.chunks { data.append(chunk) }
                    return (name, data)
                }
            }
            var collected: [String: Data] = [:]
            for try await (name, data) in group { collected[name] = data }
            return collected
        }

        #expect(bodies.count == 8)
        for (name, data) in bodies {
            #expect(data == Data(String(repeating: name, count: 20_000).utf8))
        }
    }

    /// A transport failure before any response has to reach the awaiting
    /// caller — nobody is holding a stream yet to observe it on.
    @Test func aFailureBeforeTheHeadIsThrownToTheCaller() async throws {
        StubURLProtocol.reset(handler: { _ in
            StubURLProtocol.Response(error: URLError(.cannotConnectToHost))
        })
        let body = ChunkedBody(configuration: StubURLProtocol.makeConfiguration())

        await #expect(throws: (any Error).self) {
            _ = try await body.fetch(URLRequest(url: URL(string: "https://example.com/x")!))
        }
    }

    /// Resuming a continuation twice traps the process, so the guard has to
    /// hold under concurrency, not just in sequence.
    @Test func onceBoxRunsExactlyOnceUnderConcurrentCalls() async {
        let box = OnceBox()
        let counter = Counter()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<64 {
                group.addTask { box.once { counter.increment() } }
            }
        }
        #expect(counter.value == 1)
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
        func increment() { lock.lock(); count += 1; lock.unlock() }
    }
}
