import SwiftUI

/**
 A download's progress bar (Figma `ProgressTrack`).

 `nil` is indeterminate, not "no progress yet" — a download can be
 preparing with no fraction knowable yet, which is a different state from
 zero. That branch is left as the system's own linear indicator, unstyled:
 there is no "unfilled portion" to recolour when the fraction itself is
 unknown.
 */
struct ProgressTrack: View {
    let fraction: Double?

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

private struct FillTrackProgressStyle: ProgressViewStyle {
    private static let cornerRadius: CGFloat = 2
    private static let trackHeight: CGFloat = 4

    func makeBody(configuration: Configuration) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: Self.cornerRadius)
                    .fill(Palette.fillTrack)
                RoundedRectangle(cornerRadius: Self.cornerRadius)
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
