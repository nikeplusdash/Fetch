import SwiftUI
import UniformTypeIdentifiers
import FetchKit

/// Dropping a torrent anywhere on the window, on any screen.
///
/// **The overlay covers the window, not a target inside it.** A drop zone you
/// have to find is a drop zone you miss. The whole window accepts, so the
/// highlight is the whole window, inset far enough that the rounded corner
/// still reads.
///
/// **A non-torrent never lights it.** The rule lived in `DownloadsView`'s drop
/// handler, where it was reachable on one screen only; it is
/// `DroppedItem.first(in:)` now, which is tested. Nothing opens on nothing.
struct WindowTorrentDrop: ViewModifier {
    /// False on Settings, where a dropped torrent would have nowhere to go.
    let isEnabled: Bool
    /// What is being dragged over the window right now, once it has been read
    /// far enough to name it. Nil for a drag Fetch will not take.
    @State private var hovering: DroppedItem?
    /// A drag carrying URLs that Fetch cannot use — a folder, a photo, a page
    /// that is not a link to anything downloadable.
    ///
    /// **It lights the window too, in a different colour.** The original rule
    /// was that a non-torrent never lights it, which is tidy and taught three
    /// separate rounds of "drag and drop is broken": a refusal that looks
    /// exactly like nothing happening is indistinguishable from a bug. Saying
    /// what Fetch takes, once, at the moment someone is trying to give it
    /// something else, is the cheapest possible time to say it.
    @State private var refusing = false
    let onDrop: (DroppedItem) -> Void

    func body(content: Content) -> some View {
        content
            .overlay {
                if let hovering {
                    overlay(
                        title: hovering.isDirectlyDownloadable
                            ? "Drop to check and download"
                            : "Drop to open in Add Link",
                        detail: hovering.displayName,
                        tint: Palette.accent)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                } else if refusing {
                    overlay(
                        title: "Fetch cannot take that",
                        detail: "Drop a .torrent file, a magnet link, or a web address.",
                        tint: Palette.attention)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            .animation(.snappy(duration: 0.18), value: hovering)
            .animation(.snappy(duration: 0.18), value: refusing)
            .onDrop(
                of: [.fileURL, .url],
                delegate: TorrentDropDelegate(
                    isEnabled: isEnabled, hovering: $hovering,
                    refusing: $refusing, onDrop: onDrop))
    }

    private func overlay(title: String, detail: String, tint: Color) -> some View {
        VStack(spacing: Spacing.s8) {
            Image(systemName: tint == Palette.attention
                  ? "exclamationmark.circle" : "arrow.down.circle")
                .font(FetchFont.largeTitle)
                .foregroundStyle(tint)
            Text(title)
                .font(FetchFont.sheetTitle)
                .foregroundStyle(Palette.textPrimary)
            // It names the file it is about to take: dragging three things and
            // getting one download is confusing after the fact and obvious
            // before it.
            Text(detail)
                .font(FetchFont.callout)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, WindowMetrics.contentInset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // **The window's own surface, not a coloured wash.** A flat tint over
        // the content read as a rectangle painted on top of the app; the point
        // of the overlay is that the *window* is the target, so it should look
        // like the window has changed state. Glass frosts what is underneath,
        // Blizzard and Midnight are opaque and cannot, so each gets the surface
        // it is made of and the tint is left to the border and the glyph.
        .background {
            if ActiveTheme.shared.isTranslucent {
                Rectangle().fill(.ultraThinMaterial)
            } else {
                Rectangle().fill(Palette.contentBackground.opacity(0.92))
            }
        }
        .background(tint.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: Radius.r10))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.r10)
                .strokeBorder(
                    tint,
                    style: StrokeStyle(lineWidth: 2, dash: [Spacing.s6, Spacing.s4]))
        }
        // Inside the window's own rounded corner rather than flush to the
        // edge, so the highlight reads as *the window* being a target rather
        // than as a rectangle drawn over one.
        .padding(Spacing.s6)
    }
}

/// Reads the drag far enough to say what it is, before deciding to take it.
///
/// A `DropDelegate` rather than `.dropDestination(for: URL.self)`, because the
/// overlay has to name the file **while it is still being dragged** and
/// `dropDestination` only hands the payload over once it has been let go.
private struct TorrentDropDelegate: DropDelegate {
    let isEnabled: Bool
    @Binding var hovering: DroppedItem?
    @Binding var refusing: Bool
    let onDrop: (DroppedItem) -> Void

