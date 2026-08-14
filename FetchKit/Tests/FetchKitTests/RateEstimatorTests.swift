import Testing
import Foundation
@testable import FetchKit

/// Regression coverage for Task 17 Bug 2.2: `AppModel` used to derive
/// `bytesPerSecond` from two consecutive progress samples with no
/// smoothing, so a tick that landed slightly early or late produced a wild
/// instantaneous rate, and the ETA built from it flipped between values
/// like "about 3 minutes" and "2 minutes" on every ~100ms progress event.
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

        // Only 100ms later — well under the 500ms refresh floor — mimics
        // the ~10Hz progress cadence `DownloadEngine` actually emits at.
        let tooSoon = estimator.update(bytes: 50_000, at: Self.epoch.addingTimeInterval(0.1))
        #expect(tooSoon == 0)
    }

    @Test func firstRealWindowPublishesItsInstantaneousRate() {
        var estimator = RateEstimator(alpha: 0.2, minimumRefreshInterval: 0.5)
        _ = estimator.update(bytes: 0, at: Self.epoch)

        // 500_000 bytes over 1 second == 500_000 B/s, and nothing has been
        // published yet, so the EMA has no history to blend against.
        let rate = estimator.update(bytes: 500_000, at: Self.epoch.addingTimeInterval(1.0))
        #expect(rate == 500_000)
    }

    @Test func aSuddenSpikeIsPulledTowardHistoryNotAdoptedOutright() {
        var estimator = RateEstimator(alpha: 0.2, minimumRefreshInterval: 0.5)
        var now = Self.epoch
        _ = estimator.update(bytes: 0, at: now)

        // Establish a steady ~200_000 B/s baseline over several windows.
        var bytes: Int64 = 0
        for _ in 0..<5 {
            now = now.addingTimeInterval(1.0)
            bytes += 200_000
            _ = estimator.update(bytes: bytes, at: now)
        }
        let baseline = estimator.currentRate
        #expect(abs(baseline - 200_000) < 1)   // converged after 5 identical windows

        // A single 2_000_000 B/s window (10x the baseline) — a plausible
        // burst right after a slow start, or scheduling jitter on one tick.
        now = now.addingTimeInterval(1.0)
        bytes += 2_000_000
        let afterSpike = estimator.update(bytes: bytes, at: now)

        #expect(afterSpike > baseline, "should move toward the spike…")
        #expect(afterSpike < 2_000_000, "…but not jump all the way to it")
        // EMA with alpha=0.2: 0.2 * 2_000_000 + 0.8 * 200_000 == 560_000.
        #expect(abs(afterSpike - 560_000) < 1)
    }

    @Test func noForwardProgressKeepsThePreviousRateInsteadOfCollapsingToZero() {
        var estimator = RateEstimator(alpha: 0.2, minimumRefreshInterval: 0.5)
        var now = Self.epoch
        _ = estimator.update(bytes: 0, at: now)
        now = now.addingTimeInterval(1.0)
        let established = estimator.update(bytes: 300_000, at: now)
        #expect(established > 0)

        // Same byte count again (e.g. the first tick after a pause/resume
        // replays the position it was already at) — must not report 0.
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

        // Ten rapid-fire samples inside one refresh window (mirrors
        // progress arriving ~10x/sec against a 500ms floor) must not move
        // the published rate at all.
        for tick in 1...10 {
            now = now.addingTimeInterval(0.04)
            let rate = estimator.update(bytes: 1_000_000 + Int64(tick * 1_000), at: now)
            #expect(rate == first)
        }
    }
}
