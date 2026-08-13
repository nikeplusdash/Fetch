import Testing
import Foundation
@testable import FetchKit

/// Measuring a file, without the two traps the obvious answers carry.
@Suite struct FileSizeTests {
    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("size-\(UUID().uuidString).bin")
    }

    @Test func itReportsTheSizeOfAFile() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 0x01, count: 1234).write(to: url)

        #expect(FileSize.of(url) == 1234)
    }

    @Test func anAbsentFileHasNoSize() {
        #expect(FileSize.of(temporaryFile()) == nil)
    }

    @Test func aDirectoryHasNoSize() {
        #expect(FileSize.of(FileManager.default.temporaryDirectory) == nil)
    }

    @Test func anEmptyFileIsZeroNotAbsent() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data().write(to: url)

        #expect(FileSize.of(url) == 0)
    }

    /// **The trap that made this a type rather than a one-liner.**
    ///
    /// `URL.resourceValues(forKeys:)` caches what it fetched onto the `URL`,
    /// so reading the same URL value twice returns the first answer even after
    /// the file has grown. `RangeTransfer` reads its partial's size once per
    /// pass around its loop precisely because it *is* changing — a cached read
    /// makes a resume compute its offset from a stale length.
    @Test func aSecondReadOfTheSameURLSeesTheFileGrow() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }

        try Data(repeating: 0x01, count: 400).write(to: url)
        #expect(FileSize.of(url) == 400)

        try Data(repeating: 0x01, count: 1000).write(to: url)
        #expect(FileSize.of(url) == 1000)
    }

    /// And it must notice a file going away, for the same reason.
    @Test func aSecondReadNoticesTheFileIsGone() throws {
        let url = temporaryFile()
        try Data(repeating: 0x01, count: 10).write(to: url)
        #expect(FileSize.of(url) == 10)

        try FileManager.default.removeItem(at: url)
        #expect(FileSize.of(url) == nil)
    }

    /// The whole reason this exists: `FileManager.attributesOfItem` builds a
    /// dictionary that includes the file's **extended attributes**, so asking
    /// for a size issues a `getxattr` — which can block in the kernel
    /// indefinitely and did, on Fetch's launch path, before the first window.
    /// A file with a large xattr is measured here as cheaply as one without.
    @Test func extendedAttributesAreNotRead() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 0x01, count: 64).write(to: url)

        let value = [UInt8](repeating: 0x7F, count: 4096)
        _ = value.withUnsafeBufferPointer { buffer in
            setxattr(url.path, "com.fetch.test", buffer.baseAddress, buffer.count, 0, 0)
        }

        // The size is the file's, never the file's plus anything hanging off it.
        #expect(FileSize.of(url) == 64)
    }
}
