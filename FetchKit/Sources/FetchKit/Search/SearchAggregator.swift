import Foundation
import FetchPluginAPI

/// Fans out a query to every enabled `SearchProvider` concurrently, with a
/// per-provider timeout, then dedupes and returns one flat result list.
///
/// The pipeline is dedupe → parse → group → score. `parse` runs
/// `ReleaseNameParser` and overlays indexer attributes; `score` is now
/// `QualityProfile`-weighted Best match, which filters as well as orders.
/// `group` stays identity here on purpose — see its own doc comment.
public struct SearchAggregator: Sendable {
    public struct Outcome: Sendable {
        public let results: [SearchResult]
        /// Removed by the active `QualityProfile`. Carried rather than dropped
        /// so §12.1's "show N filtered" affordance can make an over-strict
        /// profile discoverable instead of mystifying.
        public let filtered: [SearchResult]
        /// One dead indexer must not empty the results table — this is the
        /// non-blocking-banner sidecar ("2 of 5 indexers failed").
        public let failures: [SearchProviderID: any Error]
    }

    let providers: [any SearchProvider]
    let perProviderTimeout: TimeInterval
    let profile: QualityProfile
    /// Safe search. On by default: a debrid search surfaces whatever the
    /// indexers carry, and the setting a user has to find before their first
    /// search protects nobody.
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

    /// The providers that will actually be asked.
    ///
    /// Filtering here rather than inside each provider is what keeps
    /// `SearchEvent.started(providerCount:)` honest: a provider that cannot
    /// answer must not count toward "3 of 7 indexers", because the user reads
    /// the shortfall as indexers having failed.
    ///
    /// `participates(in:)` calls `capabilities()`, which for a cold indexer is
    /// a network round trip. Before this filter existed, that round trip
    /// happened inside `search(_:)`'s own `withTaskGroup`, so N providers paid
    /// it concurrently; a plain sequential loop here would silently turn N
    /// parallel round trips into N serial ones — the wall-clock cost of a
    /// first, cold-cache search going from the slowest indexer to the sum of
    /// all of them. `withTaskGroup` restores the fan-out; results are tagged
    /// with their original index so the kept list can be rebuilt in the order
    /// `providers` was given, independent of which check finishes first.
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

        // `TaskGroup` yields in completion order, which is not deterministic
        // run to run. Sorting by provider ID before flattening makes the
        // dedup fold below reproducible regardless of which provider answers
        // first — important since `merge` is a running fold, not a single
        // all-at-once reduction.
        let allResults = perProviderResults
            .sorted { $0.0.rawValue < $1.0.rawValue }
            .flatMap(\.1)

