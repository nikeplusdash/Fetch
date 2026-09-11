import SwiftUI

/**
 The app's navigation: three destinations, drawn directly rather than by a
 `List` inside a `NavigationSplitView`.

 **Why not a `List`.** The split view wrapped its content in a rounded glass
 surface inset from the window frame, so the sidebar read as a card lying on
 the window instead of as part of it, and the sidebar list style added a
 second inset panel of its own inside that. Both are chrome the app never
 asked for and neither could be turned off. Three fixed destinations need
 none of what a `List` provides — no diffing, no reordering, no scrolling —
 so the column is a stack, and the corner it sits in is the window's own.

 Selection, hover and keyboard access are the parts a `List` *was* giving us
 for free, so they are spelled out here instead: the ⌘-number shortcuts are
 the standard macOS way to reach a fixed set of tabs, and read better on
 three items than arrow keys through a focus ring.
 */
struct SidebarColumn: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
        .environment(\.isTableFocused, true)
        .frame(width: WindowMetrics.sidebarWidth)
        .frame(maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sections")
    }
}

private struct SidebarItem: View {
    let section: SidebarSection
    let isSelected: Bool
    let shortcut: KeyEquivalent
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.s8) {
                Image(systemName: section.symbolName)
                    .font(.system(size: IconSize.md))
                    .frame(width: WindowMetrics.sidebarGlyphWidth)
                Text(section.title)
                    .font(FetchFont.body)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.s8)
            .frame(height: WindowMetrics.sidebarRowHeight)
        }
        .buttonStyle(.plain)
        .selectableRow(isSelected: isSelected, shape: .sidebar, onSelect: action)
        .padding(.vertical, Spacing.s2)
        .keyboardShortcut(shortcut, modifiers: .command)
        .accessibilityLabel(section.title)
        .accessibilityAddTraits(.isButton)
    }
}
