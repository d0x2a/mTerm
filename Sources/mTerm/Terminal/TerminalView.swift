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

    private var scrollOffset: Int = 0
    private var scrollResidue: CGFloat = 0
    private var lastScrollbackLines: Int = 0
    private var lastSnapshotCols: Int = 1
    private var lastSnapshotRows: Int = 1
    private var lastReportedTitle: String = ""
    private var lastReportedCwd: String? = nil
    private var lastInputTime: CFTimeInterval = CACurrentMediaTime()

    private struct ActiveSelection {
        var anchor: (col: Int, row: Int)
        var end: (col: Int, row: Int)
        var dragging: Bool

        var normalized: Selection {
            let aBeforeE = anchor.row < end.row
                || (anchor.row == end.row && anchor.col <= end.col)
            let s = aBeforeE ? anchor : end
            let e = aBeforeE ? end : anchor
            return Selection(startCol: s.col, startRow: s.row,
                             endCol: e.col, endRow: e.row)
        }
    }

    private var activeSelection: ActiveSelection?

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
    private var lastMouseCoord: (col: Int, row: Int)? = nil
    private var lastAppliedTheme: Theme = ThemeStore.currentTheme
    private var lastAppliedFontFamily: String = ThemeStore.shared.settings.fontFamily
    private var lastAppliedFontSize: Double = ThemeStore.shared.settings.fontSize
    private var lastAppliedThinStrokes: Bool = ThemeStore.shared.settings.thinStrokes

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
            || s.thinStrokes != lastAppliedThinStrokes
        else { return }
        lastAppliedFontFamily = s.fontFamily
        lastAppliedFontSize = s.fontSize
        lastAppliedThinStrokes = s.thinStrokes
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
            thinStrokes: lastAppliedThinStrokes
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
    }

    // MARK: input

    override func keyDown(with event: NSEvent) {
        guard let session else { return super.keyDown(with: event) }
        let bytes = bytesForKey(event)
        if !bytes.isEmpty {
            scrollOffset = 0          // typing always snaps to bottom
            scrollResidue = 0
            activeSelection = nil
            lastInputTime = CACurrentMediaTime()
            session.write(bytes)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let coord = cellCoord(at: convert(event.locationInWindow, from: nil))
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if mods.contains(.command) {
            if let match = triggerMatch(at: coord) {
                handleTriggerClick(match)
                return                       // don't start a selection
            }
        }

        if event.clickCount >= 3 {
            // Triple-click: select the whole visible line.
            let lastCol = max(0, lastSnapshotCols - 1)
            activeSelection = ActiveSelection(
                anchor: (col: 0, row: coord.row),
                end:    (col: lastCol, row: coord.row),
                dragging: false
            )
        } else {
            activeSelection = ActiveSelection(anchor: coord, end: coord, dragging: true)
        }
    }

    private func triggerMatch(at coord: (col: Int, row: Int)) -> TriggerMatch? {
        currentTriggerMatches.first {
            $0.viewportRow == coord.row &&
            coord.col >= $0.viewportCol &&
            coord.col < $0.viewportCol + $0.length
        }
    }

    private func handleTriggerClick(_ match: TriggerMatch) {
        guard let action = match.trigger.clickAction else { return }
        switch action {
        case .openURL:
            if let url = URL(string: match.text) {
                NSWorkspace.shared.open(url)
            }
        case .openFile:
            let url = resolveFileURL(match.text)
            NSWorkspace.shared.open(url)
        case .runCommand(let template):
            // Substitute $1 with the matched text, append \r so the shell
            // actually executes it.
            var cmd = template.replacingOccurrences(of: "$1", with: match.text)
            cmd.append("\r")
            session?.write(Array(cmd.utf8))
        }
    }

    private func resolveFileURL(_ path: String) -> URL {
        var p = path
        if p.hasPrefix("~") {
            p = (p as NSString).expandingTildeInPath
        }
        if !p.hasPrefix("/"), let cwd = session?.currentDirectory {
            p = (cwd as NSString).appendingPathComponent(p)
        }
        return URL(fileURLWithPath: p)
    }

    override func mouseDragged(with event: NSEvent) {
        guard activeSelection != nil else { return }
        let coord = cellCoord(at: convert(event.locationInWindow, from: nil))
        activeSelection?.end = coord
        activeSelection?.dragging = true
    }

    override func mouseUp(with event: NSEvent) {
        guard var sel = activeSelection else { return }
        sel.dragging = false
        // A pure click (no drag) clears the selection.
        if sel.anchor == sel.end {
            activeSelection = nil
        } else {
            activeSelection = sel
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let coord = cellCoord(at: convert(event.locationInWindow, from: nil))
        lastMouseCoord = coord
        updateCursorAffordance()
    }

    override func mouseExited(with event: NSEvent) {
        lastMouseCoord = nil
        commandHeld = false
        updateCursorAffordance()
    }

    override func flagsChanged(with event: NSEvent) {
        let cmd = event.modifierFlags.contains(.command)
        if cmd != commandHeld {
            commandHeld = cmd
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
        if commandHeld,
           let coord = lastMouseCoord,
           let match = triggerMatch(at: coord),
           match.trigger.clickAction != nil {
            NSCursor.pointingHand.set()
        } else {
            NSCursor.iBeam.set()
        }
    }

    private func cellCoord(at point: NSPoint) -> (col: Int, row: Int) {
        guard let renderer else { return (0, 0) }
        let scale = CGFloat(renderer.layout.scale)
        let cellWPts = CGFloat(renderer.layout.cellWidth) / scale
        let cellHPts = CGFloat(renderer.layout.cellHeight) / scale
        guard cellWPts > 0, cellHPts > 0 else { return (0, 0) }
        let viewportPx = SIMD2<Float>(
            Float(bounds.size.width * scale),
            Float(bounds.size.height * scale)
        )
        let originPx = renderer.layout.origin(cols: lastSnapshotCols,
                                              viewportPixels: viewportPx)
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

        let next = scrollOffset + rowDelta
        scrollOffset = max(0, min(next, lastScrollbackLines))
    }

    @objc func paste(_ sender: Any?) {
        guard let session,
              let str = NSPasteboard.general.string(forType: .string),
              !str.isEmpty
        else { return }
        // Most shells expect carriage returns, not line feeds, for "enter".
        var normalized = str.replacingOccurrences(of: "\r\n", with: "\r")
        normalized = normalized.replacingOccurrences(of: "\n", with: "\r")
        session.write(Array(normalized.utf8))
    }

    @objc func copy(_ sender: Any?) {
        guard let activeSelection, let session else { return }
        let snapshot = session.snapshot(scrollOffset: scrollOffset)
        let text = activeSelection.normalized.extractText(from: snapshot)
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    @objc func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)):
            return activeSelection != nil
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
        search = nil
        window?.makeFirstResponder(self)
    }

    private func updateSearch(query: String, regex: Bool) {
        guard let session, !query.isEmpty else {
            search = nil
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
        search = state
        searchBar?.matchCount = matches.count
        searchBar?.currentMatch = state.currentIndex
    }

    private func cycleMatch(by delta: Int) {
        guard var s = search, !s.matches.isEmpty else { return }
        let n = s.matches.count
        s.currentIndex = ((s.currentIndex + delta) % n + n) % n
        search = s
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
        guard let session,
              let newOffset = session.jumpToPrompt(direction: -1, from: scrollOffset)
        else { return }
        scrollOffset = newOffset
        scrollResidue = 0
        activeSelection = nil
    }

    @objc func jumpToNextPrompt(_ sender: Any?) {
        guard let session else { return }
        // direction > 0 returns 0 if no prompt below — i.e. snap to bottom.
        scrollOffset = session.jumpToPrompt(direction: 1, from: scrollOffset) ?? 0
        scrollResidue = 0
        activeSelection = nil
    }

    private func bytesForKey(_ event: NSEvent) -> [UInt8] {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let opt = mods.contains(.option)
        let shift = mods.contains(.shift)

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
            thinStrokes: s.thinStrokes
        )
    }

    private func updateDrawableSize() {
        guard let metalLayer = layer as? CAMetalLayer, let window else { return }
        let scale = window.backingScaleFactor
        metalLayer.contentsScale = scale
        let size = bounds.size
        metalLayer.drawableSize = CGSize(
            width: max(1, size.width * scale),
            height: max(1, size.height * scale)
        )
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
        s?.onChildExit = { [weak self] in
            guard let self else { return }
            self.delegate?.terminalViewDidTerminate(self)
        }
        session = s
    }

    private func resizeSessionIfNeeded() {
        guard let session, let (cols, rows) = gridDimensions() else { return }
        session.resize(cols: cols, rows: rows)
    }

    @objc private func tick(_ sender: CADisplayLink) {
        guard let metalLayer = layer as? CAMetalLayer, let renderer else { return }
        ensureSession()
        reconcileThemeIfChanged()
        reconcileFontIfChanged()
        let snapshot = session?.snapshot(scrollOffset: scrollOffset)
            ?? TerminalSnapshot(cols: 1, rows: 1, cells: [Cell()],
                                cursorCol: 0, cursorRow: 0, cursorVisible: false,
                                scrollbackLines: 0, scrollOffset: 0, title: "",
                                prompts: [], scrolledRows: 0, currentDirectory: nil)
        lastScrollbackLines = snapshot.scrollbackLines
        lastSnapshotCols = snapshot.cols
        lastSnapshotRows = snapshot.rows
        if scrollOffset > lastScrollbackLines {
            scrollOffset = lastScrollbackLines
        }
        if snapshot.title != lastReportedTitle
            || snapshot.currentDirectory != lastReportedCwd {
            lastReportedTitle = snapshot.title
            lastReportedCwd = snapshot.currentDirectory
            delegate?.terminalView(self,
                                   didUpdate: snapshot.title,
                                   cwd: snapshot.currentDirectory)
        }
        currentTriggerMatches = triggerEvaluator.evaluate(snapshot: snapshot)

        let focused = window?.isKeyWindow ?? false
        renderer.render(to: metalLayer,
                        snapshot: snapshot,
                        selection: activeSelection?.normalized,
                        highlights: composedHighlights(snapshot: snapshot),
                        focused: focused,
                        cursorOn: cursorBlinkOn())
    }

    private func composedHighlights(snapshot: TerminalSnapshot) -> [HighlightBand] {
        var bands: [HighlightBand] = []

        // Trigger highlights only show while ⌘ is held — same affordance iTerm
        // and Terminal.app use for "this is clickable". Drawn first so search
        // highlights paint on top.
        if commandHeld {
            for m in currentTriggerMatches {
                let style: HighlightStyle
                switch m.trigger.style {
                case .background: style = .background
                case .underline:  style = .underline
                case .both:       style = .both
                }
                bands.append(HighlightBand(
                    col: m.viewportCol,
                    row: m.viewportRow,
                    length: m.length,
                    color: m.trigger.color,
                    style: style
                ))
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
    private func cursorBlinkOn() -> Bool {
        let elapsed = CACurrentMediaTime() - lastInputTime
        if elapsed < 0.5 { return true }
        let cyclePos = (elapsed - 0.5).truncatingRemainder(dividingBy: 1.06)
        return cyclePos < 0.53
    }
}
