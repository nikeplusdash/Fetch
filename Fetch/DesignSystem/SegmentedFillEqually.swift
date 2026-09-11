import SwiftUI
import AppKit

extension View {
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
