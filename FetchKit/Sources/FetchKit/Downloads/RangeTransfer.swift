import Foundation

/**
 Streams one file to a `.fetchpart` file using HTTP range requests.

 The resume offset is the size of the partial file on disk, never an opaque
 resume blob. That is what lets a paused download survive both app quit and
 the debrid's 3-hour link expiry: on resume we request a *fresh* link and
 continue from the same byte.

 Callers must ensure at most one in-flight `transfer(to:)` per partial URL —
 the actor serializes its own state, not the file.
 */
public actor RangeTransfer {
    private let body: ChunkedBody

    public init(body: ChunkedBody = ChunkedBody()) {
        self.body = body
    }

    public func transfer(
        to partialURL: URL,
        expectedSize: Int64,
        linkProvider: @Sendable () async throws -> URL,
        onProgress: @Sendable (Int64) -> Void
    ) async throws {
        var relinkAttempted = false
        var restartedFromZero = false

        while true {
            var offset = Self.fileSize(at: partialURL)

            if expectedSize > 0, offset > expectedSize {
                try Data().write(to: partialURL)
                offset = 0
            } else if expectedSize > 0, offset == expectedSize {
                try Self.verify(partialURL, expectedSize: expectedSize)
                return
            }

            let url = try await linkProvider()
            var request = URLRequest(url: url)
            if offset > 0 {
                request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
            }

            let stream = try await body.fetch(request)
            let http = stream.head

            if http.statusCode == 403 || http.statusCode == 410 {
                guard !relinkAttempted else { throw DownloadError.linkExpired }
                relinkAttempted = true
                continue
            }

            if http.statusCode == 416 {
                try Self.verify(partialURL, expectedSize: expectedSize)
                return
            }

            guard (200...299).contains(http.statusCode) else {
                throw DownloadError.network("HTTP \(http.statusCode)")
            }

            if http.statusCode == 206, offset > 0 {
                guard let declared = Self.contentRangeStart(http), declared == offset else {
                    try Data().write(to: partialURL)
                    guard !restartedFromZero else {
                        throw DownloadError.rangeNotSupported(status: http.statusCode)
                    }
                    restartedFromZero = true
                    continue
                }
            }

            var writeOffset = offset
            if http.statusCode == 200 && offset > 0 {
                try Data().write(to: partialURL)
                writeOffset = 0
            }

            try Self.ensureFileExists(at: partialURL)
            let handle = try FileHandle(forWritingTo: partialURL)
            try handle.seek(toOffset: UInt64(writeOffset))
            defer { try? handle.close() }

            var written = writeOffset
            for try await chunk in stream.chunks {
                guard !chunk.isEmpty else { continue }
                try handle.write(contentsOf: chunk)
                written += Int64(chunk.count)
                onProgress(written)
            }
            try handle.close()

            try Self.verify(partialURL, expectedSize: expectedSize)
            return
        }
    }


    static func contentRangeStart(_ response: ChunkedBody.Head) -> Int64? {
        guard let raw = response.value(forHeader: "Content-Range"),
              let unitsRange = raw.range(of: "bytes ")
        else { return nil }
        let rest = raw[unitsRange.upperBound...]
        guard let dash = rest.firstIndex(of: "-") else { return nil }
        return Int64(rest[rest.startIndex..<dash].trimmingCharacters(in: .whitespaces))
    }

    static func fileSize(at url: URL) -> Int64 {
        FileSize.of(url) ?? 0
    }

    private static func ensureFileExists(at url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if !fm.fileExists(atPath: url.path) {
            guard fm.createFile(atPath: url.path, contents: nil) else {
                throw DownloadError.destinationUnwritable(path: url.path)
            }
        }
    }

    private static func verify(_ url: URL, expectedSize: Int64) throws {
        guard expectedSize > 0 else { return }
        let actual = fileSize(at: url)
        guard actual == expectedSize else {
            throw DownloadError.sizeMismatch(expected: expectedSize, actual: actual)
        }
    }
}
