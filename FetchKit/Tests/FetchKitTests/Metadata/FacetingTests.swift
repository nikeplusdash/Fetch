import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

/// Client-side faceting over loaded results (§8, Faceting).
///
/// The rule that makes this more than filtering: **OR within a facet, AND
/// across facets**, with counts computed against the set filtered by all
/// *other* active facets — so a facet never offers an option that would
/// return nothing.
@Suite struct FacetingTests {
    private func result(
        _ name: String, size: Int64 = 1_000_000_000, seeders: Int = 10,
        resolution: Resolution? = nil, source: ReleaseSource? = nil,
        codec: VideoCodec? = nil, hdr: HDRFormat? = nil,
        group: String? = nil, languages: [String] = [], kind: MediaKind = .movie
    ) -> SearchResult {
        var m = ReleaseMetadata.unparsed
        m.resolution = resolution
        m.source = source
        m.videoCodec = codec
        m.hdr = hdr
        m.releaseGroup = group
        m.languages = languages
        m.mediaKind = kind
        let hash = name.lowercased().padding(toLength: 40, withPad: "0", startingAt: 0)
        return SearchResult(
            infoHashHex: hash, title: name, size: size, seeders: seeders, peers: 0,
            grabs: nil, fileCount: nil, category: nil, publishDate: nil,
            magnetURI: "magnet:?xt=urn:btih:\(hash)",
            sources: [SearchProviderID(rawValue: "ix")], rawAttributes: [:], metadata: m)
    }

    private var sample: [SearchResult] {
        [
            result("a", resolution: .r2160p, source: .webdl, codec: .hevc),
            result("b", resolution: .r1080p, source: .bluray, codec: .avc),
            result("c", resolution: .r1080p, source: .webdl, codec: .hevc),
            result("d", resolution: .r720p, source: .webrip, codec: .avc),
        ]
    }

    // MARK: - Options and counts

    @Test func optionsAreCountedFromTheResults() {
        let options = Faceting.options(for: sample, selection: FacetSelection())
        let byValue = Dictionary(
            uniqueKeysWithValues: (options[.resolution] ?? []).map { ($0.label, $0.count) })

        #expect(byValue["1080p"] == 2)
        #expect(byValue["2160p"] == 1)
        #expect(byValue["720p"] == 1)
    }

    @Test func aDimensionNoResultCarriesOffersNothing() {
        let options = Faceting.options(for: sample, selection: FacetSelection())
        #expect((options[.hdr] ?? []).isEmpty)
    }

    /// Options are ordered by count so the most useful cut is at the top,
    /// with the label breaking ties for a stable list.
    @Test func optionsAreOrderedByCountThenLabel() {
        let options = Faceting.options(for: sample, selection: FacetSelection())
        #expect((options[.resolution] ?? []).map(\.label) == ["1080p", "2160p", "720p"])
    }

    // MARK: - OR within, AND across

    @Test func twoValuesInOneDimensionAreOred() {
        var selection = FacetSelection()
        selection.toggle(.init(dimension: .resolution, value: "2160p"))
        selection.toggle(.init(dimension: .resolution, value: "720p"))

        let filtered = Faceting.filter(sample, selection: selection)
        #expect(Set(filtered.map(\.title)) == ["a", "d"])
    }

    @Test func valuesInDifferentDimensionsAreAnded() {
        var selection = FacetSelection()
        selection.toggle(.init(dimension: .resolution, value: "1080p"))
        selection.toggle(.init(dimension: .source, value: "webdl"))

        #expect(Faceting.filter(sample, selection: selection).map(\.title) == ["c"])
    }

    @Test func anEmptySelectionFiltersNothing() {
        #expect(Faceting.filter(sample, selection: FacetSelection()).count == 4)
    }

    /// The subtle rule: a dimension's own selection must not narrow its own
    /// counts, or selecting 1080p would leave every other resolution reading
    /// zero and the user could never widen the filter again.
    @Test func aDimensionsCountsIgnoreItsOwnSelection() {
        var selection = FacetSelection()
        selection.toggle(.init(dimension: .resolution, value: "1080p"))

        let options = Faceting.options(for: sample, selection: selection)
        let byValue = Dictionary(
            uniqueKeysWithValues: (options[.resolution] ?? []).map { ($0.label, $0.count) })

        #expect(byValue["2160p"] == 1)
        #expect(byValue["720p"] == 1)
    }

