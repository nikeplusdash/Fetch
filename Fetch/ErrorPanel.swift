import SwiftUI
import AppKit

/**
 The pop-up that floats over the window without being part of its layout.

 `InlineBannerView` was a row *in* the layout: a download failing while you
 were reading a list pushed the whole screen down, and two of them stacked
 pushed it twice.

 The first replacement went too far the other way — an `NSPanel` tucked under
 the window's bottom edge, genuinely outside its frame. That did guarantee it
 could never move anything, and it read as a separate window sitting on the
 desktop rather than as this app saying something. An overlay is the same
 guarantee by a different route: an overlay takes part in no layout at all,
 so nothing above it can be pushed, and it is unmistakably inside the window
 it belongs to.

 It holds one sentence and at most one action, and it leaves on a click, on
 the cross, or after six seconds.

 **What does not become one of these.** A failed download explains itself in
 its own sub-line, because the row is still there to be looked at. A missing
 debrid key is the full-screen empty state, because the screen has nothing
 else to show. This is for the third case only: something that happened while
 the user was looking somewhere else, which will never be discovered unless it
 is said once.
 */
@MainActor
@Observable
final class ErrorPanel: ErrorPresenter {
    static let maxWidth: CGFloat = 460
    private static let dismissAfter = Duration.seconds(6)

    private(set) var current: AppAlert?

    @ObservationIgnored private var dismissal: Task<Void, Never>?

    func present(_ alert: AppAlert) {
        dismissal?.cancel()
        current = alert

        dismissal = Task { [weak self] in
            try? await Task.sleep(for: Self.dismissAfter)
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    func dismiss() {
        dismissal?.cancel()
        dismissal = nil
        current = nil
    }
}

/**
 Where the pop-up sits: bottom of the window, over everything, in no layout.
 */
struct ErrorPanelOverlay: View {
    let panel: ErrorPanel

    var body: some View {
        if let alert = panel.current {
            ErrorPanelContent(alert: alert, dismiss: panel.dismiss)
                .frame(maxWidth: ErrorPanel.maxWidth)
                .padding(Spacing.s16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

private struct ErrorPanelContent: View {
    let alert: AppAlert
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: Spacing.s10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: IconSize.lg))
                .foregroundStyle(Palette.miss)

            Text(alert.message)
                .font(FetchFont.callout)
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let title = alert.actionTitle, let action = alert.action {
                Button(title) {
                    action()
                    dismiss()
                }
                .buttonStyle(.borderless)
                .font(FetchFont.callout)
            }

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: IconSize.xs, weight: .semibold))
                    .foregroundStyle(Palette.textTertiary)
                    .frame(width: IconSize.lg, height: IconSize.lg)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, Spacing.s12)
        .padding(.vertical, Spacing.s10)
        .background(Palette.contentBackground)
        .overlay(
            RoundedRectangle(cornerRadius: Radius.r10)
                .strokeBorder(Palette.separator, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Radius.r10))
        .shadow(color: .black.opacity(0.22), radius: 18, y: 6)
        .contentShape(Rectangle())
        .onTapGesture(perform: dismiss)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isStaticText)
    }
}

private struct ErrorPresenterKey: EnvironmentKey {
    nonisolated(unsafe) static let defaultValue: (any ErrorPresenter)? = nil
}

extension EnvironmentValues {
    var errorPresenter: (any ErrorPresenter)? {
        get { self[ErrorPresenterKey.self] }
        set { self[ErrorPresenterKey.self] = newValue }
    }
}
