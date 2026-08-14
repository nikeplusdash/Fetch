import Foundation

/// Smooths a bursty, instantaneous transfer rate into one stable enough to
/// display without "vibrating" the UI on every progress tick.
///
/// `DownloadEngine.report` always emits `bytesPerSecond: 0` — the rate has
/// to be derived client-side from consecutive (bytes, timestamp) samples.
/// Progress arrives roughly 10x/sec, and a rate computed from two
/// back-to-back samples that close together is dominated by scheduling
/// jitter (a slightly-early or slightly-late tick swings the instantaneous
/// value wildly), which in turn makes a derived ETA flip between, say,
/// "about 3 minutes" and "2 minutes" tick to tick.
///
/// Two independent techniques fix this, both driven by wall-clock time
/// rather than call count so behaviour doesn't depend on how often the
/// caller happens to sample:
///
/// 1. **Throttled recomputation.** A new rate is only derived at most once
///    per `minimumRefreshInterval` (~2x/sec is plenty for a human-readable
///    number); calls in between just echo the last published value. This
///    also means each computed instantaneous rate is averaged over a wider
///    time window, which is noise reduction in its own right.
/// 2. **Exponential moving average.** Each newly computed instantaneous
///    rate is blended with the running estimate (`alpha` toward the new
///    sample, `1 - alpha` toward history) rather than replacing it
///    outright, so a single anomalous tick can't swing the displayed value
///    on its own.
public struct RateEstimator: Sendable {
    private let alpha: Double
    private let minimumRefreshInterval: TimeInterval

    private var smoothedRate: Double = 0
    private var lastPublishedAt: Date?
    private var lastPublishedBytes: Int64?

    /// - Parameters:
    ///   - alpha: EMA weight given to each new instantaneous sample, in
    ///     `(0, 1]`. ~0.2 is the standard "plenty smooth but still tracks a
    ///     real trend within a few seconds" choice.
    ///   - minimumRefreshInterval: minimum wall-clock time between
    ///     recomputed (and therefore possibly changed) published rates.
    public init(alpha: Double = 0.2, minimumRefreshInterval: TimeInterval = 0.5) {
        precondition(alpha > 0 && alpha <= 1, "alpha must be in (0, 1]")
        self.alpha = alpha
        self.minimumRefreshInterval = minimumRefreshInterval
    }

    /// The most recently published smoothed rate, in bytes/sec. `0` before
    /// any sample has been published.
    public var currentRate: Double { smoothedRate }

    /// Feed a new `(bytes downloaded so far, timestamp)` sample. Returns the
    /// rate the UI should display right now — which may be unchanged from
    /// the last call, either because the refresh interval hasn't elapsed
    /// yet or because `bytes` didn't advance (e.g. the first sample after a
    /// resume, replaying the position a paused job was already at).
    @discardableResult
    public mutating func update(bytes: Int64, at now: Date = Date()) -> Double {
        guard let lastAt = lastPublishedAt, let lastBytes = lastPublishedBytes else {
            // First sample ever: nothing to derive a rate from yet.
            lastPublishedAt = now
            lastPublishedBytes = bytes
            return smoothedRate
        }

        let elapsed = now.timeIntervalSince(lastAt)
        guard elapsed >= minimumRefreshInterval else {
            return smoothedRate
        }

        defer {
            lastPublishedAt = now
            lastPublishedBytes = bytes
        }

        guard elapsed > 0, bytes > lastBytes else {
            // No forward progress across this window — keep publishing the
            // last real estimate rather than letting it collapse to 0.
            return smoothedRate
        }

        let instantaneous = Double(bytes - lastBytes) / elapsed
        smoothedRate = smoothedRate == 0
            ? instantaneous
            : (alpha * instantaneous + (1 - alpha) * smoothedRate)
        return smoothedRate
    }
}
