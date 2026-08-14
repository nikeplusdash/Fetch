import Foundation
import CryptoKit

/// A BitTorrent v1 info hash, always normalized to lowercase 40-char hex.
///
/// Accepts 40-char hex in any case, or 32-char RFC 4648 base32 (which some
/// indexers emit). Rejects everything else — there are no lossy fallbacks,
/// because a silently-wrong hash produces a cache badge that is wrong rather
/// than an error that is visible.
public struct InfoHash: Hashable, Sendable, Codable, CustomStringConvertible {
    public let hex: String

    public init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // NOT Character.isHexDigit: it accepts Unicode fullwidth digits
        // (U+FF10 etc.), which .lowercased() does not normalize to ASCII.
        if trimmed.count == 40, trimmed.utf8.allSatisfy(Self.isASCIIHexDigit) {
            self.hex = trimmed.lowercased()
            return
        }

        if trimmed.count == 32, let data = Base32.decode(trimmed), data.count == 20 {
            self.hex = data.map { String(format: "%02x", $0) }.joined()
            return
        }

        return nil
    }

    public var description: String { hex }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let parsed = InfoHash(raw) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Not a valid info hash: \(raw)"
            ))
        }
        self = parsed
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }

    private static func isASCIIHexDigit(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte)      // 0-9
            || (0x41...0x46).contains(byte)   // A-F
            || (0x61...0x66).contains(byte)   // a-f
    }
}

extension InfoHash {
    /// Lowercase hex SHA-1 of `data`.
    ///
    /// A torrent's infohash is defined as the SHA-1 of its bencoded `info`
    /// dictionary, which is what makes a fetched `.torrent` checkable against
    /// the hash that was requested. SHA-1 is weak, but it is not a security
    /// choice here — it is the identifier BitTorrent defines.
    public static func sha1Hex(_ data: Data) -> String {
        Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
