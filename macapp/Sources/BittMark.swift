import CoreGraphics
import Foundation

/// The BITT logo, drawn with CoreGraphics so one definition serves the app
/// icon, the menu bar icon and anywhere else the mark is needed.
///
/// The mark is a hexagon — the swarm — with a download arrow knocked out of it
/// in negative space. A solid silhouette with a hole stays readable at 16pt,
/// where fine strokes would turn to mush.
enum BittMark {

    /// Six vertices, point-up, so the shape leads the eye down to the arrow.
    static func hexagon(centre: CGPoint, radius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        for index in 0..<6 {
            let angle = CGFloat.pi / 2 + CGFloat(index) * (.pi / 3)
            let point = CGPoint(x: centre.x + cos(angle) * radius,
                                y: centre.y + sin(angle) * radius)
            index == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        path.closeSubpath()
        return path
    }

    /// The arrow that gets subtracted from the hexagon.
    static func arrow(centre: CGPoint, radius R: CGFloat) -> CGPath {
        let stemHalf = R * 0.190
        let headHalf = R * 0.520
        let top = centre.y + R * 0.530
        let shoulder = centre.y - R * 0.055
        let tip = centre.y - R * 0.610

        let path = CGMutablePath()
        path.move(to: CGPoint(x: centre.x - stemHalf, y: top))
        path.addLine(to: CGPoint(x: centre.x + stemHalf, y: top))
        path.addLine(to: CGPoint(x: centre.x + stemHalf, y: shoulder))
        path.addLine(to: CGPoint(x: centre.x + headHalf, y: shoulder))
        path.addLine(to: CGPoint(x: centre.x, y: tip))
        path.addLine(to: CGPoint(x: centre.x - headHalf, y: shoulder))
        path.addLine(to: CGPoint(x: centre.x - stemHalf, y: shoulder))
        path.closeSubpath()
        return path
    }

    /// Hexagon with the arrow cut out, filled in the context's current colour.
    /// `radius` is the hexagon's circumradius.
    static func fillGlyph(in context: CGContext, centre: CGPoint, radius: CGFloat) {
        let combined = CGMutablePath()
        combined.addPath(hexagon(centre: centre, radius: radius))
        combined.addPath(arrow(centre: centre, radius: radius))
        context.addPath(combined)
        context.fillPath(using: .evenOdd)   // the arrow becomes a hole
    }

    /// Peers orbiting the swarm. Decorative, so only the large icon uses them.
    static func satellites(in context: CGContext, centre: CGPoint, radius R: CGFloat,
                           alpha: (Int) -> CGFloat) {
        let positions: [(angle: CGFloat, scale: CGFloat)] = [
            (0.0, 1.00), (60, 0.66), (120, 0.86), (180, 1.00), (240, 0.66), (300, 0.86),
        ]
        for (index, item) in positions.enumerated() {
            let angle = item.angle * .pi / 180
            let distance = R * 1.34
            let dot = CGPoint(x: centre.x + cos(angle) * distance,
                              y: centre.y + sin(angle) * distance)
            let dotRadius = R * 0.105 * item.scale
            context.setAlpha(alpha(index))
            context.addEllipse(in: CGRect(x: dot.x - dotRadius, y: dot.y - dotRadius,
                                          width: dotRadius * 2, height: dotRadius * 2))
            context.fillPath()
        }
        context.setAlpha(1)
    }
}
