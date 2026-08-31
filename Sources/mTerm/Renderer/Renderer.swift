import AppKit
import CoreText
import Metal
import QuartzCore
import simd

/// One glyph quad. 24 bytes — a full screen is ~8.5k of these, and the frame
/// spends real time writing and uploading them, so the layout is packed:
/// the quad's on-screen size and its atlas footprint are the same rectangle
/// (they always were — `glyphSize` used to be a verbatim copy of `atlasSize`),
/// and 16 bits is ample against a 2048² atlas.
private struct CellInstance {
    /// Top-left of the quad, in drawable pixels.
    var glyphPos: SIMD2<Float>
    var atlasPos: SIMD2<UInt16>
    /// Size of the quad *and* of its atlas rect.
    var atlasSize: SIMD2<UInt16>
    /// RGBA8, red in the low byte — what Metal's `unpack_unorm4x8_to_float`
    /// expects. Terminal colors are 8-bit at every source (theme hexes, the
    /// 256-color palette, SGR truecolor), so packing costs no fidelity.
    var fgColor: UInt32
    /// Bit 0: sample the color atlas as-is instead of tinting coverage with fgColor.
    var flags: UInt32
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
    /// Recolour the glyphs and draw nothing. Paired with `.underline` for the
    /// link under the pointer, so the text and the rule beneath it read as
    /// one object. Adds no geometry, so nothing shifts when it appears.
    case text
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

    /// Top-left pixel of the cell grid: pinned to the left margin, and
    /// top-aligned because terminals fill from the top down.
    ///
    /// This used to centre the grid horizontally so a sub-cell remainder was
    /// split between both sides rather than piling up on the right. That makes
    /// the text slide left and right by up to half a cell during a live resize,
    /// as the remainder grows and collapses across each column boundary.
    /// Pinning left keeps every glyph still and puts the whole remainder in the
    /// right padding. `margin` is 8pt in device pixels, so this is already on a
    /// pixel boundary — nothing to round.
    var origin: SIMD2<Float> { SIMD2<Float>(margin, margin) }
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

    /// Instance staging, kept across frames. These reach ~8.5k glyphs and ~10k
    /// flats on a full screen; reallocating and regrowing them every frame was
    /// pure overhead in the keystroke path.
    private var flatScratch: [FlatInstance] = []
    private var glyphScratch: [CellInstance] = []
    /// Per-cell glyph-colour overrides for `.text` highlight bands, viewport
    /// indexed (`row * cols + col`). 0 means "no override".
    private var textColorScratch: [UInt32] = []

    init(device: MTLDevice, pixelFormat: MTLPixelFormat, scale: CGFloat,
         fontFamily: String = FontCatalog.defaultFamily,
         fontSize: Double = 14,
         strokeWeight: Double = 1.0,
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

    /// Fills `flatScratch` and `glyphScratch` with this frame's instances.
    private func buildInstances(from snapshot: TerminalSnapshot,
                                selection: Selection?,
                                highlights: [HighlightBand],
                                focused: Bool,
                                cursorOn: Bool) {
        flatScratch.removeAll(keepingCapacity: true)
        glyphScratch.removeAll(keepingCapacity: true)
        glyphScratch.reserveCapacity(snapshot.cells.count / 2)

        let cellWidth = layout.cellWidth
        let cellHeight = layout.cellHeight
        let ascent = layout.ascent
        let origin = layout.origin

        let theme = ThemeStore.currentTheme
        let cursorColor = theme.cursor
        let defaultBg = PackedColor(theme.background)
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
                flatScratch.append(FlatInstance(
                    pos: SIMD2<Float>(x, y),
                    size: SIMD2<Float>(w, cellHeight),
                    color: h.color
                ))
            case .underline, .text:
                break
            }
            switch h.style {
            case .underline, .both:
                // The band's alpha is honored rather than forced to 1.0, so
                // a caller can ask for a hairline. `.background` already
                // works that way; an underline that silently ignored alpha
                // made the same colour mean two different things.
                flatScratch.append(FlatInstance(
                    pos: SIMD2<Float>(x, y + underlineTop),
                    size: SIMD2<Float>(w, underlineThickness),
                    color: h.color
                ))
            case .background, .text:
                break
            }
        }

        let cols = snapshot.cols

