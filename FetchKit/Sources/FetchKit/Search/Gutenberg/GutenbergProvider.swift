import Foundation
import FetchPluginAPI

/// Project Gutenberg, through Gutendex (spec §2, amendment §6.3).
///
/// The second source that needs no debrid, no account and no key — and the
/// cleanest test of `.direct` there is: every result is one file, freely
/// licensed, with no swarm anywhere near it.
///
/// Shaped like `InternetArchiveProvider` on purpose. Two keyless sources that
/// read as one pattern are easier to hold than two inventions.
public struct GutenbergProvider: SearchProvider {
    public static let providerID = SearchProviderID(rawValue: "gutenberg")
    public var id: SearchProviderID { Self.providerID }
    public let displayName = "Project Gutenberg"

    /// The API and the files live on different origins — the case §3 rule 4's
    /// exact-match host rule exists for.
    ///
    /// `apiHost` is enforced by the `HTTPClient` allowlist. `fileHost` cannot
    /// be: the download runs through `DownloadEngine`, which has no allowlist,
    /// so it is enforced where the candidate is *made* instead — see
    /// `BookFormat.choices(from:servedBy:…)`. Naming it in `allowedHosts`
    /// alone would be a constant that does nothing.
    public static let apiHost = "gutendex.com"
    public static let fileHost = "www.gutenberg.org"

    /// Gutendex serves a fixed 32 per page and accepts no `limit`.
    static let pageSize = 32
    /// Two pages fill the default limit of 50 from a page boundary, and a
    /// first search always starts on one — so the common case still costs two
    /// hops and no more.
    ///
    /// Three, not two, because paging arrived: Fetch asks in 50s and Gutendex
    /// answers in 32s, so page 2 of a search starts 18 books inside Gutendex's
    /// page 2 and needs one more to reach 50. The third hop is only ever paid
    /// by a window that does not start on a boundary, which is to say by
    /// someone who has actually scrolled.
    static let maxPages = 3

    // The trailing slash matters: `/books` 301-redirects to `/books/`, and
    // every search would otherwise pay a redirect hop.
    private static let base = URL(string: "https://gutendex.com/books/")!

    private let client: any HTTPClientProtocol
    private let languages: [String]
    private let includesSupplementary: Bool

    // `formatPriority` is gone (7d §4.7). Preference now lives in
    // `QualityProfile.documentFormatOrder` and is applied by the ranking, so
    // that changing it reorders results already on screen instead of only the
    // next search. `BookFormat.defaultPriority` remains as a *stable* order
    // for the candidates this provider emits — the ranking's sort is stable,
    // so it decides ties among formats the profile does not rank.

    public init(
        client: any HTTPClientProtocol = HTTPClient(),
        languages: [String] = [],
        includesSupplementary: Bool = false
    ) {
        self.client = client
        self.languages = languages
        self.includesSupplementary = includesSupplementary
    }

    /// A constant, and no round trip. Gutendex has no capabilities endpoint,
    /// and inventing a request to ask would cost every search a hop.
    public func capabilities() async throws -> ProviderCapabilities {
        ProviderCapabilities(
            categories: [TorznabCategory(id: 7000, name: "Books")],
            supportedModes: [.search, .book],
            supportedAttributes: [],
            maxLimit: Self.pageSize * Self.maxPages)
    }

    // MARK: - Search

    public func search(_ query: SearchQuery) async throws -> [SearchResult] {
        let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }

        // Gutendex pages in fixed 32s and takes no `limit`, so a requested
        // window almost never starts on a page boundary — 50 results per page
        // of Fetch's own means page 2 begins at offset 50, which is 18 books
        // into Gutendex's page 2.
        //
        // `page = offset / 32 + 1` alone threw that remainder away and served
        // books 33–50 over again. It was latent for as long as nothing paged
        // and became real on the first scroll, so it is fixed here rather than
        // left as the known gap it was recorded as. `dropped` is the fix: ask
        // from the page the window starts in, then skip into it.
        let firstPage = query.offset / Self.pageSize + 1
        let dropped = query.offset % Self.pageSize
        // Enough pages to cover the window from wherever inside the first one
        // it begins, so a non-aligned offset does not come up short.
        let wanted = dropped + query.limit
        let pages = max(1, Int((Double(wanted) / Double(Self.pageSize)).rounded(.up)))
        var results: [SearchResult] = []

