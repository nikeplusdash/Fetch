import SwiftUI
import FetchKit

/// One torrent's header — disclosure, title, stats, progress and controls
/// (Figma `DownloadRow`), for `DownloadsView.TorrentRow`.
///
/// Fixed-width columns rather than one joined string.
///
/// The previous version built a `" · "` sentence from up to five parts in a
/// single unconstrained `Text`. Every part changes length as a download
/// progresses — bytes, rate, ETA — so the row reflowed on every progress
/// tick, ten times a second. `DownloadRow.swift` had solved this already
/// with pinned units and fixed column widths, and its comment says why;
/// that file was left unreferenced when this screen replaced it, so the
/// solution went out of sight along with it. `ColumnWidth.byteCount` /
/// `.rate` / `.eta` are sized for the longest realistic string at this font
/// and must not be made flexible.
struct DownloadRowView: View {
    @Environment(AppModel.self) private var model
    let group: AppModel.TorrentGroup
    let isExpanded: Bool
    /// Threaded down from the list's own selection, so a long torrent name
    /// reveals itself here the same way a search result's does. `List` paints
    /// selection by tag and tells the row nothing, so it has to be passed.
    var isSelected: Bool = false
    let onToggleExpanded: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s4) {
            HStack(spacing: Spacing.s8) {
                // Expandable when there is anything below to reveal — several
                // queued files, or files that were skipped.
                if group.items.count > 1 || !model.skippedFiles(for: group).isEmpty {
                    Button(action: onToggleExpanded) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Palette.textTertiary)
                            .frame(width: 12)
                    }
                    .buttonStyle(.plain)
                } else {
                    Spacer().frame(width: 12)
                }

                VStack(alignment: .leading, spacing: Spacing.s2) {
                    RevealingText(text: group.displayName, isRevealing: isSelected)
                    details
                }

                Spacer()
                controls
            }

            if let fraction = group.fraction, group.section == .active {
                ProgressTrack(fraction: fraction)
                    // Starts where the title starts, not at the row edge: a
                    // full-bleed bar under an indented title reads as
                    // belonging to the list rather than to this download.
                    .padding(.leading, Spacing.s20)
            }

            // Why it failed, on the row rather than only in a banner that
            // scrolls away. `DownloadError` is `LocalizedError` now, so this
            // is a sentence — it used to be "The operation couldn't be
            // completed. (FetchKit.DownloadError error 6.)", which named
            // neither the file nor the cause.
            if let reason = failureReason {
                Text(reason)
                    .font(FetchFont.footnote)
                    .foregroundStyle(Palette.miss)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, Spacing.s20)
                    .textSelection(.enabled)
            }
        }
        .contextMenu { rowMenu }
        // On the whole row: hovering the byte counts or the controls is still
        // hovering this download, and its name is what you wanted.
        .help(group.displayName)
    }

    /// The row's own menu. Everything here was previously reachable only by
    /// finding the release in Search again — a torrent already on a row knew
    /// its own contents the whole time (`torrentFiles`), and offered no way to
    /// act on the parts of it that were skipped or that failed.
    @ViewBuilder
    private var rowMenu: some View {
        let others = model.redownloadablePaths(for: group)
        if !others.isEmpty {
            Button("Download \(others.count) Other File\(others.count == 1 ? "" : "s")") {
                Task {
                    await model.redownload(paths: Set(others.map(\.path)), from: group)
                }
            }
        }
        if group.section == .completed {
            Button("Show in Finder") { model.revealInFinder(group) }
        }
        if model.canResume(group) {
            Button("Resume") { model.resumeTorrent(group) }
        }
        if group.section == .failed || group.section == .completed {
            Button("Remove Row") { model.removeTorrent(group) }
        }
    }

    /// The first distinct reason among this row's files. One torrent's files
    /// fail together and for the same reason far more often than not, and
    /// eighty copies of one sentence is not eighty times the information.
    private var failureReason: String? {
        guard group.section == .failed else { return nil }
        return group.items.compactMap(\.errorMessage).first
    }

    private var details: some View {
        HStack(spacing: Spacing.s8) {
            if group.items.count > 1 || skippedCount > 0 {
                Text(fileCountText)
                    .frame(width: ColumnWidth.state, alignment: .leading)
            }


            // Pinned to the group's own total, so crossing a unit boundary
            // mid-transfer cannot change the string's width.
            Text("\(ByteCount.format(group.bytesDownloaded, pinnedTo: group.pinnedUnit)) / "
                 + "\(ByteCount.format(group.totalBytes, pinnedTo: group.pinnedUnit))")
                .frame(width: ColumnWidth.byteCount, alignment: .leading)

            if group.section == .active {
                Text(group.bytesPerSecond > 0
                     ? "\(ByteCount.format(Int64(group.bytesPerSecond)))/s" : "")
                    .frame(width: ColumnWidth.rate, alignment: .leading)
                Text(group.etaText ?? "")
                    .frame(width: ColumnWidth.eta, alignment: .leading)
            }

            if group.queuedCount > 0, group.section == .active {
                Text("\(group.queuedCount) waiting for a free slot")
                    .foregroundStyle(Palette.textTertiary)
            }
            if let provider = group.items.compactMap({ model.providerForDownload[$0.id] }).first,
               model.providers.count > 1 {
                Text("via \(provider)")
                    .foregroundStyle(Palette.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .font(FetchFont.footnoteMono)
        .foregroundStyle(Palette.textSecondary)
        .lineLimit(1)
    }

    private var skippedCount: Int { model.skippedFiles(for: group).count }

    /// "1 file", never "1 files". The count column only appears above one
    /// file or alongside skipped ones, but a skipped-file row can still leave
    /// a single queued one.
    private var fileCountText: String {
        let queued = group.items.count
        let total = queued + skippedCount
        if skippedCount > 0 { return "\(queued) of \(total) files" }
        return queued == 1 ? "1 file" : "\(queued) files"
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: Spacing.s8) {
            if model.canPause(group) {
                Button { model.pauseTorrent(group) } label: { Image(systemName: "pause.fill") }
                    .buttonStyle(.borderless)
                    .help("Pause all files in this torrent")
            }
            if model.canResume(group) {
                Button { model.resumeTorrent(group) } label: { Image(systemName: "play.fill") }
                    .buttonStyle(.borderless)
                    .help("Resume all files in this torrent")
            }
            // Cancel is for work still in flight. A row in Failed has nothing
            // left to cancel — it needs removing, which is a different verb
            // and used to have no button at all.
            if group.section != .completed && group.section != .failed {
                Button { model.cancelTorrent(group) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Cancel this torrent")
            }
            if group.section == .completed {
                Button {
                    model.revealInFinder(group)
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Show in Finder")
            }
            if group.section == .failed || group.section == .completed {
                Button { model.removeTorrent(group) } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove this row. The downloaded file is not deleted.")
            }
        }
    }
}
