import Foundation
import FetchPluginAPI

/// Which subfolder a download is filed into (§9, Destination resolution).
///
/// Ordered, first match wins, every stated condition required.
public struct RoutingRule: Sendable, Codable, Equatable, Identifiable {
    public struct Match: Sendable, Codable, Equatable {
        public var mediaKind: MediaKind?
        public var resolution: Resolution?
        /// Case-insensitive substring rather than a regex: a bad regex in a
        /// user-edited rule silently matches nothing, and a rule that quietly
        /// does nothing is worse than one that cannot be expressed.
        public var titleContains: String?

        public init(
            mediaKind: MediaKind? = nil, resolution: Resolution? = nil,
            titleContains: String? = nil
        ) {
            self.mediaKind = mediaKind
            self.resolution = resolution
            self.titleContains = titleContains
        }

        func matches(_ metadata: ReleaseMetadata) -> Bool {
            if let mediaKind, metadata.mediaKind != mediaKind { return false }
            if let resolution, metadata.resolution != resolution { return false }
            if let titleContains, !titleContains.isEmpty {
                guard let title = metadata.title,
                      title.localizedCaseInsensitiveContains(titleContains)
                else { return false }
            }
            return true
        }
    }

    public var id: UUID
    public var match: Match
    public var subfolder: String

    public init(id: UUID = UUID(), match: Match, subfolder: String) {
        self.id = id
        self.match = match
        self.subfolder = subfolder
    }

    /// The shipped defaults (§9).
    public static let defaults: [RoutingRule] = [
        RoutingRule(match: .init(mediaKind: .movie), subfolder: "Movies"),
        RoutingRule(match: .init(mediaKind: .tv), subfolder: "TV Shows"),
        RoutingRule(match: .init(mediaKind: .anime), subfolder: "Anime"),
        RoutingRule(match: .init(mediaKind: .music), subfolder: "Music"),
        RoutingRule(match: .init(mediaKind: .book), subfolder: "Books"),
    ]
}

public enum Routing {
    public static let fallbackSubfolder = "Other"

    /// First matching rule's subfolder, or the fallback.
    ///
    /// The result is sanitized: a rule is user-editable text that becomes a
    /// path component, so `../..` in one must not reach disk.
    public static func subfolder(
        for metadata: ReleaseMetadata, rules: [RoutingRule]
    ) -> String {
        let raw = rules.first { $0.match.matches(metadata) }?.subfolder ?? fallbackSubfolder
        let cleaned = raw
            .split(separator: "/")
            .map { PathSanitizer.sanitize(component: String($0)) }
            .filter { !$0.isEmpty && $0 != ".." && $0 != "." }
            .joined(separator: "/")
        return cleaned.isEmpty ? fallbackSubfolder : cleaned
    }
}

/// Renders a filename from metadata.
///
/// Rendering is **total**: it degrades rather than failing, because a naming
/// strategy that can throw would leave a downloaded file with nowhere to go.
public enum NameTemplate {
    /// Substitutes `{Field}` and `{Field:00}` tokens.
    ///
    /// An unresolved token takes its surrounding bracketed segment with it
    /// rather than emitting a literal `{Year}`, and separators left stranded
    /// collapse — otherwise names come out as `Dune () [ ]` or `Dune  - .mkv`.
    /// Returns nil when nothing at all resolved.
    public static func render(_ template: String, metadata: ReleaseMetadata) -> String? {
        var output = template
        var resolvedAny = false

        for (token, value) in values(of: metadata) {
            // Padded form first: `{Season:00}` must not be eaten by `{Season}`.
            let padded = "{\(token):00}"
            if output.contains(padded) {
                output = output.replacingOccurrences(
                    of: padded, with: value.padded(to: 2))
                resolvedAny = true
            }
            let plain = "{\(token)}"
            if output.contains(plain) {
                output = output.replacingOccurrences(of: plain, with: value.text)
                resolvedAny = true
            }
        }

        // Anything still bracketed had no value: drop the token and any
        // wrapper it sat inside.
        output = dropUnresolvedSegments(from: output)
        output = collapseSeparators(output)

        let trimmed = output.trimmingCharacters(in: .whitespaces)
        return resolvedAny && !trimmed.isEmpty ? trimmed : nil
    }

