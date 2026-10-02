import AppKit
import SwiftUI

/// The BITT logo as a view. Drawn from the same `BittMark` geometry as the
/// app icon and the menu bar icon, so all three stay in step.
struct BrandMark: View {
    var size: CGFloat = 24

    var body: some View {
        Image(nsImage: LogoImage.image(side: size * 2))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityLabel("BITT")
    }
}

enum LogoImage {
    private static var cache: [CGFloat: NSImage] = [:]

    static func image(side: CGFloat) -> NSImage {
        if let existing = cache[side] { return existing }
        let pixels = max(16, Int(side.rounded()))
        let image = NSImage(size: NSSize(width: pixels / 2, height: pixels / 2), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            draw(in: context, rect: rect)
            return true
        }
        cache[side] = image
        return image
    }

    private static func draw(in context: CGContext, rect: CGRect) {
        context.setShouldAntialias(true)
        let plate = rect
        let radius = plate.width * 0.2237
        let path = CGPath(roundedRect: plate, cornerWidth: radius, cornerHeight: radius,
                          transform: nil)

        context.saveGState()
        context.addPath(path)
        context.clip()
        let space = CGColorSpaceCreateDeviceRGB()
        let start = CGColor(colorSpace: space, components: [0.33, 0.42, 0.98, 1])!
        let end = CGColor(colorSpace: space, components: [0.52, 0.22, 0.85, 1])!
        if let gradient = CGGradient(colorsSpace: space, colors: [start, end] as CFArray,
                                     locations: [0, 1]) {
            context.drawLinearGradient(gradient,
                                       start: CGPoint(x: plate.minX, y: plate.maxY),
                                       end: CGPoint(x: plate.maxX, y: plate.minY),
                                       options: [])
        }
        context.restoreGState()

        context.setFillColor(NSColor.white.cgColor)
        BittMark.fillGlyph(in: context,
                            centre: CGPoint(x: plate.midX, y: plate.midY),
                            radius: plate.width * 0.325)
    }
}
