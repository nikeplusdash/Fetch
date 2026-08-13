import SwiftUI
import FetchKit

/// Whether a result starts downloading the moment you ask for it.
///
/// Replaces the cache-only badge, which could only answer for torrents — so a
/// Gutenberg book and an Archive.org file, the two things in the list that
/// genuinely download instantly and need no account at all, showed nothing.
///
/// The glyph carries the state, not just the colour: `CacheBadgeView` made the
/// same choice for the same reason, and the two now agree because they answer
/// the same question.
struct ReadinessBadgeView: View {
    let readiness: ResultReadiness
    var isOnFill: Bool = false
    /// Only a torrent can be re-checked; a public file has nothing to ask.
    var onRetry: (() -> Void)?

    var body: some View {
        Group {
            switch readiness {
            case .checking:
                ProgressView().controlSize(.small).scaleEffect(0.6)
            case .unknown where onRetry != nil:
                Button(action: { onRetry?() }) { symbol }.buttonStyle(.plain)
            default:
                symbol
            }
        }
        .help(explanation)
        .accessibilityLabel(explanation)
    }

    private var symbol: some View {
        Image(systemName: name)
            .font(.system(size: IconSize.lg, weight: .medium))
            .foregroundStyle(isOnFill ? Palette.statusOnFill : tint)
    }

    private var name: String {
        switch readiness {
        case .direct: "arrow.down.circle.fill"
        case .needsFetching: "clock.arrow.circlepath"
        case .checking: "circle.dotted"
        case .unknown: "questionmark.circle"
        }
    }

    private var tint: Color {
        switch readiness {
        case .direct: Palette.cached
        case .needsFetching: Palette.attention
        case .checking, .unknown: Palette.textTertiary
        }
    }

    private var explanation: String {
        switch readiness {
        case .direct: "Downloads straight away"
        case .needsFetching: "Your debrid has to fetch this first, which can take a while"
        case .checking: "Checking whether this is ready"
        case .unknown: "Not known yet — click to check again"
        }
    }
}
