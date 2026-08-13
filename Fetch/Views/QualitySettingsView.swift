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
            // Above the split, not inside the Form's first card. It chooses
            // which axes the *whole* pane edits — both columns — so a control
            // sitting in one column's first row was claiming a narrower scope
            // than it has, and inheriting that card's insets made it read as
            // a setting rather than a mode.
            Picker("Kind", selection: $editing) {
                ForEach(EditableKind.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, Spacing.s20)
            .padding(.vertical, Spacing.s8)
            .fixedSize(horizontal: false, vertical: true)

            Divider()

            HSplitView {
            Form {
                switch editing {
                case .video:
                    preferenceSection(
                        title: "Resolution",
                        labels: model.qualityProfile.resolutionOrder.map(\.name),
                        onMove: { from, to in model.qualityProfile.resolutionOrder.move(fromOffsets: from, toOffset: to) })

                    preferenceSection(
                        title: "Source",
                        labels: model.qualityProfile.sourceOrder.map(\.name),
                        onMove: { from, to in model.qualityProfile.sourceOrder.move(fromOffsets: from, toOffset: to) })

                    preferenceSection(
                        title: "Codec",
                        labels: model.qualityProfile.codecOrder.map(\.name),
                        onMove: { from, to in model.qualityProfile.codecOrder.move(fromOffsets: from, toOffset: to) })

                case .audio:
                    preferenceSection(
                        title: "Audio codec",
                        labels: model.qualityProfile.audioCodecOrder.map(\.name),
                        onMove: { from, to in model.qualityProfile.audioCodecOrder.move(fromOffsets: from, toOffset: to) })

                    Section {
                        Toggle("Prefer lossless", isOn: $model.qualityProfile.prefersLossless)
                            .toggleStyle(.checkbox)
                        Text("A preference, not a filter — a lossy release is "
                             + "demoted, never hidden. To refuse one outright, "
                             + "reject it above, where you can see what it removed.")
                            .font(FetchFont.footnote)
                            .foregroundStyle(Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                case .books:
                    preferenceSection(
                        title: "Format",
                        labels: model.qualityProfile.documentFormatOrder.map(\.displayName),
                        onMove: { from, to in model.qualityProfile.documentFormatOrder.move(fromOffsets: from, toOffset: to) })

                    Section {
                        Text("This reorders a book's own download links as well "
                             + "as the results list: one book is one row with a "
                             + "link per format, and the first is what a download "
                             + "takes.")
                            .font(FetchFont.footnote)
                            .foregroundStyle(Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                case .other:
                    Section {
                        Text("Software, games and anything Fetch cannot classify "
                             + "have no quality axis to rank on, so they order by "
                             + "name match and popularity alone. A release that "
                             + "carries a resolution is still ranked as video, "
                             + "even when nobody could say it was a film.")
                            .font(FetchFont.footnote)
                            .foregroundStyle(Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Section {
                    ForEach(Self.rejectableSources, id: \.self) { source in
                        Toggle(
                            source.name.uppercased(),
                            isOn: Binding(
                                get: { model.qualityProfile.rejected.contains(.source(source)) },
                                set: { isOn in
                                    if isOn {
                                        model.qualityProfile.rejected.append(.source(source))
                                    } else {
                                        model.qualityProfile.rejected.removeAll { $0 == .source(source) }
                                    }
                                }))
                        .toggleStyle(.checkbox)
                    }
                    Text("Rejected releases are removed, not demoted — no number "
                         + "of seeders makes a camrip the right answer. They stay "
                         + "reachable behind \"show N hidden\" on the results list.")
                        .font(FetchFont.footnote)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } header: {
                    Text("Reject").font(FetchFont.headline)
                }

                Section {
                    LabeledContent("Quality") {
                        Slider(value: $model.qualityProfile.weights.quality, in: 0...2)
                    }
                    LabeledContent("Popularity") {
                        Slider(value: $model.qualityProfile.weights.popularity, in: 0...2)
                    }
                    Text("Seeders for a torrent, downloads for Internet Archive "
                         + "and Project Gutenberg — counted logarithmically: 5 "
                         + "versus 50 matters, 2,000 versus 4,000 does not. A "
                         + "linear term would let a popular rip outrank every REMUX.")
                        .font(FetchFont.footnote)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } header: {
                    Text("Weighting").font(FetchFont.headline)
                }

                Section {
                    Button("Reset to defaults") { model.qualityProfile = .default }
                        .buttonStyle(.borderless)
                }
            }
            .formStyle(.grouped)
            // Keeps rows off the scroller. A grouped Form draws its cards to
            // the container's edge, so an overlay scrollbar lands on top of
            // the right-hand controls rather than beside them.
            .padding(.trailing, Spacing.s8)
            // **Both columns asked for a minimum and neither had a ceiling**,
            // so the pair demanded 620 points plus padding from a window whose
            // minimum is 900 *including* the sidebar — and the right-hand one
            // simply ran off the edge, taking its text with it. Flexible with
            // a floor, and the preview capped, so the editor absorbs the
            // slack and the preview stays a readable column rather than
            // growing to whatever is left.
            .frame(minWidth: 300, maxWidth: .infinity)

            preview
                .frame(minWidth: 260, idealWidth: 320, maxWidth: 380)
            }
        }
    }

    private func preferenceSection(
        title: String, labels: [String], onMove: @escaping (IndexSet, Int) -> Void
    ) -> some View {
        Section {
            // Drag to reorder; the first entry is the most preferred.
            ReorderableRows(count: labels.count, onMove: onMove) { index in
                let label = labels[index]
                HStack(spacing: Spacing.s8) {
                    Text("\(index + 1)")
                        .font(FetchFont.calloutMono)
                        .foregroundStyle(Palette.textTertiary)
                        .frame(width: 16, alignment: .trailing)
                    Text(label)
                    Spacer()
                    Image(systemName: "line.3.horizontal")
                        .foregroundStyle(Palette.textQuaternary)
                }
                .padding(.vertical, Spacing.s2)
            }
        } header: {
            Text("\(title) — most preferred first").font(FetchFont.headline)
        }
    }

    // MARK: - Live preview

    /// Ranked by the profile as it is edited.
    private var preview: some View {
        let ranked = model.qualityProfile.apply(to: sample, matching: "")

        return VStack(alignment: .leading, spacing: Spacing.s8) {
            Text("Preview")
                .font(FetchFont.headline)
            Text(model.searchResults.isEmpty
                 ? "A built-in sample — run a search and this shows your own results."
                 : "Your current search results, re-ranked as you edit.")
                .font(FetchFont.footnote)
                .foregroundStyle(Palette.textSecondary)
                // Wraps instead of running past the column's edge, which is
                // where the sentence was disappearing.
                .fixedSize(horizontal: false, vertical: true)

            List {
                ForEach(Array(ranked.accepted.prefix(12).enumerated()), id: \.offset) { index, result in
                    HStack(spacing: Spacing.s8) {
                        Text("\(index + 1)")
                            .font(FetchFont.calloutMono)
                            .foregroundStyle(Palette.textTertiary)
                            .frame(width: 18, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(result.title)
                                .font(FetchFont.footnote)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(Self.subtitle(result))
                                .font(FetchFont.caption2)
                                .foregroundStyle(Palette.textTertiary)
                        }
                    }
                }
                if !ranked.rejected.isEmpty {
                    Text("\(ranked.rejected.count) rejected by this profile")
                        .font(FetchFont.caption2)
                        .foregroundStyle(Palette.miss)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .background(Palette.contentBackground)
            .clipShape(RoundedRectangle(cornerRadius: Radius.r8))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.r8)
                    .strokeBorder(Palette.separator))
        }
        .padding(Spacing.s12)
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
