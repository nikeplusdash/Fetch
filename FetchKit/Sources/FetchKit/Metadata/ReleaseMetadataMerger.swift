import Foundation
import FetchPluginAPI

/// Overlays authoritative Torznab attributes onto a name-parsed
/// `ReleaseMetadata`, and merges torrent-level metadata into a
/// file-level parse (§8's two-level parsing). Both are pure data
/// transforms — no I/O.
public enum ReleaseMetadataMerger {
    // MARK: - Attribute merge

    /// Attributes win on conflict (§8: "Attributes win on conflict, and
    /// every field records which source produced it"). A recognized
    /// attribute always overrides whatever the title parse produced for
    /// that field, even if the parse already had a value — the table in
    /// §8 rates `imdb`/`tvdbid`/`resolution`/`video` etc. as authoritative
    /// *when present*, with no carve-out for "unless the parse disagrees".
    ///
    /// Unrecognized attribute values (an indexer's `resolution="8K"`, say)
    /// still count as attribute-sourced — they decode through the same
    /// `unknown(String)` enums the parser uses, never dropped.
    public static func mergingAttributes(
        _ rawAttributes: [String: String], into metadata: ReleaseMetadata
    ) -> ReleaseMetadata {
        var result = metadata
        var provenance = metadata.provenance

        func value(_ keys: String...) -> String? {
            for key in keys {
                for (attrKey, attrValue) in rawAttributes
                where attrKey.caseInsensitiveCompare(key) == .orderedSame {
                    let trimmed = attrValue.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { return trimmed }
                }
            }
            return nil
        }

        if let raw = value("imdb", "imdbid") {
            result.imdbID = raw.hasPrefix("tt") ? raw : "tt\(raw)"
            provenance[.imdbID] = .attribute
        }
        if let raw = value("tmdbid", "tmdb"), let intValue = Int(raw) {
            result.tmdbID = intValue
            provenance[.tmdbID] = .attribute
        }
        if let raw = value("tvdbid", "tvdb"), let intValue = Int(raw) {
            result.tvdbID = intValue
            provenance[.tvdbID] = .attribute
        }
        if let raw = value("year"), let intValue = Int(raw) {
            result.year = intValue
            provenance[.year] = .attribute
        }
        if let raw = value("season"), let intValue = Int(raw) {
            result.season = intValue
            provenance[.season] = .attribute
        }
        if let raw = value("episode", "ep"), let intValue = Int(raw) {
            result.episodes = [intValue]
            provenance[.episodes] = .attribute
        }
        if let raw = value("resolution") {
            result.resolution = Self.resolve(raw, table: TokenTables.resolution) ?? .unknown(raw)
            provenance[.resolution] = .attribute
        }
        if let raw = value("video", "videocodec", "codec") {
            result.videoCodec = Self.resolve(raw, table: TokenTables.videoCodec) ?? .unknown(raw)
            provenance[.videoCodec] = .attribute
        }
        if let raw = value("audio", "audiocodec") {
            result.audioCodec = Self.resolve(raw, table: TokenTables.audioCodec) ?? .unknown(raw)
            provenance[.audioCodec] = .attribute
        }
        if let raw = value("group", "releasegroup", "team") {
            result.releaseGroup = raw
            provenance[.releaseGroup] = .attribute
        }

        result.provenance = provenance
        return result
    }

    // MARK: - Provider-stated fields

