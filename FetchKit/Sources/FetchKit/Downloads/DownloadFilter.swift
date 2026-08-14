import Foundation

/// How the Downloads list is narrowed.
///
/// **Three pills, not eight.** The screen used to be two modes — a lifecycle
/// list and a shelf — and before that a four-case filter. Both were answering
/// the wrong question. There is one list now, in the order things arrived, and
/// these narrow it without ever re-sorting it.
///
/// Here rather than in the view because the view has no test bundle, and
/// because "which states count as failed" is exactly the kind of decision that
/// silently drifts when it lives in a `switch` inside a `ForEach`.
public enum DownloadFilter: String, CaseIterable, Sendable, Identifiable {
    /// Everything that has not landed: running, waiting, and the three ways a
    /// download ends without a file.
    ///
    /// **Two pills, not three.** Failed was its own, which made the row of
    /// pills a lifecycle diagram — and the question people arrive with is not
    /// "which stage is this at" but "is it still going, and did any of it go
    /// wrong", which is one list. A failure is not a category of thing to
    /// browse; it is something in the way of what you asked for, and it belongs
    /// beside the work it interrupted. Clear is offered here for exactly that
    /// reason.
    case downloads
    /// `completed` only. What landed.
    case library

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .downloads: "Downloads"
        case .library: "Library"
        }
    }

    public func accepts(_ state: DownloadState) -> Bool {
        switch self {
        case .downloads: state != .completed
        case .library: state == .completed
        }
    }

    /// The three ways a download ends with no file to show for it.
    ///
    /// They keep separate glyphs because they are separate things — a failure
    /// can be resumed, a missing file is a new decision, a cancellation was
    /// deliberate — but Clear acts on all three, because "get these out of my
    /// way" does not distinguish between them.
    public static func isClearable(_ state: DownloadState) -> Bool {
        state == .failed || state == .missing || state == .cancelled
    }

    /// The category row appears under exactly one of these.
    public var showsCategories: Bool { self == .library }
}
