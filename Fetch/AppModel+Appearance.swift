import AppKit
import Carbon
import Foundation
import FetchKit


struct GlobalShortcut: Equatable, Codable, Sendable {
    let keyCode: UInt16
    let modifierFlags: UInt

    static let `default` = GlobalShortcut(
        keyCode: UInt16(kVK_ANSI_F),
        modifierFlags: NSEvent.ModifierFlags([.control, .command]).rawValue)

    var modifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifierFlags) }

    var displayString: String {
        var symbols = ""
        if modifiers.contains(.control) { symbols += "⌃" }
        if modifiers.contains(.option) { symbols += "⌥" }
        if modifiers.contains(.shift) { symbols += "⇧" }
        if modifiers.contains(.command) { symbols += "⌘" }
        return symbols + Self.keyName(for: keyCode)
    }

    var isUsable: Bool {
        !modifiers.intersection([.control, .option, .command]).isEmpty
    }

    var carbonModifiers: UInt32 {
        var flags: UInt32 = 0
        if modifiers.contains(.command) { flags |= UInt32(cmdKey) }
        if modifiers.contains(.option) { flags |= UInt32(optionKey) }
        if modifiers.contains(.control) { flags |= UInt32(controlKey) }
        if modifiers.contains(.shift) { flags |= UInt32(shiftKey) }
        return flags
    }

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

/**
 The system-wide key, registered through Carbon.

 **Carbon rather than `NSEvent.addGlobalMonitorForEvents`.** A global monitor
 needs the user to grant Accessibility access in System Settings — a scary
 permission dialog for a download manager, and one that silently stops
 working after an app update. `RegisterEventHotKey` needs no permission at
 all, and it is the only API that tells us the combination is already taken
 rather than just never firing.
 */
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
        let identifier = EventHotKeyID(signature: OSType(0x46544348), id: 1)
        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode),
            shortcut.carbonModifiers,
            identifier,
            GetEventDispatcherTarget(),
            0,
            &reference)
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

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), fetchHotkeyHandler, 1, &spec, nil, &handler)
    }
}

private func fetchHotkeyHandler(
    _ callRef: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    MainActor.assumeIsolated { GlobalHotkey.shared.fire() }
    return noErr
}


extension AppModel {
    private static let themeKey = "appearance.theme"
    private static let shortcutKey = "appearance.shortcut"

    var globalShortcut: GlobalShortcut {
        guard let data = UserDefaults.standard.data(forKey: Self.shortcutKey),
              let shortcut = try? JSONDecoder().decode(GlobalShortcut.self, from: data)
        else { return .default }
        return shortcut
    }

    func restoreAppearance() {
        if let raw = UserDefaults.standard.string(forKey: Self.themeKey),
           let stored = AppearanceTheme(rawValue: raw) {
            appearanceTheme = stored
        }
        applyTheme()
        try? GlobalHotkey.shared.register(globalShortcut) { [weak self] in
            self?.openForSearch()
        }
    }

    func setAppearanceTheme(_ theme: AppearanceTheme) {
        appearanceTheme = theme
        UserDefaults.standard.set(theme.rawValue, forKey: Self.themeKey)
        applyTheme()
    }

    func setGlobalShortcut(_ shortcut: GlobalShortcut) throws {
        let previous = globalShortcut
        do {
            try GlobalHotkey.shared.register(shortcut) { [weak self] in
                self?.openForSearch()
            }
        } catch {
            try? GlobalHotkey.shared.register(previous) { [weak self] in
                self?.openForSearch()
            }
            throw error
        }
        UserDefaults.standard.set(try? JSONEncoder().encode(shortcut), forKey: Self.shortcutKey)
    }

    func openForSearch() {
        WindowPresenter.showMainWindow()
        sidebarSection = .search
        searchFieldText = ""
        Task { @MainActor in
            for _ in 0..<40 {
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

    private func applyTheme() {
        ActiveTheme.shared.theme = appearanceTheme
        if let pinned = appearanceTheme.prefersDarkAppearance {
            NSApp.appearance = NSAppearance(named: pinned ? .darkAqua : .aqua)
        } else {
            NSApp.appearance = nil
        }
    }

    private static func firstTextField(in view: NSView) -> NSTextField? {
        for subview in view.subviews {
            if let field = subview as? NSTextField, field.isEditable { return field }
            if let found = firstTextField(in: subview) { return found }
        }
        return nil
    }
}
