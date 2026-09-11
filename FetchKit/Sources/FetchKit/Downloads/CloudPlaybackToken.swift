import Foundation
import FetchPluginAPI

/**
 What a `PlaylistSource.cloud(token:)` string carries.

 Base64-of-JSON rather than a delimited string, because provider-chosen
 torrent and file ids contain `:` and `/` — Real-Debrid's are opaque
 strings and Premiumize's are paths in all but name — and any separator
 could collide with one. The encoding is this app's own on both sides;
 nothing else ever reads it.

 `init?(encoded:)` returns nil rather than trapping on anything this app
 did not write, which is what lets a stale token in a playlist be dropped
 as one unreachable file rather than take the player down with it.
 */
public struct CloudPlaybackToken: Sendable, Equatable, Codable {
    public let provider: DebridProviderID
    public let origin: DebridCloudItem.Origin
    public let file: DebridFileID

    public init(
        provider: DebridProviderID, origin: DebridCloudItem.Origin, file: DebridFileID
    ) {
        self.provider = provider
        self.origin = origin
        self.file = file
    }

    public func encoded() -> String {
        (try? JSONEncoder().encode(self))?.base64EncodedString() ?? ""
    }

    public init?(encoded: String) {
        guard let data = Data(base64Encoded: encoded),
              let token = try? JSONDecoder().decode(Self.self, from: data)
        else { return nil }
        self = token
    }
}
