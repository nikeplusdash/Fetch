import Foundation

public enum ColumnAlignment: Sendable, Equatable {
    case leading, trailing
}

/**
 One column's geometry and behaviour, declared once and consumed by both the
 header and every row, so the two cannot drift apart.

 The widths that used to live in the app's `ColumnWidth` grab-bag were points
 tuned for one string at one font size, shared between two unrelated tables,
 and copied by eye into three hand-built grids. A column that states its own
 width, alignment and breakpoint is the same information with one owner.
 */
public struct ColumnSpec<ID: Hashable & Sendable>: Sendable, Identifiable {
    public enum Sizing: Sendable, Equatable {
        case fixed(CGFloat)
        case flexible(min: CGFloat)
    }

    public let id: ID
    public let title: String
    public let sizing: Sizing
    public var alignment: ColumnAlignment
    public var isNumeric: Bool
    public var sortKey: String?
    public var dropsBelow: CGFloat?
    public var symbol: String?
    public var help: String?

    public init(id: ID, title: String, sizing: Sizing,
                alignment: ColumnAlignment = .leading, isNumeric: Bool = false,
                sortKey: String? = nil, dropsBelow: CGFloat? = nil,
                symbol: String? = nil, help: String? = nil) {
        self.id = id
        self.title = title
        self.sizing = sizing
        self.alignment = alignment
        self.isNumeric = isNumeric
        self.sortKey = sortKey
        self.dropsBelow = dropsBelow
        self.symbol = symbol
        self.help = help
    }

    public var minimumWidth: CGFloat {
        switch sizing {
        case .fixed(let width): width
        case .flexible(let min): min
        }
    }
}

/**
 A table's whole column layout.

 `visible(in:)` is the breakpoint rule: a column names the container width it
 needs and disappears below it, rather than squeezing its neighbours until a
 name truncates to nothing. `without(_:)` is how a screen drops a column it
 has no use for — the Library's missing Rate — as a value, so the header and
 the rows cannot disagree about whether it is there.
 */
public struct ColumnSet<ID: Hashable & Sendable>: Sendable {
    public let columns: [ColumnSpec<ID>]
    public let gap: CGFloat

    public init(columns: [ColumnSpec<ID>], gap: CGFloat) {
        self.columns = columns
        self.gap = gap
    }

    public func visible(in width: CGFloat) -> [ColumnSpec<ID>] {
        columns.filter { spec in
            guard let breakpoint = spec.dropsBelow else { return true }
            return width >= breakpoint
        }
    }

    public func without(_ id: ID) -> ColumnSet<ID> {
        ColumnSet(columns: columns.filter { $0.id != id }, gap: gap)
    }

    /**
     One column's own width, for a caller that has to line something up with
     it from outside the row — an expanded card indented to start under the
     name, say. Nil when the set has no such column.
     */
    public func width(of id: ID) -> CGFloat? {
        columns.first { $0.id == id }?.minimumWidth
    }

    public func minimumWidth(in width: CGFloat) -> CGFloat {
        let shown = visible(in: width)
        guard !shown.isEmpty else { return 0 }
        let widths = shown.reduce(CGFloat.zero) { $0 + $1.minimumWidth }
        return widths + gap * CGFloat(shown.count - 1)
    }
}
