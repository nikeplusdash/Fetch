import Foundation

/**
 How the Downloads list is narrowed.

 **Three pills, not eight.** The screen used to be two modes — a lifecycle
 list and a shelf — and before that a four-case filter. Both were answering
 the wrong question. There is one list now, in the order things arrived, and
 these narrow it without ever re-sorting it.

 Cloud is the odd one and stays odd on purpose: its rows are things held on
 a service, not `DownloadState` rows, so `accepts(_:)` is false for every
 state rather than pretending to narrow a list it has nothing to do with.

 Here rather than in the view because the view has no test bundle, and
 because "which states count as failed" is exactly the kind of decision that
 silently drifts when it lives in a `switch` inside a `ForEach`.
 */
public enum DownloadFilter: String, CaseIterable, Sendable, Identifiable {
    case downloads
    case library
    case cloud

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .downloads: "Downloads"
        case .library: "Library"
        case .cloud: "Cloud"
        }
    }

    public func accepts(_ state: DownloadState) -> Bool {
        switch self {
        case .downloads: state != .completed && state != .onCloud
        case .library: state == .completed || state == .onCloud
        case .cloud: false
        }
    }

    /**
     The three ways a download ends with no file to show for it.

     They keep separate glyphs because they are separate things — a failure
     can be resumed, a missing file is a new decision, a cancellation was
     deliberate — but Clear acts on all three, because "get these out of my
     way" does not distinguish between them.
     */
    public static func isClearable(_ state: DownloadState) -> Bool {
        state == .failed || state == .missing || state == .cancelled
    }

    /**
     The states a row can be stopped out of.

     Deliberately not `!state.isTerminal`, which would sweep `failed` in too:
     a failed row has already stopped, so offering to cancel it is offering
     to do nothing, and it is Clear's row to take.

     `.cloudQueued` is here because the service is doing something that can
     be called off, and calling it off deletes the account's copy — the row
     is that copy. `.onCloud` is not: nothing is in flight, and Remove is its
     only ending.
     */
    public static func isCancellable(_ state: DownloadState) -> Bool {
        state == .queued || state == .preparing
            || state == .downloading || state == .paused
            || state == .cloudQueued
    }

    public var showsCategories: Bool { self == .library || self == .cloud }
}
