import SwiftUI
import FetchKit

/// One category on the search bar (Figma `CategoryPill`).
///
/// Selected uses the accent fill with `textOnAccent`; unselected uses
/// `fillQuaternary` with primary text — the same symbol renders in both
/// states, so it carries no state of its own. The fill/text-colour swap is a
/// large luminance change, not a colour-only distinction, and the
/// `.isSelected` accessibility trait carries the state for VoiceOver.
struct CategoryPillView: View {
    let category: SearchCategory
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.s4) {
                Image(systemName: category.symbolName)
                    .font(.system(size: IconSize.sm))
                Text(category.title)
                    .font(FetchFont.footnote)
            }
            .padding(.horizontal, Spacing.s12)
            .padding(.vertical, Spacing.s6)
            .foregroundStyle(isSelected ? Palette.textOnAccent : Palette.textPrimary)
            // **A capsule, and empty until chosen.** Every pill used to carry
            // a fill, so eight of them read as eight buttons all equally lit
            // and the selected one had to out-shout the rest. An outline for
            // the unchosen leaves the fill to mean one thing.
            .background(Capsule().fill(isSelected ? Palette.accent : .clear))
            .overlay(
                Capsule().strokeBorder(
                    isSelected ? .clear : Palette.separator, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(category.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
