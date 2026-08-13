import Foundation

/// Streams a response body as `Data` chunks.
///
/// **Why this exists.** `URLSession.bytes(for:)` returns an `AsyncSequence` of
/// `UInt8`, so `for try await byte in bytes` performs one async suspension per
/// **byte** — roughly 26 million of them for a 25 MB file. That is what made
/// downloads crawl regardless of how many connections were open; parallel
/// segments each iterating byte-by-byte are still iterating byte-by-byte.
///
/// A `URLSessionDataDelegate` hands over whole `Data` chunks as they arrive,
/// which is what the networking stack produces anyway.
///
/// **One session, for the actor's lifetime.** This used to build a fresh
/// `URLSession` per request, so every segment and every retry paid a new TCP
/// and TLS handshake and no connection was ever reused. Noise on a 200 MB
/// movie; on a source of 500 KB books it is most of the transfer. The cost of
/// sharing is that one delegate now serves many tasks, so all per-task state
/// is keyed by `taskIdentifier`.
public actor ChunkedBody {
    public struct Head: Sendable {
        public let statusCode: Int
        /// Flattened to strings on the way out: `allHeaderFields` is
        /// `[AnyHashable: Any]`, which cannot cross an isolation boundary.
        public let headers: [String: String]

        public func value(forHeader name: String) -> String? {
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
    }

    /// Response head, then the body in chunks.
    public struct Stream: Sendable {
        public let head: Head
        public let chunks: AsyncThrowingStream<Data, any Error>
    }

    private let session: URLSession
    private let multiplexer: ChunkMultiplexer

    public init(configuration: URLSessionConfiguration = ChunkedBody.defaultConfiguration()) {
        let multiplexer = ChunkMultiplexer()
        self.multiplexer = multiplexer
        self.session = URLSession(
            configuration: configuration, delegate: multiplexer, delegateQueue: nil)
    }

    /// The session retains its delegate, so both would live for the process's
    /// lifetime without this.
    deinit { session.finishTasksAndInvalidate() }

    public static func defaultConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 60
        // Long transfers: a 60 GB remux on a slow line legitimately takes hours.
        configuration.timeoutIntervalForResource = 60 * 60 * 24
        // The session is shared for the actor's lifetime (see the type doc),
        // so this knob is not academic: the default of 6 would silently
        // throttle configurations the Settings UI openly offers, with nothing
        // to tell the user why a download is slow.
        //
        // **It is a limit, not a reservation.** Nothing is preallocated;
        // `URLSession` opens what the work in flight actually needs. That is
        // what makes covering the worst case free, and covering it is the
        // point: `maxConcurrent` (up to 10) and
        // `SegmentedTransfer.maxSegmentsAllowed` (16) compound
        // multiplicatively when several downloads share a host, so the true
        // worst case is 10 × 16 = 160 — not the 26 you get by adding the
        // maxima.
        //
        // This used to be 32, reasoning that 160 connections to one host
        // would be hostile and — per this repo's own measurements — slower
        // rather than faster. Both true, and neither is a reason to *fail*:
        // exceeding the cap does not degrade gracefully. Excess tasks queue
        // inside `URLSession` with their request timers already running, so
        // with both sliders raised, 128 of 160 tasks time out and the
        // download dies. The politeness argument is real but it is not this
        // layer's to make — the two sliders are where the user makes it, and
        // a setting the UI offers must not silently break the thing it
        // configures. Keep this at the product of the two maxima; if either
        // maximum changes, change this with it.
        configuration.httpMaximumConnectionsPerHost = maxConnectionsPerHost
        return configuration
    }

    /// 10 (`maxConcurrent`'s ceiling) × 16 (`maxSegmentsAllowed`) — every
    /// request the two Settings sliders can put in flight against one host at
    /// once.
    public static let maxConnectionsPerHost = 160

    public func fetch(_ request: URLRequest) async throws -> Stream {
        let task = session.dataTask(with: request)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Resuming a continuation twice traps. Two paths can report
                // the same failure — see `ChunkMultiplexer`.
                let guardBox = OnceBox()
                // Registered *before* `resume`: a cached or immediately-failing
                // request can deliver its response before this line would
                // otherwise run.
                multiplexer.register(
                    taskIdentifier: task.taskIdentifier,
                    onHead: { head, chunks in
                        guardBox.once { continuation.resume(returning: Stream(head: head, chunks: chunks)) }
                    },
                    onEarlyFailure: { error in
                        guardBox.once { continuation.resume(throwing: error) }
                    })
                task.resume()
            }
        } onCancel: {
            // Covers cancellation while awaiting the head. Cancellation while
            // draining `chunks` is covered separately by the stream's
            // `onTermination` in `ChunkMultiplexer`, since by then this
            // continuation has already resumed and this handler is gone.
            //
            // Without this, cancelling the Swift `Task` (a pause, or the
            // `for try await` in `RangeTransfer` unwinding) unwinds the
            // caller but leaves the `URLSessionDataTask` running for up to
            // `timeoutIntervalForResource` — 24 hours. That used to only
            // waste bandwidth, because each request owned its own session
            // and pool. Now the session and its per-host connection slots
            // are shared, so a zombie task can starve every new request to
            // that host.
            task.cancel()
        }
    }
}

