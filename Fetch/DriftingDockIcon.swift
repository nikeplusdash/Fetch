import AppKit
import FetchKit

/**
 Moves the icon's clouds along while the app runs.

 **The Dock is the only place this can happen.** An app icon is a static
 asset everywhere else — Finder, Spotlight, Launchpad and System Settings
 all read the bundle, and none of them will ask again while the app is
 running. `applicationIconImage` is the one surface macOS lets a running app
 redraw, so the drifting sky is a Dock and app-switcher effect and the
 bundle keeps the still version for everywhere else.

 **Nothing masks a runtime icon.** The art in the asset catalogue is drawn
 edge to edge because macOS 26 cuts the silhouette itself, lights it and
 drops its shadow. It does none of that for an image handed to
 `applicationIconImage` — that image is blitted as given, and the first
 version of this put a hard-cornered square in a Dock full of rounded ones.

 So the shape is borrowed rather than reproduced: the system's own rendering
 of the bundle is fetched once, its opaque region becomes a clip, and each
 frame is drawn as that rendering with fresh sky painted inside it. The
 silhouette, the shadow and the rim are therefore exactly the ones macOS
 draws, because they *are* the ones macOS drew — no squircle of ours to go
 subtly wrong against everything else on the Dock.

 **Slow on purpose.** A full pass takes ten minutes, about a twentieth of
 the icon's width per minute: enough that the sky has moved when you next
 glance at the Dock, far too slow to catch the eye while you are working.
 This is weather, not a progress indicator.

 The colour of that sky comes from `SkyPalette`, which follows the clock —
 so the Dock icon is dark at two in the morning and gold at sunset, while
 the bundle stays at noon for everywhere that reads a file.

 The frames are nearly free — `AppIconArtwork` keeps the blurred cloud field
 between them, so a tick is a gradient, two image draws and a path.
 */
@MainActor
final class DriftingDockIcon {
    static let shared = DriftingDockIcon()

    private var timer: Timer?
    private var persistenceTimer: Timer?
    private var phase: CGFloat = 0
    private var stencil: Stencil?

    private let side = 512
    private let tick: TimeInterval = 3
    private let period: TimeInterval = 10 * 60

    private init() {}

    func start() {
        guard timer == nil else { return }
        stencil = Stencil(side: side)
        guard stencil != nil else { return }

        redraw()
        persistToBundle()
        let timer = Timer.scheduledTimer(withTimeInterval: tick, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advance() }
        }
        timer.tolerance = 1
        self.timer = timer

        let persistence = Timer.scheduledTimer(
            withTimeInterval: period, repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.persistToBundle() }
        }
        persistence.tolerance = 30
        self.persistenceTimer = persistence
    }

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

    func reassert() {
        guard stencil != nil else { return }
        redraw()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        persistenceTimer?.invalidate()
        persistenceTimer = nil
        NSApp.applicationIconImage = nil
    }

    private func advance() {
        phase += CGFloat(tick / period)
        if phase >= 1 { phase -= 1 }
        redraw()
    }

    private func redraw() {
        let sky = SkyPalette.at(Date())
        guard let stencil, let image = stencil.frame(drift: phase, palette: sky) else { return }
        NSApp.applicationIconImage = NSImage(
            cgImage: image, size: NSSize(width: side, height: side))
    }

    func forgetPersistedIcon() { Stencil.forgetCustomIcon() }

    private struct Stencil {
        let rendered: CGImage
        let face: CGImage
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

        private static var cacheURL: URL? {
            let version = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "0"
            return FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("Fetch", isDirectory: true)
                .appendingPathComponent("dock-stencil-\(version).png")
        }

        static var bundleHasCustomIcon: Bool {
            FileManager.default.fileExists(
                atPath: Bundle.main.bundlePath + "/Icon\r")
        }

        static func forgetCustomIcon() {
            try? FileManager.default.removeItem(
                atPath: Bundle.main.bundlePath + "/Icon\r")
        }

        init?(side: Int) {
            self.side = side
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
                if !Self.bundleHasCustomIcon { Self.cachePristine(drawn) }
            }
            self.rendered = rendered

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

            context.draw(rendered, in: canvas)
            context.saveGState()
            context.clip(to: canvas, mask: face)
            context.translateBy(x: bounds.minX, y: CGFloat(side) - bounds.maxY)
            AppIconArtwork.draw(
                into: context, size: bounds.width, drift: drift, palette: palette)
            context.restoreGState()
            return context.makeImage()
        }
    }
}
