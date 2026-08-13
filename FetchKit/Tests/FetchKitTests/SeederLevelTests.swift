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

    /// A source that did not say is not a source that said zero — the same
    /// distinction the results table draws with an em dash rather than "0 B".
    @Test func anUnknownCountIsNotDead() {
        #expect(SeederLevel(seeders: nil) == nil)
    }

    /// A negative count is malformed input, not a live swarm.
    @Test func aNegativeCountIsDead() {
        #expect(SeederLevel(seeders: -1) == .dead)
    }

    /// The ramp is what carries the level for anyone who cannot use colour.
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
