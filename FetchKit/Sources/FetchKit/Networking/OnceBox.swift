import Foundation

/// Runs a closure the first time and ignores every call after.
///
/// Exists for `CheckedContinuation`, which **traps the process** when resumed
/// twice. `ChunkedBody` has two paths that can both report the same failure —
/// cancelling a non-HTTP response, and the completion callback that cancel
/// then triggers — and a trap in a download is a crash the user sees.
final class OnceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func once(_ body: () -> Void) {
        lock.lock()
        if fired {
            lock.unlock()
            return
        }
        fired = true
        lock.unlock()
        body()
    }
}