/// Bridges `URLSessionDataDelegate` callbacks into per-task
/// `AsyncThrowingStream`s.
///
/// One instance serves every task on the shared session, so every piece of
/// state here is keyed by `taskIdentifier`. Entries are removed on completion;
/// a long-running app would otherwise accumulate one per download forever.
private final class ChunkMultiplexer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct Entry {
        let onHead: (ChunkedBody.Head, AsyncThrowingStream<Data, any Error>) -> Void
        let onEarlyFailure: (any Error) -> Void
        var continuation: AsyncThrowingStream<Data, any Error>.Continuation?
        var deliveredHead = false
    }

    private var entries: [Int: Entry] = [:]
    private let lock = NSLock()

    func register(
        taskIdentifier: Int,
        onHead: @escaping (ChunkedBody.Head, AsyncThrowingStream<Data, any Error>) -> Void,
        onEarlyFailure: @escaping (any Error) -> Void
    ) {
        lock.lock(); defer { lock.unlock() }
        entries[taskIdentifier] = Entry(onHead: onHead, onEarlyFailure: onEarlyFailure)
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let id = dataTask.taskIdentifier

        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            lock.lock()
            let entry = entries[id]
            lock.unlock()
            // The cancel above makes `didCompleteWithError` fire too, which
            // would report this same failure a second time. `OnceBox` in
            // `fetch` is what makes that safe instead of a trap.
            entry?.onEarlyFailure(NetworkError.transport(URLError(.badServerResponse)))
            return
        }

        let stream = AsyncThrowingStream<Data, any Error> { continuation in
            lock.lock()
            entries[id]?.continuation = continuation
            lock.unlock()
            // Covers cancellation while draining chunks: if the consumer's
            // `for try await` unwinds (a pause, or the task group in
            // `RangeTransfer` cancelling a sibling), the stream is dropped
            // and this fires — without it the `URLSessionDataTask` would
            // keep running and holding a shared connection slot for up to
            // `timeoutIntervalForResource`.
            continuation.onTermination = { _ in dataTask.cancel() }
        }

        lock.lock()
        entries[id]?.deliveredHead = true
        let entry = entries[id]
        lock.unlock()

        entry?.onHead(
            ChunkedBody.Head(
                statusCode: http.statusCode,
                headers: Dictionary(
                    http.allHeaderFields.compactMap { key, value in
                        guard let key = key as? String else { return nil }
                        return (key, String(describing: value))
                    },
                    uniquingKeysWith: { first, _ in first })),
            stream)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let continuation = entries[dataTask.taskIdentifier]?.continuation
        lock.unlock()
        continuation?.yield(data)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
    ) {
        lock.lock()
        let entry = entries.removeValue(forKey: task.taskIdentifier)
        lock.unlock()

        guard let entry else { return }

        if let error {
            // A failure before the head means nobody is holding the stream to
            // observe it — surface it to the awaiting caller instead.
            if entry.deliveredHead {
                entry.continuation?.finish(throwing: error)
            } else {
                entry.onEarlyFailure(error)
            }
        } else if entry.deliveredHead {
            entry.continuation?.finish()
        } else {
            // No error and no head: unreachable over real HTTP, but if it
            // ever happened, `entry.continuation` is nil here, so doing
            // nothing would leave the `fetch` continuation unresumed
            // forever — a permanent hang plus a continuation-misuse leak.
            // An error at least gives the caller something to show instead
            // of a download stuck at 0%.
            entry.onEarlyFailure(NetworkError.transport(URLError(.unknown)))
        }
    }
}
