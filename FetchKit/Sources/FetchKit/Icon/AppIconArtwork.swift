import CoreGraphics
import CoreImage
import Foundation

/**
 Fetch's app icon, drawn rather than exported.

 **Why it is code.** macOS ships no dependable SVG rasteriser on the command
 line — `qlmanage` produces nothing and `sips` does not read SVG — so the
 asset catalogue is rendered from this. Keeping it here rather than in a
 throwaway script is what lets the running app draw the same sky with its
 clouds moved along, which a PNG cannot do.

 The geometry is the v4 mark from `design/icon`, in the same 1024 space.
 Keep the two in step by hand.

 **Verify changes through `NSWorkspace.icon(forFile:)`, not by opening the
 PNG.** macOS 26 re-masks the art, applies its own material and lights it;
 the file on disk and the icon on screen are not the same image. That is
 also why the art is edge to edge and draws no rounded rectangle of its own
 — the silhouette is the system's to decide.
 */
public enum AppIconArtwork {


    static let glassFill = CGColor(gray: 1, alpha: 0.34)
    static let glassEdge = CGColor(gray: 1, alpha: 0.72)
    static let glassHighlight = CGColor(gray: 1, alpha: 0.42)
    static let tipFill = CGColor(gray: 1, alpha: 0.92)
    static let clear = CGColor(gray: 1, alpha: 0)


    static let fieldOverhang: CGFloat = 256

    static func cloudField(side: CGFloat) -> CGImage? {
        let scale = side / 1024
        let height = side + fieldOverhang * scale
        guard let layer = CGContext(
            data: nil, width: Int(side * 2), height: Int(height), bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        layer.scaleBy(x: scale, y: scale)

        for tile in [CGFloat(-1024), 0, 1024, 2048] {
            layer.saveGState()
            layer.translateBy(x: tile, y: 0)

            layer.setFillColor(CGColor(gray: 1, alpha: 1))
            func blob(_ x: CGFloat, _ y: CGFloat, _ rx: CGFloat, _ ry: CGFloat) {
                layer.fillEllipse(in: CGRect(
                    x: x - rx, y: y - ry, width: rx * 2, height: ry * 2))
            }
            func circle(_ x: CGFloat, _ y: CGFloat, _ radius: CGFloat) {
                blob(x, y, radius, radius)
            }


            blob(-140, 150, 200, 55)
            blob(60, 140, 330, 66)
            blob(300, 155, 190, 50)
            for (x, y, radius) in [
                (CGFloat(-40), CGFloat(120), CGFloat(120)), (70, 95, 125),
                (180, 110, 110), (280, 130, 90), (360, 150, 65),
            ] { circle(x, y, radius) }

            blob(700, 955, 160, 60)
            blob(880, 950, 290, 70)
            blob(1050, 965, 170, 55)
            for (x, y, radius) in [
                (CGFloat(740), CGFloat(890), CGFloat(95)), (840, 845, 120),
                (950, 880, 105), (1040, 915, 80),
            ] { circle(x, y, radius) }

            layer.setBlendMode(.destinationOut)
            for (x, y, radius) in [
                (CGFloat(-10), CGFloat(238), CGFloat(70)), (250, 242, 60),
                (790, 1015, 60), (965, 1020, 55),
            ] { circle(x, y, radius) }
            layer.setBlendMode(.normal)
            layer.restoreGState()
        }

        guard let sharp = layer.makeImage(),
              let blur = CIFilter(name: "CIGaussianBlur") else { return nil }
        blur.setValue(CIImage(cgImage: sharp), forKey: kCIInputImageKey)
        blur.setValue(30 * scale, forKey: kCIInputRadiusKey)
        guard let output = blur.outputImage else { return sharp }
        return Cache.shared.render(
            output, from: CGRect(x: 0, y: 0, width: side * 2, height: height))
    }


    /**
     `drift` slides the clouds sideways; it wraps at 1, and 0 is the sky the
     asset catalogue holds. `palette` is the hour of the day — noon by
     default, because the bundle icon cannot change with the clock and the
     Dock is the only place that can.
     */
    public static func draw(
        into ctx: CGContext, size: CGFloat,
        drift: CGFloat = 0, palette: SkyPalette = .day
    ) {
        let s = size / 1024
        ctx.saveGState()
        ctx.translateBy(x: 0, y: size)
        ctx.scaleBy(x: s, y: -s)

        let canvas = CGRect(x: 0, y: 0, width: 1024, height: 1024)
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: [palette.top.cgColor, palette.bottom.cgColor] as CFArray,
                                  locations: [0, 1])!
        ctx.saveGState()
        ctx.addRect(canvas); ctx.clip()
        ctx.drawLinearGradient(
            gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 410, y: 1024),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

        if let clouds = Cache.shared.field(side: size) {
            let phase = drift - drift.rounded(.down)
            let field = CGRect(
                x: phase * 1024 - 1024, y: 0,
                width: 2048, height: 1024 + fieldOverhang)
            func lay(_ rect: CGRect, alpha: CGFloat) {
                ctx.saveGState()
                ctx.setAlpha(alpha * palette.cloudOpacity)
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                ctx.draw(clouds, in: rect)
                ctx.setBlendMode(.sourceAtop)
                ctx.setFillColor(palette.cloud.cgColor)
                ctx.fill(rect)
                ctx.endTransparencyLayer()
                ctx.restoreGState()
            }
            lay(field, alpha: 0.30)
            lay(field.offsetBy(dx: 0, dy: -26), alpha: 0.18)
        }
        ctx.restoreGState()

        let stemLeft: CGFloat = 418, stemRight: CGFloat = 606
        let stemTop: CGFloat = 214, shoulder: CGFloat = 554
        let headLeft: CGFloat = 290, headRight: CGFloat = 734
        let apexY: CGFloat = 812, cx: CGFloat = 512
        let topRadius: CGFloat = 40, edgeRadius: CGFloat = 26

        let arrow = CGMutablePath()
        arrow.move(to: CGPoint(x: stemLeft, y: stemTop + topRadius))
        arrow.addArc(tangent1End: CGPoint(x: stemLeft, y: stemTop),
                     tangent2End: CGPoint(x: stemRight, y: stemTop), radius: topRadius)
        arrow.addArc(tangent1End: CGPoint(x: stemRight, y: stemTop),
                     tangent2End: CGPoint(x: stemRight, y: shoulder), radius: topRadius)
        arrow.addLine(to: CGPoint(x: stemRight, y: shoulder))
        arrow.addArc(tangent1End: CGPoint(x: headRight, y: shoulder),
                     tangent2End: CGPoint(x: cx, y: apexY), radius: edgeRadius)
        arrow.addArc(tangent1End: CGPoint(x: cx, y: apexY),
                     tangent2End: CGPoint(x: headLeft, y: shoulder), radius: edgeRadius)
        arrow.addArc(tangent1End: CGPoint(x: headLeft, y: shoulder),
                     tangent2End: CGPoint(x: stemLeft, y: shoulder), radius: edgeRadius)
        arrow.addLine(to: CGPoint(x: stemLeft, y: shoulder))
        arrow.closeSubpath()

        ctx.setFillColor(glassFill)
        ctx.addPath(arrow); ctx.fillPath()

        ctx.setStrokeColor(glassEdge)
        ctx.setLineWidth(10)
        ctx.addPath(arrow); ctx.strokePath()

        ctx.saveGState()
        ctx.addPath(arrow); ctx.clip()
        let sheen = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [glassHighlight, clear] as CFArray,
            locations: [0, 1])!
        ctx.drawLinearGradient(
            sheen, start: CGPoint(x: 0, y: stemTop),
            end: CGPoint(x: 0, y: stemTop + 320), options: [])
        ctx.restoreGState()

