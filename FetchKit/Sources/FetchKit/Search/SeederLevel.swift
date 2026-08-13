import Foundation

/// How healthy a swarm is, as the `SeederMeter` renders it.
///
/// Thresholds are the design system's: high ≥ 100 · medium 10–99 · low 1–9 ·
/// dead 0. Colour is reinforcement, not signal — `filledBars` encodes the
/// level geometrically, and the exact count is always shown beside it. A dead
/// torrent is worth surfacing loudly: it will never complete, however good the
/// release is.
public enum SeederLevel: String, CaseIterable, Sendable, Equatable {
    case high, medium, low, dead

    /// Nil for an unknown count. A source that did not say is not a source
    /// that said zero, and rendering a dead meter for "unknown" would tell the
    /// user something false about a perfectly healthy release.
    public init?(seeders: Int?) {
        guard let seeders else { return nil }
        switch seeders {
        case 100...: self = .high
        case 10..<100: self = .medium
        case 1..<10: self = .low
        default: self = .dead
        }
    }

    /// Of four. The ramp is what conveys the level without colour.
    public var filledBars: Int {
        switch self {
        case .high: 4
        case .medium: 2
        case .low: 1
        case .dead: 0
        }
    }

    public var accessibilityDescription: String {
        switch self {
        case .high: "well seeded"
        case .medium: "moderately seeded"
        case .low: "poorly seeded"
        case .dead: "no seeders — this will not complete"
        }
    }
}
