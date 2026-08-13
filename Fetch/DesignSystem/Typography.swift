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

    // Tabular figures — any view showing a changing number uses these.
    public static let bodyMono     = Font.system(size: 13, weight: .regular).monospacedDigit()
    public static let calloutMono  = Font.system(size: 12, weight: .regular).monospacedDigit()
    public static let footnoteMono = Font.system(size: 10, weight: .regular).monospacedDigit()
}
