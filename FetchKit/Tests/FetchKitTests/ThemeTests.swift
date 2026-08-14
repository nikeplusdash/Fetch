import Testing
@testable import FetchKit

/// **Contrast is a test, not a judgement.**
///
/// The app target has no test bundle, so the palettes live in FetchKit purely
/// so this file can exist. Every one of these walks `AppearanceTheme` rather
/// than naming the three themes: plan 3 merges last, on top of two screens
/// rewritten in other worktrees, and a check that enumerates costs nothing to
/// re-run against whatever those screens turned out to be.
@Suite("Theme contrast")
struct ThemeContrastTests {
    @Test("Relative luminance matches the WCAG anchors")
    func luminanceAnchors() {
        let black = ThemeColor.white(0, alpha: 1)
        let white = ThemeColor.white(1, alpha: 1)
        #expect(abs(black.relativeLuminance - 0) < 0.0001)
        #expect(abs(white.relativeLuminance - 1) < 0.0001)
        // The ratio the whole floor is expressed in terms of.
        #expect(abs(white.contrastRatio(on: black) - 21) < 0.01)
    }

    /// Alpha was the bug this guards. Measuring a 10%-opacity hairline as if
    /// it were solid reports a ratio the user will never see.
    @Test("A translucent ink is measured where it lands")
    func translucentInkIsComposited() {
        let half = ThemeColor.white(0, alpha: 0.5)
        let onWhite = half.contrastRatio(on: .white(1, alpha: 1))
        let opaqueBlack = ThemeColor.white(0, alpha: 1).contrastRatio(on: .white(1, alpha: 1))
        #expect(onWhite < opaqueBlack)
        #expect(onWhite > 1)
    }

    /// The rule the whole plan turns on: **a theme that fails the floor does
    /// not ship.**
    @Test("Every ink level clears its floor on every surface in every theme")
    func everyInkClearsItsFloor() {
        for rendering in AppearanceTheme.allRenderings {
            let palette = rendering.palette
            for level in InkLevel.allCases {
                guard let floor = level.contrastFloor else { continue }
                for surface in ThemeSurface.allCases {
                    let ratio = palette.ink(level)
                        .contrastRatio(on: palette.surface(surface))
                    #expect(
                        ratio >= floor,
                        """
                        \(rendering) \(level.rawValue) on \(surface.rawValue): \
                        \(String(format: "%.2f", ratio)):1, floor \(floor):1
                        """)
                }
            }
        }
    }

    /// Quaternary has no text floor, so what is asserted about it instead is
    /// that it stays the faintest: four levels that do not descend are not four
    /// levels, and a screen reaching for "one step quieter" would get louder.
    @Test("The four ink levels descend, in every theme")
    func inkOrdering() {
        for rendering in AppearanceTheme.allRenderings {
            let palette = rendering.palette
            let ratios = InkLevel.allCases.map {
                palette.ink($0).contrastRatio(on: palette.pane)
            }
            for (louder, quieter) in zip(ratios, ratios.dropFirst()) {
                #expect(louder > quieter, "\(rendering): \(ratios)")
            }
        }
    }

    /// Status colours are glyphs and one-word labels, and they are only ever
    /// drawn on the pane or on a banded row — never on the sidebar.
    @Test("Every status colour clears the status floor")
    func statusColoursClearTheirFloor() {
        for rendering in AppearanceTheme.allRenderings {
            let palette = rendering.palette
            let statuses: [(String, ThemeColor)] = [
                ("ready", palette.ready), ("warn", palette.warn), ("stop", palette.stop),
                // Added at integration. It was the user's System Settings
                // accent, so until now the one glyph meaning "running" was the
                // only status whose contrast could not be measured at all.
                ("live", palette.live),
            ]
            for (name, colour) in statuses {
                for surface in [ThemeSurface.pane, .rowAlternate] {
                    let ratio = colour.contrastRatio(on: palette.surface(surface))
                    #expect(
                        ratio >= Theme.statusContrastFloor,
                        """
                        \(rendering) \(name) on \(surface.rawValue): \
                        \(String(format: "%.2f", ratio)):1
                        """)
                }
            }
        }
    }

    @Test("Text on a selected row clears its floor")
    func onSelectionClearsItsFloor() {
        for rendering in AppearanceTheme.allRenderings {
            let palette = rendering.palette
            let ratio = palette.onSelection.contrastRatio(on: palette.selection)
            #expect(
                ratio >= Theme.onSelectionContrastFloor,
                "\(rendering): \(String(format: "%.2f", ratio)):1")
        }
    }
}

