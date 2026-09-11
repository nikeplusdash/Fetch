import SwiftUI
import UniformTypeIdentifiers
import FetchKit

struct WindowTorrentDrop: ViewModifier {
    let isEnabled: Bool
    @State private var hovering: DroppedItem?
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
            Text(detail)
                .font(FetchFont.callout)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, WindowMetrics.contentInset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .padding(Spacing.s6)
    }
}

private struct TorrentDropDelegate: DropDelegate {
    let isEnabled: Bool
    @Binding var hovering: DroppedItem?
    @Binding var refusing: Bool
    let onDrop: (DroppedItem) -> Void

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

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if hovering != nil { return DropProposal(operation: .copy) }
        return DropProposal(operation: refusing ? .cancel : .copy)
    }

    func dropExited(info: DropInfo) {
        hovering = nil
        refusing = false
    }

    func performDrop(info: DropInfo) -> Bool {
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
    func windowTorrentDrop(
        isEnabled: Bool = true, onDrop: @escaping (DroppedItem) -> Void
    ) -> some View {
        modifier(WindowTorrentDrop(isEnabled: isEnabled, onDrop: onDrop))
    }
}
