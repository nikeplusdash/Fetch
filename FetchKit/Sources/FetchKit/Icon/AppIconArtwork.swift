import CoreGraphics
import CoreImage
import Foundation

/// Fetch's app icon, drawn rather than exported.
///
/// **Why it is code.** macOS ships no dependable SVG rasteriser on the command
/// line — `qlmanage` produces nothing and `sips` does not read SVG — so the
/// asset catalogue is rendered from this. Keeping it here rather than in a
/// throwaway script is what lets the running app draw the same sky with its
/// clouds moved along, which a PNG cannot do.
///
/// The geometry is the v4 mark from `design/icon`, in the same 1024 space.
/// Keep the two in step by hand.
///
/// **Verify changes through `NSWorkspace.icon(forFile:)`, not by opening the
/// PNG.** macOS 26 re-masks the art, applies its own material and lights it;
/// the file on disk and the icon on screen are not the same image. That is
/// also why the art is edge to edge and draws no rounded rectangle of its own
/// — the silhouette is the system's to decide.
public enum AppIconArtwork {

    // MARK: - Palette

    /// The sky itself is `SkyPalette`, which has an hour of the day in it.
    ///
    /// The arrow is glass over that sky, which means it is mostly *not*
    /// painted.
    ///
    /// A frosted pane reads from three things and none of them is a fill
    /// colour: a wash light enough that the field shows through, an edge that
    /// catches more light than the face, and a highlight along the top where
    /// the light comes from. Painting a pale blue arrow instead gives a
    /// sticker — the giveaway is that a sticker looks the same wherever it
    /// sits, and glass does not.
    static let glassFill = CGColor(gray: 1, alpha: 0.34)
    static let glassEdge = CGColor(gray: 1, alpha: 0.72)
    static let glassHighlight = CGColor(gray: 1, alpha: 0.42)
    /// The tip is the one part that is nearly solid: it is where the download
    /// lands, and the icon needs one thing that reads at 16 points once the
    /// glass has dissolved into the sky.
    static let tipFill = CGColor(gray: 1, alpha: 0.92)
    static let clear = CGColor(gray: 1, alpha: 0)

    // MARK: - Sky

    /// Two cloud banks, as a field twice the canvas wide that repeats every
    /// 1024 — so `drift` can slide it sideways for ever without a seam.
    ///
    /// **A silhouette, then blurred — not pale shapes drawn softly.**
    /// Overlapping semi-transparent circles compound where they overlap, so
    /// the seams between them stay visible however soft each one is. The body
    /// therefore goes down at full opacity, which unions cleanly; it is the
    /// blur that makes it a cloud and the compositing alpha that decides how
    /// present it is.
    ///
    /// **Carved, not just drawn.** After the union, a few circles are cut back
    /// out with `.destinationOut`. A cloud's underside is torn where the air
    /// stops holding it up, and an outline built only by adding circles is
    /// uniformly convex — which is exactly what makes drawn clouds look like
    /// cartoon sheep.
    ///
    /// **Both banks run off the canvas edges.** You never see a whole cloud;
    /// one floating entirely inside the frame reads as a sticker. Anchoring
    /// each to an edge is most of what makes the sky look like it continues
    /// past the icon.
    ///
    /// **Coordinates here are y-down**, like the arrow's and like the SVG's.
    /// The layer is a plain bitmap and so is y-up, but it is composited into an
    /// already-flipped context and the two cancel: a shape authored at y = 180
    /// lands 180 down from the top of the finished icon. Authoring it y-up put
    /// the heavy bank in the corner opposite the one intended.
    ///
    /// Deterministic on purpose: randomness would mean the icon differs
    /// between builds, and an app icon that is not byte-identical from one
    /// render to the next cannot be diffed or reviewed.
    /// The field is taller than the canvas by `fieldOverhang`, so the lower
    /// bank can hang past the bottom without meeting the edge of the bitmap.
    /// A shape clipped by that edge leaves a hard horizontal line the moment
    /// the second, offset pass is composited over it — the two passes' cut-off
    /// points are 26 apart and the step between them is a drawn-on rule across
    /// the icon.
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

        // The field is 2048 wide and holds two copies of a 1024-wide sky. The
        // copies either side of that — at -1024 and 2048 — are drawn only so
        // the blur has neighbours at the crop edges; without them the seam
        // reappears as a soft vertical band every time the drift wraps.
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

