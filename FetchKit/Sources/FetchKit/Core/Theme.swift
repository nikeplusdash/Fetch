import Foundation

/// One colour, in sRGB, with no dependency on AppKit or SwiftUI.
///
/// **Here rather than as a `Color`.** The contrast floor is the only rule in
/// this plan that can actually be checked, and the app target has no test
/// bundle to check it in. A `Color` cannot be read back for its components on
/// any platform we can run `swift test` on, so the palettes are declared in
/// numbers the test can do arithmetic with and converted to `Color` once, at
/// the boundary, in `Palette`.
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

    /// `0xRRGGBB`, the form the design page states every value in.
    public init(hex: UInt32, alpha: Double = 1) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            alpha: alpha)
    }

    /// Black or white at an opacity — how the design page writes every
    /// separator and fill, and how `Palette` already wrote them.
    public static func white(_ level: Double, alpha: Double) -> ThemeColor {
        ThemeColor(red: level, green: level, blue: level, alpha: alpha)
    }

    public var isOpaque: Bool { alpha >= 1 }

    /// Source-over composite, for measuring a translucent ink or fill against
    /// the surface it actually lands on.
    ///
    /// A contrast ratio between two translucent colours is meaningless, and
    /// every separator, fill and quaternary ink in all three themes is
    /// translucent — so the test composites before it measures rather than
    /// silently treating alpha as if it were 1.
    public func composited(over backdrop: ThemeColor) -> ThemeColor {
        guard alpha < 1 else { return self }
        let a = alpha
        return ThemeColor(
            red: red * a + backdrop.red * (1 - a),
            green: green * a + backdrop.green * (1 - a),
            blue: blue * a + backdrop.blue * (1 - a),
            alpha: 1)
    }

    /// WCAG 2.1 relative luminance. Alpha is ignored: composite first.
    public var relativeLuminance: Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045
                ? channel / 12.92
                : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// The WCAG ratio of this colour, laid on `surface`, against that surface.
    ///
    /// `surface` must be opaque — every surface a theme declares is.
    public func contrastRatio(on surface: ThemeColor) -> Double {
        let ink = composited(over: surface).relativeLuminance
        let bed = surface.relativeLuminance
        let lighter = max(ink, bed), darker = min(ink, bed)
        return (lighter + 0.05) / (darker + 0.05)
    }
}

/// A surface a theme paints, and that ink is drawn on.
///
/// Three, and no more: a fourth would be a colour some screen had invented for
/// itself, which is the thing this plan exists to make impossible.
public enum ThemeSurface: String, CaseIterable, Sendable {
    /// The sidebar, and any bar drawn on the window rather than on the pane.
    case chrome
    /// The content surface every list and every settings pane sits on.
    case pane
    /// A row banded against the one above it: `fill` laid over `pane`.
    case rowAlternate
}

/// The four text levels, and what each is measured against.
///
/// **The floor is per level, not per theme.** A theme that cannot meet it at a
/// level changes its ink until it can; it does not get a lower floor for being
/// prettier. Glass and Blizzard both had their tertiary darkened for exactly
/// this reason — see the two `ink3` comments in `Theme`.
public enum InkLevel: String, CaseIterable, Sendable {
    case primary, secondary, tertiary, quaternary

    /// The ratio this level must clear on every surface in `surfaces`, or nil
    /// where the level is not text at all.
    public var contrastFloor: Double? {
        switch self {
        case .primary: 7.0        // AAA body: this is the name of the file
        case .secondary: 4.5      // AA body: the sub-line under it
        case .tertiary: 3.0       // AA large / non-text: counts, units, headings
        // Not text. `textQuaternary` is a hairline and a disabled fill, and
        // holding it to a text ratio would mean it could no longer be either.
        // What is asserted about it instead is that it stays the faintest of
        // the four — see `inkOrdering` in the tests.
        case .quaternary: nil
        }
    }
}

/// A theme, rendered for one system appearance.
///
/// Glass has two of these because it follows the system; the other two have one
/// each, because they state their own value. Enumerating them is how the test
/// covers "every theme" without knowing which themes exist.
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

/// Every token a theme owns, in numbers.
///
/// `Palette` maps each of these onto the token names the app already reads.
/// **Nothing is added here that no `Palette` token consumes** — a value in this
/// struct that no screen can reach is a colour with no meaning, and the design
/// page has several (`--live`, `--desk-2`) that are page furniture rather than
/// app tokens.
public struct ThemePalette: Equatable, Sendable {
    /// The sidebar's surface, and what a swatch shows beside the pane.
    public let chrome: ThemeColor
    /// The content surface. For Glass this is the opaque value the frosted
    /// material settles at, not a colour the app paints — see `isTranslucent`.
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

    /// Landed. **Green in all three themes**: a theme may restate a colour, it
    /// may not restate what the colour means.
    public let ready: ThemeColor
    /// Needs attention, and not an error.
    public let warn: ThemeColor
    /// Failed.
    public let stop: ThemeColor
    /// Moving: bytes are arriving now.
    ///
    /// **Added at integration, and the reason is worth keeping.** This was the
    /// user's System Settings accent, which is deliberately unthemed — so the
    /// one glyph that says a download is running had a colour no theme owned
    /// and no floor could be measured against. An accent is the user's
    /// statement about every app; it is not a status, and using it as one meant
    /// "downloading" was whatever hue happened to be set, against whichever of
    /// three surfaces happened to be behind it.
    public let live: ThemeColor

