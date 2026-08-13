import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

/// Ranking releases (§8, Ranking).
///
/// The spec's own justification: "Best match is the default because seeder
/// count alone reliably surfaces the wrong thing — a 720p rip usually
/// out-seeds the REMUX." Every test here is a version of that sentence.
@Suite struct QualityProfileTests {
    private func result(
        _ name: String, seeders: Int = 10, size: Int64 = 1_000_000_000,
        resolution: Resolution? = nil, source: ReleaseSource? = nil,
        codec: VideoCodec? = nil, group: String? = nil
    ) -> SearchResult {
        var m = ReleaseMetadata.unparsed
        m.resolution = resolution
        m.source = source
        m.videoCodec = codec
        m.releaseGroup = group
        let hash = String(
            (name + "\(seeders)").unicodeScalars
                .filter { CharacterSet.alphanumerics.contains($0) }
                .map { String($0) }.joined()
                .padding(toLength: 40, withPad: "0", startingAt: 0))
        return SearchResult(
            infoHashHex: hash, title: name, size: size, seeders: seeders, peers: 0,
            grabs: nil, fileCount: nil, category: nil, publishDate: nil,
            magnetURI: "magnet:?xt=urn:btih:\(hash)",
            sources: [SearchProviderID(rawValue: "ix")],
            rawAttributes: [:], metadata: m)
    }

    // MARK: - The headline case

    /// The whole reason Best match exists.
    @Test func aRemuxOutranksAHigherSeededRip() {
        let remux = result("REMUX", seeders: 40, resolution: .r1080p, source: .remux)
        let rip = result("rip", seeders: 400, resolution: .r720p, source: .webrip)

        let ranked = QualityProfile.default.rank([rip, remux], matching: "")
        #expect(ranked.first?.title == "REMUX")
    }

    /// But seeders are not ignored — between equals, availability decides.
    @Test func betweenEqualQualityMoreSeedersWins() {
        let a = result("a", seeders: 10, resolution: .r1080p, source: .bluray)
        let b = result("b", seeders: 900, resolution: .r1080p, source: .bluray)

        #expect(QualityProfile.default.rank([a, b], matching: "").first?.title == "b")
    }

    @Test func higherResolutionOutranksLower() {
        let uhd = result("uhd", seeders: 10, resolution: .r2160p, source: .webdl)
        let hd = result("hd", seeders: 10, resolution: .r1080p, source: .webdl)

        #expect(QualityProfile.default.rank([hd, uhd], matching: "").first?.title == "uhd")
    }

    // MARK: - Hard filters

    /// `rejected` is a filter, not a penalty: "no amount of seeders makes a
    /// camrip the right answer."
    @Test func camAndScreenerAreRejectedOutrightByDefault() {
        let cam = result("cam", seeders: 99_999, resolution: .r1080p, source: .cam)
        let screener = result("screener", seeders: 50_000, source: .screener)
        let real = result("real", seeders: 3, resolution: .r1080p, source: .bluray)

        let ranked = QualityProfile.default.rank([cam, screener, real], matching: "")
        #expect(ranked.map(\.title) == ["real"])
    }

    @Test func aRequiredTokenExcludesReleasesLackingIt() {
        var profile = QualityProfile.default
        profile.required = [.resolution(.r2160p)]

        let uhd = result("uhd", resolution: .r2160p, source: .webdl)
        let hd = result("hd", seeders: 5000, resolution: .r1080p, source: .bluray)

        #expect(profile.rank([hd, uhd], matching: "").map(\.title) == ["uhd"])
    }

    @Test func rejectingAReleaseGroupRemovesIt() {
        var profile = QualityProfile.default
        profile.rejected.append(.releaseGroup("YIFY"))

        let yify = result("small", seeders: 900, resolution: .r1080p, source: .bluray, group: "YIFY")
        let other = result("other", seeders: 10, resolution: .r1080p, source: .bluray, group: "FGT")

        #expect(profile.rank([yify, other], matching: "").map(\.title) == ["other"])
    }

    /// Filtering must be reported, not silent — §12.1 shows rejected releases
    /// behind a "show N filtered" affordance so an over-strict profile is
    /// discoverable rather than mystifying.
    @Test func filteringReportsWhatItRemoved() {
        let cam = result("cam", source: .cam)
        let real = result("real", resolution: .r1080p, source: .bluray)

        let outcome = QualityProfile.default.apply(to: [cam, real], matching: "")
        #expect(outcome.accepted.map(\.title) == ["real"])
        #expect(outcome.rejected.map(\.title) == ["cam"])
    }

    // MARK: - Unknown metadata

    /// A release nothing could be parsed from must still be rankable — it
    /// sorts low, but dropping it would hide results the user can see on the
    /// indexer itself.
    @Test func anUnparsedReleaseIsRankedNotDiscarded() {
        let known = result("known", seeders: 10, resolution: .r1080p, source: .bluray)
        let unknown = result("unknown", seeders: 10)

        let ranked = QualityProfile.default.rank([unknown, known], matching: "")
        #expect(ranked.count == 2)
        #expect(ranked.first?.title == "known")
    }

    /// An unrecognized token round-trips as `.unknown` rather than nil, and
    /// must not be mistaken for a preferred value.
    @Test func anUnknownResolutionDoesNotOutrankAKnownOne() {
        let weird = result("weird", seeders: 10, resolution: .unknown("1440p"), source: .bluray)
        let known = result("known", seeders: 10, resolution: .r2160p, source: .bluray)

        #expect(QualityProfile.default.rank([weird, known], matching: "").first?.title == "known")
    }

    // MARK: - Determinism

    @Test func rankingIsStableAcrossRuns() {
        let input = [
            result("a", seeders: 50, resolution: .r1080p, source: .bluray),
            result("b", seeders: 50, resolution: .r1080p, source: .bluray),
            result("c", seeders: 50, resolution: .r1080p, source: .bluray),
        ]
        let first = QualityProfile.default.rank(input, matching: "").map(\.title)
        for _ in 0..<10 {
            #expect(QualityProfile.default.rank(input, matching: "").map(\.title) == first)
        }
    }

    @Test func rankingNothingYieldsNothing() {
        #expect(QualityProfile.default.rank([], matching: "").isEmpty)
    }

    // MARK: - Profile as data

    /// Profiles are Tier-1 plugin data (§8), so one must survive a JSON
    /// round trip — a profile that cannot be written to a file is not one.
    @Test func aProfileRoundTripsThroughJSON() throws {
        var profile = QualityProfile.default
        profile.required = [.videoCodec(.hevc)]
        profile.rejected = [.source(.cam), .releaseGroup("YIFY")]

        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(QualityProfile.self, from: data)

        #expect(decoded.required == profile.required)
        #expect(decoded.rejected == profile.rejected)
        #expect(decoded.resolutionOrder == profile.resolutionOrder)
    }

    /// Reordering preferences must actually change the answer, or the profile
    /// is decorative.
    @Test func reorderingPreferenceChangesTheWinner() {
        var smallestFirst = QualityProfile.default
        smallestFirst.resolutionOrder = [.r720p, .r1080p, .r2160p]

        let uhd = result("uhd", seeders: 10, resolution: .r2160p, source: .webdl)
        let sd = result("720", seeders: 10, resolution: .r720p, source: .webdl)

        #expect(QualityProfile.default.rank([sd, uhd], matching: "").first?.title == "uhd")
        #expect(smallestFirst.rank([sd, uhd], matching: "").first?.title == "720")
    }
}
