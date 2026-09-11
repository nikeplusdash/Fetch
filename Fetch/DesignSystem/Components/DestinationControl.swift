import SwiftUI
import FetchKit

/**
 The destination, stated and changed by one control.

 The path used to be a bare grey `/Users/nikeshkumar/Downloads/Fetch` above
 the buttons: not a control, not truncated, four levels of somebody's home
 directory, and the only place the destination appeared at all. It is a
 readout **and** the button that changes it now, in the block with the name,
 which is the only place either belongs.
 */
struct DestinationReadoutButton: View {
    let readout: DestinationReadout
    var isOverridden = false
    let menu: DestinationMenuItems

    var body: some View {
        Menu {
            menu
        } label: {
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

/**
 The entries themselves: the folders the organization rules can send things
 to, then Choose location.
 */
struct DestinationMenuItems: View {
    let entries: [DestinationMenu.Entry]
    let root: URL
    let selected: DestinationMenu.Entry
    let onSelect: (DestinationMenu.Entry) -> Void

    var body: some View {
        Section("Where") {
            ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                Button {
                    onSelect(entry)
                } label: {
                    if entry == selected, entry != .choose {
                        Label(title(entry), systemImage: "checkmark")
                    } else {
                        Text(title(entry))
                    }
                }
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
