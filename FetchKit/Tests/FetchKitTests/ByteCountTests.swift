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


    @Test func pinnedUnitIsChosenFromTotalBytes() {
        #expect(ByteCount.pinnedUnit(for: 500) == .useBytes)
        #expect(ByteCount.pinnedUnit(for: 500_000) == .useKB)
        #expect(ByteCount.pinnedUnit(for: 500_000_000) == .useMB)
        #expect(ByteCount.pinnedUnit(for: 5_000_000_000) == .useGB)
    }

    @Test func formatPinnedToUsesTheGivenUnitEvenBelowItsOwnNaturalThreshold() {
        let text = ByteCount.format(999_000, pinnedTo: .useGB)
        #expect(text.contains("GB"))
        #expect(!text.contains("KB"))
    }

    @Test func pinnedFormattingDoesNotChangeUnitAsBytesCrossANaturalBoundary() {
        let total: Int64 = 1_100_000
        let unit = ByteCount.pinnedUnit(for: total)
        #expect(unit == .useMB)

        let samples: [Int64] = [10_000, 500_000, 998_000, 1_000_000, 1_050_000, total]
        let unitSuffixes = Set(samples.map { sample -> String in
            let text = ByteCount.format(sample, pinnedTo: unit)
            return text.hasSuffix("MB") ? "MB" : (text.hasSuffix("KB") ? "KB" : "other")
        })
        #expect(unitSuffixes == ["MB"])

        let unpinnedSuffixes = Set(samples.map { sample -> String in
            let text = ByteCount.format(sample)
            return text.hasSuffix("MB") ? "MB" : (text.hasSuffix("KB") ? "KB" : "other")
        })
        #expect(unpinnedSuffixes.count > 1)
    }
}
