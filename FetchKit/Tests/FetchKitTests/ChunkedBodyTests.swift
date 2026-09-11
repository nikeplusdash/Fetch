import Testing
import Foundation
@testable import FetchKit

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

    @Test func concurrentFetchesDoNotCrossStreams() async throws {
        StubURLProtocol.reset(handler: { request in
            let name = request.url?.lastPathComponent ?? "?"
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

    @Test func aFailureBeforeTheHeadIsThrownToTheCaller() async throws {
        StubURLProtocol.reset(handler: { _ in
            StubURLProtocol.Response(error: URLError(.cannotConnectToHost))
        })
        let body = ChunkedBody(configuration: StubURLProtocol.makeConfiguration())

        await #expect(throws: (any Error).self) {
            _ = try await body.fetch(URLRequest(url: URL(string: "https://example.com/x")!))
        }
    }

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
