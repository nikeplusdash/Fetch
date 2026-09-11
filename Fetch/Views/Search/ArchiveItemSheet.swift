import SwiftUI
import FetchKit
import FetchPluginAPI

/**
 The picker for an Internet Archive item (amendment §6.2).

 Separate from `FilePickerSheet` rather than a branch inside it, because
 almost nothing is shared: there is no cache badge to resolve, no magnet to
 submit, no debrid to route to, and no "prepare and wait" state. What is
 left is a file list and a Download button — and building that as a second
 small view is honest about how much simpler the direct path is.

 An IA item is a *folder*, which is the same shape as a torrent, so §12.2's
 selection idea carries over: never download eleven derived formats of one
 book when the user wanted the EPUB.
 */
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
    @State private var filterText = ""
    @State private var showsDerived: Bool?
    @State private var expanded: Set<String> = []
    @State private var isSubmitting = false
    @State private var torrentURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ThemedDivider()
            content
            listFooter
            ThemedDivider()
            footer
        }
        .frame(width: 560, height: 420)
        .task { await load() }
        .onDisappear { model.forgetDestinationOverride(for: result) }
    }

    private var header: some View {
        SheetHeaderBlock(
            title: result.title,
            tag: TagPill(
                title: "Ready", tone: .ready,
                explanation: "Archive.org serves this over plain HTTPS. No debrid "
                    + "account is involved and nothing is queued.")
        ) {
            if let size = result.size {
                Text(ByteCount.format(size))
                SheetFactSeparator()
            }
            Text("Internet Archive")
            if let creator = result.rawAttributes["creator"] {
                SheetFactSeparator()
                Text(creator).lineLimit(1)
            }
            SheetFactSeparator()
            DestinationReadoutButton(
                readout: model.destinationReadout(for: result),
                isOverridden: model.hasDestinationOverride(for: result),
                menu: destinationMenu)
        }
    }

    private var destinationMenu: DestinationMenuItems {
        DestinationMenuItems(
            entries: model.destinationEntries(for: result),
            root: model.destinationRoot,
            selected: model.selectedDestinationEntry(for: result),
            onSelect: { model.selectDestination($0, for: result) })
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
            EmptyStateView(
                symbol: "exclamationmark.triangle.fill",
                message: message,
                tint: Palette.attention,
                size: .inline)
        case .picking(let files):
            let shown = Self.matching(
                (showsDerived ?? false) ? files : files.filter { !$0.isDerived }, filterText)
            let tree = FileTree.build(from: shown.map(Self.asDebridFile))
            VStack(spacing: 0) {
                toolbar(files: files, shown: shown)
                ThemedDivider()
                if tree.isEmpty {
                    centred {
                        Text("No files match “\(filterText)”.")
                            .foregroundStyle(Palette.textSecondary)
                    }
                } else {
                    ScrollView {
                        FileTreeOutlineView(
                            nodes: tree,
                            checkState: {
                                CheckStateRule.state(of: $0, selected: selected)
                            },
                            onToggle: { selected = CheckStateRule.toggled($0, in: selected) },
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
                .help("Archive.org generates extra formats from each upload, "
                      + "usually an .mp4 beside the original. Off by default so "
                      + "the list is not every file twice.")
        }
        .font(FetchFont.callout)
        .padding(.horizontal, Spacing.s12)
        .padding(.vertical, Spacing.s8)
    }

    static func asDebridFile(_ file: InternetArchiveProvider.ItemFile) -> DebridFile {
        DebridFile(
            id: DebridFileID(rawValue: file.url.absoluteString),
            name: file.name,
            shortName: (file.name as NSString).lastPathComponent,
            size: file.size ?? 0,
            mimeType: nil)
    }

    static func matching(
        _ files: [InternetArchiveProvider.ItemFile], _ text: String
    ) -> [InternetArchiveProvider.ItemFile] {
        let needle = text.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return files }
        return files.filter { $0.name.localizedCaseInsensitiveContains(needle) }
    }

    @ViewBuilder
    private var listFooter: some View {
        if case .picking(let files) = phase {
            let chosen = files.filter { selected.contains($0.name) }
            let bytes = chosen.compactMap(\.size).reduce(0, +)
            ListFooterBar(
                leading: "\(chosen.count) of \(files.count) "
                    + (files.count == 1 ? "file" : "files"),
                trailing: bytes > 0 ? ByteCount.format(bytes) : nil)
        }
    }

    private var footer: some View {
        HStack(spacing: Spacing.s12) {
            if torrentURL != nil {
                Label("Also available as a torrent", systemImage: "link")
                    .font(FetchFont.footnote)
                    .foregroundStyle(Palette.textTertiary)
                    .help("Archive.org publishes a .torrent for this item. Downloading "
                          + "it through a debrid is faster when one already holds it. "
                          + "That route is not wired up yet.")
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            PrimaryActionButton(
                title: "Download",
                isBusy: isSubmitting,
                isEnabled: !selected.isEmpty,
                action: download)
        }
        .padding(.horizontal, WindowMetrics.sheetInset)
        .padding(.vertical, Spacing.s12)
    }

    private func centred<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack { Spacer(); content(); Spacer() }
            .frame(maxWidth: .infinity)
    }


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
            selected = Set(ArchiveFileSelection.preselected(
                names: files.filter { !$0.isDerived }.map(\.name),
                formatOrder: model.qualityProfile.documentFormatOrder))
            if showsDerived == nil { showsDerived = model.archiveShowsDerivedByDefault }
            phase = .picking(files)
            expanded = Set(
                FileTree.build(from: files.map(Self.asDebridFile))
                    .filter(\.isFolder).map(\.id))


            torrentURL = try? await provider.torrentURL(forItem: identifier)
        } catch {
            phase = .error(String(describing: error))
        }
    }


    private func download() {
        guard case .picking(let files) = phase else { return }
        isSubmitting = true
        let chosen = files.filter { selected.contains($0.name) }
        Task {
            let folder = result.title.isEmpty
                ? (result.rawAttributes["identifier"] ?? "")
                : result.title

            await model.enqueueDirect(
                chosen.map {
                    (name: ItemFolder.relativePath(folder: folder, file: $0.name),
                     size: $0.size, url: $0.url)
                },
                contentKey: result.rawAttributes["identifier"] ?? result.id.rawValue,
                groupName: folder,
                subfolder: model.plannedSubfolder(for: result),
                metadata: result.metadata)
            isSubmitting = false
            dismiss()
        }
    }
}
