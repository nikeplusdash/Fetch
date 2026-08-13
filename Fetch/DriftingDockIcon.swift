import AppKit
import FetchKit

/// Moves the icon's clouds along while the app runs.
///
/// **The Dock is the only place this can happen.** An app icon is a static
/// asset everywhere else — Finder, Spotlight, Launchpad and System Settings
/// all read the bundle, and none of them will ask again while the app is
/// running. `applicationIconImage` is the one surface macOS lets a running app
/// redraw, so the drifting sky is a Dock and app-switcher effect and the
/// bundle keeps the still version for everywhere else.
///
/// **Nothing masks a runtime icon.** The art in the asset catalogue is drawn
/// edge to edge because macOS 26 cuts the silhouette itself, lights it and
/// drops its shadow. It does none of that for an image handed to
/// `applicationIconImage` — that image is blitted as given, and the first
/// version of this put a hard-cornered square in a Dock full of rounded ones.
///
/// So the shape is borrowed rather than reproduced: the system's own rendering
/// of the bundle is fetched once, its opaque region becomes a clip, and each
/// frame is drawn as that rendering with fresh sky painted inside it. The
/// silhouette, the shadow and the rim are therefore exactly the ones macOS
/// draws, because they *are* the ones macOS drew — no squircle of ours to go
/// subtly wrong against everything else on the Dock.
///
/// **Slow on purpose.** A full pass takes ten minutes, about a twentieth of
/// the icon's width per minute: enough that the sky has moved when you next
/// glance at the Dock, far too slow to catch the eye while you are working.
/// This is weather, not a progress indicator.
///
/// The colour of that sky comes from `SkyPalette`, which follows the clock —
/// so the Dock icon is dark at two in the morning and gold at sunset, while
/// the bundle stays at noon for everywhere that reads a file.
///
/// The frames are nearly free — `AppIconArtwork` keeps the blurred cloud field
/// between them, so a tick is a gradient, two image draws and a path.
@MainActor
final class DriftingDockIcon {
    static let shared = DriftingDockIcon()

    private var timer: Timer?
    private var phase: CGFloat = 0
    private var stencil: Stencil?

    /// Rendered larger than the Dock asks for, because the app switcher shows
    /// the same image at a size the Dock never uses.
    private let side = 512
    private let tick: TimeInterval = 3
    private let period: TimeInterval = 10 * 60

    private init() {}

