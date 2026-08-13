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
struct ReorderableRows<RowContent: View>: View {
    let count: Int
    /// Same shape as `.onMove`, so the call sites keep passing the handlers
    /// they already had.
    let onMove: (IndexSet, Int) -> Void
    @ViewBuilder let row: (Int) -> RowContent

    @State private var draggingIndex: Int?

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { index in
                row(index)
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
