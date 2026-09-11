import Testing
import Foundation
@testable import FetchKit

@Suite struct PreflightCheckTests {
    @Test func reportsCapacityForRealVolume() throws {
        let capacity = try PreflightCheck.availableCapacity(
            at: FileManager.default.temporaryDirectory
        )
        #expect(capacity > 0)
    }

    @Test func passesWhenSpaceIsAmple() throws {
        try PreflightCheck.assertSpace(needed: 1, at: FileManager.default.temporaryDirectory)
    }

    @Test func throwsDiskFullWhenRequestExceedsCapacity() {
        #expect(throws: DownloadError.self) {
            try PreflightCheck.assertSpace(
                needed: Int64.max, at: FileManager.default.temporaryDirectory
            )
        }
    }
}
