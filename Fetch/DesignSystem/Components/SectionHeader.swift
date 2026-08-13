import SwiftUI

struct SectionHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack {
            Text(title).font(FetchFont.headline).lineLimit(1)
            Text("\(count)")
                .font(FetchFont.calloutMono)
                .foregroundStyle(Palette.textSecondary)
            Spacer()
        }
        .padding(.horizontal, Spacing.s12)
        // Fixed rather than padding-driven: a title long enough to wrap
        // would otherwise grow this section's header taller than its
        // neighbours', and every section jitters as the list scrolls past it.
        .frame(height: RowHeight.regular)
    }
}
