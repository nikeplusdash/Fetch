import SwiftUI
import FetchKit

/// Settings § Quality (§12.4) — the profile that decides Best match.
///
/// The live preview is the point, not decoration. The spec's reasoning: an
/// abstract weighting slider is otherwise unevaluable — you cannot tell what
/// "quality 1.0, seeders 0.35" means until you watch it reorder releases you
/// recognise. It re-ranks your **current search results** where there are any,
/// so the preview is about content you were actually looking at.
struct QualitySettingsView: View {
    @Environment(AppModel.self) private var model

    /// Which kind's axes are on screen. Four groups, not eight kinds: TV and
    /// anime are ranked by the video axes, so editing "Video" edits them too.
    @State private var editing: EditableKind = .video

    enum EditableKind: String, CaseIterable, Identifiable {
        case video, audio, books, other
        var id: Self { self }
        var title: String {
            switch self {
            case .video: "Video"
            case .audio: "Audio"
            case .books: "Books"
            case .other: "Other"
            }
        }
    }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            // The same pill row the pane tabs and the Downloads filters use.
            // It chooses which axes the *whole* pane edits, so it sits above
            // every group rather than inside the first one, where it read as a
            // setting rather than a mode.
            FilterPillBar(
                items: EditableKind.allCases,
                title: \.title,
                isSelected: { $0 == editing },
                select: { editing = $0 },
                height: WindowMetrics.subBarHeight)
                .background(Palette.rowAlternate)
            ThemedDivider()

            axes(for: model)
            rejectGroup(model)
            weightingGroup(model)

