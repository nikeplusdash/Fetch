import Foundation
import Testing
@testable import FetchKit

@Suite("Row selection")
struct RowSelectionTests {
    private let ids = ["a", "b", "c"]

    @Test("A fresh selection has nothing selected")
    func startsEmpty() {
        #expect(RowSelection<String>().selected == nil)
    }

    @Test("A click selects, and asking about another row says no")
    func clickSelects() {
        var selection = RowSelection<String>()
        selection.click("b")
        #expect(selection.selected == "b")
        #expect(selection.isSelected("b"))
        #expect(!selection.isSelected("a"))
    }

    @Test("Clear deselects")
    func clearDeselects() {
        var selection = RowSelection<String>()
        selection.click("b")
        selection.clear()
        #expect(selection.selected == nil)
    }

    @Test("Move walks the visible order and returns the row to scroll to")
    func moveWalks() {
        var selection = RowSelection<String>()
        #expect(selection.move(.down, in: ids) == "a")
        #expect(selection.move(.down, in: ids) == "b")
        #expect(selection.selected == "b")
    }

    @Test("Move clamps at the end rather than wrapping")
    func moveClamps() {
        var selection = RowSelection<String>()
        selection.click("c")
        #expect(selection.move(.down, in: ids) == "c")
    }

    @Test("A selection that left the list is treated as none")
    func staleSelectionIsNone() {
        var selection = RowSelection<String>()
        selection.click("z")
        #expect(selection.move(.down, in: ids) == "a")
    }

    @Test("Moving in an empty list selects nothing and reports nothing")
    func emptyList() {
        var selection = RowSelection<String>()
        #expect(selection.move(.down, in: []) == nil)
        #expect(selection.selected == nil)
    }
}

@Suite("Row interaction")
struct RowInteractionPolicyTests {
    @Test("On search, a single click only selects")
    func searchSingleClick() {
        #expect(RowInteraction.effects(for: .singleClick("a"), policy: .results) == [.select("a")])
    }

    @Test("On downloads, a single click selects and expands")
    func downloadsSingleClick() {
        #expect(RowInteraction.effects(for: .singleClick("a"), policy: .downloads)
                == [.select("a"), .toggleExpansion("a")])
    }

    @Test("A double click activates on both tables")
    func doubleClickActivates() {
        #expect(RowInteraction.effects(for: .doubleClick("a"), policy: .results) == [.select("a"), .activate("a")])
        #expect(RowInteraction.effects(for: .doubleClick("a"), policy: .downloads) == [.select("a"), .activate("a")])
    }

    @Test("The chevron toggles expansion without selecting")
    func chevronOnlyToggles() {
        #expect(RowInteraction.effects(for: .chevron("a"), policy: .downloads) == [.toggleExpansion("a")])
    }

    @Test("Arrow keys select and never expand, on either table")
    func arrowsDoNotExpand() {
        #expect(RowInteraction.effects(for: RowGesture<String>.arrow(.down), policy: .downloads).isEmpty)
        #expect(RowInteraction.effects(for: RowGesture<String>.arrow(.up), policy: .results).isEmpty)
    }

    @Test("Left and right collapse and expand only where selection expands")
    func sideArrows() {
        #expect(RowInteraction.effects(for: RowGesture<String>.leftArrow, policy: .downloads) == [.collapse])
        #expect(RowInteraction.effects(for: RowGesture<String>.rightArrow, policy: .downloads) == [.expand])
        #expect(RowInteraction.effects(for: RowGesture<String>.leftArrow, policy: .results).isEmpty)
        #expect(RowInteraction.effects(for: RowGesture<String>.rightArrow, policy: .results).isEmpty)
    }
}
