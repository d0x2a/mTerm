import AppKit
import CoreText
import Metal
import QuartzCore
import simd

private struct CellInstance {
    var glyphPos: SIMD2<Float>
    var glyphSize: SIMD2<Float>
    var atlasPos: SIMD2<Float>
    var atlasSize: SIMD2<Float>
    var fgColor: SIMD4<Float>
    /// 1 = sample the color atlas as-is, 0 = tint the coverage atlas with
    /// fgColor. A float because it rides along to the shader as vertex data.
    var isColor: Float
}

private struct FlatInstance {
    var pos: SIMD2<Float>
    var size: SIMD2<Float>
    var color: SIMD4<Float>
}

private struct Uniforms {
    var viewportSize: SIMD2<Float>
    var atlasSize: SIMD2<Float>
    var colorAtlasSize: SIMD2<Float>
}

enum HighlightStyle {
    case background    // full-cell tint behind the glyph
    case underline     // thin line at the bottom of the cell
    case both          // tint + underline
}

/// A colored band the renderer paints between the cell background and the
/// glyph layer. Used for search matches, trigger highlights, etc.
struct HighlightBand {
    let col: Int
    let row: Int       // viewport row
    let length: Int    // in cells
    let color: SIMD4<Float>
    let style: HighlightStyle
}

struct GridLayout {
    let cellWidth: Float       // drawable pixels
    let cellHeight: Float
    let ascent: Float          // baseline offset from the top of the cell
    /// Height of the tight ascent+descent glyph box inside the cell. Equals
    /// cellHeight at line height 1.0; smaller once extra leading is added, and
    /// what row-relative decorations (underlines) anchor to so they stay
    /// attached to the text instead of drifting to the bottom of a tall cell.
    let glyphBoxHeight: Float
    /// Blank pixels inserted above the glyph box (half of the extra leading).
    let glyphBoxTop: Float
    let margin: Float          // minimum padding around the grid
    let scale: Float

    func gridSize(viewportPixels: SIMD2<Float>) -> (cols: Int, rows: Int) {
        let usableW = max(0, viewportPixels.x - 2 * margin)
        let usableH = max(0, viewportPixels.y - 2 * margin)
        let cols = max(1, Int(floor(usableW / cellWidth)))
        let rows = max(1, Int(floor(usableH / cellHeight)))
        return (cols, rows)
    }

    /// Top-left pixel of the cell grid. The grid is centered horizontally in
    /// the viewport (so any sub-cell remainder is split between left and right
    /// padding instead of always piling up on the right) and top-aligned
    /// vertically (terminals fill from the top down).
    func origin(cols: Int, viewportPixels: SIMD2<Float>) -> SIMD2<Float> {
        let gridW = Float(cols) * cellWidth
        // Floor so the grid lands on a pixel boundary (otherwise the /2
        // can produce a half-pixel x when viewport-gridW is odd, which
        // re-introduces sub-pixel sampling that nearest-filter can't hide).
        let x = max(margin, floor((viewportPixels.x - gridW) / 2))
        return SIMD2<Float>(x, margin)
    }
}

final class Renderer {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let glyphPipeline: MTLRenderPipelineState
    private let flatPipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private let glyphAtlas: GlyphAtlas
    private let font: CTFont

    let layout: GridLayout

    private var glyphBuffer: MTLBuffer?
    private var glyphCapacity = 0
    private var flatBuffer: MTLBuffer?
    private var flatCapacity = 0

