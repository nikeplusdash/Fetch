import SwiftUI

struct AppAlert: Identifiable, Equatable {
    let id = UUID()
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    static func == (a: AppAlert, b: AppAlert) -> Bool { a.id == b.id }
}

@MainActor
protocol ErrorPresenter: AnyObject {
    func present(_ alert: AppAlert)
}

/**
 The no-op used until plan 1 lands `ErrorPanel`, and in previews.

 **Not a fatalError and not a print.** A stub that crashes makes plan 2
 untestable against this seam; a stub that logs quietly is what the old
 banner effectively was. It holds the last alert so a test can assert one was
 raised without a window existing.
 */
@MainActor
final class RecordingErrorPresenter: ErrorPresenter {
    private(set) var alerts: [AppAlert] = []
    func present(_ alert: AppAlert) { alerts.append(alert) }
}
