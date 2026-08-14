import SwiftUI

/// Something that went wrong while the user was looking somewhere else.
///
/// **Not every failure is one of these.** A failed download explains itself in
/// its own sub-line, because the row is still there to be looked at. A missing
/// debrid key is the full-screen empty state, because the screen has nothing
/// else to show. This type is for the third case only: a thing that happened
/// out of view, which will not be discovered unless it is said once.
struct AppAlert: Identifiable, Equatable {
    let id = UUID()
    /// One sentence. If it needs two, it is a state rather than an alert, and
    /// states belong on a row or in an empty view.
    let message: String
    /// At most one, and it must be a verb. Nil for something you can only be
    /// told about.
    var actionTitle: String?
    var action: (() -> Void)?

    static func == (a: AppAlert, b: AppAlert) -> Bool { a.id == b.id }
}

/// The seam the three plans share.
///
/// Plan 1 implements this with a panel outside the window. Plan 2 calls it
/// instead of drawing a red line at the foot of a sheet. Declared in the
/// foundation commit so neither has to wait for the other, and so the call
/// sites in plan 2 compile against something real before plan 1 merges.
@MainActor
protocol ErrorPresenter: AnyObject {
    func present(_ alert: AppAlert)
}

/// The no-op used until plan 1 lands `ErrorPanel`, and in previews.
///
/// **Not a fatalError and not a print.** A stub that crashes makes plan 2
/// untestable against this seam; a stub that logs quietly is what the old
/// banner effectively was. It holds the last alert so a test can assert one was
/// raised without a window existing.
@MainActor
final class RecordingErrorPresenter: ErrorPresenter {
    private(set) var alerts: [AppAlert] = []
    func present(_ alert: AppAlert) { alerts.append(alert) }
}
