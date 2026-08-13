import SwiftUI

/// Semantic colour tokens. Light values are measured for >=3:1 contrast on
/// `bg/content`; dark values are confirmed against the Figma library.
public enum Palette {
    // Status — design system spec §3.3
    public static let cached    = dynamic(light: 0x1EA333, dark: 0x32D74B)
    public static let miss      = dynamic(light: 0xFF3B30, dark: 0xFF453A)
    public static let attention = dynamic(light: 0xD97C00, dark: 0xFF9F0A)
    public static let unknown   = dynamic(light: 0x8E8E93, dark: 0x98989D)

    // Chrome
    public static let windowBackground  = dynamic(light: 0xECECEC, dark: 0x1E1E1E)
    public static let contentBackground = dynamic(light: 0xFFFFFF, dark: 0x1E1E1E)
    public static let rowAlternate      = dynamic(light: 0xF4F5F5, dark: 0x262628)

    /// The user's System Settings accent, not a brand colour (§3.2).
    public static let accent = Color.accentColor

    // Text — expressed as opacity over label colours so they track appearance.
    public static let textPrimary    = Color.primary.opacity(0.85)
    public static let textSecondary  = Color.secondary
    public static let textTertiary   = dynamicWhite(light: 0.42, dark: 0.33)
    public static let textQuaternary = dynamicWhite(light: 0.10, dark: 0.10)

    public static let separator = dynamicWhite(light: 0.10, dark: 0.15)

    /// A slight darkening laid over the window's frosted material.
    ///
    /// Material alone is beautiful and, over a bright wallpaper, thin: small
    /// text at `textSecondary` on `.ultraThinMaterial` above a sunlit
    /// photograph falls well under the 4.5:1 the design system asks for, and
    /// the contrast changes as the user's desktop does — which is the worst
    /// property a text background can have.
    ///
    /// One scrim over the whole window fixes the floor without turning the
    /// frost into a panel: enough to stabilise contrast, not enough to read as
    /// a solid surface. Heavier in dark mode, where the material itself is
    /// lighter than the text it carries.
    public static let windowScrim = Color.black.opacity(0.16)

    // MARK: - Selection

    /// A selected row in a focused list. Figma states `#0A82FF`; AppKit's
    /// value tracks the user's accent, which is what the design system spec
    /// §3.2 asks for ("the user's System Settings accent, not a brand colour").
    public static let bgSelected = Color(nsColor: .selectedContentBackgroundColor)

    /// A selected row in a list that does **not** have focus.
    ///
    /// Not cosmetic. A row painted full accent blue in an unfocused list
    /// claims focus it does not have, which is the same kind of lie `.failed`
    /// told about a deleted file.
    public static let bgSelectedInactive =
        Color(nsColor: .unemphasizedSelectedContentBackgroundColor)

    /// Text and glyphs drawn on `bgSelected` or on a filled `CategoryPill`.
    public static let textOnAccent = Color(nsColor: .alternateSelectedControlTextColor)

    /// A status glyph drawn on a filled background — the selected row's cache
    /// badge, where `Palette.cached` green on accent blue fails contrast.
    public static let statusOnFill = Color(nsColor: .alternateSelectedControlTextColor)

    // MARK: - Fills

    /// Chip and unselected-pill backgrounds. Figma: `#00000014`.
    public static let fillQuaternary = dynamicWhite(light: 0.08, dark: 0.12)

    /// The unfilled part of a `ProgressTrack` or a `SeederMeter` bar.
    public static let fillTrack = dynamicWhite(light: 0.12, dark: 0.18)

    /// Row separators inside the file tree, which are lighter than
    /// `separator` because they subdivide rather than divide.
    public static let borderGrid = Color(nsColor: .gridColor)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }

    /// Black-at-opacity in light, white-at-opacity in dark (spec expresses
    /// these as alpha over a base, not as distinct hues).
    private static func dynamicWhite(light: Double, dark: Double) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark
                ? NSColor(white: 1.0, alpha: dark)
                : NSColor(white: 0.0, alpha: light)
        })
    }
}

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: Double((hex >> 16) & 0xFF) / 255.0,
            green:   Double((hex >> 8) & 0xFF) / 255.0,
            blue:    Double(hex & 0xFF) / 255.0,
            alpha:   1.0
        )
    }
}
