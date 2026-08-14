import Foundation

enum Base32 {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
    private static let lookup: [Character: UInt8] = {
        var dict = [Character: UInt8]()
        for (i, c) in alphabet.enumerated() { dict[c] = UInt8(i) }
        return dict
    }()

    /// RFC 4648 base32 decode, no padding expected. Returns nil on any
    /// character outside the alphabet.
    static func decode(_ input: String) -> Data? {
        var bits = 0
        var accumulator: UInt32 = 0
        var out = Data()

        for character in input.uppercased() {
            guard let value = lookup[character] else { return nil }
            accumulator = (accumulator << 5) | UInt32(value)
            bits += 5
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((accumulator >> UInt32(bits)) & 0xFF))
            }
        }
        return out
    }
}