    /// Laid over the window's material to stop small text from depending on
    /// the user's wallpaper. Clear where there is no material to lay it on.
    public let scrim: ThemeColor

    /// Whether the window is a lens or a material. Only Glass is a lens.
    public let isTranslucent: Bool

    /// `fill` over `pane`. Derived rather than stated, because the two were
    /// stated separately once and drifted: a row band that is not the fill
    /// colour is a second fill nobody declared.
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

    /// Every token, by name, so a test can walk the set rather than list it.
    ///
    /// Plan 3 merges last, against two screens rewritten in other worktrees.
    /// Checking the token *set* is cheap and checking it by looking at screens
    /// is not, so the set is enumerable.
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
    /// Whether this theme pins the app's appearance, and to which.
    ///
    /// Nil for Glass, which follows. `AppModel` sets `NSApp.appearance` from
    /// this, and the AppKit-derived tokens that are deliberately *not* themed
    /// (the accent-tracking selection on the search results list) then resolve
    /// against the same appearance the theme states, instead of against a
    /// system setting the window is no longer showing.
    var prefersDarkAppearance: Bool? {
        followsSystemAppearance ? nil : self == .midnight
    }

    /// Every (theme, appearance) pair the app can actually be in.
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

    /// The token set for this theme under the given system appearance.
    ///
    /// `inDarkAppearance` is ignored by the two pinned themes: asking Midnight
    /// for its light palette is a question with no answer, and returning a
    /// light one would let a token resolve to a colour the theme does not have.
    func palette(inDarkAppearance isDark: Bool) -> ThemePalette {
        switch self {
        case .glass: isDark ? Theme.glassDark : Theme.glassLight
        case .blizzard: Theme.blizzard
        case .midnight: Theme.midnight
        }
    }
}

/// The three palettes.
///
/// Values are the design page's, with two exceptions, both marked, both forced
/// by the contrast floor. Nothing else in the app may state a colour.
public enum Theme {
    // MARK: - Glass

    /// Frosted material over the desktop, in a light system appearance.
    ///
    /// **The surfaces are opaque here and translucent on screen, on purpose.**
    /// A ratio against `rgba(252, 253, 255, .72)` over an unknown wallpaper is
    /// not a measurement, it is a wish — the number would change with the
    /// user's desktop, which is the worst property a contrast floor can have.
    /// These two are the values the material plus `scrim` settles at, and they
    /// are the same pair the design page paints its Glass swatch in, because a
    /// swatch has the same problem a test does: it has to show glass without
    /// having a desktop behind it.
    public static let glassLight = ThemePalette(
        chrome: ThemeColor(hex: 0xCFD8E2),
        pane: ThemeColor(hex: 0xEEF2F6),
        ink: ThemeColor(hex: 0x14181D),
        inkSecondary: ThemeColor(hex: 0x4A5663),
        // Design page says `#7c8894`. That measures 2.95:1 on `pane`, 2.62:1
        // on a banded row and 2.31:1 on `chrome`, against a floor of 3.
        // Darkened by the least that clears it on all three (3.96, 3.52, 3.09)
        // and no further; the hue is the page's.
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

    /// The same lens, in a dark system appearance. Glass follows.
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

    // MARK: - Blizzard

    /// The website's paper, brought inside. Warm white, and opaque: the point
    /// of this one is that the window stops changing as the desktop does.
    public static let blizzard = ThemePalette(
        chrome: ThemeColor(hex: 0xF3EFE6),
        pane: ThemeColor(hex: 0xFBF9F4),
        ink: ThemeColor(hex: 0x1F1C17),
        inkSecondary: ThemeColor(hex: 0x5F594E),
        // Design page says `#948d80`, which measures 2.80:1 on a banded row
        // and 2.83:1 on `chrome`. Same correction as Glass, same reason, same
        // hue; it clears at 3.57, 3.24 and 3.27.
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
        // No material, so nothing to steady. A scrim over an opaque surface is
        // just a darker opaque surface declared in two places.
        scrim: .white(0, alpha: 0),
        isTranslucent: false)

    // MARK: - Midnight

    /// Past dark mode: a pane darker than the app's own dark appearance, with
    /// thinner separators to compensate — a hairline that reads correctly on
    /// `#191b1e` is a stripe on `#0d0f12`.
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

    /// What a status colour must clear on the surfaces it is drawn on: the
    /// pane, and a banded row. **Not `chrome`** — a status colour is a glyph on
    /// a download row or a word in a settings pane, and the sidebar has three
    /// destinations and no states. Measuring it there would fail Glass's amber
    /// over text that is never drawn there, which is a test asserting something
    /// the app does not do.
    ///
    /// Three rather than 4.5: these are glyphs and one-word labels, not body
    /// text, and 4.5 across four themes would flatten the greens to the point
    /// where landed and running stop being distinguishable at a glance —
    /// which is the only job the colour has.
    public static let statusContrastFloor: Double = 3.0

    /// What text on a selected row must clear against the fill behind it.
    public static let onSelectionContrastFloor: Double = 4.5
}
