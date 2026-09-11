import SwiftUI
import FetchKit

/**
 A download's state, as a glyph and nothing else.

 **The word is gone from the row.** `StateLabel` drew an icon and a word
 together in a 92-point column, so a list of nine downloads carried nine
 repetitions of the same eight strings — and on a screen whose title column
 was the thing being squeezed. The word survives where a word is actually
 useful: the tooltip, and the accessibility label, which is the only place it
 was ever load-bearing.

 Colour separates four groups rather than eight states: green for landed,
 accent for moving, amber for needs-you, grey for neither. Eight tints would
 be a legend to memorise; four are a thing you learn once.
 */
struct StateGlyph: View {
    let state: DownloadState

    var body: some View {
        Image(systemName: Self.symbol(for: state))
            .font(.system(size: IconSize.lg))
            .foregroundStyle(Self.tint(for: state))
            .frame(width: Self.side, height: Self.side)
            .accessibilityLabel(Self.explanation(for: state) ?? Self.title(for: state))
            .help(Self.explanation(for: state) ?? Self.title(for: state))
    }

    private static let side = TableColumns.downloads.width(of: .status) ?? RowHeight.compact


    static func symbol(for state: DownloadState) -> String {
        switch state {
        case .queued: "clock"
        case .preparing: "hourglass"
        case .downloading: "arrow.down.circle"
        case .paused: "pause.circle"
        case .completed: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        case .cancelled: "xmark.circle"
        case .missing: "questionmark.folder"
        case .cloudQueued: "cloud.fill"
        case .onCloud: "cloud"
        }
    }

    static func tint(for state: DownloadState) -> Color {
        switch state {
        case .completed: Palette.cached
        case .downloading: Palette.inProgress
        case .paused, .preparing, .missing: Palette.attention
        case .failed: Palette.miss
        case .queued, .cancelled: Palette.unknown
        case .cloudQueued: Palette.inProgress
        case .onCloud: Palette.cached
        }
    }

    static func title(for state: DownloadState) -> String {
        switch state {
        case .queued: "Queued"
        case .preparing: "Preparing"
        case .downloading: "Downloading"
        case .paused: "Paused"
        case .completed: "Completed"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        case .missing: "Missing"
        case .cloudQueued: "Fetching to your cloud"
        case .onCloud: "On your cloud"
        }
    }

    static func explanation(for state: DownloadState) -> String? {
        switch state {
        case .missing: "Downloaded. The file is no longer where Fetch saved it."
        case .preparing: "The service is fetching it. Nothing is arriving here yet."
        default: nil
        }
    }
}
