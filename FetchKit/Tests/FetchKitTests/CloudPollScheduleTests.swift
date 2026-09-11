import Testing
import Foundation
import FetchPluginAPI
@testable import FetchKit

@Suite struct CloudPollScheduleTests {

    private let id = DebridTorrentID(rawValue: "t1")

    private func torrent(_ state: DebridTorrentState) -> DebridTorrent {
        DebridTorrent(
            id: DebridTorrentID(rawValue: "t1"), infoHashHex: "abc", name: "T",
            size: 1, progress: 0, state: state, files: [],
            seeds: nil, downloadSpeed: nil, eta: nil)
    }

    @Test func itDoublesFromThirtySecondsToATenMinuteCeiling() {
        #expect(CloudPollSchedule.interval(afterUnchangedAnswers: 0) == .seconds(30))
        #expect(CloudPollSchedule.interval(afterUnchangedAnswers: 1) == .seconds(60))
        #expect(CloudPollSchedule.interval(afterUnchangedAnswers: 2) == .seconds(120))
        #expect(CloudPollSchedule.interval(afterUnchangedAnswers: 3) == .seconds(240))
        #expect(CloudPollSchedule.interval(afterUnchangedAnswers: 4) == .seconds(480))
        #expect(CloudPollSchedule.interval(afterUnchangedAnswers: 5) == .seconds(600))
    }

    /**
     The count grows for as long as the app runs, and `1 << 64` is a trap,
     not a long interval.
     */
    @Test func anAbsurdCountIsClampedRatherThanShifted() {
        #expect(CloudPollSchedule.interval(afterUnchangedAnswers: 10_000) == .seconds(600))
        #expect(CloudPollSchedule.interval(afterUnchangedAnswers: -5) == .seconds(30))
    }

    @Test func aTorrentNeverSeenBeforeIsDueImmediately() {
        let schedule = CloudPollSchedule()
        #expect(schedule.isDue(id))
    }

    @Test func aTorrentJustAskedAboutIsNotDueYet() {
        var schedule = CloudPollSchedule()
        let now = ContinuousClock.now
        schedule.record(id, answer: torrent(.downloading), now: now)
        #expect(!schedule.isDue(id, now: now))
        #expect(schedule.isDue(id, now: now.advanced(by: .seconds(31))))
    }

    /**
     State is the signal that something is happening, so a state that
     changes is when the next answer is likely to be the interesting one.
     */
    @Test func aChangedStateResetsTheIntervalToThirtySeconds() {
        var schedule = CloudPollSchedule()
        var now = ContinuousClock.now
        for _ in 0..<5 {
            now = now.advanced(by: .seconds(600))
            schedule.record(id, answer: torrent(.downloading), now: now)
        }
        #expect(!schedule.isDue(id, now: now.advanced(by: .seconds(1))))

        schedule.record(id, answer: torrent(.completed), now: now)
        #expect(!schedule.isDue(id, now: now.advanced(by: .seconds(29))))
        #expect(schedule.isDue(id, now: now.advanced(by: .seconds(31))))
    }

    /**
     A service having a bad minute should be asked less often, not more —
     and its last known state must survive, so a later identical answer
     keeps growing the interval instead of restarting it.
     */
    @Test func aFailedLookupBacksOffRatherThanResetting() {
        var schedule = CloudPollSchedule()
        let now = ContinuousClock.now
        schedule.record(id, answer: torrent(.downloading), now: now)
        schedule.record(id, answer: nil, now: now)
        #expect(!schedule.isDue(id, now: now.advanced(by: .seconds(59))))
        #expect(schedule.isDue(id, now: now.advanced(by: .seconds(61))))
    }

    @Test func dueFiltersInTheCallersOrder() {
        var schedule = CloudPollSchedule()
        let a = DebridTorrentID(rawValue: "a")
        let b = DebridTorrentID(rawValue: "b")
        let now = ContinuousClock.now
        schedule.record(a, answer: torrent(.downloading), now: now)
        #expect(schedule.due(from: [a, b], now: now) == [b])
        #expect(schedule.due(from: [a, b], now: now.advanced(by: .seconds(31))) == [a, b])
    }

    /**
     Housekeeping, not policy: a forgotten torrent is polled sooner, never
     later, so nothing in this type can retire a row.
     */
    @Test func retainForgetsEntriesAndForgettingOnlyEverPollsSooner() {
        var schedule = CloudPollSchedule()
        let now = ContinuousClock.now
        schedule.record(id, answer: torrent(.downloading), now: now)
        #expect(!schedule.isDue(id, now: now))
        schedule.retain(only: [])
        #expect(schedule.isDue(id, now: now))
    }
}
