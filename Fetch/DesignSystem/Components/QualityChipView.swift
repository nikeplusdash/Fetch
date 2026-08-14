import SwiftUI

/// One parsed or stated quality value (Figma `QualityChip`).
///
/// `Emphasis` is the load-bearing part: it renders `ReleaseMetadata`'s
/// provenance. A value a Torznab indexer *stated* reads `known`; one the
/// release-name parser *inferred* reads `guessed`, in lower contrast with a
/// dashed border. That is the same signal that gates renaming, and until now
/// it has never been visible — `QualitySummary` joined every value into one
/// string, losing which was which.
struct QualityChipView: View {
    enum Emphasis { case known, guessed }

    let label: String
    let emphasis: Emphasis
    /// True on a selected, focused row — `Palette.bgSelected` blue behind a
    /// translucent `fillQuaternary` chip still shows through, so
    /// `textPrimary`/`textSecondary` wash out rather than disappear, but
    /// still fail contrast. Same escape hatch as `CacheBadgeView.isOnFill`.
    var isOnFill: Bool = false

    var body: some View {
        Text(label)
            .font(FetchFont.caption2)
            .foregroundStyle(
                isOnFill ? Palette.statusOnFill
                    : (emphasis == .known ? Palette.textPrimary : Palette.textSecondary))
            .padding(.horizontal, Spacing.s6)
            .padding(.vertical, Spacing.s2)
            .background(
                RoundedRectangle(cornerRadius: Radius.r4)
                    .fill(Palette.fillQuaternary))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.r4)
                    .strokeBorder(
                        // `Palette.separator` is black at 10% — invisible
                        // over the accent-blue selection fill behind
                        // `isOnFill`. `textOnAccent` at partial opacity reads
                        // on that fill the way `separator` reads on the
                        // ordinary background, so the dashed/solid distinction
                        // this chip exists to render survives selection
                        // instead of surviving only in the accessibility label.
                        isOnFill ? Palette.textOnAccent.opacity(0.5) : Palette.separator,
                        style: StrokeStyle(
                            lineWidth: 1,
                            dash: emphasis == .guessed ? [2, 2] : [])))
            .fixedSize()
            .accessibilityLabel(
                emphasis == .known ? label : "\(label), inferred from the release name")
    }
}
