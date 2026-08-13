import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

/// Stage 7d §6. `AppModel` decodes the persisted profile with `try?`, so a v1
/// blob against the v2 shape does not crash — it silently yields `.default`
/// and discards whatever the user had customised. That is the failure these
/// tests exist to prevent.
@Suite struct ProfileMigrationTests {
    /// A profile exactly as v1 wrote it: three video axes, `weights.seeders`,
    /// a `weights.size` that `score` never read, and no version field.
    private let v1 = """
    {
      "resolutionOrder": ["720p", "1080p", "2160p"],
      "sourceOrder": ["bluray", "remux"],
      "codecOrder": ["hevc", "av1"],
      "required": [],
      "rejected": [{"source": {"_0": "cam"}}],
      "weights": {"quality": 1.5, "seeders": 0.8, "size": 0.2}
    }
    """

    @Test func aV1ProfileKeepsItsCustomisedVideoOrder() throws {
        let profile = try JSONDecoder().decode(QualityProfile.self, from: Data(v1.utf8))

        #expect(profile.resolutionOrder == [.r720p, .r1080p, .r2160p])
        #expect(profile.sourceOrder == [.bluray, .remux])
        #expect(profile.codecOrder == [.hevc, .av1])
    }

    /// `weights.seeders` is v1's spelling of the same term.
    @Test func aV1SeederWeightBecomesThePopularityWeight() throws {
        let profile = try JSONDecoder().decode(QualityProfile.self, from: Data(v1.utf8))

        #expect(profile.weights.quality == 1.5)
        #expect(profile.weights.popularity == 0.8)
    }

    /// v1 could not express book or music preferences, so migration takes the
    /// shipped defaults for them rather than leaving them empty — an empty
    /// order ranks every format equally, which is the inert ranking 7d fixes.
    @Test func aV1ProfileGainsTheKindsItCouldNotExpress() throws {
        let profile = try JSONDecoder().decode(QualityProfile.self, from: Data(v1.utf8))

        #expect(profile.documentFormatOrder.first == .epub)
        #expect(profile.audioCodecOrder.first == .flac)
    }

    @Test func aV1RejectionSurvives() throws {
        let profile = try JSONDecoder().decode(QualityProfile.self, from: Data(v1.utf8))
        #expect(profile.rejected.contains(.source(.cam)))
    }

    // MARK: - v2 round trip

    @Test func aV2ProfileRoundTripsThroughJSON() throws {
        var profile = QualityProfile.default
        profile.documentFormatOrder = [.pdf, .epub]
        profile.prefersLossless = false
        profile.required = [.videoCodec(.hevc)]

        let decoded = try JSONDecoder().decode(
            QualityProfile.self, from: JSONEncoder().encode(profile))

        #expect(decoded == profile)
    }

    /// `perKind` is keyed on `MediaKind`, and Swift encodes a dictionary with
    /// a non-`String` key as a flat alternating array. Asserting the shape
    /// keeps the persisted profile readable and the v1 fallback writable.
    @Test func perKindEncodesAsAnObjectNotAnArray() throws {
        let data = try JSONEncoder().encode(QualityProfile.default)
        let json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["perKind"] is [String: Any])
        #expect(json["version"] as? Int == 2)
    }

    /// The unread `weights.size` is dropped, not carried: §8's `sizeBounds`
    /// is where size preference belongs, and a slider that does nothing is
    /// worse than an absent one.
    @Test func theUnreadSizeWeightIsNotResurrected() throws {
        let data = try JSONEncoder().encode(QualityProfile.default)
        let json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let weights = try #require(json["weights"] as? [String: Any])

        #expect(weights["size"] == nil)
    }
}

/// Stage 7d §4.7. Format preference reorders a result's candidates, and
/// `SearchResult.init` re-sorts them by `preferenceRank` immediately after.
/// That interaction is load-bearing and invisible; without a test naming it,
/// simplifying the sort would quietly break format preference.
@Suite struct CandidateOrderTests {
    private func url(_ s: String) -> URL { URL(string: s)! }
    private let hex = String(repeating: "ef", count: 20)

    private func book(candidates: [ResultOrigin]) -> SearchResult {
        var m = ReleaseMetadata.unparsed
        m.mediaKind = .book
        m.documentFormat = candidates.compactMap(\.documentFormat).first
        return SearchResult(
            candidates: candidates, title: "Dune", size: nil, seeders: nil,
            peers: nil, category: nil, publishDate: nil, sources: [],
            sourceKey: "gutenberg:1", rawAttributes: [:], metadata: m)
    }

