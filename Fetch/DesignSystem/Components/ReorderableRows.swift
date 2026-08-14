import SwiftUI
import UniformTypeIdentifiers

/// Rows the user can drag into a new order, inside a settings pane.
///
/// **Why not `.onMove`.** It is only honoured by `List`. A `Form` — grouped or
/// not — is not one, so `ForEach { … }.onMove { … }` written directly in a
/// `Form` section compiles, renders, and silently never fires. Seven lists
/// were in that state: the debrid preference order, the routing rules, and all
/// five quality-profile orderings, whose headers read "most preferred first".
///
/// **Why not a nested `List` either.** That was the first fix, and it traded
/// one defect for another: a `List` inside an already-scrolling pane needs a
/// bounded height, a bounded height has to be computed from a row height
/// nobody knows, and guessing it too large leaves dead space under the last
/// row. Every settings bug in this pass has come from guessing a measurement
/// instead of letting layout supply it.
///
/// So the rows are a plain `VStack` — it sizes to its content, with no height
/// to get wrong — and reordering is real drag and drop rather than `List`'s
/// built-in affordance.
/// **It takes the items, not a count, and this is what fixed a crash.**
///
/// It used to be `ForEach(0..<count, id: \.self)` with the row closure handed
/// an `Int`, so every call site subscripted the model array by that index.
/// SwiftUI treats a `Range<Int>` as *constant* data: it does not re-key its
/// children when the range changes, so removing the last debrid provider left a
/// child scheduled to update at index 0 of an array that now had none, and
/// `Array._checkSubscript` trapped before the view could be torn down. The same
/// was true of the routing rules, which also delete.
///
/// Guarding the subscript would have hidden it. Iterating the elements with
/// their own identity is what actually fixes it — a removed element's child is
/// torn down rather than re-evaluated — and handing the row its element means
/// no call site can write the unsafe subscript in the first place. The index is
/// still passed, because "most preferred first" lists number their rows, but
/// nothing has to look anything up with it.
struct ReorderableRows<Item, ID: Hashable, RowContent: View>: View {
    let items: [Item]
    /// What makes a row that row. Identity is the whole fix, so it is required
    /// rather than defaulted to the position.
    let id: KeyPath<Item, ID>
    /// Same shape as `.onMove`, so the call sites keep passing the handlers
    /// they already had.
    let onMove: (IndexSet, Int) -> Void
    @ViewBuilder let row: (Int, Item) -> RowContent

    @State private var draggingIndex: Int?

    /// The element, its identity and its position, resolved once.
    ///
    /// `ForEach(Array(items.enumerated()), id: \.element[keyPath: id])` is the
    /// obvious spelling and does not compile: the key path is a runtime value,
    /// so it cannot appear inside a key-path literal. Materialising the three
    /// facts into a row says the same thing and reads better at the `ForEach`.
    private struct Positioned: Identifiable {
        let id: ID
        let index: Int
        let item: Item
    }

    private var rows: [Positioned] {
        items.enumerated().map {
            Positioned(id: $0.element[keyPath: id], index: $0.offset, item: $0.element)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(rows) { positioned in
                let index = positioned.index
                row(index, positioned.item)
                    // The dragged row dims in place rather than disappearing:
                    // a gap that opens where the row *was* reads as the drop
                    // having already happened.
                    .opacity(draggingIndex == index ? 0.4 : 1)
                    .onDrag {
                        draggingIndex = index
                        return NSItemProvider(object: String(index) as NSString)
                    }
                    .onDrop(
                        of: [.plainText],
                        delegate: ReorderDrop(
                            destination: index,
                            draggingIndex: $draggingIndex,
                            onMove: onMove))
            }
        }
    }
}

extension ReorderableRows where Item: Identifiable, ID == Item.ID {
    /// The common case: the element already knows what it is.
    init(
        _ items: [Item],
        onMove: @escaping (IndexSet, Int) -> Void,
        @ViewBuilder row: @escaping (Int, Item) -> RowContent
    ) {
        self.init(items: items, id: \.id, onMove: onMove, row: row)
    }
}

/// Resolves one drop into an `onMove`.
private struct ReorderDrop: DropDelegate {
    let destination: Int
    @Binding var draggingIndex: Int?
    let onMove: (IndexSet, Int) -> Void

    func performDrop(info: DropInfo) -> Bool {
        defer { draggingIndex = nil }
        guard let source = draggingIndex, source != destination else { return false }
        // `move(fromOffsets:toOffset:)` inserts *before* the destination, so
        // dragging downwards has to target the far side of the row being
        // passed. Without the +1 a row dragged one place down lands back where
        // it started and the drag looks broken rather than rejected.
        onMove(IndexSet(integer: source), source < destination ? destination + 1 : destination)
        return true
    }

    func dropEntered(info: DropInfo) {}

    func validateDrop(info: DropInfo) -> Bool {
        draggingIndex != nil
    }

    func dropExited(info: DropInfo) {}
}