    func start() {
        guard timer == nil else { return }
        // Taken before the first override, so it is the bundle's icon as macOS
        // renders it and not a picture of our own last frame.
        stencil = Stencil(side: side)
        guard stencil != nil else { return }

        redraw()
        let timer = Timer.scheduledTimer(withTimeInterval: tick, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advance() }
        }
        // A second either way is nothing to a ten-minute pass, and it lets the
        // system coalesce this wake-up with whatever else it was going to do —
        // the difference between a timer that costs nothing and one that shows
        // up in the energy tab.
        timer.tolerance = 1
        self.timer = timer
    }

    /// Puts the bundle's own icon back. Nothing calls this yet; it exists so
    /// that turning the effect off is a one-liner rather than a relaunch.
    func stop() {
        timer?.invalidate()
        timer = nil
        NSApp.applicationIconImage = nil
    }

    private func advance() {
        phase += CGFloat(tick / period)
        if phase >= 1 { phase -= 1 }
        redraw()
    }

    private func redraw() {
        // The palette is recomputed every tick rather than cached per hour:
        // `SkyPalette` interpolates continuously, so dusk arrives as a slow
        // change of colour instead of the icon switching from day to evening
        // between one frame and the next.
        let sky = SkyPalette.at(Date())
        guard let stencil, let image = stencil.frame(drift: phase, palette: sky) else { return }
        NSApp.applicationIconImage = NSImage(
            cgImage: image, size: NSSize(width: side, height: side))
    }

    /// The system's rendering of the bundle icon, plus the clip that isolates
    /// its face from its shadow.
    private struct Stencil {
        let rendered: CGImage
        /// White where the icon's face is, black over the shadow and outside.
        let face: CGImage
        /// Where the face sits in the canvas. macOS insets the art to leave
        /// room for the shadow, and the sky has to land in the same place or
        /// the arrow would jump the moment the first frame replaced the
        /// bundle's icon.
        let bounds: CGRect
        let side: Int

        init?(side: Int) {
            self.side = side
            let icon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
            var rect = CGRect(x: 0, y: 0, width: side, height: side)
            guard let rendered = icon.cgImage(
                forProposedRect: &rect, context: nil, hints: nil) else { return nil }
            self.rendered = rendered

            // **Alpha, by drawing the icon twice.** The direct route —
            // `clip(to:mask:)` with the icon itself — is not allowed: that call
            // requires a DeviceGray image with no alpha, which is exactly the
            // thing being extracted. Over white a pixel comes out as
            // `icon·a + 255·(1−a)` and over black as `icon·a`, so the
            // difference between the two renders is `255·(1−a)` and the icon's
            // own colour cancels.
            //
            // The buffers are ours, not the contexts'. `CGContext.data` is
            // owned by the context and freed with it, so reading it after the
            // context goes out of scope is a use-after-free — which is
            // precisely how the first version of this launched the app and
            // then quietly killed it before the Dock icon ever appeared.
            func render(over background: CGFloat) -> [UInt8] {
                var buffer = [UInt8](repeating: 0, count: side * side * 4)
                buffer.withUnsafeMutableBytes { raw in
                    guard let context = CGContext(
                        data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8,
                        bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                    else { return }
                    context.setFillColor(CGColor(gray: background, alpha: 1))
                    context.fill(rect)
                    context.draw(rendered, in: rect)
                }
                return buffer
            }
            let onWhite = render(over: 1), onBlack = render(over: 0)

            // The face is the fully opaque part: the shadow is soft and the
            // antialiased rim is partial, so a threshold this high also erodes
            // the edge by a pixel, which is what keeps the system's own rim
            // visible around the new sky rather than painted over.
            guard let mask = CGContext(
                data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
                  let pixels = mask.data?.bindMemory(to: UInt8.self, capacity: side * side)
            else { return nil }

            var minX = side, minY = side, maxX = 0, maxY = 0
            for index in 0..<(side * side) {
                let opaque = Int(onWhite[index * 4]) - Int(onBlack[index * 4]) <= 5
                pixels[index] = opaque ? 255 : 0
                guard opaque else { continue }
                let x = index % side, y = index / side
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
            guard minX < maxX, minY < maxY, let face = mask.makeImage() else { return nil }
            self.face = face
            // Top-down, because that is how the buffer is laid out; `frame`
            // flips it back when it positions the art.
            self.bounds = CGRect(
                x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        }

        func frame(drift: CGFloat, palette: SkyPalette) -> CGImage? {
            guard let context = CGContext(
                data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            let canvas = CGRect(x: 0, y: 0, width: side, height: side)
            context.interpolationQuality = .high

            // The shadow, the rim and the system's own lighting come from
            // underneath; only the face is repainted.
            context.draw(rendered, in: canvas)
            context.saveGState()
            context.clip(to: canvas, mask: face)
            // **Scaled into the face, not cropped by it.** Measured rather
            // than assumed: the arrow's tip sits 70.9% down the asset and
            // 66.8% down the icon macOS draws, which is where it lands if the
            // whole 1024 canvas is shrunk to about 78% and centred, and not
            // where it lands if the art is cropped at full size. Drawing it
            // edge to edge here would have left an arrow noticeably larger
            // than the bundle's, and it would have jumped the moment the first
            // frame replaced it.
            context.translateBy(x: bounds.minX, y: CGFloat(side) - bounds.maxY)
            AppIconArtwork.draw(
                into: context, size: bounds.width, drift: drift, palette: palette)
            context.restoreGState()
            return context.makeImage()
        }
    }
}