    private struct Value {
        let text: String
        func padded(to width: Int) -> String {
            guard let number = Int(text) else { return text }
            return String(format: "%0\(width)d", number)
        }
    }

    private static func values(of metadata: ReleaseMetadata) -> [(String, Value)] {
        var pairs: [(String, Value)] = []
        func add(_ token: String, _ text: String?) {
            guard let text, !text.isEmpty else { return }
            pairs.append((token, Value(text: text)))
        }

        add("Title", metadata.title)
        add("Year", metadata.year.map(String.init))
        add("Season", metadata.season.map(String.init))
        add("Episode", metadata.episodes.first.map(String.init))
        add("Absolute", metadata.absoluteEpisode.map(String.init))
        add("EpisodeTitle", metadata.episodeTitle)
        add("Resolution", encoded(metadata.resolution))
        add("Source", encoded(metadata.source))
        add("VideoCodec", encoded(metadata.videoCodec))
        add("AudioCodec", encoded(metadata.audioCodec))
        add("ReleaseGroup", metadata.releaseGroup)
        add("Artist", metadata.artist)
        add("Album", metadata.album)
        add("Author", metadata.author)
        return pairs
    }

    private static func encoded<T: Encodable>(_ value: T?) -> String? {
        guard let value,
              let data = try? JSONEncoder().encode([value]),
              let decoded = try? JSONDecoder().decode([String].self, from: data)
        else { return nil }
        return decoded.first
    }

    /// Removes any `{...}` that survived substitution, along with a bracket
    /// pair or parentheses immediately wrapping it.
    private static func dropUnresolvedSegments(from text: String) -> String {
        var output = text
        for pattern in [#"\s*\[[^\]]*\{[^}]*\}[^\]]*\]"#,
                        #"\s*\([^)]*\{[^}]*\}[^)]*\)"#,
                        #"\{[^}]*\}"#] {
            output = output.replacingOccurrences(
                of: pattern, with: "", options: .regularExpression)
        }
        return output
    }