        for page in firstPage..<(firstPage + min(pages, Self.maxPages)) {
            let response = try await books(matching: text, page: page)
            results.append(contentsOf: response.results.compactMap(result(from:)))

            // The catalogue said there is no more. Asking anyway is a wasted
            // round trip on every narrow search.
            if response.next == nil { break }
            if results.count >= wanted { break }
        }

        return Array(results.dropFirst(dropped).prefix(query.limit))
    }

    private func books(matching text: String, page: Int) async throws -> BooksResponse {
        var items = [URLQueryItem(name: "search", value: text)]
        if page > 1 { items.append(URLQueryItem(name: "page", value: String(page))) }
        // Only when a filter is actually set: `languages=` with no value
        // filters to nothing.
        if !languages.isEmpty {
            items.append(URLQueryItem(name: "languages", value: languages.joined(separator: ",")))
        }

        return try await client.send(
            Endpoint(baseURL: Self.base, path: "", queryItems: items),
            as: BooksResponse.self)
    }

    private func result(from book: Book) -> SearchResult? {
        let choices = BookFormat.choices(
            from: book.formats,
            servedBy: Self.fileHost,
            priority: BookFormat.defaultPriority,
            includingSupplementary: includesSupplementary)
        // Nothing downloadable is the one case §3's amended drop rule still
        // drops: no candidates at all.
        guard !choices.isEmpty else { return nil }

        let author = book.authors.first.map { BookFilename.displayAuthor($0.name) }

        var metadata = ReleaseMetadata.unparsed
        metadata.mediaKind = .book
        metadata.title = book.title
        metadata.author = author
        metadata.languages = book.languages
        metadata.documentFormat = choices.first?.format.documentFormat
        // These came from API fields, not from parsing a release name. §12.1
        // renders a stated value differently from a guessed one.
        metadata.provenance = [.mediaKind: .attribute, .title: .attribute, .languages: .attribute]
        if author != nil { metadata.provenance[.author] = .attribute }
        if choices.first != nil { metadata.provenance[.documentFormat] = .attribute }

        var attributes = ["gutenbergID": String(book.id)]
        if let author { attributes["author"] = author }
        if !book.languages.isEmpty { attributes["languages"] = book.languages.joined(separator: ",") }
        if let downloads = book.downloadCount { attributes["downloads"] = String(downloads) }

        return SearchResult(
            // Each candidate is labelled: 7d ranks *within* a result, so a
            // candidate the ranking cannot identify is one it cannot order.
            candidates: choices.map { .direct(url: $0.url, format: $0.format.documentFormat) },
            title: book.title,
            // The catalogue publishes none. `Content-Length` settles it at
            // download time; 0 would claim a zero-byte file.
            size: nil,
            // Absent, not zero: a book is not a torrent nobody is seeding.
            seeders: nil,
            peers: nil,
            // The catalogue's download count, in the typed field the ranking
            // reads. It was computed already and written only to a raw
            // attribute nothing consulted, so a book contributed no
            // popularity at all and sorted below every torrent.
            grabs: book.downloadCount,
            category: TorznabCategory(id: 7000, name: "Books"),
            publishDate: nil,
            sources: [id],
            // Gutenberg's own catalogue ID. Identity used to be the first
            // candidate's URL, so changing format preference made the same
            // book a different row.
            sourceKey: "gutenberg:\(book.id)",
            rawAttributes: attributes,
            metadata: metadata)
    }

    // MARK: - One book

    /// One book with its real download choices, for the sheet.
    ///
    /// Fetched on selection rather than per search hit — the same lazy call
    /// §6.2 makes for an Internet Archive item's file list, and for the same
    /// reason: 50 results must not be 50 extra round trips.
    public func book(id bookID: Int) async throws -> GutenbergBook {
        // The trailing slash again: `/books/84` redirects to `/books/84/`.
        // `appendingPathComponent` does *not* strip one — checked on
        // 2026-08-02, `…/books/` plus "84/" keeps the slash. What it will not
        // do is add one, so the slash has to be written out either way; here
        // it is visible in the URL rather than buried in an argument.
        let url = URL(string: "https://gutendex.com/books/\(bookID)/")!
        let book = try await client.send(
            Endpoint(baseURL: url, path: ""), as: Book.self)

        return GutenbergBook(
            id: book.id,
            title: book.title,
            author: book.authors.first.map { BookFilename.displayAuthor($0.name) },
            languages: book.languages,
            downloadCount: book.downloadCount,
            choices: BookFormat.choices(
                from: book.formats,
                servedBy: Self.fileHost,
                priority: BookFormat.defaultPriority,
                includingSupplementary: includesSupplementary))
    }

    // MARK: - Wire shapes

    struct BooksResponse: Decodable, Sendable {
        let count: Int
        let next: String?
        let results: [Book]
    }

    struct Book: Decodable, Sendable {
        let id: Int
        let title: String
        let authors: [Person]
        let languages: [String]
        let downloadCount: Int?
        let formats: [String: String]

        struct Person: Decodable, Sendable { let name: String }

        /// Tolerant on everything except `id` and `formats`. A book missing a
        /// title is still downloadable; a strict decoder would throw away the
        /// whole page over one odd record.
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(Int.self, forKey: .id)
            formats = (try? c.decode([String: String].self, forKey: .formats)) ?? [:]
            title = (try? c.decode(String.self, forKey: .title)) ?? "Untitled"
            authors = (try? c.decode([Person].self, forKey: .authors)) ?? []
            languages = (try? c.decode([String].self, forKey: .languages)) ?? []
            downloadCount = try? c.decode(Int.self, forKey: .downloadCount)
        }

        enum CodingKeys: String, CodingKey {
            case id, title, authors, languages, formats
            case downloadCount = "download_count"
        }
    }
}

