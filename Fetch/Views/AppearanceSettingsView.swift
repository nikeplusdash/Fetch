import SwiftUI
import AppKit
import FetchKit

/**
 Settings § Appearance — the theme, the key that opens Fetch, and the one
 thing that is coming rather than here.

 **First in the pane row.** It is the pane people open Settings to find, and
 Debrid is the one they open once.
 */
struct AppearanceSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SettingsGroup(title: "Theme") {
                    SettingRow(
                        label: "Surface",
                        help: "Glass follows your system between light and dark. "
                            + "The other two do not."
                    ) {
                        ThemeSwatchRow(
                            selection: model.appearanceTheme,
                            onSelect: { model.setAppearanceTheme($0) })
                    }
                }

                SettingsGroup(title: "Shortcut") {
                    SettingRow(
                        label: "Open Fetch and search",
                        help: "Works while any app is in front. Fetch comes forward "
                            + "with the field focused and empty."
                    ) {
                        ShortcutRecorder()
                    }
                }
            }
            .padding(.bottom, Spacing.s16)
        }
    }
}


private struct ThemeSwatchRow: View {
    let selection: AppearanceTheme
    let onSelect: (AppearanceTheme) -> Void

    var body: some View {
        HStack(spacing: Spacing.s8) {
            ForEach(AppearanceTheme.allCases) { theme in
                ThemeSwatch(
                    theme: theme,
                    isSelected: theme == selection,
                    action: { onSelect(theme) })
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Surface")
    }
}

private struct ThemeSwatch: View {
    let theme: AppearanceTheme
    let isSelected: Bool
    let action: () -> Void

    private static let width: CGFloat = 64
    private static let chipHeight: CGFloat = 32
    private static let chromeWidth: CGFloat = 20

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Color(theme, \.chrome).frame(width: Self.chromeWidth)
                    Color(theme, \.pane)
                }
                .frame(height: Self.chipHeight)

                Text(theme.title)
                    .font(FetchFont.footnote)
                    .foregroundStyle(isSelected ? Palette.textPrimary : Palette.textSecondary)
                    .lineLimit(1)
                    .padding(.vertical, Spacing.s4)
            }
            .frame(width: Self.width)
            .clipShape(RoundedRectangle(cornerRadius: Radius.r8))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.r8)
                    .strokeBorder(
                        isSelected ? Palette.textPrimary : Palette.separator,
                        lineWidth: 1)
            }
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: Radius.r10)
                        .strokeBorder(Palette.fillTrack, lineWidth: 2)
                        .padding(-2)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(theme.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .help(theme.followsSystemAppearance
              ? "\(theme.title). Follows your system between light and dark."
              : "\(theme.title)")
    }
}

private extension Color {
    init(_ theme: AppearanceTheme, _ token: KeyPath<ThemePalette, ThemeColor>) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(theme.palette(inDarkAppearance: isDark)[keyPath: token])
        })
    }
}


private struct ShortcutRecorder: View {
    @Environment(AppModel.self) private var model

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: Spacing.s4) {
            Button { toggleRecording() } label: {
                Text(isRecording ? "Press keys" : model.globalShortcut.displayString)
                    .font(FetchFont.callout)
                    .monospaced()
                    .foregroundStyle(isRecording ? Palette.textSecondary : Palette.textPrimary)
                    .padding(.horizontal, Spacing.s8)
                    .padding(.vertical, Spacing.s4)
                    .frame(minWidth: 64)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.r6)
                            .fill(isRecording ? Palette.fillQuaternary : .clear))
                    .overlay {
                        RoundedRectangle(cornerRadius: Radius.r6)
                            .strokeBorder(
                                isRecording ? Palette.textPrimary : Palette.separator,
                                lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isRecording
                ? "Recording a shortcut. Press a combination, or Escape to cancel."
                : "Shortcut, \(model.globalShortcut.displayString). Click to record a new one.")

            if let failure {
                Text(failure)
                    .font(FetchFont.footnote)
                    .foregroundStyle(Palette.miss)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 220, alignment: .trailing)
            }
        }
        .onDisappear { stopRecording() }
    }

    private func toggleRecording() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    private func startRecording() {
        failure = nil
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            record(event)
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }

    private func record(_ event: NSEvent) {
        guard event.keyCode != UInt16(53) else {
            stopRecording()
            return
        }
        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .function, .numericPad])
        let shortcut = GlobalShortcut(
            keyCode: event.keyCode, modifierFlags: flags.rawValue)
        do {
            try model.setGlobalShortcut(shortcut)
            failure = nil
            stopRecording()
        } catch {
            failure = (error as? LocalizedError)?.errorDescription
                ?? String(describing: error)
        }
    }
}