@Suite("What a theme may change")
struct ThemeInvariantTests {
    /// **Green is landed in all three.** A theme may restate a colour; it may
    /// not restate what the colour means. This is the cheapest form that claim
    /// can be checked in: the ready colour is green in every theme, and the
    /// three status colours never collide.
    @Test("Ready is green everywhere, and the three statuses stay apart")
    func statusMeaningIsFixed() {
        for rendering in AppearanceTheme.allRenderings {
            let palette = rendering.palette
            #expect(
                palette.ready.green > palette.ready.red
                    && palette.ready.green > palette.ready.blue,
                "\(rendering): ready is not green")
            // Failed is red-dominant, needs-attention is warm and not red.
            #expect(palette.stop.red > palette.stop.green, "\(rendering): stop is not red")
            #expect(
                palette.warn.red > palette.warn.blue
                    && palette.warn.green > palette.warn.blue,
                "\(rendering): warn is not amber")
            #expect(palette.ready != palette.warn && palette.warn != palette.stop)
            #expect(
                palette.live.blue > palette.live.red
                    && palette.live.blue > palette.live.green,
                "\(rendering): live is not blue")
        }
    }

    /// The token set is the contract with the two screens rewritten elsewhere.
    /// A theme that is missing one, or that leaves a surface see-through,
    /// breaks a screen this plan is not allowed to open.
    @Test("Every theme states the same tokens, and its surfaces are opaque")
    func tokenSetIsComplete() {
        let expected = Theme.glassLight.allTokens.map(\.name)
        for rendering in AppearanceTheme.allRenderings {
            let palette = rendering.palette
            #expect(palette.allTokens.map(\.name) == expected, "\(rendering)")
            for surface in ThemeSurface.allCases {
                #expect(palette.surface(surface).isOpaque, "\(rendering) \(surface.rawValue)")
            }
            #expect(palette.selection.isOpaque, "\(rendering) selection")
            #expect(palette.onSelection.isOpaque, "\(rendering) onSelection")
        }
    }

    /// Only Glass is a lens, so only Glass has a scrim to steady it. A scrim
    /// over an opaque surface is a second, undeclared surface colour.
    @Test("Only a translucent theme carries a scrim")
    func onlyGlassIsScrimmed() {
        for rendering in AppearanceTheme.allRenderings {
            let palette = rendering.palette
            #expect(palette.isTranslucent == (rendering.theme == .glass))
            #expect((palette.scrim.alpha > 0) == palette.isTranslucent, "\(rendering)")
        }
    }

    /// The pinning rule, stated twice in the type and checked once here: a
    /// theme that follows the system must not also name an appearance, and one
    /// that does not follow must.
    @Test("Pinning agrees with following")
    func pinningAgreesWithFollowing() {
        for theme in AppearanceTheme.allCases {
            #expect((theme.prefersDarkAppearance == nil) == theme.followsSystemAppearance)
        }
        #expect(AppearanceTheme.blizzard.prefersDarkAppearance == false)
        #expect(AppearanceTheme.midnight.prefersDarkAppearance == true)
    }

    /// Glass is two renderings because it follows; the other two are one each.
    @Test("Renderings cover every appearance the app can be in")
    func renderingsAreComplete() {
        let renderings = AppearanceTheme.allRenderings
        #expect(renderings.count == 4)
        #expect(renderings.filter { $0.theme == .glass }.count == 2)
        #expect(renderings.filter { $0.theme == .blizzard } == [
            ThemeRendering(theme: .blizzard, isDark: false)
        ])
        #expect(renderings.filter { $0.theme == .midnight } == [
            ThemeRendering(theme: .midnight, isDark: true)
        ])
    }

    /// Asking a pinned theme for the appearance it does not have must not
    /// hand back a palette it does not own — that is how a light row lands in
    /// Midnight when the system flips at three in the morning.
    @Test("A pinned theme answers with one palette whichever way it is asked")
    func pinnedThemesIgnoreTheSystem() {
        for theme in AppearanceTheme.allCases where !theme.followsSystemAppearance {
            #expect(theme.palette(inDarkAppearance: true) == theme.palette(inDarkAppearance: false))
        }
        #expect(
            AppearanceTheme.glass.palette(inDarkAppearance: true)
                != AppearanceTheme.glass.palette(inDarkAppearance: false))
    }

    /// A banded row is the fill over the pane, not a third colour.
    @Test("The banded row is derived from the fill")
    func rowAlternateIsDerived() {
        for rendering in AppearanceTheme.allRenderings {
            let palette = rendering.palette
            #expect(palette.rowAlternate == palette.fill.composited(over: palette.pane))
            #expect(palette.rowAlternate != palette.pane)
        }
    }
}
