import SwiftUI

/// The app's navigation: three destinations, drawn directly rather than by a
/// `List` inside a `NavigationSplitView`.
///
/// **Why not a `List`.** The split view wrapped its content in a rounded glass
/// surface inset from the window frame, so the sidebar read as a card lying on
/// the window instead of as part of it, and the sidebar list style added a
/// second inset panel of its own inside that. Both are chrome the app never
/// asked for and neither could be turned off. Three fixed destinations need
/// none of what a `List` provides — no diffing, no reordering, no scrolling —
/// so the column is a stack, and the corner it sits in is the window's own.
///
/// Selection, hover and keyboard access are the parts a `List` *was* giving us
/// for free, so they are spelled out here instead: the ⌘-number shortcuts are
/// the standard macOS way to reach a fixed set of tabs, and read better on
/// three items than arrow keys through a focus ring.
struct SidebarColumn: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The traffic lights' strip, at exactly the height the detail
            // column's `ScreenTitleBar` occupies — including the gap it leaves
            // under itself. Read from that type rather than re-summed here, so
            // the first destination and the first control across the divider
            // cannot end up on two lines again.
            Color.clear.frame(height: ScreenTitleBar.height)

            VStack(alignment: .leading, spacing: Spacing.s2) {
                ForEach(Array(SidebarSection.allCases.enumerated()), id: \.element) { index, section in
                    SidebarItem(
                        section: section,
                        isSelected: model.sidebarSection == section,
                        shortcut: KeyEquivalent(Character("\(index + 1)"))
                    ) {
                        model.sidebarSection = section
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, WindowMetrics.trafficLightInset)
        .frame(width: WindowMetrics.sidebarWidth)
        .frame(maxHeight: .infinity)
        // Nothing painted here. The frost is the window's, once, and a
        // material on this column would stack a second one on top of it.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sections")
    }
}

/// One destination. An inset rounded pill rather than a full-bleed bar: the
/// row is a target inside the column, not a stripe across it.
private struct SidebarItem: View {
    let section: SidebarSection
    let isSelected: Bool
    let shortcut: KeyEquivalent
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.s8) {
                Image(systemName: section.symbolName)
                    .font(.system(size: IconSize.md))
                    // Reserved, so a wide glyph does not shift the label of
                    // one row out of line with the two beside it.
                    .frame(width: 18)
                Text(section.title)
                    .font(FetchFont.body)
                    // A destination's name is not prose. If the column is ever
                    // too narrow for it, it should say so by truncating rather
                    // than by folding "Downloads" onto two lines and pushing
                    // the row below it out of rhythm.
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.s8)
            // A stated height rather than whatever the padding came to, so the
            // band this row centres in is the same number the detail column
            // uses. See `WindowMetrics.sidebarRowHeight`.
            .frame(height: WindowMetrics.sidebarRowHeight)
            .foregroundStyle(isSelected ? Palette.textOnAccent : Palette.textPrimary)
            .background(
                RoundedRectangle(cornerRadius: Radius.r8)
                    .fill(fill))
            .contentShape(RoundedRectangle(cornerRadius: Radius.r8))
        }
        .padding(.vertical, Spacing.s2)
        .buttonStyle(.plain)
        .keyboardShortcut(shortcut, modifiers: .command)
        .onHover { isHovering = $0 }
        .accessibilityLabel(section.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// Hover is deliberately quieter than selection: it says a row is a
    /// target, not that it is the one you are on.
    private var fill: Color {
        if isSelected { return Palette.bgSelected }
        return isHovering ? Palette.fillQuaternary : .clear
    }
}
