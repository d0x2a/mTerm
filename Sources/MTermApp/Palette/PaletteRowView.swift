import MTermCore
import AppKit

/// The hub's colours, derived from the active terminal theme rather than the
/// system appearance.
///
/// Same reasoning as `SidebarView.applyThemeBackground`: the panel floats over
/// the terminal, so it has to belong to the terminal's palette. Taking system
/// semantic colours here would put light text on a dark theme's panel whenever
/// macOS itself is in light mode. The one exception is the selection rail,
/// which stays `controlAccentColor` — that is the user's own accent, and it
/// reads on both grounds.
struct PaletteColors {
    let panel: NSColor
    let elevated: NSColor
    let border: NSColor
    let ink: NSColor
    let dim: NSColor
    /// The filled band behind the selected row. Tinted with the user's own
    /// accent rather than a neutral wash: it has to carry the selection on its
    /// own now that the row no longer draws a rail beside it.
    let selection: NSColor
    /// What the hub's elevation is cast in. Pure black under a light theme
    /// reads as dirt, so it takes a darkened cast of the theme's own
    /// background and lets opacity do the rest.
    let shadow: NSColor
    let isDark: Bool

    /// `theme` is the *active tab's* effective theme, not the app-wide one: a
    /// profile can pin a theme, and a hub floating over a pinned-dark tab has
    /// to be dark even when Appearance says light.
    static func current(for theme: Theme = ThemeStore.currentTheme) -> PaletteColors {
        let isDark = theme.appearance == .dark
        let white = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        let black = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)

        func color(_ c: SIMD4<Float>) -> NSColor {
            NSColor(srgbRed: CGFloat(c.x), green: CGFloat(c.y),
                    blue: CGFloat(c.z), alpha: 1)
        }
        func lift(_ base: NSColor, _ amount: CGFloat, toward target: NSColor) -> NSColor {
            base.blended(withFraction: amount, of: target) ?? base
        }

        let background = color(theme.background)
        let ink = color(theme.foreground)

        // Elevation moves toward light in *both* appearances, because a raised
        // surface catches more light. This is where it parts company with
        // `SidebarView.applyThemeBackground`, which darkens a light theme —
        // right for the sidebar, which is recessed *beside* the terminal, and
        // wrong here: darkening Pencil Light's near-white background turned the
        // hub into a grey box floating on a white terminal, which is exactly
        // what "doesn't match the theme" looks like.
        //
        // On a light theme that leaves the panel almost the value of the
        // terminal behind it, and the border and the shadow do the separating.
        // That is the intended result — a white card on an off-white ground,
        // not a grey one — and it keeps a tinted theme's tint: Solarized
        // Light's cream stays cream instead of going drab.
        let panel = lift(background, isDark ? 0.13 : 0.55, toward: white)

        return PaletteColors(
            panel: panel,
            // Chips and pills need to separate from the panel, so they go the
            // other way on a light theme — there is no room above white.
            elevated: lift(panel, 0.07, toward: isDark ? white : black),
            border: NSColor(white: isDark ? 1 : 0, alpha: isDark ? 0.18 : 0.13),
            ink: ink,
            // Mixed toward the panel rather than toward black or white, so the
            // step down from `ink` is always the same *relative* step. Pushing
            // toward black instead made secondary text nearly invisible on the
            // low-contrast themes — Solarized Dark's foreground is already a
            // mid grey, and darkening that further left paths unreadable.
            dim: ink.blended(withFraction: 0.42, of: panel) ?? ink,
            selection: NSColor.controlAccentColor.withAlphaComponent(isDark ? 0.30 : 0.20),
            shadow: lift(background, 0.8, toward: black),
            isDark: isDark
        )
    }
}

/// A small filled chip — a tab's foreground process, a theme's appearance.
final class PaletteRowPill: NSView {
    let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 4
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 17),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

