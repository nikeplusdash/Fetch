import SwiftUI
import FetchKit

/**
 The row's hover/selection-revealed action cluster (optional Copy
 Magnet, and Info).

 There is no Download button. For a torrent-backed result it did exactly
 what Info did — open the picker — because there is nothing to download
 until files are chosen, so it was a second glyph for one action. Laid out whether or not it is visible — revealing
 buttons that change the row's width would make every neighbouring row
 jump as the pointer travels down the list — and `.accessibilityHidden`
 exactly when it is invisible, or Tab would walk through every row's
 hidden buttons.

 `infoHelp`/`infoAccessibilityLabel` are the one part that legitimately
 differs between row types: "Choose files…" opens a torrent's file picker,
 "Choose format…" opens a book's format picker.
 */
struct ResultRowActions: View {
    static let reservedWidth: CGFloat = 64

    let title: String
    let isSelected: Bool
    let isHovered: Bool
    let hasMagnet: Bool
    let infoHelp: String
    let infoAccessibilityLabel: String
    let onCopyMagnet: () -> Void
    let onActivate: () -> Void

    var body: some View {
        HStack(spacing: Spacing.s4) {
            if hasMagnet {
                Button(action: onCopyMagnet) {
                    Image(systemName: "link")
                }
                .buttonStyle(.plain)
                .help("Copy magnet link")
                .accessibilityLabel("Copy magnet link for \(title)")
            }

            Button(action: onActivate) {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.plain)
            .help(infoHelp)
            .accessibilityLabel(infoAccessibilityLabel)
        }
        .font(.system(size: IconSize.md))
        .padding(.horizontal, Spacing.s6)
        .padding(.vertical, Spacing.s2)
        .background(.regularMaterial, in: Capsule())
        .contentShape(Capsule())
        .frame(width: Self.reservedWidth, alignment: .trailing)
        .opacity(isSelected || isHovered ? 1 : 0)
        .allowsHitTesting(isSelected || isHovered)
        .accessibilityHidden(!(isSelected || isHovered))
    }
}
