import SwiftUI
import FetchKit

struct StateLabel: View {
    let state: DownloadState

    private var symbol: String {
        switch state {
        case .queued: "clock"
        case .preparing: "hourglass"
        case .downloading: "arrow.down.circle"
        case .paused: "pause.circle"
        case .completed: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        case .cancelled: "xmark.circle"
        // Not a warning triangle: the download did its job, and the file left
        // afterwards. The empty slot says "was here, isn't now".
        case .missing: "questionmark.folder"
        }
    }

    private var tint: Color {
        switch state {
        case .completed: Palette.cached
        case .failed: Palette.miss
        case .paused, .preparing, .missing: Palette.attention
        case .queued, .cancelled: Palette.unknown
        case .downloading: Palette.accent
        }
    }

    private var title: String {
        switch state {
        case .queued: "Queued"
        case .preparing: "Preparing"
        case .downloading: "Downloading"
        case .paused: "Paused"
        case .completed: "Completed"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        case .missing: "Missing"
        }
    }

    /// Said in the tooltip, because "Missing" alone reads as an error Fetch
    /// made rather than a file that is no longer on disk.
    private var explanation: String? {
        state == .missing
            ? "Downloaded, but the file is no longer where Fetch saved it."
            : nil
    }

    var body: some View {
        Label(title, systemImage: symbol)
            .font(FetchFont.callout)
            .foregroundStyle(tint)
            .labelStyle(.titleAndIcon)
            .accessibilityLabel(explanation ?? title)
            .help(explanation ?? title)
    }
}
