import SwiftUI
import simd

struct AppearancePane: View {
    @ObservedObject private var store = ThemeStore.shared

    private var lightThemes: [Theme] {
        Theme.builtin.filter { $0.appearance == .light }
    }
    private var darkThemes: [Theme] {
        Theme.builtin.filter { $0.appearance == .dark }
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
            }

            Section("Theme") {
                Picker("Light theme",
                       selection: $store.settings.lightThemeId) {
                    ForEach(lightThemes) { Text($0.name).tag($0.id) }
                }
                Picker("Dark theme",
                       selection: $store.settings.darkThemeId) {
                    ForEach(darkThemes) { Text($0.name).tag($0.id) }
                }
            }

            Section("Font") {
                Picker("Family", selection: $store.settings.fontFamily) {
                    ForEach(FontCatalog.available, id: \.displayName) { entry in
                        Text(entry.displayName).tag(entry.displayName)
                    }
                }
                Stepper(value: $store.settings.fontSize,
                        in: FontCatalog.minSize...FontCatalog.maxSize,
                        step: 1) {
                    Text("Size: \(Int(store.settings.fontSize)) pt")
                }
                Toggle("Use thin strokes",
                       isOn: $store.settings.thinStrokes)
            }

            Section("Preview") {
                ThemePreview(theme: store.current)
            }

            Section("Sessions") {
                Toggle("Warn before closing a tab with a running process",
                       isOn: $store.settings.warnOnCloseWithRunningProcess)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ThemePreview: View {
    let theme: Theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                ForEach(0..<8, id: \.self) { i in swatch(theme.ansi[i]) }
            }
            HStack(spacing: 4) {
                ForEach(8..<16, id: \.self) { i in swatch(theme.ansi[i]) }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("vadnov@mac ~ % ls -la")
                    .foregroundColor(color(theme.foreground))
                HStack(spacing: 0) {
                    Text("drwxr-xr-x  ").foregroundColor(color(theme.ansi[12]))
                    Text("4 vadnov  ").foregroundColor(color(theme.foreground))
                    Text("staff   128 ").foregroundColor(color(theme.ansi[3]))
                    Text("Sources").foregroundColor(color(theme.ansi[4]))
                }
                HStack(spacing: 0) {
                    Text("-rw-r--r--  ").foregroundColor(color(theme.foreground))
                    Text("1 vadnov  ").foregroundColor(color(theme.foreground))
                    Text("staff   742 ").foregroundColor(color(theme.ansi[3]))
                    Text("Package.swift").foregroundColor(color(theme.ansi[2]))
                }
            }
            .font(.system(.body, design: .monospaced))
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
