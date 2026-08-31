import AppKit
import Metal
import QuartzCore
import simd

final class TerminalView: NSView, CALayerDelegate {
    private var renderer: Renderer?
    private var session: Session?
    private var displayLink: CADisplayLink?

    weak var delegate: TerminalViewDelegate?

    /// Optional CWD passed in before the session is created. Used by ⌘T (inherit
    /// from the active tab) and by session restore on launch.
    var initialCwd: String?

    /// The session's last-known working directory (from OSC 7). nil if the shell
    /// hasn't emitted OSC 7 yet.
    var currentDirectory: String? { session?.currentDirectory }

    /// Foreground command running under the shell, or nil if the shell is
    /// idle. Used to warn before closing the tab/window.
    var foregroundProcess: (pid: pid_t, name: String)? {
        session?.foregroundProcess()
    }

    /// Last grid size handed to the session, so a resize that doesn't cross a
    /// cell boundary doesn't re-announce the same dimensions.
    private var lastReportedGrid: (cols: Int, rows: Int)?

    private var scrollOffset: Int = 0
    private var scrollResidue: CGFloat = 0
    private var lastScrollbackLines: Int = 0
    private var lastSnapshotCols: Int = 1
    private var lastSnapshotRows: Int = 1
    private var lastReportedTitle: String = ""
    private var lastReportedCwd: String? = nil
    private var lastReportedFgProcess: String? = nil
    private var lastReportedFocus: Bool = false
    private var lastInputTime: CFTimeInterval = CACurrentMediaTime()

    /// A selection in progress. Rows are *absolute* line numbers — the same
    /// space as Prompt.absoluteLine — so the span stays glued to its text as
    /// output scrolls it up or the user scrolls away from it. Converted to
    /// viewport rows only for drawing, by viewportSelection(snapshot:).
    private struct ActiveSelection {
        var anchor: (col: Int, row: Int)
        var end: (col: Int, row: Int)
        var dragging: Bool

        /// Endpoints in document order. Rows are absolute lines.
        var absoluteRange: Selection {
            let aBeforeE = anchor.row < end.row
                || (anchor.row == end.row && anchor.col <= end.col)
            let s = aBeforeE ? anchor : end
            let e = aBeforeE ? end : anchor
            return Selection(startCol: s.col, startRow: s.row,
                             endCol: e.col, endRow: e.row)
        }
    }

    private var activeSelection: ActiveSelection?
    /// scrolledRows from the most recent rendered frame. Mouse hits resolve
    /// against this rather than the session's live value on purpose: a click
    /// lands on the text the user can see, which is the frame we last drew. If
    /// output scrolled since, the live value would map the click onto whatever
    /// has moved into that row instead.
    private var lastScrolledRows: Int = 0

    /// Something that affects the next frame changed. Cleared once presented.
    /// Starts true so the first tick always draws.
    private var needsFrame = true
    private var lastPresentTime: CFTimeInterval = 0
    private var lastRenderedBlink = false
    /// Display refresh period, learned from the display link.
    private var frameInterval: CFTimeInterval = 1.0 / 60.0
    /// Safety net for the dirty check: redraw at least this often even when
    /// nothing looks dirty, so a state change nobody flagged can't leave a
    /// stale frame on screen indefinitely.
    private static let maxIdleInterval: CFTimeInterval = 0.25
    /// Alt-screen state as of the last frame, to spot the swap.
    private var lastUsingAlt: Bool = false

    private struct SearchState {
        var query: String
        var useRegex: Bool
        var matches: [SearchMatch]
        var currentIndex: Int
    }

    private var search: SearchState?
    private var searchBar: SearchBar?

    private let triggerEvaluator = TriggerEvaluator()
    private var currentTriggerMatches: [TriggerMatch] = []
    private var commandHeld: Bool = false
    private var pathExistsCache: [String: Bool] = [:]
    private var pathCacheStamp: CFTimeInterval = 0
    private static let pathCacheTTL: CFTimeInterval = 2.0
    /// Memo for evaluateTriggers. Kept separate from currentTriggerMatches,
    /// which is cleared whenever ⌘ comes up — reusing that as the memo would
    /// hand back an empty result the next time ⌘ went down on an unchanged
    /// screen.
    private var memoedFingerprint: Int? = nil
    private var memoedTriggerMatches: [TriggerMatch] = []
    private var lastMouseCoord: (col: Int, row: Int)? = nil
    /// Last pointer location in window coordinates, used to detect when the
    /// pointer is over the split-view divider's grab zone (which overlaps our
    /// left edge) so we don't clobber its resize cursor with the I-beam.
    private var lastMouseWindowPoint: NSPoint? = nil
    private var lastAppliedTheme: Theme = ThemeStore.currentTheme
    private var lastAppliedFontFamily: String = ThemeStore.shared.settings.fontFamily
    private var lastAppliedFontSize: Double = ThemeStore.shared.settings.fontSize
    private var lastAppliedStrokeWeight: Double = ThemeStore.shared.settings.strokeWeight
    private var lastAppliedLineHeight: Double = ThemeStore.shared.settings.lineHeight

    override var wantsUpdateLayer: Bool { true }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // For a Metal-backed view, AppKit should never try to redraw the layer
        // itself — our presents are the only source of truth.
        layerContentsRedrawPolicy = .never
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Called every tick. Detects theme changes and dispatches a cell remap so
    /// already-printed text picks up the new palette.
    private func reconcileThemeIfChanged() {
        let new = ThemeStore.currentTheme
        let old = lastAppliedTheme
        guard old != new else { return }
        invalidate()
        lastAppliedTheme = new
        session?.applyThemeChange(from: old, to: new)
    }

    /// Called every tick. Rebuilds the Metal renderer (and its glyph atlas) when
    /// the user picks a new font/size or toggles thin strokes in Settings, then
    /// re-flows the PTY to the new cell grid so the shell doesn't keep believing
    /// it has the old cols/rows.
    private func reconcileFontIfChanged() {
        let s = ThemeStore.shared.settings
        guard s.fontFamily != lastAppliedFontFamily
            || s.fontSize != lastAppliedFontSize
            || s.strokeWeight != lastAppliedStrokeWeight
            || s.lineHeight != lastAppliedLineHeight
        else { return }
        invalidate()
        lastAppliedFontFamily = s.fontFamily
        lastAppliedFontSize = s.fontSize
        lastAppliedStrokeWeight = s.strokeWeight
        lastAppliedLineHeight = s.lineHeight
        rebuildRenderer()
    }

