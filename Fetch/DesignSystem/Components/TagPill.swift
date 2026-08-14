import SwiftUI

/// A small filled capsule carrying one word about the thing beside it.
///
/// Two plans need this shape and would otherwise build it twice: the sheet's
/// **Queued** / **Ready**, which replaces a full amber sentence at the far
/// corner of the sheet from the thing it described, and Settings' **Coming
/// soon**. One component, so the two cannot come to disagree about a radius.
struct TagPill: View {
    enum Tone { case ready, waiting, quiet }

    let title: String
    var tone: Tone = .quiet
    /// Said in the tooltip. The pill is one word because one word is what the
    /// row has space for; the sentence it replaced is often still worth having
    /// somewhere, and this is somewhere.
    var explanation: String?

    var body: some View {
        Text(title)
            .font(FetchFont.tagLabel)
            .foregroundStyle(ink)
            .padding(.horizontal, Spacing.s8)
            .padding(.vertical, Spacing.s2)
            .background(Capsule().fill(bed))
            .overlay {
                if tone == .quiet {
                    Capsule().strokeBorder(Palette.separator, lineWidth: 1)
                }
            }
            .accessibilityLabel(explanation ?? title)
            .help(explanation ?? title)
    }

    private var ink: Color {
        switch tone {
        case .ready: Palette.cached
        case .waiting: Palette.attention
        case .quiet: Palette.textTertiary
        }
    }

    /// A tint of the ink, not a second colour. The bed exists to seat the word,
    /// not to be noticed on its own.
    private var bed: Color {
        switch tone {
        case .ready: Palette.cached.opacity(0.13)
        case .waiting: Palette.attention.opacity(0.14)
        case .quiet: .clear
        }
    }
}