    /// But another dimension's selection does narrow them — that is what
    /// makes the counts honest about what a click would return.
    @Test func countsReflectOtherDimensionsSelections() {
        var selection = FacetSelection()
        selection.toggle(.init(dimension: .source, value: "webdl"))

        let options = Faceting.options(for: sample, selection: selection)
        let byValue = Dictionary(
            uniqueKeysWithValues: (options[.resolution] ?? []).map { ($0.label, $0.count) })

        #expect(byValue["2160p"] == 1)
        #expect(byValue["1080p"] == 1)
        #expect(byValue["720p"] == nil, "720p has no WEB-DL release, so it must not be offered")
    }

    // MARK: - Multi-valued dimensions

    /// A release can carry several languages; matching any selected one is
    /// enough, the same as any other OR-within-a-facet.
    @Test func aMultiValuedDimensionMatchesOnAnyValue() {
        let results = [
            result("multi", languages: ["English", "French"]),
            result("french", languages: ["French"]),
            result("silent"),
        ]
        var selection = FacetSelection()
        selection.toggle(.init(dimension: .language, value: "English"))

        #expect(Faceting.filter(results, selection: selection).map(\.title) == ["multi"])
    }

    // MARK: - Derived dimensions

    @Test func sizesFallIntoBuckets() {
        let results = [
            result("tiny", size: 500_000_000),
            result("mid", size: 8_000_000_000),
            result("huge", size: 60_000_000_000),
        ]
        let options = Faceting.options(for: results, selection: FacetSelection())
        #expect((options[.sizeBucket] ?? []).count == 3)
    }

    @Test func aSizeBucketSelectionFiltersByRange() throws {
        let results = [
            result("tiny", size: 500_000_000),
            result("huge", size: 60_000_000_000),
        ]
        var selection = FacetSelection()
        let bucket = try #require(
            Faceting.options(for: results, selection: FacetSelection())[.sizeBucket]?
                .first { $0.count == 1 && $0.label.contains("<") })
        selection.toggle(bucket.value)

        #expect(Faceting.filter(results, selection: selection).map(\.title) == ["tiny"])
    }

    /// The seeder threshold is a slider, not a set of options — it lives on
    /// the selection rather than in the dimensions.
    @Test func theSeederThresholdExcludesPoorlySeededReleases() {
        let results = [result("dead", seeders: 0), result("alive", seeders: 400)]
        var selection = FacetSelection()
        selection.minSeeders = 10

        #expect(Faceting.filter(results, selection: selection).map(\.title) == ["alive"])
    }

    // MARK: - Selection behaviour

    @Test func togglingTwiceClearsTheValue() {
        var selection = FacetSelection()
        let value = FacetValue(dimension: .resolution, value: "1080p")
        selection.toggle(value)
        selection.toggle(value)

        #expect(selection.isEmpty)
        #expect(Faceting.filter(sample, selection: selection).count == 4)
    }

    @Test func clearingRemovesEverythingIncludingTheThreshold() {
        var selection = FacetSelection()
        selection.toggle(.init(dimension: .resolution, value: "1080p"))
        selection.minSeeders = 50
        selection.clear()

        #expect(selection.isEmpty)
        #expect(selection.minSeeders == 0)
    }

    /// An unrecognized token round-trips as `.unknown` rather than nil, and
    /// must still be facetable — otherwise a new codec becomes invisible.
    @Test func anUnknownValueIsStillOfferedAsAFacet() {
        let results = [result("weird", resolution: .unknown("1440p"))]
        let options = Faceting.options(for: results, selection: FacetSelection())
        #expect((options[.resolution] ?? []).map(\.label) == ["1440p"])
    }

    @Test func facetingNothingYieldsNoOptions() {
        let options = Faceting.options(for: [], selection: FacetSelection())
        let total = options.values.reduce(0) { $0 + $1.count }
        #expect(total == 0)
    }
}
