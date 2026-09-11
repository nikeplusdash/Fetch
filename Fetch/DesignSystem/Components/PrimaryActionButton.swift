import SwiftUI

/**
 A sheet's primary action.

 **It used to carry a chevron, and the chevron is gone.** The destination is
 a control on the facts line beside the name, and putting a second opener for
 the same menu on the button meant one choice with two doors — which reads as
 two different settings until you have opened both and found the same list.
 The header says where the download is going and changes it; the button
 starts it. One job each.
 */
struct PrimaryActionButton: View {
    let title: String
    var isBusy = false
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Text(title).opacity(isBusy ? 0 : 1)
                if isBusy {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .disabled(!isEnabled || isBusy)
    }
}
