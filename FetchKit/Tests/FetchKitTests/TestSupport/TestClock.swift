import Foundation
@testable import FetchKit

actor TestClock: RetryClock {
    private(set) var sleeps: [TimeInterval] = []
    func sleep(for duration: TimeInterval) async throws { sleeps.append(duration) }
    func recordedSleeps() -> [TimeInterval] { sleeps }
}
