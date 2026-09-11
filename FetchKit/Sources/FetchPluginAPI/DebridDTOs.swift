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

/**
 Forward-compatible: an unrecognized provider state round-trips as
 `.unknown` rather than trapping or silently becoming nil.
 */
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

    public var isReady: Bool { self == .completed }
}

public struct DebridTorrent: Sendable, Codable, Equatable {
    public let apiVersion: Int
    public let id: DebridTorrentID
    public let infoHashHex: String
    public let name: String
    public let size: Int64
    public let progress: Double
    public let state: DebridTorrentState
    public let files: [DebridFile]
    public let seeds: Int?
    public let downloadSpeed: Int64?
    public let eta: TimeInterval?

    public let filesArePresent: Bool

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
