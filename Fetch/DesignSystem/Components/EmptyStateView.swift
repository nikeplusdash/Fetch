import SwiftUI

enum EmptyStateSize {
    case full, inline

    var glyph: CGFloat {
        switch self {
        case .full: IconSize.xxl
        case .inline: IconSize.xl
        }
    }

    var titleFont: Font {
        switch self {
        case .full: FetchFont.title3
        case .inline: FetchFont.body
        }
    }

    var messageFont: Font {
        switch self {
        case .full: FetchFont.callout
        case .inline: FetchFont.footnote
        }
    }

    var inset: CGFloat {
        switch self {
        case .full: 0
        case .inline: Spacing.s24
        }
    }
}

/**
 The one way a screen, a sheet or a column says it has nothing to show.

 **Seven hand-rolled copies of this stack** — a searching spinner, a filter
 column with no facets, three sheet errors and two sheet dead-ends — each
 picked their own glyph size, their own spacing and their own button style,
 so the same "nothing here" read as a different app on every surface. What
 actually varies is scale, and that is the one knob: `full` for a screen or a
 sheet's whole body, `inline` for a column or a strip inside one.

 A title is optional because an error message is often the whole sentence;
 `progress` swaps the glyph for a spinner, which is the only difference
 between "nothing yet" and "not yet".
 */
struct EmptyStateView: View {
    var symbol: String? = nil
    var progress = false
    var title: String? = nil
    let message: String
    var tint: Color = Palette.textTertiary
    var size: EmptyStateSize = .full
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: Spacing.s8) {
            if progress {
                ProgressView()
            } else if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: size.glyph))
                    .foregroundStyle(tint)
            }
            if let title {
                Text(title).font(size.titleFont)
            }
            Text(message)
                .font(size.messageFont)
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, Spacing.s8)
            }
        }
        .padding(.horizontal, size.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
