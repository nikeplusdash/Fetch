import SwiftUI

/// One routing rule in Settings § Organization (Figma `RuleRow`).
///
/// Order is load-bearing — the first matching rule wins — so the drag handle
/// is part of the row rather than an affordance that appears on hover.
struct RuleRowView: View {
    /// Sized for the longest `MediaKind` name — "software" — at body size.
    /// A token rather than a literal because the header-and-rows lesson from
    /// the results list applies here too: two columns that must line up
    /// should read one number, not two.
    static let matchColumn: CGFloat = 88

    let match: String
    /// Editable, not display-only: this is the same `TextField` the inline
    /// row carried before extraction, moved rather than redesigned — the
    /// destination subfolder was the one thing about a rule the user could
    /// already change from this screen.
    @Binding var destination: String
    let isDragging: Bool
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: Spacing.s8) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(Palette.textTertiary)
                .accessibilityHidden(true)

            // **Fixed, so this reads as a table.** Intrinsic width meant a
            // three-letter match and an eight-letter one pushed their arrow
            // and their field to different places, and a column of five rules
            // came out as five different layouts stacked up. Sized for the
            // longest `MediaKind` name at this font.
            Text(match)
                .font(FetchFont.body)
                .lineLimit(1)
                .frame(width: RuleRowView.matchColumn, alignment: .leading)

            Image(systemName: "arrow.right")
                .font(.system(size: IconSize.xs))
                .foregroundStyle(Palette.textTertiary)
                .frame(width: 14)

            // Takes the remaining width rather than a fixed 160, so every
            // field in the column starts *and* ends on the same two lines.
            TextField("Subfolder", text: $destination)
                .textFieldStyle(.roundedBorder)
                // Hidden, not absent. Inside a `Form` the first argument is a
                // *label*, not a placeholder, and the grouped style lays a
                // labelled control out label-above-field once the row runs
                // long — which is what put the box on its own line. The row
                // owns its layout; the field just needs to be a field.
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
        // No `accessibilityElement` grouping: `.combine` (this row's first
        // draft) collapses the subtree into one read-only element, which
        // drops the `TextField` and the delete `Button` — an interactive
        // control does not survive being merged into a combined label. The
        // pre-task inline row had no grouping either, so each child stays
        // independently reachable, matching it exactly rather than trading
        // that reachability for a summary label.
    }
}
