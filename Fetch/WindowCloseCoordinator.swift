import AppKit
import FetchKit
import SwiftUI

/// Decides what the window's close button does, and keeps the app alive when
/// the answer is "keep downloading".
///
/// **Why an `NSWindowDelegate` and not `.onDisappear`.** The choice has to be
/// made *before* the window goes, and only `windowShouldClose` can refuse a
/// close. SwiftUI has no equivalent, so this reaches for AppKit — the same
/// reason the app already reaches for `NSWorkspace` and `NSPasteboard`.
@MainActor
final class WindowCloseCoordinator: NSObject, NSWindowDelegate {
    private let model: AppModel
    /// Set while the sheet is up, so a second click on the close button does
    /// not stack a second copy of the question.
    private var isAsking = false

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    /// Attaches to whichever window is the app's main one.
    ///
    /// Deferred a turn: at the moment SwiftUI's scene body first runs there is
    /// no `NSWindow` yet, and asking for one returns nil.
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
            // The window goes; `applicationShouldTerminateAfterLastWindowClosed`
            // is what keeps the process.
            return true
        case .ask:
            guard !isAsking else { return false }
            isAsking = true
            ask(on: sender)
            return false
        }
    }

    /// The question, once.
    ///
    /// An alert rather than a sheet in a SwiftUI view, because the window it
    /// belongs to is the one being closed — a SwiftUI sheet would need the
    /// close to have already happened, which is the thing being decided.
    private func ask(on window: NSWindow) {
        let alert = NSAlert()
        alert.messageText = "Closing the window — what should Fetch do?"
        alert.informativeText =
            "Downloads keep running unless you quit. You can change this later "
            + "in Settings › Transfers."
        alert.addButton(withTitle: "Keep Downloading")
        alert.addButton(withTitle: "Minimise")
        alert.addButton(withTitle: "Quit Fetch")

        let remember = NSButton(checkboxWithTitle: "Don't ask again", target: nil, action: nil)
        remember.state = .on
        alert.accessoryView = remember

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            isAsking = false

            let chosen: WindowCloseBehaviour = switch response {
            case .alertFirstButtonReturn: .background
            case .alertSecondButtonReturn: .minimise
            default: .quit
            }
            // Only remembered if they asked for it to be. Unchecked, the
            // choice applies once and the question comes back — which is what
            // "don't ask again" being a *choice* means.
            if remember.state == .on { model.windowCloseBehaviour = chosen }

            switch chosen {
            case .minimise: window.miniaturize(nil)
            case .quit: NSApp.terminate(nil)
            case .background, .ask: window.close()
            }
        }
    }
}

/// Keeps the process alive when the last window closes, unless the user has
/// said otherwise.
@MainActor
final class FetchAppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        DriftingDockIcon.shared.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        model?.windowCloseBehaviour.terminatesOnLastWindowClose ?? true
    }

    /// Clicking the Dock icon with no window open brings one back — otherwise
    /// an app running in the background with its window closed is unreachable
    /// except through the menu bar.
    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows: Bool
    ) -> Bool {
        true
    }
}
