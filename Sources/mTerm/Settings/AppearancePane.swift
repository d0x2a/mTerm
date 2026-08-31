import AppKit
import SwiftUI
import UniformTypeIdentifiers
import simd

struct AppearancePane: View {
    @ObservedObject private var store = ThemeStore.shared
    @ObservedObject private var fonts = FontCatalogStore.shared

    private var lightThemes: [Theme] {
        store.allThemes.filter { $0.appearance == .light }
    }
    private var darkThemes: [Theme] {
        store.allThemes.filter { $0.appearance == .dark }
    }

    @FocusState.Binding var focus: SettingsField?
    @State private var fontPicker = FontPickerHandle()

    /// Tab order for this pane, top to bottom as the controls are laid out.
    /// Read by `SettingsView`, which owns the focus state and the Tab handler.
    static let fieldOrder: [SettingsField] = [
        .mode, .lightTheme, .darkTheme, .importTheme,
        .fontFamily, .fontSize, .strokeWeight, .lineHeight, .blinkCursor
    ]

    init(focus: FocusState<SettingsField?>.Binding) {
        self._focus = focus
    }

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Mode", selection: $store.settings.appearanceMode) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .focusableControl(.mode, focus: $focus) { direction in
                    stepSelection(&store.settings.appearanceMode,
                                  in: AppearanceMode.allCases, by: direction)
                }
            }

            Section("Theme") {
                Picker("Light theme",
                       selection: $store.settings.lightThemeId) {
                    ForEach(lightThemes) { Text($0.name).tag($0.id) }
                }
                .focusableControl(.lightTheme, focus: $focus) { direction in
                    stepSelection(&store.settings.lightThemeId,
                                  in: lightThemes.map(\.id), by: direction)
                }
                Picker("Dark theme",
                       selection: $store.settings.darkThemeId) {
                    ForEach(darkThemes) { Text($0.name).tag($0.id) }
                }
                .focusableControl(.darkTheme, focus: $focus) { direction in
                    stepSelection(&store.settings.darkThemeId,
                                  in: darkThemes.map(\.id), by: direction)
                }
                HStack {
                    Spacer()
                    Button("Import theme…") { importTheme() }
                        .focusableControl(.importTheme, focus: $focus,
                                          onActivate: { importTheme() })
                }
            }

            Section("Font") {
                LabeledContent("Family") {
                    FontFamilyPicker(selection: $store.settings.fontFamily,
                                     recommended: fonts.available,
                                     others: fonts.others,
                                     handle: fontPicker)
                        .fixedSize()
                        .focusableControl(.fontFamily, focus: $focus,
                                          onActivate: { fontPicker.present?() })
                }
                Stepper(value: $store.settings.fontSize,
                        in: FontCatalog.minSize...FontCatalog.maxSize,
                        step: 1) {
                    Text("Size: \(Int(store.settings.fontSize)) pt")
                }
                .focusableControl(.fontSize, focus: $focus) { direction in
                    let next = store.settings.fontSize + Double(direction)
                    store.settings.fontSize =
                        min(max(next, FontCatalog.minSize), FontCatalog.maxSize)
                }
                AdjustableSlider(title: "Stroke weight",
                                 value: $store.settings.strokeWeight,
                                 range: 0.0...1.0, step: 0.05, format: "%.2f",
                                 field: .strokeWeight, focus: $focus)
                AdjustableSlider(title: "Line spacing",
                                 value: $store.settings.lineHeight,
                                 range: 1.0...2.0, step: 0.05, dragStep: 0.05,
                                 format: "%.2f×",
                                 field: .lineHeight, focus: $focus)
            }

            Section("Cursor") {
                Toggle("Blink", isOn: $store.settings.blinkCursor)
                    .focusableControl(.blinkCursor, focus: $focus,
                                      onActivate: { store.settings.blinkCursor.toggle() })
            }

            Section("Preview") {
                ThemePreview(theme: store.current,
                             fontFamily: store.settings.fontFamily,
                             fontSize: store.settings.fontSize,
                             lineHeight: store.settings.lineHeight)
            }
        }
        .formStyle(.grouped)
    }

    private func importTheme() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose an iTerm2 .itermcolors file"
        if let type = UTType(filenameExtension: "itermcolors") {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let theme = try store.importTheme(from: url)
            // Auto-select the freshly imported theme for its appearance bucket.
            if theme.appearance == .light {
                store.settings.lightThemeId = theme.id
            } else {
                store.settings.darkThemeId = theme.id
            }
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn't import theme"
            alert.informativeText = (error as? ThemeImportError)?.errorDescription
                ?? error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}

