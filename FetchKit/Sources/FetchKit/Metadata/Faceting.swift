import Foundation
import FetchPluginAPI

/// A facetable attribute of a release (§8, Faceting).
public enum FacetDimension: String, Sendable, Codable, CaseIterable, Hashable {
    case resolution, source, videoCodec, audioCodec, hdr, language
    case releaseGroup, mediaKind, sizeBucket

    public var title: String {
        switch self {
        case .resolution: "Resolution"
        case .source: "Source"
        case .videoCodec: "Codec"
        case .audioCodec: "Audio"
        case .hdr: "HDR"
        case .language: "Language"
        case .releaseGroup: "Group"
        case .mediaKind: "Kind"
        case .sizeBucket: "Size"
        }
    }
}

/// One selectable value within a dimension.
///
/// The value is a string rather than the typed enum because dimensions carry
/// different types and several are multi-valued. Enum cases already encode to
/// strings for the plugin boundary, so this reuses that representation rather
/// than inventing a parallel one.
public struct FacetValue: Hashable, Sendable, Codable {
    public let dimension: FacetDimension
    public let value: String

    public init(dimension: FacetDimension, value: String) {
        self.dimension = dimension
        self.value = value
    }
}

/// A value plus how many results would remain if it were chosen.
public struct FacetOption: Sendable, Identifiable, Hashable {
    public let value: FacetValue
    public let label: String
    public let count: Int

    public var id: FacetValue { value }
}

/// What the user has narrowed to.
public struct FacetSelection: Sendable, Equatable {
    public private(set) var values: Set<FacetValue> = []
    /// A slider rather than a set of options, so it lives here rather than
    /// among the dimensions.
    public var minSeeders: Int = 0

    public init() {}

    public var isEmpty: Bool { values.isEmpty && minSeeders == 0 }

    public mutating func toggle(_ value: FacetValue) {
        if values.contains(value) { values.remove(value) } else { values.insert(value) }
    }

    public func contains(_ value: FacetValue) -> Bool { values.contains(value) }

    public mutating func clear() {
        values = []
        minSeeders = 0
    }

    func values(in dimension: FacetDimension) -> Set<String> {
        Set(values.filter { $0.dimension == dimension }.map(\.value))
    }

    var activeDimensions: Set<FacetDimension> { Set(values.map(\.dimension)) }
}

public enum Faceting {
    /// Size buckets, in ascending order. Boundaries chosen around how release
    /// sizes actually cluster: a 1080p web rip, a 1080p encode, a 4K encode,
    /// and a REMUX.
    static let sizeBuckets: [(label: String, range: Range<Int64>)] = [
        ("< 1 GB", 0..<1_000_000_000),
        ("1–5 GB", 1_000_000_000..<5_000_000_000),
        ("5–15 GB", 5_000_000_000..<15_000_000_000),
        ("15–50 GB", 15_000_000_000..<50_000_000_000),
        ("> 50 GB", 50_000_000_000..<Int64.max),
    ]

    /// Every value a result carries in a dimension. Multi-valued for language;
    /// at most one for the rest.
    static func values(of result: SearchResult, in dimension: FacetDimension) -> [String] {
        let metadata = result.metadata
        switch dimension {
        case .resolution: return [metadata.resolution].compactMap(encoded)
        case .source: return [metadata.source].compactMap(encoded)
        case .videoCodec: return [metadata.videoCodec].compactMap(encoded)
        case .audioCodec: return [metadata.audioCodec].compactMap(encoded)
        case .hdr: return [metadata.hdr].compactMap(encoded)
        case .mediaKind: return [encoded(metadata.mediaKind)].compactMap { $0 }
        case .language: return metadata.languages
        case .releaseGroup: return [metadata.releaseGroup].compactMap { $0 }
        case .sizeBucket:
            // No size means no bucket, not the smallest bucket: Gutenberg
            // publishes no size, and filing those under "< 1 GB" would be a
            // claim the source never made.
            guard let size = result.size else { return [] }
            return sizeBuckets.first { $0.range.contains(size) }.map { [$0.label] } ?? []
        }
    }

    /// Enum cases already encode to strings for the plugin boundary, and an
    /// unrecognized token round-trips as its raw value — so a new codec is
    /// facetable the day it appears, without a code change.
    private static func encoded<T: Encodable>(_ value: T?) -> String? {
        guard let value else { return nil }
        guard let data = try? JSONEncoder().encode([value]),
              let decoded = try? JSONDecoder().decode([String].self, from: data),
              let first = decoded.first, !first.isEmpty
        else { return nil }
        return first
    }

    /// Applies the selection: **OR within a dimension, AND across dimensions**.
    public static func filter(
        _ results: [SearchResult], selection: FacetSelection
    ) -> [SearchResult] {
        filter(results, selection: selection, ignoring: nil)
    }

    /// `ignoring` excludes one dimension from the filter — what counting a
    /// dimension's own options requires.
    private static func filter(
        _ results: [SearchResult], selection: FacetSelection, ignoring: FacetDimension?
    ) -> [SearchResult] {
        results.filter { result in
            // A minimum-seeders filter is a torrent filter. Applying it to a
            // result that has no seeders would hide every book the moment the
            // user nudged the slider off zero.
            if let seeders = result.seeders, seeders < selection.minSeeders { return false }

            for dimension in selection.activeDimensions where dimension != ignoring {
                let wanted = selection.values(in: dimension)
                guard !wanted.isEmpty else { continue }
                let actual = Set(values(of: result, in: dimension))
                guard !actual.isDisjoint(with: wanted) else { return false }
            }
            return true
        }
    }

    /// Options per dimension, counted against the set filtered by every
    /// *other* active dimension.
    ///
    /// A dimension must not narrow its own counts. If it did, selecting 1080p
    /// would leave every other resolution reading zero, and the user could
    /// never widen the filter again — the facet would be a one-way door.
    public static func options(
        for results: [SearchResult], selection: FacetSelection
    ) -> [FacetDimension: [FacetOption]] {
        var output: [FacetDimension: [FacetOption]] = [:]

        for dimension in FacetDimension.allCases {
            let scope = filter(results, selection: selection, ignoring: dimension)

            var counts: [String: Int] = [:]
            for result in scope {
                for value in values(of: result, in: dimension) {
                    counts[value, default: 0] += 1
                }
            }

            output[dimension] = counts
                .map { value, count in
                    FacetOption(
                        value: FacetValue(dimension: dimension, value: value),
                        label: value, count: count)
                }
                // Most useful cut first; label breaks ties so the list is stable
                // rather than reordering on every keystroke.
                .sorted { $0.count != $1.count ? $0.count > $1.count : $0.label < $1.label }
        }
        return output
    }
}