/// One row. Rebuilt per keystroke rather than recycled — the whole list is at
/// most a few dozen rows, and a recycled row that kept a stale highlight range
/// is a subtler bug than a rebuild is a cost.
///
/// Every kind of row shares one grid, which is the whole point of the layout:
/// the icon sits under the search field's magnifier and the title under the
/// text you typed, so a result lines up with the query that produced it. The
/// tab index moved to the right to make that possible — it is a shortcut hint,
/// and the action rows were already showing theirs on the right.
final class PaletteRowView: NSView {
    static let height: CGFloat = 30
    /// Icon column, aligned with the field's magnifying glass.
    static let iconInset: CGFloat = 9
    /// Distance from the icon to the title. Puts the title under the field's
    /// text; `PaletteHeaderView` uses the same figure.
    static let titleGap: CGFloat = 11

    private let swatch = NSView()
    private let marker = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")
    private let pill = PaletteRowPill()
    private let rightStack = NSStackView()
    private let closeButton = NSButton()
    /// Tab rows reserve the close button's slot whether or not it is showing,
    /// so nothing beside it jumps sideways as the selection moves.
    private var rightToEdge: NSLayoutConstraint!
    private var rightToCloseButton: NSLayoutConstraint!

    private var colors = PaletteColors.current()
    var onClick: (() -> Void)?
    var onHover: (() -> Void)?
    /// Set on tab rows only. The same thing ⌘⌫ does, made visible — the
    /// keyboard affordance is named in the footer, but nothing in the list
    /// says a row can be closed at all until a ✕ appears on it.
    var onClose: (() -> Void)?
    private var trackingAreaRef: NSTrackingArea?
    private var pressed = false

    var isSelected: Bool = false { didSet { refreshSelection() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6

        swatch.wantsLayer = true
        swatch.layer?.cornerRadius = 3
        swatch.layer?.borderWidth = 1
        swatch.isHidden = true

        marker.imageScaling = .scaleProportionallyDown

        title.font = .systemFont(ofSize: 13)
        title.lineBreakMode = .byTruncatingTail
        detail.lineBreakMode = .byTruncatingTail
        badge.font = .systemFont(ofSize: 11, weight: .medium)
        badge.alignment = .right

        closeButton.isBordered = false
        closeButton.bezelStyle = .inline
        closeButton.imagePosition = .imageOnly
        closeButton.image = Self.symbol("xmark")
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.isHidden = true
        closeButton.toolTip = "Close this tab (⌘⌫)"

        rightStack.orientation = .horizontal
        rightStack.spacing = 8
        rightStack.alignment = .centerY
        rightStack.setViews([pill, badge], in: .leading)

        for view in [swatch, marker, title, detail, rightStack, closeButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        title.setContentHuggingPriority(.required, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        detail.setContentHuggingPriority(.defaultLow, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        rightStack.setContentHuggingPriority(.required, for: .horizontal)
        rightStack.setContentCompressionResistancePriority(.required, for: .horizontal)

        rightToEdge = rightStack.trailingAnchor.constraint(
            equalTo: trailingAnchor, constant: -12)
        rightToCloseButton = rightStack.trailingAnchor.constraint(
            equalTo: closeButton.leadingAnchor, constant: -8)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),

            marker.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.iconInset),
            marker.centerYAnchor.constraint(equalTo: centerYAnchor),
            marker.widthAnchor.constraint(equalToConstant: 14),
            marker.heightAnchor.constraint(equalToConstant: 14),

            swatch.centerXAnchor.constraint(equalTo: marker.centerXAnchor),
            swatch.centerYAnchor.constraint(equalTo: centerYAnchor),
            swatch.widthAnchor.constraint(equalToConstant: 22),
            swatch.heightAnchor.constraint(equalToConstant: 14),

            title.leadingAnchor.constraint(equalTo: marker.trailingAnchor,
                                           constant: Self.titleGap),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),

            detail.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 10),
            detail.centerYAnchor.constraint(equalTo: centerYAnchor),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: rightStack.leadingAnchor,
                                             constant: -10),

