import Testing
import Foundation
@testable import FetchKit

@Suite struct LibraryOrderTests {
    private struct Row { let name: String; let date: Date? }
    private func at(_ day: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(day) * 86_400) }

    private func order(_ rows: [Row]) -> [String] {
        DownloadLibrary.newestFirst(rows, date: \.date, name: \.name).map(\.name)
    }

    @Test func theNewestComesFirst() {
        #expect(order([
            Row(name: "old", date: at(1)),
            Row(name: "new", date: at(9)),
            Row(name: "middle", date: at(5)),
        ]) == ["new", "middle", "old"])
    }

    @Test func aRowWithNoDateSortsLastNotFirst() {
        #expect(order([
            Row(name: "undated", date: nil),
            Row(name: "dated", date: at(1)),
        ]) == ["dated", "undated"])
    }

    @Test func sameInstantFallsBackToTheName() {
        #expect(order([
            Row(name: "Beta", date: at(3)),
            Row(name: "Alpha", date: at(3)),
        ]) == ["Alpha", "Beta"])
    }

    @Test func undatedRowsAreOrderedByNameAmongThemselves() {
        #expect(order([Row(name: "B", date: nil), Row(name: "A", date: nil)]) == ["A", "B"])
    }
}
