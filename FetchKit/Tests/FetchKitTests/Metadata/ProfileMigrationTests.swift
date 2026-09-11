import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

@Suite struct ProfileMigrationTests {
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

    @Test func aV1SeederWeightBecomesThePopularityWeight() throws {
        let profile = try JSONDecoder().decode(QualityProfile.self, from: Data(v1.utf8))

        #expect(profile.weights.quality == 1.5)
        #expect(profile.weights.popularity == 0.8)
    }

    @Test func aV1ProfileGainsTheKindsItCouldNotExpress() throws {
        let profile = try JSONDecoder().decode(QualityProfile.self, from: Data(v1.utf8))

        #expect(profile.documentFormatOrder.first == .epub)
        #expect(profile.audioCodecOrder.first == .flac)
    }

    @Test func aV1RejectionSurvives() throws {
        let profile = try JSONDecoder().decode(QualityProfile.self, from: Data(v1.utf8))
        #expect(profile.rejected.contains(.source(.cam)))
    }


    @Test func aV2ProfileRoundTripsThroughJSON() throws {
        var profile = QualityProfile.default
        profile.documentFormatOrder = [.pdf, .epub]
        profile.prefersLossless = false
        profile.required = [.videoCodec(.hevc)]

        let decoded = try JSONDecoder().decode(
            QualityProfile.self, from: JSONEncoder().encode(profile))

        #expect(decoded == profile)
    }

    @Test func perKindEncodesAsAnObjectNotAnArray() throws {
        let data = try JSONEncoder().encode(QualityProfile.default)
        let json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["perKind"] is [String: Any])
        #expect(json["version"] as? Int == 2)
    }

    @Test func theUnreadSizeWeightIsNotResurrected() throws {
        let data = try JSONEncoder().encode(QualityProfile.default)
        let json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let weights = try #require(json["weights"] as? [String: Any])

        #expect(weights["size"] == nil)
    }
}

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

    @Test func theWinningFormatIsWrittenBackToTheMetadata() {
        let reordered = QualityProfile.default.orderingCandidates(of: book(candidates: [
            .direct(url: url("https://g/1.pdf"), format: .pdf),
            .direct(url: url("https://g/1.epub"), format: .epub),
        ]))

        #expect(reordered.metadata.documentFormat == .epub)
    }

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

    @Test func anUnlabelledCandidateSortsAfterRankedOnes() {
        let reordered = QualityProfile.default.orderingCandidates(of: book(candidates: [
            .direct(url: url("https://g/1.bin")),
            .direct(url: url("https://g/1.epub"), format: .epub),
        ]))

        #expect(reordered.candidates.first?.documentFormat == .epub)
    }

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
