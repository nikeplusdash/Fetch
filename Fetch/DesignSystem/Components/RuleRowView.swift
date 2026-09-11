import SwiftUI

/**
 One routing rule in Settings § Organization (Figma `RuleRow`).

 Order is load-bearing — the first matching rule wins — so the drag handle
 is part of the row rather than an affordance that appears on hover.
 */
struct RuleRowView: View {
    static let matchColumn: CGFloat = 88
    static let arrowColumn: CGFloat = 14

    let match: String
    @Binding var destination: String
    let isDragging: Bool
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: Spacing.s8) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(Palette.textTertiary)
                .accessibilityHidden(true)

            Text(match)
                .font(FetchFont.body)
                .lineLimit(1)
                .frame(width: RuleRowView.matchColumn, alignment: .leading)

            Image(systemName: "arrow.right")
                .font(.system(size: IconSize.xs))
                .foregroundStyle(Palette.textTertiary)
                .frame(width: RuleRowView.arrowColumn)

            TextField("Subfolder", text: $destination)
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .frame(maxWidth: .infinity)

            Button(action: onDelete) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete rule \(match)")
        }
        .padding(.vertical, Spacing.s2)
        .opacity(isDragging ? 0.5 : 1)
    }
}
