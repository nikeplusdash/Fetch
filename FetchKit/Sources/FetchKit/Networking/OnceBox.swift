import Foundation

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
