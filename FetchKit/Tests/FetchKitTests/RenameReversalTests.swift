import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

/// Undoing a rename (§9: "renaming is always reversible").
///
/// The record keeps both the debrid's own path and the path the file was
/// actually written to, so reverting is a move between two resolvable
/// locations rather than a guess at what the name used to be.
@Suite struct RenameReversalTests {
    private func request(
        fileName: String, renamedPath: String?, subfolder: String? = "TV Shows"
    ) -> DownloadRequest {
        DownloadRequest(
            providerID: DebridProviderID(rawValue: "torbox"),
            torrentID: DebridTorrentID(rawValue: "t1"),
            file: DebridFile(
                id: DebridFileID(rawValue: "f1"), name: fileName,
                shortName: (fileName as NSString).lastPathComponent,
                size: 100, mimeType: nil),
            infoHashHex: "aa",
            subfolder: subfolder,
            destinationRoot: URL(fileURLWithPath: "/downloads", isDirectory: true),
            renamedPath: renamedPath)
    }

    @Test func aRenamedFileRevertsToItsOriginalPath() throws {
        let plan = try #require(RenameReversal.plan(for: request(
            fileName: "Pack/The.Expanse.S03E05.mkv",
            renamedPath: "The Expanse/Season 03/The Expanse - S03E05.mkv")))

        #expect(plan.from.path
            == "/downloads/TV Shows/The Expanse/Season 03/The Expanse - S03E05.mkv")
        #expect(plan.to.path == "/downloads/TV Shows/Pack/The.Expanse.S03E05.mkv")
    }

    /// Nothing to undo when the file was never renamed — the action must be
    /// unavailable rather than a no-op that looks like it worked.
    @Test func anUnrenamedFileHasNothingToRevert() {
        #expect(RenameReversal.plan(for: request(
            fileName: "movie.mkv", renamedPath: nil)) == nil)
    }

    /// A rename that resolved to the same place is also nothing to undo.
    @Test func aRenameThatChangedNothingHasNothingToRevert() {
        #expect(RenameReversal.plan(for: request(
            fileName: "movie.mkv", renamedPath: "movie.mkv")) == nil)
    }

    @Test func revertingHonoursTheRoutedSubfolder() throws {
        let plan = try #require(RenameReversal.plan(for: request(
            fileName: "raw.mkv", renamedPath: "Dune (2021)/Dune (2021).mkv",
            subfolder: "Movies")))

        #expect(plan.to.path == "/downloads/Movies/raw.mkv")
    }

    /// Both sides go through DestinationResolver, so a hostile stored path
    /// cannot make the revert write outside the download directory.
    ///
    /// The invariant is **descendancy**, not the absence of a substring:
    /// sanitizing `../../etc/passwd` yields `/downloads/TV Shows/etc/passwd`,
    /// which contains "/etc/passwd" and is perfectly safe. Asserting on the
    /// substring tests the wrong property.
    @Test func aHostileStoredPathCannotEscape() throws {
        let plan = try #require(RenameReversal.plan(for: request(
            fileName: "../../etc/passwd", renamedPath: "x/y.mkv")))

        let root = URL(fileURLWithPath: "/downloads", isDirectory: true)
            .standardizedFileURL.path
        for url in [plan.from, plan.to] {
            #expect(url.standardizedFileURL.path.hasPrefix(root + "/"))
            #expect(!url.standardizedFileURL.pathComponents.contains(".."))
        }
    }
}
