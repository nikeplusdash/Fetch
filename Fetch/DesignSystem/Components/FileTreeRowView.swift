import SwiftUI
import FetchKit

/// Maps a file extension to an SF Symbol for the picker's `OutlineGroup`
/// rows (§12.2, "type icon by UTI from extension"). Purely presentational —
/// deliberately separate from `SmartFileSelection`'s video-extension set,
/// which is selection logic, not an icon lookup.
enum FileIconKind {
    static func symbolName(forFileNamed name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "mp4", "mkv", "avi", "mov", "wmv", "flv", "webm", "m4v",
             "mpg", "mpeg", "m2ts", "ts", "vob", "3gp", "ogv", "m2v", "divx":
            "film"
        case "mp3", "flac", "aac", "wav", "m4a", "ogg", "opus":
            "music.note"
        case "srt", "sub", "ass", "vtt":
            "captions.bubble"
        case "zip", "rar", "7z", "tar", "gz":
            "archivebox"
        case "jpg", "jpeg", "png", "gif", "webp", "bmp", "heic":
            "photo"
        case "nfo", "txt", "md":
            "doc.text"
        default:
            "doc"
        }
    }
}

/// One row of the file-picker's hierarchical `OutlineGroup` (§12.2):
/// tri-state checkbox, type icon, name, size.
struct FileTreeRowView: View {
    let node: FileTreeNode
    /// `true`/`false` fully (un)checked, `nil` = mixed (some but not all
    /// descendants selected) — only meaningful for folder rows.
    let checkState: Bool?
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: Spacing.s8) {
            Button(action: onToggle) {
                Image(systemName: checkboxSymbol)
                    .foregroundStyle(checkState == false ? Palette.textTertiary : Palette.accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(checkState == true ? "checked" : checkState == nil ? "partially checked" : "unchecked")

            Image(systemName: iconName)
                .foregroundStyle(Palette.textSecondary)
                .frame(width: IconSize.lg)

            Text(node.name)
                .font(FetchFont.body)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: Spacing.s8)

            Text(ByteCount.format(node.size))
                .font(FetchFont.footnoteMono)
                .foregroundStyle(Palette.textSecondary)
        }
        .frame(height: RowHeight.compact)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        // The tree is a flattened `LazyVStack`, not a `List`, so it draws no
        // separator of its own — `Palette.borderGrid` is lighter than
        // `Palette.separator` because these subdivide a tree rather than
        // divide unrelated sections.
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.borderGrid).frame(height: 1)
        }
    }

    private var checkboxSymbol: String {
        switch checkState {
        case true: "checkmark.square.fill"
        case false: "square"
        case nil: "minus.square.fill"
        }
    }

    private var iconName: String {
        switch node.kind {
        case .folder: "folder"
        case .file(let file): FileIconKind.symbolName(forFileNamed: file.name)
        }
    }
}