    /// Re-applies the fields a **provider stated** over a title parse.
    ///
    /// `mergingAttributes` only knows the Torznab attribute vocabulary
    /// (`imdb`/`year`/`resolution`/…). A source like Gutendex or Archive.org
    /// does not put its knowledge in `rawAttributes` at all — it fills
    /// `ReleaseMetadata` directly and marks those fields `.attribute`, which
    /// is precisely the enum's meaning of "a source said so" as against
    /// `.titleParse`'s "Fetch guessed". Without this step the parse stage
    /// rebuilt metadata from the guess and discarded the statement: a
    /// Gutenberg book's `mediaKind` fell back from `.book` to `.other` and the
    /// EPUB routed to `Other/` instead of `Books/`.
    ///
    /// Only `.attribute` fields are carried over, and only those — anything
    /// the provider left unstated is still whatever the title parse produced,
    /// with its `.titleParse` provenance intact. A result that states nothing
    /// (`ReleaseMetadata.unparsed`, which is every Torznab result) has an
    /// empty provenance, so this is exactly a no-op for that path.
    public static func mergingStated(
        _ stated: ReleaseMetadata, into parsed: ReleaseMetadata
    ) -> ReleaseMetadata {
        var result = parsed
        var provenance = parsed.provenance

        for field in MetadataField.allCases where stated.provenance[field] == .attribute {
            // A provider can mark a field `.attribute` and still have nothing
            // in it — `InternetArchiveProvider` sets `.title: .attribute`
            // unconditionally while `doc.title` is optional. Copying that nil
            // would delete the title the parse recovered from the identifier
            // *and* leave provenance claiming a source stated it, which is a
            // worse answer than the guess it replaced.
            guard Self.hasValue(field, in: stated) else { continue }

            switch field {
            case .mediaKind: result.mediaKind = stated.mediaKind
            case .title: result.title = stated.title
            case .year: result.year = stated.year
            case .season: result.season = stated.season
            case .episodes: result.episodes = stated.episodes
            case .absoluteEpisode: result.absoluteEpisode = stated.absoluteEpisode
            case .isSeasonPack: result.isSeasonPack = stated.isSeasonPack
            case .episodeTitle: result.episodeTitle = stated.episodeTitle
            case .imdbID: result.imdbID = stated.imdbID
            case .tmdbID: result.tmdbID = stated.tmdbID
            case .tvdbID: result.tvdbID = stated.tvdbID
            case .resolution: result.resolution = stated.resolution
            case .source: result.source = stated.source
            case .videoCodec: result.videoCodec = stated.videoCodec
            case .audioCodec: result.audioCodec = stated.audioCodec
            case .audioChannels: result.audioChannels = stated.audioChannels
            case .hdr: result.hdr = stated.hdr
            case .editions: result.editions = stated.editions
            case .languages: result.languages = stated.languages
            case .isProper: result.isProper = stated.isProper
            case .isRepack: result.isRepack = stated.isRepack
            case .releaseGroup: result.releaseGroup = stated.releaseGroup
            case .artist: result.artist = stated.artist
            case .album: result.album = stated.album
            case .author: result.author = stated.author
            case .documentFormat: result.documentFormat = stated.documentFormat
            }
            provenance[field] = .attribute
        }

        result.provenance = provenance
        return result
    }

    /// Whether the provider actually put something in the field it marked
    /// stated.
    ///
    /// The four non-optional cases are always present by construction: a
    /// `MediaKind` is `.unknown` rather than absent, and a `Bool` a provider
    /// declared is a real answer even when it is `false`.
    private static func hasValue(_ field: MetadataField, in stated: ReleaseMetadata) -> Bool {
        switch field {
        case .mediaKind, .isSeasonPack, .isProper, .isRepack:
            return true
        case .title:           return stated.title?.isEmpty == false
        case .year:            return stated.year != nil
        case .season:          return stated.season != nil
        case .episodes:        return !stated.episodes.isEmpty
        case .absoluteEpisode: return stated.absoluteEpisode != nil
        case .episodeTitle:    return stated.episodeTitle?.isEmpty == false
        case .imdbID:          return stated.imdbID?.isEmpty == false
        case .tmdbID:          return stated.tmdbID != nil
        case .tvdbID:          return stated.tvdbID != nil
        case .resolution:      return stated.resolution != nil
        case .source:          return stated.source != nil
        case .videoCodec:      return stated.videoCodec != nil
        case .audioCodec:      return stated.audioCodec != nil
        case .audioChannels:   return stated.audioChannels?.isEmpty == false
        case .hdr:             return stated.hdr != nil
        case .editions:        return !stated.editions.isEmpty
        case .languages:       return !stated.languages.isEmpty
        case .releaseGroup:    return stated.releaseGroup?.isEmpty == false
        case .artist:          return stated.artist?.isEmpty == false
        case .album:           return stated.album?.isEmpty == false
        case .author:          return stated.author?.isEmpty == false
        case .documentFormat:      return stated.documentFormat != nil
        }
    }

