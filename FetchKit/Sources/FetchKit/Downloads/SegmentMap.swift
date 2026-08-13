import Foundation

/// Which byte ranges of a file still need fetching.
///
/// **Why this replaces "the partial file's size is the offset".**
/// `RangeTransfer` sends one open-ended `Range: bytes=<offset>-`, so a file
/// downloads over exactly one connection — and for a single-file torrent, the
/// engine's `maxConcurrent` therefore does nothing at all. Splitting a file
/// into parallel ranges is what actually saturates a debrid link.
///
/// The cost is real and was a deliberate choice in the original design: with
/// eight ranges in flight the partial file has holes, so its size on disk stops
/// meaning "how much is done". This map is what takes over that job, which is
/// why it is persisted with the download record and tested this heavily — if it
/// is wrong, a resumed download either refetches everything or, worse, believes
/// it holds bytes it never wrote.
public struct SegmentMap: Sendable, Equatable, Codable {
    public let totalBytes: Int64
    /// Sorted, non-overlapping, coalesced.
    public private(set) var completedRanges: [Range<Int64>]

    public init(totalBytes: Int64, segments: Int) {
        self.totalBytes = totalBytes
        self.completedRanges = []
        self.plannedSegments = Self.plan(totalBytes: totalBytes, segments: segments)
    }

    /// The initial split, kept so `remaining` can report gaps segment by
    /// segment rather than as one enormous range after the first completion.
    private var plannedSegments: [Range<Int64>]

    /// Splits a file into `segments` contiguous ranges covering every byte.
    ///
    /// Returns nothing for an unknown or empty size — the caller must fall
    /// back to a single open-ended range, since a server that never declared a
    /// length cannot be split.
    public static func plan(totalBytes: Int64, segments: Int) -> [Range<Int64>] {
        guard totalBytes > 0, segments > 0 else { return [] }

        // Never produce empty ranges: a request for zero bytes would be issued
        // and never complete, wedging the download at 99%.
        let count = Int64(min(Int64(segments), totalBytes))
        let size = totalBytes / count

        return (0..<count).map { index in
            let start = index * size
            // The last segment absorbs the remainder, or the tail of the file
            // is never fetched and every download truncates.
            let end = index == count - 1 ? totalBytes : start + size
            return start..<end
        }
    }

    /// Records bytes now on disk, coalescing with what was already there so the
    /// map cannot grow without bound across a long resumed download.
    public mutating func markComplete(_ range: Range<Int64>) {
        guard !range.isEmpty else { return }

        var merged = completedRanges + [range]
        merged.sort { $0.lowerBound < $1.lowerBound }

        var result: [Range<Int64>] = []
        for next in merged {
            if let last = result.last, next.lowerBound <= last.upperBound {
                result[result.count - 1] =
                    last.lowerBound..<Swift.max(last.upperBound, next.upperBound)
            } else {
                result.append(next)
            }
        }
        completedRanges = result
    }

    public var bytesComplete: Int64 {
        completedRanges.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
    }

    public var isComplete: Bool { bytesComplete >= totalBytes && totalBytes > 0 }

    /// The gaps still to fetch, clipped to the planned segment boundaries so
    /// work stays parallelizable after a partial resume.
    public var remaining: [Range<Int64>] {
        var gaps: [Range<Int64>] = []

        for segment in plannedSegments {
            var cursor = segment.lowerBound
            for done in completedRanges where done.upperBound > segment.lowerBound
                && done.lowerBound < segment.upperBound {
                if done.lowerBound > cursor {
                    gaps.append(cursor..<Swift.min(done.lowerBound, segment.upperBound))
                }
                cursor = Swift.max(cursor, done.upperBound)
            }
            if cursor < segment.upperBound { gaps.append(cursor..<segment.upperBound) }
        }
        return gaps
    }

    /// Whether this map can be trusted against a file the server now reports as
    /// `totalBytes`.
    ///
    /// A size change means the link points at different content. Resuming
    /// against it would interleave two files into one — silently, and
    /// undetectably until the file failed to play.
    public func matches(totalBytes: Int64) -> Bool { self.totalBytes == totalBytes }
}
