import SwiftUI
import FetchKit

/**
 The one checkbox. Draws `mixed` for a folder whose files are partly chosen
 — the state the picker had no glyph for, so it drew an empty box and said
 something untrue about the folder.
 */
struct Checkbox: View {
    let state: CheckState
    var size: CGFloat = IconSize.lg
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .foregroundStyle(state == .off ? Palette.textTertiary : Palette.accent)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(state == .on ? .isSelected : [])
    }

    private var symbol: String {
        switch state {
        case .on: "checkmark.square.fill"
        case .mixed: "minus.square.fill"
        case .off: "square"
        }
    }

    private var label: String {
        switch state {
        case .on: "Selected"
        case .mixed: "Partly selected"
        case .off: "Not selected"
        }
    }
}
