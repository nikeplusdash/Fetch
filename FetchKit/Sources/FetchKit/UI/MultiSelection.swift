import Foundation

/**
 A set of rows chosen together, and the anchor a shift-click measures from.

 The arithmetic of "everything between where I last clicked and where I just
 clicked" is the part that goes wrong quietly — off by one at an end, upside
 down when you drag backwards, stranded when the row you anchored on is no
 longer in the list — so it is stated here where it can be tested, rather
 than in a view that has no test bundle to state it in.

 The order of the rows is passed in rather than held: the list is filtered
 and re-sorted under the selection, and a range means whatever is on screen
 at the moment the shift key goes down.
 */
public struct MultiSelection<ID: Hashable & Sendable>: Equatable, Sendable {
    public private(set) var chosen: Set<ID>
    public private(set) var anchor: ID?

    public init(chosen: Set<ID> = []) {
        self.chosen = chosen
        self.anchor = nil
    }

    public func isSelected(_ id: ID) -> Bool { chosen.contains(id) }

    /**
     What is chosen and still on screen. Rows leave the list — a file is
     removed, a filter narrows — and a choice that outlived its row must not
     go on counting towards "all of them are selected".
     */
    public func chosen(in order: [ID]) -> Set<ID> {
        chosen.intersection(order)
    }

    /**
     Adds or removes one row, leaving the rest alone. This is a checkbox, and
     a command-click.
     */
    public mutating func toggle(_ id: ID) {
        if chosen.contains(id) {
            chosen.remove(id)
        } else {
            chosen.insert(id)
        }
        anchor = id
    }

    /**
     Keeps only this row. A plain click means "this one", the way it does in
     every list on the platform; the checkbox beside it is how you add one
     without saying that.
     */
    public mutating func replace(with id: ID) {
        chosen = [id]
        anchor = id
    }

    /**
     Takes everything between the anchor and this row, both ends included,
     and keeps whatever was chosen outside that range.

     With nothing anchored — or an anchor that has since left the list — this
     is a first click rather than nothing at all, because a shift key that
     silently does nothing reads as a broken list.
     */
    public mutating func extend(to id: ID, in order: [ID]) {
        guard let anchor,
              let from = order.firstIndex(of: anchor),
              let to = order.firstIndex(of: id)
        else {
            chosen.insert(id)
            self.anchor = id
            return
        }
        let range = from <= to ? from...to : to...from
        chosen.formUnion(order[range])
    }

    public mutating func selectAll(_ order: [ID]) {
        chosen.formUnion(order)
        anchor = order.last
    }

    public mutating func clear() {
        chosen.removeAll()
        anchor = nil
    }

    public mutating func invert(in order: [ID]) {
        chosen = Set(order).subtracting(chosen)
        anchor = nil
    }

    /**
     What a master checkbox over this list shows. An empty list is `off`
     rather than `mixed`: there is nothing to be partly through.
     */
    public func state(in order: [ID]) -> CheckState {
        guard !order.isEmpty else { return .off }
        let inList = chosen(in: order)
        if inList.isEmpty { return .off }
        return inList.count == order.count ? .on : .mixed
    }
}
