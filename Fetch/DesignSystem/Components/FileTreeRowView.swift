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

/// One row of the file picker, as **one grid**: disclosure gutter, checkbox,
/// type glyph, name, size.
///
/// **This is the left-alignment fix.** The row used to be a depth-dependent
/// stack: one guide rule per level, then a chevron *or* a spacer, then a nested
/// `HStack` holding the checkbox and everything after it. Every part of the row
/// therefore moved when the depth changed, so a file's checkbox sat under its
/// sibling folder's name and the size column landed at a different offset on
/// every level — a list of columns with no columns in it.
///
/// Depth is now a fixed indent applied to **the disclosure gutter alone**. The
/// checkbox, the glyph and the name of every row at the same level line up
/// exactly, and the size column is one column down the whole sheet.
struct FileTreeRowView: View {
    let node: FileTreeNode
    /// How far under the top level this row sits. Only the gutter reads it.
    let depth: Int
    /// `true`/`false` fully (un)checked, `nil` = mixed (some but not all
    /// descendants selected) — only meaningful for folder rows.
    let checkState: Bool?
    /// Nil for a file, which has nothing to open.
    var isExpanded: Bool?
    var onToggleExpanded: (() -> Void)?
    let onToggle: () -> Void

    /// One level of depth, on the gutter only.
    static let indent: CGFloat = IconSize.lg

    var body: some View {
        HStack(spacing: Spacing.s8) {
            disclosure
                .frame(width: IconSize.lg)
                .padding(.leading, CGFloat(depth) * Self.indent)

            Button(action: onToggle) {
                Image(systemName: checkboxSymbol)
                    .foregroundStyle(checkState == false ? Palette.textTertiary : Palette.accent)
            }
            .buttonStyle(.plain)
            .frame(width: IconSize.lg)
            .accessibilityLabel(checkState == true ? "checked"
                                : checkState == nil ? "partially checked" : "unchecked")

            Image(systemName: iconName)
                .foregroundStyle(Palette.textTertiary)
                .frame(width: IconSize.lg)

            Text(node.name)
                .font(FetchFont.body)
                .fontWeight(checkState == false ? .regular : .medium)
                .foregroundStyle(checkState == false ? Palette.textSecondary : Palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(ByteCount.format(node.size))
                .font(FetchFont.calloutMono)
                .foregroundStyle(Palette.textTertiary)
                .frame(width: ColumnWidth.fileSize, alignment: .trailing)
        }
        .padding(.horizontal, WindowMetrics.sheetInset)
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

    /// The gutter. A folder's chevron, or nothing — and either way the same
    /// width, which is what stops a folder's name starting at a different
    /// offset from a file's.
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
