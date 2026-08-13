import Foundation

/// Streams one file to a `.fetchpart` file using HTTP range requests.
///
/// The resume offset is the size of the partial file on disk, never an opaque
/// resume blob. That is what lets a paused download survive both app quit and
/// the debrid's 3-hour link expiry: on resume we request a *fresh* link and
/// continue from the same byte.
///
/// Callers must ensure at most one in-flight `transfer(to:)` per partial URL —
/// the actor serializes its own state, not the file.
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
                // An over-length partial — e.g. a 206 whose Content-Range
                // overstated the body — would wedge permanently: verify()
                // throws before any network call, the file never shrinks, and
                // no retry can ever recover. Truncate and restart instead.
                //
                // `offset` is reset to 0 here (not left stale) so the request
                // built below asks for a fresh full download rather than a
                // nonsensical `Range: bytes=<old-length>-` against a file we
                // just emptied — a spec-compliant server would correctly
                // answer that stale range with 416, which would otherwise
                // throw sizeMismatch on this same attempt instead of just
                // succeeding outright.
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

            // Chunks, not `session.bytes(for:)`. That yields one UInt8 per
            // async suspension — ~26 million for a 25 MB file — which made
            // every download crawl no matter how fast the link was.
            let stream = try await body.fetch(request)
            let http = stream.head

            // Expired CDN link — re-request once, then give up.
            if http.statusCode == 403 || http.statusCode == 410 {
                guard !relinkAttempted else { throw DownloadError.linkExpired }
                relinkAttempted = true
                continue
            }

            // Partial is already at or past the end.
            if http.statusCode == 416 {
                try Self.verify(partialURL, expectedSize: expectedSize)
                return
            }

            guard (200...299).contains(http.statusCode) else {
                throw DownloadError.network("HTTP \(http.statusCode)")
            }

            // A 206 whose body does NOT start where we asked writes bytes at
            // the wrong position. Size-only verification still passes, so the
            // file is silently corrupt — the same worst case as an ignored
            // Range, just harder to see.
            if http.statusCode == 206, offset > 0 {
                guard let declared = Self.contentRangeStart(http), declared == offset else {
                    // The partial is emptied because those bytes can no longer
                    // be trusted to be where we think they are — and having
                    // done that, the condition that caused this is *gone*: the
                    // next pass asks for the whole file from zero. Throwing
                    // here anyway failed a download whose problem had already
                    // been fixed one line earlier. Only a second occurrence,
                    // which would mean the server is doing this from offset 0,
                    // is really unrecoverable.
                    try Data().write(to: partialURL)
                    guard !restartedFromZero else {
                        throw DownloadError.rangeNotSupported(status: http.statusCode)
                    }
                    restartedFromZero = true
                    continue
                }
            }

            // The critical case: we asked for a range and got the whole body.
            // Appending here would silently corrupt the file.
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

    // MARK: - Helpers

    /// Parses the start byte from `Content-Range: bytes 400-999/1000`.
    /// Returns nil when the header is absent or unparseable.
    static func contentRangeStart(_ response: ChunkedBody.Head) -> Int64? {
        guard let raw = response.value(forHeader: "Content-Range"),
              let unitsRange = raw.range(of: "bytes ")
        else { return nil }
        let rest = raw[unitsRange.upperBound...]
        guard let dash = rest.firstIndex(of: "-") else { return nil }
        return Int64(rest[rest.startIndex..<dash].trimmingCharacters(in: .whitespaces))
    }

    /// `FileSize`, not `attributesOfItem`: the latter reads every extended
    /// attribute to build its dictionary, so asking a resuming download how
    /// many bytes it already has could block in `getxattr`. Once per resume,
    /// on a file the user may have synced.
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
