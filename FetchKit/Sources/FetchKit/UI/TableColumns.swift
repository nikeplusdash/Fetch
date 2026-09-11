import Foundation

public enum ResultColumn: Hashable, Sendable { case cache, kind, name, size, seeds, source }
public enum DownloadColumn: Hashable, Sendable { case status, name, size, rate, added }
public enum FileColumn: Hashable, Sendable { case checkbox, glyph, name, percent, size, control }

/**
 The app's tables, each declared once.

 A screen picks a set; its header and its rows are rendered from that same
 value, which is what makes laying them out differently impossible rather
 than merely discouraged. Three hand-built copies of the downloads grid, and
 a fourth typed for the cloud screen, are what this replaces.

 The widths are the ones the app already used, so adopting a set moves no
 pixels sideways. The one deliberate change is the gap: the results grid was
 on 8 while every other grid was on 16, each documented as the app's gap.
 */
public enum TableColumns {
    public static let gap: CGFloat = 16

    /**
     The seeder meter's own width: two bars of 4 with 3 between them, a gap,
     then five digits of the mono face.
     */
    public static let seedsWidth: CGFloat = 51

    public static let results = ColumnSet<ResultColumn>(columns: [
        ColumnSpec(id: .cache, title: "", sizing: .fixed(32), sortKey: "cache",
                   symbol: "arrow.down.circle",
                   help: "Sort by what downloads straight away"),
        ColumnSpec(id: .kind, title: "Type", sizing: .fixed(64), sortKey: "kind"),
        ColumnSpec(id: .name, title: "Name", sizing: .flexible(min: 160), sortKey: "name"),
        ColumnSpec(id: .size, title: "Size", sizing: .fixed(76),
                   alignment: .trailing, isNumeric: true, sortKey: "size"),
        ColumnSpec(id: .seeds, title: "Seeds", sizing: .fixed(seedsWidth),
                   alignment: .trailing, isNumeric: true, sortKey: "seeders"),
        ColumnSpec(id: .source, title: "Source", sizing: .fixed(64), alignment: .trailing),
    ], gap: gap)

    public static let downloads = downloads(showsRate: true)

    /**
     The Library shows finished work, where a transfer rate is a column of
     dashes; it asks for the set without one. Header and rows take the same
     value, so a column cannot appear in one and not the other.
     */
    public static func downloads(showsRate: Bool) -> ColumnSet<DownloadColumn> {
        var columns: [ColumnSpec<DownloadColumn>] = [
            ColumnSpec(id: .status, title: "", sizing: .fixed(24)),
            ColumnSpec(id: .name, title: "Name", sizing: .flexible(min: 160)),
            ColumnSpec(id: .size, title: "Size", sizing: .fixed(64),
                       alignment: .trailing, isNumeric: true),
        ]
        if showsRate {
            columns.append(ColumnSpec(id: .rate, title: "Rate", sizing: .fixed(80),
                                      alignment: .trailing, isNumeric: true))
        }
        columns.append(ColumnSpec(id: .added, title: "Added", sizing: .fixed(96),
                                  alignment: .trailing))
        return ColumnSet(columns: columns, gap: gap)
    }

    public static let files = ColumnSet<FileColumn>(columns: [
        ColumnSpec(id: .checkbox, title: "", sizing: .fixed(20)),
        ColumnSpec(id: .glyph, title: "", sizing: .fixed(16)),
        ColumnSpec(id: .name, title: "Name", sizing: .flexible(min: 120)),
        ColumnSpec(id: .percent, title: "", sizing: .fixed(44),
                   alignment: .trailing, isNumeric: true),
        ColumnSpec(id: .size, title: "Size", sizing: .fixed(68),
                   alignment: .trailing, isNumeric: true),
        ColumnSpec(id: .control, title: "", sizing: .fixed(24), alignment: .trailing),
    ], gap: gap)
}
