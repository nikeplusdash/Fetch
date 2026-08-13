import Testing
import Foundation
@testable import FetchKit

@Suite struct PathSanitizerTests {
    let root = URL(fileURLWithPath: "/Users/test/Downloads", isDirectory: true)

    @Test func stripsParentTraversal() throws {
        let url = try DestinationResolver.resolve(
            root: root, subfolder: "Movies", relativePath: "../../../etc/passwd"
        )
        #expect(url.path.hasPrefix("/Users/test/Downloads/Movies"))
        #expect(!url.path.contains(".."))
    }

    @Test func rejectsAbsolutePathsByTreatingThemAsRelative() throws {
        let url = try DestinationResolver.resolve(
            root: root, subfolder: nil, relativePath: "/etc/passwd"
        )
        #expect(url.path == "/Users/test/Downloads/etc/passwd")
    }

    @Test func stripsNullBytesAndSlashesInComponents() {
        #expect(!PathSanitizer.sanitize(component: "bad\u{0}name").contains("\u{0}"))
        #expect(PathSanitizer.sanitize(component: "a/b") == "a_b")
    }

    @Test func preservesNestedStructure() throws {
        let url = try DestinationResolver.resolve(
            root: root, subfolder: "TV", relativePath: "Show/Season 01/ep.mkv"
        )
        #expect(url.path == "/Users/test/Downloads/TV/Show/Season 01/ep.mkv")
    }

    @Test func truncatesLongComponentsPreservingExtension() {
        let long = String(repeating: "a", count: 300) + ".mkv"
        let result = PathSanitizer.sanitize(component: long)
        #expect(result.utf8.count <= 255)
        #expect(result.hasSuffix(".mkv"))
    }

    @Test func dropsEmptyAndDotComponents() throws {
        let url = try DestinationResolver.resolve(
            root: root, subfolder: nil, relativePath: "a//./b/ep.mkv"
        )
        #expect(url.path == "/Users/test/Downloads/a/b/ep.mkv")
    }

    @Test func throwsWhenNothingUsableRemains() {
        #expect(throws: DownloadError.self) {
            _ = try DestinationResolver.resolve(
                root: root, subfolder: nil, relativePath: "../.."
            )
        }
    }

    @Test func sanitizesSubfolderToo() throws {
        let url = try DestinationResolver.resolve(
            root: root, subfolder: "../evil", relativePath: "f.mkv"
        )
        #expect(url.path.hasPrefix("/Users/test/Downloads/evil"))
    }

    @Test func collisionSuffixIncrementsBeforeExtension() {
        #expect(
            PathSanitizer.disambiguate("file.mkv", exists: { $0 == "file.mkv" }) == "file (1).mkv"
        )
        #expect(
            PathSanitizer.disambiguate("file.mkv", exists: { _ in false }) == "file.mkv"
        )
    }

    @Test func oversizedExtensionIsStillCapped() {
        let name = "short." + String(repeating: "e", count: 300)
        #expect(PathSanitizer.sanitize(component: name).utf8.count <= 255)
    }

    @Test func oversizedMultiByteExtensionIsStillCapped() {
        // A "." followed by 300 four-byte emoji as the extension. Truncating
        // the suffix by Character count (not UTF-8 byte count) would still
        // blow through the 255-byte cap here, unlike the ASCII case above.
        let name = "x." + String(repeating: "\u{1F600}", count: 300)
        #expect(PathSanitizer.sanitize(component: name).utf8.count <= 255)
    }

    @Test func subfolderCannotMaskACollapsedFilePath() {
        #expect(throws: DownloadError.self) {
            _ = try DestinationResolver.resolve(
                root: URL(fileURLWithPath: "/Users/test/Downloads", isDirectory: true),
                subfolder: "Movies", relativePath: "../..")
        }
    }
}
