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
        // **A constant-width pair, so it can be centred without coming apart.**
        // The meter and the count are each left-aligned in a slot of their own,
        // and both slots are fixed — so the bars line up down the column and
        // the digits line up beside them, exactly as when the whole cell was
        // left-aligned. What that buys is the freedom to centre the *pair*
        // under its heading: a block of constant width has a centre that does
        // not move, whereas centring a cell whose width followed its digit
        // count is what put a two-digit meter left of a one-digit one.
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
            // Reserved whether or not there is a level to draw, so a result
            // with no seeder count does not slide its number left into the
            // meter's place.
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
