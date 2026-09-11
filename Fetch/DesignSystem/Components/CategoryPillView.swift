import SwiftUI
import FetchKit

/**
 One category on the search bar (Figma `CategoryPill`).

 Selected uses the selection fill with `onSelection`, the same pair every
 other chosen pill in the app uses — it was the one pill painting itself
 with `Palette.accent`, so a theme that moved selection left this row
 behind. Unselected is an outline with primary text: the same symbol renders
 in both states, so it carries no state of its own. The fill/text-colour
 swap is a large luminance change, not a colour-only distinction, and the
 `.isSelected` accessibility trait carries the state for VoiceOver.
 */
struct CategoryPillView: View {
    let category: SearchCategory
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Pill(style: isSelected ? .selected : .outline, size: .large) {
                HStack(spacing: Spacing.s4) {
                    Image(systemName: category.symbolName)
                        .font(.system(size: IconSize.sm))
                    Text(category.title)
                        .font(FetchFont.footnote)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(category.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
