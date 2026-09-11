import SwiftUI

/**
 The one chevron.

 Four of these existed, two drawn leading and two trailing, each with its own
 glyph size and its own idea of how much room to leave. It reserves its gutter
 whether or not the row can open, so a list of expandable and plain rows keeps
 every name on the same x — the alignment a sibling row elsewhere in the app
 used to fake by drawing an invisible copy of a grip at zero opacity.
 */
struct DisclosureChevron: View {
    let isExpanded: Bool
    var isExpandable: Bool = true
    let onToggle: () -> Void

    var body: some View {
        Group {
            if isExpandable {
                Button(action: onToggle) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: IconSize.xs, weight: .bold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "Hide files" : "Show files")
            } else {
                Color.clear
            }
        }
        .frame(width: IconSize.sm)
    }
}
