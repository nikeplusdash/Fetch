import Foundation

/// What closing Fetch's window should do.
///
/// A download manager is the archetypal app whose window closing is not the
/// app finishing — transfers outlive the window by design, and quitting
/// mid-download is a data loss, not a tidy-up. But guessing that on the user's
/// behalf is its own trap: an app that silently refuses to quit is one people
/// end up Force Quitting.
///
/// So it is asked once, plainly, and remembered.
public enum WindowCloseBehaviour: String, CaseIterable, Sendable, Hashable {
    /// No choice made yet. The first close asks.
    case ask
    /// Window goes to the Dock, app stays as it was.
    case minimise
    /// Window closes, downloads carry on, the menu bar carries the app.
    case background
    /// Closing the window ends the app.
    case quit

    public var title: String {
        switch self {
        case .ask: "Ask every time"
        case .minimise: "Minimise to the Dock"
        case .background: "Keep downloading in the background"
        case .quit: "Quit Fetch"
        }
    }

    public var detail: String {
        switch self {
        case .ask: "Choose what happens each time the window closes."
        case .minimise: "The window goes to the Dock and everything keeps running."
        case .background:
            "The window closes and downloads carry on. Fetch stays in the menu bar."
        case .quit: "Downloads stop. Unfinished ones resume when you open Fetch again."
        }
    }

    /// Whether the app should end when its last window closes.
    ///
    /// `.ask` answers false: the question is put to the user *instead* of
    /// closing, so terminating here would answer it for them.
    public var terminatesOnLastWindowClose: Bool { self == .quit }

    /// The same choice as the four cases above, as the binary Settings now
    /// offers.
    ///
    /// **It was a binary wearing a picker.** Three of the four cases keep the
    /// app running and differ only in what happens to the *window*, which is a
    /// thing macOS already lets you decide by pressing a different button. The
    /// question worth a setting is whether closing the window stops the
    /// downloads, and that has two answers.
    ///
    /// `.ask` reads as keeping them: the dialog it stands for offers to keep
    /// going and cannot be shown from a switch, so answering "off" here would
    /// silently convert an unanswered question into a quit.
    public var keepsDownloading: Bool { self != .quit }

    /// What the switch writes. `.minimise` is not reachable from it, on
    /// purpose: minimising is the yellow button, and a preference that
    /// duplicates a window control is a second place for the same decision to
    /// live.
    public init(keepsDownloading: Bool) {
        self = keepsDownloading ? .background : .quit
    }
}

/// How far along everything currently downloading is, for the menu bar.
public struct ActiveProgress: Sendable, Equatable {
    public let count: Int
    /// 0…1 across every running download, by bytes rather than by file — a
    /// 4 GB remux and a 2 MB cover are not half the work each.
    public let fraction: Double

    public init(count: Int, fraction: Double) {
        self.count = count
        self.fraction = fraction
    }

    /// Nil when nothing is running, so the caller can show the plain icon
    /// rather than "0%", which reads as a stalled download.
    public static func of(
        _ items: [(state: DownloadState, downloaded: Int64, total: Int64)]
    ) -> ActiveProgress? {
        let live = items.filter { $0.state == .downloading || $0.state == .queued }
        guard !live.isEmpty else { return nil }

        let total = live.reduce(Int64(0)) { $0 + $1.total }
        let done = live.reduce(Int64(0)) { $0 + $1.downloaded }
        // An unknown total is not zero progress: with nothing to divide by,
        // the honest answer is "running" rather than a made-up percentage.
        guard total > 0 else { return ActiveProgress(count: live.count, fraction: 0) }
        return ActiveProgress(
            count: live.count, fraction: min(Double(done) / Double(total), 1))
    }
}
