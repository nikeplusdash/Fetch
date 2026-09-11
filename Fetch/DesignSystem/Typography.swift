import SwiftUI

public enum FetchFont {
    public static let largeTitle   = Font.system(size: 26, weight: .regular)
    public static let title1       = Font.system(size: 22, weight: .regular)
    public static let title2       = Font.system(size: 17, weight: .regular)
    public static let title3       = Font.system(size: 15, weight: .regular)
    public static let headline     = Font.system(size: 13, weight: .bold)
    public static let body         = Font.system(size: 13, weight: .regular)
    public static let callout      = Font.system(size: 12, weight: .regular)
    public static let subheadline  = Font.system(size: 11, weight: .regular)
    public static let footnote     = Font.system(size: 10, weight: .regular)
    public static let caption2     = Font.system(size: 10, weight: .medium)

    public static let bodyMono     = Font.system(size: 13, weight: .regular).monospacedDigit()
    public static let calloutMono  = Font.system(size: 12, weight: .regular).monospacedDigit()
    public static let footnoteMono = Font.system(size: 10, weight: .regular).monospacedDigit()


    public static let sectionLabel = Font.system(size: 10, weight: .semibold)
    public static let sheetTitle   = Font.system(size: 15, weight: .semibold)
    public static let tagLabel     = Font.system(size: 10, weight: .semibold)

    public static let sectionTracking: CGFloat = 0.8
}

public extension View {
    func sectionLabel() -> some View {
        self
            .font(FetchFont.sectionLabel)
            .tracking(FetchFont.sectionTracking)
            .textCase(.uppercase)
            .foregroundStyle(Palette.textTertiary)
    }
}
