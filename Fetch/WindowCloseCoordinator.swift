import AppKit
import FetchKit
import SwiftUI

/**
 Decides what the window's close button does, and keeps the app alive when
 the answer is "keep downloading".

 **Why an `NSWindowDelegate` and not `.onDisappear`.** The choice has to be
 made *before* the window goes, and only `windowShouldClose` can refuse a
 close. SwiftUI has no equivalent, so this reaches for AppKit — the same
 reason the app already reaches for `NSWorkspace` and `NSPasteboard`.
 */
@MainActor
final class WindowCloseCoordinator: NSObject, NSWindowDelegate {
    private let model: AppModel
    private var isAsking = false

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    func attach() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = NSApp.windows.first(where: { $0.canBecomeMain })
            else { return }
            window.delegate = self
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        switch model.windowCloseBehaviour {
        case .quit:
            return true
        case .minimise:
            sender.miniaturize(nil)
            return false
        case .background:
            goToBackground(sender)
            return false
        case .ask:
            guard !isAsking else { return false }
            isAsking = true
            ask(on: sender)
            return false
        }
    }

    private func goToBackground(_ window: NSWindow) {
        WindowPresenter.hidden = window
        window.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
    }

    private func ask(on window: NSWindow) {
        let alert = NSAlert()
        alert.messageText = "What should Fetch do when the window closes?"
        alert.informativeText =
            "Downloads keep running unless you quit. You can change this later "
            + "in Settings › Transfers."
        alert.addButton(withTitle: "Keep Downloading")
        alert.addButton(withTitle: "Minimise")
        alert.addButton(withTitle: "Quit Fetch")

        let remember = NSButton(checkboxWithTitle: "Don't ask again", target: nil, action: nil)
        remember.state = .off
        alert.accessoryView = remember

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            isAsking = false

            let chosen: WindowCloseBehaviour = switch response {
            case .alertFirstButtonReturn: .background
            case .alertSecondButtonReturn: .minimise
            default: .quit
            }
            if remember.state == .on { model.windowCloseBehaviour = chosen }

            switch chosen {
            case .minimise: window.miniaturize(nil)
            case .quit: NSApp.terminate(nil)
            case .background, .ask: goToBackground(window)
            }
        }
    }
}

@MainActor
enum WindowPresenter {
    static weak var hidden: NSWindow?

    static func showMainWindow() {
        Task { @MainActor in await present() }
    }

    private static func present() async {
        fetchLog(.info, "present", "start policy=\(NSApp.activationPolicy().rawValue) "
                 + "active=\(NSApp.isActive) windows=\(NSApp.windows.count)")
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
            try? await Task.sleep(for: .milliseconds(50))
            DriftingDockIcon.shared.reassert()
        }

        NSApp.activate(ignoringOtherApps: true)
        fetchLog(.info, "present", "activated policy=\(NSApp.activationPolicy().rawValue) "
                 + "active=\(NSApp.isActive)")

        for attempt in 0..<20 {
            if let window = mainWindow() {
                window.deminiaturize(nil)
                window.makeKeyAndOrderFront(nil)
                fetchLog(.info, "present",
                         "attempt=\(attempt) visible=\(window.isVisible) "
                         + "key=\(window.isKeyWindow) main=\(window.isMainWindow) "
                         + "level=\(window.level.rawValue) active=\(NSApp.isActive)")
                window.orderFrontRegardless()
                if window.isKeyWindow {
                    fetchLog(.info, "present", "key after \(attempt) attempts")
                    hidden = nil
                    return
                }
                NSApp.activate(ignoringOtherApps: true)
            } else {
                fetchLog(.info, "present", "attempt=\(attempt) no main window among "
                         + "\(NSApp.windows.count): "
                         + NSApp.windows.map {
                             "\(type(of: $0)) canMain=\($0.canBecomeMain) vis=\($0.isVisible)"
                         }.joined(separator: " | "))
            }
            if attempt == 2 { NSApp.activate(ignoringOtherApps: true) }
            try? await Task.sleep(for: .milliseconds(25))
        }
        fetchLog(.warn, "present", "gave up; never became key")
    }

    private static func mainWindow() -> NSWindow? {
        if let hidden { return hidden }
        return NSApp.windows.first {
            $0.styleMask.contains(.titled) && !($0 is NSPanel)
        }
    }
}

/**
 Keeps the process alive when the last window closes, unless the user has
 said otherwise.
 */
@MainActor
final class FetchAppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationWillFinishLaunching(_ notification: Notification) {
        DriftingDockIcon.shared.start()
        observeTheMomentsThatResetTheTile()
    }

    private func observeTheMomentsThatResetTheTile() {
        for name: Notification.Name in [
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSApplication.didUnhideNotification,
            NSApplication.didBecomeActiveNotification,
        ] {
            NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated { DriftingDockIcon.shared.reassert() }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        DriftingDockIcon.shared.reassert()
        DriftingDockIcon.shared.persistToBundle()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        model?.windowCloseBehaviour.terminatesOnLastWindowClose ?? true
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows: Bool
    ) -> Bool {
        true
    }
}