    private static func collapseSeparators(_ text: String) -> String {
        var output = text
        for (pattern, replacement) in [
            (#"\s{2,}"#, " "),          // doubled spaces
            (#"\s*-\s*-\s*"#, " - "),   // stranded dashes
            (#"^\s*[-–]\s*"#, ""),      // leading separator
            (#"\s*[-–]\s*$"#, ""),      // trailing separator
            (#"\(\s*\)"#, ""),          // empty parens
            (#"\[\s*\]"#, ""),          // empty brackets
        ] {
            output = output.replacingOccurrences(
                of: pattern, with: replacement, options: .regularExpression)
        }
        return output.trimmingCharacters(in: .whitespaces)
    }
}

/// How a downloaded file is named (§9).
public enum NamingStrategy: Sendable, Codable, Equatable {
    /// The provider's filename, sanitized and otherwise untouched.
    case preserveOriginal
    case template(String)

    /// Templates may contain `/` — M4's acceptance criterion is a season pack
    /// filing each episode under `{Series}/Season NN/`, which a single
    /// component cannot express. Each component is sanitized separately.
    public static func defaultTemplate(for kind: MediaKind) -> String {
        switch kind {
        case .tv: "{Title}/Season {Season:00}/{Title} - S{Season:00}E{Episode:00}"
        case .anime: "{Title}/{Title} - {Absolute:00} [{ReleaseGroup}]"
        case .music: "{Artist}/{Album}/{Title}"
        case .book: "{Author}/{Title}"
        default: "{Title} ({Year})/{Title} ({Year}) [{Resolution}]"
        }
    }

    /// The final filename, or the original when the parse is too weak to
    /// justify renaming.
    ///
    /// **This gate is the whole reason `ReleaseMetadata` tracks provenance.**
    /// A movie needs a title and a year, TV needs title, season and episode,
    /// and each must have come from this file's own name or an indexer
    /// attribute. `.inherited` does not count: a season pack's torrent-level
    /// title says nothing about which episode a given file holds, and trusting
    /// it turns twelve episodes into twelve copies of one name.
    public func filename(
        for metadata: ReleaseMetadata, originalFilename: String
    ) -> String? {
        relativePath(for: metadata, originalFilename: originalFilename)
            .map { ($0 as NSString).lastPathComponent }
    }

    /// The path relative to the routed subfolder, which may contain folders.
    ///
    /// A weak parse returns the original filename unchanged **and flat** —
    /// inventing a folder for a file that could not be identified is worse
    /// than not renaming it at all.
    public func relativePath(
        for metadata: ReleaseMetadata, originalFilename: String
    ) -> String? {
        let ext = (originalFilename as NSString).pathExtension

        switch self {
        case .preserveOriginal:
            return originalFilename
        case .template(let template):
            guard isConfident(metadata),
                  let rendered = NameTemplate.render(template, metadata: metadata)
            else { return originalFilename }

            // Sanitized per component, so a title containing a separator
            // cannot invent an extra directory level or climb out of one.
            let components = rendered
                .split(separator: "/")
                .map { PathSanitizer.sanitize(component: String($0)) }
                .filter { !$0.isEmpty }
            guard let leaf = components.last else { return originalFilename }

            // The extension comes from the actual file, never the template: a
            // renamed .mkv that becomes .mp4 will not play.
            let named = ext.isEmpty ? leaf : "\(leaf).\(ext)"
            return (components.dropLast() + [named]).joined(separator: "/")
        }
    }

    private func isConfident(_ metadata: ReleaseMetadata) -> Bool {
        func known(_ field: MetadataField) -> Bool {
            switch metadata.provenance[field] {
            case .attribute, .titleParse: true
            // Inherited from the torrent, so not evidence about this file.
            case .inherited, nil: false
            }
        }

        switch metadata.mediaKind {
        case .tv, .anime:
            return known(.title) && known(.season) && known(.episodes)
                && metadata.season != nil && !metadata.episodes.isEmpty
        case .music:
            return known(.title) && known(.artist)
        case .book:
            return known(.title) && known(.author)
        default:
            return known(.title) && known(.year)
                && metadata.title != nil && metadata.year != nil
        }
    }
}

/// Names every file in a torrent, using two-level parsing (§8).
///
/// Each file is parsed on its own name first, then inherits what it did not
/// determine from the torrent-level parse. That is what lets a season pack
/// name each episode individually — the torrent supplies series, season and
/// quality, the filename supplies the episode.
///
/// Without it every file in the pack renders the same name, so twelve episodes
/// collapse onto one path and eleven are lost. Inherited fields are marked
/// `.inherited`, which the confidence gate refuses to count, so a file whose
/// own name says nothing keeps its original name instead of colliding.
public enum FileRenamer {
    /// Returns nil for a file that should keep the debrid's own path.
    public static func plan(
        torrentMetadata: ReleaseMetadata, strategy: NamingStrategy
    ) -> @Sendable (DebridFile) -> String? {
        guard case .template = strategy else { return { _ in nil } }

        return { file in
            let leaf = (file.name as NSString).lastPathComponent

            // A companion is not the release and must not be renamed as though
            // it were — an .nfo or a sample clip must not become the thing a
            // folder is named after (§8).
            guard !CompanionFileFilter.isNonMediaCompanion(fileName: leaf) else { return nil }

            let merged = ReleaseMetadataMerger.mergingFile(
                ReleaseNameParser.parse(leaf), inheritingFrom: torrentMetadata)

            let renamed = strategy.relativePath(for: merged, originalFilename: leaf)
            // Unchanged means the parse was too weak; let the engine use the
            // original path rather than flattening the torrent's structure.
            return renamed == leaf ? nil : renamed
        }
    }
}

/// Undoing a rename (§9: "renaming is always reversible").
///
/// Both sides are recomputed through `DestinationResolver` rather than stored
/// as absolute paths, so a revert cannot write outside the download directory
/// even if the stored relative path is hostile — the same guarantee the
/// original write had.
public enum RenameReversal {
    public struct Plan: Equatable, Sendable {
        public let from: URL
        public let to: URL
    }

    /// Nil when there is nothing to undo, so the action can be hidden rather
    /// than offered as a no-op that looks like it worked.
    public static func plan(for request: DownloadRequest) -> Plan? {
        guard let renamedPath = request.renamedPath, renamedPath != request.file.name,
              let from = try? DestinationResolver.resolve(
                root: request.destinationRoot, subfolder: request.subfolder,
                relativePath: renamedPath),
              let to = try? DestinationResolver.resolve(
                root: request.destinationRoot, subfolder: request.subfolder,
                relativePath: request.file.name),
              from != to
        else { return nil }

        return Plan(from: from, to: to)
    }
}
