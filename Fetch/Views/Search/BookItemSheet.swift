import SwiftUI
import FetchKit
import FetchPluginAPI

/// The format panel for a Project Gutenberg book (spec §5).
///
/// Checkboxes rather than radio buttons: once a cover is downloadable,
/// "the EPUB and the cover" is a reasonable thing to want, and `enqueueDirect`
/// already takes an array. It also makes this the same interaction as
/// `ArchiveItemSheet`, which is the point of having a panel at all.
struct BookItemSheet: View {
    let result: SearchResult

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private enum Phase {
        case loading
        case picking(GutenbergBook)
        case error(String)
    }

    @State private var phase: Phase = .loading
    @State private var selected: Set<BookFormat> = []
    @State private var isSubmitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ThemedDivider()
            content
            listFooter
            ThemedDivider()
            footer
        }
        .frame(width: 460, height: 360)
        .task { await load() }
        .onDisappear { model.forgetDestinationOverride(for: result) }
    }

    /// The same block the other three sheets use.
    ///
    /// No size on the facts line: Gutenberg publishes none anywhere in its
    /// catalogue, and the download learns it from `Content-Length`. A dash
    /// there would be a fact stated as absent; leaving it out is the absence.
    private var header: some View {
        SheetHeaderBlock(
            title: result.title,
            tag: TagPill(
                title: "Ready", tone: .ready,
                explanation: "Project Gutenberg serves this over plain HTTPS. No "
                    + "debrid account is involved and nothing is queued.")
        ) {
            Text("Project Gutenberg")
            if let author = result.rawAttributes["author"] {
                SheetFactSeparator()
                Text(author).lineLimit(1)
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
            centred { ProgressView("Loading formats…") }
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
        case .picking(let book):
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.s4) {
                    ForEach(book.choices) { choice in
                        Toggle(isOn: binding(for: choice.format)) {
                            HStack(spacing: Spacing.s6) {
                                Text(choice.format.displayName)
                                if choice.format == book.choices.first?.format {
                                    Text("preferred")
                                        .font(FetchFont.caption2)
                                        .foregroundStyle(Palette.textTertiary)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .padding(Spacing.s16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// The count that describes the format list, inside its border.
    ///
    /// The filename rides in the trailing slot rather than the size, because
    /// Gutenberg declares no size and its URLs carry no filename either — so
    /// this is the only place anyone sees what they are actually getting.
    @ViewBuilder
    private var listFooter: some View {
        if case .picking(let book) = phase {
            ListFooterBar(
                leading: "\(selected.count) of \(book.choices.count) "
                    + (book.choices.count == 1 ? "format" : "formats"),
                trailing: savedFilename(for: book))
        }
    }

    private var footer: some View {
        HStack(spacing: Spacing.s12) {
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

    /// The name the first chosen file will be saved as.
    private func savedFilename(for book: GutenbergBook) -> String? {
        let chosen = book.choices.filter { selected.contains($0.format) }
        guard let first = chosen.first else { return nil }
        let name = BookFilename.make(
            title: book.title, author: book.author, format: first.format)
        return chosen.count == 1 ? name : "\(name), …"
    }

    private func binding(for format: BookFormat) -> Binding<Bool> {
        Binding(
            get: { selected.contains(format) },
            set: { on in
                if on { selected.insert(format) } else { selected.remove(format) }
            })
    }

    private func centred<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack { Spacer(); content(); Spacer() }
            .frame(maxWidth: .infinity)
    }

    // MARK: - Loading

    private func load() async {
        guard let raw = result.rawAttributes["gutenbergID"], let id = Int(raw) else {
            phase = .error("This result is missing its Gutenberg ID.")
            return
        }
        let provider = GutenbergProvider(
            client: HTTPClient(allowedHosts: [
                GutenbergProvider.apiHost, GutenbergProvider.fileHost,
            ]),
            includesSupplementary: model.gutenbergIncludesSupplementary)
        do {
            let fetched = try await provider.book(id: id)
            // The sheet offers the same order the list ranked by, or the row
            // and the sheet disagree about which format is preferred.
            let book = fetched.ordered(by: model.qualityProfile.documentFormatOrder)
            guard let preferred = book.choices.first else {
                phase = .error("This book has no downloadable formats.")
                return
            }
            selected = [preferred.format]
            phase = .picking(book)
        } catch {
            phase = .error(String(describing: error))
        }
    }

    // MARK: - Actions

    private func download() {
        guard case .picking(let book) = phase else { return }
        isSubmitting = true
        let chosen = book.choices.filter { selected.contains($0.format) }
        Task {
            await model.enqueueDirect(
                chosen.map { choice in
                    (name: BookFilename.make(
                        title: book.title, author: book.author, format: choice.format),
                     size: nil,
                     url: choice.url)
                },
                // The book, so two formats of one work share one row — the
                // same job the infohash does for a torrent.
                contentKey: "gutenberg:\(book.id)",
                groupName: book.title,
                subfolder: model.plannedSubfolder(for: result),
                metadata: result.metadata)
            isSubmitting = false
            dismiss()
        }
    }
}