/// One Gutenberg book, resolved to what can actually be downloaded.
public struct GutenbergBook: Sendable, Equatable {
    public let id: Int
    public let title: String
    public let author: String?
    public let languages: [String]
    public let downloadCount: Int?
    public let choices: [BookFormatChoice]

    public init(
        id: Int, title: String, author: String?, languages: [String],
        downloadCount: Int?, choices: [BookFormatChoice]
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.languages = languages
        self.downloadCount = downloadCount
        self.choices = choices
    }

    /// The same book with its formats in the profile's preferred order.
    ///
    /// The sheet has to offer the order the list ranked by, or the row's
    /// badge and the sheet's pre-selection disagree about which format is
    /// preferred — which is what happened while the provider held one
    /// preference and `QualityProfile` held another.
    ///
    /// Stable, so a format the profile does not rank keeps its place after
    /// the ranked ones rather than jumping the queue.
    public func ordered(by formats: [DocumentFormat]) -> GutenbergBook {
        func rank(_ choice: BookFormatChoice) -> Int {
            guard let format = choice.format.documentFormat,
                  let index = formats.firstIndex(of: format) else { return formats.count }
            return index
        }
        let sorted = choices.enumerated()
            .sorted { a, b in
                let (x, y) = (rank(a.element), rank(b.element))
                return x != y ? x < y : a.offset < b.offset
            }
            .map(\.element)

        return GutenbergBook(
            id: id, title: title, author: author, languages: languages,
            downloadCount: downloadCount, choices: sorted)
    }
}
