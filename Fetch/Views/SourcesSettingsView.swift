import SwiftUI
import FetchKit

/// Settings § Sources — the sources that need no key, no account and no
/// debrid (spec §6).
///
/// This tab exists because `searchesInternetArchive` shipped in 7b set from
/// `AppModel`, defaulting to true, and surfaced **nowhere** — infrastructure
/// built and never connected, which is a documented failure mode in this repo.
/// Torznab servers stay in § Search: those are credentials and endpoints, and
/// these are neither.
struct SourcesSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        Form {
            Section("Results") {
                Toggle("Safe search", isOn: $model.safeSearch)
                    .help("Hides results an indexer files under Torznab's XXX "
                          + "categories (6000–6999). Matching is on the category the "
                          + "indexer declares, so a result it categorises wrongly can "
                          + "still get through — and nothing is hidden for its title "
                          + "alone. Takes effect on your next search.")
            }

            Section("Internet Archive") {
                Toggle("Search Internet Archive", isOn: $model.searchesInternetArchive)
                Toggle(
                    "Show files Archive.org generated",
                    isOn: $model.archiveShowsDerivedByDefault)
                    .help("Archive.org generates extra formats from each upload — usually "
                          + "an .mp4 beside the original. This sets the default for an "
                          + "item's picker; the toggle is still there per item.")
            }

            Section("Project Gutenberg") {
                Toggle("Search Project Gutenberg", isOn: $model.searchesGutenberg)

                Text("Format preference lives in Quality › Books — it applies "
                     + "to Internet Archive books too, and reordering it "
                     + "re-ranks results already on screen.")
                    .font(FetchFont.footnote)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle(
                    "Follow this Mac's preferred languages",
                    isOn: $model.gutenbergFollowsSystemLanguages)
                Text(languageSummary)
                    .font(FetchFont.footnote)
                    .foregroundStyle(Palette.textSecondary)

                Toggle(
                    "Include cover art and metadata files",
                    isOn: $model.gutenbergIncludesSupplementary)
                    .help("Gutenberg publishes a cover image and a catalogue record "
                          + "beside each book. Off by default because neither is the book.")
            }
        }
        .formStyle(.grouped)
        .padding(Spacing.s16)
    }

    /// States what the filter resolved to. A filter the user can read is a
    /// different thing from a filter that hides.
    private var languageSummary: String {
        guard model.gutenbergFollowsSystemLanguages else {
            return "All languages — the whole catalogue answers."
        }
        let codes = model.gutenbergLanguageCodes
        guard !codes.isEmpty else { return "All languages — macOS reported no preference." }
        let names = codes.map { code in
            Locale.current.localizedString(forLanguageCode: code) ?? code
        }
        return "Searching in \(names.joined(separator: ", ")) — from macOS."
    }
}
