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
            goToBackground(sender)
            return false
        case .ask:
            guard !isAsking else { return false }
            isAsking = true
            ask(on: sender)
            return false
        }
    }

    /// Out of sight and out of the Dock, still downloading.
    ///
    /// **Ordered out, not closed.** Closing a `WindowGroup`'s window destroys
    /// it, and with no Dock icon left there is nothing to click to get it back
    /// — the menu bar item and the shortcut both reach for an existing window
    /// and would find none. Ordering it out keeps it, so both ways back are a
    /// `makeKeyAndOrderFront` on a window that is still there.
    ///
    /// `.accessory` is what removes the Dock icon and the menu bar; the status
    /// item stays, which is the whole reason the app has one.
    private func goToBackground(_ window: NSWindow) {
        // Remembered, because finding it again afterwards turned out to be the
        // hard part. See `WindowPresenter.hidden`.
        WindowPresenter.hidden = window
        window.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
    }

    /// The question, once.
    ///
    /// An alert rather than a sheet in a SwiftUI view, because the window it
    /// belongs to is the one being closed — a SwiftUI sheet would need the
    /// close to have already happened, which is the thing being decided.
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
        // **Unchecked.** It was pre-ticked, so the common path — read the
        // buttons, press one — silently answered a second question nobody had
        // read, and the dialog never came back. Remembering is the thing being
        // offered; offering it means not doing it by default.
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
            // Only remembered if they asked for it to be. Unchecked, the
            // choice applies once and the question comes back — which is what
            // "don't ask again" being a *choice* means.
            if remember.state == .on { model.windowCloseBehaviour = chosen }

            switch chosen {
            case .minimise: window.miniaturize(nil)
            case .quit: NSApp.terminate(nil)
            case .background, .ask: goToBackground(window)
            }
        }
    }
}

/// Bringing Fetch back from the background, from the menu bar or the shortcut.
///
/// One function because there are two ways in and they must do the same three
/// things: restore the Dock icon, activate, and show the window that was
/// ordered out. Doing two of the three is how an app comes forward with no
/// window, or shows a window it cannot be switched to.
@MainActor
enum WindowPresenter {
    /// The window that was ordered out, kept so it can be found again.
    ///
    /// **Searching `NSApp.windows` for it does not work, which the log settled
    /// after two wrong guesses.** Once ordered out, SwiftUI's window reports
    /// `canBecomeMain == false` — so the filter that was meant to pick it
    /// excluded it, every attempt found "no main window among 3", and the app
    /// came forward with its Dock icon and nothing else. Holding the reference
    /// removes the search entirely.
    static weak var hidden: NSWindow?

    static func showMainWindow() {
        Task { @MainActor in await present() }
    }

    /// **The order matters and so does the waiting between the steps.**
    ///
    /// Doing all three in one run-loop turn is what produced "the icon comes
    /// back but the window does not": `setActivationPolicy(.regular)` is not
    /// applied synchronously, so an app still transitioning out of `.accessory`
    /// cannot become frontmost, and the `activate` in the same turn was simply
    /// dropped. The Dock icon appeared — that part *is* immediate — and the
    /// window was ordered in behind whatever the user was actually looking at.
    private static func present() async {
        // Instrumented on purpose. This has been fixed twice by reasoning about
        // what AppKit ought to do and is being fixed a third time by finding
        // out what it does. Every step records what it saw, so the log says
        // which one failed rather than leaving it to be guessed from "the
        // window did not come up".
        fetchLog(.info, "present", "start policy=\(NSApp.activationPolicy().rawValue) "
                 + "active=\(NSApp.isActive) windows=\(NSApp.windows.count)")
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
            // One turn for AppKit to finish becoming an ordinary app. Without
            // it everything below is asked of an app that is not yet allowed
            // to come forward.
            try? await Task.sleep(for: .milliseconds(50))
            // The tile that just reappeared is a new one, drawn from the
            // bundle: going `.accessory` took the old one away and the override
            // with it. Re-asserted after the wait, so it lands on the tile that
            // exists rather than the one on its way out.
            DriftingDockIcon.shared.reassert()
        }

        NSApp.activate(ignoringOtherApps: true)
        fetchLog(.info, "present", "activated policy=\(NSApp.activationPolicy().rawValue) "
                 + "active=\(NSApp.isActive)")

