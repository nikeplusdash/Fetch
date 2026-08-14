import Testing
import Foundation
@testable import FetchKit

/// Parallel range fetches into one file.
///
/// The stub answers per request from its `Range` header rather than from a
/// queue, because segments arrive in nondeterministic order — a FIFO harness
/// would serve segment 3 the bytes meant for segment 1 and the test would pass
/// on a corrupt download.
@Suite(.serialized, .usesStubURLProtocol) struct SegmentedTransferTests {
    /// Deterministic content, so a misplaced write is detectable rather than
    /// merely "wrong length".
    private static func content(_ size: Int) -> Data {
        Data((0..<size).map { UInt8($0 % 251) })
    }

    /// Serves exactly the bytes asked for, as a well-formed 206.
    private static func rangeServer(_ whole: Data) -> @Sendable (URLRequest) -> StubURLProtocol.Response {
        { request in
            guard let header = request.value(forHTTPHeaderField: "Range"),
                  let spec = header.split(separator: "=").last
            else { return StubURLProtocol.Response(status: 200, body: whole) }

            let bounds = spec.split(separator: "-", omittingEmptySubsequences: false)
            let start = Int(bounds.first ?? "0") ?? 0
            let end = bounds.count > 1 ? (Int(bounds[1]) ?? whole.count - 1) : whole.count - 1
            let slice = whole[start...min(end, whole.count - 1)]

            return StubURLProtocol.Response(
                status: 206,
                headers: ["Content-Range": "bytes \(start)-\(end)/\(whole.count)"],
                body: Data(slice))
        }
    }

    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("seg-\(UUID().uuidString).part")
    }

    private func makeTransfer(segments: Int = 4) -> SegmentedTransfer {
        SegmentedTransfer(
            body: ChunkedBody(configuration: StubURLProtocol.makeConfiguration()),
            maxSegments: segments,
            // The retry path is under test, not the clock. At the real 1s base
            // the backoff tests would sleep for seven seconds each.
            retryDelay: 0)
    }

    // MARK: - Correctness

    /// The bar every other test is measured against: the bytes on disk must
    /// equal the bytes the server holds, byte for byte.
    @Test func aSegmentedDownloadReassemblesTheFileExactly() async throws {
        let whole = Self.content(10_000)
        StubURLProtocol.reset(handler: Self.rangeServer(whole))

        let partial = temporaryFile()
        defer { try? FileManager.default.removeItem(at: partial) }

        let map = try await makeTransfer().transfer(
            from: URL(string: "https://cdn.example/file")!,
            to: partial,
            map: SegmentMap(totalBytes: 10_000, segments: 4),
            onProgress: { _ in })

        #expect(map.isComplete)
        #expect(try Data(contentsOf: partial) == whole)
    }

    @Test func everySegmentIsRequestedAsAClosedRange() async throws {
        let whole = Self.content(1_000)
        StubURLProtocol.reset(handler: Self.rangeServer(whole))

        let partial = temporaryFile()
        defer { try? FileManager.default.removeItem(at: partial) }

        _ = try await makeTransfer().transfer(
            from: URL(string: "https://cdn.example/file")!,
            to: partial,
            map: SegmentMap(totalBytes: 1_000, segments: 4),
            onProgress: { _ in })

        let ranges = StubURLProtocol.recordedRequests()
            .compactMap { $0.value(forHTTPHeaderField: "Range") }
            .sorted()

        #expect(ranges.count == 4)
        // Closed, never open-ended: an open range would overrun into the next
        // segment's bytes and the later write would win.
        #expect(ranges.allSatisfy { $0.contains("-") && !$0.hasSuffix("-") })
    }

    // MARK: - Resume

    /// Only the holes are refetched, which is the entire justification for
    /// persisting a segment map.
    @Test func resumingRefetchesOnlyTheMissingRanges() async throws {
        let whole = Self.content(1_000)
        StubURLProtocol.reset(handler: Self.rangeServer(whole))

        let partial = temporaryFile()
        defer { try? FileManager.default.removeItem(at: partial) }

        var map = SegmentMap(totalBytes: 1_000, segments: 4)
        map.markComplete(0..<250)
        map.markComplete(500..<750)

        let finished = try await makeTransfer().transfer(
            from: URL(string: "https://cdn.example/file")!,
            to: partial, map: map, onProgress: { _ in })

        #expect(finished.isComplete)
        let requested = StubURLProtocol.recordedRequests()
            .compactMap { $0.value(forHTTPHeaderField: "Range") }
        #expect(requested.count == 2)
        #expect(Set(requested) == ["bytes=250-499", "bytes=750-999"])
    }

    @Test func anAlreadyCompleteMapMakesNoRequests() async throws {
        StubURLProtocol.reset(handler: Self.rangeServer(Self.content(100)))

        let partial = temporaryFile()
        defer { try? FileManager.default.removeItem(at: partial) }

        var map = SegmentMap(totalBytes: 100, segments: 4)
        for range in map.remaining { map.markComplete(range) }

        _ = try await makeTransfer().transfer(
            from: URL(string: "https://cdn.example/file")!,
            to: partial, map: map, onProgress: { _ in })

        #expect(StubURLProtocol.recordedRequests().isEmpty)
    }

    // MARK: - Failure

    /// A server that ignores `Range` and sends the whole body must be refused.
    /// Writing a full file at each segment's offset would corrupt the output
    /// silently — the download would "succeed" and the file would be garbage.
    @Test func aServerIgnoringRangeIsRejectedRatherThanWrittenBlindly() async throws {
        let whole = Self.content(1_000)
        StubURLProtocol.reset(handler: { _ in
            StubURLProtocol.Response(status: 200, body: whole)
        })

        let partial = temporaryFile()
        defer { try? FileManager.default.removeItem(at: partial) }

        await #expect(throws: DownloadError.rangeNotSupported(status: 200)) {
            _ = try await makeTransfer().transfer(
                from: URL(string: "https://cdn.example/file")!,
                to: partial,
                map: SegmentMap(totalBytes: 1_000, segments: 4),
                onProgress: { _ in })
        }
    }

    // MARK: - Status codes are not all "range not supported"
    //
    // The reported bug: `FetchKit.DownloadError error 6` — which is
    // `.rangeNotSupported`, not `.debrid`, because Swift numbers payload cases
    // before payload-free ones. Every non-206 answer used to become that one
    // error, unretried and terminal. With `segmentsPerFile > 1` and several
    // downloads in flight, a debrid CDN produces 403s and 429s routinely, and
    // each one permanently killed a download that a fresh link or one retry
    // would have finished.

    private func transferring(
        _ handler: @escaping @Sendable (URLRequest) -> StubURLProtocol.Response,
        segments: Int = 2, total: Int = 1_000
    ) async throws -> SegmentMap {
        StubURLProtocol.reset(handler: handler)
        let partial = temporaryFile()
        defer { try? FileManager.default.removeItem(at: partial) }
        return try await makeTransfer(segments: segments).transfer(
            from: URL(string: "https://cdn.example/file")!,
            to: partial,
            map: SegmentMap(totalBytes: Int64(total), segments: segments),
            onProgress: { _ in })
    }

    /// An expired debrid link is `.linkExpired`, so the engine knows to ask for
    /// a fresh one. Calling it "range not supported" told the engine the
    /// opposite — that re-requesting could not help.
    @Test func anExpiredLinkIsReportedAsExpiredNotAsRangeUnsupported() async throws {
        await #expect(throws: DownloadError.linkExpired) {
            _ = try await self.transferring { _ in
                StubURLProtocol.Response(status: 403)
            }
        }
    }

    @Test func aGoneLinkIsAlsoReportedAsExpired() async throws {
        await #expect(throws: DownloadError.linkExpired) {
            _ = try await self.transferring { _ in
                StubURLProtocol.Response(status: 410)
            }
        }
    }

    /// Rate limiting is transient by definition, so it is retried before it is
    /// reported — and reported as itself when the retries run out.
    @Test func aRateLimitIsRetriedAndThenReportedAsNetwork() async throws {
        await #expect(throws: DownloadError.network("HTTP 429")) {
            _ = try await self.transferring { _ in
                StubURLProtocol.Response(status: 429)
            }
        }
        // Three attempts per segment, two segments.
        #expect(StubURLProtocol.recordedRequests().count
                == SegmentedTransfer.maxAttemptsPerSegment * 2)
    }

    @Test func aServerErrorIsRetriedAndThenReportedAsNetwork() async throws {
        await #expect(throws: DownloadError.network("HTTP 503")) {
            _ = try await self.transferring { _ in
                StubURLProtocol.Response(status: 503)
            }
        }
    }

    /// The point of the retry: a 429 that clears on the second attempt is a
    /// download that finishes, not one the user has to notice and resume.
    @Test func aTransientFailureThatClearsCompletesTheDownload() async throws {
        let whole = Self.content(1_000)
        let serve = Self.rangeServer(whole)

        final class Attempts: @unchecked Sendable {
            private var seen: Set<String> = []
            private let lock = NSLock()
            /// True the first time each distinct range is asked for.
            func isFirst(_ key: String) -> Bool {
                lock.lock(); defer { lock.unlock() }
                return seen.insert(key).inserted
            }
        }
        let attempts = Attempts()

        StubURLProtocol.reset(handler: { request in
            let key = request.value(forHTTPHeaderField: "Range") ?? ""
            if attempts.isFirst(key) { return StubURLProtocol.Response(status: 429) }
            return serve(request)
        })

        let partial = temporaryFile()
        defer { try? FileManager.default.removeItem(at: partial) }

        let map = try await makeTransfer(segments: 2).transfer(
            from: URL(string: "https://cdn.example/file")!,
            to: partial,
            map: SegmentMap(totalBytes: 1_000, segments: 2),
            onProgress: { _ in })

        #expect(map.isComplete)
        #expect(try Data(contentsOf: partial) == whole)
    }

    /// A dropped connection is the same kind of transient as a 503, and used
    /// to be the same kind of terminal — the segment threw and the whole
    /// download died with it.
    @Test func aDroppedConnectionIsRetried() async throws {
        let whole = Self.content(1_000)
        let serve = Self.rangeServer(whole)

        final class Attempts: @unchecked Sendable {
            private var seen: Set<String> = []
            private let lock = NSLock()
            func isFirst(_ key: String) -> Bool {
                lock.lock(); defer { lock.unlock() }
                return seen.insert(key).inserted
            }
        }
        let attempts = Attempts()

        StubURLProtocol.reset(handler: { request in
            let key = request.value(forHTTPHeaderField: "Range") ?? ""
            if attempts.isFirst(key) {
                return StubURLProtocol.Response(error: URLError(.networkConnectionLost))
            }
            return serve(request)
        })

        let partial = temporaryFile()
        defer { try? FileManager.default.removeItem(at: partial) }

        let map = try await makeTransfer(segments: 2).transfer(
            from: URL(string: "https://cdn.example/file")!,
            to: partial,
            map: SegmentMap(totalBytes: 1_000, segments: 2),
            onProgress: { _ in })

        #expect(map.isComplete)
        #expect(try Data(contentsOf: partial) == whole)
    }

    /// A connection that keeps dropping is a real failure, and it is reported
    /// rather than retried forever.
    @Test func aConnectionThatNeverRecoversFails() async throws {
        StubURLProtocol.reset(handler: { _ in
            StubURLProtocol.Response(error: URLError(.networkConnectionLost))
        })
        let partial = temporaryFile()
        defer { try? FileManager.default.removeItem(at: partial) }

        await #expect(throws: (any Error).self) {
            _ = try await self.makeTransfer(segments: 1).transfer(
                from: URL(string: "https://cdn.example/file")!,
                to: partial,
                map: SegmentMap(totalBytes: 1_000, segments: 1),
                onProgress: { _ in })
        }
        #expect(StubURLProtocol.recordedRequests().count
                == SegmentedTransfer.maxAttemptsPerSegment)
    }

    /// A status with no transient reading is not retried — retrying a 404
    /// three times just makes the user wait longer for the same answer.
    @Test func aNotFoundIsReportedImmediatelyWithoutRetrying() async throws {
        await #expect(throws: DownloadError.network("HTTP 404")) {
            _ = try await self.transferring(
                { _ in StubURLProtocol.Response(status: 404) }, segments: 1)
        }
        #expect(StubURLProtocol.recordedRequests().count == 1)
    }

    // MARK: - Progress

    @Test func progressIsReportedAsOneAggregateFigure() async throws {
        let whole = Self.content(400_000)
        StubURLProtocol.reset(handler: Self.rangeServer(whole))

        let partial = temporaryFile()
        defer { try? FileManager.default.removeItem(at: partial) }

        final class Box: @unchecked Sendable {
            var seen: [Int64] = []
            let lock = NSLock()
            func record(_ value: Int64) { lock.lock(); seen.append(value); lock.unlock() }
        }
        let box = Box()

        _ = try await makeTransfer().transfer(
            from: URL(string: "https://cdn.example/file")!,
            to: partial,
            map: SegmentMap(totalBytes: 400_000, segments: 4),
            onProgress: { box.record($0.bytesComplete) })

        // Monotonic and never exceeding the total — eight independent counters
        // would give neither.
        #expect(box.seen == box.seen.sorted())
        #expect(box.seen.allSatisfy { $0 <= 400_000 })
    }

    // MARK: - Bounds

    @Test func theSegmentCountIsCappedAtSixteen() async {
        let transfer = SegmentedTransfer(
            body: ChunkedBody(configuration: StubURLProtocol.makeConfiguration()),
            maxSegments: 500)
        #expect(await transfer.segmentLimit == SegmentedTransfer.maxSegmentsAllowed)
    }

    @Test func atLeastOneSegmentIsAlwaysUsed() async {
        let transfer = SegmentedTransfer(
            body: ChunkedBody(configuration: StubURLProtocol.makeConfiguration()),
            maxSegments: 0)
        #expect(await transfer.segmentLimit == 1)
    }
}
