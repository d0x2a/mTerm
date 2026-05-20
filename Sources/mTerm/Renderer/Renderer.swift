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
}

private struct FlatInstance {
    var pos: SIMD2<Float>
    var size: SIMD2<Float>
    var color: SIMD4<Float>
}

private struct Uniforms {
    var viewportSize: SIMD2<Float>
    var atlasSize: SIMD2<Float>
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
    let ascent: Float
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
         thinStrokes: Bool = true) {
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
        let ascent = Float(CTFontGetAscent(font)).rounded()
        let descent = Float(CTFontGetDescent(font))
        let leading = Float(CTFontGetLeading(font))
        let cellHeight = ceil(ascent + descent + leading)

        var charM: UniChar = 0x4D
        var glyphM: CGGlyph = 0
        CTFontGetGlyphsForCharacters(font, &charM, &glyphM, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyphM, &advance, 1)
        let cellWidth = ceil(Float(advance.width))

        self.layout = GridLayout(
            cellWidth: cellWidth,
            cellHeight: cellHeight,
            ascent: ascent,
            margin: 8 * Float(scale),
            scale: Float(scale)
        )

        self.glyphAtlas = GlyphAtlas(device: device, font: font,
                                     thinStrokes: thinStrokes)

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
        let outlineThickness: Float = max(1, layout.scale)

        // Highlight bands (search matches, trigger highlights) — drawn before
        // selection/cursor so those overlay on top.
        let underlineThickness = max(1, layout.scale)
        let underlineInset     = max(1, layout.scale)
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
                    pos: SIMD2<Float>(x, y + cellHeight - underlineInset - underlineThickness),
                    size: SIMD2<Float>(w, underlineThickness),
                    color: underlineColor
                ))
            case .background:
                break
            }
        }

        // Prompt gutter dots — small filled squares centered in the left padding.
        let dotSize: Float = 4 * layout.scale
        let dotX: Float = max(0, origin.x / 2 - dotSize / 2)
        for p in snapshot.prompts {
            let color: SIMD4<Float>
            if let code = p.exitCode {
                color = (code == 0)
                    ? SIMD4(0.35, 0.78, 0.45, 1.0)        // green = success
                    : SIMD4(0.95, 0.40, 0.40, 1.0)        // red = failure
            } else {
                color = SIMD4(0.50, 0.50, 0.50, 0.80)     // grey = running / unknown
            }
            let dotY = origin.y + Float(p.viewportRow) * cellHeight + (cellHeight - dotSize) / 2
            flats.append(FlatInstance(
                pos: SIMD2<Float>(dotX, dotY),
                size: SIMD2<Float>(dotSize, dotSize),
                color: color
            ))
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
                if isCursor {
                    if !focused {
                        // Unfocused: 1-point outline around the cell.
                        appendOutline(into: &flats, pos: cellRect.pos, size: cellRect.size,
                                      thickness: outlineThickness, color: cursorColor)
                    } else if cursorOn {
                        flats.append(FlatInstance(pos: cellRect.pos, size: cellRect.size, color: cursorColor))
                    }
                    // else: focused but in the "off" phase of the blink → draw nothing.
                }

                // Glyph: skip blank cells.
                if cell.scalar == " " { continue }
                if cell.scalar.value > UInt32(UInt16.max) { continue }
                guard let entry = glyphAtlas.entry(for: cell.scalar),
                      entry.atlasSize.x > 0 else { continue }

                let glyphPos = SIMD2<Float>(
                    cellLeft + entry.bearing.x,
                    baselineY + entry.bearing.y
                )
                // Glyph color flips to the cell's bg ONLY when a focused filled
                // cursor is drawn on top of it (the classic inverted look).
                let invertGlyph = isCursor && focused && cursorOn
                let glyphFg = invertGlyph ? cell.bg : cell.fg
                glyphs.append(CellInstance(
                    glyphPos: glyphPos,
                    glyphSize: entry.atlasSize,
                    atlasPos: entry.atlasOrigin,
                    atlasSize: entry.atlasSize,
                    fgColor: glyphFg
                ))
            }
        }

        return (flats, glyphs)
    }

    private func appendOutline(into flats: inout [FlatInstance],
                               pos: SIMD2<Float>, size: SIMD2<Float>,
                               thickness: Float, color: SIMD4<Float>) {
        let t = thickness
        // top
        flats.append(FlatInstance(pos: pos,
                                  size: SIMD2(size.x, t),
                                  color: color))
        // bottom
        flats.append(FlatInstance(pos: SIMD2(pos.x, pos.y + size.y - t),
                                  size: SIMD2(size.x, t),
                                  color: color))
        // left
        flats.append(FlatInstance(pos: SIMD2(pos.x, pos.y + t),
                                  size: SIMD2(t, size.y - 2 * t),
                                  color: color))
        // right
        flats.append(FlatInstance(pos: SIMD2(pos.x + size.x - t, pos.y + t),
                                  size: SIMD2(t, size.y - 2 * t),
                                  color: color))
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
            atlasSize: SIMD2<Float>(Float(glyphAtlas.width), Float(glyphAtlas.height))
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
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.drawPrimitives(
                type: .triangleStrip,
                vertexStart: 0,
                vertexCount: 4,
                instanceCount: glyphs.count
            )
        }

        enc.endEncoding()
        cb.present(drawable)
        cb.commit()
    }
}
