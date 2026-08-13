import AppKit
import SwiftUI
import FetchKit

/// Shared chrome for `SearchResultRowView` and `BookResultRowView`: the
/// selection background, the row-level foreground that flips for it, the
/// double-tap-to-open gesture, and the context menu.
///
/// Extracted after Task 13's review found the child-override contrast trap
/// twice — once in `BookResultRowView`, once almost reintroduced in
/// `SearchResultRowView` — because nothing enforced that both rows' chrome
/// stayed identical. Centralising it here means a third row type (or a third
/// pass fixing the same class of bug) inherits the fix instead of having to
/// repeat it.
struct ResultRowChrome: ViewModifier {
    let isSelected: Bool
    let isListFocused: Bool
    let hasMagnet: Bool
    /// The page this result came from, when it has one.
    let sourcePage: URL?
    let onActivate: () -> Void
    let onCopyMagnet: () -> Void
    /// Bound rather than owned: `actions`-style views inside each row need
    /// the same hover state to drive their own opacity, so the source of
    /// truth lives in the row and this modifier only writes to it.
    @Binding var isHovered: Bool

    func body(content: Content) -> some View {
        content
            .foregroundStyle(isSelected && isListFocused ? Palette.textOnAccent : Palette.textPrimary)
            .padding(.vertical, Spacing.s2)
            // **No horizontal padding here.** It had 6 points of its own, and
            // that is the answer to why the column header would not line up
            // with the columns: there were two sources of horizontal inset and
            // every attempt adjusted the other one. `resultsColumnLayout()` is
            // the only place it comes from now, and the header applies the
            // very same modifier.
            .frame(minHeight: RowHeight.regular)
            .background(background)
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            // Only the double tap is handled here. Selection belongs to the
            // enclosing `List(selection:)`, which each row feeds through its
            // `.tag`.
            //
            // This used to carry a count-1 gesture as well, declared after the
            // count-2 one so SwiftUI would arbitrate between them. It does
            // arbitrate — by waiting for the double tap to *fail* before
            // firing the single — so every click paid the double-click
            // interval before the row lit up. The row was not slow to select;
            // it was waiting to find out whether the click was a double.
            //
            // A hand-rolled single-tap could never have beaten that, because
            // the arbitration is the cost. Deleting it removes the arbitration
            // entirely: `List` selects on mouse-down, and the double tap is
            // then the only gesture left to recognise.
            .onTapGesture(count: 2, perform: onActivate)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .contextMenu {
                Button("Download…", action: onActivate)
                if let page = sourcePage {
                    // The item's page, not the file's URL — opening a
                    // candidate would download the same file again in Safari.
                    // Only Archive.org and Gutenberg have one; a torrent's
                    // "source" is an indexer and its listing is not something
                    // a result carries, so those get no item rather than a
                    // guess at a tracker's URL scheme.
                    Button("Open on the Web…") { NSWorkspace.shared.open(page) }
                }
                if hasMagnet {
                    Button("Copy Magnet Link", action: onCopyMagnet)
                }
            }
    }

    @ViewBuilder
    private var background: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: Radius.r4)
                .fill(isListFocused ? Palette.bgSelected : Palette.bgSelectedInactive)
        }
    }
}

extension View {
    func resultRowChrome(
        isSelected: Bool, isListFocused: Bool, hasMagnet: Bool,
        sourcePage: URL? = nil,
        isHovered: Binding<Bool>,
        onActivate: @escaping () -> Void,
        onCopyMagnet: @escaping () -> Void
    ) -> some View {
        modifier(ResultRowChrome(
            isSelected: isSelected, isListFocused: isListFocused, hasMagnet: hasMagnet,
            sourcePage: sourcePage,
            onActivate: onActivate, onCopyMagnet: onCopyMagnet,
            isHovered: isHovered))
    }
}

/// A field that is normally muted (secondary/tertiary) but would fail
/// contrast against `Palette.bgSelected` blue. Only the focused-selected
/// case forces `textOnAccent`; selected-but-unfocused keeps the field at
/// `base`, matching the row-level foreground's own unfocused behaviour.
///
/// The trap this avoids: setting `.foregroundStyle` on a child unconditionally
/// overrides the row-level one that flips on selection, which is what left
/// `BookResultRowView`'s author/size/language/source fields low-contrast on
/// their own selected background (Task 13 review) — a single free function
/// instead of one private method per row means the fix cannot drift out of
/// sync between them again.
func mutedRowForeground(_ base: Color, isSelected: Bool, isListFocused: Bool) -> Color {
    (isSelected && isListFocused) ? Palette.textOnAccent : base
}

/// The row's hover/selection-revealed action cluster (optional Copy
/// Magnet, and Info).
///
/// There is no Download button. For a torrent-backed result it did exactly
/// what Info did — open the picker — because there is nothing to download
/// until files are chosen, so it was a second glyph for one action. Laid out whether or not it is visible — revealing
/// buttons that change the row's width would make every neighbouring row
/// jump as the pointer travels down the list — and `.accessibilityHidden`
/// exactly when it is invisible, or Tab would walk through every row's
/// hidden buttons.
///
/// `infoHelp`/`infoAccessibilityLabel` are the one part that legitimately
/// differs between row types: "Choose files…" opens a torrent's file picker,
/// "Choose format…" opens a book's format picker.
struct ResultRowActions: View {
    /// Reserved whether or not the cluster is visible, so revealing it on
    /// hover cannot shift the row's other columns — and so `ResultsHeaderView`
    /// can reserve the same gap and stay aligned with the values below it.
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
        .frame(width: Self.reservedWidth, alignment: .trailing)
        .opacity(isSelected || isHovered ? 1 : 0)
        .accessibilityHidden(!(isSelected || isHovered))
    }
}
