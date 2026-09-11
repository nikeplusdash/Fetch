import Foundation
import Testing
@testable import FetchKit

@Suite struct InfoHashTests {
    static let hex40 = "dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c"

    @Test func acceptsLowercaseHex() {
        #expect(InfoHash(Self.hex40)?.hex == Self.hex40)
    }

    @Test func uppercaseHexNormalizesToLowercase() {
        #expect(InfoHash(Self.hex40.uppercased())?.hex == Self.hex40)
    }

    @Test func acceptsBase32AndConvertsToHex() {
        let b32 = "3WBFL3G4PSSV7MF37AJSHWDQMLNR63I4"
        #expect(InfoHash(b32)?.hex == Self.hex40)
    }

    @Test func base32IsCaseInsensitive() {
        let b32 = "3wbfl3g4pssv7mf37ajshwdqmlnr63i4"
        #expect(InfoHash(b32)?.hex == Self.hex40)
    }

    @Test(arguments: [
        "",
        "dd8255ecdc7ca55fb0bbf81323d87062db1f6d",
        "dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c00",
        "zz8255ecdc7ca55fb0bbf81323d87062db1f6d1c",
        "3WBFL3G4PSSV7MF36AJSHWDQMLNR63I",
        "3WBFL3G4PSSV7MF36AJSHWDQMLNR6318",
        "\u{FF10}d8255ecdc7ca55fb0bbf81323d87062db1f6d1c",
    ]) func rejectsInvalid(_ raw: String) {
        #expect(InfoHash(raw) == nil)
    }

    @Test func equalityIgnoresOriginalCasing() {
        #expect(InfoHash(Self.hex40) == InfoHash(Self.hex40.uppercased()))
    }

    @Test func roundTripsThroughCodable() throws {
        let original = InfoHash(Self.hex40)!
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(InfoHash.self, from: data) == original)
    }
}