            rightStack.centerYAnchor.constraint(equalTo: centerYAnchor),

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),
        ])
        rightToEdge.isActive = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = trackingAreaRef { removeTrackingArea(area) }
        let area = NSTrackingArea(
            rect: bounds,
            // `.mouseMoved` as well as enter/exit: with the pointer already
            // resting on a row when the hub opens, crossing into a *different*
            // row would otherwise be the only way to start hovering.
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) { onHover?() }
    override func mouseMoved(with event: NSEvent) { onHover?() }

    /// Consumed rather than forwarded. A view that doesn't handle `mouseDown`
    /// never becomes the window's mouse-down view and so never receives the
    /// matching `mouseUp`: the press falls through to the terminal underneath,
    /// which takes first responder, ends the hub's field editor and dismisses
    /// it — a click that looked like it did nothing but close the hub.
    /// `SidebarView`'s rows answer the same rule by acting on the press.
    override func mouseDown(with event: NSEvent) {
        pressed = true
    }

    /// Acting on release, not press, so sliding off a row still cancels —
    /// running a command is not something to commit to on the way down.
    override func mouseUp(with event: NSEvent) {
        let wasPressed = pressed
        pressed = false
        guard wasPressed,
              bounds.contains(convert(event.locationInWindow, from: nil))
        else { return }
        // Last statement: `onClick` tears this view out of the hierarchy.
        onClick?()
    }

    // MARK: content

    func apply(_ scored: ScoredItem, colors: PaletteColors) {
        self.colors = colors
        let item = scored.item

        title.attributedStringValue = Self.highlighted(
            item.label, ranges: scored.labelRanges,
            font: .systemFont(ofSize: 13), color: colors.ink)

        swatch.isHidden = true
        marker.isHidden = false
        detail.isHidden = true
        badge.isHidden = true
        pill.isHidden = true
        badge.textColor = colors.dim

        let closable = item.kind == .tab
        rightToCloseButton.isActive = false
        rightToEdge.isActive = false
        (closable ? rightToCloseButton : rightToEdge)?.isActive = true

        switch item.kind {
        case .tab:
            applyTab(scored, colors: colors)
        case .action:
            marker.image = Self.symbol("command")
            marker.contentTintColor = colors.dim
            setBadge(item.shortcut)
        case .theme:
            applyTheme(item, colors: colors)
        case .setting:
            marker.image = Self.symbol("gearshape")
            marker.contentTintColor = colors.dim
            // The pane goes in the right-hand column, not inline after the
            // title. It is a category drawn from a set of five, so following a
            // title of varying length made it land at a different x on every
            // row — a ragged echo down the list. A tab's directory stays inline
            // because it identifies the row rather than classifying it.
            setBadge(item.secondary.first, font: .systemFont(ofSize: 11.5))
        }
        refreshSelection()
    }

    private func applyTab(_ scored: ScoredItem, colors: PaletteColors) {
        guard let info = scored.item.tab else { return }
        setBadge(info.index <= 9 ? "⌘\(info.index)" : nil)

        if info.wantsAttention {
            marker.image = Self.symbol("bell.fill")
            marker.contentTintColor = .systemOrange
        } else if info.process == nil {
            marker.image = Self.symbol("circle")
            marker.contentTintColor = colors.dim
        } else {
            marker.image = Self.symbol("circle.fill")
            marker.contentTintColor = .controlAccentColor
        }

        // "~" is its own basename, so an unqualified home tab would otherwise
        // read "~   ~". Same for any tab sitting directly in a directory whose
        // name it took.
        let directory = info.directory == scored.item.label ? "" : info.directory
        let text = info.windowLabel.map { directory.isEmpty ? $0 : "\(directory)  ·  \($0)" }
            ?? directory
        detail.isHidden = text.isEmpty
        detail.attributedStringValue = Self.highlighted(
            text, ranges: scored.ranges(forSecondary: 0),
            font: .monospacedSystemFont(ofSize: 11.5, weight: .regular),
            color: colors.dim)

        if info.isCurrent {
            setPill("current", filled: false,
                    font: .systemFont(ofSize: 10, weight: .medium), colors: colors)
        } else if let tmux = info.tmuxWindowID {
            setPill("tmux:\(tmux)", filled: true,
                    font: .monospacedSystemFont(ofSize: 10.5, weight: .medium),
                    colors: colors, ink: colors.ink)
        } else if let process = info.process {
            setPill(process, filled: true,
                    font: .monospacedSystemFont(ofSize: 10.5, weight: .medium),
                    colors: colors,
                    ranges: scored.ranges(forSecondary: 1))
        }
    }

    private func applyTheme(_ item: PaletteItem, colors: PaletteColors) {
        marker.isHidden = true
        swatch.isHidden = false
        guard let theme = item.theme else { return }
        func color(_ c: SIMD4<Float>) -> CGColor {
            NSColor(srgbRed: CGFloat(c.x), green: CGFloat(c.y),
                    blue: CGFloat(c.z), alpha: 1).cgColor
        }
        swatch.layer?.backgroundColor = color(theme.background)
        swatch.layer?.borderColor = colors.border.cgColor
        // The blue slot, which is also what `Theme.linkAccent` reads — enough
        // of the palette to tell Nord from Dracula at a glance.
        swatch.layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        let stripe = CALayer()
        stripe.frame = CGRect(x: 22 - 8, y: 0, width: 8, height: 14)
        stripe.backgroundColor = color(theme.linkAccent)
        swatch.layer?.addSublayer(stripe)

        setPill(theme.appearance == .dark ? "dark" : "light", filled: false,
                font: .systemFont(ofSize: 10, weight: .medium), colors: colors)
    }

    // MARK: row parts

    private func setBadge(_ text: String?,
                          font: NSFont = .systemFont(ofSize: 11, weight: .medium)) {
        guard let text, !text.isEmpty else { badge.isHidden = true; return }
        badge.isHidden = false
        badge.font = font
        badge.stringValue = text
    }

    private func setDetail(_ text: String, font: NSFont, colors: PaletteColors) {
        guard !text.isEmpty else { detail.isHidden = true; return }
        detail.isHidden = false
        detail.font = font
        detail.textColor = colors.dim
        detail.stringValue = text
    }

    private func setPill(_ text: String, filled: Bool, font: NSFont,
                         colors: PaletteColors, ink: NSColor? = nil,
                         ranges: [Range<Int>] = []) {
        pill.isHidden = false
        pill.label.attributedStringValue = Self.highlighted(
            text, ranges: ranges, font: font, color: ink ?? colors.dim)
        pill.layer?.backgroundColor = filled
            ? colors.elevated.cgColor
            : NSColor.clear.cgColor
    }

    private func refreshSelection() {
        layer?.backgroundColor = isSelected ? colors.selection.cgColor : NSColor.clear.cgColor
        // Hidden, not merely transparent: a disabled button still hit-tests,
        // and an invisible one sitting over the right edge of an action row
        // would swallow the click that should have run the action.
        closeButton.isHidden = !(isSelected && onClose != nil)
        closeButton.contentTintColor = colors.dim
    }

    @objc private func closeTapped() { onClose?() }

    // MARK: helpers

    private static func symbol(_ name: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }

    /// Bolds the characters the query landed on. Ranges are `Character`
    /// offsets from `Fuzzy`, converted here — and clamped rather than trusted,
    /// because they were measured against the lowercased field and a few
    /// scripts change length when they lowercase.
    static func highlighted(_ text: String, ranges: [Range<Int>],
                            font: NSFont, color: NSColor) -> NSAttributedString {
        let out = NSMutableAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: color])
        guard !ranges.isEmpty else { return out }
        let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        for range in ranges {
            guard let lo = text.index(text.startIndex, offsetBy: range.lowerBound,
                                      limitedBy: text.endIndex),
                  let hi = text.index(text.startIndex, offsetBy: range.upperBound,
                                      limitedBy: text.endIndex),
                  lo < hi
            else { continue }
            out.addAttributes([.font: bold], range: NSRange(lo..<hi, in: text))
        }
        return out
    }
}

/// A section header — "Tabs", "Actions" — between runs of rows.
final class PaletteHeaderView: NSView {
    private let label = NSTextField(labelWithString: "")

    init(title: String, colors: PaletteColors) {
        super.init(frame: .zero)
        label.stringValue = title.uppercased()
        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.textColor = colors.dim
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            // Aligned with the row titles below it, which in turn sit under
            // the search field's text. `+ 5` is the inset the rows carry so
            // their selection band can round off short of the panel edge.
            label.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: 5 + PaletteRowView.iconInset + 14 + PaletteRowView.titleGap),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            heightAnchor.constraint(equalToConstant: 26),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}
