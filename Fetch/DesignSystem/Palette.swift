import SwiftUI
import FetchKit

/**
 Which theme the window is currently made of.

 **A holder rather than a property on `AppModel`, and the reason is that
 `Palette` is static.** Every token is reached as `Palette.textSecondary`
 from 79 call sites that have no model, no environment and no binding, and
 threading one through all of them is the "one screen changes" that this plan
 exists to avoid. `@Observable` is what makes a static read still redraw: a
 view body that touches `Palette.textSecondary` records a dependency on
 `theme` through this object, so changing it invalidates exactly the views
 that were painted with it and nothing else.

 `@unchecked Sendable` because the macro's storage is not: `theme` is written
 only from `AppModel.setAppearanceTheme`, which is `@MainActor`, and read
 from view bodies, which are too. Marking the class `@MainActor` instead
 would make `Palette` main-actor-isolated, which `View.sectionLabel()` — a
 nonisolated extension in `Typography` — cannot call.
 */
@Observable
final class ActiveTheme: @unchecked Sendable {
    static let shared = ActiveTheme()

    var theme: AppearanceTheme = .blizzard

    private init() {}

    var isTranslucent: Bool { theme.palette(inDarkAppearance: false).isTranslucent }
}

public enum Palette {

    public static var cached: Color { themed(\.ready) }
    public static var miss: Color { themed(\.stop) }
    public static var attention: Color { themed(\.warn) }
    public static var inProgress: Color { themed(\.live) }
    public static var unknown: Color { themed(\.inkTertiary) }


    public static var windowBackground: Color { themed(\.chrome) }
    public static var contentBackground: Color { themed(\.pane) }
    public static var rowAlternate: Color { themed(\.rowAlternate) }

    public static let accent = Color.accentColor


    public static var textPrimary: Color { themed(\.ink) }
    public static var textSecondary: Color { themed(\.inkSecondary) }
    public static var textTertiary: Color { themed(\.inkTertiary) }
    public static var textQuaternary: Color { themed(\.inkQuaternary) }

    public static var separator: Color { themed(\.line) }

    public static var windowScrim: Color { themed(\.scrim) }


    public static let bgSelected = Color(nsColor: .selectedContentBackgroundColor)

    public static let bgSelectedInactive =
        Color(nsColor: .unemphasizedSelectedContentBackgroundColor)

    public static let textOnAccent = Color(nsColor: .alternateSelectedControlTextColor)

    /**
     Ink for a row painted with `bgSelected`. Named apart from `textOnAccent`
     so a theme can move a selected row's ink without moving the ink on every
     accent-filled control.
     */
    public static var textOnSelectedRow: Color { textOnAccent }

    public static var selection: Color { themed(\.selection) }
    public static var onSelection: Color { themed(\.onSelection) }

    public static let statusOnFill = Color(nsColor: .alternateSelectedControlTextColor)


    public static var fillQuaternary: Color { themed(\.fill) }

    public static var fillTrack: Color { themed(\.fillStrong) }

    public static var borderGrid: Color { themed(\.lineSoft) }


    private static func themed(_ token: KeyPath<ThemePalette, ThemeColor>) -> Color {
        let theme = ActiveTheme.shared.theme
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(theme.palette(inDarkAppearance: isDark)[keyPath: token])
        })
    }
}

extension NSColor {
    convenience init(_ color: ThemeColor) {
        self.init(
            srgbRed: color.red,
            green: color.green,
            blue: color.blue,
            alpha: color.alpha)
    }
}
