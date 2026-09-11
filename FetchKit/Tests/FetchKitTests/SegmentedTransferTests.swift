import Testing
import Foundation
@testable import FetchKit

@Suite(.serialized, .usesStubURLProtocol) struct SegmentedTransferTests {
    private static func content(_ size: Int) -> Data {
        Data((0..<size).map { UInt8($0 % 251) })
    }

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
            retryDelay: 0)
    }


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
        #expect(ranges.allSatisfy { $0.contains("-") && !$0.hasSuffix("-") })
    }


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

    @Test func aRateLimitIsRetriedAndThenReportedAsNetwork() async throws {
        await #expect(throws: DownloadError.network("HTTP 429")) {
            _ = try await self.transferring { _ in
                StubURLProtocol.Response(status: 429)
            }
        }
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

    @Test func aTransientFailureThatClearsCompletesTheDownload() async throws {
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

    @Test func aNotFoundIsReportedImmediatelyWithoutRetrying() async throws {
        await #expect(throws: DownloadError.network("HTTP 404")) {
            _ = try await self.transferring(
                { _ in StubURLProtocol.Response(status: 404) }, segments: 1)
        }
        #expect(StubURLProtocol.recordedRequests().count == 1)
    }


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

        #expect(box.seen == box.seen.sorted())
        #expect(box.seen.allSatisfy { $0 <= 400_000 })
    }


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
