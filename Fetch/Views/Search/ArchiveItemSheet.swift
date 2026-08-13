import SwiftUI
import FetchKit
import FetchPluginAPI

/// The picker for an Internet Archive item (amendment §6.2).
///
/// Separate from `FilePickerSheet` rather than a branch inside it, because
/// almost nothing is shared: there is no cache badge to resolve, no magnet to
/// submit, no debrid to route to, and no "prepare and wait" state. What is
/// left is a file list and a Download button — and building that as a second
/// small view is honest about how much simpler the direct path is.
///
/// An IA item is a *folder*, which is the same shape as a torrent, so §12.2's
/// selection idea carries over: never download eleven derived formats of one
/// book when the user wanted the EPUB.
struct ArchiveItemSheet: View {
    let result: SearchResult

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private enum Phase {
        case loading
        case picking([InternetArchiveProvider.ItemFile])
        case empty
        case error(String)
    }

    @State private var phase: Phase = .loading
    @State private var selected: Set<String> = []
    /// Narrows a long list by name. An IA collection can hold thousands of
    /// files — 2,398 in the one that exposed this — and scrolling to find one
    /// episode is not a workable picker.
    @State private var filterText = ""
    /// Archive.org generates an h.264 `.mp4` beside many uploads. Off by
    /// default so a picker is not every episode twice; available because that
    /// mp4 is often the copy that actually plays.
    ///
    /// Seeded from Settings § Sources rather than hardcoded, so the
    /// preference is a preference. Still per-item after that.
    @State private var showsDerived: Bool?
    @State private var expanded: Set<String> = []
    @State private var isSubmitting = false
    /// Present only when the item has one. Fetching it is plain HTTPS to
    /// archive.org — no DHT, no peers, no announce.
    @State private var torrentURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 560, height: 420)
        .task { await load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.s2) {
            Text(result.title)
                .font(FetchFont.title3)
                // Three, and wrapping rather than truncating. This is the one
                // place with room to say the whole name, and a release name
                // cut off at two lines in the header of the sheet you opened
                // *to identify it* is the wrong economy. Three is the ceiling
                // because a fourth starts eating the file list below.
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack(spacing: Spacing.s6) {
                Label("No debrid needed", systemImage: "bolt.circle.fill")
                    .foregroundStyle(Palette.cached)
                Text("· Internet Archive")
                if let creator = result.rawAttributes["creator"] {
                    Text("· \(creator)").lineLimit(1)
                }
            }
            .font(FetchFont.callout)
            .foregroundStyle(Palette.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.s16)
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            centred { ProgressView("Loading files…") }
        case .empty:
            centred {
                Text("This item has no downloadable files.")
                    .foregroundStyle(Palette.textSecondary)
            }
        case .error(let message):
            centred {
                VStack(spacing: Spacing.s8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Palette.attention)
                    Text(message)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Palette.textSecondary)
                }
                .padding(Spacing.s16)
            }
        case .picking(let files):
            let shown = Self.matching(
                (showsDerived ?? false) ? files : files.filter { !$0.isDerived }, filterText)
            let tree = FileTree.build(from: shown.map(Self.asDebridFile))
            VStack(spacing: 0) {
                toolbar(files: files, shown: shown)
                Divider()
                if tree.isEmpty {
                    centred {
                        Text("No files match “\(filterText)”.")
                            .foregroundStyle(Palette.textSecondary)
                    }
                } else {
                    ScrollView {
                        // An IA collection is the season-pack case one order
                        // of magnitude further along — 1,786 episodes across
                        // several shows — so it needs a real tree.
                        FileTreeOutlineView(
                            nodes: tree,
                            checkState: {
                                FileTreeSelection.checkState(for: $0, selected: selected)
                            },
                            onToggle: { selected = FileTreeSelection.toggling($0, in: selected) },
                            expanded: $expanded)
                            .padding(.horizontal, Spacing.s12)
                    }
                }
            }
        }
    }

    private func toolbar(
        files: [InternetArchiveProvider.ItemFile],
        shown: [InternetArchiveProvider.ItemFile]
    ) -> some View {
        HStack(spacing: Spacing.s8) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundStyle(Palette.textTertiary)
            // Filtering narrows what All/None act on, which is how "select
            // all of Season 2" becomes two actions instead of forty.
            TextField("Filter files…", text: $filterText)
                .textFieldStyle(.plain)
            if shown.count != files.count {
                Text("\(shown.count) of \(files.count)")
                    .font(FetchFont.caption2)
                    .foregroundStyle(Palette.textTertiary)
            }
            Button("All") { selected.formUnion(shown.map(\.name)) }
                .disabled(shown.isEmpty)
            Button("None") { shown.forEach { selected.remove($0.name) } }
                .disabled(shown.isEmpty)
            Toggle("Derived", isOn: Binding(
                get: { showsDerived ?? false },
                set: { showsDerived = $0 }))
                .toggleStyle(.checkbox)
                .help("Archive.org generates extra formats from each upload — "
                      + "usually an .mp4 beside the original. Off by default so "
                      + "the list is not every file twice.")
        }
        .font(FetchFont.callout)
        .padding(.horizontal, Spacing.s12)
        .padding(.vertical, Spacing.s8)
    }

    /// `FileTree` groups on `DebridFile.name` being a full relative path,
    /// which is exactly what an IA file name is. Mapping across means the tree
    /// building, the row view, and the tri-state selection are all shared
    /// rather than reimplemented for this sheet.
    static func asDebridFile(_ file: InternetArchiveProvider.ItemFile) -> DebridFile {
        DebridFile(
            id: DebridFileID(rawValue: file.url.absoluteString),
            name: file.name,
            shortName: (file.name as NSString).lastPathComponent,
            // 0 means "not declared" throughout the download layer, and the
            // folder-size sums read this — so an unknown file contributes
            // nothing rather than a wrong number.
            size: file.size ?? 0,
            mimeType: nil)
    }

    /// Case-insensitive substring over the whole relative path, so "S01E04"
    /// and "Season 01" both work.
    static func matching(
        _ files: [InternetArchiveProvider.ItemFile], _ text: String
    ) -> [InternetArchiveProvider.ItemFile] {
        let needle = text.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return files }
        return files.filter { $0.name.localizedCaseInsensitiveContains(needle) }
    }

    private var footer: some View {
        HStack(spacing: Spacing.s8) {
            if torrentURL != nil {
                Label("Also available as a torrent", systemImage: "link")
                    .font(FetchFont.footnote)
                    .foregroundStyle(Palette.textTertiary)
                    .help("Archive.org publishes a .torrent for this item. Downloading "
                          + "it through a debrid is faster when one already holds it — "
                          + "that route is not wired up yet.")
            }
            if case .picking(let files) = phase {
                let chosen = files.filter { selected.contains($0.name) }
                let bytes = chosen.compactMap(\.size).reduce(0, +)
                Text("\(chosen.count) of \(files.count) selected"
                     + (bytes > 0 ? " · \(ByteCount.format(bytes))" : ""))
                    .font(FetchFont.footnote)
                    .foregroundStyle(Palette.textSecondary)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Download") { download() }
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty || isSubmitting)
        }
        .padding(Spacing.s16)
    }

    private func centred<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack { Spacer(); content(); Spacer() }
            .frame(maxWidth: .infinity)
    }

    // MARK: - Loading

    private func load() async {
        guard let identifier = result.rawAttributes["identifier"] else {
            phase = .error("This result is missing its Archive.org identifier.")
            return
        }
        let provider = InternetArchiveProvider(
            client: HTTPClient(allowedHosts: [InternetArchiveProvider.host]))
        do {
            let files = try await provider.files(inItem: identifier)
            guard !files.isEmpty else {
                phase = .empty
                return
            }
            // Ranked by the user's Quality › Books order, the same one the
            // Gutenberg sheet uses. This sheet used to hardcode its own, so
            // that preference silently did not apply to Archive.org items.
            selected = Set(ArchiveFileSelection.preselected(
                names: files.filter { !$0.isDerived }.map(\.name),
                formatOrder: model.qualityProfile.documentFormatOrder))
            if showsDerived == nil { showsDerived = model.archiveShowsDerivedByDefault }
            phase = .picking(files)
            // Top level open, deeper levels closed: a collection opens on its
            // shows rather than on nothing, without unrolling 1,786 episodes.
            expanded = Set(
                FileTree.build(from: files.map(Self.asDebridFile))
                    .filter(\.isFolder).map(\.id))


            // Best-effort and after the list, so a slow or missing torrent
            // never delays the files the user actually came for.
            torrentURL = try? await provider.torrentURL(forItem: identifier)
        } catch {
            phase = .error(String(describing: error))
        }
    }

    // MARK: - Actions

    private func download() {
        guard case .picking(let files) = phase else { return }
        isSubmitting = true
        let chosen = files.filter { selected.contains($0.name) }
        Task {
            // An item's files go inside a folder named after the item, the way
            // a torrent's do. Without it eight files from one item landed
            // loose in `Movies/` and the Downloads row read "8 files" — the
            // item's name is only recoverable from the path they share.
            let folder = result.title.isEmpty
                ? (result.rawAttributes["identifier"] ?? "")
                : result.title

            await model.enqueueDirect(
                chosen.map {
                    (name: ItemFolder.relativePath(folder: folder, file: $0.name),
                     size: $0.size, url: $0.url)
                },
                // The item, so its files share one row — the same job the
                // infohash does for a torrent.
                contentKey: result.rawAttributes["identifier"] ?? result.id.rawValue,
                groupName: folder,
                subfolder: model.subfolder(for: result.metadata),
                metadata: result.metadata)
            isSubmitting = false
            dismiss()
        }
    }
}
