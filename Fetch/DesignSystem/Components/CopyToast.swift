import SwiftUI

/// A one-line confirmation that fades out on its own.
///
/// **Copying gave no sign it had happened.** The link button put a magnet on
/// the pasteboard and changed nothing on screen, so the only way to find out
/// whether the click had registered was to go and paste it somewhere. That is
/// the whole class of action this exists for: instantaneous, invisible, and
/// with nothing to undo.
///
/// **Deliberately not `ErrorPanel`.** That is one sentence with an action and a
/// six-second life, for things that went wrong and may need a decision. This is
/// an acknowledgement — no button, no dismiss, gone before it is in the way —
/// and mixing the two would mean a successful copy and a failed search wearing
/// the same clothes.
@MainActor
@Observable
final class CopyToast {
    /// Long enough to notice out of the corner of an eye, short enough not to
    /// be something you wait out.
    private static let life = Duration.seconds(1.6)

    private(set) var message: String?

    @ObservationIgnored private var dismissal: Task<Void, Never>?

    /// Newest wins, like the error panel: copying twice in a row should not
    /// queue two confirmations of a pasteboard that only holds one thing.
    func show(_ message: String) {
        dismissal?.cancel()
        self.message = message
        dismissal = Task { [weak self] in
            try? await Task.sleep(for: Self.life)
            guard !Task.isCancelled else { return }
            self?.message = nil
        }
    }
}

/// Renders whatever the toast is currently saying.
///
/// Refuses every hit test: it appears over the results list, unasked, and a
/// confirmation that swallows the click meant for the row underneath it would
/// be a worse bug than the one it fixes.
struct CopyToastOverlay: View {
    let toast: CopyToast

    var body: some View {
        if let message = toast.message {
            HStack(spacing: Spacing.s6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Palette.cached)
                Text(message)
                    .font(FetchFont.callout)
                    .foregroundStyle(Palette.textPrimary)
            }
            .padding(.horizontal, Spacing.s12)
            .padding(.vertical, Spacing.s8)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Palette.separator, lineWidth: 1))
            .shadow(radius: 8, y: 2)
            .padding(.bottom, Spacing.s24)
            .allowsHitTesting(false)
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
        }
    }
}
