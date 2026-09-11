import SwiftUI
import FetchKit

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

/**
 One row of the file picker, on the app's file grid (`TableColumns.files`),
 which is the same grid an expanded torrent's files are drawn on.

 **This is the left-alignment fix.** The row used to be a depth-dependent
 stack: one guide rule per level, then a chevron *or* a spacer, then a nested
 `HStack` holding the checkbox and everything after it. Every part of the row
 therefore moved when the depth changed, so a file's checkbox sat under its
 sibling folder's name and the size column landed at a different offset on
 every level — a list of columns with no columns in it.

 Depth is now an indent inside **the name cell alone**, where the disclosure
 chevron lives with the name it opens. The checkbox, the type glyph and the
 size column of every row sit in the same place whatever the depth, because
 they are the columns of one set rather than the contents of one stack.

 The picker has no use for the percent a download reports or for a per-file
 play button, so it drops those two columns as a value rather than drawing
 them empty.
 */
struct FileTreeRowView: View {
    let node: FileTreeNode
    let depth: Int
    let width: CGFloat
    let checkState: CheckState
    var isExpanded: Bool?
    var onToggleExpanded: (() -> Void)?
    let onToggle: () -> Void

    static let indent: CGFloat = IconSize.lg

    private var columns: ColumnSet<FileColumn> {
        TableColumns.files.without(.percent).without(.control)
    }

    var body: some View {
        ColumnRow(set: columns, width: width) { spec in
            switch spec.id {
            case .checkbox:
                Checkbox(state: checkState, onToggle: onToggle)
            case .glyph:
                Image(systemName: iconName)
                    .foregroundStyle(Palette.textTertiary)
            case .name:
                HStack(spacing: Spacing.s4) {
                    disclosure
                        .frame(width: IconSize.lg)
                    Text(node.name)
                        .font(FetchFont.body)
                        .fontWeight(checkState == .off ? .regular : .medium)
                        .foregroundStyle(checkState == .off
                                         ? Palette.textSecondary : Palette.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.leading, CGFloat(depth) * Self.indent)
            case .size:
                Text(ByteCount.format(node.size))
                    .font(FetchFont.calloutMono)
                    .foregroundStyle(Palette.textTertiary)
            case .percent, .control:
                Color.clear
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.borderGrid).frame(height: 1)
        }
    }

    @ViewBuilder
    private var disclosure: some View {
        if let isExpanded, let onToggleExpanded {
            Button(action: onToggleExpanded) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: IconSize.xs, weight: .semibold))
                    .foregroundStyle(Palette.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "collapse" : "expand")
        } else {
            Color.clear.frame(height: 1)
        }
    }

    private var iconName: String {
        switch node.kind {
        case .folder: "folder"
        case .file(let file): FileIconKind.symbolName(forFileNamed: file.name)
        }
    }
}