            SettingsGroup(title: "Preview") {
                // **The point, not decoration.** A weighting slider is
                // otherwise unevaluable: you cannot tell what "quality 1.0,
                // popularity 0.35" means until you watch it reorder releases
                // you recognise. In one column with the settings rather than
                // beside them in an `HSplitView`, which demanded 620 points
                // from a window whose minimum is 900 including the sidebar and
                // simply ran the preview off the edge.
                preview
            }
        }
    }

    /// The reorderable preference lists for whichever kind is chosen.
    @ViewBuilder
    private func axes(for model: AppModel) -> some View {
        @Bindable var model = model
        switch editing {
        case .video:
            preferenceGroup(
                title: "Resolution",
                labels: model.qualityProfile.resolutionOrder.map(\.name),
                onMove: { from, to in
                    model.qualityProfile.resolutionOrder.move(fromOffsets: from, toOffset: to) })
            preferenceGroup(
                title: "Source",
                labels: model.qualityProfile.sourceOrder.map(\.name),
                onMove: { from, to in
                    model.qualityProfile.sourceOrder.move(fromOffsets: from, toOffset: to) })
            preferenceGroup(
                title: "Codec",
                labels: model.qualityProfile.codecOrder.map(\.name),
                onMove: { from, to in
                    model.qualityProfile.codecOrder.move(fromOffsets: from, toOffset: to) })

        case .audio:
            preferenceGroup(
                title: "Audio codec",
                labels: model.qualityProfile.audioCodecOrder.map(\.name),
                onMove: { from, to in
                    model.qualityProfile.audioCodecOrder.move(fromOffsets: from, toOffset: to) })
            SettingsGroup(title: "Lossless") {
                SettingRow(
                    label: "Prefer lossless",
                    help: "A preference, not a filter. A lossy release is "
                        + "demoted, never hidden."
                ) {
                    Toggle("", isOn: $model.qualityProfile.prefersLossless).labelsHidden()
                }
            }

        case .books:
            preferenceGroup(
                title: "Format",
                labels: model.qualityProfile.documentFormatOrder.map(\.displayName),
                onMove: { from, to in
                    model.qualityProfile.documentFormatOrder.move(
                        fromOffsets: from, toOffset: to) })
            SettingsGroup(title: "What this reorders") {
                SettingRow(
                    label: "A book's own links, too",
                    help: "One book is one row with a link per format, and the "
                        + "first is what a download takes."
                ) { EmptyView() }
            }

        case .other:
            SettingsGroup(title: "Everything else") {
                SettingRow(
                    label: "No quality axis",
                    help: "Software, games and anything unclassified rank on "
                        + "name match and popularity alone.",
                    detail: (
                        summary: "Except when they carry a resolution",
                        body: "A release that states a resolution is ranked as "
                            + "video even when nobody could say it was a film. "
                            + "That is deliberate: the axes follow the metadata "
                            + "a release actually carries, not the label a "
                            + "parser guessed for it.")
                ) { EmptyView() }
            }
        }
    }

    private func rejectGroup(_ model: AppModel) -> some View {
        @Bindable var model = model
        return SettingsGroup(title: "Reject") {
            ForEach(Self.rejectableSources, id: \.self) { source in
                SettingRow(
                    label: source.name.uppercased(),
                    help: nil
                ) {
                    Toggle("", isOn: Binding(
                        get: { model.qualityProfile.rejected.contains(.source(source)) },
                        set: { isOn in
                            if isOn {
                                model.qualityProfile.rejected.append(.source(source))
                            } else {
                                model.qualityProfile.rejected.removeAll {
                                    $0 == .source(source)
                                }
                            }
                        }))
                        .labelsHidden()
                }
            }
            SettingRow(
                label: "What rejecting does",
                help: "Removed, not demoted. No number of seeders makes a "
                    + "camrip the right answer.",
                detail: (
                    summary: "They are still reachable",
                    body: "Rejected releases sit behind \"show N hidden\" on the "
                        + "results list, so a profile that is too aggressive is "
                        + "visible rather than silent.")
            ) { EmptyView() }
        }
    }

    private func weightingGroup(_ model: AppModel) -> some View {
        @Bindable var model = model
        return SettingsGroup(title: "Weighting") {
            SettingRow(label: "Quality", help: "How much the axes above matter.") {
                Slider(value: $model.qualityProfile.weights.quality, in: 0...2)
                    .frame(width: ColumnWidth.byteCount)
            }
            SettingRow(
                label: "Popularity",
                help: "Seeders for a torrent, downloads for the open sources.",
                detail: (
                    summary: "Counted logarithmically",
                    body: "5 versus 50 matters; 2,000 versus 4,000 does not. A "
                        + "linear term would let a popular rip outrank every "
                        + "REMUX. Quality and popularity are both normalised "
                        + "0 to 1, so changing one means re-checking the other.")
            ) {
                Slider(value: $model.qualityProfile.weights.popularity, in: 0...2)
                    .frame(width: ColumnWidth.byteCount)
            }
            SettingRow(label: "Start again", help: "Back to the shipped profile.") {
                Button("Reset") { model.qualityProfile = .default }
            }
        }
    }

    /// Drag to reorder; the first entry is the most preferred.
    private func preferenceGroup(
        title: String, labels: [String], onMove: @escaping (IndexSet, Int) -> Void
    ) -> some View {
        SettingsGroup(title: "\(title), most preferred first") {
            // Keyed by the label itself. This list only ever reorders, so it
            // could not hit the removal trap, but one component with two
            // iteration models is one waiting to be copied from.
            ReorderableRows(items: labels, id: \.self, onMove: onMove) { index, label in
                HStack(spacing: Spacing.s8) {
                    Text("\(index + 1)")
                        .font(FetchFont.calloutMono)
                        .foregroundStyle(Palette.textTertiary)
                        .frame(width: IconSize.lg, alignment: .trailing)
                    Text(label).font(FetchFont.body)
                    Spacer()
                    Image(systemName: "line.3.horizontal")
                        .foregroundStyle(Palette.textQuaternary)
                }
                .padding(.vertical, Spacing.s6)
                .overlay(alignment: .bottom) { ThemedDivider().opacity(0.6) }
            }
        }
    }

    // MARK: - Live preview

    /// Ranked by the profile as it is edited.
    private var preview: some View {
        let ranked = model.qualityProfile.apply(to: sample, matching: "")

        return VStack(alignment: .leading, spacing: Spacing.s8) {
            Text(model.searchResults.isEmpty
                 ? "A built-in sample. Run a search and this shows your own results."
                 : "Your current search results, re-ranked as you edit.")
                .font(FetchFont.subheadline)
                .foregroundStyle(Palette.textSecondary)
                // Wraps instead of running past the column's edge, which is
                // where the sentence was disappearing.
                .fixedSize(horizontal: false, vertical: true)

            // A `VStack`, not a `List`: a scrolling list inside a scrolling
            // pane needs a height nobody knows, and every settings bug in this
            // area has come from guessing a measurement instead of letting
            // layout supply it.
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(ranked.accepted.prefix(8).enumerated()), id: \.offset) { index, result in
                    if index > 0 { ThemedDivider().opacity(0.6) }
                    HStack(spacing: Spacing.s8) {
                        Text("\(index + 1)")
                            .font(FetchFont.calloutMono)
                            .foregroundStyle(Palette.textTertiary)
                            .frame(width: IconSize.xl, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(result.title)
                                .font(FetchFont.callout)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(Self.subtitle(result))
                                .font(FetchFont.subheadline)
                                .foregroundStyle(Palette.textTertiary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, Spacing.s6)
                    .padding(.horizontal, Spacing.s8)
                }
                if !ranked.rejected.isEmpty {
                    ThemedDivider().opacity(0.6)
                    Text("\(ranked.rejected.count) rejected by this profile")
                        .font(FetchFont.subheadline)
                        .foregroundStyle(Palette.miss)
                        .padding(Spacing.s8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.rowAlternate)
            .clipShape(RoundedRectangle(cornerRadius: Radius.r8))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.r8)
                    .strokeBorder(Palette.separator))
        }
        .padding(.vertical, Spacing.s12)
    }

    /// Real results where there are any. The fallback is deliberately the
    /// spec's own example — a REMUX that a 720p rip out-seeds — because that
    /// is the case the whole ranking exists to get right.
    ///
    /// The sample follows the picker: previewing book format order against
    /// five film releases would show nothing moving and read as a broken
    /// setting rather than an inapplicable one.
    private var sample: [SearchResult] {
        guard model.searchResults.isEmpty else { return Array(model.searchResults.prefix(40)) }
        return switch editing {
        case .video, .other: Self.builtInSample
        case .audio: Self.builtInAudioSample
        case .books: Self.builtInBookSample
        }
    }

    /// What a row says under its title. A book has no seeders and is not a
    /// torrent nobody is seeding, so it says what it does have instead.
    private static func subtitle(_ result: SearchResult) -> String {
        if let seeders = result.seeders { return "\(seeders) seeders" }
        var parts: [String] = []
        if let format = result.metadata.documentFormat { parts.append(format.displayName) }
        if let codec = result.metadata.audioCodec { parts.append(codec.name.uppercased()) }
        if let grabs = result.grabs { parts.append("\(grabs) downloads") }
        return parts.isEmpty ? "no seeders" : parts.joined(separator: " · ")
    }

    /// One book, several formats — which is what a Gutenberg result is.
    private static let builtInBookSample: [SearchResult] = [
        makeBook("Frankenstein", format: .pdf, downloads: 240_000, key: "sample:1"),
        makeBook("Frankenstein", format: .epub, downloads: 58_824, key: "sample:2"),
        makeBook("Dracula", format: .azw3, downloads: 31_002, key: "sample:3"),
        makeBook("The Time Machine", format: .text, downloads: 12_440, key: "sample:4"),
    ]

    private static let builtInAudioSample: [SearchResult] = [
        makeAudio("Album (FLAC)", codec: .flac, seeders: 30),
        makeAudio("Album (MP3 320)", codec: .mp3, seeders: 800),
        makeAudio("Album (AAC)", codec: .aac, seeders: 120),
    ]

    private static func makeBook(
        _ title: String, format: DocumentFormat, downloads: Int, key: String
    ) -> SearchResult {
        var metadata = ReleaseMetadata.unparsed
        metadata.mediaKind = .book
        metadata.documentFormat = format
        return SearchResult(
            candidates: [.direct(
                url: URL(string: "https://www.gutenberg.org/\(key).\(format.displayName)")!,
                format: format)],
            title: title, size: nil, seeders: nil, peers: nil, grabs: downloads,
            category: nil, publishDate: nil,
            sources: [SearchProviderID(rawValue: "sample")], sourceKey: key,
            rawAttributes: [:], metadata: metadata)
    }

    private static func makeAudio(
        _ title: String, codec: AudioCodec, seeders: Int
    ) -> SearchResult {
        var metadata = ReleaseMetadata.unparsed
        metadata.mediaKind = .music
        metadata.audioCodec = codec
        let hash = String(title.filter(\.isLetter).lowercased()
            .padding(toLength: 40, withPad: "0", startingAt: 0))
        return SearchResult(
            infoHashHex: hash, title: title, size: 400_000_000, seeders: seeders,
            peers: 0, grabs: nil, fileCount: nil, category: nil, publishDate: nil,
            magnetURI: "magnet:?xt=urn:btih:\(hash)",
            sources: [SearchProviderID(rawValue: "sample")],
            rawAttributes: [:], metadata: metadata)
    }

    private static let builtInSample: [SearchResult] = [
        make("Movie.2021.1080p.BluRay.REMUX.AVC.TrueHD-GRP", seeders: 40,
             resolution: .r1080p, source: .remux, codec: .avc),
        make("Movie.2021.720p.WEBRip.x264-RIP", seeders: 900,
             resolution: .r720p, source: .webrip, codec: .avc),
        make("Movie.2021.2160p.WEB-DL.DDP5.1.HDR.HEVC-GRP", seeders: 220,
             resolution: .r2160p, source: .webdl, codec: .hevc),
        make("Movie.2021.1080p.WEB-DL.DDP5.1.H264-GRP", seeders: 310,
             resolution: .r1080p, source: .webdl, codec: .avc),
        make("Movie.2021.CAM.x264-BAD", seeders: 1500, resolution: .r480p, source: .cam),
    ]

    private static func make(
        _ title: String, seeders: Int, resolution: Resolution? = nil,
        source: ReleaseSource? = nil, codec: VideoCodec? = nil
    ) -> SearchResult {
        var metadata = ReleaseMetadata.unparsed
        metadata.mediaKind = .movie
        metadata.resolution = resolution
        metadata.source = source
        metadata.videoCodec = codec
        let hash = String(title.filter(\.isLetter).lowercased()
            .padding(toLength: 40, withPad: "0", startingAt: 0))
        return SearchResult(
            infoHashHex: hash, title: title, size: 1_000_000_000, seeders: seeders,
            peers: 0, grabs: nil, fileCount: nil, category: nil, publishDate: nil,
            magnetURI: "magnet:?xt=urn:btih:\(hash)",
            sources: [SearchProviderID(rawValue: "sample")],
            rawAttributes: [:], metadata: metadata)
    }

    // MARK: - Labels

    private static let rejectableSources: [ReleaseSource] = [.cam, .screener, .hdtv, .dvd]

}
