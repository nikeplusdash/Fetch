import Foundation
import Testing
@testable import FetchKit

@Suite("Tones")
struct ToneTests {
    private let kinds: [MediaKind] = [
        .movie, .tv, .anime, .music, .book, .software, .game, .other, .unknown("papers"),
    ]

    @Test("Every media kind names one tone, and the same one every time")
    func everyKindHasOneTone() {
        for kind in kinds {
            #expect(kind.tone == kind.tone)
        }
        #expect(Set(kinds.map(\.tone)).count == 4)
    }

    @Test("The three moving-picture kinds share the accent, because they are one thing")
    func movingPicturesShareTheAccent() {
        #expect(MediaKind.movie.tone == .accent)
        #expect(MediaKind.tv.tone == .accent)
        #expect(MediaKind.anime.tone == .accent)
    }

    @Test("Sound, paper and the rest each read differently from a film")
    func unrelatedKindsDoNotCollide() {
        let distinct: [MediaKind] = [.movie, .music, .book, .other]
        #expect(Set(distinct.map(\.tone)).count == distinct.count)
    }

    @Test("A kind nobody named is quiet, never louder than a kind that was")
    func unnamedKindsAreQuiet() {
        #expect(MediaKind.other.tone == .quiet)
        #expect(MediaKind.unknown("papers").tone == .quiet)
        #expect(MediaKind.software.tone == .quiet)
        #expect(MediaKind.game.tone == .quiet)
    }

    @Test("A book is muted, one step above the unnamed and one below a film")
    func bookIsMuted() {
        #expect(MediaKind.book.tone == .muted)
    }

    @Test("Every verdict names one tone")
    func everyVerdictHasOneTone() {
        for verdict in HealthReport.Verdict.allCases {
            #expect(verdict.tone == verdict.tone)
        }
        #expect(Set(HealthReport.Verdict.allCases.map(\.tone)).count == 4)
    }

    @Test("The two ways of being broken share one tone, and it is the loud one")
    func brokenVerdictsAreDanger() {
        #expect(HealthReport.Verdict.failing.tone == .danger)
        #expect(HealthReport.Verdict.unreliable.tone == .danger)
    }

    @Test("Working, slow and broken never wear each other's tone")
    func verdictsThatDifferLookDifferent() {
        let distinct: [HealthReport.Verdict] = [.healthy, .slow, .failing, .untested]
        #expect(Set(distinct.map(\.tone)).count == distinct.count)
        #expect(HealthReport.Verdict.healthy.tone == .positive)
        #expect(HealthReport.Verdict.slow.tone == .caution)
    }

    @Test("A verdict nobody has tested is muted, not a warning")
    func untestedIsNotAWarning() {
        #expect(HealthReport.Verdict.untested.tone == .muted)
        #expect(HealthReport.Verdict.untested.tone != .caution)
        #expect(HealthReport.Verdict.untested.tone != .danger)
    }

    @Test("A worse verdict is never quieter than a better one")
    func toneRisesWithTheVerdict() {
        let ladder: [Tone] = [.plain, .muted, .quiet, .accent, .positive, .caution, .danger]
        let healthy = ladder.firstIndex(of: HealthReport.Verdict.healthy.tone)
        let slow = ladder.firstIndex(of: HealthReport.Verdict.slow.tone)
        let failing = ladder.firstIndex(of: HealthReport.Verdict.failing.tone)
        #expect(healthy != nil && slow != nil && failing != nil)
        #expect(healthy! < slow!)
        #expect(slow! < failing!)
    }
}
