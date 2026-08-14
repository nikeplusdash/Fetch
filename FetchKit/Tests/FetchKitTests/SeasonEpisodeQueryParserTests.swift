import Testing
@testable import FetchKit

/// This is a small, dedicated helper scoped only to deriving `season`/`episode`
/// from a free-text search query — NOT the full `ReleaseNameParser` (§8),
/// which is M3 scope and parses complete release names against a token-table
/// corpus. This parser only needs to recognize the couple of patterns a user
/// is likely to type into a search box, so `t=tvsearch` can be used instead of
/// free text (§7).
@Suite struct SeasonEpisodeQueryParserTests {
    @Test func standardSxxExxPattern() {
        let result = SeasonEpisodeQueryParser.extract(from: "The Expanse S03E05")
        #expect(result.title == "The Expanse")
        #expect(result.season == 3)
        #expect(result.episode == 5)
    }

    @Test func lowercaseAndNoLeadingZeros() {
        let result = SeasonEpisodeQueryParser.extract(from: "the expanse s3e5")
        #expect(result.title == "the expanse")
        #expect(result.season == 3)
        #expect(result.episode == 5)
    }

    @Test func alternateXPattern() {
        let result = SeasonEpisodeQueryParser.extract(from: "Show 1x02")
        #expect(result.title == "Show")
        #expect(result.season == 1)
        #expect(result.episode == 2)
    }

    @Test func noPatternLeavesTextUnchanged() {
        let result = SeasonEpisodeQueryParser.extract(from: "Breaking Bad")
        #expect(result.title == "Breaking Bad")
        #expect(result.season == nil)
        #expect(result.episode == nil)
    }

    @Test func doesNotFalsePositiveOnResolutionTokens() {
        let result = SeasonEpisodeQueryParser.extract(from: "Movie 2160p")
        #expect(result.season == nil)
        #expect(result.episode == nil)
        #expect(result.title == "Movie 2160p")
    }

    @Test func collapsesWhitespaceLeftBehindByTheMatch() {
        let result = SeasonEpisodeQueryParser.extract(from: "The  Expanse   S03E05   ")
        #expect(result.title == "The Expanse")
        #expect(result.season == 3)
        #expect(result.episode == 5)
    }

    @Test func matchWithNothingElseYieldsEmptyTitle() {
        let result = SeasonEpisodeQueryParser.extract(from: "S03E05")
        #expect(result.title == "")
        #expect(result.season == 3)
        #expect(result.episode == 5)
    }
}
