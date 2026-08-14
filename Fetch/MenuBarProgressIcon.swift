import AppKit

/// The menu bar icon: a small download arrow inside a ring that fills as the
/// transfers do.
///
/// **Drawn as bezier paths, not from an SF Symbol.** The first version drew
/// `arrow.down` into the image and recoloured it with `.sourceAtop`, which
/// composited into a dark filled disc with the arrow knocked out of it — the
/// opposite of the intent, and unrecognisable at 18 points. Two shapes and a
/// stroke have no rendering behaviour to be surprised by.
///
/// **Not a template image.** A menu bar label is normally flattened to one
/// colour that follows the menu bar's appearance, and a flattened ring has no
/// green in it. Opting out means owning both colours, which is why everything
/// monochrome is drawn in `labelColor` — the one colour that already tracks a
/// light or dark menu bar.
enum MenuBarProgressIcon {
    /// The menu bar's own metric. Larger is clipped; smaller floats.
    private static let side: CGFloat = 18

    static func image(fraction: Double?) -> NSImage {
        let image = NSImage(
            size: NSSize(width: side, height: side), flipped: false
        ) { rect in
            let centre = CGPoint(x: rect.midX, y: rect.midY)
            let radius = side / 2 - 1.4

            // The track is always there, so the icon does not change shape
            // when a download starts — only fill. An icon that grows a ring
            // draws the eye far more than one that fills a ring it already had.
            let track = NSBezierPath()
            track.appendArc(withCenter: centre, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = 1.6
            NSColor.labelColor.withAlphaComponent(0.28).setStroke()
            track.stroke()

            if let fraction, fraction > 0 {
                // Clockwise from twelve, as every progress ring on this
                // platform reads. A floor of 4% so the first moments of a
                // download are a visible arc rather than a speck that looks
                // like a rendering fault.
                let swept = max(fraction, 0.04) * 360
                let arc = NSBezierPath()
                arc.appendArc(
                    withCenter: centre, radius: radius,
                    startAngle: 90, endAngle: 90 - swept, clockwise: true)
                arc.lineWidth = 1.8
                arc.lineCapStyle = .round
                NSColor.systemGreen.setStroke()
                arc.stroke()
            }

            // A downward arrow: one stem, two strokes for the head. Sized to
            // clear the ring rather than touch it.
            let stemTop = centre.y + 4.2
            let stemBottom = centre.y - 3.4
            let stem = NSBezierPath()
            stem.move(to: CGPoint(x: centre.x, y: stemTop))
            stem.line(to: CGPoint(x: centre.x, y: stemBottom))
            stem.lineWidth = 1.7
            stem.lineCapStyle = .round

            let head = NSBezierPath()
            head.move(to: CGPoint(x: centre.x - 2.9, y: centre.y - 0.6))
            head.line(to: CGPoint(x: centre.x, y: stemBottom))
            head.line(to: CGPoint(x: centre.x + 2.9, y: centre.y - 0.6))
            head.lineWidth = 1.7
            head.lineCapStyle = .round
            head.lineJoinStyle = .round

            NSColor.labelColor.setStroke()
            stem.stroke()
            head.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }
}
