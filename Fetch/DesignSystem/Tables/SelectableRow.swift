import SwiftUI

/**
 What a row currently looks like, published to everything inside it.

 `isOnFill` is the question every cell used to be asked by parameter — 21 of
 them, plus a free function seven rows called by hand — and getting it wrong
 left muted text sitting illegibly on a selected row's fill.
 */
struct RowVisualState: Equatable {
    var isSelected = false
    var isFocused = false
    var isHovered = false

    var isOnFill: Bool { isSelected && isFocused }
}

extension RowVisualState {
    /**
     A normally-muted field's colour, lifted to legible ink when the row is
     painted with the selection fill. Setting a child's `foregroundStyle`
     unconditionally overrides the row-level one that flips on selection,
     which is what left a book row's author, size and language unreadable on
     their own selected background; this is the one place that decides.
     */
    func ink(_ base: Color) -> Color {
        isOnFill ? Palette.textOnSelectedRow : base
    }
}

extension EnvironmentValues {
    @Entry var rowState = RowVisualState()
    @Entry var isTableFocused = false
}

enum RowShape {
    case list, sidebar

    var radius: CGFloat {
        switch self {
        case .list: Radius.r4
        case .sidebar: Radius.r8
        }
    }
}

/**
 The one painter of a selected, hovered or focus-lost row.

 Four painters used to share this job — a custom fill on search rows, another
 on the sidebar, AppKit's own highlight under the downloads list, and a
 capsule on the pills — which is why selection looked like a different app on
 each screen. A row says whether it is selected; this decides what that looks
 like, and publishes the answer through `\.rowState` so its cells can pick a
 legible ink without being handed a flag.
 */
struct SelectableRow: ViewModifier {
    let isSelected: Bool
    var shape: RowShape = .list
    let onSelect: () -> Void
    var onActivate: (() -> Void)?

    @Environment(\.isTableFocused) private var isTableFocused
    @Environment(\.controlActiveState) private var controlActive
    @State private var isHovered = false

    func body(content: Content) -> some View {
        let focused = isTableFocused && controlActive == .key
        content
            .environment(\.rowState, RowVisualState(
                isSelected: isSelected, isFocused: focused, isHovered: isHovered))
            .foregroundStyle(isSelected && focused ? Palette.textOnSelectedRow : Palette.textPrimary)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: shape.radius)
                        .fill(focused ? Palette.bgSelected : Palette.bgSelectedInactive)
                } else if isHovered {
                    RoundedRectangle(cornerRadius: shape.radius)
                        .fill(Palette.fillQuaternary)
                }
            }
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .simultaneousGesture(TapGesture(count: 2).onEnded { onActivate?() })
            .simultaneousGesture(TapGesture(count: 1).onEnded(onSelect))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

extension View {
    func selectableRow(isSelected: Bool, shape: RowShape = .list,
                       onSelect: @escaping () -> Void,
                       onActivate: (() -> Void)? = nil) -> some View {
        modifier(SelectableRow(isSelected: isSelected, shape: shape,
                               onSelect: onSelect, onActivate: onActivate))
    }
}
