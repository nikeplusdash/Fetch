import Foundation

/**
 One colour, in sRGB, with no dependency on AppKit or SwiftUI.

 **Here rather than as a `Color`.** The contrast floor is the only rule in
 this plan that can actually be checked, and the app target has no test
 bundle to check it in. A `Color` cannot be read back for its components on
 any platform we can run `swift test` on, so the palettes are declared in
 numbers the test can do arithmetic with and converted to `Color` once, at
 the boundary, in `Palette`.
 */
public struct ThemeColor: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /**
     `0xRRGGBB`, the form the design page states every value in.
     */
    public init(hex: UInt32, alpha: Double = 1) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            alpha: alpha)
    }

    /**
     Black or white at an opacity — how the design page writes every
     separator and fill, and how `Palette` already wrote them.
     */
    public static func white(_ level: Double, alpha: Double) -> ThemeColor {
        ThemeColor(red: level, green: level, blue: level, alpha: alpha)
    }

    public var isOpaque: Bool { alpha >= 1 }

    /**
     Source-over composite, for measuring a translucent ink or fill against
     the surface it actually lands on.

     A contrast ratio between two translucent colours is meaningless, and
     every separator, fill and quaternary ink in all three themes is
     translucent — so the test composites before it measures rather than
     silently treating alpha as if it were 1.
     */
    public func composited(over backdrop: ThemeColor) -> ThemeColor {
        guard alpha < 1 else { return self }
        let a = alpha
        return ThemeColor(
            red: red * a + backdrop.red * (1 - a),
            green: green * a + backdrop.green * (1 - a),
            blue: blue * a + backdrop.blue * (1 - a),
            alpha: 1)
    }

    public var relativeLuminance: Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045
                ? channel / 12.92
                : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /**
     The WCAG ratio of this colour, laid on `surface`, against that surface.

     `surface` must be opaque — every surface a theme declares is.
     */
    public func contrastRatio(on surface: ThemeColor) -> Double {
        let ink = composited(over: surface).relativeLuminance
        let bed = surface.relativeLuminance
        let lighter = max(ink, bed), darker = min(ink, bed)
        return (lighter + 0.05) / (darker + 0.05)
    }
}

/**
 A surface a theme paints, and that ink is drawn on.

 Three, and no more: a fourth would be a colour some screen had invented for
 itself, which is the thing this plan exists to make impossible.
 */
public enum ThemeSurface: String, CaseIterable, Sendable {
    case chrome
    case pane
    case rowAlternate
}

/**
 The four text levels, and what each is measured against.

 **The floor is per level, not per theme.** A theme that cannot meet it at a
 level changes its ink until it can; it does not get a lower floor for being
 prettier. Glass and Blizzard both had their tertiary darkened for exactly
 this reason — see the two `ink3` comments in `Theme`.
 */
public enum InkLevel: String, CaseIterable, Sendable {
    case primary, secondary, tertiary, quaternary

    public var contrastFloor: Double? {
        switch self {
        case .primary: 7.0
        case .secondary: 4.5
        case .tertiary: 3.0
        case .quaternary: nil
        }
    }
}

/**
 A theme, rendered for one system appearance.

 Glass has two of these because it follows the system; the other two have one
 each, because they state their own value. Enumerating them is how the test
 covers "every theme" without knowing which themes exist.
 */
public struct ThemeRendering: Hashable, Sendable, CustomStringConvertible {
    public let theme: AppearanceTheme
    public let isDark: Bool

    public init(theme: AppearanceTheme, isDark: Bool) {
        self.theme = theme
        self.isDark = isDark
    }

    public var palette: ThemePalette { theme.palette(inDarkAppearance: isDark) }

    public var description: String {
        theme.followsSystemAppearance
            ? "\(theme.title) (\(isDark ? "dark" : "light"))"
            : theme.title
    }
}

