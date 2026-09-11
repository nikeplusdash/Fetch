import SwiftUI
import FetchKit

/**
 One checkable facet value and how many results choosing it would leave
 (Figma `FacetRow`).

 The count is what makes the sidebar trustworthy: it is computed against
 every *other* active facet but not its own, so a facet never offers an
 option that would return nothing and never becomes a one-way door.
 */
struct FacetRowView: View {
    let label: String
    let count: Int
    let isChecked: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.s6) {
                Checkbox(state: isChecked ? .on : .off, size: IconSize.md, onToggle: action)
                    .allowsHitTesting(false)
                Text(label)
                    .font(FetchFont.callout)
                    .lineLimit(1)
                Spacer()
                Text("\(count)")
                    .font(FetchFont.footnoteMono)
                    .foregroundStyle(Palette.textTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label), \(count) results")
        .accessibilityAddTraits(isChecked ? [.isButton, .isSelected] : .isButton)
    }
}
