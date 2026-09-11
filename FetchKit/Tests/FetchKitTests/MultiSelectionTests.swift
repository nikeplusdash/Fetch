import Foundation
import Testing
@testable import FetchKit

@Suite("Multi selection")
struct MultiSelectionTests {
    private let order = ["a", "b", "c", "d", "e"]

    @Test("A fresh selection is empty and has no anchor")
    func startsEmpty() {
        let selection = MultiSelection<String>()
        #expect(selection.chosen.isEmpty)
        #expect(selection.anchor == nil)
    }

    @Test("Toggle adds, toggles again to remove, and anchors where it was clicked")
    func toggleAddsAndRemoves() {
        var selection = MultiSelection<String>()
        selection.toggle("b")
        #expect(selection.chosen == ["b"])
        #expect(selection.anchor == "b")
        selection.toggle("b")
        #expect(selection.chosen.isEmpty)
        #expect(selection.anchor == "b")
    }

    @Test("A plain click keeps only what it clicked")
    func replaceKeepsOne() {
        var selection = MultiSelection<String>()
        selection.toggle("a")
        selection.toggle("c")
        selection.replace(with: "e")
        #expect(selection.chosen == ["e"])
        #expect(selection.anchor == "e")
    }

    @Test("Shift takes the range between the anchor and the click, both ends included")
    func extendTakesTheRange() {
        var selection = MultiSelection<String>()
        selection.toggle("b")
        selection.extend(to: "d", in: order)
        #expect(selection.chosen == ["b", "c", "d"])
    }

    @Test("The range works upwards too")
    func extendUpwards() {
        var selection = MultiSelection<String>()
        selection.toggle("d")
        selection.extend(to: "b", in: order)
        #expect(selection.chosen == ["b", "c", "d"])
    }

    @Test("Shift keeps what was already chosen outside the range")
    func extendIsAdditive() {
        var selection = MultiSelection<String>()
        selection.toggle("a")
        selection.toggle("c")
        selection.extend(to: "e", in: order)
        #expect(selection.chosen == ["a", "c", "d", "e"])
    }

    @Test("Shift with nothing anchored behaves like a first click")
    func extendWithoutAnchor() {
        var selection = MultiSelection<String>()
        selection.extend(to: "c", in: order)
        #expect(selection.chosen == ["c"])
        #expect(selection.anchor == "c")
    }

    @Test("An anchor that has left the list does not strand the shift key")
    func staleAnchorFallsBackToOneRow() {
        var selection = MultiSelection<String>()
        selection.toggle("z")
        selection.extend(to: "c", in: order)
        #expect(selection.chosen.contains("c"))
        #expect(selection.anchor == "c")
    }

    @Test("Select all takes the list, clear gives it back")
    func selectAllAndClear() {
        var selection = MultiSelection<String>()
        selection.selectAll(order)
        #expect(selection.chosen == Set(order))
        selection.clear()
        #expect(selection.chosen.isEmpty)
        #expect(selection.anchor == nil)
    }

    @Test("Invert swaps chosen for unchosen, within the list only")
    func invertSwaps() {
        var selection = MultiSelection<String>()
        selection.toggle("a")
        selection.toggle("c")
        selection.invert(in: order)
        #expect(selection.chosen == ["b", "d", "e"])
    }

    @Test("The master checkbox reads all, none or some")
    func masterState() {
        var selection = MultiSelection<String>()
        #expect(selection.state(in: order) == .off)
        selection.toggle("a")
        #expect(selection.state(in: order) == .mixed)
        selection.selectAll(order)
        #expect(selection.state(in: order) == .on)
    }

    @Test("An empty list is off, never mixed")
    func emptyListIsOff() {
        var selection = MultiSelection<String>()
        selection.toggle("a")
        #expect(selection.state(in: []) == .off)
    }

    @Test("Rows that leave the list stop counting towards all-selected")
    func staleChoicesDoNotClaimAll() {
        var selection = MultiSelection<String>()
        selection.selectAll(order)
        #expect(selection.state(in: ["a", "b"]) == .on)
        #expect(selection.chosen(in: ["a", "b"]) == ["a", "b"])
    }
}