            // **Ellipses only, no rectangles.** The bases here used to be
            // filled rects, which is the obvious way to give a cumulus its
            // flat underside and also puts four right angles in a shape that
            // must not contain one — a blur softens a corner but does not stop
            // it reading as a corner, and the sky came out looking like it was
            // built from Tetris pieces. A row of wide, flat ellipses sharing a
            // bottom edge gives the same flat base out of nothing but curves.

            // Upper left, running off two edges. Lobes get smaller towards the
            // right, which is what gives a cloud a direction.
            blob(-140, 150, 200, 55)
            blob(60, 140, 330, 66)
            blob(300, 155, 190, 50)
            for (x, y, radius) in [
                (CGFloat(-40), CGFloat(120), CGFloat(120)), (70, 95, 125),
                (180, 110, 110), (280, 130, 90), (360, 150, 65),
            ] { circle(x, y, radius) }

            // Lower right, off the right edge and further down, so the two sit
            // on a diagonal rather than facing each other. Its base sits below
            // the masked area — the bank runs off the bottom rather than
            // ending there.
            blob(700, 955, 160, 60)
            blob(880, 950, 290, 70)
            blob(1050, 965, 170, 55)
            for (x, y, radius) in [
                (CGFloat(740), CGFloat(890), CGFloat(95)), (840, 845, 120),
                (950, 880, 105), (1040, 915, 80),
            ] { circle(x, y, radius) }