    private static func resolve<Value>(_ raw: String, table: [QualityTokenEntry<Value>]) -> Value? {
        guard let match = QualityMatcher.find(table, in: raw), match.range == raw.startIndex..<raw.endIndex
        else { return nil }
        return match.value
    }

    // MARK: - Two-level merge

    /// The file's own values win where present; anything the file parse
    /// didn't determine is inherited from the torrent-level parse and
    /// marked `.inherited` (§8) — without this, every episode of a season
    /// pack would file under the same torrent-level name, since an
    /// individual file's name often carries only the episode marker
    /// ("S03E05.mkv") and nothing else.
    public static func mergingFile(
        _ file: ReleaseMetadata, inheritingFrom torrent: ReleaseMetadata
    ) -> ReleaseMetadata {
        var result = file
        var provenance = file.provenance

        func inheritOptional<T>(_ field: MetadataField, _ keyPath: WritableKeyPath<ReleaseMetadata, T?>) {
            guard provenance[field] == nil, let torrentValue = torrent[keyPath: keyPath] else { return }
            result[keyPath: keyPath] = torrentValue
            provenance[field] = .inherited
        }

        func inheritArray<T>(_ field: MetadataField, _ keyPath: WritableKeyPath<ReleaseMetadata, [T]>) {
            guard provenance[field] == nil, !torrent[keyPath: keyPath].isEmpty else { return }
            result[keyPath: keyPath] = torrent[keyPath: keyPath]
            provenance[field] = .inherited
        }

        func inheritBool(_ field: MetadataField, _ keyPath: WritableKeyPath<ReleaseMetadata, Bool>) {
            guard provenance[field] == nil, torrent[keyPath: keyPath] else { return }
            result[keyPath: keyPath] = torrent[keyPath: keyPath]
            provenance[field] = .inherited
        }

        inheritOptional(.title, \.title)
        inheritOptional(.year, \.year)
        inheritOptional(.season, \.season)
        inheritArray(.episodes, \.episodes)
        inheritOptional(.absoluteEpisode, \.absoluteEpisode)
        inheritBool(.isSeasonPack, \.isSeasonPack)
        inheritOptional(.episodeTitle, \.episodeTitle)
        inheritOptional(.imdbID, \.imdbID)
        inheritOptional(.tmdbID, \.tmdbID)
        inheritOptional(.tvdbID, \.tvdbID)
        inheritOptional(.resolution, \.resolution)
        inheritOptional(.source, \.source)
        inheritOptional(.videoCodec, \.videoCodec)
        inheritOptional(.audioCodec, \.audioCodec)
        inheritOptional(.audioChannels, \.audioChannels)
        inheritOptional(.hdr, \.hdr)
        inheritArray(.editions, \.editions)
        inheritArray(.languages, \.languages)
        inheritBool(.isProper, \.isProper)
        inheritBool(.isRepack, \.isRepack)
        inheritOptional(.releaseGroup, \.releaseGroup)
        inheritOptional(.artist, \.artist)
        inheritOptional(.album, \.album)
        inheritOptional(.author, \.author)
        inheritOptional(.documentFormat, \.documentFormat)

        // `mediaKind` always has a `.titleParse` provenance once a name has
        // gone through `ReleaseNameParser` (even "unrecognized" resolves to
        // `.other`), so it is never actually inherited in practice — kept
        // here for symmetry and to cover a caller that passes an
        // `.unparsed` file-level value directly.
        if provenance[.mediaKind] == nil, torrent.provenance[.mediaKind] != nil {
            result.mediaKind = torrent.mediaKind
            provenance[.mediaKind] = .inherited
        }

        result.provenance = provenance
        return result
    }
}
