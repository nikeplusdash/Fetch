import SwiftUI
import FetchKit

/**
 A small filled capsule carrying one word about the thing beside it.

 Two plans need this shape and would otherwise build it twice: the sheet's
 **Queued** / **Ready**, which replaces a full amber sentence at the far
 corner of the sheet from the thing it described, and Settings' **Coming
 soon**. One component, so the two cannot come to disagree about a radius.
 */
struct TagPill: View {
    enum Tone { case ready, waiting, quiet }

    let title: String
    var tone: Tone = .quiet
    var explanation: String?

    var body: some View {
        Pill(tone: pillTone, style: tone == .quiet ? .outline : .tinted) {
            Text(title)
                .font(FetchFont.tagLabel)
        }
        .accessibilityLabel(explanation ?? title)
        .help(explanation ?? title)
    }

    private var pillTone: FetchKit.Tone {
        switch tone {
        case .ready: .positive
        case .waiting: .caution
        case .quiet: .quiet
        }
    }
}
