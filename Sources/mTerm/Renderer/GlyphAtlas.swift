import CoreGraphics
import CoreText
import Metal
import simd

struct GlyphEntry {
    var atlasOrigin: SIMD2<Float>
    var atlasSize: SIMD2<Float>
    var bearing: SIMD2<Float>
    var advance: Float
    /// Lives in the color atlas rather than the coverage one. Emoji fonts are
    /// color bitmaps, so their glyphs carry their own pixels instead of a mask
    /// to tint with the cell's foreground.
    var isColor: Bool = false
}

private struct GlyphKey: Hashable {
    let fontID: ObjectIdentifier
    let glyph: CGGlyph
}

private struct Resolved {
    let font: CTFont
    let glyph: CGGlyph
    let isColor: Bool
}

/// Shelf packer state. Each atlas keeps its own — they fill independently.
private struct Shelf {
    let width: Int
    let height: Int
    let pad: Int
    var y = 0
    var rowHeight = 0
    var x = 0

    mutating func alloc(w: Int, h: Int) -> (Int, Int)? {
        let stride = w + pad
        if x + stride > width {
            y += rowHeight + pad
            rowHeight = 0
            x = 0
        }
        if y + h > height { return nil }
        let pos = (x, y)
        x += stride
        rowHeight = max(rowHeight, h)
        return pos
    }
}

final class GlyphAtlas {
    let texture: MTLTexture
    /// RGBA companion for color-bitmap glyphs (Apple Color Emoji). Kept apart
    /// from the coverage atlas so ordinary text stays one byte per pixel.
    let colorTexture: MTLTexture
    let font: CTFont
    let width: Int
    let height: Int
    let colorWidth: Int
    let colorHeight: Int
    /// 0.0 = no stem-darkening (pure CoreText AA, can look too thin on
    /// dark themes). 1.0 ≈ macOS's old CG font-smoothing dilation. The
    /// rasterizer always renders without CG smoothing and then applies a
    /// gamma curve to the alpha bitmap whose strength is keyed off this
    /// value, giving a continuous "thin → bold" knob.
    let strokeWeight: Double

    /// Atlas entries are keyed by (fontID, glyph). CGGlyph IDs are font-local,
    /// so once we start using fallback fonts for missing glyphs (e.g. ➜ which
    /// SF Mono doesn't carry) we have to disambiguate by font.
    private var entries: [GlyphKey: GlyphEntry] = [:]
    /// Cached per-scalar resolution. nil = known-missing across primary + fallback.
    private var scalarToResolved: [UInt32: Resolved?] = [:]
    /// Direct-mapped fast path for ASCII, which is very nearly everything a
    /// terminal draws. The general path costs two dictionary probes per glyph
    /// per *frame* — scalar → resolved font, then (font, glyph) → atlas entry —
    /// and at a screenful of text per frame that dominated the atlas's share of
    /// the frame build. Only successful lookups are cached: a glyph that came
    /// back nil because the atlas was momentarily full still retries later,
    /// exactly as it did before.
    private var asciiEntries = [GlyphEntry?](repeating: nil, count: 128)
    /// Extra blank pixels around each glyph in the atlas. 2px (not 1) so the
    /// sub-pixel offset baked into the rasterization (see `rasterize`) can't
    /// push anti-aliased pixels past the bitmap edge.
    private static let pad = 2
    private let pad = GlyphAtlas.pad
    private var shelf: Shelf
    private var colorShelf: Shelf

    /// Per-pixel alpha remap for the strokeWeight gamma boost. nil when
    /// strokeWeight == 0 (the no-op case skips the post-process entirely).
    private let strokeLUT: [UInt8]?

