import SwiftUI

/// Non-blocking partial-failure banner ("2 of 5 indexers failed", design
/// spec §7/§12.1). Content-layer chrome — standard materials and system
/// colours only, never Liquid Glass (design system spec §2).
struct InlineBannerView: View {
    /// Defaults to `.info`, and `.info` renders exactly as this banner did
    /// before `Severity` existed — `exclamationmark.triangle.fill` on
    /// `Palette.attention` — so the two existing call sites (a missing-
    /// provider notice and a partial-indexer-failure notice, neither
    /// touched by the task that added this enum) are visually unchanged.
    /// `.warning` and `.error` are the new appearances; each still pairs a
    /// colour with a symbol distinct from `.info`'s, never colour alone
    /// (design system spec rule 2).
    enum Severity { case info, warning, error }

    let message: String
    var severity: Severity = .info
    var onRetry: (() -> Void)?
    /// Names the action button. Defaults to Retry, which is right for the
    /// partial-failure case but not for banners whose fix is elsewhere.
    var retryTitle: String = "Retry"
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: Spacing.s8) {
            Image(systemName: symbolName)
                .foregroundStyle(tint)
            Text(message)
                .font(FetchFont.callout)
                .foregroundStyle(Palette.textPrimary)
            Spacer()
            if let onRetry {
                Button(retryTitle, action: onRetry)
                    .buttonStyle(.borderless)
                    .font(FetchFont.callout)
            }
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, Spacing.s12)
        .padding(.vertical, Spacing.s8)
        // A floating card, in the system's own material rather than a flat
        // fill: this sits over arbitrary content and a solid rectangle reads
        // as a slab dropped on it. `.regularMaterial` is what every macOS
        // popover and notification uses, and it tracks light and dark for
        // free.
        //
        // The rule that used to run along the bottom went with it. It was
        // there because this was a *row* of the layout and needed to separate
        // itself from the content below; floating, it separated nothing and
        // read as an unfinished edge.
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.r12))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.r12)
                .strokeBorder(Palette.separator.opacity(0.6), lineWidth: 1))
        .shadow(color: .black.opacity(0.22), radius: 14, y: 6)
        .frame(maxWidth: 620)
    }

    private var symbolName: String {
        switch severity {
        case .info: "exclamationmark.triangle.fill"
        case .warning: "exclamationmark.circle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private var tint: Color {
        switch severity {
        case .info: Palette.attention
        case .warning: Palette.attention
        case .error: Palette.miss
        }
    }
}
