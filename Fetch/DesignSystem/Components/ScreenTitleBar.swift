import SwiftUI

/**
 The strip along the top of the detail column, carrying the app's name.

 The strip has to exist regardless: the title bar is hidden, so every screen
 owns the window down to its top edge and has to leave the traffic lights
 across the divider a clear band. It was reserved space and nothing else,
 which left the widest part of the window's top saying nothing at all.

 One view rather than a line of text on each screen, because "the same on
 every view" is a promise three separate copies cannot keep.
 */
struct ScreenTitleBar: View {
    var body: some View {
        Text(Self.appName)
            .font(FetchFont.headline)
            .foregroundStyle(Palette.textPrimary)
            .lineLimit(1)
            .padding(.horizontal, Spacing.s12)
            .frame(maxWidth: .infinity)
            .frame(height: Self.height)
        .offset(y: WindowMetrics.trafficLightsCenterY - Self.height / 2)
    }

    static var height: CGFloat {
        WindowMetrics.titleBarInset + WindowMetrics.firstControlGap
    }

    static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Fetch"
    }
}
