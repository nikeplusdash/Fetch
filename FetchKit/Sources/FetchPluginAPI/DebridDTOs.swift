import Foundation

public struct DebridAccount: Sendable, Codable, Equatable {
    public let apiVersion: Int
    public let email: String?
    public let plan: String?
    public let expiresAt: Date?

    public init(email: String?, plan: String?, expiresAt: Date?) {
        self.apiVersion = currentAPIVersion
        self.email = email
        self.plan = plan
        self.expiresAt = expiresAt
    }
}

public struct DebridFile: Sendable, Codable, Equatable, Identifiable {
    public let id: DebridFileID
    /// Full path within the torrent — this is the stable key used to
    /// re-resolve a selection after submission.
    public let name: String
    public let shortName: String
    public let size: Int64
    public let mimeType: String?

    public init(
        id: DebridFileID, name: String, shortName: String,
        size: Int64, mimeType: String?
    ) {
        self.id = id
        self.name = name
        self.shortName = shortName
        self.size = size
        self.mimeType = mimeType
    }
}

public struct CacheEntry: Sendable, Codable, Equatable {
    public let apiVersion: Int
    /// Lowercase 40-char hex. `FetchPluginAPI` cannot import `FetchKit`, so
    /// the boundary carries the string and `FetchKit` maps it to `InfoHash`.
    public let infoHashHex: String
    public let name: String
    public let size: Int64
    public let files: [DebridFile]?

    public init(infoHashHex: String, name: String, size: Int64, files: [DebridFile]?) {
        self.apiVersion = currentAPIVersion
        self.infoHashHex = infoHashHex
        self.name = name
        self.size = size
        self.files = files
    }
}

/// Forward-compatible: an unrecognized provider state round-trips as
/// `.unknown` rather than trapping or silently becoming nil.
public enum DebridTorrentState: Sendable, Codable, Equatable {
    case queued, checking, downloading, uploading, stalled, completed
    case failed(reason: String)
    case unknown(String)

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw.lowercased() {
        case "queued", "queued_download": self = .queued
        case "checking", "metadl", "checkingdl": self = .checking
        case "downloading": self = .downloading
        case "uploading", "seeding": self = .uploading
        case "stalled", "stalleddl", "stalled (no seeds)": self = .stalled
        case "completed", "cached", "uploaded": self = .completed
        case "failed", "error": self = .failed(reason: raw)
        default: self = .unknown(raw)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .queued: try container.encode("queued")
        case .checking: try container.encode("checking")
        case .downloading: try container.encode("downloading")
        case .uploading: try container.encode("uploading")
        case .stalled: try container.encode("stalled")
        case .completed: try container.encode("completed")
        case .failed(let reason): try container.encode(reason)
        case .unknown(let raw): try container.encode(raw)
        }
    }

    /// True when the state alone says the files are downloadable.
    ///
    /// **Not the whole answer** — see `DebridTorrent.isReady`, which is what
    /// callers should ask. TorBox reports `download_state: "uploading"` the
    /// moment a finished torrent starts seeding, and `"stalled (no seeds)"`
    /// while it waits; neither is `.completed`, so a poll that only asked this
    /// could spin forever on a torrent whose files were sitting there ready.
    public var isReady: Bool { self == .completed }
}

public struct DebridTorrent: Sendable, Codable, Equatable {
    public let apiVersion: Int
    public let id: DebridTorrentID
    public let infoHashHex: String
    public let name: String
    public let size: Int64
    public let progress: Double        // 0...1
    public let state: DebridTorrentState
    public let files: [DebridFile]
    public let seeds: Int?
    public let downloadSpeed: Int64?
    public let eta: TimeInterval?

    /// The service says the files are on its side and servable, whatever it
    /// calls the state.
    ///
    /// TorBox has answered this all along as `download_present`, which
    /// `TorBoxProvider` decoded and then dropped on the floor — declared and
    /// never connected, failure mode #1. It matters because TorBox reports a
    /// finished torrent as `uploading` once it starts seeding, so a poll
    /// keyed on `.completed` alone waits for a transition that has already
    /// happened. A provider with nothing to say reports `false` and behaves
    /// exactly as it did before.
    public let filesArePresent: Bool

    /// Whether this torrent's files can be fetched **now**.
    ///
    /// State *or* presence, never state alone — see `filesArePresent`. The
    /// file list must be non-empty either way: a service that says "ready"
    /// and lists nothing has nothing to enqueue, and treating that as ready
    /// produced a torrent with no rows.
    public var isReady: Bool { (state.isReady || filesArePresent) && !files.isEmpty }

    public init(
        id: DebridTorrentID, infoHashHex: String, name: String, size: Int64,
        progress: Double, state: DebridTorrentState, files: [DebridFile],
        seeds: Int?, downloadSpeed: Int64?, eta: TimeInterval?,
        filesArePresent: Bool = false
    ) {
        self.apiVersion = currentAPIVersion
        self.id = id
        self.infoHashHex = infoHashHex
        self.name = name
        self.size = size
        self.progress = progress
        self.state = state
        self.files = files
        self.seeds = seeds
        self.downloadSpeed = downloadSpeed
        self.eta = eta
        self.filesArePresent = filesArePresent
    }
}