        // `.text` bands recolour glyphs rather than drawing a quad, so they
        // have to reach the cell loop as a per-cell lookup. Refilled each
        // frame into a kept buffer, and skipped entirely when nothing asks
        // for it — which is every frame the pointer isn't on a link.
        var recolorsText = false
        for h in highlights where h.style == .text { recolorsText = true; break }
        if recolorsText {
            let needed = snapshot.rows * cols
            if textColorScratch.count < needed {
                textColorScratch = [UInt32](repeating: 0, count: needed)
            } else {
                for i in 0..<needed { textColorScratch[i] = 0 }
            }
            for h in highlights where h.style == .text {
                guard h.row >= 0, h.row < snapshot.rows else { continue }
                let start = max(0, h.col)
                let end = min(h.col + h.length, cols)
                guard start < end else { continue }
                // Alpha stays in the packed value: 0 is the "no override"
                // sentinel, and an opaque colour can never pack to 0.
                let packed = PackedColor(h.color).value
                let base = h.row * cols
                for c in start..<end { textColorScratch[base + c] = packed }
            }
        }

        // One bounds-checked subscript per cell adds up at ~10k cells a frame.
        snapshot.cells.withUnsafeBufferPointer { cells in
            for row in 0..<snapshot.rows {
                let baselineY = origin.y + Float(row) * cellHeight + ascent
                let cellTop = origin.y + Float(row) * cellHeight
                // Resolve the selection to a column span once per row, rather
                // than asking `contains` about every cell in it.
                var selectionStart = Int.max
                var selectionEnd = Int.min
                if let selection, row >= selection.startRow, row <= selection.endRow {
                    selectionStart = row == selection.startRow ? selection.startCol : 0
                    selectionEnd = row == selection.endRow ? selection.endCol : cols - 1
                }
                let cursorOnThisRow = snapshot.cursorVisible && row == snapshot.cursorRow
                let rowBase = snapshot.rowStart(row)
                for col in 0..<cols {
                    let cell = cells[rowBase + col]
                    let isCursor = cursorOnThisRow && col == snapshot.cursorCol
                    let isSelected = col >= selectionStart && col <= selectionEnd
                    let cellLeft = origin.x + Float(col) * cellWidth
                    let cellRect = (
                        pos: SIMD2<Float>(cellLeft, cellTop),
                        size: SIMD2<Float>(cellWidth, cellHeight)
                    )

                    // Per-cell flat instances, painted bottom-up: bg → selection → cursor.
                    if cell.bg != defaultBg {
                        flatScratch.append(FlatInstance(pos: cellRect.pos, size: cellRect.size,
                                                        color: cell.bg.simd))
                    }
                    if isSelected {
                        flatScratch.append(FlatInstance(pos: cellRect.pos, size: cellRect.size, color: selectionColor))
                    }
                    if isCursor && focused && cursorOn {
                        flatScratch.append(FlatInstance(pos: cellRect.pos, size: cellRect.size, color: cursorColor))
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
                    // The one place a cell colour still needs float maths.
                    if cell.attrs.contains(.faint) {
                        glyphFg = PackedColor(mix(glyphFg.simd, cell.bg.simd, t: 0.5))
                    }
                    // Link recolour, applied after faint so a hovered link
                    // inside dimmed output is still legible, and skipped under
                    // the cursor so the inverted block keeps its contrast.
                    if recolorsText && !invertGlyph {
                        let override = textColorScratch[row * cols + col]
                        if override != 0 { glyphFg = PackedColor(override) }
                    }
                    glyphScratch.append(CellInstance(
                        glyphPos: glyphPos,
                        atlasPos: SIMD2<UInt16>(UInt16(entry.atlasOrigin.x),
                                                UInt16(entry.atlasOrigin.y)),
                        atlasSize: SIMD2<UInt16>(UInt16(entry.atlasSize.x),
                                                 UInt16(entry.atlasSize.y)),
                        fgColor: glyphFg.value,
                        flags: entry.isColor ? 1 : 0
                    ))
                }
            }
        }
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

        buildInstances(from: snapshot,
                       selection: selection,
                       highlights: highlights,
                       focused: focused,
                       cursorOn: cursorOn)

        growBuffer(&flatBuffer, capacity: &flatCapacity, count: flatScratch.count, type: FlatInstance.self)
        growBuffer(&glyphBuffer, capacity: &glyphCapacity, count: glyphScratch.count, type: CellInstance.self)
        if !flatScratch.isEmpty, let buf = flatBuffer { copyInto(buf, flatScratch) }
        if !glyphScratch.isEmpty, let buf = glyphBuffer { copyInto(buf, glyphScratch) }

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
        if !flatScratch.isEmpty, let buf = flatBuffer {
            enc.setRenderPipelineState(flatPipeline)
            enc.setVertexBuffer(buf, offset: 0, index: 0)
            enc.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.drawPrimitives(
                type: .triangleStrip,
                vertexStart: 0,
                vertexCount: 4,
                instanceCount: flatScratch.count
            )
        }

        // Glyph pass.
        if !glyphScratch.isEmpty, let buf = glyphBuffer {
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
                instanceCount: glyphScratch.count
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
