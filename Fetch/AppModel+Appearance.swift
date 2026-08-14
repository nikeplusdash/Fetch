import AppKit
import Carbon
import Foundation
import FetchKit

/// Plan 3's additions — the theme and the global shortcut.
///
/// See `AppModel+Library` for why these three files exist.

// MARK: - The shortcut

/// A key and its modifiers, as recorded from a real key press.
///
/// **Recorded, not typed.** A text field asking for "⌃⌘F" has to parse a string
/// the user cannot type the symbols of, and it cannot tell ⌥ from the character
/// ⌥ produces. Pressing the combination is the only input that is guaranteed to
/// be the combination.
struct GlobalShortcut: Equatable, Codable, Sendable {
    /// The physical key, as AppKit and Carbon both report it. Layout-
    /// independent on purpose: this is a position on the keyboard, so a French
    /// layout gets the same key rather than the same letter somewhere else.
    let keyCode: UInt16
    /// `NSEvent.ModifierFlags.rawValue`, already masked to the device-
    /// independent flags.
    let modifierFlags: UInt

    /// `⌃⌘F` — free on a stock system, which is the whole reason for it.
    static let `default` = GlobalShortcut(
        keyCode: UInt16(kVK_ANSI_F),
        modifierFlags: NSEvent.ModifierFlags([.control, .command]).rawValue)

    var modifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifierFlags) }

    /// What the key cap reads. Modifiers in the order macOS prints them, which
    /// is not the order they are usually written in code.
    var displayString: String {
        var symbols = ""
        if modifiers.contains(.control) { symbols += "⌃" }
        if modifiers.contains(.option) { symbols += "⌥" }
        if modifiers.contains(.shift) { symbols += "⇧" }
        if modifiers.contains(.command) { symbols += "⌘" }
        return symbols + Self.keyName(for: keyCode)
    }

    /// Whether this is something a global hotkey can be.
    ///
    /// At least one of ⌃⌥⌘ — a bare key, or ⇧ alone, would swallow that key in
    /// every other app on the system, which is not a shortcut, it is a fault.
    var isUsable: Bool {
        !modifiers.intersection([.control, .option, .command]).isEmpty
    }

    /// The Carbon flags `RegisterEventHotKey` wants, which are not AppKit's.
    var carbonModifiers: UInt32 {
        var flags: UInt32 = 0
        if modifiers.contains(.command) { flags |= UInt32(cmdKey) }
        if modifiers.contains(.option) { flags |= UInt32(optionKey) }
        if modifiers.contains(.control) { flags |= UInt32(controlKey) }
        if modifiers.contains(.shift) { flags |= UInt32(shiftKey) }
        return flags
    }

    /// The name on the cap. Only the keys someone might plausibly bind: the
    /// rest fall back to the current layout's character for that position,
    /// which is right for every letter and digit.
    private static func keyName(for keyCode: UInt16) -> String {
        switch Int(keyCode) {
        case kVK_Space: "Space"
        case kVK_Return: "↩"
        case kVK_Tab: "⇥"
        case kVK_Escape: "⎋"
        case kVK_Delete: "⌫"
        case kVK_LeftArrow: "←"
        case kVK_RightArrow: "→"
        case kVK_UpArrow: "↑"
        case kVK_DownArrow: "↓"
        default: layoutCharacter(for: keyCode)
        }
    }

    /// The character this position produces on the user's own layout, so an
    /// AZERTY keyboard is not told its shortcut is on a key it does not have.
    private static func layoutCharacter(for keyCode: UInt16) -> String {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return "?" }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = data.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.baseAddress?
                .assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(
                layout,
                keyCode,
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeys,
                characters.count,
                &length,
                &characters)
        }
        guard status == noErr, length > 0 else { return "?" }
        return String(utf16CodeUnits: characters, count: length).uppercased()
    }
}

