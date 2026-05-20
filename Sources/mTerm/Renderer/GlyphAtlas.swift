import CoreGraphics
import CoreText
import Metal
import simd

struct GlyphEntry {
    var atlasOrigin: SIMD2<Float>
    var atlasSize: SIMD2<Float>
    var bearing: SIMD2<Float>
    var advance: Float
}

private struct GlyphKey: Hashable {
    let fontID: ObjectIdentifier
    let glyph: CGGlyph
}

private struct Resolved {
    let font: CTFont
    let glyph: CGGlyph
}

final class GlyphAtlas {
    let texture: MTLTexture
    let font: CTFont
    let width: Int
    let height: Int
    /// When false, glyphs are rasterized without CoreGraphics's stroke-
    /// dilation pass — lighter, "thinner" rendering. iTerm2's "Use thin
    /// strokes" toggle does the same thing.
    let thinStrokes: Bool

    /// Atlas entries are keyed by (fontID, glyph). CGGlyph IDs are font-local,
    /// so once we start using fallback fonts for missing glyphs (e.g. ➜ which
    /// SF Mono doesn't carry) we have to disambiguate by font.
    private var entries: [GlyphKey: GlyphEntry] = [:]
    /// Cached per-scalar resolution. nil = known-missing across primary + fallback.
    private var scalarToResolved: [UInt32: Resolved?] = [:]
    private var shelfY = 0
    private var shelfHeight = 0
    private var xCursor = 0
    /// Extra blank pixels around each glyph in the atlas. 2px (not 1) so the
    /// sub-pixel offset baked into the rasterization (see `rasterize`) can't
    /// push anti-aliased pixels past the bitmap edge.
    private let pad = 2

