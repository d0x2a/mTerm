import SwiftUI

/// Every focusable control in the Settings window, in no particular order —
/// each pane declares its own traversal order below.
enum SettingsField: Hashable {
    /// The category list. Always the first Tab stop, and where focus sits when
    /// Settings opens — so ↑/↓ change section until Tab moves into the pane.
    case sidebar
    // Appearance
    case mode, lightTheme, darkTheme, importTheme
    case fontFamily, fontSize, strokeWeight, lineHeight, blinkCursor
    // General
    case warnOnClose
    // Notifications
    case notificationsEnabled, notifyOnBell, notifyOnlyWhenUnfocused
}

/// Tab traversal, implemented by hand rather than left to AppKit.
///
/// AppKit only puts sliders, checkboxes and pop-ups in the key view loop when
/// Full Keyboard Access is on, and that is a system-wide setting most people
/// leave off. It can't be forced per-app either: setting `AppleKeyboardUIMode`
/// in the app's own defaults domain leaves `NSApp.isFullKeyboardAccessEnabled`
/// false (verified on macOS 26). So Settings walks its own ordered list.
///
/// `stops` always begins with `.sidebar`, and a nil `current` is treated as
/// sitting there — which is how Settings opens, with no control selected and
/// the arrow keys still driving the category list. The first Tab therefore
/// lands on the first *control*, not back on the list.
func nextFocus(after current: SettingsField?,
               in stops: [SettingsField],
               by delta: Int) -> SettingsField? {
    guard !stops.isEmpty else { return nil }
    let i = current.flatMap { stops.firstIndex(of: $0) } ?? 0
    let n = stops.count
    return stops[((i + delta) % n + n) % n]
}

/// Whether the pane's controls are part of the focus system at all.
///
/// False until the first Tab. SwiftUI picks its own initial focus target when a
/// window opens — the first `.focusable()` view it finds, which is the topmost
/// control in the pane — and `.defaultFocus` does not reliably outrank that
/// across a `NavigationSplitView`'s two columns. A control that isn't focusable
/// can't be chosen at all, so Settings opens inert and the arrow keys stay with
/// the category list until Tab asks for something else.
private struct SettingsKeyboardActiveKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var settingsKeyboardActive: Bool {
        get { self[SettingsKeyboardActiveKey.self] }
        set { self[SettingsKeyboardActiveKey.self] = newValue }
    }
}

/// Marks one control as focusable and gives it keyboard behaviour.
///
/// `onAdjust` receives -1 for ←/↓ and +1 for →/↑, which is the direction
/// convention every AppKit control uses. `onActivate` fires on Space and
/// Return. A control that passes neither is still Tab-reachable — a focus
/// stop with nothing to adjust, like a preview.
struct FocusableControl: ViewModifier {
    let field: SettingsField
    @FocusState.Binding var focus: SettingsField?
    var onAdjust: ((Int) -> Void)?
    var onActivate: (() -> Void)?

    @Environment(\.settingsKeyboardActive) private var keyboardActive

    func body(content: Content) -> some View {
        content
            .focusable(keyboardActive)
            .focused($focus, equals: field)
            .onKeyPress(keys: [.leftArrow, .downArrow]) { _ in
                guard let onAdjust else { return .ignored }
                onAdjust(-1)
                return .handled
            }
            .onKeyPress(keys: [.rightArrow, .upArrow]) { _ in
                guard let onAdjust else { return .ignored }
                onAdjust(1)
                return .handled
            }
            .onKeyPress(keys: [.space, .return]) { _ in
                guard let onActivate else { return .ignored }
                onActivate()
                return .handled
            }
    }
}

extension View {
    func focusableControl(_ field: SettingsField,
                          focus: FocusState<SettingsField?>.Binding,
                          onAdjust: ((Int) -> Void)? = nil,
                          onActivate: (() -> Void)? = nil) -> some View {
        modifier(FocusableControl(field: field, focus: focus,
                                  onAdjust: onAdjust, onActivate: onActivate))
    }
}

/// A labelled slider with its value read out on the right, adjustable with the
/// arrow keys once focused. Home/End jump to the ends of the range.
struct AdjustableSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    /// How far one arrow press moves the value.
    let step: Double
    /// Detent for *dragging*, kept separate from the keyboard increment so
    /// adding arrow-key support doesn't quantise a slider that was free to
    /// move continuously under the mouse. nil = continuous.
    var dragStep: Double?
    let format: String
    let field: SettingsField
    @FocusState.Binding var focus: SettingsField?

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value))
                    .foregroundColor(.secondary)
                    .font(.system(.body, design: .monospaced))
                    .monospacedDigit()
            }
            slider
                .focusableControl(field, focus: $focus) { direction in
                    adjust(by: Double(direction) * step)
                }
                .onKeyPress(.home) { value = range.lowerBound; return .handled }
                .onKeyPress(.end)  { value = range.upperBound; return .handled }
        }
    }

    @ViewBuilder
    private var slider: some View {
        if let dragStep {
            Slider(value: $value, in: range, step: dragStep)
        } else {
            Slider(value: $value, in: range)
        }
    }

    /// Snapped back onto the step grid so repeated presses can't accumulate
    /// float drift and leave the readout showing 0.6499999.
    private func adjust(by delta: Double) {
        let raw = min(max(value + delta, range.lowerBound), range.upperBound)
        let snapped = (raw / step).rounded() * step
        value = min(max(snapped, range.lowerBound), range.upperBound)
    }
}

/// Moves a selection within a list of ids by `direction`, clamping at the ends
/// rather than wrapping — matching how an AppKit pop-up behaves under ←/→.
func stepSelection<T: Equatable>(_ selection: inout T, in options: [T], by direction: Int) {
    guard let i = options.firstIndex(of: selection) else {
        if let first = options.first { selection = first }
        return
    }
    let next = min(max(i + direction, 0), options.count - 1)
    selection = options[next]
}
