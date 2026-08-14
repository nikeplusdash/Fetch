import Testing
import Foundation
@testable import FetchPluginAPI

@Suite struct MetadataDTOTests {
    // MARK: - Forward-compatible enums round trip, unknown never traps

    @Test func mediaKindRoundTripsKnownCases() throws {
        for kind: MediaKind in [.movie, .tv, .anime, .music, .book, .software, .game, .other] {
            let data = try JSONEncoder().encode(kind)
            #expect(try JSONDecoder().decode(MediaKind.self, from: data) == kind)
        }
    }

    @Test func mediaKindUnknownRoundTripsRatherThanTrapping() throws {
        let json = Data(#""holographic""#.utf8)
        let decoded = try JSONDecoder().decode(MediaKind.self, from: json)
        #expect(decoded == .unknown("holographic"))
        let encoded = try JSONEncoder().encode(decoded)
        #expect(String(data: encoded, encoding: .utf8) == #""holographic""#)
    }

    @Test func resolutionUnknownRoundTrips() throws {
        let json = Data(#""8K""#.utf8)
        let decoded = try JSONDecoder().decode(Resolution.self, from: json)
        #expect(decoded == .unknown("8K"))
        #expect(decoded != .r2160p)
        let encoded = try JSONEncoder().encode(decoded)
        #expect(String(data: encoded, encoding: .utf8) == #""8K""#)
    }

    @Test func resolutionKnownCasesRoundTrip() throws {
        for r: Resolution in [.r2160p, .r1080p, .r720p, .r576p, .r480p] {
            let data = try JSONEncoder().encode(r)
            #expect(try JSONDecoder().decode(Resolution.self, from: data) == r)
        }
    }

    @Test func releaseSourceUnknownRoundTrips() throws {
        let json = Data(#""telesync-cam-hybrid""#.utf8)
        let decoded = try JSONDecoder().decode(ReleaseSource.self, from: json)
        #expect(decoded == .unknown("telesync-cam-hybrid"))
    }

    @Test func videoCodecUnknownRoundTrips() throws {
        let json = Data(#""vvc""#.utf8)
        #expect(try JSONDecoder().decode(VideoCodec.self, from: json) == .unknown("vvc"))
    }

    @Test func audioCodecUnknownRoundTrips() throws {
        let json = Data(#""atmos-raw""#.utf8)
        #expect(try JSONDecoder().decode(AudioCodec.self, from: json) == .unknown("atmos-raw"))
    }

    @Test func hdrFormatUnknownRoundTrips() throws {
        let json = Data(#""hdr12""#.utf8)
        #expect(try JSONDecoder().decode(HDRFormat.self, from: json) == .unknown("hdr12"))
    }

    @Test func editionUnknownRoundTrips() throws {
        let json = Data(#""fan-edit""#.utf8)
        #expect(try JSONDecoder().decode(Edition.self, from: json) == .unknown("fan-edit"))
    }

    // MARK: - ReleaseMetadata

    @Test func releaseMetadataDefaultsToUnparsed() {
        let metadata = ReleaseMetadata.unparsed
        #expect(metadata.mediaKind == .other)
        #expect(metadata.title == nil)
        #expect(metadata.provenance.isEmpty)
        #expect(metadata.apiVersion == currentAPIVersion)
    }

    @Test func releaseMetadataRoundTripsIncludingProvenance() throws {
        let metadata = ReleaseMetadata(
            mediaKind: .tv,
            title: "The Expanse",
            season: 3,
            episodes: [5],
            resolution: .r1080p,
            source: .bluray,
            releaseGroup: "GROUP",
            provenance: [.title: .titleParse, .season: .titleParse, .resolution: .attribute]
        )
        let data = try JSONEncoder().encode(metadata)
        let decoded = try JSONDecoder().decode(ReleaseMetadata.self, from: data)
        #expect(decoded == metadata)
        #expect(decoded.provenance[.resolution] == .attribute)
    }

    @Test func metadataFieldCoversEveryStructField() {
        // Every field the corpus/merge tests reference must exist —
        // a compile-time-ish sanity check that the enum wasn't trimmed.
        #expect(MetadataField.allCases.count == 26)
    }
}
