import SwiftUI

/// A configured service in Settings (Figma `ProviderCard`).
///
/// `Status` is stated rather than inferred: the three debrid services are not
/// equivalent — Real-Debrid cannot report cache status at all — and the card is
/// where that is said, rather than left to be discovered as a missing badge
/// column.
struct ProviderCardView<Trailing: View>: View {
    enum Status { case untested, ok, failed }

    let title: String
    let detail: String?
    let status: Status
    @Binding var isEnabled: Bool
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: Spacing.s8) {
            Toggle("", isOn: $isEnabled)
                .labelsHidden()
                .accessibilityLabel("Enable \(title)")

            Image(systemName: symbol)
                .foregroundStyle(tint)
                .accessibilityLabel(statusDescription)

            VStack(alignment: .leading, spacing: Spacing.s2) {
                Text(title).font(FetchFont.body)
                if let detail {
                    Text(detail)
                        .font(FetchFont.footnote)
                        .foregroundStyle(Palette.textSecondary)
                }
            }

            Spacer()
            trailing()
        }
        .padding(.vertical, Spacing.s4)
    }

    private var symbol: String {
        switch status {
        case .untested: "circle.dashed"
        case .ok: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch status {
        case .untested: Palette.unknown
        case .ok: Palette.cached
        case .failed: Palette.attention
        }
    }

    private var statusDescription: String {
        switch status {
        case .untested: "not yet tested"
        case .ok: "working"
        case .failed: "not working"
        }
    }
}
