import SwiftUI
import AppKit

/// How much width a scroll view's scroller is currently taking from its
/// content, which is zero unless the user is on legacy scrollers.
///
/// **This is why the results header did not line up with its rows.** The rows
/// are in a scrolling `List` and the header is in one that is scroll-disabled;
/// with overlay scrollers those are the same width, and with legacy scrollers
/// the scrolling one is about fifteen points narrower. So Size and Source sat
/// right-aligned against two different right edges — and only for some people,
/// because macOS picks the style from the pointing device: "Automatic" means
/// overlay on a trackpad and legacy the moment a mouse is plugged in. That is
/// also why it looked intermittent.
///
/// Measured from AppKit rather than guessed: the width is a system metric and
/// the style changes at runtime, so a constant would be wrong twice.
@MainActor
@Observable
final class ScrollerInset {
    static let shared = ScrollerInset()

    private(set) var width: CGFloat = ScrollerInset.currentWidth()

    private init() {
        NotificationCenter.default.addObserver(
            forName: NSScroller.preferredScrollerStyleDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.width = ScrollerInset.currentWidth() }
        }
    }

    private static func currentWidth() -> CGFloat {
        guard NSScroller.preferredScrollerStyle == .legacy else { return 0 }
        return NSScroller.scrollerWidth(
            for: .regular, scrollerStyle: .legacy)
    }
}
