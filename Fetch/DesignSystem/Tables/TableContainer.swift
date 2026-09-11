import SwiftUI
import FetchKit

/**
 A table's scroll view, focus and keyboard.

 Not a `List`. The native one paints its own selection under the themed fill,
 hoists a row's context menu to the whole row — which is why an expanded
 torrent's files could not have menus of their own without tracking the
 pointer by hand — and cannot share an inset with a header that lives outside
 it. Owning the scroll view costs the arrow keys, which `RowSelection` and
 `RowInteraction` already answer.

 Width is measured once here and handed to the header and the rows, so every
 column in the table agrees about how much room there is.
 */
struct TableContainer<ID: Hashable & Sendable, Header: View, Rows: View>: View {
    let ids: [ID]
    let policy: RowInteractionPolicy
    @Binding var selection: RowSelection<ID>
    var onSideArrow: ((RowEffect<ID>) -> Void)?
    var onActivate: ((ID) -> Void)?
    @ViewBuilder let header: (CGFloat) -> Header
    @ViewBuilder let rows: (CGFloat) -> Rows

    @State private var width: CGFloat = 0
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header(width)
            ThemedDivider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) { rows(width) }
                }
                .onKeyPress(.upArrow) { move(.up, proxy) }
                .onKeyPress(.downArrow) { move(.down, proxy) }
                .onKeyPress(.leftArrow) { side(.leftArrow) }
                .onKeyPress(.rightArrow) { side(.rightArrow) }
                .onKeyPress(.return) { activate() }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .environment(\.isTableFocused, isFocused)
    }

    private func move(_ direction: ListCursor.Direction, _ proxy: ScrollViewProxy) -> KeyPress.Result {
        guard let target = selection.move(direction, in: ids) else { return .ignored }
        proxy.scrollTo(target, anchor: .center)
        return .handled
    }

    private func side(_ gesture: RowGesture<ID>) -> KeyPress.Result {
        let effects = RowInteraction.effects(for: gesture, policy: policy)
        guard let effect = effects.first, let onSideArrow else { return .ignored }
        onSideArrow(effect)
        return .handled
    }

    private func activate() -> KeyPress.Result {
        guard let id = selection.selected, let onActivate else { return .ignored }
        onActivate(id)
        return .handled
    }
}
