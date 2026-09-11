import Testing
import Foundation
@testable import FetchKit

@Suite struct RateEstimatorTests {
    private static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func firstSampleReportsZeroBecauseThereIsNothingToCompareYet() {
        var estimator = RateEstimator()
        let rate = estimator.update(bytes: 0, at: Self.epoch)
        #expect(rate == 0)
    }

    @Test func sampleBeforeTheRefreshIntervalEchoesThePreviousRate() {
        var estimator = RateEstimator(alpha: 0.2, minimumRefreshInterval: 0.5)
        _ = estimator.update(bytes: 0, at: Self.epoch)

        let tooSoon = estimator.update(bytes: 50_000, at: Self.epoch.addingTimeInterval(0.1))
        #expect(tooSoon == 0)
    }

    @Test func firstRealWindowPublishesItsInstantaneousRate() {
        var estimator = RateEstimator(alpha: 0.2, minimumRefreshInterval: 0.5)
        _ = estimator.update(bytes: 0, at: Self.epoch)

        let rate = estimator.update(bytes: 500_000, at: Self.epoch.addingTimeInterval(1.0))
        #expect(rate == 500_000)
    }

    @Test func aSuddenSpikeIsPulledTowardHistoryNotAdoptedOutright() {
        var estimator = RateEstimator(alpha: 0.2, minimumRefreshInterval: 0.5)
        var now = Self.epoch
        _ = estimator.update(bytes: 0, at: now)

        var bytes: Int64 = 0
        for _ in 0..<5 {
            now = now.addingTimeInterval(1.0)
            bytes += 200_000
            _ = estimator.update(bytes: bytes, at: now)
        }
        let baseline = estimator.currentRate
        #expect(abs(baseline - 200_000) < 1)

        now = now.addingTimeInterval(1.0)
        bytes += 2_000_000
        let afterSpike = estimator.update(bytes: bytes, at: now)

        #expect(afterSpike > baseline, "should move toward the spike…")
        #expect(afterSpike < 2_000_000, "…but not jump all the way to it")
        #expect(abs(afterSpike - 560_000) < 1)
    }

    @Test func noForwardProgressKeepsThePreviousRateInsteadOfCollapsingToZero() {
        var estimator = RateEstimator(alpha: 0.2, minimumRefreshInterval: 0.5)
        var now = Self.epoch
        _ = estimator.update(bytes: 0, at: now)
        now = now.addingTimeInterval(1.0)
        let established = estimator.update(bytes: 300_000, at: now)
        #expect(established > 0)

        now = now.addingTimeInterval(1.0)
        let repeated = estimator.update(bytes: 300_000, at: now)
        #expect(repeated == established)
    }

    @Test func recomputesAtMostAtTheConfiguredRefreshInterval() {
        var estimator = RateEstimator(alpha: 0.2, minimumRefreshInterval: 0.5)
        var now = Self.epoch
        _ = estimator.update(bytes: 0, at: now)
        now = now.addingTimeInterval(1.0)
        let first = estimator.update(bytes: 1_000_000, at: now)

        for tick in 1...10 {
            now = now.addingTimeInterval(0.04)
            let rate = estimator.update(bytes: 1_000_000 + Int64(tick * 1_000), at: now)
            #expect(rate == first)
        }
    }
}
