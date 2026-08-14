import SwiftUI
import AppKit
import FetchKit

/// Settings § Organization (§12.4) — where downloads are filed and what they
/// are named.
///
/// The preview shows three cases rather than one, because the interesting
/// behaviour is what happens when a parse is *weak*: §9 gates renaming on
/// confidence precisely so a bad parse keeps the original filename instead of
/// producing `Unknown (0000).mkv`. A preview that only ever showed a clean
/// parse would hide the rule that matters most.
struct OrganizationSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            // The only place the folder is editable. Settings § Debrid carried
            // a byte-identical copy of this and its own `chooseDirectory()`, so
            // the same setting had two homes. It belongs here: the routing
            // rules below subdivide exactly this root.
            SettingsGroup(title: "Where downloads land") {
                SettingRow(label: "Folder", help: model.downloadDirectory.path) {
                    Button("Choose…") { chooseDirectory() }
                }
            }

            SettingsGroup(title: "Routing") {
                ReorderableRows(
                    model.routingRules,
                    onMove: { model.routingRules.move(fromOffsets: $0, toOffset: $1) }
                ) { _, rule in
                    // Keyed by the rule's own id rather than its position. The
                    // binding used to read `routingRules[index]`, so deleting a
                    // rule left a row bound to an index that no longer existed
                    // — the same trap that crashed the Debrid pane.
                    RuleRowView(
                        match: describe(rule.match),
                        destination: Binding(
                            get: {
                                model.routingRules
                                    .first { $0.id == rule.id }?.subfolder ?? ""
                            },
                            set: { newValue in
                                guard let i = model.routingRules
                                    .firstIndex(where: { $0.id == rule.id })
                                else { return }
                                model.routingRules[i].subfolder = newValue
                            }),
                        isDragging: false,
                        onDelete: {
                            model.routingRules.removeAll { $0.id == rule.id }
                        })
                    .padding(.vertical, Spacing.s4)
                    .overlay(alignment: .bottom) { ThemedDivider().opacity(0.6) }
                }
                SettingRow(
                    label: "First match wins",
                    help: "Drag to reorder. Anything unmatched goes to "
                        + "\(Routing.fallbackSubfolder)."
                ) { EmptyView() }
            }

            SettingsGroup(title: "Naming") {
                SettingRow(
                    label: "Rename files using templates",
                    help: "Only when the release name parsed confidently. A "
                        + "weak parse keeps its original name.",
                    detail: (
                        summary: "A rename can always be undone",
                        body: "The original filename is stored with the "
                            + "download, so Revert Rename is on the file's own "
                            + "menu. That is also why this is off by default: "
                            + "the safe direction is to keep what the source "
                            + "called it until you have seen what the template "
                            + "would do.")
                ) {
                    Toggle("", isOn: $model.renamesFiles).labelsHidden()
                }
                previewRows
            }
        }
    }

    // MARK: - Preview

    private var previewRows: some View {
        VStack(alignment: .leading, spacing: Spacing.s6) {
            ForEach(Self.samples, id: \.label) { sample in
                previewRow(resolve(sample))
            }
        }
        .padding(.vertical, Spacing.s4)
    }

    private struct Resolved {
        let label: String
        let path: String
        let wasRenamed: Bool
    }

    /// Computed outside the view builder: inlined, the type-checker gives up on
    /// this expression entirely ("failed to produce diagnostic").
    private func resolve(_ sample: Sample) -> Resolved {
        let folder = model.subfolder(for: sample.metadata)
        let strategy = model.namingStrategy(for: sample.metadata.mediaKind)
        let named = strategy.relativePath(
            for: sample.metadata, originalFilename: sample.original) ?? sample.original

        return Resolved(
            label: sample.label,
            // The whole relative path, not just the leaf: templates produce
            // folders, and the folders are most of what is being decided here.
            path: folder + "/" + named,
            wasRenamed: named != sample.original)
    }

    private func previewRow(_ resolved: Resolved) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(resolved.label)
                .font(FetchFont.caption2)
                .foregroundStyle(Palette.textTertiary)
            Text(resolved.path)
                .font(FetchFont.calloutMono)
                .foregroundStyle(resolved.wasRenamed ? Palette.cached : Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private struct Sample {
        let label: String
        let original: String
        let metadata: ReleaseMetadata
    }

    /// A clean parse, a weak one, and a season-pack file — the three cases
    /// §12.4 asks the preview to show.
    private static let samples: [Sample] = [
        Sample(
            label: "Clean parse",
            original: "Dune.Part.Two.2024.2160p.WEB-DL.DDP5.1.HEVC-FLUX.mkv",
            metadata: build(kind: .movie, title: "Dune Part Two", year: 2024,
                            resolution: .r2160p,
                            provenance: [.title: .titleParse, .year: .titleParse])),
        Sample(
            label: "Weak parse, keeping its original name",
            original: "some.obscure.release.name.x264.mkv",
            metadata: build(kind: .movie, title: "some obscure release name",
                            provenance: [.title: .titleParse])),
        Sample(
            label: "Season-pack file",
            original: "The.Expanse.S03E05.1080p.BluRay.x265-GROUP.mkv",
            metadata: build(kind: .tv, title: "The Expanse", season: 3, episodes: [5],
                            resolution: .r1080p,
                            provenance: [.title: .titleParse, .season: .titleParse,
                                         .episodes: .titleParse])),
    ]

    private static func build(
        kind: MediaKind, title: String, year: Int? = nil, season: Int? = nil,
        episodes: [Int] = [], resolution: Resolution? = nil,
        provenance: [MetadataField: MetadataSource]
    ) -> ReleaseMetadata {
        var m = ReleaseMetadata.unparsed
        m.mediaKind = kind
        m.title = title
        m.year = year
        m.season = season
        m.episodes = episodes
        m.resolution = resolution
        m.provenance = provenance
        return m
    }

    private func describe(_ match: RoutingRule.Match) -> String {
        var parts: [String] = []
        if let kind = match.mediaKind { parts.append(kind.name) }
        if let resolution = match.resolution { parts.append(resolution.name) }
        if let title = match.titleContains, !title.isEmpty { parts.append("title ~ \(title)") }
        return parts.isEmpty ? "anything" : parts.joined(separator: " + ")
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = model.downloadDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.setDownloadDirectory(url)
    }
}
