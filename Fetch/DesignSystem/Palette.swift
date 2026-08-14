import SwiftUI
import FetchKit

/// Which theme the window is currently made of.
///
/// **A holder rather than a property on `AppModel`, and the reason is that
/// `Palette` is static.** Every token is reached as `Palette.textSecondary`
/// from 79 call sites that have no model, no environment and no binding, and
/// threading one through all of them is the "one screen changes" that this plan
/// exists to avoid. `@Observable` is what makes a static read still redraw: a
/// view body that touches `Palette.textSecondary` records a dependency on
/// `theme` through this object, so changing it invalidates exactly the views
/// that were painted with it and nothing else.
///
/// `@unchecked Sendable` because the macro's storage is not: `theme` is written
/// only from `AppModel.setAppearanceTheme`, which is `@MainActor`, and read
/// from view bodies, which are too. Marking the class `@MainActor` instead
/// would make `Palette` main-actor-isolated, which `View.sectionLabel()` — a
/// nonisolated extension in `Typography` — cannot call.
@Observable
final class ActiveTheme: @unchecked Sendable {
    static let shared = ActiveTheme()

    var theme: AppearanceTheme = .blizzard

    private init() {}

    /// Whether the window is a lens or a material, for the one place outside
    /// `Palette` that has to know: the window's own background in `FetchApp`.
    var isTranslucent: Bool { theme.palette(inDarkAppearance: false).isTranslucent }
}

/// Semantic colour tokens, resolved from the active theme.
///
/// **Every token resolves from the theme, and no token was renamed, added or
/// removed when it started doing so.** That is the whole reason the appearance
/// plan could be built last and merged after two screens had been rewritten in
/// other worktrees: a theme is a different set of numbers behind the same
/// names, so not one screen changed to gain three of them. If a screen looks
/// wrong in Blizzard or Midnight, it is hard-coding a colour, and the fix is in
/// that screen rather than here.
///
/// A theme may change surfaces, the four ink levels, material and selection
/// fill. It may not change layout, which glyph a state uses, any copy, or the
/// meaning of a colour — green is landed in all three, and that is asserted in
/// `ThemeTests`. The palettes themselves live in FetchKit so the contrast floor
/// can be measured; the app target has no test bundle.
public enum Palette {
    // MARK: - Status

    public static var cached: Color { themed(\.ready) }
    public static var miss: Color { themed(\.stop) }
    public static var attention: Color { themed(\.warn) }
    /// Moving: bytes are arriving now.
    ///
    /// **Not `accent`, which is what this used to be.** The accent is the
    /// user's System Settings statement about every app and is deliberately
    /// unthemed, so using it as a status meant the one glyph that says a
    /// download is running had a colour no theme owned and no contrast floor
    /// could be measured against.
    public static var inProgress: Color { themed(\.live) }
    /// No information is the same statement as "de-emphasised", so it is the
    /// same ink. It used to be a fourth grey that no theme owned.
    public static var unknown: Color { themed(\.inkTertiary) }

    // MARK: - Chrome

    /// The sidebar's surface. Opaque themes paint the window with `pane`, so
    /// this is currently what a swatch shows and what the contrast floor
    /// measures primary and secondary ink against.
    public static var windowBackground: Color { themed(\.chrome) }
    public static var contentBackground: Color { themed(\.pane) }
    public static var rowAlternate: Color { themed(\.rowAlternate) }

    /// The user's System Settings accent, not a brand colour (§3.2), and
    /// deliberately **not** themed: an accent is the user's statement about
    /// every app, and a theme overriding it would be this app deciding it knows
    /// better.
    public static let accent = Color.accentColor

    // MARK: - Ink

    public static var textPrimary: Color { themed(\.ink) }
    public static var textSecondary: Color { themed(\.inkSecondary) }
    public static var textTertiary: Color { themed(\.inkTertiary) }
    public static var textQuaternary: Color { themed(\.inkQuaternary) }

    public static var separator: Color { themed(\.line) }

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
    /// a solid surface.
    ///
    /// **Clear in Blizzard and Midnight**, which have no material to steady.
    /// A scrim over an opaque surface is only a darker opaque surface declared
    /// in a second place, and the two would drift.
    public static var windowScrim: Color { themed(\.scrim) }

    // MARK: - Selection

    /// A selected row in a focused list. Figma states `#0A82FF`; AppKit's
    /// value tracks the user's accent, which is what the design system spec
    /// §3.2 asks for ("the user's System Settings accent, not a brand colour").
    ///
    /// **Not themed, and it still moves with the theme.** Blizzard and Midnight
    /// pin `NSApp.appearance`, so this and the three AppKit colours below
    /// resolve against the appearance the theme states rather than against a
    /// system setting the window is no longer showing. Pinning is what lets
    /// four tokens stay AppKit's and still be right.
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

    /// **Ink, not accent** — the fill behind a chosen filter pill, settings
    /// pane or sidebar destination.
    ///
    /// The app had two selection colours and did not mean to: the accent for
    /// list rows, and a tint of its own on the sidebar. One selection colour is
    /// the point, and ink is the one that survives all three themes, since a
    /// user's accent is not ours to guarantee contrast for. `bgSelected` stays
    /// accent-tracking for the Search results list, which is not being touched.
    public static var selection: Color { themed(\.selection) }
    public static var onSelection: Color { themed(\.onSelection) }

    /// A status glyph drawn on a filled background — the selected row's cache
    /// badge, where `Palette.cached` green on accent blue fails contrast.
    public static let statusOnFill = Color(nsColor: .alternateSelectedControlTextColor)

    // MARK: - Fills

    /// Chip and unselected-pill backgrounds.
    public static var fillQuaternary: Color { themed(\.fill) }

    /// The unfilled part of a `ProgressTrack` or a `SeederMeter` bar.
    public static var fillTrack: Color { themed(\.fillStrong) }

    /// Row separators inside the file tree, which are lighter than
    /// `separator` because they subdivide rather than divide.
    public static var borderGrid: Color { themed(\.lineSoft) }

    // MARK: - Resolution

    /// One token, from the active theme, under whatever appearance the window
    /// is actually in.
    ///
    /// **Still a dynamic `NSColor`, and still for the original reason.** Glass
    /// follows the system, so its token has to be answered at draw time rather
    /// than at read time — a plain `Color` captured when the property was first
    /// touched would keep the appearance the app happened to launch in. The two
    /// pinned themes reach this closure too, and ignore its argument: they
    /// return the one palette they have whichever appearance asks.
    ///
    /// A fresh `NSColor` per read rather than a cached one, because a cached
    /// dynamic colour keeps resolving from the theme it was built for after the
    /// theme changes, which is a window half in Blizzard and half in Midnight.
    private static func themed(_ token: KeyPath<ThemePalette, ThemeColor>) -> Color {
        let theme = ActiveTheme.shared.theme
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(theme.palette(inDarkAppearance: isDark)[keyPath: token])
        })
    }
}

extension NSColor {
    /// The one place a `ThemeColor` becomes something AppKit can paint.
    convenience init(_ color: ThemeColor) {
        self.init(
            srgbRed: color.red,
            green: color.green,
            blue: color.blue,
            alpha: color.alpha)
    }
}
