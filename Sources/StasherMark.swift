import AppKit

enum StasherMark {
    static func templateImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { bounds in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            draw(in: context, bounds: bounds, color: CGColor(gray: 0, alpha: 1))
            return true
        }
        image.isTemplate = true
        return image
    }

    static func draw(in context: CGContext, bounds: CGRect, color: CGColor) {
        let scale = min(bounds.width, bounds.height) / 24
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: bounds.midX - 12 * scale, y: bounds.midY - 12 * scale)
        context.scaleBy(x: scale, y: scale)
        context.setStrokeColor(color)
        context.setFillColor(color)
        context.setLineJoin(.round)
        context.setLineCap(.round)
        context.setLineWidth(1.9)

        let shield = CGMutablePath()
        shield.move(to: CGPoint(x: 12, y: 22))
        shield.addLine(to: CGPoint(x: 20.3, y: 19.3))
        shield.addLine(to: CGPoint(x: 20.3, y: 12))
        shield.addQuadCurve(to: CGPoint(x: 12, y: 2.1), control: CGPoint(x: 20.3, y: 6.2))
        shield.addQuadCurve(to: CGPoint(x: 3.7, y: 12), control: CGPoint(x: 3.7, y: 6.2))
        shield.addLine(to: CGPoint(x: 3.7, y: 19.3))
        shield.closeSubpath()
        context.addPath(shield)
        context.strokePath()

        let shackle = CGMutablePath()
        shackle.move(to: CGPoint(x: 9.3, y: 12.5))
        shackle.addLine(to: CGPoint(x: 9.3, y: 14.4))
        shackle.addQuadCurve(to: CGPoint(x: 12, y: 17.1), control: CGPoint(x: 9.3, y: 17.1))
        shackle.addQuadCurve(to: CGPoint(x: 14.7, y: 14.4), control: CGPoint(x: 14.7, y: 17.1))
        shackle.addLine(to: CGPoint(x: 14.7, y: 12.5))
        context.setLineWidth(1.65)
        context.addPath(shackle)
        context.strokePath()

        let lock = CGMutablePath()
        lock.addRoundedRect(in: CGRect(x: 7.6, y: 7.8, width: 8.8, height: 5.8),
                            cornerWidth: 1.65, cornerHeight: 1.65)
        lock.addRoundedRect(in: CGRect(x: 11.35, y: 9.4, width: 1.3, height: 2.6),
                            cornerWidth: 0.65, cornerHeight: 0.65)
        context.addPath(lock)
        context.fillPath(using: .evenOdd)
    }
}
