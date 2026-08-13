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
            .padding(.horizontal, Spacing.s8)
            .padding(.vertical, Spacing.s4)
            .foregroundStyle(isSelected ? Palette.textOnAccent : Palette.textPrimary)
            .background(
                RoundedRectangle(cornerRadius: Radius.r6)
                    .fill(isSelected ? Palette.accent : Palette.fillQuaternary))
            .contentShape(RoundedRectangle(cornerRadius: Radius.r6))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(category.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