        // The window may not exist for a moment — SwiftUI rebuilds a
        // `WindowGroup`'s scene after the policy changes — so this is a poll
        // rather than a single look, and it stops as soon as the window is
        // actually key rather than as soon as it has been asked to be.
        for attempt in 0..<20 {
            if let window = mainWindow() {
                window.deminiaturize(nil)
                window.makeKeyAndOrderFront(nil)
                fetchLog(.info, "present",
                         "attempt=\(attempt) visible=\(window.isVisible) "
                         + "key=\(window.isKeyWindow) main=\(window.isMainWindow) "
                         + "level=\(window.level.rawValue) active=\(NSApp.isActive)")
                // `makeKeyAndOrderFront` is a request another app can outrank;
                // this one is not. It is the difference between a window that
                // is in front and one that has been told to be.
                window.orderFrontRegardless()
                if window.isKeyWindow {
                    fetchLog(.info, "present", "key after \(attempt) attempts")
                    hidden = nil
                    return
                }
                // Activating *after* the window is back on screen. The app has
                // nothing to come forward to while its only window is ordered
                // out, which is why the first activate reported active=false.
                NSApp.activate(ignoringOtherApps: true)
            } else {
                fetchLog(.info, "present", "attempt=\(attempt) no main window among "
                         + "\(NSApp.windows.count): "
                         + NSApp.windows.map {
                             "\(type(of: $0)) canMain=\($0.canBecomeMain) vis=\($0.isVisible)"
                         }.joined(separator: " | "))
            }
            // Re-activating on later passes: the first `activate` can land
            // before the policy change has settled, and the app then sits one
            // layer behind with a perfectly ordered window inside it.
            if attempt == 2 { NSApp.activate(ignoringOtherApps: true) }
            try? await Task.sleep(for: .milliseconds(25))
        }
        fetchLog(.warn, "present", "gave up; never became key")
    }

    /// The app's own window, not the menu bar extra's or a panel's.
    ///
    /// `canBecomeMain` alone was the filter and is not enough on its own: the
    /// app has a `MenuBarExtra` and shows panels, and picking one of those
    /// would order a window the user cannot see and leave the real one behind.
    private static func mainWindow() -> NSWindow? {
        // The one we put away, first. Then any ordinary titled window, for the
        // launch case where nothing has been hidden yet. **Not filtered on
        // `canBecomeMain`**: an ordered-out window answers false to that, which
        // is exactly how the window went missing.
        if let hidden { return hidden }
        return NSApp.windows.first {
            $0.styleMask.contains(.titled) && !($0 is NSPanel)
        }
    }
}

/// Keeps the process alive when the last window closes, unless the user has
/// said otherwise.
@MainActor
final class FetchAppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    /// **`will`, not `did`.** The Dock paints the bundle icon the moment a
    /// launch begins and goes on painting it until this process says otherwise,
    /// so every frame between then and the first override is the noon sky from
    /// the asset catalogue. Started from `applicationDidFinishLaunching` that
    /// override landed after the window had been built, which is late enough to
    /// watch the icon change colour on the way in.
    ///
    /// `applicationWillFinishLaunching` is the earliest hook AppKit offers, and
    /// the first frame is drawn synchronously inside it, so the swap happens
    /// while the Dock is still bouncing rather than after it has settled.
    func applicationWillFinishLaunching(_ notification: Notification) {
        DriftingDockIcon.shared.start()
        observeTheMomentsThatResetTheTile()
    }

    /// **A Dock tile is not a thing you set once.** `applicationIconImage` is an
    /// override on a tile the system owns, and the system rebuilds that tile
    /// out from under it — miniaturising a window makes the Dock draw the app's
    /// icon again for the minimised tile's badge, and returning from
    /// `.accessory` builds a brand new tile that has never heard of the
    /// override. Both leave the bundle's own art on screen, which is the still
    /// noon sky rather than the sky the app has been drifting all session.
    ///
    /// Re-asserting costs a gradient and two draws — `Stencil` is already in
    /// memory — and is idempotent, so hanging it off every notification that
    /// might have disturbed the tile is cheaper than working out which of them
    /// did.
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

    /// **The last thing the Dock is told is the current sky.**
    ///
    /// AppKit tears a good deal down between the decision to quit and the
    /// process actually exiting, and anything that resets `applicationIconImage`
    /// in that window leaves the bundle's noon icon on screen for the length of
    /// the quit animation — which is exactly long enough to see. Re-asserting
    /// the current frame here costs one draw and closes that window.
    ///
    /// It cannot outlive the process: once Fetch is not running, the Dock reads
    /// its tile from the bundle, and a running app cannot rewrite its own
    /// bundle without breaking its code signature. The still icon is the one a
    /// quit app shows, by design.
    func applicationWillTerminate(_ notification: Notification) {
        DriftingDockIcon.shared.reassert()
        // **The one that survives the process.** `applicationIconImage` dies
        // with the app, so without this the Dock goes back to the asset
        // catalogue's noon sky the instant Fetch quits, and shows it again for
        // the whole of the next launch. Writing the frame into the bundle is
        // what makes the tile of a *not running* Fetch the current one.
        DriftingDockIcon.shared.persistToBundle()
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
