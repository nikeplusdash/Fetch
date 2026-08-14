import Foundation
import Testing
@testable import FetchKit

/// The per-download destination, which is the half of plan 2 that can be
/// tested. The sheet only renders what these decide.
@Suite("Download destination")
struct DownloadDestinationTests {
    private let root = URL(fileURLWithPath: "/Users/x/Downloads/Fetch", isDirectory: true)

    // MARK: - Subfolder resolution

    @Test("A folder under the root becomes the subfolder the enqueue takes")
    func subfolderUnderRoot() {
        #expect(DownloadDestination.subfolder(
            forDestination: root.appendingPathComponent("Movies"), root: root) == "Movies")
        #expect(DownloadDestination.subfolder(
            forDestination: root.appendingPathComponent("TV/Show"), root: root) == "TV/Show")
    }

    @Test("The root itself is an empty subfolder, not a refusal")
    func rootIsEmptySubfolder() {
        #expect(DownloadDestination.subfolder(forDestination: root, root: root) == "")
    }

    @Test("A trailing slash does not stop a folder containing itself")
    func trailingSlash() {
        let slashed = URL(fileURLWithPath: "/Users/x/Downloads/Fetch/", isDirectory: true)
        #expect(DownloadDestination.subfolder(forDestination: slashed, root: root) == "")
    }

    /// The bug class this guards: containment tested as a string prefix says
    /// `/Users/x/Downloads/FetchOther` is inside `/Users/x/Downloads/Fetch`,
    /// because the *characters* match. It is a different folder.
    @Test("A sibling folder sharing a name prefix is outside the root")
    func siblingWithSharedPrefix() {
        let sibling = URL(fileURLWithPath: "/Users/x/Downloads/FetchOther", isDirectory: true)
        #expect(DownloadDestination.subfolder(forDestination: sibling, root: root) == nil)
    }

    @Test("A folder outside the root is refused rather than clamped")
    func outsideRoot() {
        #expect(DownloadDestination.subfolder(
            forDestination: URL(fileURLWithPath: "/Users/x/Movies"), root: root) == nil)
        #expect(DownloadDestination.subfolder(
            forDestination: URL(fileURLWithPath: "/"), root: root) == nil)
    }

    @Test("Dot components resolve before containment is decided")
    func dotComponents() {
        let sneaky = URL(fileURLWithPath: "/Users/x/Downloads/Fetch/Movies/../../Elsewhere")
        #expect(DownloadDestination.subfolder(forDestination: sneaky, root: root) == nil)
    }

    @Test("A subfolder round-trips back to the folder it names")
    func roundTrip() {
        let destination = DownloadDestination.destination(root: root, subfolder: "TV/Show")
        #expect(DownloadDestination.subfolder(
            forDestination: destination, root: root) == "TV/Show")
    }

    @Test("An empty subfolder is the root")
    func emptySubfolderIsRoot() {
        #expect(DownloadDestination.destination(root: root, subfolder: "")
                == root.standardizedFileURL)
    }

    // MARK: - The readout

    @Test("The readout is the last two root components plus the subfolder")
    func readout() {
        let readout = DestinationReadout(root: root, subfolder: "Movies")
        #expect(readout.prefix == "Downloads/Fetch/")
        #expect(readout.leaf == "Movies")
        #expect(readout.full == "Downloads/Fetch/Movies")
    }

    @Test("With no subfolder the root's own last folder is the leaf")
    func readoutAtRoot() {
        let readout = DestinationReadout(root: root, subfolder: "")
        #expect(readout.prefix == "Downloads/")
        #expect(readout.leaf == "Fetch")
    }

    @Test("A nested subfolder puts only its final folder in the leaf")
    func readoutNested() {
        let readout = DestinationReadout(root: root, subfolder: "TV/Show/Season 2")
        #expect(readout.leaf == "Season 2")
        #expect(readout.full == "Downloads/Fetch/TV/Show/Season 2")
    }

    // MARK: - The menu

    @Test("The menu is every routing folder, then Other, then Choose location")
    func menuIsTheRoutingFolders() {
        let entries = DestinationMenu.entries(
            ruleSubfolder: "Movies", rules: RoutingRule.defaults)
        #expect(entries == [
            .category(subfolder: "Movies"),
            .category(subfolder: "TV Shows"),
            .category(subfolder: "Anime"),
            .category(subfolder: "Music"),
            .category(subfolder: "Books"),
            .category(subfolder: "Other"),
            .choose,
        ])
    }

    /// A menu that reshuffles itself per download is one you have to read every
    /// time instead of reaching for the third row.
    @Test("The order is the rules' order, not this item's relevance")
    func menuOrderDoesNotFollowTheItem() {
        let forMovie = DestinationMenu.entries(
            ruleSubfolder: "Movies", rules: RoutingRule.defaults)
        let forBook = DestinationMenu.entries(
            ruleSubfolder: "Books", rules: RoutingRule.defaults)
        #expect(forMovie == forBook)
    }

    /// Otherwise the one folder every unclassified download lands in would be
    /// the only one you cannot choose deliberately.
    @Test("Other is offered even though no rule names it")
    func otherIsAlwaysOffered() {
        let entries = DestinationMenu.entries(ruleSubfolder: "", rules: [])
        #expect(entries == [.category(subfolder: "Other"), .choose])
    }

    @Test("Two rules naming one folder produce one entry")
    func duplicateRulesCollapse() {
        let rules = [
            RoutingRule(match: .init(mediaKind: .movie), subfolder: "Films"),
            RoutingRule(match: .init(mediaKind: .tv), subfolder: "Films"),
        ]
        #expect(DestinationMenu.entries(ruleSubfolder: "Films", rules: rules)
                == [.category(subfolder: "Films"), .category(subfolder: "Other"), .choose])
    }

    /// The menu must always be able to show where the item is actually headed,
    /// including after a rule that named that folder has been deleted.
    @Test("The item's own destination is offered even when no rule names it")
    func theItemsDestinationIsAlwaysPresent() {
        let entries = DestinationMenu.entries(
            ruleSubfolder: "Concerts", rules: RoutingRule.defaults)
        #expect(entries.contains(.category(subfolder: "Concerts")))
        #expect(entries.last == .choose)
    }

    @Test("A category is titled by its folder alone, and Choose by its verb")
    func menuTitles() {
        #expect(DestinationMenu.title(for: .category(subfolder: "Movies"), root: root)
                == "Movies")
        // Every category sits under the same root, so repeating the prefix on
        // six rows would say nothing.
        #expect(DestinationMenu.title(for: .category(subfolder: "TV/Show"), root: root)
                == "Show")
        #expect(DestinationMenu.title(for: .choose, root: root) == "Choose location…")
    }

    @Test("The tick finds the entry the item is headed to, whatever its spelling")
    func matchingEntry() {
        let entries = DestinationMenu.entries(
            ruleSubfolder: "Movies", rules: RoutingRule.defaults)
        #expect(DestinationMenu.entry(matching: "Movies", in: entries)
                == .category(subfolder: "Movies"))
        #expect(DestinationMenu.entry(matching: "/Movies/", in: entries)
                == .category(subfolder: "Movies"))
        #expect(DestinationMenu.entry(matching: "Nowhere", in: entries) == nil)
    }

    /// The em-dash rule from the tokens spec: none of these strings reach the
    /// user carrying one.
    @Test("No menu title contains an em-dash")
    func noEmDashInTitles() {
        let entries = DestinationMenu.entries(
            ruleSubfolder: "Movies", rules: RoutingRule.defaults)
        for entry in entries {
            #expect(!DestinationMenu.title(for: entry, root: root).contains("\u{2014}"))
        }
    }
}