    init(device: MTLDevice, pixelFormat: MTLPixelFormat, scale: CGFloat,
         fontFamily: String = FontCatalog.defaultFamily,
         fontSize: Double = 14,
         strokeWeight: Double = 0.5,
         lineHeight: Double = 1.15) {
        self.device = device
        guard let queue = device.makeCommandQueue() else {
            fatalError("could not create Metal command queue")
        }
        self.commandQueue = queue

        let nsFont = FontCatalog.makeFont(family: fontFamily, size: fontSize, scale: scale)
        let font: CTFont = nsFont
        self.font = font

        // Round the ascent to an integer so the per-row baseline lands on a
        // pixel boundary (combined with integer cellHeight + integer grid
        // origin, this is what lets us use nearest sampling on the atlas).
        //
        // The natural cell height intentionally excludes CTFontGetLeading.
        // CoreText's "leading" is the recommended whitespace between lines for
        // body text — it makes a terminal feel airy compared to iTerm2 /
        // Alacritty. Users who want that air back dial in `lineHeight`, which
        // multiplies the tight ascent+descent box; the extra pixels are split
        // above and below the glyph so rows stay optically centered.
        let ascent = Float(CTFontGetAscent(font)).rounded()
        let descent = Float(CTFontGetDescent(font))
        let naturalHeight = ceil(ascent + descent)
        let cellHeight = ceil(naturalHeight * Float(max(1.0, lineHeight)))
        // Floor the half so the baseline stays on an integer pixel; the odd
        // leftover pixel lands below the glyph, where it's least noticeable.
        let topPadding = ((cellHeight - naturalHeight) / 2).rounded(.down)
        let baselineAscent = ascent + topPadding

        var charM: UniChar = 0x4D
        var glyphM: CGGlyph = 0
        CTFontGetGlyphsForCharacters(font, &charM, &glyphM, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyphM, &advance, 1)
        let cellWidth = ceil(Float(advance.width))

        self.layout = GridLayout(
            cellWidth: cellWidth,
            cellHeight: cellHeight,
            ascent: baselineAscent,
            glyphBoxHeight: naturalHeight,
            glyphBoxTop: topPadding,
            margin: 8 * Float(scale),
            scale: Float(scale)
        )

        self.glyphAtlas = GlyphAtlas(device: device, font: font,
                                     strokeWeight: strokeWeight)

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: Shaders.source, options: nil)
        } catch {
            fatalError("could not compile shaders: \(error)")
        }
        self.glyphPipeline = Self.makePipeline(
            device: device, library: library, pixelFormat: pixelFormat,
            vertexName: "gridVertex", fragmentName: "gridFragment", blended: true
        )
        self.flatPipeline = Self.makePipeline(
            device: device, library: library, pixelFormat: pixelFormat,
            vertexName: "flatVertex", fragmentName: "flatFragment", blended: true
        )

        // Nearest filtering: glyph positions are integer-snapped (see
        // GlyphAtlas.rasterize + the integer ascent / origin below), so we
        // want exact texel reads with no bilinear blur.
        let samp = MTLSamplerDescriptor()
        samp.minFilter = .nearest
        samp.magFilter = .nearest
        samp.sAddressMode = .clampToEdge
        samp.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samp) else {
            fatalError("could not create sampler state")
        }
        self.sampler = sampler
    }

    private static func makePipeline(device: MTLDevice,
                                     library: MTLLibrary,
                                     pixelFormat: MTLPixelFormat,
                                     vertexName: String,
                                     fragmentName: String,
                                     blended: Bool) -> MTLRenderPipelineState {
        guard let vfn = library.makeFunction(name: vertexName),
              let ffn = library.makeFunction(name: fragmentName) else {
            fatalError("missing shader functions \(vertexName)/\(fragmentName)")
        }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vfn
        desc.fragmentFunction = ffn
        desc.colorAttachments[0].pixelFormat = pixelFormat
        if blended {
            let att = desc.colorAttachments[0]!
            att.isBlendingEnabled = true
            att.rgbBlendOperation = .add
            att.alphaBlendOperation = .add
            att.sourceRGBBlendFactor = .sourceAlpha
            att.sourceAlphaBlendFactor = .sourceAlpha
            att.destinationRGBBlendFactor = .oneMinusSourceAlpha
            att.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
        do {
            return try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            fatalError("could not create pipeline state for \(vertexName): \(error)")
        }
    }

    private func buildInstances(from snapshot: TerminalSnapshot,
                                selection: Selection?,
                                highlights: [HighlightBand],
                                focused: Bool,
                                cursorOn: Bool,
                                viewportPixels: SIMD2<Float>)
        -> (flat: [FlatInstance], glyphs: [CellInstance]) {
        var flats: [FlatInstance] = []
        var glyphs: [CellInstance] = []
        glyphs.reserveCapacity(snapshot.cells.count / 2)

        let cellWidth = layout.cellWidth
        let cellHeight = layout.cellHeight
        let ascent = layout.ascent
        let origin = layout.origin(cols: snapshot.cols, viewportPixels: viewportPixels)

        let theme = ThemeStore.currentTheme
        let cursorColor = theme.cursor
        let defaultBg = theme.background
        let selectionColor = theme.selection
        // Highlight bands (search matches, trigger highlights) — drawn before
        // selection/cursor so those overlay on top.
        let underlineThickness = max(1, layout.scale)
        let underlineInset     = max(1, layout.scale)
        // Anchored to the glyph box, not the cell, so extra line height pads
        // the row without pushing underlines away from the characters.
        let underlineTop = layout.glyphBoxTop + layout.glyphBoxHeight
            - underlineInset - underlineThickness
        for h in highlights {
            let x = origin.x + Float(h.col) * cellWidth
            let y = origin.y + Float(h.row) * cellHeight
            let w = Float(h.length) * cellWidth
            switch h.style {
            case .background, .both:
                flats.append(FlatInstance(
                    pos: SIMD2<Float>(x, y),
                    size: SIMD2<Float>(w, cellHeight),
                    color: h.color
                ))
            case .underline:
                break
            }
            switch h.style {
            case .underline, .both:
                // Underline color uses the band's RGB but at full opacity, so
                // the line stays visible even when the tint alpha is low.
                let underlineColor = SIMD4<Float>(h.color.x, h.color.y, h.color.z, 1.0)
                flats.append(FlatInstance(
                    pos: SIMD2<Float>(x, y + underlineTop),
                    size: SIMD2<Float>(w, underlineThickness),
                    color: underlineColor
                ))
            case .background:
                break
            }
        }

        for row in 0..<snapshot.rows {
            let baselineY = origin.y + Float(row) * cellHeight + ascent
            let cellTop = origin.y + Float(row) * cellHeight
            for col in 0..<snapshot.cols {
                let cell = snapshot.cells[row * snapshot.cols + col]
                let isCursor = snapshot.cursorVisible
                    && col == snapshot.cursorCol
                    && row == snapshot.cursorRow
                let isSelected = selection?.contains(col: col, row: row) == true
                let cellLeft = origin.x + Float(col) * cellWidth
                let cellRect = (
                    pos: SIMD2<Float>(cellLeft, cellTop),
                    size: SIMD2<Float>(cellWidth, cellHeight)
                )

                // Per-cell flat instances, painted bottom-up: bg → selection → cursor.
                if cell.bg != defaultBg {
                    flats.append(FlatInstance(pos: cellRect.pos, size: cellRect.size, color: cell.bg))
                }
                if isSelected {
                    flats.append(FlatInstance(pos: cellRect.pos, size: cellRect.size, color: selectionColor))
                }
                if isCursor && focused && cursorOn {
                    flats.append(FlatInstance(pos: cellRect.pos, size: cellRect.size, color: cursorColor))
                }
                // Otherwise: unfocused window or "off" half of the blink → no cursor.

                // Glyph: skip blank cells, and the trailing half of a
                // double-width glyph — its head already drew across both cells.
                if cell.isContinuation { continue }
                if cell.scalar == " " { continue }
                guard let entry = glyphAtlas.entry(for: cell.scalar),
                      entry.atlasSize.x > 0 else { continue }

                let glyphPos = SIMD2<Float>(
                    cellLeft + entry.bearing.x,
                    baselineY + entry.bearing.y
                )
                // Glyph color flips to the cell's bg ONLY when a focused filled
                // cursor is drawn on top of it (the classic inverted look).
                let invertGlyph = isCursor && focused && cursorOn
                var glyphFg = invertGlyph ? cell.bg : cell.fg
                // Faint (SGR 2): blend the foreground toward the background,
                // matching how iTerm2 renders dimmed text (e.g. ghost text).
                if cell.attrs.contains(.faint) {
                    glyphFg = mix(glyphFg, cell.bg, t: 0.5)
                }
                glyphs.append(CellInstance(
                    glyphPos: glyphPos,
                    glyphSize: entry.atlasSize,
                    atlasPos: entry.atlasOrigin,
                    atlasSize: entry.atlasSize,
                    fgColor: glyphFg,
                    isColor: entry.isColor ? 1 : 0
                ))
            }
        }

        return (flats, glyphs)
    }


    private func growBuffer<T>(_ buffer: inout MTLBuffer?,
                               capacity: inout Int,
                               count: Int,
                               type: T.Type) {
        if buffer == nil || count > capacity {
            let newCap = max(count, 256)
            buffer = device.makeBuffer(
                length: newCap * MemoryLayout<T>.stride,
                options: .storageModeShared
            )
            capacity = newCap
        }
    }

    private func copyInto<T>(_ buffer: MTLBuffer, _ instances: [T]) {
        instances.withUnsafeBufferPointer { src in
            buffer.contents().copyMemory(
                from: src.baseAddress!,
                byteCount: instances.count * MemoryLayout<T>.stride
            )
        }
    }

    func render(to layer: CAMetalLayer,
                snapshot: TerminalSnapshot,
                selection: Selection?,
                highlights: [HighlightBand],
                focused: Bool,
                cursorOn: Bool) {
        guard let drawable = layer.nextDrawable() else { return }
        let drawableSize = layer.drawableSize

        let viewportPx = SIMD2<Float>(Float(drawableSize.width), Float(drawableSize.height))
        let (flats, glyphs) = buildInstances(from: snapshot,
                                             selection: selection,
                                             highlights: highlights,
                                             focused: focused,
                                             cursorOn: cursorOn,
                                             viewportPixels: viewportPx)

        growBuffer(&flatBuffer, capacity: &flatCapacity, count: flats.count, type: FlatInstance.self)
        growBuffer(&glyphBuffer, capacity: &glyphCapacity, count: glyphs.count, type: CellInstance.self)
        if !flats.isEmpty, let buf = flatBuffer { copyInto(buf, flats) }
        if !glyphs.isEmpty, let buf = glyphBuffer { copyInto(buf, glyphs) }

        var uniforms = Uniforms(
            viewportSize: SIMD2<Float>(Float(drawableSize.width), Float(drawableSize.height)),
            atlasSize: SIMD2<Float>(Float(glyphAtlas.width), Float(glyphAtlas.height)),
            colorAtlasSize: SIMD2<Float>(Float(glyphAtlas.colorWidth),
                                         Float(glyphAtlas.colorHeight))
        )

        let bg = ThemeStore.currentTheme.background
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(bg.x), green: Double(bg.y), blue: Double(bg.z), alpha: Double(bg.w)
        )

        guard let cb = commandQueue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }

        // Flat pass: cell backgrounds + cursor.
        if !flats.isEmpty, let buf = flatBuffer {
            enc.setRenderPipelineState(flatPipeline)
            enc.setVertexBuffer(buf, offset: 0, index: 0)
            enc.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.drawPrimitives(
                type: .triangleStrip,
                vertexStart: 0,
                vertexCount: 4,
                instanceCount: flats.count
            )
        }

        // Glyph pass.
        if !glyphs.isEmpty, let buf = glyphBuffer {
            enc.setRenderPipelineState(glyphPipeline)
            enc.setVertexBuffer(buf, offset: 0, index: 0)
            enc.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.setFragmentTexture(glyphAtlas.texture, index: 0)
            enc.setFragmentTexture(glyphAtlas.colorTexture, index: 1)
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.drawPrimitives(
                type: .triangleStrip,
                vertexStart: 0,
                vertexCount: 4,
                instanceCount: glyphs.count
            )
        }

        enc.endEncoding()
        // The layer uses `presentsWithTransaction`, so the present must be
        // committed by us inside the current CA transaction rather than handed
        // to Core Animation asynchronously: schedule the work, wait for it, then
        // present in-line. This keeps frames in lockstep with layer geometry
        // during live resize.
        cb.commit()
        cb.waitUntilScheduled()
        drawable.present()
    }
}
