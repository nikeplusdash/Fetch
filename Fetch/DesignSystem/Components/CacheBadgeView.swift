import SwiftUI
import FetchKit

/// The search results table's cache-status glyph (design spec §12.1). Every
/// state pairs a colour with a distinct SF Symbol *and* a VoiceOver label —
/// colour is never the only signal, since ~8% of men have some form of
/// colour-vision deficiency and green-vs-red is exactly the failing pair.
/// Uses `Palette.cached/miss/attention/unknown` — `attention` is orange, not
/// yellow, because `systemYellow` measures ≈1.4:1 against white and fails
/// WCAG 1.4.11 (design system spec §3.3).
struct CacheBadgeView: View {
    let state: CacheCheckState
    /// True when this badge sits on a filled/selected background — a
    /// selected result row, say. `Palette.cached` green (and the other
    /// status colours) fail contrast on `Palette.bgSelected` blue, so the
    /// glyph switches to `Palette.statusOnFill` instead of its semantic
    /// colour rather than staying illegible.
    var isOnFill: Bool = false
    /// Only consulted for `.error` — clicking an error badge retries that
    /// hash's check (§12.1).
    var onRetry: (() -> Void)?

    var body: some View {
        switch state {
        case .unchecked:
            glyph(symbol: "questionmark", color: tint(Palette.unknown))
                .accessibilityLabel("cache status unknown")
        case .checking:
            ProgressView()
                .controlSize(.mini)
                .frame(width: IconSize.lg, height: IconSize.lg)
                .accessibilityLabel("checking cache")
        case .cached:
            glyph(symbol: "checkmark", color: tint(Palette.cached))
                .accessibilityLabel("cached, ready to download")
        case .notCached:
            glyph(symbol: "arrow.down.circle", color: tint(Palette.miss))
                .accessibilityLabel("not cached, can be prepared")
        case .error:
            Button {
                onRetry?()
            } label: {
                glyph(symbol: "exclamationmark", color: tint(Palette.attention))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("cache check failed, click to retry")
        }
    }

    private func tint(_ semantic: Color) -> Color {
        isOnFill ? Palette.statusOnFill : semantic
    }

    private func glyph(symbol: String, color: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: IconSize.sm, weight: .bold))
            .foregroundStyle(color)
            .frame(width: IconSize.lg, height: IconSize.lg)
    }
}
