import AppKit
import Metal
import QuartzCore

/// The window's one Metal drawing surface, shared by every tab in it.
///
/// This is the container the active tab's TerminalView is pinned inside, and it
/// owns the two things that used to be per-tab: the CAMetalLayer and the
/// Renderer.
///
/// Both were expensive to duplicate. A CAMetalLayer's drawable pool is the
/// largest allocation in the app — `maximumDrawableCount` full backing stores,
/// ~32 MB each at a full-screen 3470x2400 — and a layer holds that pool until
/// it deallocs, *not* until it leaves the view hierarchy. A layer per tab
/// therefore cost a pool per tab for the life of the process, whether or not
/// that tab was the one on screen, which is how a five-tab window reached a
/// gigabyte with nothing actually leaking. The Renderer rides along because it
/// carries an ~8 MB glyph atlas and every tab draws the same font at the same
/// scale, so there was never a reason to have more than one.
///
/// Only the active tab is in the view hierarchy, so only one TerminalView ever
/// draws into this at a time. The surface holds no terminal state of its own —
/// scrollback, selection and search all stay on the view, per tab.
final class TerminalSurface: NSView {
    /// Built lazily once a Metal device is available, and rebuilt when the font
    /// settings it was created for change. nil before the first `viewDidMoveToWindow`.
    private(set) var renderer: Renderer?

    var metalLayer: CAMetalLayer? { layer as? CAMetalLayer }

    /// Font settings `renderer` was built for. Held here rather than on each
    /// view so a change in Settings rebuilds the renderer once for the window
    /// instead of once per tab that happens to tick afterwards.
    private var appliedFontFamily = ThemeStore.shared.settings.fontFamily
    private var appliedFontSize = ThemeStore.shared.settings.fontSize
    private var appliedStrokeWeight = ThemeStore.shared.settings.strokeWeight
    private var appliedLineHeight = ThemeStore.shared.settings.lineHeight

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // For a Metal-backed view, AppKit should never try to redraw the layer
        // itself — our presents are the only source of truth.
        layerContentsRedrawPolicy = .never
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var wantsUpdateLayer: Bool { true }

    /// Matches the flippedness the metal layer had when TerminalView owned it,
    /// so `isGeometryFlipped` on the layer is unchanged by the move. The
    /// subviews are pinned with anchors, which don't care either way.
    override var isFlipped: Bool { true }

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.allowsNextDrawableTimeout = false
        layer.needsDisplayOnBoundsChange = true
        layer.isOpaque = true            // we render fully-opaque frames
        // Present drawables inside the current CA transaction so a frame is
        // never shown at a size that disagrees with the layer's geometry —
        // this is what keeps live resize (window + sidebar divider) smooth.
        layer.presentsWithTransaction = true
        // maximumDrawableCount stays at its default of 3. Dropping it to 2
        // looks free — we present at most one frame per tick, so the third is
        // never in flight — but presentsWithTransaction makes the present
        // synchronous on the main thread, and nextDrawable is the first call
        // in it. At two, that call waits on the compositor to release the one
        // on screen: 1.3-2.7ms average and 14ms worst case against 0.02ms at
        // three, which cost ~10fps of throughput and the same stall on
        // keystroke echo. It saved nothing either way — Core Animation keeps
        // three surfaces resident regardless.
        return layer
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        configureMetalIfNeeded()
        updateDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    /// Runs before the pinned TerminalView's own `setFrameSize` — AppKit sizes
    /// a parent before laying out its children — so the drawable is already at
    /// the new size by the time the view presents its resize frame.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    private func configureMetalIfNeeded() {
        guard renderer == nil, let metalLayer else { return }
        guard let device = MTLCreateSystemDefaultDevice() else {
            assertionFailure("Metal is required")
            return
        }
        metalLayer.device = device
        let s = ThemeStore.shared.settings
        appliedFontFamily = s.fontFamily
        appliedFontSize = s.fontSize
        appliedStrokeWeight = s.strokeWeight
        appliedLineHeight = s.lineHeight
        renderer = makeRenderer(device: device, layer: metalLayer)
    }

    private func makeRenderer(device: MTLDevice, layer: CAMetalLayer) -> Renderer {
        Renderer(
            device: device,
            pixelFormat: layer.pixelFormat,
            scale: window?.backingScaleFactor ?? 2.0,
            fontFamily: appliedFontFamily,
            fontSize: appliedFontSize,
            strokeWeight: appliedStrokeWeight,
            lineHeight: appliedLineHeight
        )
    }

    /// Rebuilds the renderer (and its glyph atlas) if the user picked a new
    /// font/size or moved the stroke/line-height sliders. Returns true when it
    /// did, which is the active view's cue to re-flow its PTY to the new cell
    /// grid and redraw.
    ///
    /// Tabs that were in the background when this fired never see the `true`;
    /// they pick the new grid up from `resizeSessionIfNeeded` when they are
    /// reinstalled, which is why TerminalView calls that on becoming active.
    @discardableResult
    func reconcileFontIfChanged() -> Bool {
        let s = ThemeStore.shared.settings
        guard s.fontFamily != appliedFontFamily
            || s.fontSize != appliedFontSize
            || s.strokeWeight != appliedStrokeWeight
            || s.lineHeight != appliedLineHeight
        else { return false }
        appliedFontFamily = s.fontFamily
        appliedFontSize = s.fontSize
        appliedStrokeWeight = s.strokeWeight
        appliedLineHeight = s.lineHeight
        guard let metalLayer, let device = metalLayer.device else { return false }
        renderer = makeRenderer(device: device, layer: metalLayer)
        return true
    }

    private func updateDrawableSize() {
        guard let metalLayer, let window else { return }
        let scale = window.backingScaleFactor
        let size = bounds.size
        // Geometry changes during a live drag must not trigger implicit CALayer
        // animations — those interpolate the drawable size and read as lag.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(
            width: max(1, size.width * scale),
            height: max(1, size.height * scale)
        )
        CATransaction.commit()
    }
}
