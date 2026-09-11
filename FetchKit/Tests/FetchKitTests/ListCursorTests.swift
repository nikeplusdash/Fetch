import Foundation
import Testing
@testable import FetchKit

/**
 The search results list stopped using `List(selection:)` — it painted
 AppKit's accent slab under the theme's own row fill (#28) — so ↑/↓ are
 answered by hand now, and these are the answers.
 */
@Suite("List cursor")
struct ListCursorTests {
    private let ids = ["a", "b", "c"]

    @Test("Down from nothing selects the first row")
    func downFromNothing() {
        #expect(ListCursor.move(.down, from: nil, in: ids) == "a")
    }

    @Test("Up from nothing selects the last row")
    func upFromNothing() {
        #expect(ListCursor.move(.up, from: nil, in: ids) == "c")
    }

    @Test("Down walks to the next row")
    func downWalks() {
        #expect(ListCursor.move(.down, from: "a", in: ids) == "b")
        #expect(ListCursor.move(.down, from: "b", in: ids) == "c")
    }

    @Test("Up walks to the previous row")
    func upWalks() {
        #expect(ListCursor.move(.up, from: "c", in: ids) == "b")
        #expect(ListCursor.move(.up, from: "b", in: ids) == "a")
    }

    /**
     Clamped rather than wrapped: leaning on ↓ at the bottom of a list must
     not throw the reader back to the top.
     */
    @Test("Down at the last row stays on the last row")
    func downClamps() {
        #expect(ListCursor.move(.down, from: "c", in: ids) == "c")
    }

    @Test("Up at the first row stays on the first row")
    func upClamps() {
        #expect(ListCursor.move(.up, from: "a", in: ids) == "a")
    }

    /**
     The answer is a value, not nil, so the view can still report the key
     press handled and stop it scrolling the list underneath a selection
     that did not move.
     */
    @Test("A one-row list answers with that row in both directions")
    func singleRow() {
        #expect(ListCursor.move(.down, from: "only", in: ["only"]) == "only")
        #expect(ListCursor.move(.up, from: "only", in: ["only"]) == "only")
        #expect(ListCursor.move(.down, from: nil, in: ["only"]) == "only")
    }

    /**
     Re-faceting or re-sorting can take the selected row off the screen
     entirely. Walking from a row that is not in the list is not a thing that
     can be done, so it is the same as walking from no selection at all —
     the alternative is arrow keys that silently do nothing until the user
     clicks something.
     */
    @Test("A selection that left the list is treated as no selection")
    func staleSelection() {
        #expect(ListCursor.move(.down, from: "gone", in: ids) == "a")
        #expect(ListCursor.move(.up, from: "gone", in: ids) == "c")
    }

    @Test("An empty list has nothing to select, in either direction")
    func emptyList() {
        #expect(ListCursor.move(.down, from: nil, in: [String]()) == nil)
        #expect(ListCursor.move(.up, from: nil, in: [String]()) == nil)
        #expect(ListCursor.move(.down, from: "a", in: [String]()) == nil)
    }

    /**
     It knows nothing about search: the id is whatever the list is keyed on.
     */
    @Test("It works on any hashable identifier")
    func anyIdentifier() {
        #expect(ListCursor.move(.down, from: 2, in: [1, 2, 3]) == 3)
        #expect(ListCursor.move(.up, from: 2, in: [1, 2, 3]) == 1)
    }
}
