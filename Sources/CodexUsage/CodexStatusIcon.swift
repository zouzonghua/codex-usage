import AppKit

enum CodexStatusIcon {
    private static let size = NSSize(width: 18, height: 18)
    private static let scale: CGFloat = 2

    static func image(primaryRemaining: Int?, weeklyRemaining: Int?) -> NSImage {
        let image = NSImage(size: Self.size)
        let pixels = Int(Self.size.width * Self.scale)

        if let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0)
        {
            bitmap.size = Self.size
            image.addRepresentation(bitmap)

            NSGraphicsContext.saveGraphicsState()
            if let context = NSGraphicsContext(bitmapImageRep: bitmap) {
                NSGraphicsContext.current = context
                Self.draw(primaryRemaining: primaryRemaining, weeklyRemaining: weeklyRemaining)
            }
            NSGraphicsContext.restoreGraphicsState()
        } else {
            image.lockFocus()
            Self.draw(primaryRemaining: primaryRemaining, weeklyRemaining: weeklyRemaining)
            image.unlockFocus()
        }

        image.isTemplate = true
        return image
    }

    private static func draw(primaryRemaining: Int?, weeklyRemaining: Int?) {
        let color = NSColor.labelColor
        let primaryRect = NSRect(x: 2, y: 2, width: 6, height: 14)
        let weeklyRect = NSRect(x: 10, y: 2, width: 6, height: 14)

        Self.drawMeter(primaryRect, remaining: primaryRemaining, color: color)
        Self.drawMeter(weeklyRect, remaining: weeklyRemaining, color: color)
    }

    private static func drawMeter(_ rect: NSRect, remaining: Int?, color: NSColor) {
        let radius = min(rect.width, rect.height) / 2
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        color.withAlphaComponent(0.28).setFill()
        path.fill()
        color.withAlphaComponent(0.44).setStroke()
        path.lineWidth = 0.5
        path.stroke()

        guard let remaining else { return }
        let clamped = CGFloat(max(0, min(remaining, 100))) / 100
        guard clamped > 0 else { return }

        let fillRect = NSRect(
            x: rect.minX,
            y: rect.minY,
            width: rect.width,
            height: rect.height * clamped)
        NSGraphicsContext.current?.cgContext.saveGState()
        path.addClip()
        color.setFill()
        NSBezierPath(rect: fillRect).fill()
        NSGraphicsContext.current?.cgContext.restoreGState()
    }
}
