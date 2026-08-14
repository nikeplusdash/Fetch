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

    // MARK: - The UI pass
    //
    // Three roles the designs use that the scale had no entry for. Added here
    // rather than as a `Font.system` at the call site, because a size written
    // into a view is a size no other view can agree with.

    /// A column heading, or the title of a settings group. Tracked out and set
    /// in caps by `.sectionLabel()`, which applies the tracking with it —
    /// quieter than any value beneath it, so it reads as a label for a column
    /// rather than an entry in it.
    public static let sectionLabel = Font.system(size: 10, weight: .semibold)
    /// The name at the top of a sheet.
    public static let sheetTitle   = Font.system(size: 15, weight: .semibold)
    /// The filled Queued / Ready pill.
    public static let tagLabel     = Font.system(size: 10, weight: .semibold)

    /// The tracking `sectionLabel` is drawn with. 0.08em at 10pt.
    public static let sectionTracking: CGFloat = 0.8
}

public extension View {
    /// A column heading or group title: tracked small caps in tertiary ink.
    ///
    /// One modifier rather than three lines repeated at every heading, so the
    /// tracking and the case cannot come apart from the size.
    func sectionLabel() -> some View {
        self
            .font(FetchFont.sectionLabel)
            .tracking(FetchFont.sectionTracking)
            .textCase(.uppercase)
            .foregroundStyle(Palette.textTertiary)
    }
}
