import SwiftUI

/// A download's progress bar (Figma `ProgressTrack`).
///
/// `nil` is indeterminate, not "no progress yet" — a download can be
/// preparing with no fraction knowable yet, which is a different state from
/// zero. That branch is left as the system's own linear indicator, unstyled:
/// there is no "unfilled portion" to recolour when the fraction itself is
/// unknown.
struct ProgressTrack: View {
    let fraction: Double?      // nil = indeterminate

    var body: some View {
        if let fraction {
            ProgressView(value: min(max(fraction, 0), 1))
                .progressViewStyle(FillTrackProgressStyle())
        } else {
            ProgressView()
                .progressViewStyle(.linear)
                .controlSize(.small)
        }
    }
}

/// Draws the unfilled portion in `Palette.fillTrack` rather than the
/// system default, which on a row background reads as barely-there and
/// stops registering as "there is more to go". Everything else about the
/// bar matches what the plain `ProgressView(value:)` this replaces would
/// have drawn.
private struct FillTrackProgressStyle: ProgressViewStyle {
    /// Not a full `Capsule`: the system's small linear indicator draws a
    /// subtly rounded rectangular track, not a pill. AppKit doesn't expose
    /// its exact corner radius, so reverting to *literally* the system
    /// shape isn't available from inside a custom `ProgressViewStyle` —
    /// this is the closest practical approximation, not a redesign.
    private static let cornerRadius: CGFloat = 2
    /// Matches `.controlSize(.small)`'s linear track thickness. Not pulled
    /// from `Dimension.swift`: nothing else in the design system measures a
    /// progress-bar thickness, and this is the only place that would read
    /// such a token — adding a one-consumer case would be clutter, not
    /// reuse.
    private static let trackHeight: CGFloat = 4

    func makeBody(configuration: Configuration) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: Self.cornerRadius)
                    .fill(Palette.fillTrack)
                RoundedRectangle(cornerRadius: Self.cornerRadius)
                    // `.tint`, not `Palette.accent`: this must resolve
                    // whatever tint is active in the environment at the call
                    // site — the same thing a bare, unstyled `ProgressView`
                    // reads — rather than a fixed colour that would ignore a
                    // local `.tint()` override further up the view tree.
                    .fill(.tint)
                    .frame(width: geo.size.width * (configuration.fractionCompleted ?? 0))
            }
        }
        .frame(height: Self.trackHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int((configuration.fractionCompleted ?? 0) * 100))%")
    }
}
