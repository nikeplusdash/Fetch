import Foundation

/// Distinct identifier types so a file ID can never be passed where a torrent
/// ID belongs. Each encodes as its bare raw value, not as a wrapper object.
public struct DebridProviderID: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(from d: any Decoder) throws {
        rawValue = try d.singleValueContainer().decode(String.self)
    }
    public func encode(to e: any Encoder) throws {
        var c = e.singleValueContainer(); try c.encode(rawValue)
    }
}

public struct SearchProviderID: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(from d: any Decoder) throws {
        rawValue = try d.singleValueContainer().decode(String.self)
    }
    public func encode(to e: any Encoder) throws {
        var c = e.singleValueContainer(); try c.encode(rawValue)
    }
}

public struct DebridTorrentID: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(from d: any Decoder) throws {
        rawValue = try d.singleValueContainer().decode(String.self)
    }
    public func encode(to e: any Encoder) throws {
        var c = e.singleValueContainer(); try c.encode(rawValue)
    }
}

public struct DebridFileID: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(from d: any Decoder) throws {
        rawValue = try d.singleValueContainer().decode(String.self)
    }
    public func encode(to e: any Encoder) throws {
        var c = e.singleValueContainer(); try c.encode(rawValue)
    }
}

public struct DownloadID: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init() { self.rawValue = UUID() }
    public init(from d: any Decoder) throws {
        let raw = try d.singleValueContainer().decode(String.self)
        guard let uuid = UUID(uuidString: raw) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: d.codingPath, debugDescription: "Not a UUID: \(raw)"))
        }
        rawValue = uuid
    }
    public func encode(to e: any Encoder) throws {
        var c = e.singleValueContainer(); try c.encode(rawValue.uuidString)
    }
}

/// A file-hosting service a debrid can unrestrict — "mediafire", "mega",
/// "1fichier". Distinct from `DebridProviderID`: the host is where the file
/// lives, the provider is who fetches it.
public struct HostID: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(from d: any Decoder) throws {
        rawValue = try d.singleValueContainer().decode(String.self)
    }
    public func encode(to e: any Encoder) throws {
        var c = e.singleValueContainer(); try c.encode(rawValue)
    }
}

/// A web download queued at a debrid — the hosted-link counterpart of
/// `DebridTorrentID`.
public struct DebridDownloadID: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(from d: any Decoder) throws {
        rawValue = try d.singleValueContainer().decode(String.self)
    }
    public func encode(to e: any Encoder) throws {
        var c = e.singleValueContainer(); try c.encode(rawValue)
    }
}

/// A file-hosting service a debrid can unrestrict, as that debrid reports it
/// (amendment §5, 7e §3.1).
///
/// Coverage is a property of the *debrid*: a user with TorBox and Real-Debrid
/// has two of these lists, and a Rapidgator link may be reachable through one
/// and not the other.
public struct DebridHost: Sendable, Codable, Hashable {
    public let id: HostID
    public let displayName: String
    /// Registrable domains this host serves from, e.g. `["1fichier.com",
    /// "alterupload.com"]`.
    public let domains: [String]
    /// A provider may report a host it normally supports as temporarily down.
    public let isActive: Bool

    public init(id: HostID, displayName: String, domains: [String], isActive: Bool = true) {
        self.id = id
        self.displayName = displayName
        self.domains = domains
        self.isActive = isActive
    }

    /// Whether this host serves `url`.
    ///
    /// **Matched on label boundaries, never as a substring.**
    /// `evil-mediafire.com` contains `mediafire.com`, and treating that as a
    /// match would hand an attacker-chosen URL to the user's debrid account.
    /// The same rule `HTTPClient` applies to its allowlist, and the same
    /// correction the recurring-failure list records for paths: decide on
    /// where the value lands, not on what the string contains.
    ///
    /// `isActive` is deliberately **not** consulted here. Whether a host
    /// serves a URL and whether it is currently up are two questions, and
    /// merging them would make "MediaFire, reported down" indistinguishable
    /// from "not MediaFire".
    public func matches(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        return domains.contains { domain in
            let domain = domain.lowercased()
            return host == domain || host.hasSuffix("." + domain)
        }
    }
}

/// One web download at a debrid — the hosted-link counterpart of
/// `DebridTorrent`.
///
/// `DebridTorrentState` is reused rather than duplicated: a web download
/// queues, downloads, completes and errors exactly as a torrent does, and §5's
/// framing is "mirrors the torrent family". A parallel enum would be two
/// vocabularies for one set of facts.
public struct DebridWebDownload: Sendable, Equatable {
    public let id: DebridDownloadID
    public let name: String
    public let size: Int64?
    public let progress: Double
    public let state: DebridTorrentState
    public let files: [DebridFile]

    public init(
        id: DebridDownloadID, name: String, size: Int64?, progress: Double,
        state: DebridTorrentState, files: [DebridFile]
    ) {
        self.id = id
        self.name = name
        self.size = size
        self.progress = progress
        self.state = state
        self.files = files
    }
}
