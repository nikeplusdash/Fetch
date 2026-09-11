import SwiftUI

/**
 A single line of text that truncates like any other — until the row it sits
 in is selected, when it slides sideways to show the rest and slides back.

 **Why a component and not a modifier at three call sites.** Three lists show
 long names in a fixed column (search results, book results, downloads), and
 all three had exactly one answer for a name that did not fit: middle
 truncation and a tooltip. A tooltip is a good fallback and a poor primary —
 it costs a hover, a delay, and knowing it is there at all.

 **It cannot change the row's width.** `ColumnWidth`'s fixed columns exist
 because an unconstrained `Text` reflows a whole row as its neighbours'
 numbers change, ten times a second during a download. So the scrolling
 version is laid out at its intrinsic width *inside* a flexible frame and
 clipped: the row sees the same flexible box whether or not anything is
 moving.

 **It degrades to exactly the old behaviour.** If the measurement comes back
 empty — a text that has not been laid out yet, a platform that lays
 backgrounds out differently than expected — `overflow` is zero, nothing
 scrolls, and what renders is the middle-truncated `Text` this replaced.
 */
struct RevealingText: View {
    let text: String
    let isRevealing: Bool
    var font: Font = FetchFont.body

    private static let speed: CGFloat = 22
    private static let dwell: TimeInterval = 1.2

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var textWidth: CGFloat = 0
    @State private var visibleWidth: CGFloat = 0

    private var overflow: CGFloat { max(0, textWidth - visibleWidth) }

    private var isScrolling: Bool { isRevealing && overflow > 1 && !reduceMotion }

    private var travel: TimeInterval { max(0.3, TimeInterval(overflow / Self.speed)) }

    var body: some View {
        staticLabel
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(isScrolling ? 0 : 1)
            .overlay(alignment: .leading) {
                if isScrolling {
                    scrollingLabel
                        .frame(width: visibleWidth, alignment: .leading)
                        .clipped()
                }
            }
            .clipped()
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: VisibleWidthKey.self, value: proxy.size.width)
                }
                .allowsHitTesting(false)
            }
            .background(alignment: .leading) {
                measuringLabel.allowsHitTesting(false)
            }
            .onPreferenceChange(VisibleWidthKey.self) { visibleWidth = $0 }
            .onPreferenceChange(TextWidthKey.self) { textWidth = $0 }
            .allowsHitTesting(false)
            .accessibilityLabel(text)
    }

    private var staticLabel: some View {
        Text(text)
            .font(font)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private var scrollingLabel: some View {
        KeyframeAnimator(initialValue: CGFloat.zero, repeating: true) { offset in
            label.offset(x: offset)
        } keyframes: { _ in
            KeyframeTrack {
                LinearKeyframe(0, duration: Self.dwell)
                LinearKeyframe(-overflow, duration: travel)
                LinearKeyframe(-overflow, duration: Self.dwell)
                LinearKeyframe(0, duration: 0.001)
            }
        }
        .allowsHitTesting(false)
    }

    private var label: some View {
        Text(text)
            .font(font)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var measuringLabel: some View {
        label
            .hidden()
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: TextWidthKey.self, value: proxy.size.width)
                }
            }
    }
}

private struct TextWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct VisibleWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
