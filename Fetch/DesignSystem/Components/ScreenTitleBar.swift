import SwiftUI

/// The strip along the top of the detail column, carrying the app's name.
///
/// The strip has to exist regardless: the title bar is hidden, so every screen
/// owns the window down to its top edge and has to leave the traffic lights
/// across the divider a clear band. It was reserved space and nothing else,
/// which left the widest part of the window's top saying nothing at all.
///
/// One view rather than a line of text on each screen, because "the same on
/// every view" is a promise three separate copies cannot keep.
struct ScreenTitleBar: View {
    var body: some View {
        Text(Self.appName)
            .font(FetchFont.headline)
            .foregroundStyle(Palette.textPrimary)
            .lineLimit(1)
            .padding(.horizontal, Spacing.s12)
            // Centred across the detail column, which is the surface it
            // titles — the sidebar has its own name for itself in the three
            // destinations, and a title centred over both would sit off to one
            // side of everything it belongs to.
            .frame(maxWidth: .infinity)
            .frame(height: Self.height)
        // **On the lights' centre line, not the strip's.** The lights sit
        // `trafficLightInset` from the top of the window and this strip is
        // taller than that — centred in the strip the name rides above the
        // buttons it is supposed to sit level with, which is visible the moment
        // your eye crosses the divider. Derived, so retuning either constant
        // keeps the two on one line.
        .offset(y: WindowMetrics.trafficLightsCenterY - Self.height / 2)
    }

    /// The strip's full height: the lights' clearance **and the gap under it**.
    ///
    /// **The gap belongs here, not at four call sites.** Every screen has to
    /// leave the same room above its first control, and each of them was
    /// leaving it separately — Search with its own `.padding(.top, 8)`,
    /// Downloads and Settings each with a `firstControlGap`, the sidebar with a
    /// third. Four copies of one rule is four chances to disagree, and they
    /// took two of them: a manual fix to one screen left it eight points above
    /// the other three, and the previous fix had left Search behind instead.
    ///
    /// Now the strip is the whole distance. A screen that shows one gets the
    /// gap; a screen that adds its own would be adding it twice, which is
    /// visible immediately rather than subtly.
    static var height: CGFloat {
        WindowMetrics.titleBarInset + WindowMetrics.firstControlGap
    }

    /// Read from the bundle rather than typed here, so it cannot come to
    /// disagree with the app it is naming.
    static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Fetch"
    }
}
