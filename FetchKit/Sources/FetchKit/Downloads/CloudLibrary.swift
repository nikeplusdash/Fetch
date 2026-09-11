import Foundation
import FetchPluginAPI

/**
 One row of the Cloud pill: a thing the user owns, wherever it is held.
 */
public struct CloudRow: Sendable, Equatable, Identifiable {
    /**
     The infohash when there is one, else the representative's own id. Not
     the name: two unrelated releases share a name often enough, and a key
     that collapsed them would hide one behind the other.
     */
    public let key: String

    public let name: String
    public let size: Int64
    public let kind: MediaKind

    /**
     Every service holding this, in preference order. The first is the one
     a play or a download resolves through.
     */
    public let providers: [DebridProviderID]

    /**
     The per-provider originals, in the same order as `providers` except
     where one service holds the same thing twice.
     */
    public let members: [DebridCloudItem]

    public var id: String { key }

    public init(
        key: String, name: String, size: Int64, kind: MediaKind,
        providers: [DebridProviderID], members: [DebridCloudItem]
    ) {
        self.key = key
        self.name = name
        self.size = size
        self.kind = kind
        self.providers = providers
        self.members = members
    }
}

/**
 What every service returned, as one list.

 **Dedup is by infohash, and only by infohash.** The same torrent held on
 two services is one thing the user owns, not two, and it becomes one row
 that remembers every service holding it. Names are not a fallback key:
 Premiumize reports no infohash at all, and collapsing its rows by name
 would merge unrelated releases that happen to share one.

 Order in is provider-preference order, so the first member of a group is
 the preferred service and becomes the row's representative — which is why
 this does no sorting of its own.

 Here rather than in the app for the reason `DownloadLibrary` is: the app
 target has no test bundle, and "which two rows are the same row" is
 exactly the decision that drifts when it lives in a view.
 */
public enum CloudLibrary {
    public static func rows(from items: [DebridCloudItem]) -> [CloudRow] {
        var order: [String] = []
        var groups: [String: [DebridCloudItem]] = [:]

        for item in items {
            let key = item.infoHashHex.map { "btih:" + $0.lowercased() } ?? item.id
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(item)
        }

        return order.compactMap { key in
            guard let members = groups[key], let representative = members.first
            else { return nil }

            var providers: [DebridProviderID] = []
            for member in members where !providers.contains(member.provider) {
                providers.append(member.provider)
            }

            return CloudRow(
                key: key,
                name: representative.name,
                size: representative.size,
                kind: TorrentContentKind.kind(
                    files: representative.files.map(\.name),
                    name: representative.name) ?? .other,
                providers: providers,
                members: members)
        }
    }

    public static func sections(
        _ rows: [CloudRow]
    ) -> [(kind: MediaKind, rows: [CloudRow])] {
        DownloadLibrary.sections(rows, kind: \.kind, name: \.name)
    }
}
