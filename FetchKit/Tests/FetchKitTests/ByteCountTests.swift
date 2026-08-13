import Testing
@testable import FetchKit

@Suite struct ByteCountTests {
    @Test func formatsBytesInBinaryUnits() {
        #expect(ByteCount.format(0).contains("0"))
        #expect(ByteCount.format(1_048_576).contains("MB"))
    }

    @Test func formatsRateWithPerSecondSuffix() {
        #expect(ByteCount.rate(1_048_576).hasSuffix("/s"))
    }

    @Test func etaReturnsNilForNonPositiveRate() {
        #expect(ByteCount.eta(remaining: 100, bytesPerSecond: 0) == nil)
    }

    @Test func etaFormatsPositiveRate() {
        #expect(ByteCount.eta(remaining: 1_000_000, bytesPerSecond: 100_000) != nil)
    }

    @Test func etaReturnsNilWhenNothingRemains() {
        #expect(ByteCount.eta(remaining: 0, bytesPerSecond: 100_000) == nil)
    }

    // MARK: - Task 17 Bug 2.1: pinned-unit formatting
    //
    // Regression coverage for the "size vibrates" bug: `format(_:)` alone
    // recomputes the best-fit unit for every value it's handed, so a byte
    // count hovering near a unit boundary (say, a total near 1 MB) flips
    // between "998 KB" and "1.1 MB" tick to tick as it climbs toward that
    // total — a string-length change that visibly reflows the row on every
    // progress update. Pinning the unit once, from the total, and reusing
    // it for every intermediate value keeps the string's shape stable.

    @Test func pinnedUnitIsChosenFromTotalBytes() {
        #expect(ByteCount.pinnedUnit(for: 500) == .useBytes)
        #expect(ByteCount.pinnedUnit(for: 500_000) == .useKB)
        #expect(ByteCount.pinnedUnit(for: 500_000_000) == .useMB)
        #expect(ByteCount.pinnedUnit(for: 5_000_000_000) == .useGB)
    }

    @Test func formatPinnedToUsesTheGivenUnitEvenBelowItsOwnNaturalThreshold() {
        // 999 KB alone would naturally format in KB, but a download whose
        // *total* is ~1 GB must render its transferred figure in GB too, so
        // the two numbers in "x / y" always share a unit.
        let text = ByteCount.format(999_000, pinnedTo: .useGB)
        #expect(text.contains("GB"))
        #expect(!text.contains("KB"))
    }

    @Test func pinnedFormattingDoesNotChangeUnitAsBytesCrossANaturalBoundary() {
        // A total just over 1 MB pins the unit to MB. Format a sequence of
        // transferred values that would, under `format(_:)`'s own
        // per-value unit choice, cross from KB into MB partway through —
        // with the unit pinned, every one of them must report the same
        // unit, unlike the un-pinned formatter.
        let total: Int64 = 1_100_000
        let unit = ByteCount.pinnedUnit(for: total)
        #expect(unit == .useMB)

        let samples: [Int64] = [10_000, 500_000, 998_000, 1_000_000, 1_050_000, total]
        let unitSuffixes = Set(samples.map { sample -> String in
            let text = ByteCount.format(sample, pinnedTo: unit)
            return text.hasSuffix("MB") ? "MB" : (text.hasSuffix("KB") ? "KB" : "other")
        })
        #expect(unitSuffixes == ["MB"])

        // Sanity check that this scenario would otherwise have flapped:
        // the un-pinned formatter disagrees with itself across the same
        // samples (some render in KB, at least one in MB).
        let unpinnedSuffixes = Set(samples.map { sample -> String in
            let text = ByteCount.format(sample)
            return text.hasSuffix("MB") ? "MB" : (text.hasSuffix("KB") ? "KB" : "other")
        })
        #expect(unpinnedSuffixes.count > 1)
    }
}
