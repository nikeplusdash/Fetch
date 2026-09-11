import Foundation

/**
 What the window is made of.

 Declared in the foundation commit so `AppModel` can hold one and plans 1 and
 2 compile against it. **Plan 3 fills in the palettes** and the resolver that
 turns one of these into the token set `Palette` reads; nothing else may.

 A theme may change surfaces, the four ink levels, material and selection
 fill. It may not change layout, which glyph a state uses, any copy, or the
 meaning of a colour — green is landed in all three. Every theme is measured
 to the same contrast floor or it does not ship, which is why this type lives
 in FetchKit: that measurement is a test, and the app target has no bundle to
 put one in.
 */
public enum AppearanceTheme: String, CaseIterable, Sendable, Identifiable {
    case glass
    case blizzard
    case midnight

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .glass: "Glass"
        case .blizzard: "Blizzard"
        case .midnight: "Midnight"
        }
    }

    public var followsSystemAppearance: Bool { self == .glass }
}
