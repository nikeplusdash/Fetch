import CoreGraphics
import FetchKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

func write(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fatalError("could not write \(url.lastPathComponent)") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        fatalError("could not finalise \(url.lastPathComponent)")
    }
    print("wrote \(url.lastPathComponent) (\(image.width)x\(image.height))")
}

let arguments = CommandLine.arguments

if arguments.count > 2, arguments[1] == "--hours" {
    let hours = [0, 3, 5, 6, 7, 12, 18, 19, 20, 22]
    let side = 200, gap = 14
    let width = side * hours.count + gap * (hours.count + 1)
    guard let sheet = CGContext(
        data: nil, width: width, height: side + gap * 2, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fatalError("no context") }
    sheet.setFillColor(CGColor(gray: 0.92, alpha: 1))
    sheet.fill(CGRect(x: 0, y: 0, width: width, height: side + gap * 2))
    for (index, hour) in hours.enumerated() {
        guard let image = AppIconArtwork.image(
            side: CGFloat(side), palette: SkyPalette.at(hour: Double(hour)))
        else { fatalError("could not draw hour \(hour)") }
        sheet.draw(image, in: CGRect(
            x: gap + index * (side + gap), y: gap, width: side, height: side))
    }
    write(sheet.makeImage()!, to: URL(fileURLWithPath: arguments[2]))
    exit(0)
}

if arguments.count > 2, arguments[1] == "--preview" {
    let side = 256, frames = 4, gap = 16
    let width = side * frames + gap * (frames + 1)
    guard let sheet = CGContext(
        data: nil, width: width, height: side + gap * 2, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fatalError("no context") }
    sheet.setFillColor(CGColor(gray: 0.92, alpha: 1))
    sheet.fill(CGRect(x: 0, y: 0, width: width, height: side + gap * 2))
    for frame in 0..<frames {
        guard let image = AppIconArtwork.image(
            side: CGFloat(side), drift: CGFloat(frame) / CGFloat(frames))
        else { fatalError("could not draw frame \(frame)") }
        sheet.draw(image, in: CGRect(
            x: gap + frame * (side + gap), y: gap, width: side, height: side))
    }
    write(sheet.makeImage()!, to: URL(fileURLWithPath: arguments[2]))
    exit(0)
}

let directory = arguments.count > 1 ? arguments[1] : "."

for (point, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                       (256, 1), (256, 2), (512, 1), (512, 2)] {
    let pixels = point * scale
    guard let image = AppIconArtwork.image(side: CGFloat(pixels)) else {
        fatalError("could not draw \(pixels)px")
    }
    write(image, to: URL(fileURLWithPath: directory)
        .appendingPathComponent("icon_\(point)x\(point)@\(scale)x.png"))
}