/**
 Every token a theme owns, in numbers.

 `Palette` maps each of these onto the token names the app already reads.
 **Nothing is added here that no `Palette` token consumes** — a value in this
 struct that no screen can reach is a colour with no meaning, and the design
 page has several (`--live`, `--desk-2`) that are page furniture rather than
 app tokens.
 */
public struct ThemePalette: Equatable, Sendable {
    public let chrome: ThemeColor
    public let pane: ThemeColor

    public let ink: ThemeColor
    public let inkSecondary: ThemeColor
    public let inkTertiary: ThemeColor
    public let inkQuaternary: ThemeColor

    public let line: ThemeColor
    public let lineSoft: ThemeColor
    public let fill: ThemeColor
    public let fillStrong: ThemeColor

    public let selection: ThemeColor
    public let onSelection: ThemeColor

    public let ready: ThemeColor
    public let warn: ThemeColor
    public let stop: ThemeColor
    public let live: ThemeColor

    public let scrim: ThemeColor

    public let isTranslucent: Bool

    public var rowAlternate: ThemeColor { fill.composited(over: pane) }

    public func surface(_ surface: ThemeSurface) -> ThemeColor {
        switch surface {
        case .chrome: chrome
        case .pane: pane
        case .rowAlternate: rowAlternate
        }
    }

    public func ink(_ level: InkLevel) -> ThemeColor {
        switch level {
        case .primary: ink
        case .secondary: inkSecondary
        case .tertiary: inkTertiary
        case .quaternary: inkQuaternary
        }
    }

    public var allTokens: [(name: String, color: ThemeColor)] {
        [
            ("chrome", chrome), ("pane", pane), ("rowAlternate", rowAlternate),
            ("ink", ink), ("inkSecondary", inkSecondary),
            ("inkTertiary", inkTertiary), ("inkQuaternary", inkQuaternary),
            ("line", line), ("lineSoft", lineSoft),
            ("fill", fill), ("fillStrong", fillStrong),
            ("selection", selection), ("onSelection", onSelection),
            ("ready", ready), ("warn", warn), ("stop", stop),
            ("scrim", scrim),
        ]
    }
}

public extension AppearanceTheme {
    var prefersDarkAppearance: Bool? {
        followsSystemAppearance ? nil : self == .midnight
    }

    static var allRenderings: [ThemeRendering] {
        allCases.flatMap { theme -> [ThemeRendering] in
            if let pinned = theme.prefersDarkAppearance {
                return [ThemeRendering(theme: theme, isDark: pinned)]
            }
            return [
                ThemeRendering(theme: theme, isDark: false),
                ThemeRendering(theme: theme, isDark: true),
            ]
        }
    }

    func palette(inDarkAppearance isDark: Bool) -> ThemePalette {
        switch self {
        case .glass: isDark ? Theme.glassDark : Theme.glassLight
        case .blizzard: Theme.blizzard
        case .midnight: Theme.midnight
        }
    }
}

/**
 The three palettes.

 Values are the design page's, with two exceptions, both marked, both forced
 by the contrast floor. Nothing else in the app may state a colour.
 */
public enum Theme {

    public static let glassLight = ThemePalette(
        chrome: ThemeColor(hex: 0xCFD8E2),
        pane: ThemeColor(hex: 0xEEF2F6),
        ink: ThemeColor(hex: 0x14181D),
        inkSecondary: ThemeColor(hex: 0x4A5663),
        inkTertiary: ThemeColor(hex: 0x6D7986),
        inkQuaternary: ThemeColor(hex: 0x14181D, alpha: 0.10),
        line: ThemeColor(hex: 0x14181D, alpha: 0.13),
        lineSoft: ThemeColor(hex: 0x14181D, alpha: 0.07),
        fill: ThemeColor(hex: 0x14181D, alpha: 0.06),
        fillStrong: ThemeColor(hex: 0x14181D, alpha: 0.12),
        selection: ThemeColor(hex: 0x14181D),
        onSelection: ThemeColor(hex: 0xFFFFFF),
        ready: ThemeColor(hex: 0x1E8A52),
        warn: ThemeColor(hex: 0xB8720F),
        stop: ThemeColor(hex: 0xC14733),
        live: ThemeColor(hex: 0x2F6FD0),
        scrim: .white(0, alpha: 0.16),
        isTranslucent: true)

