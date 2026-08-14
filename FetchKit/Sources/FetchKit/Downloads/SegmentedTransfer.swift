import Foundation

/// Fetches one file over several parallel byte ranges.
///
/// **What this buys.** `RangeTransfer` opens exactly one connection per file,
/// so a single-file torrent downloads at whatever one stream yields no matter
/// how the engine's `maxConcurrent` is set. Eight ranges in parallel is what
/// actually saturates a debrid link — the reason to pay for one.
///
/// **What it costs.** The partial file now has holes while in flight, so its
/// size no longer means "how much is done". `SegmentMap` takes over that job
/// and is persisted with the download record.
public actor SegmentedTransfer {
    private let body: ChunkedBody
    private let maxSegments: Int

    /// **Measured, not assumed.** Against a live TorBox account over a 190 MB
    /// slice, two runs on separate links:
    ///
    ///     segments   run 1        run 2
    ///        1       6.9 MB/s     8.6 MB/s
    ///        4       9.6 MB/s    10.5 MB/s   <- best both times
    ///        8       9.4 MB/s    10.1 MB/s
    ///       16       8.8 MB/s     9.5 MB/s
    ///
    /// Absolute throughput moved ~20% between runs, but the ordering did not:
    /// 4 won both, and more than 4 was consistently *worse*. Past that point
    /// the bottleneck stops being per-connection — it becomes the line or the
    /// account's aggregate cap — and extra streams only add overhead.
    ///
    /// **One.** Measured, twice, against two unrelated hosts.
    ///
    /// | segments | TorBox CDN | archive.org |
    /// |---|---|---|
    /// | 1 | **9.2 MB/s** | **9.2 MB/s** |
    /// | 3 | — | 5.8 MB/s |
    /// | 4 | 8.9 MB/s | — |
    /// | 8 | 8.1 MB/s | 7.8 MB/s |
    /// | 16 | 8.7 MB/s | 8.7 MB/s |
    ///
    /// A single connection was fastest every time, and splitting cost up to
    /// 37%. It also skips this whole path: below 2 segments the engine uses
    /// `RangeTransfer` directly, so there is no preallocation, no seek per
    /// chunk, and no `SegmentWriter` actor funnelling every segment's writes
    /// through one serialized owner.
    ///
    /// 8 was the original default purely because download accelerators use it;
    /// 4 replaced it on a two-run measurement that only compared 4 and 8. This
    /// is the first measurement that included 1.
    ///
    /// Kept configurable rather than removed: this was measured on a ~90 Mbps
    /// line that one TCP stream saturates. On a connection fast enough that it
    /// does not, splitting should win. Re-measure with
    /// `LiveSegmentBenchmarkTests` before assuming otherwise.
    public static let defaultSegments = 1
    /// A ceiling rather than a recommendation: no debrid documents a
    /// connection limit, so an unbounded fan-out is not something to point at
    /// one — and the measurement says it would be slower anyway.
    public static let maxSegmentsAllowed = 16

    /// How many times one segment's *request* is retried when the server
    /// answers with something transient (429, 5xx).
    ///
    /// Retried at the head, never mid-body: a stream that dies after writing
    /// half a segment has already moved `ProgressCounter`, and re-running it
    /// would count those bytes twice. A mid-body failure still fails the
    /// segment, and the engine's resume path refetches it against the map.
    static let maxAttemptsPerSegment = 3

    /// Base backoff between those attempts, doubling each time. Injectable so
    /// the retry tests do not spend seven real seconds asleep.
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

    /// The clamped segment count actually in use.
    var segmentLimit: Int { maxSegments }

    public struct Progress: Sendable {
        public let bytesComplete: Int64
        public let totalBytes: Int64
    }

    /// Downloads every gap in `map` into `partial`, returning the updated map.
    ///
    /// The file is preallocated so segments can write at their own offsets
    /// without extending it; without that, a segment writing at 4 GB into a
    /// zero-length file would have to zero-fill everything before it.
    /// `onSegmentComplete` fires the moment a range lands, not at the end.
    /// Without it, pausing or losing the connection mid-transfer would throw
    /// away every finished segment — the map would still say zero.
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

        // Progress is aggregated here rather than per segment, because eight
        // independent counters would make the UI's single bar meaningless.
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

            // Bounded to maxSegments in flight: the gap list after a resume can
            // be far longer than the segment count, and firing all of them at
            // once is exactly the unbounded fan-out the cap exists to prevent.
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
        // Closed range, unlike RangeTransfer's open-ended form: a segment must
        // stop at its boundary or it would overwrite the next one's bytes.
        request.setValue(
            "bytes=\(range.lowerBound)-\(range.upperBound - 1)",
            forHTTPHeaderField: "Range")

        var attempt = 0
        while true {
            // Chunks, never `session.bytes(for:)`: that yields one UInt8 per
            // async suspension, ~26 million for a 25 MB file, and it is what
            // made downloads crawl no matter how many connections were open.
            let stream: ChunkedBody.Stream
            do {
                stream = try await body.fetch(request)
            } catch {
                // A connection that never got a response is the same kind of
                // transient as a 503, and was the same kind of terminal: one
                // dropped connection killed the download. Retried here rather
                // than mid-body, for the reason on `maxAttemptsPerSegment` —
                // nothing has been read yet, so nothing can be double-counted.
                //
                // Both shapes are matched because `ChunkedBody` emits both: a
                // failure before the head arrives is forwarded as the session's
                // own `URLError`, while its own rejections are `NetworkError`.
                // Matching only the tidy one would have retried nothing at all.
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

            // Everything below used to be one line: `guard status == 206 else
            // { throw .rangeNotSupported }`. That reported an expired link, a
            // rate limit and an outage as "this server does not support
            // ranges", never retried any of them, and killed the download
            // permanently on the first one — which is the whole of the
            // "DownloadError error 6 after multiple downloads" report. With
            // `segmentsPerFile > 1` and several downloads running, a debrid
            // CDN produces these routinely.
            switch status {
            case 200:
                // The only status that genuinely means what the old error
                // said: the server ignored `Range` and is sending the whole
                // file down every segment. Writing that at segment offsets
                // corrupts the output silently, so it must not be written —
                // but the download is not lost: the engine falls back to one
                // whole-file transfer.
                throw DownloadError.rangeNotSupported(status: status)

            case 403, 410:
                // A debrid link is credentialed and time-limited. Re-resolving
                // it is the engine's job, because it is the thing that holds
                // the provider.
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

    /// The `URLError` inside whichever wrapper this arrived in, or nil when
    /// the failure is not a transport one and retrying cannot help.
    private static func transportError(_ error: any Error) -> URLError? {
        if case .transport(let urlError)? = error as? NetworkError { return urlError }
        return error as? URLError
    }

    /// Doubling from `retryDelay`: 1s, 2s, 4s at the default.
    private func backOff(_ attempt: Int) async throws {
        let delay = retryDelay * pow(2, Double(attempt - 1))
        guard delay > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
    }

    /// Creates the file at full length so segments can seek within it.
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

/// Serializes writes to the one partial file.
///
/// Segments write at disjoint offsets, so they could in principle use separate
/// handles — but the engine's one-writer-per-partial invariant is easier to
/// keep true with a single owner, and disk writes are far cheaper than the
/// network fetches feeding them.
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

/// Aggregates progress across segments into one figure.
actor ProgressCounter {
    private var bytes: Int64
    private let total: Int64
    private var lastReport = Date.distantPast

    init(base: Int64, total: Int64) {
        self.bytes = base
        self.total = total
    }

    /// Coalesced to ~10/sec, matching the engine's own rule: raw byte
    /// callbacks fire thousands of times a second and would melt SwiftUI
    /// diffing (§9).
    func add(_ count: Int64, report: @Sendable (SegmentedTransfer.Progress) -> Void) {
        bytes += count
        let now = Date()
        guard now.timeIntervalSince(lastReport) >= 0.1 || bytes >= total else { return }
        lastReport = now
        report(SegmentedTransfer.Progress(bytesComplete: bytes, totalBytes: total))
    }
}
