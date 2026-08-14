import SwiftUI
import FetchKit

/// The destination, stated and changed by one control.
///
/// The path used to be a bare grey `/Users/nikeshkumar/Downloads/Fetch` above
/// the buttons: not a control, not truncated, four levels of somebody's home
/// directory, and the only place the destination appeared at all. It is a
/// readout **and** the button that changes it now, in the block with the name,
/// which is the only place either belongs.
struct DestinationReadoutButton: View {
    let readout: DestinationReadout
    /// True when this is not where the rules would have sent it. The one signal
    /// needed that this download is off the rails on purpose.
    var isOverridden = false
    let menu: DestinationMenuItems

    var body: some View {
        Menu {
            menu
        } label: {
            // **The category, and nothing else.** This showed the path with
            // the folder on the end of it, in two weights, and the folder kept
            // losing: layout priorities were meant to stop the prefix winning
            // the width and it still rendered as "Downloads/Fetch/" with the
            // one word the reader needs squeezed to nothing.
            //
            // Two halves competing for one line is the problem, so there is one
            // half now. The menu this opens lists categories by name — Movies,
            // Music, Other — so the control that opens it should say the same
            // word rather than a path ending in it, and the two finally agree
            // about what a destination is called. The full path is the tooltip,
            // which is where a thing you rarely need but sometimes want belongs.
            Text(readout.leaf)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
                .font(FetchFont.callout)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(isOverridden
              ? "\(readout.full). The organization rules would have sent it "
                + "somewhere else."
              : "\(readout.full), chosen by the organization rules.")
    }
}

/// The entries themselves: the folders the organization rules can send things
/// to, then Choose location.
struct DestinationMenuItems: View {
    let entries: [DestinationMenu.Entry]
    let root: URL
    /// Which entry is in force. Compared rather than held as an index, so a
    /// menu rebuilt after the rules change still ticks the right row.
    let selected: DestinationMenu.Entry
    let onSelect: (DestinationMenu.Entry) -> Void

    var body: some View {
        // Titled, because a bare list of folders hanging off a chevron does not
        // say what choosing one of them does.
        Section("Where") {
            ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                Button {
                    onSelect(entry)
                } label: {
                    // Choose never carries the tick: it is a verb, not a place,
                    // and it is never the destination in force.
                    if entry == selected, entry != .choose {
                        Label(title(entry), systemImage: "checkmark")
                    } else {
                        Text(title(entry))
                    }
                }
                // Between the places and the verb that opens a file dialog.
                //
                // **The one `Divider()` left in plan 2's files, deliberately.**
                // Inside a `Menu` this becomes an `NSMenuItem.separator`, drawn
                // by the menu itself on a surface no theme owns. A themed
                // rectangle here would be a one-point view *item* in the menu
                // rather than a separator between two.
                if index == entries.count - 2 {
                    Divider()
                }
            }
        }
    }

    private func title(_ entry: DestinationMenu.Entry) -> String {
        DestinationMenu.title(for: entry, root: root)
    }
}
