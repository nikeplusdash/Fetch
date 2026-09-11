import Foundation

/**
 Which row a table has selected.

 One type for every table in the app, so arrow keys, clicks and the painted
 highlight cannot disagree about what "selected" means on one screen versus
 another. It holds no view state and no layout: a table hands it the ids in
 the order they are on screen, and it answers with the one that is chosen.
 */
public struct RowSelection<ID: Hashable & Sendable>: Equatable, Sendable {
    public private(set) var selected: ID?

    public init() {}

    public func isSelected(_ id: ID) -> Bool { selected == id }

    public mutating func click(_ id: ID) { selected = id }

    public mutating func clear() { selected = nil }

    /**
     Answers one arrow press and returns the row the caller should scroll
     into view, or nil when the list holds nothing to select. Clamping and
     the treatment of a selection that has scrolled out of the results are
     `ListCursor`'s to decide; this only remembers the answer.
     */
    public mutating func move(_ direction: ListCursor.Direction, in ids: [ID]) -> ID? {
        guard let next = ListCursor.move(direction, from: selected, in: ids) else {
            selected = nil
            return nil
        }
        selected = next
        return next
    }
}

/**
 What a table does with a gesture.

 Downloads folds expansion into selection — clicking a torrent is how you
 open it — while a search row has nothing to expand. The difference is a
 value passed to one interaction rule, not two code paths that drift.
 */
public struct RowInteractionPolicy: Sendable, Equatable {
    public let selectionExpands: Bool
    public let activatesOnDoubleClick: Bool

    public init(selectionExpands: Bool, activatesOnDoubleClick: Bool) {
        self.selectionExpands = selectionExpands
        self.activatesOnDoubleClick = activatesOnDoubleClick
    }

    public static let results = RowInteractionPolicy(
        selectionExpands: false, activatesOnDoubleClick: true)
    public static let downloads = RowInteractionPolicy(
        selectionExpands: true, activatesOnDoubleClick: true)
}

public enum RowGesture<ID: Hashable & Sendable>: Equatable, Sendable {
    case singleClick(ID)
    case doubleClick(ID)
    case chevron(ID)
    case arrow(ListCursor.Direction)
    case leftArrow
    case rightArrow
}

public enum RowEffect<ID: Hashable & Sendable>: Equatable, Sendable {
    case select(ID)
    case toggleExpansion(ID)
    case activate(ID)
    case collapse
    case expand
}

public enum RowInteraction {
    /**
     The ordered effects of one gesture.

     Arrow keys deliberately never expand: walking down a list of torrents
     would otherwise open every one it passed through. The side arrows are
     how a keyboard opens and closes a row, and they do nothing on a table
     whose rows have no children.
     */
    public static func effects<ID: Hashable & Sendable>(
        for gesture: RowGesture<ID>, policy: RowInteractionPolicy
    ) -> [RowEffect<ID>] {
        switch gesture {
        case .singleClick(let id):
            policy.selectionExpands ? [.select(id), .toggleExpansion(id)] : [.select(id)]
        case .doubleClick(let id):
            policy.activatesOnDoubleClick ? [.select(id), .activate(id)] : [.select(id)]
        case .chevron(let id):
            [.toggleExpansion(id)]
        case .arrow:
            []
        case .leftArrow:
            policy.selectionExpands ? [.collapse] : []
        case .rightArrow:
            policy.selectionExpands ? [.expand] : []
        }
    }
}
