import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

/// Gated live check against the real archive.org, mirroring the app's exact
/// configuration — same client, same allowlist. Run with FETCH_LIVE=1.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["FETCH_LIVE"] == "1"))
struct LiveInternetArchiveTests {
    @Test func liveSearchReturnsResults() async throws {
        let provider = InternetArchiveProvider(
            client: HTTPClient(allowedHosts: [InternetArchiveProvider.host]))
        let results = try await provider.search(SearchQuery(text: "frank herbert dune"))

        print("IA LIVE: \(results.count) results")
        for result in results.prefix(5) {
            print("  • \(result.title.prefix(50)) | kind=\(result.metadata.mediaKind) "
                  + "| id=\(result.rawAttributes["identifier"] ?? "?")")
        }
        #expect(!results.isEmpty)
    }

    @Test func liveResultsSurviveTheDefaultQualityProfile() async throws {
        let provider = InternetArchiveProvider(
            client: HTTPClient(allowedHosts: [InternetArchiveProvider.host]))
        let results = try await provider.search(SearchQuery(text: "frank herbert dune"))
        let outcome = QualityProfile.default.apply(to: results, matching: "")

        print("IA LIVE: \(outcome.accepted.count) accepted, \(outcome.rejected.count) rejected")
        #expect(!outcome.accepted.isEmpty, "the default profile rejected every IA result")
    }

    /// The item that exposed both bugs: 8,891 files, nested folders, 6,487 of
    /// them IA-generated derivatives. The picker showed exactly one — a flat
    /// 20.6 GB .zip — because every nested name was rejected.
    @Test func liveNestedCollectionListsItsRealFiles() async throws {
        let provider = InternetArchiveProvider(
            client: HTTPClient(allowedHosts: [InternetArchiveProvider.host]))
        let files = try await provider.files(inItem: "old-cartoons-collection")

        print("IA LIVE: \(files.count) user-facing files")
        for file in files.prefix(3) { print("  • \(file.name)") }

        #expect(files.count > 1_000, "nested files are being dropped again")
        #expect(files.contains { $0.name.contains("/") }, "no nested paths survived")

        // The h.264 .mp4 beside each .mkv is kept and flagged, not dropped:
        // it is visible on archive.org and is often the copy that plays.
        let derived = files.filter(\.isDerived)
        #expect(derived.contains { $0.name.hasSuffix(".mp4") },
                "the .mp4 alternatives went missing again")
        #expect(derived.allSatisfy { $0.format != "Thumbnail" },
                "thumbnail strips are not an alternative format")
        print("IA LIVE: \(files.count - derived.count) uploaded, \(derived.count) derived")
        for file in files {
            #expect(file.url.absoluteString
                .hasPrefix("https://archive.org/download/old-cartoons-collection/"))
        }
    }
}