/// Why a recorded combination could not be made live.
enum GlobalShortcutError: LocalizedError {
    case needsAModifier
    case alreadyTaken

    var errorDescription: String? {
        switch self {
        case .needsAModifier:
            "A global shortcut needs Control, Option or Command, or it would "
            + "swallow that key in every other app."
        case .alreadyTaken:
            "Something else on this Mac already uses that combination. Try another."
        }
    }
}

/// The system-wide key, registered through Carbon.
///
/// **Carbon rather than `NSEvent.addGlobalMonitorForEvents`.** A global monitor
/// needs the user to grant Accessibility access in System Settings — a scary
/// permission dialog for a download manager, and one that silently stops
/// working after an app update. `RegisterEventHotKey` needs no permission at
/// all, and it is the only API that tells us the combination is already taken
/// rather than just never firing.
@MainActor
final class GlobalHotkey {
    static let shared = GlobalHotkey()

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var action: (() -> Void)?

    private init() {}

    func register(_ shortcut: GlobalShortcut, action: @escaping () -> Void) throws {
        guard shortcut.isUsable else { throw GlobalShortcutError.needsAModifier }
        unregister()
        installHandlerIfNeeded()

        var reference: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: OSType(0x46544348), id: 1)  // 'FTCH'
        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode),
            shortcut.carbonModifiers,
            identifier,
            GetEventDispatcherTarget(),
            0,
            &reference)
        // The conflict check the spec asks for is this return value. There is
        // no way to ask the system "is ⌃⌘F free?" without trying to take it.
        guard status == noErr, let reference else { throw GlobalShortcutError.alreadyTaken }
        hotKey = reference
        self.action = action
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        action = nil
    }

    fileprivate func fire() { action?() }

    /// Installed once and left. Tearing the handler down with each re-record
    /// raced the registration that followed it.
    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), fetchHotkeyHandler, 1, &spec, nil, &handler)
    }
}

/// Carbon calls back through a C function pointer, which can capture nothing,
/// so the one hotkey the app has is reached through the shared instance. The
/// event target is the main run loop, which is what makes the hop safe.
private func fetchHotkeyHandler(
    _ callRef: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    MainActor.assumeIsolated { GlobalHotkey.shared.fire() }
    return noErr
}

// MARK: - The model's side

extension AppModel {
    private static let themeKey = "appearance.theme"
    private static let shortcutKey = "appearance.shortcut"

    /// The combination currently registered, or the default until one is.
    ///
    /// Read from `UserDefaults` each time rather than stored: `AppModel`'s
    /// stored properties are declared in `AppModel.swift`, which three
    /// worktrees were editing at once, and this is read twice — once on launch
    /// and once when the Appearance pane draws.
    var globalShortcut: GlobalShortcut {
        guard let data = UserDefaults.standard.data(forKey: Self.shortcutKey),
              let shortcut = try? JSONDecoder().decode(GlobalShortcut.self, from: data)
        else { return .default }
        return shortcut
    }

    /// Called once, from the window's `onAppear`.
    func restoreAppearance() {
        if let raw = UserDefaults.standard.string(forKey: Self.themeKey),
           let stored = AppearanceTheme(rawValue: raw) {
            appearanceTheme = stored
        }
        applyTheme()
        // A shortcut that another app has taken since it was recorded is not
        // an error worth interrupting a launch over — the row in Settings
        // shows what is set, and re-recording it is one click.
        try? GlobalHotkey.shared.register(globalShortcut) { [weak self] in
            self?.openForSearch()
        }
    }

    /// Picks a theme, and makes it the one the window is made of.
    func setAppearanceTheme(_ theme: AppearanceTheme) {
        appearanceTheme = theme
        UserDefaults.standard.set(theme.rawValue, forKey: Self.themeKey)
        applyTheme()
    }

