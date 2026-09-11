import Foundation

public enum Spacing {
    public static let s2: CGFloat = 2,  s4: CGFloat = 4
    public static let s6: CGFloat = 6,  s8: CGFloat = 8
    public static let s10: CGFloat = 10
    public static let s12: CGFloat = 12, s14: CGFloat = 14
    public static let s16: CGFloat = 16
    public static let s20: CGFloat = 20, s24: CGFloat = 24
}

public enum WindowMetrics {
    public static let titleBarInset: CGFloat = 32
    public static let sidebarWidth: CGFloat = 200
    public static let trafficLightInset: CGFloat = 9
    public static let trafficLightsWidth: CGFloat = 60
    public static let trafficLightDiameter: CGFloat = 14
    public static var trafficLightsCenterY: CGFloat {
        trafficLightInset + trafficLightDiameter / 2
    }

    public static let pillBarLift: CGFloat = 8
    public static let pillBarGap: CGFloat = 10

    public static let firstControlGap: CGFloat = 8

    public static let barHeight: CGFloat = 36
    public static let subBarHeight: CGFloat = 36
    public static let railHeight: CGFloat = 28

    public static let sidebarRowHeight: CGFloat = 36
    public static let sidebarGlyphWidth: CGFloat = 18

    public static let contentInset: CGFloat = 20
    public static let sheetInset: CGFloat = 16

    public static let controlInset: CGFloat = 12
}

public enum Radius {
    public static let r4: CGFloat = 4,  r6: CGFloat = 6
    public static let r8: CGFloat = 8,  r10: CGFloat = 10
    public static let r12: CGFloat = 12, r16: CGFloat = 16
}

public enum RowHeight {
    public static let compact: CGFloat = 24
    public static let regular: CGFloat = 28
    public static let download: CGFloat = 56
    public static let searchField: CGFloat = 36

    public static let rowPaddingV: CGFloat = 6
    public static let fileRowPaddingV: CGFloat = 6
    public static let columnGap: CGFloat = 16
    public static let subLineGap: CGFloat = 2
    public static let trackTopGap: CGFloat = 6
    public static let trackHeight: CGFloat = 3
}

/**
 A row's vertical bands. `single` is a one-line row; `stacked` is a row whose
 name cell carries a subline and a progress track, and `firstLine` is the band
 its short neighbours centre against so they do not sink with the stack.
 */
public enum RowMetrics {
    public static let single: CGFloat = 28
    public static let stacked: CGFloat = 56
    public static let firstLine: CGFloat = 20
    public static let headerHeight: CGFloat = 28
}

public enum SeederMeter {
    public static let barsWidth: CGFloat = 4 * 2 + 3
    public static let countWidth: CGFloat = 44
    public static let width: CGFloat = barsWidth + Spacing.s4 + countWidth
}

public enum IconSize {
    public static let xs: CGFloat = 10, sm: CGFloat = 12, md: CGFloat = 14
    public static let lg: CGFloat = 16, xl: CGFloat = 20
    public static let xxl: CGFloat = 32
}
