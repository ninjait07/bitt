import AppKit

/// The menu bar icon: the BITT mark as a template image, so macOS tints it for
/// light and dark menu bars automatically.
enum StatusIcon {
    static let template: NSImage = {
        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setShouldAntialias(true)
            context.setFillColor(NSColor.black.cgColor)
            BittMark.fillGlyph(in: context,
                                centre: CGPoint(x: rect.midX, y: rect.midY),
                                radius: side * 0.46)
            return true
        }
        image.isTemplate = true
        return image
    }()
}