    init(device: MTLDevice, font: CTFont, thinStrokes: Bool,
         width: Int = 2048, height: Int = 2048) {
        self.font = font
        self.thinStrokes = thinStrokes
        self.width = width
        self.height = height

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: width, height: height,
            mipmapped: false
        )
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else {
            fatalError("could not create glyph atlas texture")
        }
        let zero = [UInt8](repeating: 0, count: width * height)
        zero.withUnsafeBufferPointer { ptr in
            tex.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: ptr.baseAddress!,
                bytesPerRow: width
            )
        }
        self.texture = tex
    }

    func entry(for scalar: Unicode.Scalar) -> GlyphEntry? {
        if scalar.value > UInt32(UInt16.max) { return nil }
        if let cached = scalarToResolved[scalar.value] {
            guard let r = cached else { return nil }
            return entry(font: r.font, glyph: r.glyph)
        }

        let resolved = resolve(scalar: scalar)
        scalarToResolved[scalar.value] = resolved
        guard let r = resolved else { return nil }
        return entry(font: r.font, glyph: r.glyph)
    }

    private func entry(font: CTFont, glyph: CGGlyph) -> GlyphEntry? {
        let key = GlyphKey(fontID: ObjectIdentifier(font), glyph: glyph)
        if let cached = entries[key] { return cached }
        return rasterize(font: font, glyph: glyph)
    }

    private func resolve(scalar: Unicode.Scalar) -> Resolved? {
        var unichar = UniChar(scalar.value)
        var glyph: CGGlyph = 0
        CTFontGetGlyphsForCharacters(font, &unichar, &glyph, 1)
        if glyph != 0 {
            return Resolved(font: font, glyph: glyph)
        }
        // Primary font lacks this scalar. Ask CoreText to find a fallback
        // (e.g. ➜ U+279C is missing from SF Mono, falls back to a symbol font).
        let s = String(scalar) as NSString
        let range = CFRangeMake(0, s.length)
        let fallback = CTFontCreateForString(font, s, range)
        var u = unichar
        var g: CGGlyph = 0
        CTFontGetGlyphsForCharacters(fallback, &u, &g, 1)
        if g == 0 { return nil }
        return Resolved(font: fallback, glyph: g)
    }

    private func rasterize(font: CTFont, glyph: CGGlyph) -> GlyphEntry? {
        var glyphs = [glyph]
        var bounds = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyphs, &bounds, 1)

        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyphs, &advance, 1)

        let bitmapW = Int(ceil(bounds.width)) + 2 * pad
        let bitmapH = Int(ceil(bounds.height)) + 2 * pad

        let key = GlyphKey(fontID: ObjectIdentifier(font), glyph: glyph)

        if bitmapW <= 2 * pad || bitmapH <= 2 * pad {
            let entry = GlyphEntry(
                atlasOrigin: .zero, atlasSize: .zero,
                bearing: .zero, advance: Float(advance.width)
            )
            entries[key] = entry
            return entry
        }

        guard let ctx = CGContext(
            data: nil,
            width: bitmapW, height: bitmapH,
            bitsPerComponent: 8,
            bytesPerRow: bitmapW,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
        ) else { return nil }

        ctx.setShouldAntialias(true)
        // Stroke dilation. CG's "font smoothing" thickens strokes on
        // anti-aliased text. Turning it off matches the iTerm2 "Use thin
        // strokes" look — preferred on Retina, where the dilation is
        // mostly a holdover from non-Retina LCDs.
        ctx.setShouldSmoothFonts(!thinStrokes)
        ctx.setFillColor(CGColor(gray: 1.0, alpha: 1.0))

        // Bearings are the bitmap's offset from the cell origin (X) and from
        // the baseline (Y, screen-Y-down). Their natural values are fractional
        // because CoreText reports fractional `bounds.minX` / `bounds.minY`.
        // Storing fractional bearings means the GPU samples the atlas on
        // sub-pixel positions, which a linear sampler blurs and a nearest
        // sampler jitters by up to 1px.
        //
        // Fix: floor each bearing to an integer (so the blit lands on pixel
        // boundaries) and shift the rasterization position inside the bitmap
        // by the matching fractional amount. CoreText's grayscale AA then
        // captures the sub-pixel position as varying coverage within the
        // integer-pixel bitmap.
        //
        // Y uses `ceil(bounds.height)` (the integer bitmap height) rather
        // than `bounds.height` because the bitmap may have an extra fractional
        // row of blank pixels above the glyph; the baseline's position inside
        // the bitmap depends on the bitmap's integer height, not the glyph's
        // fractional one.
        let bearingXFloat = Float(bounds.minX) - Float(pad)
        let bearingYFloat = -Float(bounds.minY) - Float(ceil(bounds.height)) - Float(pad)
        let bearingXInt = bearingXFloat.rounded(.down)
        let bearingYInt = bearingYFloat.rounded(.down)
        let shiftX = CGFloat(bearingXFloat - bearingXInt) // [0, 1)
        let shiftY = CGFloat(bearingYFloat - bearingYInt) // [0, 1)

        // CG is Y-up: shifting the glyph DOWN in screen-Y-down means
        // DECREASING the CG y origin.
        let originX = -bounds.minX + CGFloat(pad) + shiftX
        let originY = -bounds.minY + CGFloat(pad) - shiftY
        var pos = CGPoint(x: originX, y: originY)
        var g = glyph
        CTFontDrawGlyphs(font, &g, &pos, 1, ctx)

        guard let data = ctx.data else { return nil }
        guard let (ax, ay) = alloc(w: bitmapW, h: bitmapH) else { return nil }

        let bytesPerRow = ctx.bytesPerRow
        texture.replace(
            region: MTLRegionMake2D(ax, ay, bitmapW, bitmapH),
            mipmapLevel: 0,
            withBytes: data,
            bytesPerRow: bytesPerRow
        )

        let entry = GlyphEntry(
            atlasOrigin: SIMD2<Float>(Float(ax), Float(ay)),
            atlasSize: SIMD2<Float>(Float(bitmapW), Float(bitmapH)),
            bearing: SIMD2<Float>(bearingXInt, bearingYInt),
            advance: Float(advance.width)
        )
        entries[key] = entry
        return entry
    }

    private func alloc(w: Int, h: Int) -> (Int, Int)? {
        let stride = w + pad
        if xCursor + stride > width {
            shelfY += shelfHeight + pad
            shelfHeight = 0
            xCursor = 0
        }
        if shelfY + h > height { return nil }
        let pos = (xCursor, shelfY)
        xCursor += stride
        shelfHeight = max(shelfHeight, h)
        return pos
    }
}
