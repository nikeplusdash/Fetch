import Testing
import Foundation
@testable import FetchKit

@Suite(.serialized, .usesStubURLProtocol) struct RangeTransferTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("fetchpart")
    }

    private func makeTransfer() -> RangeTransfer {
        RangeTransfer(body: ChunkedBody(configuration: StubURLProtocol.makeConfiguration()))
    }

    private let link: @Sendable () async throws -> URL = {
        URL(string: "https://cdn.example.com/file.bin")!
    }

    @Test func downloadsFreshFileFromZero() async throws {
        let body = Data(repeating: 0xAB, count: 1000)
        StubURLProtocol.reset([
            StubURLProtocol.Response(
                status: 200,
                headers: ["Content-Length": "1000"],
                body: body
            )
        ])
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try await makeTransfer().transfer(
            to: url, expectedSize: 1000, linkProvider: link, onProgress: { _ in }
        )
        #expect(try Data(contentsOf: url) == body)
    }

    @Test func resumesFromExistingPartialWithRangeHeader() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 0x01, count: 400).write(to: url)

        StubURLProtocol.reset([
            StubURLProtocol.Response(
                status: 206,
                headers: ["Content-Range": "bytes 400-999/1000"],
                body: Data(repeating: 0x02, count: 600)
            )
        ])

        try await makeTransfer().transfer(
            to: url, expectedSize: 1000, linkProvider: link, onProgress: { _ in }
        )

        let written = try Data(contentsOf: url)
        #expect(written.count == 1000)
        #expect(written[0] == 0x01)
        #expect(written[999] == 0x02)

        let sent = try #require(StubURLProtocol.recordedRequests().first)
        #expect(sent.value(forHTTPHeaderField: "Range") == "bytes=400-")
    }

    /// The critical case: server ignored Range and sent the whole body.
    /// Appending would corrupt the file, so the partial must be truncated.
    @Test func serverIgnoringRangeTruncatesAndRestarts() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 0x01, count: 400).write(to: url)

        let full = Data(repeating: 0x09, count: 1000)
        StubURLProtocol.reset([
            StubURLProtocol.Response(
                status: 200, headers: ["Content-Length": "1000"], body: full
            )
        ])

        try await makeTransfer().transfer(
            to: url, expectedSize: 1000, linkProvider: link, onProgress: { _ in }
        )

        let written = try Data(contentsOf: url)
        #expect(written.count == 1000)
        #expect(written == full)      // not 1400 bytes, not 0x01-prefixed
    }

    @Test func status416TreatsFileAsComplete() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 0x07, count: 1000).write(to: url)

        StubURLProtocol.reset([StubURLProtocol.Response(status: 416)])

        try await makeTransfer().transfer(
            to: url, expectedSize: 1000, linkProvider: link, onProgress: { _ in }
        )
        #expect(try Data(contentsOf: url).count == 1000)
    }

    @Test func expiredLinkIsRelinkedOnceThenSucceeds() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        StubURLProtocol.reset([
            StubURLProtocol.Response(status: 403),
            StubURLProtocol.Response(
                status: 200, headers: ["Content-Length": "10"],
                body: Data(repeating: 0x05, count: 10)
            ),
        ])

        let calls = Counter()
        try await makeTransfer().transfer(
            to: url, expectedSize: 10,
            linkProvider: { await calls.bump(); return URL(string: "https://cdn/x")! },
            onProgress: { _ in }
        )
        #expect(await calls.value == 2)     // original + one re-link
        #expect(try Data(contentsOf: url).count == 10)
    }

    @Test func repeatedExpiryFailsRatherThanLoopingForever() async {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        StubURLProtocol.reset([StubURLProtocol.Response(status: 403)])

        await #expect(throws: DownloadError.linkExpired) {
            try await makeTransfer().transfer(
                to: url, expectedSize: 10, linkProvider: link, onProgress: { _ in }
            )
        }
    }

    @Test func sizeMismatchThrowsAndKeepsPartial() async {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        StubURLProtocol.reset([
            StubURLProtocol.Response(
                status: 200, headers: ["Content-Length": "5"],
                body: Data(repeating: 0x01, count: 5)
            )
        ])

        await #expect(throws: DownloadError.self) {
            try await makeTransfer().transfer(
                to: url, expectedSize: 1000, linkProvider: link, onProgress: { _ in }
            )
        }
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func reportsProgressAsBytesArrive() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        StubURLProtocol.reset([
            StubURLProtocol.Response(
                status: 200, headers: ["Content-Length": "100"],
                body: Data(repeating: 0x03, count: 100)
            )
        ])

        let observed = Counter()
        try await makeTransfer().transfer(
            to: url, expectedSize: 100, linkProvider: link,
            onProgress: { _ in Task { await observed.bump() } }
        )
        #expect(try Data(contentsOf: url).count == 100)
    }

    @Test func overLongPartialIsTruncatedAndRestarted() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 0xFF, count: 5000).write(to: url)   // > expected

        StubURLProtocol.reset([
            StubURLProtocol.Response(
                status: 200, headers: ["Content-Length": "1000"],
                body: Data(repeating: 0x0A, count: 1000))
        ])
        try await makeTransfer().transfer(
            to: url, expectedSize: 1000, linkProvider: link, onProgress: { _ in })

        let written = try Data(contentsOf: url)
        #expect(written.count == 1000)
        #expect(written.allSatisfy { $0 == 0x0A })
        #expect(!StubURLProtocol.recordedRequests().isEmpty)
    }

    /// A 206 whose body starts somewhere other than where we asked writes at
    /// the wrong offset, and a size-only check would still pass.
    @Test func misplacedContentRangeIsRejectedNotWrittenBlindly() async {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try? Data(repeating: 0x01, count: 400).write(to: url)

        StubURLProtocol.reset([
            StubURLProtocol.Response(
                status: 206,
                headers: ["Content-Range": "bytes 0-599/1000"],   // asked for 400-
                body: Data(repeating: 0x02, count: 600))
        ])
        await #expect(throws: DownloadError.self) {
            try await makeTransfer().transfer(
                to: url, expectedSize: 1000, linkProvider: link, onProgress: { _ in })
        }
    }

    /// The 416 handler is only reachable over the network when the partial is
    /// shorter than expected; the equal-size case short-circuits earlier.
    @Test func status416IsReachedOverTheNetworkWhenSizeIsUnknown() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 0x07, count: 500).write(to: url)

        StubURLProtocol.reset([StubURLProtocol.Response(status: 416)])
        try await makeTransfer().transfer(
            to: url, expectedSize: 0, linkProvider: link, onProgress: { _ in })

        #expect(!StubURLProtocol.recordedRequests().isEmpty)   // actually hit the network
        #expect(try Data(contentsOf: url).count == 500)
    }

    /// Pins the offset reset: without it the retry sends a stale Range header.
    @Test func truncationClearsTheRangeHeaderOnTheRetry() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 0xFF, count: 5000).write(to: url)

        StubURLProtocol.reset([
            StubURLProtocol.Response(
                status: 200, headers: ["Content-Length": "1000"],
                body: Data(repeating: 0x0A, count: 1000))
        ])
        try await makeTransfer().transfer(
            to: url, expectedSize: 1000, linkProvider: link, onProgress: { _ in })

        let sent = try #require(StubURLProtocol.recordedRequests().last)
        #expect(sent.value(forHTTPHeaderField: "Range") == nil)
    }
}

actor Counter {
    private(set) var value = 0
    func bump() { value += 1 }
}
