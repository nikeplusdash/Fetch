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
    /// Separate from `timer`: the frames are three seconds apart and the file
    /// is written once a period, so one clock cannot serve both.
    private var persistenceTimer: Timer?
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
        // Written straight away, so a session that ends in a force quit or a
        // crash still leaves the tile roughly right rather than months stale.
        persistToBundle()
        let timer = Timer.scheduledTimer(withTimeInterval: tick, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advance() }
        }
        // A second either way is nothing to a ten-minute pass, and it lets the
        // system coalesce this wake-up with whatever else it was going to do —
        // the difference between a timer that costs nothing and one that shows
        // up in the energy tab.
        timer.tolerance = 1
        self.timer = timer

        // One write per drift period. The tile only has to be close: it is
        // read when Fetch is *not* running, and the sky moves in minutes.
        let persistence = Timer.scheduledTimer(
            withTimeInterval: period, repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.persistToBundle() }
        }
        persistence.tolerance = 30
        self.persistenceTimer = persistence
    }

    /// Writes the current frame into the app bundle, so the Dock shows it while
    /// Fetch is **not** running.
    ///
    /// **This is the only fix for the switch on the way in and out.**
    /// `applicationIconImage` lives exactly as long as the process: the Dock
    /// paints the bundle's own icon from the moment a launch begins until this
    /// app overrides it, and paints it again the instant the app quits. Moving
    /// the override earlier narrowed that window and could never close it,
    /// because part of it is before any of our code has run at all. The tile of
    /// a app that is not running comes from the bundle, so the bundle is what
    /// has to change.
    ///
    /// **It does not break the code signature.** `setIcon` writes an `Icon\r`
    /// file at the *top level* of the bundle and a `com.apple.FinderInfo`
    /// extended attribute on it. `codesign` seals `Contents/`, which is
    /// untouched — verified against a real build: plain `codesign --verify`
    /// still reports "valid on disk" and "satisfies its Designated
    /// Requirement", and the app launches normally. `--deep --strict` does
    /// object to the xattr, but that is a check Gatekeeper runs on a
    /// freshly-downloaded copy, and a freshly-downloaded copy has no custom
    /// icon: this is written later, on the user's own machine, by an app that
    /// has already been admitted.
    ///
    /// Failure is silent and harmless. A bundle on a read-only volume, or one
    /// running translocated, simply keeps its still icon.
    func persistToBundle() {
        guard let stencil,
              let image = stencil.frame(drift: phase, palette: SkyPalette.at(Date()))
        else { return }
        let written = NSWorkspace.shared.setIcon(
            NSImage(cgImage: image, size: NSSize(width: side, height: side)),
            forFile: Bundle.main.bundlePath,
            options: [])
        if !written {
            fetchLog(.warn, "icon", "could not write the Dock tile into the bundle")
        }
    }

    /// Paints the current frame again, without touching the timer.
    ///
    /// For the moments when something else may have put the bundle icon back —
    /// termination is the one that shows. Cheap: `Stencil` holds the system's
    /// rendering, so this is a gradient and two draws.
    func reassert() {
        guard stencil != nil else { return }
        redraw()
    }

    /// Puts the bundle's own icon back. Nothing calls this yet; it exists so
    /// that turning the effect off is a one-liner rather than a relaunch.
    func stop() {
        timer?.invalidate()
        timer = nil
        persistenceTimer?.invalidate()
        persistenceTimer = nil
        NSApp.applicationIconImage = nil
        // The bundle keeps whatever was last written. Removing the custom icon
        // is `Stencil.forgetCustomIcon()`, which the caller can reach for if it
        // wants the asset catalogue's own art back everywhere.
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

    /// Removes the custom icon written into the bundle, so everything that
    /// reads a file sees the asset catalogue's art again.
    func forgetPersistedIcon() { Stencil.forgetCustomIcon() }

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

        private static func cachedPristine(side: Int) -> CGImage? {
            guard let url = cacheURL,
                  let data = try? Data(contentsOf: url),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  image.width == side
            else { return nil }
            return image
        }

        private static func cachePristine(_ image: CGImage) {
            guard let url = cacheURL else { return }
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard let destination = CGImageDestinationCreateWithURL(
                url as CFURL, "public.png" as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
        }

        /// Where the pristine rendering is kept between launches.
        ///
        /// Keyed by build, so a version with new art re-captures rather than
        /// wearing the old one for ever.
        private static var cacheURL: URL? {
            let version = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "0"
            return FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("Fetch", isDirectory: true)
                .appendingPathComponent("dock-stencil-\(version).png")
        }

        /// True once `persistToBundle()` has written one. `setIcon` puts an
        /// `Icon\r` at the top level of the bundle; its presence is the only
        /// thing that distinguishes "macOS is rendering our art" from "macOS is
        /// rendering last session's sky".
        static var bundleHasCustomIcon: Bool {
            FileManager.default.fileExists(
                atPath: Bundle.main.bundlePath + "/Icon\r")
        }

        /// Removes it, so the asset catalogue's own art is what everything
        /// reads again.
        static func forgetCustomIcon() {
            try? FileManager.default.removeItem(
                atPath: Bundle.main.bundlePath + "/Icon\r")
        }

        init?(side: Int) {
            self.side = side
            // **The source has to be art, not a photograph of the last
            // session.** `NSWorkspace.icon(forFile:)` returns the *custom* icon
            // once one has been written — which is a frame of this very
            // effect — so building the stencil from it would compound one
            // session's sky into the next. The system's rendering of the
            // untouched bundle is captured once and kept.
            //
            // Falling back to the workspace icon when there is no cache is
            // safe rather than merely tolerable: the face mask comes from
            // alpha, which a written frame has in exactly the same places, and
            // the sky inside it is repainted every frame regardless.
            var rect = CGRect(x: 0, y: 0, width: side, height: side)
            let pristine = Self.cachedPristine(side: side)
            let rendered: CGImage
            if let pristine {
                rendered = pristine
            } else {
                let icon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
                guard let drawn = icon.cgImage(
                    forProposedRect: &rect, context: nil, hints: nil) else { return nil }
                rendered = drawn
                // Only worth keeping if it is genuinely the bundle's own art.
                if !Self.bundleHasCustomIcon { Self.cachePristine(drawn) }
            }
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