private struct ThemePreview: View {
    let theme: Theme
    let fontFamily: String
    let fontSize: Double
    let lineHeight: Double

    /// Resolved through the same `makeFont` the renderer uses, so the preview
    /// can't disagree with what the terminal will actually draw — including
    /// which face a font from the "Other" section resolves to, and the
    /// fallback when the chosen font has been uninstalled.
    ///
    /// Scale 1: `makeFont` works in device pixels for the renderer, and this
    /// is laid out in points.
    private var previewFont: Font {
        Font(FontCatalog.makeFont(family: fontFamily, size: fontSize, scale: 1))
    }

    /// Height of one sample row, measured from a *reference* font rather than
    /// the selected one.
    ///
    /// Natural line height varies by about 5 pt between families at 13 pt
    /// (Courier 13.0, Lantinghei TC 18.1) — roughly 15 pt across these three
    /// rows. The Settings window sizes itself to its pane, so letting the
    /// preview follow each family's own metrics made the whole window jump
    /// every time a font was picked. Deriving the row height from the size
    /// and line spacing alone keeps the block still while still reacting to
    /// the two controls that should change it.
    ///
    /// It's also closer to the terminal, where every row is exactly one cell
    /// tall no matter which glyphs land on it.
    private var sampleRowHeight: CGFloat {
        let reference = NSFont.monospacedSystemFont(ofSize: CGFloat(fontSize), weight: .regular)
        return ceil((reference.ascender - reference.descender) * CGFloat(lineHeight))
    }

    /// One terminal row, at a fixed height.
    private func sampleRow<Content: View>(
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        content().frame(height: sampleRowHeight, alignment: .leading)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                ForEach(0..<8, id: \.self) { i in swatch(theme.ansi[i]) }
            }
            HStack(spacing: 4) {
                ForEach(8..<16, id: \.self) { i in swatch(theme.ansi[i]) }
            }

            VStack(alignment: .leading, spacing: 0) {
                sampleRow {
                    Text("vadnov@mac ~ % ls -la")
                        .foregroundColor(color(theme.foreground))
                }
                sampleRow {
                    HStack(spacing: 0) {
                        Text("drwxr-xr-x  ").foregroundColor(color(theme.ansi[12]))
                        Text("4 vadnov  ").foregroundColor(color(theme.foreground))
                        Text("staff   128 ").foregroundColor(color(theme.ansi[3]))
                        Text("Sources").foregroundColor(color(theme.ansi[4]))
                    }
                }
                sampleRow {
                    HStack(spacing: 0) {
                        Text("-rw-r--r--  ").foregroundColor(color(theme.foreground))
                        Text("1 vadnov  ").foregroundColor(color(theme.foreground))
                        Text("staff   742 ").foregroundColor(color(theme.ansi[3]))
                        Text("Package.swift").foregroundColor(color(theme.ansi[2]))
                    }
                }
            }
            .font(previewFont)
            // A 28 pt font would otherwise wrap these lines and make the
            // preview taller than the pane it's previewing.
            .lineLimit(1)
            .padding(12)
            .background(color(theme.background))
            .cornerRadius(6)
        }
        .padding(.vertical, 4)
    }

    private func swatch(_ c: SIMD4<Float>) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(color(c))
            .frame(width: 28, height: 22)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.primary.opacity(0.15), lineWidth: 0.5)
            )
    }

    private func color(_ c: SIMD4<Float>) -> Color {
        Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z), opacity: Double(c.w))
    }
}
