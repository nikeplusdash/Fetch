import SwiftUI
import FetchKit

/// Swarm health as a four-bar ramp plus the exact count (Figma `SeederMeter`).
///
/// The ramp is the signal and the colour is reinforcement: `filledBars`
/// encodes the level geometrically, so the meter still reads at a glance
/// without colour vision. An unknown count renders an em dash — a source that
/// did not say is not a source that said zero.
struct SeederMeterView: View {
    let seeders: Int?
    /// True on a selected, focused row. `Palette.cached`/`attention`/`miss`
    /// bars and the count text sit directly on `Palette.bgSelected` blue with
    /// no background of their own — the exact pairing `CacheBadgeView` grew
    /// `isOnFill` to escape. The bar heights still carry the level once
    /// colour collapses to one tint, same as `CacheBadgeView`'s distinct
    /// glyphs carry its states.
    var isOnFill: Bool = false

    private var level: SeederLevel? { SeederLevel(seeders: seeders) }

    var body: some View {
        HStack(spacing: Spacing.s4) {
            if let level {
                HStack(alignment: .bottom, spacing: 1) {
                    ForEach(0..<4, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 0.5)
                            .fill(index < level.filledBars ? tint(level) : Palette.fillTrack)
                            .frame(width: 2, height: 3 + CGFloat(index) * 2.5)
                    }
                }
                .frame(height: IconSize.sm, alignment: .bottom)
            }
            Text(seeders.map(String.init) ?? "—")
                .font(FetchFont.calloutMono)
                .foregroundStyle(isOnFill ? Palette.statusOnFill : Palette.textSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        guard let seeders, let level else { return "seeder count unknown" }
        return "\(seeders) seeders, \(level.accessibilityDescription)"
    }

    /// A dead torrent is worth surfacing loudly — it will never complete,
    /// however good the release is.
    private func tint(_ level: SeederLevel) -> Color {
        if isOnFill { return Palette.statusOnFill }
        return switch level {
        case .high, .medium: Palette.cached
        case .low: Palette.attention
        case .dead: Palette.miss
        }
    }
}
