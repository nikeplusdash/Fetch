import Foundation

/**
 One thing already in a debrid account, as any provider reports it.

 `origin` keeps a torrent and a web download distinct so playback and
 download route to the right pair of methods without inspecting the id —
 the two id spaces are provider-chosen and nothing says they cannot
 overlap, which is also why `id` carries a kind marker.

 `files` may arrive empty from a list call — Real-Debrid's listing carries
 none — and is filled lazily by the screen that needs them. An empty
 `files` therefore means "not asked yet", never "no files".
 */
public struct DebridCloudItem: Sendable, Equatable, Identifiable {
    public enum Origin: Sendable, Equatable, Codable {
        case torrent(DebridTorrentID)
        case web(DebridDownloadID)
    }

    public let provider: DebridProviderID
    public let origin: Origin
    public let name: String
    public let size: Int64

    /**
     The dedup key across services when present, and nil for a web
     download, which has no torrent to be the same as.
     */
    public let infoHashHex: String?

    public let addedAt: Date?
    public let files: [DebridFile]

    public init(
        provider: DebridProviderID, origin: Origin, name: String, size: Int64,
        infoHashHex: String?, addedAt: Date?, files: [DebridFile]
    ) {
        self.provider = provider
        self.origin = origin
        self.name = name
        self.size = size
        self.infoHashHex = infoHashHex
        self.addedAt = addedAt
        self.files = files
    }

    public var id: String {
        switch origin {
        case .torrent(let torrent): "\(provider.rawValue):t:\(torrent.rawValue)"
        case .web(let web): "\(provider.rawValue):w:\(web.rawValue)"
        }
    }

    public func replacingFiles(_ files: [DebridFile]) -> DebridCloudItem {
        DebridCloudItem(
            provider: provider, origin: origin, name: name, size: size,
            infoHashHex: infoHashHex, addedAt: addedAt, files: files)
    }
}