    init(device: MTLDevice, font: CTFont, strokeWeight: Double,
         width: Int = 2048, height: Int = 2048,
         colorWidth: Int = 1024, colorHeight: Int = 1024) {
        self.font = font
        self.strokeWeight = strokeWeight
        self.width = width
        self.height = height
        self.colorWidth = colorWidth
        self.colorHeight = colorHeight
        self.shelf = Shelf(width: width, height: height, pad: GlyphAtlas.pad)
        self.colorShelf = Shelf(width: colorWidth, height: colorHeight, pad: GlyphAtlas.pad)

        if strokeWeight > 0 {
            let exponent = 1.0 - 0.5 * strokeWeight
            var table = [UInt8](repeating: 0, count: 256)
            for i in 0..<256 {
                let v = Double(i) / 255.0
                let boosted = pow(v, exponent)
                table[i] = UInt8(min(255, Int(boosted * 255 + 0.5)))
            }
            self.strokeLUT = table
        } else {
            self.strokeLUT = nil
        }

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

        // Emoji are far rarer than text, so the color atlas is a quarter the
        // side length — still room for hundreds of glyphs at 4 bytes each.
        let colorDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: colorWidth, height: colorHeight,
            mipmapped: false
        )
        colorDesc.usage = [.shaderRead]
        colorDesc.storageMode = .shared
        guard let colorTex = device.makeTexture(descriptor: colorDesc) else {
            fatalError("could not create color glyph atlas texture")
        }
        let colorZero = [UInt8](repeating: 0, count: colorWidth * colorHeight * 4)
        colorZero.withUnsafeBufferPointer { ptr in
            colorTex.replace(
                region: MTLRegionMake2D(0, 0, colorWidth, colorHeight),
                mipmapLevel: 0,
                withBytes: ptr.baseAddress!,
                bytesPerRow: colorWidth * 4
            )
        }
        self.colorTexture = colorTex
    }

    func entry(for scalar: Unicode.Scalar) -> GlyphEntry? {
        let value = scalar.value
        if value < 128, let cached = asciiEntries[Int(value)] { return cached }
        let entry = resolvedEntry(for: scalar)
        if value < 128, let entry { asciiEntries[Int(value)] = entry }
        return entry
    }

    /// The general two-dictionary path, for anything the ASCII cache can't answer.
    private func resolvedEntry(for scalar: Unicode.Scalar) -> GlyphEntry? {
        if let cached = scalarToResolved[scalar.value] {
            guard let r = cached else { return nil }
            return entry(font: r.font, glyph: r.glyph, isColor: r.isColor)
        }

        let resolved = resolve(scalar: scalar)
        scalarToResolved[scalar.value] = resolved
        guard let r = resolved else { return nil }
        return entry(font: r.font, glyph: r.glyph, isColor: r.isColor)
    }

    private func entry(font: CTFont, glyph: CGGlyph, isColor: Bool) -> GlyphEntry? {
        let key = GlyphKey(fontID: ObjectIdentifier(font), glyph: glyph)
        if let cached = entries[key] { return cached }
        return rasterize(font: font, glyph: glyph, isColor: isColor)
    }

    /// Looks a scalar up in the primary font, then in whatever CoreText
    /// nominates as a fallback (➜ U+279C is missing from SF Mono; emoji are
    /// missing from every text font).
    ///
    /// Glyph lookup is by UTF-16, so a scalar above U+FFFF needs *both* units
    /// of its surrogate pair passed together — CoreText answers with the glyph
    /// in the first slot and 0 in the second. Asking with a single UniChar,
    /// as this used to, cannot express those scalars at all, which is why every
    /// emoji above the BMP went missing.
    private func resolve(scalar: Unicode.Scalar) -> Resolved? {
        let units = Array(String(scalar).utf16)
        var chars = units
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        CTFontGetGlyphsForCharacters(font, &chars, &glyphs, units.count)
        if glyphs[0] != 0 {
            return Resolved(font: font, glyph: glyphs[0], isColor: false)
        }
        let s = String(scalar) as NSString
        let range = CFRangeMake(0, s.length)
        let fallback = CTFontCreateForString(font, s, range)
        var fbChars = units
        var fbGlyphs = [CGGlyph](repeating: 0, count: units.count)
        CTFontGetGlyphsForCharacters(fallback, &fbChars, &fbGlyphs, units.count)
        if fbGlyphs[0] == 0 { return nil }
        let traits = CTFontGetSymbolicTraits(fallback)
        return Resolved(font: fallback, glyph: fbGlyphs[0],
                        isColor: traits.contains(.traitColorGlyphs))
    }

    private func rasterize(font: CTFont, glyph: CGGlyph, isColor: Bool) -> GlyphEntry? {
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
                bearing: .zero, advance: Float(advance.width), isColor: isColor
            )
            entries[key] = entry
            return entry
        }

        // Color glyphs carry their own pixels, so they need real RGBA. Text
        // stays a one-byte coverage mask to be tinted with the cell's color.
        let ctx: CGContext?
        if isColor {
            ctx = CGContext(
                data: nil,
                width: bitmapW, height: bitmapH,
                bitsPerComponent: 8,
                bytesPerRow: bitmapW * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        } else {
            ctx = CGContext(
                data: nil,
                width: bitmapW, height: bitmapH,
                bitsPerComponent: 8,
                bytesPerRow: bitmapW,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
            )
        }
        guard let ctx else { return nil }

        ctx.setShouldAntialias(true)
        // We never use CG's font smoothing (it's a binary on/off knob); the
        // strokeWeight gamma pass below provides a continuous equivalent.
        ctx.setShouldSmoothFonts(false)
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
        guard let (ax, ay) = (isColor ? colorShelf.alloc(w: bitmapW, h: bitmapH)
                                      : shelf.alloc(w: bitmapW, h: bitmapH))
        else { return nil }

        let bytesPerRow = ctx.bytesPerRow

        // Stroke-weight gamma boost: push the AA edge coverage toward 1
        // so soft edges read as thicker. Skipped entirely at weight 0, and
        // never applied to color glyphs — there's no coverage to thicken.
        if let lut = strokeLUT, !isColor {
            let buf = data.assumingMemoryBound(to: UInt8.self)
            lut.withUnsafeBufferPointer { lutPtr in
                let lutBase = lutPtr.baseAddress!
                for y in 0..<bitmapH {
                    let rowStart = y * bytesPerRow
                    for x in 0..<bitmapW {
                        buf[rowStart + x] = lutBase[Int(buf[rowStart + x])]
                    }
                }
            }
        }

        (isColor ? colorTexture : texture).replace(
            region: MTLRegionMake2D(ax, ay, bitmapW, bitmapH),
            mipmapLevel: 0,
            withBytes: data,
            bytesPerRow: bytesPerRow
        )

        let entry = GlyphEntry(
            atlasOrigin: SIMD2<Float>(Float(ax), Float(ay)),
            atlasSize: SIMD2<Float>(Float(bitmapW), Float(bitmapH)),
            bearing: SIMD2<Float>(bearingXInt, bearingYInt),
            advance: Float(advance.width),
            isColor: isColor
        )
        entries[key] = entry
        return entry
    }

}
