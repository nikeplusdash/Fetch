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
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 460, height: 360)
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
                Text("· Project Gutenberg")
                if let author = result.rawAttributes["author"] {
                    Text("· \(author)").lineLimit(1)
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

    private var footer: some View {
        HStack(spacing: Spacing.s8) {
            if case .picking(let book) = phase {
                Text(summary(for: book))
                    .font(FetchFont.footnote)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
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

    /// Shows the name the file will actually be saved as — the URLs carry
    /// none, so this is the only place the user sees what they are getting.
    private func summary(for book: GutenbergBook) -> String {
        let chosen = book.choices.filter { selected.contains($0.format) }
        guard let first = chosen.first else { return "Nothing selected" }
        let name = BookFilename.make(
            title: book.title, author: book.author, format: first.format)
        return chosen.count == 1 ? "1 file · \(name)" : "\(chosen.count) files · \(name), …"
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
                subfolder: model.subfolder(for: result.metadata),
                metadata: result.metadata)
            isSubmitting = false
            dismiss()
        }
    }
}