    public static let glassDark = ThemePalette(
        chrome: ThemeColor(hex: 0x202225),
        pane: ThemeColor(hex: 0x191B1E),
        ink: ThemeColor(hex: 0xE9EBEE),
        inkSecondary: ThemeColor(hex: 0x9AA6B2),
        inkTertiary: ThemeColor(hex: 0x6D7883),
        inkQuaternary: .white(1, alpha: 0.10),
        line: .white(1, alpha: 0.11),
        lineSoft: .white(1, alpha: 0.06),
        fill: .white(1, alpha: 0.07),
        fillStrong: .white(1, alpha: 0.18),
        selection: ThemeColor(hex: 0xE9EBEE),
        onSelection: ThemeColor(hex: 0x14171A),
        ready: ThemeColor(hex: 0x45C07E),
        warn: ThemeColor(hex: 0xE0A04A),
        stop: ThemeColor(hex: 0xE2705C),
        live: ThemeColor(hex: 0x6BA4EF),
        scrim: .white(0, alpha: 0.16),
        isTranslucent: true)


    public static let blizzard = ThemePalette(
        chrome: ThemeColor(hex: 0xF3EFE6),
        pane: ThemeColor(hex: 0xFBF9F4),
        ink: ThemeColor(hex: 0x1F1C17),
        inkSecondary: ThemeColor(hex: 0x5F594E),
        inkTertiary: ThemeColor(hex: 0x8A8376),
        inkQuaternary: ThemeColor(hex: 0x1F1C17, alpha: 0.10),
        line: ThemeColor(hex: 0x1F1C17, alpha: 0.13),
        lineSoft: ThemeColor(hex: 0x1F1C17, alpha: 0.07),
        fill: ThemeColor(hex: 0x1F1C17, alpha: 0.05),
        fillStrong: ThemeColor(hex: 0x1F1C17, alpha: 0.11),
        selection: ThemeColor(hex: 0x1F1C17),
        onSelection: ThemeColor(hex: 0xFBF9F4),
        ready: ThemeColor(hex: 0x2C7F4E),
        warn: ThemeColor(hex: 0xB8720F),
        stop: ThemeColor(hex: 0xC14733),
        live: ThemeColor(hex: 0x2F6FD0),
        scrim: .white(0, alpha: 0),
        isTranslucent: false)


    public static let midnight = ThemePalette(
        chrome: ThemeColor(hex: 0x131519),
        pane: ThemeColor(hex: 0x0D0F12),
        ink: ThemeColor(hex: 0xE8EAEE),
        inkSecondary: ThemeColor(hex: 0x98A2AE),
        inkTertiary: ThemeColor(hex: 0x69737F),
        inkQuaternary: .white(1, alpha: 0.10),
        line: .white(1, alpha: 0.10),
        lineSoft: .white(1, alpha: 0.055),
        fill: .white(1, alpha: 0.06),
        fillStrong: .white(1, alpha: 0.16),
        selection: ThemeColor(hex: 0xE8EAEE),
        onSelection: ThemeColor(hex: 0x0D0F12),
        ready: ThemeColor(hex: 0x43C07D),
        warn: ThemeColor(hex: 0xE0A04A),
        stop: ThemeColor(hex: 0xE2705C),
        live: ThemeColor(hex: 0x6BA4EF),
        scrim: .white(0, alpha: 0),
        isTranslucent: false)

    public static let statusContrastFloor: Double = 3.0

    public static let onSelectionContrastFloor: Double = 4.5
}
