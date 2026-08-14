import Foundation

/// The one line of help under a debrid service's name in Settings.
///
/// **The row has to explain the order it is in.** Preference used to be
/// expressed by a star, which explained nothing, beside a card that said a
/// provider was a different kind of thing from every other setting. The order
/// of the rows *is* the preference, so the top row says so, and every row says
/// the one other thing that differs between these services: whether it can
/// report what it has cached. Real-Debrid cannot — the endpoint was withdrawn —
/// and a user who is never told will read the missing badges as a bug.
///
/// Here rather than in the pane because it is a four-way choice over two
/// booleans, and because the app target cannot test a `switch` inside a view.
public enum DebridRowCopy {
    public static func help(
        isPreferred: Bool, reportsCacheStatus: Bool, isEnabled: Bool
    ) -> String {
        guard isEnabled else {
            return "Off. Nothing routes to it until you switch it back on."
        }
        switch (isPreferred, reportsCacheStatus) {
        case (true, true):
            return "Preferred. Reports what it has cached, so results are badged "
                + "before you open them."
        case (true, false):
            return "Preferred. Cannot report cached status, so nothing from it "
                + "is badged."
        case (false, true):
            return "Used when it already has the torrent. Reports what it has cached."
        case (false, false):
            return "Cannot report cached status, so nothing from it is badged."
        }
    }
}
