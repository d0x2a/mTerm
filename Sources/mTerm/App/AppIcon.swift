import AppKit

/// Programmatic mTerm app icon.
///
/// Rendered as a resolution-independent NSImage so it stays crisp at every
/// dock / cmd-tab / about-panel size without shipping a `.icns` resource.
enum AppIcon {
    static func make() -> NSImage {
        let size = NSSize(width: 1024, height: 1024)
        let image = NSImage(size: size, flipped: false) { rect in
            draw(in: rect)
            return true
        }
        // Treat as a template-free regular icon (the dock should not tint it).
        image.isTemplate = false
        return image
    }

    /// Renders the icon at every size macOS expects in an `.iconset` bundle,
    /// writing PNGs into `directory`. The caller is expected to run `iconutil
    /// -c icns <directory>` to pack the result into a single `.icns`.
    static func exportIconset(to directory: String) {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: directory)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        // (logical size in points, scale factor). macOS Icon Composer wants
        // both @1x and @2x for each canonical size.
        let entries: [(Int, Int)] = [
            (16, 1), (16, 2),
            (32, 1), (32, 2),
            (128, 1), (128, 2),
            (256, 1), (256, 2),
            (512, 1), (512, 2),
        ]

        let image = make()
        for (base, scale) in entries {
            let pixels = base * scale
            let suffix = scale == 1 ? "" : "@2x"
            let filename = "icon_\(base)x\(base)\(suffix).png"
            let url = dir.appendingPathComponent(filename)

            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: pixels, pixelsHigh: pixels,
                bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0
            ) else { continue }

            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
            NSGraphicsContext.restoreGraphicsState()

