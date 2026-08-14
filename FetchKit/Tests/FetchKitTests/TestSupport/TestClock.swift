import Foundation
@testable import FetchKit

/// Records requested sleeps without performing them, so retry tests assert
/// on backoff behaviour in microseconds rather than seconds.
actor TestClock: RetryClock {
    private(set) var sleeps: [TimeInterval] = []
    func sleep(for duration: TimeInterval) async throws { sleeps.append(duration) }
    func recordedSleeps() -> [TimeInterval] { sleeps }
}
