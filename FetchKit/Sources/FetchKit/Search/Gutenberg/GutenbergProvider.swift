import Foundation
import FetchPluginAPI

/**
 Project Gutenberg, through Gutendex (spec §2, amendment §6.3).

 The second source that needs no debrid, no account and no key — and the
 cleanest test of `.direct` there is: every result is one file, freely
 licensed, with no swarm anywhere near it.

 Shaped like `InternetArchiveProvider` on purpose. Two keyless sources that
 read as one pattern are easier to hold than two inventions.
 */
public struct GutenbergProvider: SearchProvider {
    public static let providerID = SearchProviderID(rawValue: "gutenberg")
    public var id: SearchProviderID { Self.providerID }
    public let displayName = "Project Gutenberg"

    public static let apiHost = "gutendex.com"
    public static let fileHost = "www.gutenberg.org"

    static let pageSize = 32
    static let maxPages = 3

    private static let base = URL(string: "https://gutendex.com/books/")!

    private let client: any HTTPClientProtocol
    private let languages: [String]
    private let includesSupplementary: Bool


    public init(
        client: any HTTPClientProtocol = HTTPClient(),
        languages: [String] = [],
        includesSupplementary: Bool = false
    ) {
        self.client = client
        self.languages = languages
        self.includesSupplementary = includesSupplementary
    }

    /**
     A constant, and no round trip. Gutendex has no capabilities endpoint,
     and inventing a request to ask would cost every search a hop.
     */
    public func capabilities() async throws -> ProviderCapabilities {
        ProviderCapabilities(
            categories: [TorznabCategory(id: 7000, name: "Books")],
            supportedModes: [.search, .book],
            supportedAttributes: [],
            maxLimit: Self.pageSize * Self.maxPages)
    }


    public func search(_ query: SearchQuery) async throws -> [SearchResult] {
        let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }

        let firstPage = query.offset / Self.pageSize + 1
        let dropped = query.offset % Self.pageSize
        let wanted = dropped + query.limit
        let pages = max(1, Int((Double(wanted) / Double(Self.pageSize)).rounded(.up)))
        var results: [SearchResult] = []

        for page in firstPage..<(firstPage + min(pages, Self.maxPages)) {
            let response = try await books(matching: text, page: page)
            results.append(contentsOf: response.results.compactMap(result(from:)))

            if response.next == nil { break }
            if results.count >= wanted { break }
        }

        return Array(results.dropFirst(dropped).prefix(query.limit))
    }

    private func books(matching text: String, page: Int) async throws -> BooksResponse {
        var items = [URLQueryItem(name: "search", value: text)]
        if page > 1 { items.append(URLQueryItem(name: "page", value: String(page))) }
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
        guard !choices.isEmpty else { return nil }

        let author = book.authors.first.map { BookFilename.displayAuthor($0.name) }

        var metadata = ReleaseMetadata.unparsed
        metadata.mediaKind = .book
        metadata.title = book.title
        metadata.author = author
        metadata.languages = book.languages
        metadata.documentFormat = choices.first?.format.documentFormat
        metadata.provenance = [.mediaKind: .attribute, .title: .attribute, .languages: .attribute]
        if author != nil { metadata.provenance[.author] = .attribute }
        if choices.first != nil { metadata.provenance[.documentFormat] = .attribute }

        var attributes = ["gutenbergID": String(book.id)]
        if let author { attributes["author"] = author }
        if !book.languages.isEmpty { attributes["languages"] = book.languages.joined(separator: ",") }
        if let downloads = book.downloadCount { attributes["downloads"] = String(downloads) }

        return SearchResult(
            candidates: choices.map { .direct(url: $0.url, format: $0.format.documentFormat) },
            title: book.title,
            size: nil,
            seeders: nil,
            peers: nil,
            grabs: book.downloadCount,
            category: TorznabCategory(id: 7000, name: "Books"),
            publishDate: nil,
            sources: [id],
            sourceKey: "gutenberg:\(book.id)",
            rawAttributes: attributes,
            metadata: metadata)
    }


    /**
     One book with its real download choices, for the sheet.

     Fetched on selection rather than per search hit — the same lazy call
     §6.2 makes for an Internet Archive item's file list, and for the same
     reason: 50 results must not be 50 extra round trips.
     */
    public func book(id bookID: Int) async throws -> GutenbergBook {
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

/**
 One Gutenberg book, resolved to what can actually be downloaded.
 */
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

    /**
     The same book with its formats in the profile's preferred order.

     The sheet has to offer the order the list ranked by, or the row's
     badge and the sheet's pre-selection disagree about which format is
     preferred — which is what happened while the provider held one
     preference and `QualityProfile` held another.

     Stable, so a format the profile does not rank keeps its place after
     the ranked ones rather than jumping the queue.
     */
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