        func bevel(along start: CGPoint, _ end: CGPoint, brightness: CGFloat) {
            let run = CGPoint(x: end.x - start.x, y: end.y - start.y)
            let length = max(hypot(run.x, run.y), 0.001)
            var inward = CGPoint(x: run.y / length, y: -run.x / length)
            let middle = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
            let toCentre = CGPoint(x: cx - middle.x, y: 640 - middle.y)
            if inward.x * toCentre.x + inward.y * toCentre.y < 0 {
                inward = CGPoint(x: -inward.x, y: -inward.y)
            }

            func band(inset: CGFloat, width: CGFloat, colours: [CGColor], stops: [CGFloat]) {
                let line = CGMutablePath()
                line.move(to: CGPoint(x: start.x + inward.x * inset, y: start.y + inward.y * inset))
                line.addLine(to: CGPoint(x: end.x + inward.x * inset, y: end.y + inward.y * inset))
                ctx.saveGState()
                ctx.addPath(arrow); ctx.clip()
                ctx.addPath(line.copy(
                    strokingWithWidth: width, lineCap: .round,
                    lineJoin: .round, miterLimit: 10))
                ctx.clip()
                let streak = CGGradient(
                    colorsSpace: CGColorSpaceCreateDeviceRGB(),
                    colors: colours as CFArray, locations: stops)!
                ctx.drawLinearGradient(streak, start: start, end: end, options: [])
                ctx.restoreGState()
            }

            band(inset: 26, width: 30,
                 colours: [clear, CGColor(gray: 0, alpha: 0.10 * brightness), clear],
                 stops: [0, 0.45, 1])
            band(inset: 2, width: 22,
                 colours: [clear, CGColor(gray: 1, alpha: brightness), clear],
                 stops: [0, 0.40, 1])
        }
        bevel(along: CGPoint(x: headLeft, y: shoulder), CGPoint(x: cx, y: apexY),
              brightness: 1)
        bevel(along: CGPoint(x: headRight, y: shoulder), CGPoint(x: cx, y: apexY),
              brightness: 0.5)

        ctx.saveGState()
        ctx.addPath(arrow); ctx.clip()
        let tip = CGMutablePath()
        tip.move(to: CGPoint(x: 424, y: 726))
        tip.addLine(to: CGPoint(x: 600, y: 726))
        tip.addLine(to: CGPoint(x: cx, y: apexY + 4))
        tip.closeSubpath()
        ctx.setFillColor(tipFill)
        ctx.addPath(tip); ctx.fillPath()
        ctx.restoreGState()

        ctx.restoreGState()
    }

    /**
     Renders the icon on its own, for callers that want an image rather than
     a context — the Dock icon, chiefly.
     */
    public static func image(
        side: CGFloat, drift: CGFloat = 0, palette: SkyPalette = .day
    ) -> CGImage? {
        guard let ctx = CGContext(
            data: nil, width: Int(side), height: Int(side), bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setAllowsAntialiasing(true)
        ctx.interpolationQuality = .high
        draw(into: ctx, size: side, drift: drift, palette: palette)
        return ctx.makeImage()
    }

    private final class Cache: @unchecked Sendable {
        static let shared = Cache()
        private let lock = NSLock()
        private let context = CIContext()
        private var fields: [Int: CGImage] = [:]

        func field(side: CGFloat) -> CGImage? {
            lock.lock(); defer { lock.unlock() }
            let key = Int(side)
            if let cached = fields[key] { return cached }
            guard let made = AppIconArtwork.cloudField(side: side) else { return nil }
            fields[key] = made
            return made
        }

        func render(_ image: CIImage, from rect: CGRect) -> CGImage? {
            context.createCGImage(image, from: rect)
        }
    }
}
