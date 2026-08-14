import Testing
import Foundation
@testable import FetchKit

/// Splitting a file into parallel byte ranges, and remembering which are done.
///
/// **Why this type has to exist.** `RangeTransfer` sends one open-ended
/// `Range: bytes=<offset>-`, so a single file downloads over exactly one
/// connection and `maxConcurrent` does nothing for it. Segmenting is what
/// saturates a debrid link.
///
/// The cost is stated at the top of `RangeTransfer`: resume worked because the
/// partial file's size on disk *was* the offset, needing no stored state.
/// Eight ranges in flight leave holes, so size stops meaning progress and this
/// map becomes the thing that must be right — hence the tests.
@Suite struct SegmentMapTests {

    // MARK: - Planning

    @Test func aFileSplitsIntoEvenSegments() {
        let plan = SegmentMap.plan(totalBytes: 1000, segments: 4)
        #expect(plan == [0..<250, 250..<500, 500..<750, 750..<1000])
    }

    /// The remainder has to land somewhere or the tail of the file is never
    /// fetched — an off-by-one here truncates every download.
    @Test func anUnevenSplitStillCoversEveryByte() {
        let plan = SegmentMap.plan(totalBytes: 1003, segments: 4)
        #expect(plan.first?.lowerBound == 0)
        #expect(plan.last?.upperBound == 1003)
        #expect(plan.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) } == 1003)
    }

    @Test func segmentsNeverOverlap() {
        let plan = SegmentMap.plan(totalBytes: 9_999, segments: 7)
        for (a, b) in zip(plan, plan.dropFirst()) {
            #expect(a.upperBound == b.lowerBound)
        }
    }

    /// More segments than bytes must not produce empty ranges — an empty
    /// range would be a request for nothing that never completes.
    @Test func aTinyFileIsNotSplitIntoEmptyRanges() {
        let plan = SegmentMap.plan(totalBytes: 3, segments: 8)
        #expect(plan.allSatisfy { !$0.isEmpty })
        #expect(plan.count <= 3)
        #expect(plan.last?.upperBound == 3)
    }

    @Test func oneSegmentIsTheWholeFile() {
        #expect(SegmentMap.plan(totalBytes: 500, segments: 1) == [0..<500])
    }

    @Test func anEmptyFileHasNothingToFetch() {
        #expect(SegmentMap.plan(totalBytes: 0, segments: 8).isEmpty)
    }

    /// A size the server never declared cannot be split — the caller must fall
    /// back to a single open-ended range.
    @Test func anUnknownSizeCannotBePlanned() {
        #expect(SegmentMap.plan(totalBytes: -1, segments: 8).isEmpty)
    }

    // MARK: - Progress

    @Test func afreshMapHasEverythingRemaining() {
        let map = SegmentMap(totalBytes: 1000, segments: 4)
        #expect(map.bytesComplete == 0)
        #expect(!map.isComplete)
        #expect(map.remaining == [0..<250, 250..<500, 500..<750, 750..<1000])
    }

    @Test func completingASegmentRemovesItFromRemaining() {
        var map = SegmentMap(totalBytes: 1000, segments: 4)
        map.markComplete(250..<500)

        #expect(map.bytesComplete == 250)
        #expect(map.remaining == [0..<250, 500..<750, 750..<1000])
    }

    /// Adjacent completed ranges coalesce, so the map cannot grow without
    /// bound over a long resumed download.
    @Test func adjacentCompletedRangesMerge() {
        var map = SegmentMap(totalBytes: 1000, segments: 4)
        map.markComplete(0..<250)
        map.markComplete(250..<500)

        #expect(map.completedRanges == [0..<500])
    }

    @Test func overlappingCompletionIsIdempotent() {
        var map = SegmentMap(totalBytes: 1000, segments: 4)
        map.markComplete(0..<300)
        map.markComplete(200..<500)

        #expect(map.completedRanges == [0..<500])
        #expect(map.bytesComplete == 500)
    }

    @Test func completingEverythingCompletesTheMap() {
        var map = SegmentMap(totalBytes: 1000, segments: 4)
        for range in map.remaining { map.markComplete(range) }

        #expect(map.isComplete)
        #expect(map.bytesComplete == 1000)
        #expect(map.remaining.isEmpty)
    }

    /// Partial progress inside a segment counts, so a connection dropped
    /// mid-range does not throw away what it already wrote.
    @Test func aPartiallyFinishedSegmentKeepsWhatItWrote() {
        var map = SegmentMap(totalBytes: 1000, segments: 4)
        map.markComplete(0..<100)

        #expect(map.bytesComplete == 100)
        #expect(map.remaining.first == 100..<250)
    }

    // MARK: - Resume

    /// The whole point: a resumed download re-requests only the holes.
    @Test func resumingRefetchesOnlyTheGaps() throws {
        var map = SegmentMap(totalBytes: 1000, segments: 4)
        map.markComplete(0..<250)
        map.markComplete(500..<750)

        let encoded = try JSONEncoder().encode(map)
        let restored = try JSONDecoder().decode(SegmentMap.self, from: encoded)

        #expect(restored.remaining == [250..<500, 750..<1000])
        #expect(restored.bytesComplete == 500)
    }

    /// A map whose file changed size underneath it is not trustworthy — the
    /// link may point at different content, and resuming against it would
    /// interleave two files.
    @Test func aMapForADifferentSizeIsRejected() {
        var map = SegmentMap(totalBytes: 1000, segments: 4)
        map.markComplete(0..<250)

        #expect(!map.matches(totalBytes: 2000))
        #expect(map.matches(totalBytes: 1000))
    }

    @Test func mapsRoundTripThroughJSON() throws {
        var map = SegmentMap(totalBytes: 5_000_000_000, segments: 8)
        map.markComplete(0..<1_000_000)

        let decoded = try JSONDecoder().decode(
            SegmentMap.self, from: try JSONEncoder().encode(map))
        #expect(decoded == map)
    }
}
