import SwiftUI
import AppKit

/// Draws a crisp macOS menu bar template dragonfly silhouette (18x18pt, auto-adapting to Light/Dark menu bars).
enum DragonflyTrayArtwork {
    static func image(listening: Bool, starting: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: true) { _ in
            NSColor.labelColor.setFill()
            NSColor.labelColor.setStroke()

            let cx: CGFloat = 9.0

            // Upper pair of dragonfly wings (wider, swept gently upward)
            drawWing(cx: cx, anchorY: 5.7, side: -1, length: 7.8, width: 2.55, angleDeg: -14)
            drawWing(cx: cx, anchorY: 5.7, side: 1, length: 7.8, width: 2.55, angleDeg: 14)

            // Lower pair of dragonfly wings (slightly shorter, angled gently downward)
            drawWing(cx: cx, anchorY: 7.6, side: -1, length: 6.7, width: 2.25, angleDeg: 15)
            drawWing(cx: cx, anchorY: 7.6, side: 1, length: 6.7, width: 2.25, angleDeg: -15)

            // Head (distinctive broad dragonfly eyes)
            let head = NSBezierPath(ovalIn: NSRect(x: cx - 1.55, y: 1.8, width: 3.1, height: 2.15))
            head.fill()

            // Thorax
            let thorax = NSBezierPath(ovalIn: NSRect(x: cx - 1.15, y: 3.9, width: 2.3, height: 3.9))
            thorax.fill()

            // Slender tapered abdomen (tail)
            let tail = NSBezierPath()
            tail.move(to: NSPoint(x: cx - 0.75, y: 7.5))
            tail.line(to: NSPoint(x: cx + 0.75, y: 7.5))
            tail.line(to: NSPoint(x: cx + 0.42, y: 15.9))
            tail.curve(to: NSPoint(x: cx - 0.42, y: 15.9),
                       controlPoint1: NSPoint(x: cx + 0.35, y: 16.7),
                       controlPoint2: NSPoint(x: cx - 0.35, y: 16.7))
            tail.close()
            tail.fill()

            if listening {
                // Subtle acoustic wave arcs flanking the slender tail while actively listening
                for (dx, r) in [(-2.6, 2.0), (-4.2, 3.2), (2.6, 2.0), (4.2, 3.2)] as [(CGFloat, CGFloat)] {
                    let isLeft = dx < 0
                    let arc = NSBezierPath()
                    arc.lineWidth = 1.15
                    arc.lineCapStyle = .round
                    let center = NSPoint(x: cx + (isLeft ? -0.9 : 0.9), y: 13.4)
                    arc.appendArc(
                        withCenter: center,
                        radius: r,
                        startAngle: isLeft ? 140 : -40,
                        endAngle: isLeft ? 220 : 40,
                        clockwise: false
                    )
                    arc.stroke()
                }
            } else if starting {
                // Small indicator dot near the tail tip while starting
                let dot = NSBezierPath(ovalIn: NSRect(x: cx + 2.4, y: 12.6, width: 2.2, height: 2.2))
                dot.fill()
            }

            return true
        }
        image.isTemplate = true
        return image
    }

    private static func drawWing(cx: CGFloat, anchorY: CGFloat, side: CGFloat, length: CGFloat, width: CGFloat, angleDeg: CGFloat) {
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: cx + side * 0.65, yBy: anchorY)
        transform.rotate(byDegrees: angleDeg)
        transform.concat()

        // Graceful teardrop wing silhouette: narrow at thorax attachment, gently rounded toward tip
        let path = NSBezierPath()
        let tipX = side * length
        let midX = side * (length * 0.56)
        let halfW = width * 0.5
        path.move(to: NSPoint(x: 0, y: 0))
        path.curve(
            to: NSPoint(x: tipX, y: 0),
            controlPoint1: NSPoint(x: side * (length * 0.28), y: -halfW * 1.15),
            controlPoint2: NSPoint(x: midX + side * (length * 0.36), y: -halfW * 1.1)
        )
        path.curve(
            to: NSPoint(x: 0, y: 0),
            controlPoint1: NSPoint(x: midX + side * (length * 0.36), y: halfW * 1.1),
            controlPoint2: NSPoint(x: side * (length * 0.28), y: halfW * 1.15)
        )
        path.close()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

struct DragonflyTrayIcon: View {
    var listening: Bool
    var starting: Bool

    var body: some View {
        Image(nsImage: DragonflyTrayArtwork.image(listening: listening, starting: starting))
            .renderingMode(.template)
            .accessibilityLabel(listening ? "SpikDoum · 듣기 중" : "SpikDoum")
    }
}
