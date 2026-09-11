import Foundation

/**
 Streams a response body as `Data` chunks.

 **Why this exists.** `URLSession.bytes(for:)` returns an `AsyncSequence` of
 `UInt8`, so `for try await byte in bytes` performs one async suspension per
 **byte** — roughly 26 million of them for a 25 MB file. That is what made
 downloads crawl regardless of how many connections were open; parallel
 segments each iterating byte-by-byte are still iterating byte-by-byte.

 A `URLSessionDataDelegate` hands over whole `Data` chunks as they arrive,
 which is what the networking stack produces anyway.

 **One session, for the actor's lifetime.** This used to build a fresh
 `URLSession` per request, so every segment and every retry paid a new TCP
 and TLS handshake and no connection was ever reused. Noise on a 200 MB
 movie; on a source of 500 KB books it is most of the transfer. The cost of
 sharing is that one delegate now serves many tasks, so all per-task state
 is keyed by `taskIdentifier`.
 */
public actor ChunkedBody {
    public struct Head: Sendable {
        public let statusCode: Int
        public let headers: [String: String]

        public func value(forHeader name: String) -> String? {
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
    }

    /**
     Response head, then the body in chunks.
     */
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

    deinit { session.finishTasksAndInvalidate() }

    public static func defaultConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60 * 60 * 24
        configuration.httpMaximumConnectionsPerHost = maxConnectionsPerHost
        return configuration
    }

    public static let maxConnectionsPerHost = 160

    public func fetch(_ request: URLRequest) async throws -> Stream {
        let task = session.dataTask(with: request)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let guardBox = OnceBox()
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
            task.cancel()
        }
    }
}

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
            entry?.onEarlyFailure(NetworkError.transport(URLError(.badServerResponse)))
            return
        }

        let stream = AsyncThrowingStream<Data, any Error> { continuation in
            lock.lock()
            entries[id]?.continuation = continuation
            lock.unlock()
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
            if entry.deliveredHead {
                entry.continuation?.finish(throwing: error)
            } else {
                entry.onEarlyFailure(error)
            }
        } else if entry.deliveredHead {
            entry.continuation?.finish()
        } else {
            entry.onEarlyFailure(NetworkError.transport(URLError(.unknown)))
        }
    }
}