    /// **`DropInfo`, not the drag pasteboard.** This read
    /// `NSPasteboard(name: .drag)` because it is synchronous and the item
    /// providers are not — and it returned the *previous* drag's contents. A
    /// `.torrent` dragged from Downloads was refused while the log showed a
    /// folder dropped several minutes earlier: the global drag pasteboard is
    /// not guaranteed to be rewritten for every session, so what it holds is
    /// whatever was last put there rather than what is under the pointer.
    ///
    /// The providers are the drag's own data and cannot be stale. They cost a
    /// frame or two, which was the whole reason for the shortcut, and that cost
    /// is now affordable: the overlay has a refusing state, so arriving at the
    /// answer slightly late shows "checking" rather than a wrong answer.
    func validateDrop(info: DropInfo) -> Bool {
        guard isEnabled else { return false }
        return info.hasItemsConforming(to: Self.types)
    }

    func dropEntered(info: DropInfo) {
        guard isEnabled else { return }
        classify(info) { item in
            hovering = item
            refusing = item == nil
        }
    }

    /// The cursor, and the actual refusal. A drag Fetch cannot use gets
    /// `.cancel` however loudly the window is explaining itself, so it cannot
    /// be dropped and `performDrop` is never reached.
    ///
    /// `.copy` while the answer is still coming: refusing during that window
    /// would flicker the cursor on every drag, and `performDrop` re-reads
    /// anyway, so a drop that arrives early is still decided correctly.
    func dropUpdated(info: DropInfo) -> DropProposal? {
        if hovering != nil { return DropProposal(operation: .copy) }
        return DropProposal(operation: refusing ? .cancel : .copy)
    }

    func dropExited(info: DropInfo) {
        hovering = nil
        refusing = false
    }

    func performDrop(info: DropInfo) -> Bool {
        // Read again rather than trusting the hover: `dropEntered` does not
        // fire for a drag that begins already inside the window, which is what
        // dragging out of a Finder window overlapping this one does.
        classify(info) { item in
            hovering = nil
            refusing = false
            guard let item else {
                fetchLog(.warn, "drop", "performDrop found nothing")
                return
            }
            fetchLog(.info, "drop", "performDrop \(item.displayName)")
            onDrop(item)
        }
        return true
    }

    private static let types: [UTType] = [.fileURL, .url]

    /// Resolves the drag's URLs and hands back the first thing Fetch can use.
    ///
    /// Every provider is asked, and the *first usable* answer wins rather than
    /// the first to arrive — otherwise a mixed drop would be decided by which
    /// load finished first, which is not a decision anyone made.
    private func classify(_ info: DropInfo, then act: @escaping (DroppedItem?) -> Void) {
        let providers = info.itemProviders(for: Self.types)
        guard !providers.isEmpty else { return act(nil) }

        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                if let url = await Self.url(from: provider) { urls.append(url) }
            }
            let item = DroppedItem.first(in: urls)
            fetchLog(.info, "drop",
                     "urls=\(urls.map(\.absoluteString)) item=\(item?.displayName ?? "nil")")
            act(item)
        }
    }

    /// One provider's URL, however it chooses to represent it.
    ///
    /// A file dragged from Finder arrives as a `public.file-url` whose data is
    /// the URL's bytes; a link dragged from a browser arrives as `public.url`.
    /// Both are asked for, because a drag can be either and the caller does not
    /// know which until it looks.
    private static func url(from provider: NSItemProvider) async -> URL? {
        for type in types where provider.hasItemConformingToTypeIdentifier(type.identifier) {
            if let url = await withCheckedContinuation({ (continuation: CheckedContinuation<URL?, Never>) in
                provider.loadItem(forTypeIdentifier: type.identifier) { item, _ in
                    switch item {
                    case let url as URL: continuation.resume(returning: url)
                    case let data as Data:
                        continuation.resume(
                            returning: URL(dataRepresentation: data, relativeTo: nil))
                    case let string as String:
                        continuation.resume(returning: URL(string: string))
                    default: continuation.resume(returning: nil)
                    }
                }
            }) {
                return url
            }
        }
        return nil
    }
}

extension View {
    /// The window-wide torrent drop. One modifier, at the root.
    func windowTorrentDrop(
        isEnabled: Bool = true, onDrop: @escaping (DroppedItem) -> Void
    ) -> some View {
        modifier(WindowTorrentDrop(isEnabled: isEnabled, onDrop: onDrop))
    }
}
