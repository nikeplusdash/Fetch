import Foundation
import Testing

/// Deterministic HTTP for tests. Register on an ephemeral configuration and
/// script responses per request. Supports scripting a sequence so retry paths
/// can be exercised (fail, fail, succeed).
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response: Sendable {
        var status: Int = 200
        var headers: [String: String] = [:]
        var body: Data = Data()
        var error: (any Error)?

        static func json(_ string: String, status: Int = 200) -> Response {
            Response(status: status,
                     headers: ["Content-Type": "application/json"],
                     body: Data(string.utf8))
        }
    }

    /// Answers per request rather than in order. Concurrent range requests
    /// arrive in nondeterministic order, so a FIFO queue cannot serve them —
    /// a segmented download needs the response to depend on the `Range`
    /// header, not on which task happened to start first.
    nonisolated(unsafe) private static var handler: (@Sendable (URLRequest) -> Response)?

    static func reset(handler: @escaping @Sendable (URLRequest) -> Response) {
        lock.lock(); defer { lock.unlock() }
        Self.handler = handler
        queue = []
        recorded = []
        recordedBodies = []
    }

    /// Consumed front-to-back; the last entry repeats once exhausted.
    nonisolated(unsafe) private static var queue: [Response] = []
    nonisolated(unsafe) private static var recorded: [URLRequest] = []
    private static let lock = NSLock()

    static func reset(_ responses: [Response]) {
        lock.lock(); defer { lock.unlock() }
        queue = responses
        handler = nil
        recorded = []
        recordedBodies = []
    }

    static func next(for request: URLRequest) -> Response {
        lock.lock(); defer { lock.unlock() }
        if let handler { return handler(request) }
        if queue.count > 1 { return queue.removeFirst() }
        return queue.first ?? Response()
    }

    nonisolated(unsafe) private static var recordedBodies: [Data?] = []

    static func record(_ request: URLRequest) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(request)
        recordedBodies.append(resolveBody(of: request))
    }

    /// `URLSession` converts `httpBody` into `httpBodyStream` before a
    /// `URLProtocol` ever sees the request, so `recorded[i].httpBody` is nil
    /// even for a POST that plainly has one. Draining the stream here is the
    /// only way a test can assert on what was actually sent.
    private static func resolveBody(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }

        stream.open()
        defer { stream.close() }

        var data = Data()
        let size = 4096
        var buffer = [UInt8](repeating: 0, count: size)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    /// Lock-guarded snapshot. Tests must use this, never the storage.
    static func recordedRequests() -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    /// Bodies of the recorded requests, positionally aligned with
    /// `recordedRequests()`. Use this rather than `request.httpBody`.
    static func recordedBody(at index: Int) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return recordedBodies.indices.contains(index) ? recordedBodies[index] : nil
    }

    static func lastRecordedBody() -> Data? {
        lock.lock(); defer { lock.unlock() }
        return recordedBodies.last ?? nil
    }

    /// Configuration for `ChunkedBody`, which owns its own session because it
    /// needs a delegate.
    static func makeConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return config
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.record(request)
        let response = Self.next(for: request)

        if let error = response.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }

        let http = HTTPURLResponse(
            url: request.url!,
            statusCode: response.status,
            httpVersion: "HTTP/1.1",
            headerFields: response.headers
        )!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// `@Suite(.serialized)` only serializes the tests *within* one suite —
/// swift-testing still runs sibling suites concurrently by default. Since
/// `StubURLProtocol`'s `queue`/`recorded` are process-global, two suites
/// that both use the stub (e.g. `HTTPClientTests` and `TorBoxCacheTests`)
/// can still interleave `reset()`/`next()`/`recordedRequests()` calls and
/// clobber each other — the `NSLock` above only prevents memory corruption,
/// not this logical race. Every suite touching `StubURLProtocol` must also
/// apply `.usesStubURLProtocol`, which funnels all such tests through one
/// global FIFO async lock so at most one runs at a time, package-wide.
struct StubProtocolIsolationTrait: TestTrait, SuiteTrait, TestScoping {
    func provideScope(
        for test: Test, testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        await StubProtocolGate.shared.acquire()
        do {
            try await function()
        } catch {
            await StubProtocolGate.shared.release()
            throw error
        }
        await StubProtocolGate.shared.release()
    }
}

extension Trait where Self == StubProtocolIsolationTrait {
    static var usesStubURLProtocol: Self { StubProtocolIsolationTrait() }
}

/// FIFO async mutex. Waiters suspend via a continuation instead of blocking
/// a Concurrency thread-pool worker, so this cannot exhaust or deadlock the
/// cooperative pool the way a blocking `NSLock` held across an `await` could.
private actor StubProtocolGate {
    static let shared = StubProtocolGate()
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isLocked {
            isLocked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        guard !waiters.isEmpty else {
            isLocked = false
            return
        }
        waiters.removeFirst().resume()
    }
}