    @Test func candidatesReorderToThePreferredFormat() {
        let reordered = QualityProfile.default.orderingCandidates(of: book(candidates: [
            .direct(url: url("https://g/1.pdf"), format: .pdf),
            .direct(url: url("https://g/1.epub"), format: .epub),
        ]))

        #expect(reordered.candidates.first?.documentFormat == .epub)
    }

    /// The winner is what the row displays *and* what a download with no UI
    /// takes. The two must not be allowed to disagree.
    @Test func theWinningFormatIsWrittenBackToTheMetadata() {
        let reordered = QualityProfile.default.orderingCandidates(of: book(candidates: [
            .direct(url: url("https://g/1.pdf"), format: .pdf),
            .direct(url: url("https://g/1.epub"), format: .epub),
        ]))

        #expect(reordered.metadata.documentFormat == .epub)
    }

    /// **The subtle one.** A torrent must keep §4's precedence over every
    /// direct candidate even while the directs reorder among themselves —
    /// `preferenceRank` outranks format, always. Reordering may never promote
    /// a torrent above a `.direct` or the other way round.
    @Test func formatReorderingNeverDisturbsPreferenceRank() {
        let reordered = QualityProfile.default.orderingCandidates(of: book(candidates: [
            .direct(url: url("https://g/1.pdf"), format: .pdf),
            .torrent(infoHash: InfoHash(hex)!,
                     magnet: MagnetLink("magnet:?xt=urn:btih:\(hex)")!, targetPath: nil),
            .direct(url: url("https://g/1.epub"), format: .epub),
        ]))

        #expect(reordered.candidates.map(\.preferenceRank) == [0, 0, 2])
        #expect(reordered.candidates.first?.documentFormat == .epub)
    }

    /// Changing the preference must not change the book's identity. This is
    /// the known gap, asserted at the level the pipeline actually runs.
    @Test func reorderingDoesNotChangeTheResultsIdentity() {
        let original = book(candidates: [
            .direct(url: url("https://g/1.pdf"), format: .pdf),
            .direct(url: url("https://g/1.epub"), format: .epub),
        ])
        var pdfFirst = QualityProfile.default
        pdfFirst.documentFormatOrder = [.pdf, .epub]

        #expect(QualityProfile.default.orderingCandidates(of: original).id
            == pdfFirst.orderingCandidates(of: original).id)
    }

    /// Changing the preference *does* change the winner — or the setting is
    /// decorative, which is the gap this stage closes.
    @Test func reorderingPreferenceChangesTheWinningCandidate() {
        let original = book(candidates: [
            .direct(url: url("https://g/1.epub"), format: .epub),
            .direct(url: url("https://g/1.pdf"), format: .pdf),
        ])
        var pdfFirst = QualityProfile.default
        pdfFirst.documentFormatOrder = [.pdf, .epub]

        #expect(pdfFirst.orderingCandidates(of: original)
            .candidates.first?.documentFormat == .pdf)
    }

    /// A candidate whose format nobody stated sorts after every ranked one
    /// rather than being shuffled unpredictably against them.
    @Test func anUnlabelledCandidateSortsAfterRankedOnes() {
        let reordered = QualityProfile.default.orderingCandidates(of: book(candidates: [
            .direct(url: url("https://g/1.bin")),
            .direct(url: url("https://g/1.epub"), format: .epub),
        ]))

        #expect(reordered.candidates.first?.documentFormat == .epub)
    }

    /// Only text ranks on format. A film's mirrors keep the provider's own
    /// order, which for mirrors is usually meaningful.
    @Test func aNonTextResultKeepsItsCandidateOrder() {
        var m = ReleaseMetadata.unparsed
        m.mediaKind = .movie
        m.resolution = .r1080p
        let film = SearchResult(
            candidates: [.direct(url: url("https://a/2")), .direct(url: url("https://a/1"))],
            title: "Dune", size: nil, seeders: nil, peers: nil, category: nil,
            publishDate: nil, sources: [], sourceKey: "ia:dune",
            rawAttributes: [:], metadata: m)

        #expect(QualityProfile.default.orderingCandidates(of: film).candidates
            == film.candidates)
    }
}