            // The tearing. A cloud's underside is torn where the air stops
            // holding it up, and an outline built only by adding shapes is
            // uniformly convex — which is what makes drawn clouds look like
            // cartoon sheep.
            //
            // Small, and only along the undersides. The first set were as
            // large as the lobes and centred on the body, which did not tear
            // the outline so much as eat it: what came back was a scalloped
            // ribbon with a notch between every pair of lobes, and the lobes
            // themselves read as separate birds rather than one mass.
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
        // Enough to lose the circles, not enough to lose the silhouette.
        blur.setValue(CIImage(cgImage: sharp), forKey: kCIInputImageKey)
        blur.setValue(30 * scale, forKey: kCIInputRadiusKey)
        guard let output = blur.outputImage else { return sharp }
        // Cropped back to the field: a blur grows its own extent, and left
        // uncropped the layer would be drawn scaled down to fit.
        return Cache.shared.render(
            output, from: CGRect(x: 0, y: 0, width: side * 2, height: height))
    }

    // MARK: - The whole icon

    /// `drift` slides the clouds sideways; it wraps at 1, and 0 is the sky the
    /// asset catalogue holds. `palette` is the hour of the day — noon by
    /// default, because the bundle icon cannot change with the clock and the
    /// Dock is the only place that can.
    public static func draw(
        into ctx: CGContext, size: CGFloat,
        drift: CGFloat = 0, palette: SkyPalette = .day
    ) {
        let s = size / 1024
        ctx.saveGState()
        // Flip to y-down so these coordinates read the same as the SVG's.
        ctx.translateBy(x: 0, y: size)
        ctx.scaleBy(x: s, y: -s)

        let canvas = CGRect(x: 0, y: 0, width: 1024, height: 1024)
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: [palette.top.cgColor, palette.bottom.cgColor] as CFArray,
                                  locations: [0, 1])!
        ctx.saveGState()
        ctx.addRect(canvas); ctx.clip()
        // Both options, or CoreGraphics leaves everything past the axis
        // unpainted — which read as one square corner on an otherwise rounded
        // square and looked exactly like a broken clip path.
        ctx.drawLinearGradient(
            gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 410, y: 1024),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

        // Faint enough to be weather rather than decoration: at 32 points
        // these should read as a sky with something in it, not as shapes
        // competing with the arrow. Drawn inside the canvas clip so the blur
        // cannot bleed past it.
        //
        // Twice, the second pass shifted up — *negative* dy, because this
        // context is flipped and the obvious sign put the bright rim along the
        // undersides, which is where a cloud is darkest. The offset copy peaks
        // above the first, leaving a lit edge along every upward-facing
        // surface and nothing beneath. One flat wash of white has no top or
        // bottom at all.
        if let clouds = Cache.shared.field(side: size) {
            // Anchored at the top and one tile to the left: the canvas then
            // shows the field's right half, which is a whole tile with its
            // neighbours either side, so the wrap has no seam to show.
            let phase = drift - drift.rounded(.down)
            let field = CGRect(
                x: phase * 1024 - 1024, y: 0,
                width: 2048, height: 1024 + fieldOverhang)
            // **Tinted through a transparency layer.** The field is white
            // with an alpha channel, and the obvious ways to colour it are
            // both closed: `clip(to:mask:)` wants a DeviceGray image with no
            // alpha, and rebuilding the field in the hour's colour would mean
            // a fresh Gaussian over a 2048-wide bitmap every time the light
            // changed. Inside a layer, `.sourceAtop` paints the colour only
            // where the clouds already are, and the layer's own alpha carries
            // the compositing weight.
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

        // **This is the v4 mark, not an approximation of it.** The first Swift
        // version drew a thin stem plus a separate hard-cornered triangle,
        // which is a different arrow: the drawn one is a *single* outline with
        // rounded shoulders and a rounded point, and a stem half again as
        // thick. Reading the SVG rather than eyeballing the render settled it.
        //
        // The vertices below are that path's, with `addArc(tangent1End:...)`
        // for the corners it rounds — 40 at the top of the stem, 26 at the
        // shoulders and the point. Sharp where the stem meets the head,
        // because that corner is an inside one and rounding it would round the
        // wrong thing.
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

        // Glass: a wash, an edge, and a highlight where the light is.
        ctx.setFillColor(glassFill)
        ctx.addPath(arrow); ctx.fillPath()

        ctx.setStrokeColor(glassEdge)
        ctx.setLineWidth(10)
        ctx.addPath(arrow); ctx.strokePath()

        // The highlight falls off rather than stopping. A flat band across the
        // top of the stem read as a second, lighter box sitting *on* the arrow
        // — which is what a sticker looks like. Glass is brightest where it
        // faces the light and fades from there, so this is a gradient to
        // nothing.
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

        // **The shine along the two diagonals.** macOS 26's icons are lit
        // objects rather than flat shapes, and the tell is that their edges
        // catch light unevenly — a bright run along one face, nothing along
        // the next. A uniform outline stroke, which is what this had, reads as
        // a drawn border instead.
        //
        // Each streak is a straight band along one edge of the head, clipped
        // to the arrow so only its inner half survives: that turns a stroke
        // into a bevel, catching the light on the inside of the edge the way a
        // thick piece of glass does. Brightest a little before the middle and
        // gone by both ends, because a specular highlight is a reflection of
        // one light and not a coat of paint.
        //
        // The two are not equal. The light in this icon comes from the upper
        // left — the sheen down the stem says so — so the left diagonal faces
        // it and the right one only catches a glance.
        // **A bevel, not a brighter line.** The first attempt was a single
        // white streak laid over the existing outline, and against a bright
        // sky it did nothing at all — white on white-on-blue has nowhere to
        // go. What makes a thick edge of glass read is the pair: a lit rim
        // right on the boundary and a darker band of refraction just inside
        // it, so the eye gets a step in both directions rather than one more
        // shade of pale.
        func bevel(along start: CGPoint, _ end: CGPoint, brightness: CGFloat) {
            // Which way is into the arrow. Taken from the segment's own
            // normal, with the sign chosen by pointing it at the middle of the
            // head, so the two diagonals do not need separate arithmetic and
            // cannot disagree about which side they are on.
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
                // Along the edge, so the highlight has a beginning and an end.
                // A specular is a reflection of one light; a band of even
                // brightness from corner to corner is a coat of paint.
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
        // The light in this icon comes from the upper left — the sheen down
        // the stem says so — so the left diagonal faces it and the right one
        // only catches a glance. Equal shine on both would light the mark from
        // two suns.
        bevel(along: CGPoint(x: headLeft, y: shoulder), CGPoint(x: cx, y: apexY),
              brightness: 1)
        bevel(along: CGPoint(x: headRight, y: shoulder), CGPoint(x: cx, y: apexY),
              brightness: 0.5)

        // The tip: nearly solid, clipped to the arrow so it keeps the rounded
        // point rather than squaring it off.
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

    /// Renders the icon on its own, for callers that want an image rather than
    /// a context — the Dock icon, chiefly.
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

    /// The blurred cloud field, kept between frames.
    ///
    /// The blur is the whole cost of a frame and the field never changes —
    /// only where it is drawn does — so an animated icon that rebuilt it every
    /// tick would burn a Gaussian over a 2048-wide bitmap several times a
    /// minute to produce the identical bitmap. Keyed by pixel size because the
    /// Dock and the asset catalogue ask for different ones.
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
