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
        VStack(spacing: 0) {
            SettingsGroup(title: "Results") {
                SettingRow(
                    label: "Safe search",
                    help: "Hides results an indexer files under Torznab's XXX "
                        + "categories. Takes effect on your next search.",
                    detail: (
                        summary: "What it can and cannot catch",
                        body: "Matching is on the categories the indexer "
                            + "declares, so a release it categorises wrongly "
                            + "still gets through. Nothing is hidden for its "
                            + "title alone: a blocklist of words would hide "
                            + "legitimate releases invisibly.")
                ) {
                    Toggle("", isOn: $model.safeSearch).labelsHidden()
                }
            }

            SettingsGroup(title: "Internet Archive") {
                SettingRow(
                    label: "Search Internet Archive",
                    help: "Free, legal, and needs no account."
                ) {
                    Toggle("", isOn: $model.searchesInternetArchive).labelsHidden()
                }
                SettingRow(
                    label: "Show files Archive.org generated",
                    help: "Usually an .mp4 beside the original. Sets the "
                        + "default for an item's picker."
                ) {
                    Toggle("", isOn: $model.archiveShowsDerivedByDefault).labelsHidden()
                }
            }

            SettingsGroup(title: "Project Gutenberg") {
                SettingRow(
                    label: "Search Project Gutenberg",
                    help: "Format preference lives in Quality, under Books."
                ) {
                    Toggle("", isOn: $model.searchesGutenberg).labelsHidden()
                }
                SettingRow(
                    label: "Follow this Mac's languages",
                    // States what the filter resolved to. A filter you can read
                    // is a different thing from a filter that hides.
                    help: languageSummary
                ) {
                    Toggle("", isOn: $model.gutenbergFollowsSystemLanguages).labelsHidden()
                }
                SettingRow(
                    label: "Include cover art and metadata",
                    help: "Gutenberg publishes both beside each book. Neither "
                        + "is the book."
                ) {
                    Toggle("", isOn: $model.gutenbergIncludesSupplementary).labelsHidden()
                }
            }
        }
    }

    private var languageSummary: String {
        guard model.gutenbergFollowsSystemLanguages else {
            return "Searching every language in the catalogue."
        }
        let codes = model.gutenbergLanguageCodes
        guard !codes.isEmpty else {
            return "macOS reported no preference, so every language answers."
        }
        let names = codes.map { code in
            Locale.current.localizedString(forLanguageCode: code) ?? code
        }
        return "Searching in \(names.joined(separator: ", "))."
    }
}
