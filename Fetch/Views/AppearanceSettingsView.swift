import SwiftUI
import AppKit
import FetchKit

/// Settings § Appearance — the theme, the key that opens Fetch, and the one
/// thing that is coming rather than here.
///
/// **First in the pane row.** It is the pane people open Settings to find, and
/// Debrid is the one they open once.
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

// MARK: - The theme control

/// Three surfaces, not three words.
///
/// A radio list saying Glass, Blizzard, Midnight makes you pick a theme by its
/// name and find out afterwards. Each swatch is that theme's sidebar chrome
/// beside its pane, in the theme's own values, so the choice is visible before
/// it is made.
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

    /// The mock drew 62 × 34 with a 20pt strip. Snapped to the four-point grid
    /// per §1 of the tokens contract, which is the same correction every other
    /// odd number in the mocks got.
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
            // The ring, not a heavier border: a selected swatch has to stay
            // recognisably the same size as the two beside it, or picking one
            // makes the row jump.
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
    /// A named theme's token — the one place in the app that has to draw a
    /// theme it is not currently in.
    ///
    /// Dynamic for the same reason `Palette` is: Glass follows the system, so
    /// its swatch has to answer at draw time rather than at read time, or it
    /// shows the appearance the pane was first opened in.
    init(_ theme: AppearanceTheme, _ token: KeyPath<ThemePalette, ThemeColor>) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(theme.palette(inDarkAppearance: isDark)[keyPath: token])
        })
    }
}

// MARK: - The shortcut control

/// Click the key, press the combination.
///
/// **Recorded rather than typed.** A field asking for "⌃⌘F" has to parse
/// symbols the user cannot type and cannot tell ⌥ from the character ⌥
/// produces. The only input guaranteed to be the combination is the
/// combination.
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
        // A monitor left installed keeps swallowing every key press in the app
        // after the pane goes away, which looks like the whole window freezing.
        .onDisappear { stopRecording() }
    }

    private func toggleRecording() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    private func startRecording() {
        failure = nil
        isRecording = true
        // Local rather than global: this is capturing keys inside our own
        // window, and a global monitor would need Accessibility access to do
        // the same job worse.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            record(event)
            return nil   // swallowed: a recorded key must not also be typed
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }

    private func record(_ event: NSEvent) {
        guard event.keyCode != UInt16(53) else {   // Escape cancels
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
            // Stays in recording mode: the next press replaces this one, which
            // is what someone who has just been told "try another" wants.
            failure = (error as? LocalizedError)?.errorDescription
                ?? String(describing: error)
        }
    }
}
