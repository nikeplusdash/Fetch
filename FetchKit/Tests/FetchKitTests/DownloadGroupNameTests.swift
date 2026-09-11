import Testing
import Foundation
import FetchPluginAPI
@testable import FetchKit

@Suite struct DownloadGroupNameTests {
    @Test func aStatedNameWinsOverThePathDerivation() {
        let paths = ["three-body.epub", "three-body.mobi"]
        #expect(DownloadGrouping.displayName(forPaths: paths) == nil)
        #expect(DownloadGrouping.displayName(
            stated: "The Three-Body Problem", forPaths: paths)
            == "The Three-Body Problem")
    }

    @Test func noStatedNameFallsBackToThePathDerivation() {
        let paths = ["Dune.2021/a.mkv", "Dune.2021/b.mkv"]
        #expect(DownloadGrouping.displayName(stated: nil, forPaths: paths) == "Dune.2021")
    }

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
