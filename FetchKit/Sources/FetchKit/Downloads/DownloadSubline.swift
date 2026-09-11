import Foundation

/**
 Everything a row's one sub-line could be built from.

 A struct rather than nine arguments, because the call site is a view and a
 view passing nine positional values is a view making decisions about their
 order.
 */
public struct DownloadRowFacts: Sendable {
    public var state: DownloadState
    public var bytesDownloaded: Int64
    public var totalBytes: Int64
    public var pinnedUnit: ByteCountFormatter.Units
    public var etaText: String?
    public var failureReason: String?
    public var destination: String?
    public var queuePosition: Int?
    public var preparingStatus: String?
    public var cloudDiagnosis: String?

    public init(
        state: DownloadState,
        bytesDownloaded: Int64 = 0,
        totalBytes: Int64 = 0,
        pinnedUnit: ByteCountFormatter.Units = .useAll,
        etaText: String? = nil,
        failureReason: String? = nil,
        destination: String? = nil,
        queuePosition: Int? = nil,
        preparingStatus: String? = nil,
        cloudDiagnosis: String? = nil
    ) {
        self.state = state
        self.bytesDownloaded = bytesDownloaded
        self.totalBytes = totalBytes
        self.pinnedUnit = pinnedUnit
        self.etaText = etaText
        self.failureReason = failureReason
        self.destination = destination
        self.queuePosition = queuePosition
        self.preparingStatus = preparingStatus
        self.cloudDiagnosis = cloudDiagnosis
    }
}

/**
 The one fact a Downloads row says under its name.

 **One fact, never two.** The row used to carry a joined sentence of up to
 five parts — file count, bytes, rate, ETA, provider — every one of which
 changes length as a download runs, so the row reflowed ten times a second
 and said five things none of which was the one you wanted. The columns now
 carry size, rate and date; this carries the single thing the columns cannot,
 and which thing that is depends on the state:

 - running: how far along, and how long is left
 - queued: where in the line
 - failed: why, and the way out
 - finished: nothing. The glyph has already said so, and where it landed is
   the row's tooltip rather than a line under every entry in the library

 Nil where the state has nothing to add that the row is not already showing.
 An empty sub-line is better than a filler one: the row keeps its height
 either way, and a line that always says something teaches people to stop
 reading it.
 */
/**
 Where a row's one fact goes.

 Only a row that is moving gets a second line. A downloading row's progress
 and a preparing row's status change while you watch them, which is what a
 stacked line is for; a queue position, a paused percentage and a failure
 reason are static, and stacking them doubles the height of the list for text
 that never changes. What those rows would have said is not thrown away — a
 failure's reason is the whole reason to look — it moves to the tooltip.
 */
public enum SublinePlacement: Sendable, Equatable {
    case underName(String)
    case tooltip(String)
    case none

    public var text: String? {
        switch self {
        case .underName(let text), .tooltip(let text): text
        case .none: nil
        }
    }

    public var isUnderName: Bool {
        if case .underName = self { return true }
        return false
    }

    public var isTooltip: Bool {
        if case .tooltip = self { return true }
        return false
    }
}

public enum DownloadSubline {
    /**
     What the row says and where it says it. The text is `text(_:locale:)`'s
     as before; this only decides whether the row is one line or two.
     */
    public static func placement(
        _ facts: DownloadRowFacts, locale: Locale = .current
    ) -> SublinePlacement {
        guard let text = text(facts, locale: locale) else { return .none }
        return facts.state.isActive ? .underName(text) : .tooltip(text)
    }

    public static func text(_ facts: DownloadRowFacts, locale: Locale = .current) -> String? {
        switch facts.state {
        case .downloading:
            let moved = transferred(facts)
            guard let eta = facts.etaText else { return moved }
            return "\(moved), \(eta) left"

        case .preparing:
            return facts.preparingStatus ?? "Your debrid service is fetching it."

        case .queued:
            guard let position = facts.queuePosition, position > 0 else {
                return "Waiting for a free slot."
            }
            return "\(ordinal(position, locale: locale)) in line"

        case .paused:
            guard let percent = percent(facts) else { return "Paused." }
            return "Paused at \(percent)%"

        case .completed:
            return nil

        case .failed:
            guard let reason = facts.failureReason, !reason.isEmpty else {
                return "It did not finish. Try again."
            }
            return "\(sentence(reason)) Try again"

        case .cancelled:
            guard let percent = percent(facts) else { return "You stopped this." }
            return "Stopped at \(percent)%"

        case .missing:
            return "Not where Fetch saved it."

        case .onCloud:
            return nil

        case .cloudQueued:
            return facts.cloudDiagnosis ?? "Your debrid service is fetching this."
        }
    }

    static func transferred(_ facts: DownloadRowFacts) -> String {
        let total = ByteCount.format(facts.totalBytes, pinnedTo: facts.pinnedUnit)
        let done = ByteCount.format(facts.bytesDownloaded, pinnedTo: facts.pinnedUnit)
        guard let unit = total.split(separator: " ").last,
              done.hasSuffix(" \(unit)")
        else { return "\(done) of \(total)" }
        return "\(done.dropLast(unit.count + 1)) of \(total)"
    }

    private static func percent(_ facts: DownloadRowFacts) -> Int? {
        guard facts.totalBytes > 0 else { return nil }
        let fraction = Double(facts.bytesDownloaded) / Double(facts.totalBytes)
        return Int((min(max(fraction, 0), 1) * 100).rounded())
    }

    private static func sentence(_ reason: String) -> String {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return trimmed }
        return ".!?".contains(last) ? trimmed : trimmed + "."
    }

    private static func ordinal(_ value: Int, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .ordinal
        formatter.locale = locale
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

}
