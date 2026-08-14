import FetchKit
import Foundation
import UserNotifications

/// Tells the user a download finished, when Fetch is not the app they are
/// looking at.
///
/// **Only when Fetch is in the background.** A notification about something
/// you are watching happen is noise — the row already said so, and more
/// legibly. `NSApplication.isActive` is the whole rule.
///
/// **This does not work in a development build, and the reason is measured,
/// not guessed.** Asking for authorisation returns:
///
///     UNErrorDomain Code=1 "Notifications are not allowed for this application"
///
/// Fetch is ad-hoc signed — `codesign` reports `Signature=adhoc`,
/// `TeamIdentifier=not set` — and macOS will not grant notification
/// authorisation to a bundle with no stable signing identity. The app never
/// appears in Notification Centre's preferences, so there is nothing for the
/// user to switch on either. Verified by launching through `open` with the
/// bundle freshly registered with LaunchServices, so it is not an artefact of
/// running the binary directly.
///
/// This is the same wall that killed the Keychain here, and it is the one
/// HANDOFF predicted notifications would hit. **Signing with a real
/// certificate is the fix; there is no code change that helps.** Until then
/// this stays wired up, logs the refusal once, and is silent — which is the
/// right failure for something this peripheral.
@MainActor
final class DownloadNotifier {
    private var isAuthorised = false
    private var hasAsked = false

    /// Asked for at launch, not on the first finished download.
    ///
    /// **This is why no notification ever appeared.** The first version asked
    /// for permission inside the delivery path, *behind* a guard that skipped
    /// delivery whenever Fetch was frontmost — so someone watching their
    /// download finish never reached the request, never saw the prompt, and
    /// therefore could never be notified afterwards either. The gate came
    /// before the thing it depended on.
    func prepare() {
        Task { await authorise() }
    }

    /// Every finished download, whether or not Fetch is frontmost.
    ///
    /// The old rule — only when in the background — sounds tidy and is wrong
    /// for this app: a download runs for minutes and the whole point is that
    /// you go and do something else. "Frontmost" also includes sitting on the
    /// Settings screen with Downloads out of sight.
    func downloadFinished(name: String) {
        Task { await deliver(name: name) }
    }

    @discardableResult
    private func authorise() async -> Bool {
        guard !hasAsked else { return isAuthorised }
        hasAsked = true
        do {
            isAuthorised = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
            fetchLog(.info, "notify", "authorisation \(isAuthorised ? "granted" : "denied")")
        } catch {
            // Ad-hoc signing is the likely culprit and it is worth naming in
            // the log, because no amount of code fixes it.
            isAuthorised = false
            fetchLog(.warn, "notify",
                     "authorisation failed: \(String(describing: error))")
        }
        return isAuthorised
    }

    private func deliver(name: String) async {
        guard await authorise() else { return }

        let content = UNMutableNotificationContent()
        content.title = "Download finished"
        content.body = name
        content.sound = .default

        // No trigger: deliver now. A zero-interval trigger is rejected, and
        // any delay would announce a download the user has already seen land.
        do {
            try await UNUserNotificationCenter.current().add(
                UNNotificationRequest(
                    identifier: UUID().uuidString, content: content, trigger: nil))
        } catch {
            fetchLog(.warn, "notify", "delivery failed: \(String(describing: error))")
        }
    }
}
