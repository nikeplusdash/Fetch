import SwiftUI
import FetchKit

/**
 One parsed or stated quality value (Figma `QualityChip`).

 `Emphasis` is the load-bearing part: it renders `ReleaseMetadata`'s
 provenance. A value a Torznab indexer *stated* reads `known`; one the
 release-name parser *inferred* reads `guessed`, in lower contrast with a
 dashed border. That is the same signal that gates renaming, and until now
 it has never been visible — `QualitySummary` joined every value into one
 string, losing which was which.
 */
struct QualityChipView: View {
    enum Emphasis { case known, guessed }

    let label: String
    let emphasis: Emphasis
    var isOnFill: Bool = false

    var body: some View {
        Pill(
            tone: emphasis == .known ? .plain : .muted,
            shape: .rounded,
            border: emphasis == .known ? .hairline : .dashed,
            size: .mini,
            isOnFill: isOnFill
        ) {
            Text(label)
                .font(FetchFont.caption2)
        }
        .fixedSize()
        .accessibilityLabel(
            emphasis == .known ? label : "\(label), inferred from the release name")
    }
}