        let outcome = Self.pipeline(
            allResults, profile: profile, matching: query.text,
            excludeAdult: excludeAdult)
        return Outcome(
            results: outcome.accepted, filtered: outcome.rejected, failures: failures)
    }

    /// The dedupe → parse → group → score stages, in one place.
    ///
    /// Shared with `StreamedResultAccumulator` so the streaming and batch paths
    /// cannot drift apart: `SearchStreamTests` asserts they produce identical
    /// lists, and that assertion is only meaningful if both call this.
    /// Safe search runs **first**, before dedupe: an adult result merged into
    /// a clean one would carry its title and attributes into a row that then
    /// survives the filter.
    ///
    /// `query` is the text the user typed. It reaches here because 7d's
    /// primary sort key is how closely a title answers it — without it the
    /// ranking falls back to quality alone and books sort last again.
    ///
    /// Candidate reordering sits after grouping and before ranking: it is
    /// per-result, so nothing upstream of it depends on the order, and the
    /// score reads the winning format it writes back.
    static func pipeline(
        _ results: [SearchResult], profile: QualityProfile = .default,
        matching query: String, excludeAdult: Bool = true
    ) -> QualityProfile.Outcome {
        let permitted = excludeAdult ? AdultContentFilter.excludingAdult(results) : results
        return profile.apply(
            to: profile.orderingCandidates(of: group(parse(dedupe(permitted)))),
            matching: query)
    }

    // MARK: - Dedup

    /// Dedup by `infoHash`, run **before** any grouping (§7): a later
    /// "N releases" count means N distinct releases, not one release seen on
    /// N indexers.
    ///
    /// Merge rule: the entry with the highest seeder count supplies every
    /// base field; `title` is separately overridden with the longest title
    /// seen for that hash (usually the most descriptive); `sources` is the
    /// union of every contributing provider; `rawAttributes` is unioned,
    /// filling in keys the winner lacks without overwriting keys it has.
    /// Keyed on `ResultID` rather than the infohash, which for a torrent *is*
    /// the infohash — so torrent dedup is bit-for-bit what it was, and
    /// non-torrent results become dedupable instead of colliding on "".
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
        // Seeder tie-breaking applies only when both sides are torrents
        // (amendment §3). A book has no seeders, and treating nil as 0 would
        // make an arbitrary side win every merge of two direct results.
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

        // Candidates are unioned, not taken from the winner: two indexers
        // listing the same torrent may each know a different mirror, and
        // dropping the loser's would throw away a way to get the file.
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
            // Either side's key identifies the same item — they deduped to one
            // result, which for a keyed source means the key matched. Losing
            // it here would hand the merged result back to URL identity and
            // let it split again on the next candidate reorder.
            sourceKey: winner.sourceKey ?? loser.sourceKey,
            rawAttributes: rawAttributes,
            // Carried, not rebuilt. Omitting this defaulted the merged result
            // to `.unparsed`, which is 7c's bug on the merge path: a source
            // that fills `ReleaseMetadata` directly lost every stated field,
            // `mediaKind` included — and 7d picks the ranking *by* mediaKind,
            // so a merged book would have been ranked as generic.
            metadata: winner.metadata
        )
    }

    // MARK: - Pipeline stages

    /// Runs `ReleaseNameParser` against each result's `title`, then
    /// overlays `rawAttributes` via `ReleaseMetadataMerger` (§8: parse the
    /// name first, attributes win on conflict), then restores whatever the
    /// provider itself stated.
    ///
    /// The third step exists because this stage used to rebuild metadata from
    /// the title parse alone. A Torznab result carries `.unparsed` metadata so
    /// there was nothing to lose, but a source that fills `ReleaseMetadata`
    /// directly — Gutendex, Archive.org — had every stated field silently
    /// replaced by a guess made from the title. `.attribute` provenance is
    /// already the model of "a source said so", so it is what decides: a
    /// stated field is never overwritten by the parse, and an unstated one is
    /// still filled by it.
    static func parse(_ results: [SearchResult]) -> [SearchResult] {
        results.map { result in
            let parsed = ReleaseNameParser.parse(result.title)
            let merged = ReleaseMetadataMerger.mergingAttributes(result.rawAttributes, into: parsed)
            var stated = ReleaseMetadataMerger.mergingStated(result.metadata, into: merged)
            // **And the indexer's own category outranks the name.** It is a
            // stated fact from the source, which is what `.attribute`
            // provenance means everywhere else — the difference is only that
            // this source states it in a number rather than a field. Applied
            // last so it wins, and only where the tree says something: a
            // category Fetch does not model leaves the parse alone rather than
            // overwriting a good answer with nothing.
            if let kind = TorznabKind.mediaKind(for: result.category) {
                stated.mediaKind = kind
                stated.provenance[.mediaKind] = .attribute
            }
            return result.withMetadata(stated)
        }
    }

    /// Identity, deliberately.
    ///
    /// Content grouping changes the *type* — many results become one
    /// `ContentGroup` holding several — so it cannot sit inside a
    /// `[SearchResult] -> [SearchResult]` pipeline. `ContentGrouping.group` is
    /// applied at the presentation layer instead, where §12.1's flat/grouped
    /// toggle lives and where switching cannot require re-running a search.
    static func group(_ results: [SearchResult]) -> [SearchResult] { results }

    /// Plain seeder order, kept as the alternative sort the results table
    /// offers alongside Best match (§12.1). Ranking itself now lives in
    /// `QualityProfile`, which `pipeline` applies.
    public static func score(_ results: [SearchResult]) -> [SearchResult] {
        results.sorted { a, b in
            // Results with no seeder count sort by id rather than sinking to
            // the bottom: a Gutenberg book is not "worse than a 0-seed
            // torrent", it is simply not a torrent.
            let aSeeders = a.seeders ?? -1
            let bSeeders = b.seeders ?? -1
            return aSeeders != bSeeders ? aSeeders > bSeeders : a.id.rawValue < b.id.rawValue
        }
    }

    // MARK: - Per-provider timeout

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
