import SwiftUI

/**
 The count and size under a file list, inside the list's own border.

 **It counts that list, so it belongs to it.** "1 of 6 files · 705.4 MB" used
 to float in the footer region above the destination path, level with Cancel
 and Download — so ticking a checkbox changed a number sitting among the
 buttons, and the number that described the list was outside the list. Inside
 the border it sits under the thing it counts, and nothing else in the footer
 region moves when it changes.
 */
struct ListFooterBar: View {
    let leading: String
    var trailing: String?

    var body: some View {
        HStack(spacing: Spacing.s12) {
            Text(leading)
            Spacer(minLength: Spacing.s12)
            if let trailing {
                Text(trailing)
            }
        }
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
