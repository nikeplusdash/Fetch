import Foundation
import Testing

@Suite("Design system rules")
struct DesignSystemRulesTests {
    private static let repositoryRoot: URL = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private struct Finding: CustomStringConvertible {
        let file: String
        let line: Int
        let text: String

        var description: String { "\(file):\(line)  \(text)" }
    }

    private static func swiftFiles(under relativePath: String) -> [URL] {
        let directory = repositoryRoot.appending(path: relativePath)
        guard let walker = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: nil)
        else { return [] }
        return walker
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.path < $1.path }
    }

    private static func relativePath(_ url: URL) -> String {
        let root = repositoryRoot.path + "/"
        return url.path.hasPrefix(root) ? String(url.path.dropFirst(root.count)) : url.path
    }

    private static func read(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private static func sourceLines(_ source: String) -> [String] {
        source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private static func report(_ findings: [Finding], _ rule: String) -> String {
        ([rule] + findings.map { "  " + $0.description }).joined(separator: "\n")
    }

    private static func masked(_ source: String) -> [Character] {
        var characters = Array(source)
        var index = 0

        func blank(from start: Int, to end: Int) {
            guard start < end else { return }
            for position in start..<min(end, characters.count)
            where characters[position] != "\n" {
                characters[position] = " "
            }
        }

        while index < characters.count {
            let character = characters[index]
            if character == "\"" {
                let isMultiline = index + 2 < characters.count
                    && characters[index + 1] == "\""
                    && characters[index + 2] == "\""
                var cursor = index + (isMultiline ? 3 : 1)
                while cursor < characters.count {
                    if characters[cursor] == "\\" { cursor += 2; continue }
                    if characters[cursor] == "\"" {
                        if !isMultiline { break }
                        if cursor + 2 < characters.count,
                           characters[cursor + 1] == "\"",
                           characters[cursor + 2] == "\"" {
                            cursor += 2
                            break
                        }
                    }
                    if !isMultiline, characters[cursor] == "\n" { break }
                    cursor += 1
                }
                blank(from: index, to: min(cursor + 1, characters.count))
                index = cursor + 1
            } else if character == "/", index + 1 < characters.count,
                      characters[index + 1] == "*" {
                var cursor = index + 2
                var depth = 1
                while cursor + 1 < characters.count, depth > 0 {
                    if characters[cursor] == "/", characters[cursor + 1] == "*" {
                        depth += 1
                        cursor += 2
                    } else if characters[cursor] == "*", characters[cursor + 1] == "/" {
                        depth -= 1
                        cursor += 2
                    } else {
                        cursor += 1
                    }
                }
                blank(from: index, to: min(cursor, characters.count))
                index = cursor
            } else {
                index += 1
            }
        }
        return characters
    }

    private static func lineNumbers(_ characters: [Character]) -> [Int] {
        var numbers = [Int](repeating: 1, count: characters.count + 1)
        var line = 1
        for (offset, character) in characters.enumerated() {
            numbers[offset] = line
            if character == "\n" { line += 1 }
        }
        numbers[characters.count] = line
        return numbers
    }

    private static func matches(
        _ characters: [Character], _ needle: String, at index: Int
    ) -> Bool {
        let pattern = Array(needle)
        guard index >= 0, index + pattern.count <= characters.count else { return false }
        for (offset, character) in pattern.enumerated()
        where characters[index + offset] != character {
            return false
        }
        return true
    }

    private static func skippingWhitespace(_ characters: [Character], from index: Int) -> Int {
        var cursor = index
        while cursor < characters.count, characters[cursor].isWhitespace { cursor += 1 }
        return cursor
    }

    private static func frameWidthOffsets(_ characters: [Character]) -> [Int] {
        var offsets: [Int] = []
        for index in characters.indices where matches(characters, ".frame(", at: index) {
            let cursor = skippingWhitespace(characters, from: index + 7)
            if matches(characters, "width:", at: cursor) { offsets.append(index) }
        }
        return offsets
    }

    private static func widthValueOffset(_ characters: [Character], from index: Int) -> Int {
        let afterParenthesis = skippingWhitespace(characters, from: index + 7)
        return skippingWhitespace(characters, from: afterParenthesis + 6)
    }

    private static func closing(
        _ characters: [Character], from open: Int, _ opener: Character, _ closer: Character
    ) -> Int? {
        var depth = 0
        var index = open
        while index < characters.count {
            if characters[index] == opener { depth += 1 }
            if characters[index] == closer {
                depth -= 1
                if depth == 0 { return index }
            }
            index += 1
        }
        return nil
    }

    private static func hstackBodies(
        _ characters: [Character]
    ) -> [(open: Int, close: Int, start: Int)] {
        var spans: [(open: Int, close: Int, start: Int)] = []
        for index in characters.indices where matches(characters, "HStack", at: index) {
            var cursor = skippingWhitespace(characters, from: index + 6)
            if cursor < characters.count, characters[cursor] == "(" {
                guard let end = closing(characters, from: cursor, "(", ")") else { continue }
                cursor = skippingWhitespace(characters, from: end + 1)
            }
            guard cursor < characters.count, characters[cursor] == "{",
                  let close = closing(characters, from: cursor, "{", "}")
            else { continue }
            spans.append((open: cursor, close: close, start: index))
        }
        return spans
    }

    private static var appModelMentions: [Finding] {
        var findings: [Finding] = []
        for file in swiftFiles(under: "Fetch/DesignSystem") {
            for (offset, line) in sourceLines(read(file)).enumerated()
            where line.contains("AppModel") {
                findings.append(Finding(
                    file: relativePath(file),
                    line: offset + 1,
                    text: line.trimmingCharacters(in: .whitespaces)))
            }
        }
        return findings
    }

    private static var crowdedHStacks: [Finding] {
        var findings: [Finding] = []
        for file in swiftFiles(under: "Fetch/Views") {
            let characters = masked(read(file))
            let numbers = lineNumbers(characters)
            let offsets = frameWidthOffsets(characters)
            for span in hstackBodies(characters) {
                let inside = offsets.filter { $0 > span.open && $0 < span.close }
                guard inside.count > 1 else { continue }
                let widths = inside.map { String(numbers[$0]) }.joined(separator: ", ")
                findings.append(Finding(
                    file: relativePath(file),
                    line: numbers[span.start],
                    text: "one HStack fixes \(inside.count) widths, at lines \(widths)"))
            }
        }
        return findings
    }

    private static var literalWidths: [Finding] {
        var findings: [Finding] = []
        let files = swiftFiles(under: "Fetch/DesignSystem") + swiftFiles(under: "Fetch/Views")
        for file in files where file.lastPathComponent != "Dimension.swift" {
            let source = read(file)
            let lines = sourceLines(source)
            let characters = masked(source)
            let numbers = lineNumbers(characters)
            for offset in frameWidthOffsets(characters) {
                let value = widthValueOffset(characters, from: offset)
                guard value < characters.count, characters[value].isNumber else { continue }
                let number = numbers[offset]
                findings.append(Finding(
                    file: relativePath(file),
                    line: number,
                    text: lines[number - 1].trimmingCharacters(in: .whitespaces)))
            }
        }
        return findings
    }

    @Test("The scanner can see the app's source, so a green rule means something")
    func sourceTreeIsReachable() {
        let components = Self.swiftFiles(under: "Fetch/DesignSystem")
        let views = Self.swiftFiles(under: "Fetch/Views")
        #expect(components.count > 10, "nothing found under Fetch/DesignSystem")
        #expect(views.count > 10, "nothing found under Fetch/Views")
        #expect(components.contains { $0.lastPathComponent == "ScreenScaffold.swift" })
    }

    @Test("A string literal and a doc block are not source")
    func maskerIgnoresLiteralsAndComments() {
        let source = """
        let a = "HStack { .frame(width: 12) }"
        /** .frame(width: 34) */
        Text(x).frame(width: Token.wide)
        """
        #expect(Self.frameWidthOffsets(Self.masked(source)).count == 1)
    }

    @Test("A width written as a number is found; a width written as a token is not")
    func literalDetectionDiscriminates() {
        let literal = Self.masked("Text(x).frame(width: 72, alignment: .trailing)")
        let token = Self.masked("Text(x).frame(width: Self.latencyColumn)")
        let literalOffsets = Self.frameWidthOffsets(literal)
        let tokenOffsets = Self.frameWidthOffsets(token)
        #expect(literalOffsets.count == 1)
        #expect(tokenOffsets.count == 1)
        #expect(literal[Self.widthValueOffset(literal, from: literalOffsets[0])].isNumber)
        #expect(!token[Self.widthValueOffset(token, from: tokenOffsets[0])].isNumber)
    }

    @Test("An HStack's body runs to its matching brace, arguments spanning lines or not")
    func hstackBodyIsBraceMatched() {
        let source = """
        HStack(
            alignment: .center,
            spacing: 8
        ) {
            Text(a).frame(width: 1)
            VStack { Text(b) }
            Text(c).frame(width: 2)
        }
        Text(d).frame(width: 3)
        """
        let characters = Self.masked(source)
        let spans = Self.hstackBodies(characters)
        #expect(spans.count == 1)
        let inside = Self.frameWidthOffsets(characters)
            .filter { $0 > spans[0].open && $0 < spans[0].close }
        #expect(inside.count == 2)
    }

    @Test(
        "No design system component reaches for AppModel",
        .disabled("""
            4 files under Fetch/DesignSystem still mention AppModel; tracked for \
            the presentation-value pass. Palette.swift:7 and :17 name it in a doc \
            block. Components/BookResultRowView.swift:17, \
            Components/DownloadRowView.swift:24 and :26, and \
            Components/SearchResultRowView.swift:14 read it through @Environment. \
            Each wants its values passed in rather than reached for. \
            Delete this trait when they do.
            """))
    func componentsDoNotReadAppModel() {
        let findings = Self.appModelMentions
        #expect(
            findings.isEmpty,
            "\(Self.report(findings, "A design system component takes its values as parameters:"))")
    }

    @Test(
        "No hand-built row fixes more than one column width",
        .disabled("""
            1 HStack under Fetch/Views still fixes more than one width: \
            Search/SearchView.swift:316, the category bar's fade mask, whose \
            two gradients are at lines 320 and 326. It sits in a file another \
            task owns. Delete this trait when it is on a ColumnSet, or when \
            the mask stops being an HStack.
            """))
    func rowsDoNotFixTwoWidths() {
        let findings = Self.crowdedHStacks
        #expect(
            findings.isEmpty,
            "\(Self.report(findings, "A row with two fixed columns is a table; give it a ColumnSet:"))")
    }

    @Test(
        "A width is a named token, never a number written where it is used",
        .disabled("""
            10 bare numeric widths remain outside Dimension.swift: \
            DesignSystem/Components/SeederMeterView.swift:26; \
            Views/AddLinkSheet.swift:60; \
            Views/Search/ArchiveItemSheet.swift:48; \
            Views/Search/BookItemSheet.swift:38; \
            Views/Search/FacetSidebarView.swift:131; \
            Views/Search/FilePickerSheet.swift:80; \
            Views/Search/SearchView.swift:84, :108, :233 and :350. \
            The sidebar's glyph column is gone, on \
            WindowMetrics.sidebarGlyphWidth; each survivor is a sheet size or \
            a control another task owns, and each wants a named token where \
            its meaning lives. Delete this trait when they have one.
            """))
    func widthsAreNamed() {
        let findings = Self.literalWidths
        #expect(
            findings.isEmpty,
            "\(Self.report(findings, "A number here says how wide, never what column:"))")
    }
}
