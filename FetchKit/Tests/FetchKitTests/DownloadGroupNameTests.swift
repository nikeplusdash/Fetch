import Testing
import Foundation
import FetchPluginAPI
@testable import FetchKit

/// A group's name is given at enqueue time, not guessed from paths afterwards.
@Suite struct DownloadGroupNameTests {
    /// The Gutenberg case: two formats of one book, no shared folder, so the
    /// path derivation has nothing to work with and the row read "2 files".
    @Test func aStatedNameWinsOverThePathDerivation() {
        let paths = ["three-body.epub", "three-body.mobi"]
        #expect(DownloadGrouping.displayName(forPaths: paths) == nil)
        #expect(DownloadGrouping.displayName(
            stated: "The Three-Body Problem", forPaths: paths)
            == "The Three-Body Problem")
    }

    /// Records saved before the column existed still group and still name
    /// themselves exactly as they did then.
    @Test func noStatedNameFallsBackToThePathDerivation() {
        let paths = ["Dune.2021/a.mkv", "Dune.2021/b.mkv"]
        #expect(DownloadGrouping.displayName(stated: nil, forPaths: paths) == "Dune.2021")
    }

    /// An empty string is not a name. Persisting one and preferring it would
    /// give a row a blank title with no way to tell why.
    @Test func anEmptyStatedNameIsIgnored() {
        #expect(DownloadGrouping.displayName(stated: "  ", forPaths: ["Dune.2021/a.mkv"])
            == "Dune.2021")
    }

    @Test func aRequestCarriesItsGroupNameAndMetadata() {
        let request = DownloadRequest(
            providerID: DebridProviderID(rawValue: "direct"),
            torrentID: DebridTorrentID(rawValue: "direct"),
            file: DebridFile(
                id: DebridFileID(rawValue: "u"), name: "a.epub", shortName: "a.epub",
                size: 10, mimeType: nil),
            infoHashHex: "",
            subfolder: "Books",
            destinationRoot: URL(fileURLWithPath: "/tmp"),
            directURL: URL(string: "https://example.org/a.epub"),
            groupKey: DownloadGroupKey(content: "gutenberg:42"),
            groupName: "The Three-Body Problem",
            metadata: ReleaseMetadata(mediaKind: .book, title: "The Three-Body Problem"))

        #expect(request.groupName == "The Three-Body Problem")
        #expect(request.metadata.mediaKind == .book)
    }

    /// Defaulted, so the ~20 existing call sites compile unchanged.
    @Test func groupNameAndMetadataAreOptionalOnTheRequest() {
        let request = DownloadRequest(
            providerID: DebridProviderID(rawValue: "torbox"),
            torrentID: DebridTorrentID(rawValue: "t"),
            file: DebridFile(
                id: DebridFileID(rawValue: "f"), name: "x.mkv", shortName: "x.mkv",
                size: 10, mimeType: nil),
            infoHashHex: "dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c",
            subfolder: nil,
            destinationRoot: URL(fileURLWithPath: "/tmp"))

        #expect(request.groupName == nil)
        #expect(request.metadata == .unparsed)
    }
}
