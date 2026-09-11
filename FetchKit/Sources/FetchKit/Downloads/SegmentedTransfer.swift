import Foundation

/**
 Fetches one file over several parallel byte ranges.

 **What this buys.** `RangeTransfer` opens exactly one connection per file,
 so a single-file torrent downloads at whatever one stream yields no matter
 how the engine's `maxConcurrent` is set. Eight ranges in parallel is what
 actually saturates a debrid link — the reason to pay for one.

 **What it costs.** The partial file now has holes while in flight, so its
 size no longer means "how much is done". `SegmentMap` takes over that job
 and is persisted with the download record.
 */
public actor SegmentedTransfer {
    private let body: ChunkedBody
    private let maxSegments: Int

    public static let defaultSegments = 1
    public static let maxSegmentsAllowed = 16

    static let maxAttemptsPerSegment = 3

    private let retryDelay: TimeInterval

    public init(
        body: ChunkedBody = ChunkedBody(),
        maxSegments: Int = SegmentedTransfer.defaultSegments,
        retryDelay: TimeInterval = 1.0
    ) {
        self.body = body
        self.maxSegments = min(max(1, maxSegments), Self.maxSegmentsAllowed)
        self.retryDelay = retryDelay
    }

    var segmentLimit: Int { maxSegments }

    public struct Progress: Sendable {
        public let bytesComplete: Int64
        public let totalBytes: Int64
    }

    /**
     Downloads every gap in `map` into `partial`, returning the updated map.

     The file is preallocated so segments can write at their own offsets
     without extending it; without that, a segment writing at 4 GB into a
     zero-length file would have to zero-fill everything before it.
     `onSegmentComplete` fires the moment a range lands, not at the end.
     Without it, pausing or losing the connection mid-transfer would throw
     away every finished segment — the map would still say zero.
     */
    public func transfer(
        from url: URL,
        to partial: URL,
        map initialMap: SegmentMap,
        onProgress: @Sendable @escaping (Progress) -> Void,
        onSegmentComplete: @Sendable @escaping (Range<Int64>) -> Void = { _ in }
    ) async throws -> SegmentMap {
        var map = initialMap
        guard !map.isComplete else { return map }

        try preallocate(partial, size: map.totalBytes)

        let writer = SegmentWriter(url: partial)
        defer { Task { await writer.close() } }

        let counter = ProgressCounter(base: map.bytesComplete, total: map.totalBytes)

        let gaps = map.remaining
        var completed: [Range<Int64>] = []

        try await withThrowingTaskGroup(of: Range<Int64>.self) { group in
            var running = 0
            var pending = gaps[...]

            func startNext() {
                guard let next = pending.first else { return }
                pending = pending.dropFirst()
                running += 1
                group.addTask {
                    try await self.fetch(
                        range: next, from: url, writer: writer,
                        counter: counter, onProgress: onProgress)
                    return next
                }
            }

            while running < maxSegments, !pending.isEmpty { startNext() }

            while let finished = try await group.next() {
                running -= 1
                completed.append(finished)
                onSegmentComplete(finished)
                if !pending.isEmpty { startNext() }
            }
        }

        for range in completed { map.markComplete(range) }
        return map
    }

    private func fetch(
        range: Range<Int64>,
        from url: URL,
        writer: SegmentWriter,
        counter: ProgressCounter,
        onProgress: @Sendable @escaping (Progress) -> Void
    ) async throws {
        var request = URLRequest(url: url)
        request.setValue(
            "bytes=\(range.lowerBound)-\(range.upperBound - 1)",
            forHTTPHeaderField: "Range")

        var attempt = 0
        while true {
            let stream: ChunkedBody.Stream
            do {
                stream = try await body.fetch(request)
            } catch {
                guard let urlError = Self.transportError(error),
                      urlError.code != .cancelled,
                      attempt + 1 < Self.maxAttemptsPerSegment
                else { throw error }
                attempt += 1
                try await backOff(attempt)
                continue
            }
            let status = stream.head.statusCode

            if status == 206 {
                var offset = range.lowerBound
                for try await chunk in stream.chunks {
                    guard !chunk.isEmpty else { continue }
                    try await writer.write(chunk, at: offset)
                    offset += Int64(chunk.count)
                    await counter.add(Int64(chunk.count), report: onProgress)
                }
                return
            }

            switch status {
            case 200:
                throw DownloadError.rangeNotSupported(status: status)

            case 403, 410:
                throw DownloadError.linkExpired

            case 429, 500...599:
                attempt += 1
                guard attempt < Self.maxAttemptsPerSegment else {
                    throw DownloadError.network("HTTP \(status)")
                }
                try await backOff(attempt)
                continue

            default:
                throw DownloadError.network("HTTP \(status)")
            }
        }
    }

    private static func transportError(_ error: any Error) -> URLError? {
        if case .transport(let urlError)? = error as? NetworkError { return urlError }
        return error as? URLError
    }

    private func backOff(_ attempt: Int) async throws {
        let delay = retryDelay * pow(2, Double(attempt - 1))
        guard delay > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
    }

    private func preallocate(_ url: URL, size: Int64) throws {
        let manager = FileManager.default
        try manager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        if !manager.fileExists(atPath: url.path) {
            manager.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(size))
    }
}

actor SegmentWriter {
    private var handle: FileHandle?
    private let url: URL

    init(url: URL) { self.url = url }

    func write(_ data: Data, at offset: Int64) throws {
        let handle = try existingHandle()
        try handle.seek(toOffset: UInt64(offset))
        try handle.write(contentsOf: data)
    }

    private func existingHandle() throws -> FileHandle {
        if let handle { return handle }
        let opened = try FileHandle(forWritingTo: url)
        handle = opened
        return opened
    }

    func close() {
        try? handle?.close()
        handle = nil
    }
}

actor ProgressCounter {
    private var bytes: Int64
    private let total: Int64
    private var lastReport = Date.distantPast

    init(base: Int64, total: Int64) {
        self.bytes = base
        self.total = total
    }

    func add(_ count: Int64, report: @Sendable (SegmentedTransfer.Progress) -> Void) {
        bytes += count
        let now = Date()
        guard now.timeIntervalSince(lastReport) >= 0.1 || bytes >= total else { return }
        lastReport = now
        report(SegmentedTransfer.Progress(bytesComplete: bytes, totalBytes: total))
    }
}
