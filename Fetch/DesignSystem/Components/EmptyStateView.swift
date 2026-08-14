import SwiftUI

struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: Spacing.s8) {
            Image(systemName: symbol)
                .font(.system(size: 32))
                .foregroundStyle(Palette.textTertiary)
            Text(title).font(FetchFont.title3)
            Text(message)
                .font(FetchFont.callout)
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .padding(.top, Spacing.s8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
