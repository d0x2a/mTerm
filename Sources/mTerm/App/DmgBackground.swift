import AppKit

/// Programmatic background image for the release DMG window. Matches the
/// AppIcon's aesthetic (dark slate gradient, mint accent) so the install
/// experience feels cohesive with the app.
///
/// The DMG window is 600 × 400 pt; we render both 1x and 2x and the build
/// script packs them into a HiDPI .tiff via `tiffutil -cathidpicheck`.
enum DmgBackground {
    static let logicalSize = NSSize(width: 600, height: 400)

    static func exportBackgrounds(to directory: String) {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: directory)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        write(scale: 1, to: dir.appendingPathComponent("background.png"))
        write(scale: 2, to: dir.appendingPathComponent("background@2x.png"))
    }

    private static func write(scale: Int, to url: URL) {
        let pixelW = Int(logicalSize.width) * scale
        let pixelH = Int(logicalSize.height) * scale
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelW, pixelsHigh: pixelH,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ) else { return }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        // Draw in logical (point) coords; the CTM scale gives us crisp @2x.
        NSGraphicsContext.current?.cgContext.scaleBy(x: CGFloat(scale),
                                                     y: CGFloat(scale))
        draw(in: NSRect(origin: .zero, size: logicalSize))
        NSGraphicsContext.restoreGraphicsState()

        guard let data = rep.representation(using: .png, properties: [:])
        else { return }
        try? data.write(to: url)
    }

    private static func draw(in rect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // 1. Background: dark slate at top fading to near-black at bottom.
        let bg = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                NSColor(srgbRed: 0.122, green: 0.141, blue: 0.168, alpha: 1).cgColor,
                NSColor(srgbRed: 0.039, green: 0.047, blue: 0.066, alpha: 1).cgColor,
            ] as CFArray,
            locations: [0, 1]
        )!
        ctx.drawLinearGradient(
            bg,
            start: CGPoint(x: rect.midX, y: rect.maxY),
            end:   CGPoint(x: rect.midX, y: rect.minY),
            options: []
        )

        // 2. Subtle vignette in the corners.
        let vignette = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                NSColor(white: 0, alpha: 0.0).cgColor,
                NSColor(white: 0, alpha: 0.35).cgColor,
            ] as CFArray,
            locations: [0.55, 1]
        )!
        ctx.drawRadialGradient(
            vignette,
            startCenter: CGPoint(x: rect.midX, y: rect.midY),
            startRadius: 0,
            endCenter: CGPoint(x: rect.midX, y: rect.midY),
            endRadius: rect.width * 0.6,
            options: []
        )

        // 3. Right-pointing mint chevron between where the two icons sit.
        //    create-dmg places icons at y=200 (top-down). In our CG y-up
        //    space that's also y=200 for a 400-tall canvas — happens to
        //    line up because the canvas is symmetric, but write it
        //    explicitly anyway.
        let iconYFromTop: CGFloat = 200
        let arrowCenter = CGPoint(x: rect.midX,
                                  y: rect.height - iconYFromTop)
        drawArrow(at: arrowCenter, in: ctx)

        // 4. Subtle wordmark in the lower-right corner.
        drawWordmark(in: rect)
    }

    private static func drawArrow(at center: CGPoint, in ctx: CGContext) {
        let accent = NSColor(srgbRed: 0.211, green: 0.965, blue: 0.286, alpha: 0.55)
        ctx.setStrokeColor(accent.cgColor)
        ctx.setLineWidth(2.5)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        let length: CGFloat = 70
        let head: CGFloat   = 14

        let path = CGMutablePath()
        path.move(to: CGPoint(x: center.x - length / 2, y: center.y))
        path.addLine(to: CGPoint(x: center.x + length / 2, y: center.y))
        path.move(to: CGPoint(x: center.x + length / 2 - head, y: center.y + head))
        path.addLine(to: CGPoint(x: center.x + length / 2, y: center.y))
        path.addLine(to: CGPoint(x: center.x + length / 2 - head, y: center.y - head))

        ctx.addPath(path)
        ctx.strokePath()
    }

    private static func drawWordmark(in rect: NSRect) {
        let text = "mTerm"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor(white: 1, alpha: 0.22),
            .kern: 1.2,
        ]
        let attributed = NSAttributedString(string: text, attributes: attrs)
        let size = attributed.size()
        let origin = CGPoint(
            x: rect.maxX - size.width - 18,
            y: 14
        )
        attributed.draw(at: origin)
    }
}
