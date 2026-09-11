import Foundation
import FetchPluginAPI

/**
 Fans out a query to every enabled `SearchProvider` concurrently, with a
 per-provider timeout, then dedupes and returns one flat result list.

 The pipeline is dedupe → parse → group → score. `parse` runs
 `ReleaseNameParser` and overlays indexer attributes; `score` is now
 `QualityProfile`-weighted Best match, which filters as well as orders.
 `group` stays identity here on purpose — see its own doc comment.
 */
public struct SearchAggregator: Sendable {
    public struct Outcome: Sendable {
        public let results: [SearchResult]
        public let filtered: [SearchResult]
        public let failures: [SearchProviderID: any Error]
    }

    let providers: [any SearchProvider]
    let perProviderTimeout: TimeInterval
    let profile: QualityProfile
    let excludeAdult: Bool

    public init(
        providers: [any SearchProvider],
        perProviderTimeout: TimeInterval = 20,
        profile: QualityProfile = .default,
        excludeAdult: Bool = true
    ) {
        self.providers = providers
        self.perProviderTimeout = perProviderTimeout
        self.profile = profile
        self.excludeAdult = excludeAdult
    }

    /**
     The providers that will actually be asked.

     Filtering here rather than inside each provider is what keeps
     `SearchEvent.started(providerCount:)` honest: a provider that cannot
     answer must not count toward "3 of 7 indexers", because the user reads
     the shortfall as indexers having failed.

     `participates(in:)` calls `capabilities()`, which for a cold indexer is
     a network round trip. Before this filter existed, that round trip
     happened inside `search(_:)`'s own `withTaskGroup`, so N providers paid
     it concurrently; a plain sequential loop here would silently turn N
     parallel round trips into N serial ones — the wall-clock cost of a
     first, cold-cache search going from the slowest indexer to the sum of
     all of them. `withTaskGroup` restores the fan-out; results are tagged
     with their original index so the kept list can be rebuilt in the order
     `providers` was given, independent of which check finishes first.
     */
    public func participants(for categories: [TorznabCategory]) async -> [any SearchProvider] {
        guard !categories.isEmpty else { return providers }
        var didParticipate = [Bool](repeating: false, count: providers.count)
        await withTaskGroup(of: (Int, Bool).self) { group in
            for (index, provider) in providers.enumerated() {
                group.addTask { (index, await provider.participates(in: categories)) }
            }
            for await (index, result) in group {
                didParticipate[index] = result
            }
        }
        return providers.indices.filter { didParticipate[$0] }.map { providers[$0] }
    }

    public func search(_ query: SearchQuery) async -> Outcome {
        var perProviderResults: [(SearchProviderID, [SearchResult])] = []
        var failures: [SearchProviderID: any Error] = [:]

        let asked = await participants(for: query.categories)
        await withTaskGroup(of: (SearchProviderID, Swift.Result<[SearchResult], any Error>).self) { group in
            for provider in asked {
                let timeout = perProviderTimeout
                group.addTask {
                    do {
                        let results = try await Self.withTimeout(seconds: timeout) {
                            try await provider.search(query)
                        }
                        return (provider.id, .success(results))
                    } catch {
                        return (provider.id, .failure(error))
                    }
                }
            }
            for await (providerID, outcome) in group {
                switch outcome {
                case .success(let results): perProviderResults.append((providerID, results))
                case .failure(let error): failures[providerID] = error
                }
            }
        }

        let allResults = perProviderResults
            .sorted { $0.0.rawValue < $1.0.rawValue }
            .flatMap(\.1)

        let outcome = Self.pipeline(
            allResults, profile: profile, matching: query.text,
            excludeAdult: excludeAdult)
        return Outcome(
            results: outcome.accepted, filtered: outcome.rejected, failures: failures)
    }

    static func pipeline(
        _ results: [SearchResult], profile: QualityProfile = .default,
        matching query: String, excludeAdult: Bool = true
    ) -> QualityProfile.Outcome {
        let permitted = excludeAdult ? AdultContentFilter.excludingAdult(results) : results
        return profile.apply(
            to: profile.orderingCandidates(of: group(parse(dedupe(permitted)))),
            matching: query)
    }


    static func dedupe(_ results: [SearchResult]) -> [SearchResult] {
        var byID: [ResultID: SearchResult] = [:]
        var order: [ResultID] = []

        for result in results {
            if let existing = byID[result.id] {
                byID[result.id] = merge(existing, result)
            } else {
                byID[result.id] = result
                order.append(result.id)
            }
        }
        return order.compactMap { byID[$0] }
    }

    private static func merge(_ a: SearchResult, _ b: SearchResult) -> SearchResult {
        let aSeeders = a.seeders ?? -1
        let bSeeders = b.seeders ?? -1
        let winner = aSeeders >= bSeeders ? a : b
        let loser = aSeeders >= bSeeders ? b : a

        let title = b.title.count > a.title.count ? b.title : a.title

        var sources = a.sources
        for source in b.sources where !sources.contains(source) { sources.append(source) }

        var rawAttributes = winner.rawAttributes
        for (key, value) in loser.rawAttributes where rawAttributes[key] == nil {
            rawAttributes[key] = value
        }

        var candidates = winner.candidates
        for candidate in loser.candidates where !candidates.contains(candidate) {
            candidates.append(candidate)
        }

        return SearchResult(
            candidates: candidates,
            title: title,
            size: winner.size,
            seeders: winner.seeders,
            peers: winner.peers,
            grabs: winner.grabs,
            fileCount: winner.fileCount,
            category: winner.category,
            publishDate: winner.publishDate,
            sources: sources,
            sourceKey: winner.sourceKey ?? loser.sourceKey,
            rawAttributes: rawAttributes,
            metadata: winner.metadata
        )
    }


    static func parse(_ results: [SearchResult]) -> [SearchResult] {
        results.map { result in
            let parsed = ReleaseNameParser.parse(result.title)
            let merged = ReleaseMetadataMerger.mergingAttributes(result.rawAttributes, into: parsed)
            var stated = ReleaseMetadataMerger.mergingStated(result.metadata, into: merged)
            if let kind = TorznabKind.mediaKind(for: result.category) {
                stated.mediaKind = kind
                stated.provenance[.mediaKind] = .attribute
            }
            return result.withMetadata(stated)
        }
    }

    static func group(_ results: [SearchResult]) -> [SearchResult] { results }

    /**
     Plain seeder order, kept as the alternative sort the results table
     offers alongside Best match (§12.1). Ranking itself now lives in
     `QualityProfile`, which `pipeline` applies.
     */
    public static func score(_ results: [SearchResult]) -> [SearchResult] {
        results.sorted { a, b in
            let aSeeders = a.seeders ?? -1
            let bSeeders = b.seeders ?? -1
            return aSeeders != bSeeders ? aSeeders > bSeeders : a.id.rawValue < b.id.rawValue
        }
    }


    static func withTimeout<T: Sendable>(
        seconds: TimeInterval, operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                throw SearchError.providerTimeout
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw SearchError.providerTimeout
            }
            return result
        }
    }
}
