import Foundation

/// What an indexer has actually done, across every search rather than the last
/// one.
///
/// **`lastLatency` could not answer the question anybody asks.** The edit sheet
/// shows one number from one query, so an indexer that answers in 200ms four
/// times out of five and times out on the fifth reads as either excellent or
/// broken depending on when you looked — and the one that is *usually* slow is
/// indistinguishable from the one that was slow once. Reserving an indexer, or
/// switching it off, is a decision about its habits.
///
/// Deliberately three integers and a sum rather than a list of samples: a
/// rolling window would have to be persisted per indexer per search, and the
/// questions worth asking here — how fast, how often does it answer — are
/// answered by an average and a rate.
public struct IndexerHealth: Sendable, Codable, Equatable {
    /// Searches this indexer returned results for, however many.
    public private(set) var answered: Int
    /// Searches it failed or timed out on.
    public private(set) var failed: Int
    /// Summed wall-clock of the answers, so the average needs no history.
    /// Successes only — the time spent waiting for a failure is the timeout,
    /// which says more about the setting than about the indexer.
    public private(set) var latencyTotal: TimeInterval
    /// The slowest answer, kept because an average hides the outlier that is
    /// actually holding a search up.
    public private(set) var slowestLatency: TimeInterval
    /// The fastest answer. With the slowest and the average it gives the shape
    /// of an indexer's behaviour in three numbers: a wide spread is a server
    /// that is sometimes fine, which reads very differently from one that is
    /// uniformly slow.
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

    /// Whether the four stored numbers can all be true of one set of samples.
    ///
    /// **They could not, and the pane printed it.** `fastestLatency` was added
    /// after `answered` and `latencyTotal` were already being persisted, so a
    /// record decoded without it kept its old count and total and then took its
    /// "minimum" from the first sample recorded *afterwards*. On the reporting
    /// install that produced `fastest: 544 ms / slowest: 544 ms / average:
    /// 313 ms` — a minimum above the mean, which is arithmetically impossible
    /// and reads, correctly, as the app not being able to add up.
    ///
    /// A float epsilon rather than exact comparison: the average is a division
    /// and the extremes are not, so a single-sample record can miss by an ulp.
    public var isConsistent: Bool {
        guard answered > 0 else { return fastestLatency == nil }
        guard let fastest = fastestLatency, let average = averageLatency else { return false }
        let epsilon = 1e-6
        return fastest <= average + epsilon && average <= slowestLatency + epsilon
    }

    /// Nil rather than zero when nothing has been recorded: "no data" and
    /// "instant" are different facts and a table must not print one for the
    /// other.
    public var averageLatency: TimeInterval? {
        answered > 0 ? latencyTotal / Double(answered) : nil
    }

    /// The share of searches this indexer did **not** answer, 0…1.
    ///
    /// Called downtime in the UI, which is what it means in practice — an
    /// indexer that fails one search in five is unavailable a fifth of the
    /// time from where the user is standing, whatever the server's own uptime
    /// graph says.
    public var failureRate: Double? {
        attempts > 0 ? Double(failed) / Double(attempts) : nil
    }

    public var reliability: Double? {
        failureRate.map { 1 - $0 }
    }

    /// **Migrates rather than trusting the file.** A record whose numbers
    /// cannot all be true of one sample set is not repairable — the minimum it
    /// is missing is not recoverable from a count and a sum — so it starts
    /// again. That costs the user their history for those indexers once, which
    /// is strictly better than a pane that goes on reporting an impossible
    /// spread until they happen to reset it by hand.
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
            // The failure history goes too. Keeping it would leave `failed`
            // counted against an `answered` that restarts at zero, so the very
            // next search would report a fresh indexer as failing.
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

/// How often a debrid service already had what was asked about.
///
/// **The number that decides whether a subscription is worth keeping.** A
/// service's value here is almost entirely how much of what you search for it
/// already holds, and nothing in the app added that up — the badge answered it
/// one row at a time and then forgot.
///
/// `checked` counts hashes this provider gave a definite answer about, so the
/// rate has a denominator that means something. A provider that cannot report
/// cache status at all is absent rather than zero: Real-Debrid's endpoint is
/// disabled, and printing "0% cached" for it would be the same fabricated miss
/// `CacheReadiness` exists to prevent.
public struct DebridCacheStats: Sendable, Codable, Equatable {
    public private(set) var checked: Int
    public private(set) var hits: Int
    /// Answers that failed rather than resolving either way.
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
