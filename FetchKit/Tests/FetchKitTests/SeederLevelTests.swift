import Testing
@testable import FetchKit

@Suite struct SeederLevelTests {
    @Test func thresholdsMatchTheDesignSystem() {
        #expect(SeederLevel(seeders: 0) == .dead)
        #expect(SeederLevel(seeders: 1) == .low)
        #expect(SeederLevel(seeders: 9) == .low)
        #expect(SeederLevel(seeders: 10) == .medium)
        #expect(SeederLevel(seeders: 99) == .medium)
        #expect(SeederLevel(seeders: 100) == .high)
        #expect(SeederLevel(seeders: 10_000) == .high)
    }

    @Test func anUnknownCountIsNotDead() {
        #expect(SeederLevel(seeders: nil) == nil)
    }

    @Test func aNegativeCountIsDead() {
        #expect(SeederLevel(seeders: -1) == .dead)
    }

    @Test func barsRampWithLevel() {
        #expect(SeederLevel.dead.filledBars == 0)
        #expect(SeederLevel.low.filledBars == 1)
        #expect(SeederLevel.medium.filledBars == 2)
        #expect(SeederLevel.high.filledBars == 4)
    }

    @Test func everyLevelHasAVoiceOverDescription() {
        for level in SeederLevel.allCases {
            #expect(!level.accessibilityDescription.isEmpty, "\(level)")
        }
    }
}
