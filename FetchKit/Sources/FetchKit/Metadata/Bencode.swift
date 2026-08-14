import Foundation
import CryptoKit

/// A bencode value — the format `.torrent` files use.
///
/// §16 put bencode parsing out of scope for v1. Reversed deliberately: it is
/// the only way to list a torrent's files without either adding it to a debrid
/// account or joining the swarm. Joining the swarm is the one option a debrid
/// client must never take, since it would expose the user's IP to every peer
/// sharing the torrent — precisely what paying for a debrid avoids.
public indirect enum Bencode: Equatable, Sendable {
    case integer(Int64)
    /// Raw bytes: a torrent's `pieces` field is concatenated SHA-1 digests,
    /// not text, so decoding every string as UTF-8 would fail on real input.
    case bytes(Data)
    case list([Bencode])
    case dictionary([String: Bencode])

    public var integer: Int64? { if case .integer(let value) = self { value } else { nil } }
    public var bytes: Data? { if case .bytes(let value) = self { value } else { nil } }
    public var list: [Bencode]? { if case .list(let value) = self { value } else { nil } }
    public var dictionary: [String: Bencode]? {
        if case .dictionary(let value) = self { value } else { nil }
    }

    /// UTF-8 interpretation, or nil when the bytes are not text.
    public var string: String? {
        guard case .bytes(let data) = self else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Parses one complete value. Returns nil on anything malformed.
    ///
    /// This parses bytes fetched over the network, so it treats every input as
    /// hostile: no force-unwraps, no reads past the buffer, bounded nesting,
    /// and length prefixes validated before allocating anything.
    public static func parse(_ data: Data) -> Bencode? {
        var cursor = 0
        let bytes = [UInt8](data)
        guard let value = parseValue(bytes, &cursor, depth: 0) else { return nil }
        // Trailing junk means the input was not what it claimed to be.
        guard cursor == bytes.count else { return nil }
        return value
    }

    /// Byte range of the top-level `info` dictionary's value.
    ///
    /// Needed because a torrent's infohash is the SHA-1 of exactly these
    /// bytes — re-encoding the parsed structure would not reproduce them, since
    /// bencode is only canonical if you preserve the original ordering and
    /// formatting. Locating the original slice is the only correct way.
    public static func infoDictionaryRange(in data: Data) -> Range<Int>? {
        let bytes = [UInt8](data)
        var cursor = 0
        guard cursor < bytes.count, bytes[cursor] == UInt8(ascii: "d") else { return nil }
        cursor += 1

        while cursor < bytes.count, bytes[cursor] != UInt8(ascii: "e") {
            guard let key = parseBytes(bytes, &cursor)?.string else { return nil }
            let start = cursor
            guard parseValue(bytes, &cursor, depth: 0) != nil else { return nil }
            if key == "info" { return start..<cursor }
        }
        return nil
    }

    /// Torrents nest a handful of levels; anything approaching this is an
    /// attempt to blow the stack rather than a real file.
    private static let maxDepth = 64

    private static func parseValue(_ bytes: [UInt8], _ cursor: inout Int, depth: Int) -> Bencode? {
        guard depth <= maxDepth, cursor < bytes.count else { return nil }

        switch bytes[cursor] {
        case UInt8(ascii: "i"): return parseInteger(bytes, &cursor)
        case UInt8(ascii: "l"): return parseList(bytes, &cursor, depth: depth)
        case UInt8(ascii: "d"): return parseDictionary(bytes, &cursor, depth: depth)
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return parseBytes(bytes, &cursor)
        default: return nil
        }
    }

    private static func parseInteger(_ bytes: [UInt8], _ cursor: inout Int) -> Bencode? {
        cursor += 1                                   // 'i'
        var digits = ""
        while cursor < bytes.count, bytes[cursor] != UInt8(ascii: "e") {
            digits.append(Character(UnicodeScalar(bytes[cursor])))
            cursor += 1
        }
        guard cursor < bytes.count, let value = Int64(digits) else { return nil }
        cursor += 1                                   // 'e'
        return .integer(value)
    }

    private static func parseBytes(_ bytes: [UInt8], _ cursor: inout Int) -> Bencode? {
        var digits = ""
        while cursor < bytes.count, bytes[cursor] != UInt8(ascii: ":") {
            digits.append(Character(UnicodeScalar(bytes[cursor])))
            cursor += 1
        }
        // `Int` rather than `Int64`, so a length that cannot index this buffer
        // is rejected here rather than after an enormous allocation.
        guard cursor < bytes.count, let length = Int(digits), length >= 0 else { return nil }
        cursor += 1                                   // ':'

        guard length <= bytes.count - cursor else { return nil }
        let slice = Data(bytes[cursor..<(cursor + length)])
        cursor += length
        return .bytes(slice)
    }

    private static func parseList(_ bytes: [UInt8], _ cursor: inout Int, depth: Int) -> Bencode? {
        cursor += 1                                   // 'l'
        var items: [Bencode] = []
        while cursor < bytes.count, bytes[cursor] != UInt8(ascii: "e") {
            guard let item = parseValue(bytes, &cursor, depth: depth + 1) else { return nil }
            items.append(item)
        }
        guard cursor < bytes.count else { return nil }
        cursor += 1                                   // 'e'
        return .list(items)
    }

    private static func parseDictionary(
        _ bytes: [UInt8], _ cursor: inout Int, depth: Int
    ) -> Bencode? {
        cursor += 1                                   // 'd'
        var entries: [String: Bencode] = [:]
        while cursor < bytes.count, bytes[cursor] != UInt8(ascii: "e") {
            guard let key = parseBytes(bytes, &cursor)?.string,
                  let value = parseValue(bytes, &cursor, depth: depth + 1)
            else { return nil }
            entries[key] = value
        }
        guard cursor < bytes.count else { return nil }
        cursor += 1                                   // 'e'
        return .dictionary(entries)
    }
}

/// A torrent's name and file list, read from its metadata.
public struct TorrentMetadata: Equatable, Sendable {
    public struct File: Equatable, Sendable {
        /// Relative path within the torrent, matching `DebridFile.name` so a
        /// selection made against this list resolves the same way (§6).
        public let path: String
        public let length: Int64

        public init(path: String, length: Int64) {
            self.path = path
            self.length = length
        }
    }

    public let name: String
    public let files: [File]

    /// Reads a `.torrent`'s `info` dictionary, optionally proving it is the
    /// torrent that was asked for.
    ///
    /// **Verify whenever the bytes came from a third party.** itorrents.org
    /// serves a byte-identical decoy for any unknown hash — confirmed live
    /// against three different hashes — so an unverified fetch would present a
    /// fabricated file list as fact.
    public static func parse(_ data: Data, expectedInfoHash: String? = nil) -> TorrentMetadata? {
        if let expectedInfoHash {
            guard let range = Bencode.infoDictionaryRange(in: data),
                  InfoHash.sha1Hex(data[range]).caseInsensitiveCompare(expectedInfoHash)
                    == .orderedSame
            else { return nil }
        }
        return parse(data)
    }

    private static func parse(_ data: Data) -> TorrentMetadata? {
        guard let root = Bencode.parse(data)?.dictionary,
              let info = root["info"]?.dictionary,
              let name = info["name"]?.string, !name.isEmpty
        else { return nil }

        // Multi-file: `files` is a list of { length, path: [components] }.
        if let entries = info["files"]?.list {
            let files = entries.compactMap { entry -> File? in
                guard let dict = entry.dictionary,
                      let length = dict["length"]?.integer,
                      let components = dict["path"]?.list?.compactMap(\.string),
                      !components.isEmpty
                else { return nil }

                // A path component escaping the torrent root is refused —
                // the same attack `PathSanitizer` guards, arriving from a
                // different direction. Dropping the file is safer than
                // sanitizing it into something the debrid will not match.
                guard components.allSatisfy({ $0 != ".." && $0 != "." && !$0.contains("/") })
                else { return nil }

                return File(path: ([name] + components).joined(separator: "/"), length: length)
            }
            return TorrentMetadata(name: name, files: files)
        }

        // Single-file: `length` sits directly on `info` and `name` is the file.
        guard let length = info["length"]?.integer else { return nil }
        return TorrentMetadata(name: name, files: [File(path: name, length: length)])
    }
}