    /// Records a new combination, or leaves the old one registered.
    ///
    /// Persisted only after the system accepts it. Storing first would leave a
    /// shortcut in `UserDefaults` that fails to register on every launch and
    /// says nothing about why.
    func setGlobalShortcut(_ shortcut: GlobalShortcut) throws {
        let previous = globalShortcut
        do {
            try GlobalHotkey.shared.register(shortcut) { [weak self] in
                self?.openForSearch()
            }
        } catch {
            // `register` releases the key it holds before it asks for the new
            // one, so a rejected combination would otherwise leave the app with
            // no shortcut at all: the old one gone because the new one failed,
            // and the Settings row still showing it.
            try? GlobalHotkey.shared.register(previous) { [weak self] in
                self?.openForSearch()
            }
            throw error
        }
        UserDefaults.standard.set(try? JSONEncoder().encode(shortcut), forKey: Self.shortcutKey)
    }

    /// What the shortcut does: Fetch in front, on Search, with the field
    /// focused and empty.
    func openForSearch() {
        // The same three steps the menu bar item takes, including restoring the
        // Dock icon: the shortcut is the main way back once the window has been
        // sent to the background, and an `.accessory` app that activates has no
        // Dock icon and no menu bar to come forward into.
        WindowPresenter.showMainWindow()
        sidebarSection = .search
        searchFieldText = ""
        // After the run loop turn that switches screens. SwiftUI rebuilds at
        // the end of the turn `sidebarSection` was set in, so at this instant
        // the search field does not exist yet and the walk below would find
        // whichever field the previous screen had — or none, and silently do
        // nothing, which is how "the shortcut does not focus anything" looks.
        // **Polled, not slept once.** A single 50ms wait was a race that got
        // much worse once the window could be sent to the background: coming
        // back from `.accessory` restores the activation policy, re-orders the
        // window in and lets SwiftUI rebuild the Search screen, and the field
        // does not exist for any fixed number of milliseconds. Missing it left
        // the window open with nothing focused, which is what "the shortcut
        // does not focus anything" looks like.
        //
        // `mainWindow` as well as `keyWindow`: immediately after activating,
        // the window that was just ordered in is main before it is key.
        Task { @MainActor in
            for _ in 0..<40 {
                // Only once the window is genuinely key. Focusing a field in a
                // window that is still being ordered in is wasted: the
                // `makeKeyAndOrderFront` that follows resets first responder,
                // and the field ends up visible and not focused.
                if let window = NSApp.keyWindow, window.isKeyWindow,
                   let root = window.contentView,
                   let field = Self.firstTextField(in: root) {
                    window.makeFirstResponder(field)
                    return
                }
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
    }

    /// **Pinning, not tinting.** Blizzard and Midnight state their own
    /// light/dark value, and the four tokens `Palette` deliberately leaves to
    /// AppKit — the accent-tracking selection on the search results list, and
    /// the text drawn on it — resolve against `NSApp.appearance`. Setting it is
    /// what stops a Midnight window from drawing AppKit's light-mode selection
    /// because the system happens to be in light mode.
    private func applyTheme() {
        ActiveTheme.shared.theme = appearanceTheme
        if let pinned = appearanceTheme.prefersDarkAppearance {
            NSApp.appearance = NSAppearance(named: pinned ? .darkAqua : .aqua)
        } else {
            NSApp.appearance = nil
        }
    }

    /// The search field, found by walking the window rather than by holding a
    /// `FocusState` the search screen would have to publish.
    ///
    /// Depth-first from the content view, so the field at the top of the Search
    /// screen is reached before anything inside the results below it. This is
    /// the one part of the shortcut that knows what a screen looks like, and it
    /// degrades to doing nothing rather than to focusing the wrong thing only
    /// as long as Search's field stays the first one in the hierarchy.
    private static func firstTextField(in view: NSView) -> NSTextField? {
        for subview in view.subviews {
            if let field = subview as? NSTextField, field.isEditable { return field }
            if let found = firstTextField(in: subview) { return found }
        }
        return nil
    }
}