    private func rebuildRenderer() {
        guard let metalLayer = layer as? CAMetalLayer,
              let device = metalLayer.device else { return }
        let scale = window?.backingScaleFactor ?? 2.0
        renderer = Renderer(
            device: device,
            pixelFormat: metalLayer.pixelFormat,
            scale: scale,
            fontFamily: lastAppliedFontFamily,
            fontSize: lastAppliedFontSize,
            strokeWeight: lastAppliedStrokeWeight,
            lineHeight: lastAppliedLineHeight
        )
        resizeSessionIfNeeded()
    }

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
        return layer
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else {
            displayLink?.invalidate()
            displayLink = nil
            return
        }
        configureMetalIfNeeded()
        updateDrawableSize()
        ensureSession()
        let link = window.displayLink(target: self, selector: #selector(tick(_:)))
        // Ask for the panel's full rate. Left unset the system chooses, and a
        // rate below the display's maximum doesn't only pace the tick — it also
        // feeds `frameInterval` (see tick), which gates whether a keystroke echo
        // presents immediately or waits for the next tick. The floor stays low
        // so an idle terminal can still be throttled down.
        let maxFPS = Float(window.screen?.maximumFramesPerSecond ?? 60)
        link.preferredFrameRateRange = CAFrameRateRange(
            minimum: min(30, maxFPS), maximum: maxFPS, preferred: maxFPS
        )
        link.add(to: .main, forMode: .common)
        displayLink = link
        window.makeFirstResponder(self)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
        resizeSessionIfNeeded()
        // Present immediately at the new size. With `presentsWithTransaction`
        // the present lands in the same CA transaction as the layout change,
        // so the divider/window drag stays smooth instead of stretching the
        // previous frame until the next display-link tick.
        renderFrame()
    }

    // MARK: input

    override func keyDown(with event: NSEvent) {
        guard let session else { return super.keyDown(with: event) }
        let bytes = bytesForKey(event)
        if !bytes.isEmpty {
            // Only invalidate when the keystroke itself changes the screen:
            // snapping back from scrollback, dropping a selection, or waking a
            // blinked-off cursor. The typed character appears when the echo
            // arrives, and presenting a frame now would show the grid *without*
            // it -- and arm the once-per-frame limiter against the echo, which
            // is the frame that actually matters.
            if scrollOffset != 0 || activeSelection != nil || !cursorBlinkOn() {
                invalidate()
            }
            scrollOffset = 0          // typing always snaps to bottom
            scrollResidue = 0
            activeSelection = nil
            lastInputTime = CACurrentMediaTime()
            session.write(bytes)
        }
    }

    /// Forwards a mouse event to the child when it has asked for tracking.
    /// Returns true when the child took the event, so local selection stays out
    /// of the way. Holding shift is the standard escape hatch back to
    /// selecting, and scrolled-back views never report — the coordinates would
    /// describe rows the child doesn't believe are on screen.
    private func sendMouse(_ event: NSEvent,
                           button: Int,
                           kind: MouseReport.Kind,
                           coord: (col: Int, row: Int)) -> Bool {
        guard let session, scrollOffset == 0 else { return false }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !mods.contains(.shift) else { return false }
        let modes = session.inputModes
        guard modes.mouseTracking != .off else { return false }

        // Everything past this point belongs to the child even when the mode
        // doesn't want this particular event — otherwise a drag the app isn't
        // listening for would start painting a selection underneath it.
        if let bytes = MouseReport.bytes(kind: kind,
                                         button: button,
                                         col: coord.col,
                                         row: coord.row,
                                         option: mods.contains(.option),
                                         control: mods.contains(.control),
                                         tracking: modes.mouseTracking,
                                         encoding: modes.mouseEncoding) {
            session.write(bytes)
        }
        return true
    }

    private func coord(of event: NSEvent) -> (col: Int, row: Int) {
        cellCoord(at: convert(event.locationInWindow, from: nil))
    }

    override func rightMouseDown(with event: NSEvent) {
        if sendMouse(event, button: MouseReport.right, kind: .press, coord: coord(of: event)) { return }
        super.rightMouseDown(with: event)       // falls through to the menu
    }

