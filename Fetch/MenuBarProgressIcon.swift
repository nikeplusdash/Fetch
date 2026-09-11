import AppKit

enum MenuBarProgressIcon {
    private static let side: CGFloat = 18

    static func image(fraction: Double?) -> NSImage {
        let image = NSImage(
            size: NSSize(width: side, height: side), flipped: false
        ) { rect in
            let centre = CGPoint(x: rect.midX, y: rect.midY)
            let radius = side / 2 - 1.4

            let track = NSBezierPath()
            track.appendArc(withCenter: centre, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = 1.6
            NSColor.labelColor.withAlphaComponent(0.28).setStroke()
            track.stroke()

            if let fraction, fraction > 0 {
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
