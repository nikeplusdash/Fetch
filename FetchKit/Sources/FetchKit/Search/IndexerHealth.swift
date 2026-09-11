import Foundation

/**
 What an indexer has actually done, across every search rather than the last
 one.

 **`lastLatency` could not answer the question anybody asks.** The edit sheet
 shows one number from one query, so an indexer that answers in 200ms four
 times out of five and times out on the fifth reads as either excellent or
 broken depending on when you looked — and the one that is *usually* slow is
 indistinguishable from the one that was slow once. Reserving an indexer, or
 switching it off, is a decision about its habits.

 Deliberately three integers and a sum rather than a list of samples: a
 rolling window would have to be persisted per indexer per search, and the
 questions worth asking here — how fast, how often does it answer — are
 answered by an average and a rate.
 */
public struct IndexerHealth: Sendable, Codable, Equatable {
    public private(set) var answered: Int
    public private(set) var failed: Int
    public private(set) var latencyTotal: TimeInterval
    public private(set) var slowestLatency: TimeInterval
    public private(set) var fastestLatency: TimeInterval?
    public private(set) var lastFailure: String?
    public private(set) var lastFailedAt: Date?

    public init(
        answered: Int = 0, failed: Int = 0,
        latencyTotal: TimeInterval = 0, slowestLatency: TimeInterval = 0,
        fastestLatency: TimeInterval? = nil,
        lastFailure: String? = nil, lastFailedAt: Date? = nil
    ) {
        self.answered = answered
        self.failed = failed
        self.latencyTotal = latencyTotal
        self.slowestLatency = slowestLatency
        self.fastestLatency = fastestLatency
        self.lastFailure = lastFailure
        self.lastFailedAt = lastFailedAt
    }

    public var attempts: Int { answered + failed }

    public var isConsistent: Bool {
        guard answered > 0 else { return fastestLatency == nil }
        guard let fastest = fastestLatency, let average = averageLatency else { return false }
        let epsilon = 1e-6
        return fastest <= average + epsilon && average <= slowestLatency + epsilon
    }

    public var averageLatency: TimeInterval? {
        answered > 0 ? latencyTotal / Double(answered) : nil
    }

    public var failureRate: Double? {
        attempts > 0 ? Double(failed) / Double(attempts) : nil
    }

    public var reliability: Double? {
        failureRate.map { 1 - $0 }
    }

    /**
     **Migrates rather than trusting the file.** A record whose numbers
     cannot all be true of one sample set is not repairable — the minimum it
     is missing is not recoverable from a count and a sum — so it starts
     again. That costs the user their history for those indexers once, which
     is strictly better than a pane that goes on reporting an impossible
     spread until they happen to reset it by hand.
     */
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decoded = IndexerHealth(
            answered: try container.decodeIfPresent(Int.self, forKey: .answered) ?? 0,
            failed: try container.decodeIfPresent(Int.self, forKey: .failed) ?? 0,
            latencyTotal: try container.decodeIfPresent(
                TimeInterval.self, forKey: .latencyTotal) ?? 0,
            slowestLatency: try container.decodeIfPresent(
                TimeInterval.self, forKey: .slowestLatency) ?? 0,
            fastestLatency: try container.decodeIfPresent(
                TimeInterval.self, forKey: .fastestLatency),
            lastFailure: try container.decodeIfPresent(String.self, forKey: .lastFailure),
            lastFailedAt: try container.decodeIfPresent(Date.self, forKey: .lastFailedAt))

        guard decoded.isConsistent else {
            self.init()
            return
        }
        self = decoded
    }

    public mutating func record(latency: TimeInterval, failure: String?, at now: Date = Date()) {
        if let failure {
            failed += 1
            lastFailure = failure
            lastFailedAt = now
        } else {
            answered += 1
            let clamped = max(0, latency)
            latencyTotal += clamped
            slowestLatency = max(slowestLatency, clamped)
            fastestLatency = min(fastestLatency ?? clamped, clamped)
        }
    }
}

/**
 How often a debrid service already had what was asked about.

 **The number that decides whether a subscription is worth keeping.** A
 service's value here is almost entirely how much of what you search for it
 already holds, and nothing in the app added that up — the badge answered it
 one row at a time and then forgot.

 `checked` counts hashes this provider gave a definite answer about, so the
 rate has a denominator that means something. A provider that cannot report
 cache status at all is absent rather than zero: Real-Debrid's endpoint is
 disabled, and printing "0% cached" for it would be the same fabricated miss
 `CacheReadiness` exists to prevent.
 */
public struct DebridCacheStats: Sendable, Codable, Equatable {
    public private(set) var checked: Int
    public private(set) var hits: Int
    public private(set) var errors: Int

    public init(checked: Int = 0, hits: Int = 0, errors: Int = 0) {
        self.checked = checked
        self.hits = hits
        self.errors = errors
    }

    public var misses: Int { max(0, checked - hits) }

    public var hitRate: Double? {
        checked > 0 ? Double(hits) / Double(checked) : nil
    }

    public mutating func recordHit() { checked += 1; hits += 1 }
    public mutating func recordMiss() { checked += 1 }
    public mutating func recordError() { errors += 1 }

    public static func + (lhs: Self, rhs: Self) -> Self {
        DebridCacheStats(
            checked: lhs.checked + rhs.checked,
            hits: lhs.hits + rhs.hits,
            errors: lhs.errors + rhs.errors)
    }
}