    override func rightMouseUp(with event: NSEvent) {
        if sendMouse(event, button: MouseReport.right, kind: .release, coord: coord(of: event)) { return }
        super.rightMouseUp(with: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        if sendMouse(event, button: MouseReport.middle, kind: .press, coord: coord(of: event)) { return }
        super.otherMouseDown(with: event)
    }

    override func otherMouseUp(with event: NSEvent) {
        if sendMouse(event, button: MouseReport.middle, kind: .release, coord: coord(of: event)) { return }
        super.otherMouseUp(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        invalidate()
        window?.makeFirstResponder(self)
        let coord = cellCoord(at: convert(event.locationInWindow, from: nil))
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if mods.contains(.command) {
            // ⌘ can have gone down while this window wasn't key, in which case
            // flagsChanged never ran and the matches — which renderFrame only
            // computes while ⌘ is held — are still empty. Catch up here so a
            // ⌘-click that activates the window still lands on its link.
            if !commandHeld {
                commandHeld = true
                refreshTriggerMatches()
            }
            if let match = triggerMatch(at: coord) {
                handleTriggerClick(match)
                return                       // don't start a selection
            }
        }

        if sendMouse(event, button: MouseReport.left, kind: .press, coord: coord) { return }

        // Shift+click extends the existing selection rather than starting a new
        // one. The edge nearer the click is the one that moves; the far edge
        // becomes the anchor, so shift-clicking to the left of a double-clicked
        // word keeps that word's right edge pinned instead of collapsing onto
        // its start. With nothing selected yet, shift+click falls through and
        // begins a selection like a plain click.
        if mods.contains(.shift), let current = activeSelection {
            let sel = current.absoluteRange
            let start = (col: sel.startCol, row: sel.startRow)
            let end   = (col: sel.endCol,   row: sel.endRow)
            let hit = absCoord(coord)
            let beforeStart = hit.row < start.row
                || (hit.row == start.row && hit.col < start.col)
            activeSelection = ActiveSelection(anchor: beforeStart ? end : start,
                                              end: hit,
                                              dragging: true)
            return
        }

        if event.clickCount >= 3 {
            // Triple-click: select the whole visible line.
            let lastCol = max(0, lastSnapshotCols - 1)
            let line = absoluteLine(forViewportRow: coord.row)
            activeSelection = ActiveSelection(
                anchor: (col: 0, row: line),
                end:    (col: lastCol, row: line),
                dragging: false
            )
        } else if event.clickCount == 2 {
            // Double-click: select the word under the cursor.
            activeSelection = wordSelection(at: coord)
        } else {
            let hit = absCoord(coord)
            activeSelection = ActiveSelection(anchor: hit, end: hit, dragging: true)
        }
    }

    /// Expands a double-clicked cell to its surrounding word. A "word" is a run
    /// of word characters (alphanumerics plus punctuation common in paths, URLs,
    /// and identifiers); clicking any other character selects just that cell.
    private func wordSelection(at coord: (col: Int, row: Int)) -> ActiveSelection {
        let line = absoluteLine(forViewportRow: coord.row)
        let single = ActiveSelection(anchor: (col: coord.col, row: line),
                                     end: (col: coord.col, row: line), dragging: false)
        guard let session else { return single }
        let snapshot = session.snapshot(scrollOffset: scrollOffset)
        let cols = snapshot.cols
        guard coord.row >= 0, coord.row < snapshot.rows, cols > 0 else { return single }

        func isWord(_ col: Int) -> Bool {
            isWordChar(snapshot.cells[snapshot.rowStart(coord.row) + col].scalar)
        }

        let clicked = min(coord.col, cols - 1)
        guard isWord(clicked) else {
            return ActiveSelection(anchor: (col: clicked, row: line),
                                   end: (col: clicked, row: line), dragging: false)
        }
        var start = clicked
        while start > 0, isWord(start - 1) { start -= 1 }
        var end = clicked
        while end < cols - 1, isWord(end + 1) { end += 1 }
        return ActiveSelection(anchor: (col: start, row: line),
                               end: (col: end, row: line), dragging: false)
    }

    private func isWordChar(_ s: Unicode.Scalar) -> Bool {
        if CharacterSet.alphanumerics.contains(s) { return true }
        return "_-./~:+@%".unicodeScalars.contains(s)
    }

    /// Recomputes trigger matches outside the render loop. renderFrame only
    /// evaluates them while ⌘ is down (see there), so the moment ⌘ *goes* down
    /// has to fill them in itself — updateCursorAffordance reads them
    /// synchronously, a frame before the next render would have.
    private func refreshTriggerMatches() {
        guard let session else {
            currentTriggerMatches = []
            return
        }
        currentTriggerMatches = evaluateTriggers(
            snapshot: session.snapshot(scrollOffset: scrollOffset)
        )
    }

    /// Runs the triggers, then drops every file-path match that doesn't name
    /// something on disk. The path regex is deliberately loose — `and/or` and
    /// `w/e` match it — so this is what stands between "file paths are
    /// clickable" and every slash on screen becoming a click target. It also
    /// means ⌘-click can't miss: anything the pointer offers is known to
    /// exist.
    private func evaluateTriggers(snapshot: TerminalSnapshot) -> [TriggerMatch] {
        // Expire the stat cache on a fixed cadence, and force a re-evaluation
        // when it goes: a path that appeared or vanished while ⌘ was held
        // doesn't change a single cell, so the fingerprint below can't see it.
        let now = CACurrentMediaTime()
        var expired = false
        if now - pathCacheStamp > Self.pathCacheTTL {
            pathExistsCache.removeAll(keepingCapacity: true)
            pathCacheStamp = now
            expired = true
        }

        // Holding ⌘ and moving the pointer marks a frame dirty on every mouse
        // event, so without this the regexes re-run over identical text 60
        // times a second — 1.5 ms a frame on a large window. Fingerprinting
        // exactly what the evaluator reads costs ~2% of that.
        let fingerprint = triggerFingerprint(snapshot)
        if !expired, fingerprint == memoedFingerprint {
            return memoedTriggerMatches
        }

        let matches = triggerEvaluator.evaluate(snapshot: snapshot)
        let cwd = snapshot.currentDirectory
        let filtered = matches.filter { m in
            guard m.trigger.clickAction == .revealFile else { return true }
            guard let path = resolveFilePath(m.text, cwd: cwd) else { return false }
            return pathExists(path)
        }
        memoedFingerprint = fingerprint
        memoedTriggerMatches = filtered
        return filtered
    }

    /// Everything TriggerEvaluator looks at: the geometry, where the viewport
    /// sits, the cwd relative paths resolve against, and every cell's scalar.
    /// Colors and attributes are deliberately absent — a line that only
    /// changed color has the same links.
    private func triggerFingerprint(_ s: TerminalSnapshot) -> Int {
        var hasher = Hasher()
        hasher.combine(s.cols)
        hasher.combine(s.rows)
        hasher.combine(s.rowOffset)
        // Wrap flags decide how rows are joined into logical lines, so two
        // screens with identical cells but different wrapping do not have
        // identical links.
        hasher.combine(s.rowWrapped)
        hasher.combine(s.scrolledRows)
        hasher.combine(s.scrollOffset)
        hasher.combine(s.currentDirectory)
        // Link ids ride along with the scalars: a screen whose text is
        // unchanged but whose OSC 8 spans moved has different links. Packed
        // into one combine so this stays the single pass it was.
        s.cells.withUnsafeBufferPointer { cells in
            for cell in cells {
                hasher.combine(UInt64(cell.scalar.value) << 16 | UInt64(cell.link))
            }
        }
        // Ids are indexes into this, so the same id can mean a different target
        // after a sweep renumbers the table.
        hasher.combine(s.links.count)
        return hasher.finalize()
    }

    /// Cached stat(), so holding ⌘ over a screen of `find` output doesn't
    /// re-stat every hit. evaluateTriggers owns the expiry.
    private func pathExists(_ path: String) -> Bool {
        if let known = pathExistsCache[path] { return known }
        let exists = FileManager.default.fileExists(atPath: path)
        pathExistsCache[path] = exists
        return exists
    }

    /// Gives a schemeless match the scheme it needs to be openable.
    ///
    /// `URL(string:).scheme` can't be used to spot one: RFC 3986 allows dots
    /// in a scheme, so Foundation reads `code.d0x2a.com:8080/x` as the scheme
    /// "code.d0x2a.com" and `localhost:3000` as "localhost", and NSWorkspace
    /// then quietly fails to open either. A colon followed by digits is a
    /// port, not a scheme.
    ///
    /// Bare `localhost` and bare IPv4 get http — that's what a dev server on
    /// a port is. Everything else gets https, including Traefik-style
    /// `<service>.docker.localhost`, which is served over TLS.
    private func openableURL(_ text: String) -> URL? {
        if text.contains("://")
            || text.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*:(?![\d/])"#,
                          options: .regularExpression) != nil {
            return URL(string: text)
        }
        let isLoopback = text.range(
            of: #"^(?:localhost|\d{1,3}(?:\.\d{1,3}){3})(?:[:/]|$)"#,
            options: .regularExpression
        ) != nil
        return URL(string: (isLoopback ? "http://" : "https://") + text)
    }

    /// Resolves a matched path to something absolute, or nil when it can't be
    /// — a relative path with no OSC 7 cwd to anchor it has no meaning, so it
    /// stops being a link rather than guessing at the process's own cwd.
    /// A trailing `:line[:col]` from compiler or grep output is trimmed first;
    /// it's carried in the match so hovering marks the whole reference.
    private func resolveFilePath(_ text: String, cwd: String?) -> String? {
        var p = text
        while let r = p.range(of: #":\d+$"#, options: .regularExpression) {
            p.removeSubrange(r)
        }
        guard !p.isEmpty else { return nil }
        if p.hasPrefix("~") {
            p = (p as NSString).expandingTildeInPath
        } else if !p.hasPrefix("/") {
            guard let cwd else { return nil }
            p = (cwd as NSString).appendingPathComponent(p)
        }
        return (p as NSString).standardizingPath
    }

    /// The match the pointer is currently inside, if any. Nil once the
    /// pointer leaves the view — mouseExited clears lastMouseCoord, so the
    /// underline can't be left behind on a link nobody is pointing at.
    private func hoveredTriggerMatch() -> TriggerMatch? {
        guard let coord = lastMouseCoord else { return nil }
        return triggerMatch(at: coord)
    }

    private func triggerMatch(at coord: (col: Int, row: Int)) -> TriggerMatch? {
        currentTriggerMatches.first {
            $0.viewportRow == coord.row &&
            coord.col >= $0.viewportCol &&
            coord.col < $0.viewportCol + $0.length
        }
    }

    private func handleTriggerClick(_ match: TriggerMatch) {
        // An OSC 8 carries its own target, so nothing is inferred from the text
        // under the pointer — that text is a label and is free to disagree with
        // where it goes.
        if let uri = match.hyperlink {
            openHyperlink(uri)
            return
        }
        guard let action = match.trigger.clickAction else { return }
        switch action {
        case .openURL:
            if let url = openableURL(match.text) {
                NSWorkspace.shared.open(url)
            }
        case .revealFile:
            guard let path = resolveFilePath(match.text,
                                             cwd: session?.currentDirectory)
            else { return }
            // Reveal rather than open: the match was offered because it
            // exists, and selecting it in Finder can't run anything by
            // accident.
            NSWorkspace.shared.activateFileViewerSelecting(
                [URL(fileURLWithPath: path)]
            )
        case .runCommand(let template):
            // Substitute $1 with the matched text, append \r so the shell
            // actually executes it.
            var cmd = template.replacingOccurrences(of: "$1", with: match.text)
            cmd.append("\r")
            session?.write(Array(cmd.utf8))
        }
    }

    /// Opens a link that arrived as an OSC 8. The scheme was checked when the
    /// sequence was parsed, so this only has to decide between opening and
    /// revealing: a `file://` is revealed for the same reason matched paths are
    /// — ⌘-click shouldn't be able to run a .sh or a .app by accident.
    private func openHyperlink(_ uri: String) {
        guard let url = URL(string: uri) else { return }
        if url.isFileURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        invalidate()
        if sendMouse(event, button: MouseReport.left, kind: .drag, coord: coord(of: event)) { return }
        guard activeSelection != nil else { return }
        let coord = cellCoord(at: convert(event.locationInWindow, from: nil))
        activeSelection?.end = absCoord(coord)
        activeSelection?.dragging = true
    }

    override func mouseUp(with event: NSEvent) {
        invalidate()
        if sendMouse(event, button: MouseReport.left, kind: .release, coord: coord(of: event)) { return }
        guard var sel = activeSelection else { return }
        sel.dragging = false
        // A pure single click (no drag) clears the selection. Double/triple-click
        // word/line selections are intentional and kept even when they cover a
        // single cell (so anchor == end).
        if event.clickCount == 1 && sel.anchor == sel.end {
            activeSelection = nil
        } else {
            activeSelection = sel
        }
    }

    override func mouseMoved(with event: NSEvent) {
        invalidate()
        let coord = cellCoord(at: convert(event.locationInWindow, from: nil))
        _ = sendMouse(event, button: MouseReport.none, kind: .motion, coord: coord)
        lastMouseCoord = coord
        lastMouseWindowPoint = event.locationInWindow
        updateCursorAffordance()
    }

    override func mouseExited(with event: NSEvent) {
        invalidate()
        lastMouseCoord = nil
        lastMouseWindowPoint = nil
        commandHeld = false
        updateCursorAffordance()
    }

    override func flagsChanged(with event: NSEvent) {
        invalidate()
        let cmd = event.modifierFlags.contains(.command)
        if cmd != commandHeld {
            commandHeld = cmd
            if cmd { refreshTriggerMatches() }
            updateCursorAffordance()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    private func updateCursorAffordance() {
        // When the pointer sits over the split-view divider's enlarged grab
        // zone (which overlaps our left edge), let that resize cursor stand
        // instead of forcing the I-beam over it.
        if let p = lastMouseWindowPoint,
           window?.contentView?.hitTest(p) is NSSplitView {
            NSCursor.resizeLeftRight.set()
            return
        }
        if commandHeld,
           let match = hoveredTriggerMatch(),
           match.trigger.clickAction != nil {
            NSCursor.pointingHand.set()
        } else {
            NSCursor.iBeam.set()
        }
    }

    /// Marks the next tick as needing a frame. Cheap enough to call from any
    /// event handler that can change what's on screen.
    private func invalidate() { needsFrame = true }

    /// New output landed. Present it now instead of waiting for the next
    /// display-link tick: measured at ~7.7 ms of the ~9.4 ms a keystroke spent
    /// getting to the screen, because key handling and the tick share the main
    /// run loop, so an echo reliably just missed the frame being drawn.
    ///
    /// Rate-limited to one present per refresh period — under a firehose the
    /// display can't show more than that anyway, and the tick picks up whatever
    /// is still pending.
    private func sessionDidOutput() {
        needsFrame = true
        guard CACurrentMediaTime() - lastPresentTime >= frameInterval else { return }
        renderFrame()
    }

    /// Maps a viewport row to its absolute line. The top visible line is
    /// scrolledRows - scrollOffset, matching visiblePrompts and the search
    /// highlight conversion in composedHighlights.
    private func absoluteLine(forViewportRow row: Int) -> Int {
        lastScrolledRows - scrollOffset + row
    }

    private func absCoord(_ c: (col: Int, row: Int)) -> (col: Int, row: Int) {
        (col: c.col, row: absoluteLine(forViewportRow: c.row))
    }

    /// Clips the stored absolute selection onto the current viewport. Returns
    /// nil when none of it is on screen. A clipped edge loses its column bound
    /// along with the off-screen row it belonged to, so the visible remainder
    /// runs to the edge of the grid.
    private func viewportSelection(snapshot: TerminalSnapshot) -> Selection? {
        guard let activeSelection, snapshot.rows > 0, snapshot.cols > 0 else { return nil }
        let sel = activeSelection.absoluteRange
        let topAbs = snapshot.scrolledRows - snapshot.scrollOffset
        let lastRow = snapshot.rows - 1
        let startRow = sel.startRow - topAbs
        let endRow = sel.endRow - topAbs
        guard endRow >= 0, startRow <= lastRow else { return nil }
        return Selection(startCol: startRow < 0 ? 0 : sel.startCol,
                         startRow: max(0, startRow),
                         endCol: endRow > lastRow ? snapshot.cols - 1 : sel.endCol,
                         endRow: min(lastRow, endRow))
    }

    private func cellCoord(at point: NSPoint) -> (col: Int, row: Int) {
        guard let renderer else { return (0, 0) }
        let scale = CGFloat(renderer.layout.scale)
        let cellWPts = CGFloat(renderer.layout.cellWidth) / scale
        let cellHPts = CGFloat(renderer.layout.cellHeight) / scale
        guard cellWPts > 0, cellHPts > 0 else { return (0, 0) }
        let originPx = renderer.layout.origin
        let originXPts = CGFloat(originPx.x) / scale
        let originYPts = CGFloat(originPx.y) / scale
        let col = Int(floor((point.x - originXPts) / cellWPts))
        let row = Int(floor((point.y - originYPts) / cellHPts))
        return (
            max(0, min(lastSnapshotCols - 1, col)),
            max(0, min(lastSnapshotRows - 1, row))
        )
    }

    override func scrollWheel(with event: NSEvent) {
        invalidate()
        guard let renderer else { return }
        let pointsPerRow = CGFloat(renderer.layout.cellHeight) / CGFloat(renderer.layout.scale)
        guard pointsPerRow > 0 else { return }

        // event.scrollingDeltaY is in points. Positive = content moves down (i.e.
        // user is scrolling toward older content). Track integer rows; carry the
        // fractional remainder so trackpads feel smooth.
        scrollResidue += event.scrollingDeltaY
        let rowDelta = Int((scrollResidue / pointsPerRow).rounded(.towardZero))
        if rowDelta == 0 { return }
        scrollResidue -= CGFloat(rowDelta) * pointsPerRow

        // An app that asked for tracking gets the wheel as button 64/65
        // presses instead of scrolling our own viewport.
        if scrollOffset == 0,
           !event.modifierFlags.contains(.shift),
           let session,
           session.inputModes.mouseTracking != .off {
            let coord = self.coord(of: event)
            let button = rowDelta > 0 ? MouseReport.wheelUp : MouseReport.wheelDown
            let modes = session.inputModes
            for _ in 0..<min(abs(rowDelta), 8) {
                if let bytes = MouseReport.bytes(kind: .press, button: button,
                                                 col: coord.col, row: coord.row,
                                                 tracking: modes.mouseTracking,
                                                 encoding: modes.mouseEncoding) {
                    session.write(bytes)
                }
            }
            return
        }

        let next = scrollOffset + rowDelta
        scrollOffset = max(0, min(next, lastScrollbackLines))
    }

    // MARK: context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        window?.makeFirstResponder(self)

        let menu = NSMenu()
        menu.autoenablesItems = true

        func add(_ title: String,
                 _ action: Selector,
                 key: String = "",
                 mods: NSEvent.ModifierFlags = [.command],
                 target: AnyObject? = self) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            item.target = target
        }

        add("Copy", #selector(copy(_:)), key: "c")
        add("Copy All", #selector(copyAll(_:)), key: "c", mods: [.command, .shift])
        add("Paste", #selector(paste(_:)), key: "v")
        add("Select All", #selector(selectAll(_:)), key: "a")
        menu.addItem(.separator())
        add("Find…", #selector(performFind(_:)), key: "f")
        menu.addItem(.separator())
        // Tab commands live on AppDelegate — let the responder chain find them.
        add("New Tab", #selector(AppDelegate.openNewTab(_:)), key: "t", target: nil)
        add("Close Tab", #selector(AppDelegate.closeActiveTab(_:)), key: "w", target: nil)

        return menu
    }

    // MARK: clipboard

    @objc func paste(_ sender: Any?) {
        guard let session,
              let str = NSPasteboard.general.string(forType: .string),
              !str.isEmpty
        else { return }
        // Most shells expect carriage returns, not line feeds, for "enter".
        var normalized = str.replacingOccurrences(of: "\r\n", with: "\r")
        normalized = normalized.replacingOccurrences(of: "\n", with: "\r")
        // Bracketed paste (?2004): the child asked to be told where a paste
        // starts and ends, so a multi-line paste lands in its line editor
        // instead of executing a command per newline.
        if session.inputModes.bracketedPaste {
            session.write(Array("\u{1B}[200~".utf8)
                          + Array(normalized.utf8)
                          + Array("\u{1B}[201~".utf8))
        } else {
            session.write(Array(normalized.utf8))
        }
    }

    @objc func copy(_ sender: Any?) {
        guard let activeSelection, let session else { return }
        let sel = activeSelection.absoluteRange
        let text = session.selectionText(from: sel.startRow, startCol: sel.startCol,
                                         to: sel.endRow, endCol: sel.endCol)
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// Selects the whole buffer — scrollback plus the visible grid — which
    /// selections in absolute lines can now express. Copy All remains the
    /// one-step version that skips the selection entirely.
    override func selectAll(_ sender: Any?) {
        invalidate()
        guard let session, let bounds = session.contentBounds() else {
            activeSelection = nil      // empty buffer, nothing to select
            return
        }
        activeSelection = ActiveSelection(anchor: (col: 0, row: bounds.firstLine),
                                          end: (col: bounds.lastCol, row: bounds.lastLine),
                                          dragging: false)
    }

    /// Copies the whole buffer — scrollback plus the visible grid — regardless
    /// of what's selected.
    @objc func copyAll(_ sender: Any?) {
        guard let session else { return }
        let text = session.bufferText()
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    @objc func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)):
            return activeSelection != nil
        case #selector(copyAll(_:)), #selector(selectAll(_:)):
            return session != nil
        case #selector(paste(_:)):
            return NSPasteboard.general.canReadObject(forClasses: [NSString.self], options: nil)
        case #selector(jumpToPreviousPrompt(_:)),
             #selector(jumpToNextPrompt(_:)):
            return session != nil
        default:
            return true
        }
    }

    // MARK: search

    @objc func performFind(_ sender: Any?) {
        if searchBar == nil {
            showSearchBar()
        }
        searchBar?.focus()
    }

    @objc func findNext(_ sender: Any?) {
        cycleMatch(by: 1)
    }

    @objc func findPrevious(_ sender: Any?) {
        cycleMatch(by: -1)
    }

    private func showSearchBar() {
        let bar = SearchBar()
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.topAnchor.constraint(equalTo: topAnchor),
            bar.heightAnchor.constraint(equalToConstant: 36),
        ])
        bar.onQuery = { [weak self] q, regex in self?.updateSearch(query: q, regex: regex) }
        bar.onPrev  = { [weak self] in self?.cycleMatch(by: -1) }
        bar.onNext  = { [weak self] in self?.cycleMatch(by: 1) }
        bar.onClose = { [weak self] in self?.closeSearch() }
        searchBar = bar
    }

    private func closeSearch() {
        searchBar?.removeFromSuperview()
        searchBar = nil
        invalidate(); search = nil
        window?.makeFirstResponder(self)
    }

    private func updateSearch(query: String, regex: Bool) {
        guard let session, !query.isEmpty else {
            invalidate(); search = nil
            searchBar?.matchCount = 0
            return
        }
        let matches = session.search(query: query, regex: regex)
        var state = SearchState(query: query, useRegex: regex,
                                matches: matches, currentIndex: 0)
        if !matches.isEmpty {
            // Prefer the first match at-or-after the current viewport top so
            // typing doesn't yank the view across a long buffer.
            let scrolled = session.snapshot(scrollOffset: scrollOffset).scrolledRows
            let topAbs = scrolled - scrollOffset
            state.currentIndex = matches.firstIndex(where: { $0.absoluteLine >= topAbs }) ?? 0
            scrollToMatch(matches[state.currentIndex])
        }
        invalidate(); search = state
        searchBar?.matchCount = matches.count
        searchBar?.currentMatch = state.currentIndex
    }

    private func cycleMatch(by delta: Int) {
        guard var s = search, !s.matches.isEmpty else { return }
        let n = s.matches.count
        s.currentIndex = ((s.currentIndex + delta) % n + n) % n
        invalidate(); search = s
        searchBar?.currentMatch = s.currentIndex
        scrollToMatch(s.matches[s.currentIndex])
    }

    private func scrollToMatch(_ match: SearchMatch) {
        guard let session else { return }
        let scrolled = session.snapshot(scrollOffset: scrollOffset).scrolledRows
        if match.absoluteLine >= scrolled {
            scrollOffset = 0
        } else {
            let target = scrolled - match.absoluteLine
            scrollOffset = min(target, lastScrollbackLines)
        }
        scrollResidue = 0
    }

    @objc func jumpToPreviousPrompt(_ sender: Any?) {
        invalidate()
        guard let session,
              let newOffset = session.jumpToPrompt(direction: -1, from: scrollOffset)
        else { return }
        scrollOffset = newOffset
        scrollResidue = 0
    }

    @objc func jumpToNextPrompt(_ sender: Any?) {
        invalidate()
        guard let session else { return }
        // direction > 0 returns 0 if no prompt below — i.e. snap to bottom.
        scrollOffset = session.jumpToPrompt(direction: 1, from: scrollOffset) ?? 0
        scrollResidue = 0
    }

    private func bytesForKey(_ event: NSEvent) -> [UInt8] {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let opt = mods.contains(.option)
        let shift = mods.contains(.shift)

        // ⌘-anything is an app shortcut, never terminal input. When the matching
        // menu item is disabled (⌘C with no selection, say), AppKit stops
        // handling the key equivalent and the event falls through to keyDown —
        // without this the bare letter would be typed into the shell.
        if mods.contains(.command) { return [] }

        switch event.keyCode {
        case 36, 76:                                // Return / numpad enter
            // Shift+Enter and Option+Enter emit Alt-Return (ESC CR) so
            // TUIs like Claude Code can distinguish "newline" from
            // "submit". Plain Enter stays as CR.
            if opt || shift { return [0x1B, 0x0D] }
            return [0x0D]
        case 51:                                    // Backspace
            return opt ? [0x1B, 0x7F] : [0x7F]
        case 117:                                   // Forward Delete (Fn+Backspace)
            return [0x1B, 0x5B, 0x33, 0x7E]         // CSI 3 ~
        case 48:                                    // Tab
            return shift ? [0x1B, 0x5B, 0x5A] : [0x09]    // Shift+Tab → CSI Z
        case 53:                                    // Escape
            return [0x1B]
        case 126: return cursorBytes(final: 0x41, mods: mods)   // ↑
        case 125: return cursorBytes(final: 0x42, mods: mods)   // ↓
        case 124:                                                // →
            if opt { return [0x1B, 0x66] }                       // ESC f — forward-word
            return cursorBytes(final: 0x43, mods: mods)
        case 123:                                                // ←
            if opt { return [0x1B, 0x62] }                       // ESC b — backward-word
            return cursorBytes(final: 0x44, mods: mods)
        case 115: return [0x1B, 0x5B, 0x48]                      // Home (Fn+Left) — CSI H
        case 119: return [0x1B, 0x5B, 0x46]                      // End  (Fn+Right) — CSI F
        case 116: return [0x1B, 0x5B, 0x35, 0x7E]                // PageUp   — CSI 5 ~
        case 121: return [0x1B, 0x5B, 0x36, 0x7E]                // PageDown — CSI 6 ~
        default: break
        }

        // Option held but not a special key → treat Option as Meta and prefix ESC
        // to the un-Option-modified character. This is what readline / zsh ZLE
        // expect (so M-b, M-f, M-d, etc. work).
        if opt {
            guard let raw = event.charactersIgnoringModifiers, !raw.isEmpty else { return [] }
            let s = shift ? raw : raw.lowercased()
            return [0x1B] + Array(s.utf8)
        }

        // Regular keys. Ctrl-letter already comes through as the control byte
        // (Ctrl-C → 0x03 etc.) via event.characters.
        guard let chars = event.characters, !chars.isEmpty else { return [] }
        return Array(chars.utf8)
    }

    /// xterm-style cursor key with optional modifier encoding:
    /// CSI <final>             when no modifiers
    /// CSI 1 ; <code> <final>  where code = 1 + shift + 2·option + 4·control
    private func cursorBytes(final: UInt8, mods: NSEvent.ModifierFlags) -> [UInt8] {
        var code = 1
        if mods.contains(.shift)   { code += 1 }
        if mods.contains(.option)  { code += 2 }
        if mods.contains(.control) { code += 4 }
        if code == 1 {
            return [0x1B, 0x5B, final]
        }
        return [0x1B, 0x5B, 0x31, 0x3B] + Array(String(code).utf8) + [final]
    }

    // MARK: setup

    private func configureMetalIfNeeded() {
        guard renderer == nil, let metalLayer = layer as? CAMetalLayer else { return }
        guard let device = MTLCreateSystemDefaultDevice() else {
            assertionFailure("Metal is required")
            return
        }
        metalLayer.device = device
        let scale = window?.backingScaleFactor ?? 2.0
        let s = ThemeStore.shared.settings
        renderer = Renderer(
            device: device,
            pixelFormat: metalLayer.pixelFormat,
            scale: scale,
            fontFamily: s.fontFamily,
            fontSize: s.fontSize,
            strokeWeight: s.strokeWeight,
            lineHeight: s.lineHeight
        )
    }

    private func updateDrawableSize() {
        guard let metalLayer = layer as? CAMetalLayer, let window else { return }
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

    private func gridDimensions() -> (cols: Int, rows: Int)? {
        guard let renderer, let metalLayer = layer as? CAMetalLayer else { return nil }
        let ds = metalLayer.drawableSize
        // Require a real-sized viewport: avoids creating a 1x1 session that
        // immediately scrolls the shell prompt away before the real resize.
        guard ds.width >= 200 && ds.height >= 100 else { return nil }
        let (cols, rows) = renderer.layout.gridSize(viewportPixels: SIMD2(Float(ds.width), Float(ds.height)))
        guard cols >= 10 && rows >= 4 else { return nil }
        return (cols, rows)
    }

    private func ensureSession() {
        guard session == nil, let (cols, rows) = gridDimensions() else { return }
        let s = Session(cols: cols, rows: rows, cwd: initialCwd)
        s?.onOutput = { [weak self] in
            self?.sessionDidOutput()
        }
        s?.onChildExit = { [weak self] in
            guard let self else { return }
            self.delegate?.terminalViewDidTerminate(self)
        }
        s?.onBell = { [weak self] in
            guard let self else { return }
            self.delegate?.terminalView(self, didRequestAttention: .bell)
        }
        s?.onNotify = { [weak self] title, body in
            guard let self else { return }
            let t = title.isEmpty ? nil : title
            self.delegate?.terminalView(self, didRequestAttention: .notification(title: t, body: body))
        }
        session = s
    }

    private func resizeSessionIfNeeded() {
        guard let session, let (cols, rows) = gridDimensions() else { return }
        session.resize(cols: cols, rows: rows)
        // Only on an actual change: a drag inside one cell fires setFrameSize
        // repeatedly with the same grid, and the readout shouldn't blink.
        if let last = lastReportedGrid, last == (cols, rows) { return }
        let first = lastReportedGrid == nil
        lastReportedGrid = (cols, rows)
        guard !first else { return }        // opening a tab isn't a resize
        delegate?.terminalView(self, didResizeGridTo: cols, rows: rows)
    }

    @objc private func tick(_ sender: CADisplayLink) {
        if sender.duration > 0 { frameInterval = sender.duration }
        ensureSession()
        reportFocusIfChanged()
        reconcileThemeIfChanged()
        reconcileFontIfChanged()
        // While the child holds a synchronized update open (DEC 2026), hold the
        // last frame: apps that redraw several lines per frame — Homebrew's
        // download list, say — would otherwise be sampled mid-redraw and tear.
        // A resize still presents, since setFrameSize calls renderFrame direct.
        if session?.isSynchronizedUpdateActive == true { return }
        // Idle ticks used to rebuild and present the whole grid 120 times a
        // second whether or not a pixel had changed. The blink phase is part of
        // the check because it's the one thing that legitimately changes on a
        // timer rather than in response to an event.
        let blink = cursorBlinkOn()
        let stale = CACurrentMediaTime() - lastPresentTime >= Self.maxIdleInterval
        guard needsFrame || blink != lastRenderedBlink || stale else { return }
        renderFrame()
    }

    /// Focus reporting (?1004): apps that highlight the focused pane want to
    /// know when the window goes key. Only asks the session about the mode when
    /// focus actually changed, so the common case costs one Bool compare.
    private func reportFocusIfChanged() {
        let focused = window?.isKeyWindow ?? false
        guard focused != lastReportedFocus else { return }
        lastReportedFocus = focused
        invalidate()          // the cursor only draws in a focused window
        guard let session, session.inputModes.reportFocus else { return }
        session.write(Array((focused ? "\u{1B}[I" : "\u{1B}[O").utf8))
    }

    /// Builds the latest snapshot and presents one frame. Driven by the display
    /// link each tick, but also invoked synchronously from `setFrameSize` so a
    /// resize presents a correctly-sized frame in the same layout pass instead
    /// of letting Core Animation stretch the stale drawable until the next tick.
    private func renderFrame() {
        guard let metalLayer = layer as? CAMetalLayer, let renderer else { return }
        let snapshot = session?.snapshot(scrollOffset: scrollOffset)
            ?? TerminalSnapshot(cols: 1, rows: 1, cells: [Cell()], rowOffset: 0,
                                rowWrapped: [false],
                                cursorCol: 0, cursorRow: 0, cursorVisible: false,
                                scrollbackLines: 0, scrollOffset: 0, title: "",
                                prompts: [], scrolledRows: 0, currentDirectory: nil,
                                usingAlt: false, links: [])
        lastScrollbackLines = snapshot.scrollbackLines
        lastSnapshotCols = snapshot.cols
        lastSnapshotRows = snapshot.rows
        lastScrolledRows = snapshot.scrolledRows
        if snapshot.usingAlt != lastUsingAlt {
            // Entering or leaving the alt buffer replaces the grid wholesale.
            // Absolute lines survive the swap but the text under them doesn't,
            // so a selection held across it would describe nothing.
            lastUsingAlt = snapshot.usingAlt
            activeSelection = nil
        }
        if scrollOffset > lastScrollbackLines {
            scrollOffset = lastScrollbackLines
        }
        let fgProcess = session?.foregroundProcess()?.name
        if snapshot.title != lastReportedTitle
            || snapshot.currentDirectory != lastReportedCwd
            || fgProcess != lastReportedFgProcess {
            lastReportedTitle = snapshot.title
            lastReportedCwd = snapshot.currentDirectory
            lastReportedFgProcess = fgProcess
            delegate?.terminalView(self,
                                   didUpdate: snapshot.title,
                                   cwd: snapshot.currentDirectory,
                                   foregroundProcess: fgProcess)
        }
        // Trigger matches are only ever read while ⌘ is held — ⌘-click, the
        // pointing-hand affordance and the hover marking all gate on it — so
        // evaluating on every frame spent a fraction of a millisecond of the
        // keystroke path building strings and running regexes over them, only
        // to throw the answer away. Cleared rather than stale when ⌘ is up, so
        // nothing can read matches that describe a screen we've since redrawn.
        currentTriggerMatches = commandHeld
            ? evaluateTriggers(snapshot: snapshot)
            : []

        let focused = window?.isKeyWindow ?? false
        needsFrame = false
        lastRenderedBlink = cursorBlinkOn()
        lastPresentTime = CACurrentMediaTime()
        renderer.render(to: metalLayer,
                        snapshot: snapshot,
                        selection: viewportSelection(snapshot: snapshot),
                        highlights: composedHighlights(snapshot: snapshot),
                        focused: focused,
                        cursorOn: cursorBlinkOn())
    }

    private func composedHighlights(snapshot: TerminalSnapshot) -> [HighlightBand] {
        var bands: [HighlightBand] = []

        // Trigger highlights only show while ⌘ is held — same affordance
        // iTerm and Terminal.app use for "this is clickable". Drawn first
        // so search highlights paint on top.
        if commandHeld {
            for m in currentTriggerMatches {
                let style: HighlightStyle
                switch m.trigger.style {
                case .none:       continue        // clickable, but never drawn
                case .background: style = .background
                case .underline:  style = .underline
                case .both:       style = .both
                case .text:       style = .text
                }
                bands.append(HighlightBand(
                    col: m.viewportCol,
                    row: m.viewportRow,
                    length: m.length,
                    color: m.trigger.color,
                    style: style
                ))
            }

            // The link under the pointer is marked whatever its trigger's own
            // style is: this isn't decoration, it's showing which run of text
            // ⌘-click is about to act on. Every segment sharing the hovered
            // match's id is drawn, so a URL that wrapped is marked across all
            // its rows rather than only the one being pointed at — the extent
            // of the marking is the extent of what opens.
            if let hovered = hoveredTriggerMatch(), hovered.trigger.clickAction != nil {
                let accent = ThemeStore.currentTheme.linkAccent
                for m in currentTriggerMatches where m.id == hovered.id {
                    // Text and rule in the same colour, so the link reads as
                    // one object rather than as text with something drawn
                    // under it. Two bands rather than one combined style:
                    // they're independent effects and compose in the renderer.
                    for style in [HighlightStyle.underline, .text] {
                        bands.append(HighlightBand(
                            col: m.viewportCol,
                            row: m.viewportRow,
                            length: m.length,
                            color: accent,
                            style: style
                        ))
                    }
                }
            }
        }

        // Search highlights — current match brighter than the rest.
        if let search = search {
            let topAbs = snapshot.scrolledRows - snapshot.scrollOffset
            let currentColor = SIMD4<Float>(1.00, 0.78, 0.20, 0.65)
            let otherColor   = SIMD4<Float>(1.00, 0.78, 0.20, 0.28)
            for (i, m) in search.matches.enumerated() {
                let vr = m.absoluteLine - topAbs
                if vr >= 0 && vr < snapshot.rows {
                    bands.append(HighlightBand(
                        col: m.startCol, row: vr,
                        length: m.endCol - m.startCol,
                        color: i == search.currentIndex ? currentColor : otherColor,
                        style: .background
                    ))
                }
            }
        }

        return bands
    }

    /// 530 ms on / 530 ms off, with a 500 ms "always on" grace after the last
    /// keystroke so the cursor doesn't disappear while you're typing.
    ///
    /// Constant `true` when blinking is off, which does more than hold the
    /// cursor still: the idle dirty check in `tick` treats the blink phase as
    /// the one thing that legitimately changes on a timer, so a steady cursor
    /// also stops the two redraws a second an otherwise idle screen was doing.
    private func cursorBlinkOn() -> Bool {
        guard ThemeStore.shared.settings.blinkCursor else { return true }
        let elapsed = CACurrentMediaTime() - lastInputTime
        if elapsed < 0.5 { return true }
        let cyclePos = (elapsed - 0.5).truncatingRemainder(dividingBy: 1.06)
        return cyclePos < 0.53
    }
}
