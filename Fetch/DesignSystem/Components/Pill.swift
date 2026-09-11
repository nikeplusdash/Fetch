import SwiftUI
import FetchKit

enum PillStyle: Equatable {
    case filled
    case tinted
    case outline
    case selected
}

enum PillShape: Equatable {
    case capsule
    case rounded
}

enum PillBorder: Equatable {
    case automatic
    case none
    case hairline
    case dashed
}

enum PillSize: Equatable {
    case mini
    case small
    case medium
    case large
    case bar(height: CGFloat)

    var horizontal: CGFloat {
        switch self {
        case .mini: Spacing.s6
        case .small: Spacing.s8
        case .medium, .large: Spacing.s12
        case .bar: Spacing.s16
        }
    }

    var vertical: CGFloat {
        switch self {
        case .mini, .small: Spacing.s2
        case .medium: Spacing.s4
        case .large: Spacing.s6
        case .bar: 0
        }
    }

    var height: CGFloat? {
        if case .bar(let height) = self { return height }
        return nil
    }
}

/**
 The one small capsule.

 **Eight of these were built separately.** The filter bar, the category row,
 the kind and quality chips on a result, the sheet's status tag, the search
 field's structured token, the facet sidebar's removable filter and the
 indexer health capsule were the same shape doing the same job, and each
 chose its own padding, its own radius, its own hairline and its own idea of
 how much tint a tint is. Two of them reached past the token set entirely —
 a 7-point glyph and a `.thinMaterial` bed.

 Colour comes from a `Tone`, which says what the pill means rather than what
 it looks like, and this is the single place a tone becomes a `Palette`
 token. `isOnFill` is for a pill riding a selected row: the ink and the
 hairline move onto the fill, the bed does not.
 */
struct Pill<Label: View>: View {
    var tone: Tone = .plain
    var style: PillStyle = .tinted
    var shape: PillShape = .capsule
    var border: PillBorder = .automatic
    var size: PillSize = .small
    var isOnFill: Bool = false
    @ViewBuilder let label: () -> Label

    var body: some View {
        label()
            .padding(.horizontal, size.horizontal)
            .padding(.vertical, size.vertical)
            .frame(height: size.height)
            .foregroundStyle(ink)
            .background { bed(fill) }
            .overlay { edge }
            .contentShape(outline)
    }

    private var ink: Color {
        if isOnFill { return Palette.statusOnFill }
        switch style {
        case .selected: return Palette.onSelection
        case .filled: return tone.isQuiet ? tone.ink : Palette.textOnAccent
        case .tinted, .outline: return tone.ink
        }
    }

    private var fill: Color {
        switch style {
        case .selected: Palette.selection
        case .filled: tone.solid
        case .tinted: tone.wash
        case .outline: .clear
        }
    }

    private var resolvedBorder: PillBorder {
        guard border == .automatic else { return border }
        return style == .outline ? .hairline : .none
    }

    private var edgeInk: Color {
        isOnFill ? Palette.textOnAccent.opacity(PillMetrics.onFillEdge) : Palette.separator
    }

    private var outline: AnyShape {
        switch shape {
        case .capsule: AnyShape(Capsule())
        case .rounded: AnyShape(RoundedRectangle(cornerRadius: Radius.r4))
        }
    }

    @ViewBuilder
    private func bed(_ color: Color) -> some View {
        switch shape {
        case .capsule: Capsule().fill(color)
        case .rounded: RoundedRectangle(cornerRadius: Radius.r4).fill(color)
        }
    }

    @ViewBuilder
    private var edge: some View {
        let dashed = resolvedBorder == .dashed
        let stroke = StrokeStyle(
            lineWidth: PillMetrics.hairline, dash: dashed ? PillMetrics.dash : [])
        if resolvedBorder != .none {
            switch shape {
            case .capsule: Capsule().strokeBorder(edgeInk, style: stroke)
            case .rounded: RoundedRectangle(cornerRadius: Radius.r4)
                    .strokeBorder(edgeInk, style: stroke)
            }
        }
    }
}

enum PillMetrics {
    static let hairline: CGFloat = 1
    static let dash: [CGFloat] = [2, 2]
    static let wash: Double = 0.14
    static let onFillEdge: Double = 0.5
    static let countInk: Double = 0.7
}

extension Tone {
    var ink: Color {
        switch self {
        case .plain: Palette.textPrimary
        case .muted: Palette.textSecondary
        case .quiet: Palette.textTertiary
        case .accent: Palette.accent
        case .positive: Palette.cached
        case .caution: Palette.attention
        case .danger: Palette.miss
        }
    }

    var isQuiet: Bool {
        switch self {
        case .plain, .muted, .quiet: true
        case .accent, .positive, .caution, .danger: false
        }
    }

    var wash: Color {
        isQuiet ? Palette.fillQuaternary : ink.opacity(PillMetrics.wash)
    }

    var solid: Color {
        isQuiet ? Palette.fillTrack : ink
    }
}
