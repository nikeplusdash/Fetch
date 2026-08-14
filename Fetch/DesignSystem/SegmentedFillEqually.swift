import SwiftUI
import AppKit

/// SwiftUI's segmented `Picker` stretches to whatever frame you give it, but
/// the `NSSegmentedControl` backing it keeps its default `.fit` distribution
/// — segments stay content-sized, so a `.frame(maxWidth: .infinity)` picker
/// just leaves the extra width as a gap after the last segment. There is no
/// SwiftUI-level modifier for `segmentDistribution`, so this reaches into
/// AppKit for it.
extension View {
    /// Makes a `.pickerStyle(.segmented)` picker's segments share its full
    /// width equally, instead of sizing to their own content.
    func segmentedFillsEqually() -> some View {
        background(SegmentDistributionFix())
    }
}

private struct SegmentDistributionFix: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let probe = NSView(frame: .zero)
        DispatchQueue.main.async { apply(near: probe) }
        return probe
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { apply(near: nsView) }
    }

    /// Walks up from the probe (planted via `.background`, so it shares the
    /// segmented control's immediate container) and searches each ancestor's
    /// subtree, stopping at the first match — the nearest one, not every
    /// segmented control in the window.
    private func apply(near probe: NSView) {
        var ancestor = probe.superview
        while let current = ancestor {
            if let segmented = firstSegmentedControl(in: current) {
                segmented.segmentDistribution = .fillEqually
                return
            }
            ancestor = current.superview
        }
    }

    private func firstSegmentedControl(in view: NSView) -> NSSegmentedControl? {
        if let segmented = view as? NSSegmentedControl { return segmented }
        for subview in view.subviews {
            if let found = firstSegmentedControl(in: subview) { return found }
        }
        return nil
    }
}
