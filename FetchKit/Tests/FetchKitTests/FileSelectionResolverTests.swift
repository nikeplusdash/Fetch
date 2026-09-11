import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

@Suite struct FileSelectionResolverTests {
    private func file(_ id: String, _ name: String, size: Int64 = 100) -> DebridFile {
        DebridFile(
            id: DebridFileID(rawValue: id), name: name,
            shortName: (name as NSString).lastPathComponent, size: size, mimeType: nil
        )
    }

    @Test func matchesSelectedPathsAgainstAuthoritativeList() {
        let authoritative = [file("101", "Show/S01E01.mkv"), file("102", "Show/S01E02.mkv")]
        let resolution = FileSelectionResolver.resolve(
            selectedPaths: ["Show/S01E01.mkv"], authoritative: authoritative
        )
        #expect(resolution.matched.map(\.id) == [DebridFileID(rawValue: "101")])
        #expect(resolution.missing.isEmpty)
    }

    @Test func previewIDsAreIgnoredEvenIfTheyCollideWithDifferentAuthoritativeFiles() {
        let authoritative = [file("5", "Movie.mkv")]
        let resolution = FileSelectionResolver.resolve(
            selectedPaths: ["Movie.mkv"], authoritative: authoritative
        )
        #expect(resolution.matched.first?.id == DebridFileID(rawValue: "5"))
    }

    @Test func pathWithNoAuthoritativeMatchIsReportedAsMissingNotDropped() {
        let authoritative = [file("1", "Show/S01E01.mkv")]
        let resolution = FileSelectionResolver.resolve(
            selectedPaths: ["Show/S01E01.mkv", "Show/S01E99.mkv"], authoritative: authoritative
        )
        #expect(resolution.matched.count == 1)
        #expect(resolution.missing == ["Show/S01E99.mkv"])
    }

    @Test func emptySelectionResolvesToNothingMatchedNothingMissing() {
        let resolution = FileSelectionResolver.resolve(
            selectedPaths: [], authoritative: [file("1", "a.mkv")]
        )
        #expect(resolution.matched.isEmpty)
        #expect(resolution.missing.isEmpty)
    }

    @Test func allSelectedPathsMissingReportsEveryOne() {
        let resolution = FileSelectionResolver.resolve(
            selectedPaths: ["a.mkv", "b.mkv"], authoritative: []
        )
        #expect(resolution.matched.isEmpty)
        #expect(Set(resolution.missing) == ["a.mkv", "b.mkv"])
    }
}

@Suite struct FileSelectionPathShapeTests {
    private func file(_ path: String, id: String = "1") -> DebridFile {
        DebridFile(id: DebridFileID(rawValue: id), name: path,
                   shortName: (path as NSString).lastPathComponent,
                   size: 10, mimeType: nil)
    }

    @Test func aLeadingSlashDoesNotStopAMatch() {
        let resolution = FileSelectionResolver.resolve(
            selectedPaths: ["Show/S01E01.mkv"],
            authoritative: [file("/Show/S01E01.mkv")])

        #expect(resolution.matched.count == 1)
        #expect(resolution.missing.isEmpty)
    }

    @Test func itWorksTheOtherWayRound() {
        let resolution = FileSelectionResolver.resolve(
            selectedPaths: ["/Show/S01E01.mkv"],
            authoritative: [file("Show/S01E01.mkv")])

        #expect(resolution.matched.count == 1)
    }

    @Test func caseStillDistinguishesTwoFiles() {
        let resolution = FileSelectionResolver.resolve(
            selectedPaths: ["Show/a.mkv"],
            authoritative: [file("Show/A.mkv", id: "1"), file("Show/a.mkv", id: "2")])

        #expect(resolution.matched.map(\.id.rawValue) == ["2"])
    }

    @Test func aPathThatIsNotThereIsStillMissing() {
        let resolution = FileSelectionResolver.resolve(
            selectedPaths: ["Show/gone.mkv"], authoritative: [file("/Show/here.mkv")])

        #expect(resolution.matched.isEmpty)
        #expect(resolution.missing == ["Show/gone.mkv"])
    }
}
