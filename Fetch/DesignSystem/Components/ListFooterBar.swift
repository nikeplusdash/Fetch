import SwiftUI

/// The count and size under a file list, inside the list's own border.
///
/// **It counts that list, so it belongs to it.** "1 of 6 files · 705.4 MB" used
/// to float in the footer region above the destination path, level with Cancel
/// and Download — so ticking a checkbox changed a number sitting among the
/// buttons, and the number that described the list was outside the list. Inside
/// the border it sits under the thing it counts, and nothing else in the footer
/// region moves when it changes.
struct ListFooterBar: View {
    /// What the checkboxes have done: "1 of 6 files".
    let leading: String
    /// What it comes to, or nil where the source declares no size — a
    /// Gutenberg book has none, and "0 bytes" would be a wrong number rather
    /// than an absent one.
    var trailing: String?

    var body: some View {
        HStack(spacing: Spacing.s12) {
            Text(leading)
            Spacer(minLength: Spacing.s12)
            if let trailing {
                Text(trailing)
            }
        }
        // Tabular, because both halves change as boxes are ticked and a
        // proportional digit shifts the text beside it on every tick.
        //
        // `calloutMono` rather than a mono at 11: the mocks drew this half a
        // point smaller than the facts line, and the tokens spec's whole
        // purpose is that a half-point is not a reason for a fourth entry in
        // the type scale that plans 1 and 3 have never heard of.
        .font(FetchFont.calloutMono)
        .foregroundStyle(Palette.textSecondary)
        .padding(.horizontal, WindowMetrics.sheetInset)
        .padding(.vertical, RowHeight.rowPaddingV)
        .frame(maxWidth: .infinity)
        .background(Palette.rowAlternate)
        .overlay(alignment: .top) {
            Rectangle().fill(Palette.separator).frame(height: 1)
        }
    }
}
