// Renders the BITT app icon into an .iconset directory.
// Run: swiftc -o makeicon Tools/makeicon.swift Sources/BittMark.swift && ./makeicon out.iconset

import AppKit
import CoreGraphics
import Foundation

func drawIcon(in context: CGContext, size: CGFloat) {
    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    let inset = size * 0.085
    let plate = rect.insetBy(dx: inset, dy: inset)
    let radius = plate.width * 0.2237            // the Big Sur corner proportion
    let platePath = CGPath(roundedRect: plate, cornerWidth: radius, cornerHeight: radius,
                           transform: nil)
    let centre = CGPoint(x: plate.midX, y: plate.midY)
    let space = CGColorSpaceCreateDeviceRGB()

    // Shadow beneath the plate.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -size * 0.012),
                      blur: size * 0.032,
                      color: NSColor.black.withAlphaComponent(0.30).cgColor)
    context.addPath(platePath)
    context.setFillColor(NSColor.white.cgColor)
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(platePath)
    context.clip()

    // Indigo to violet, top-left to bottom-right.
    let start = CGColor(colorSpace: space, components: [0.33, 0.42, 0.98, 1])!
    let end = CGColor(colorSpace: space, components: [0.52, 0.22, 0.85, 1])!
    if let gradient = CGGradient(colorsSpace: space, colors: [start, end] as CFArray,
                                 locations: [0, 1]) {
        context.drawLinearGradient(gradient,
                                   start: CGPoint(x: plate.minX, y: plate.maxY),
                                   end: CGPoint(x: plate.maxX, y: plate.minY),
                                   options: [])
    }

    // A pool of light behind the mark lifts it off the gradient.
    if let glow = CGGradient(colorsSpace: space,
                             colors: [CGColor(colorSpace: space, components: [1, 1, 1, 0.20])!,
                                      CGColor(colorSpace: space, components: [1, 1, 1, 0])!] as CFArray,
                             locations: [0, 1]) {
        context.drawRadialGradient(glow,
                                   startCenter: centre, startRadius: 0,
                                   endCenter: centre, endRadius: plate.width * 0.62,
                                   options: [])
    }

    // Top sheen.
    if let sheen = CGGradient(colorsSpace: space,
                              colors: [CGColor(colorSpace: space, components: [1, 1, 1, 0.16])!,
                                       CGColor(colorSpace: space, components: [1, 1, 1, 0])!] as CFArray,
                              locations: [0, 1]) {
        context.drawLinearGradient(sheen,
                                   start: CGPoint(x: plate.midX, y: plate.maxY),
                                   end: CGPoint(x: plate.midX, y: plate.midY),
                                   options: [])
    }
    context.restoreGState()

    // Below about 48px the orbiting dots turn to noise and the cut-out needs
    // every pixel it can get, so the small sizes get a simplified mark.
    let detailed = size >= 48
    let markRadius = plate.width * (detailed ? 0.300 : 0.395)

    if detailed {
        context.saveGState()
        context.setFillColor(NSColor.white.cgColor)
        BittMark.satellites(in: context, centre: centre, radius: markRadius) { index in
            [0.55, 0.30, 0.42, 0.55, 0.30, 0.42][index]
        }
        context.restoreGState()
    }

    context.saveGState()
    if detailed {
        context.setShadow(offset: CGSize(width: 0, height: -size * 0.008),
                          blur: size * 0.022,
                          color: NSColor.black.withAlphaComponent(0.22).cgColor)
    }
    context.setFillColor(NSColor.white.cgColor)
    BittMark.fillGlyph(in: context, centre: centre, radius: markRadius)
    context.restoreGState()
}

func render(size: Int) -> Data? {
    let space = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(data: nil, width: size, height: size,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        return nil
    }
    drawIcon(in: context, size: CGFloat(size))
    guard let image = context.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: size, height: size)
    return rep.representation(using: .png, properties: [:])
}

@main
struct MakeIcon {
    static let variants: [(name: String, pixels: Int)] = [
        ("icon_16x16", 16), ("icon_16x16@2x", 32),
        ("icon_32x32", 32), ("icon_32x32@2x", 64),
        ("icon_128x128", 128), ("icon_128x128@2x", 256),
        ("icon_256x256", 256), ("icon_256x256@2x", 512),
        ("icon_512x512", 512), ("icon_512x512@2x", 1024),
    ]

    static func main() throws {
        let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "BITT.iconset"
        let outputURL = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

        for variant in variants {
            guard let data = render(size: variant.pixels) else {
                FileHandle.standardError.write("could not render \(variant.name)\n".data(using: .utf8)!)
                exit(1)
            }
            try data.write(to: outputURL.appendingPathComponent(variant.name + ".png"))
        }
        print("wrote \(variants.count) images to \(outputPath)")
    }
}
