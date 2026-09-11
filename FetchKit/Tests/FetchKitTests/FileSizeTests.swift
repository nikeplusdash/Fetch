import Testing
import Foundation
@testable import FetchKit

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

    @Test func aSecondReadOfTheSameURLSeesTheFileGrow() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }

        try Data(repeating: 0x01, count: 400).write(to: url)
        #expect(FileSize.of(url) == 400)

        try Data(repeating: 0x01, count: 1000).write(to: url)
        #expect(FileSize.of(url) == 1000)
    }

    @Test func aSecondReadNoticesTheFileIsGone() throws {
        let url = temporaryFile()
        try Data(repeating: 0x01, count: 10).write(to: url)
        #expect(FileSize.of(url) == 10)

        try FileManager.default.removeItem(at: url)
        #expect(FileSize.of(url) == nil)
    }

    @Test func extendedAttributesAreNotRead() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 0x01, count: 64).write(to: url)

        let value = [UInt8](repeating: 0x7F, count: 4096)
        _ = value.withUnsafeBufferPointer { buffer in
            setxattr(url.path, "com.fetch.test", buffer.baseAddress, buffer.count, 0, 0)
        }

        #expect(FileSize.of(url) == 64)
    }
}
