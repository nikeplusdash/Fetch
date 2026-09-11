import Foundation

/**
 Where ↑ and ↓ move a list's selection.

 **In FetchKit because it is a rule, not a layout.** The search results list
 used to get arrow keys free from `List(selection:)`, and paid for them with
 a second selection painter underneath the themed one — AppKit's accent slab,
 full width and square-cornered, with the row's own `Palette.bgSelected` fill
 sitting inside it (#28, the pair #3 removed from Downloads). Dropping the
 native selection is what stops the slab; it also means the arrows have to be
 answered by hand, and "which row is next" is exactly the kind of decision
 the untestable app target must not be the only place that states.

 Generic over the identifier because it knows nothing about results: it is a
 statement about a list and a cursor in it.
 */
public enum ListCursor {
    /**
     Which way a key press moves the cursor.
     */
    public enum Direction: Sendable, Equatable {
        case up, down
    }

    /**
     The selection after one arrow press: the neighbour in `ids`, or nil
     when there is nothing at all to select.

     **Clamped, never wrapped.** A table on this platform stops at its ends,
     and a list that jumps from the last row back to the first is a list that
     loses your place when you lean on the key. Pressing ↓ on the last row
     therefore returns the last row — a value, not nil, so the caller can
     swallow the key press rather than let it fall through and scroll the
     list out from under a selection that did not move.

     **Nothing selected means the near end**, which is the whole reason the
     first ↓ into a fresh list of results selects its first row rather than
     doing nothing and looking broken. ↑ takes the far end for the same
     reason, from the other side.

     **A selection that is no longer in the list is treated as no selection.**
     Results are re-faceted, re-sorted and re-filtered under a live search,
     and the id that was selected can simply stop being on screen; walking
     from a row that is not there is not a thing that can be done, and
     refusing to move would leave the arrows dead until the user clicked.
     */
    public static func move<ID: Hashable>(
        _ direction: Direction, from current: ID?, in ids: [ID]
    ) -> ID? {
        guard let first = ids.first, let last = ids.last else { return nil }
        guard let current, let index = ids.firstIndex(of: current) else {
            return direction == .down ? first : last
        }
        switch direction {
        case .down: return index + 1 < ids.count ? ids[index + 1] : last
        case .up: return index > 0 ? ids[index - 1] : first
        }
    }
}
