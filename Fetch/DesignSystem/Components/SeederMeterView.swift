import SwiftUI
import FetchKit

/**
 Swarm health as a four-bar ramp plus the exact count (Figma `SeederMeter`).

 The ramp is the signal and the colour is reinforcement: `filledBars`
 encodes the level geometrically, so the meter still reads at a glance
 without colour vision. An unknown count renders an em dash — a source that
 did not say is not a source that said zero.
 */
struct SeederMeterView: View {
    let seeders: Int?
    var isOnFill: Bool = false

    private var level: SeederLevel? { SeederLevel(seeders: seeders) }


    var body: some View {
        HStack(spacing: Spacing.s4) {
            HStack(alignment: .bottom, spacing: 1) {
                if let level {
                    ForEach(0..<4, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 0.5)
                            .fill(index < level.filledBars ? tint(level) : Palette.fillTrack)
                            .frame(width: 2, height: 3 + CGFloat(index) * 2.5)
                    }
                }
            }
            .frame(width: SeederMeter.barsWidth, height: IconSize.sm, alignment: .bottomLeading)

            Text(seeders.map(String.init) ?? "—")
                .font(FetchFont.calloutMono)
                .foregroundStyle(isOnFill ? Palette.statusOnFill : Palette.textSecondary)
                .lineLimit(1)
                .frame(width: SeederMeter.countWidth, alignment: .leading)
        }
        .frame(width: SeederMeter.width)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        guard let seeders, let level else { return "seeder count unknown" }
        return "\(seeders) seeders, \(level.accessibilityDescription)"
    }

    private func tint(_ level: SeederLevel) -> Color {
        if isOnFill { return Palette.statusOnFill }
        return switch level {
        case .high, .medium: Palette.cached
        case .low: Palette.attention
        case .dead: Palette.miss
        }
    }
}