            guard let data = rep.representation(using: .png, properties: [:])
            else { continue }
            try? data.write(to: url)
        }
    }

    private static func draw(in rect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let s = rect.width // assume square

        // macOS icons inset content so the squircle doesn't fill the tile.
        // 1024-pt grid contents live in the central ~824-pt square.
        let inset: CGFloat = s * 0.09765625
        let tile = rect.insetBy(dx: inset, dy: inset)
        let corner: CGFloat = tile.width * 0.2237

        // --- Background squircle ----------------------------------------------
        let bgPath = NSBezierPath(roundedRect: tile,
                                  xRadius: corner, yRadius: corner)
        ctx.saveGState()
        bgPath.addClip()

        let bgGradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                NSColor(srgbRed: 0.156, green: 0.176, blue: 0.211, alpha: 1).cgColor,
                NSColor(srgbRed: 0.039, green: 0.047, blue: 0.066, alpha: 1).cgColor,
            ] as CFArray,
            locations: [0, 1]
        )!
        ctx.drawLinearGradient(
            bgGradient,
            start: CGPoint(x: tile.midX, y: tile.maxY),
            end:   CGPoint(x: tile.midX, y: tile.minY),
            options: []
        )

        // Soft top highlight — feels lit from above.
        let highlight = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                NSColor(white: 1, alpha: 0.10).cgColor,
                NSColor(white: 1, alpha: 0.0).cgColor,
            ] as CFArray,
            locations: [0, 1]
        )!
        ctx.drawLinearGradient(
            highlight,
            start: CGPoint(x: tile.midX, y: tile.maxY),
            end:   CGPoint(x: tile.midX, y: tile.midY),
            options: []
        )

        // Vignette in the bottom corners.
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
            startCenter: CGPoint(x: tile.midX, y: tile.midY),
            startRadius: 0,
            endCenter: CGPoint(x: tile.midX, y: tile.midY),
            endRadius: tile.width * 0.7,
            options: []
        )

        ctx.restoreGState()

        // Inner rim highlight (1pt @ 1024 scaled to size).
        ctx.saveGState()
        let rimPath = NSBezierPath(
            roundedRect: tile.insetBy(dx: 0.75, dy: 0.75),
            xRadius: corner - 0.75, yRadius: corner - 0.75
        )
        rimPath.lineWidth = max(1, s / 1024 * 1.5)
        NSColor(white: 1, alpha: 0.07).setStroke()
        rimPath.stroke()
        ctx.restoreGState()

        // --- Foreground: m + cursor block -------------------------------------
        // Classic phosphor console green.
        let accent = NSColor(srgbRed: 0.211, green: 0.965, blue: 0.286, alpha: 1)
        let accentSoft = NSColor(srgbRed: 0.211, green: 0.965, blue: 0.286, alpha: 0.20)

        // Geometric "m": two arches sharing a common stem rhythm. Drawn as a
        // stroked path so the weight stays consistent regardless of size.
        let glyphHeight = tile.height * 0.36
        let glyphWidth  = glyphHeight * 1.32
        let stroke      = glyphHeight * 0.22

        // Total composition: [ m  ][gap][cursor]
        let cursorWidth = stroke * 1.05
        let gap = stroke * 0.85
        let totalWidth = glyphWidth + gap + cursorWidth

        let originX = tile.midX - totalWidth / 2
        let baseY   = tile.midY - glyphHeight / 2

        let mRect = NSRect(x: originX, y: baseY,
                           width: glyphWidth, height: glyphHeight)

        // Soft glow behind the glyph for depth.
        ctx.saveGState()
        ctx.setShadow(
            offset: .zero,
            blur: stroke * 1.6,
            color: accentSoft.cgColor
        )

        let mPath = makeMPath(in: mRect, strokeWidth: stroke)
        accent.setStroke()
        mPath.lineWidth = stroke
        mPath.lineCapStyle = .round
        mPath.lineJoinStyle = .round
        mPath.stroke()

        // Cursor block, baseline-aligned with the m.
        let cursorX = originX + glyphWidth + gap
        let cursorHeight = glyphHeight * 0.78
        let cursorRect = NSRect(
            x: cursorX,
            y: baseY,
            width: cursorWidth,
            height: cursorHeight
        )
        let cursorPath = NSBezierPath(
            roundedRect: cursorRect,
            xRadius: cursorWidth * 0.18,
            yRadius: cursorWidth * 0.18
        )
        accent.setFill()
        cursorPath.fill()
        ctx.restoreGState()
    }

    /// Builds a stroked "m" shape: a flat bottom with two arches on top,
    /// each arch rising to the cap-height. Stem width is implicit in the
    /// stroke width supplied by the caller.
    private static func makeMPath(in rect: NSRect, strokeWidth: CGFloat) -> NSBezierPath {
        // Inset so the stroke sits fully inside `rect`.
        let r = rect.insetBy(dx: strokeWidth / 2, dy: strokeWidth / 2)

        let archHeight = r.height
        let archRadius = r.width / 4 // two equal arches => four "stem-half" widths

        let path = NSBezierPath()

        // Left stem: from bottom-left up to the start of the first arch.
        path.move(to: NSPoint(x: r.minX, y: r.minY))
        path.line(to: NSPoint(x: r.minX, y: r.minY + archHeight - archRadius))

        // First arch: quarter-curve up, quarter-curve down.
        path.curve(
            to: NSPoint(x: r.minX + archRadius, y: r.maxY),
            controlPoint1: NSPoint(x: r.minX, y: r.maxY - archRadius * 0.45),
            controlPoint2: NSPoint(x: r.minX + archRadius * 0.55, y: r.maxY)
        )
        path.curve(
            to: NSPoint(x: r.minX + archRadius * 2, y: r.minY + archHeight - archRadius),
            controlPoint1: NSPoint(x: r.minX + archRadius * 1.45, y: r.maxY),
            controlPoint2: NSPoint(x: r.minX + archRadius * 2, y: r.maxY - archRadius * 0.45)
        )

        // Center stem drop — the dip between the two humps.
        path.line(to: NSPoint(x: r.minX + archRadius * 2, y: r.minY))
        path.move(to: NSPoint(x: r.minX + archRadius * 2, y: r.minY + archHeight - archRadius))

        // Second arch, mirroring the first.
        path.curve(
            to: NSPoint(x: r.minX + archRadius * 3, y: r.maxY),
            controlPoint1: NSPoint(x: r.minX + archRadius * 2, y: r.maxY - archRadius * 0.45),
            controlPoint2: NSPoint(x: r.minX + archRadius * 2.55, y: r.maxY)
        )
        path.curve(
            to: NSPoint(x: r.maxX, y: r.minY + archHeight - archRadius),
            controlPoint1: NSPoint(x: r.minX + archRadius * 3.45, y: r.maxY),
            controlPoint2: NSPoint(x: r.maxX, y: r.maxY - archRadius * 0.45)
        )

        // Right stem.
        path.line(to: NSPoint(x: r.maxX, y: r.minY))

        return path
    }
}
