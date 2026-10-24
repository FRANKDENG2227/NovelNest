import Foundation
import Testing
@testable import NovelNestCore

struct BookshelfOrderingTests {
    struct Book: BookshelfItem {
        var title: String
        var createdAt: Date
        var lastOpenedAt: Date?
    }

    static func day(_ n: Double) -> Date { Date(timeIntervalSince1970: n * 86_400) }

    @Test func recentlyOpenedFirstThenNeverOpenedByImportDate() {
        let books = [
            Book(title: "从未打开-旧", createdAt: Self.day(1), lastOpenedAt: nil),
            Book(title: "昨天打开", createdAt: Self.day(1), lastOpenedAt: Self.day(9)),
            Book(title: "从未打开-新", createdAt: Self.day(5), lastOpenedAt: nil),
            Book(title: "今天打开", createdAt: Self.day(2), lastOpenedAt: Self.day(10)),
            Book(title: "上周打开", createdAt: Self.day(8), lastOpenedAt: Self.day(3)),
        ]
        #expect(BookshelfOrdering.sorted(books).map(\.title) == ["今天打开", "昨天打开", "上周打开", "从未打开-新", "从未打开-旧"])
    }

    @Test func openingABookMovesItToTheTop() {
        var books = [
            Book(title: "A", createdAt: Self.day(1), lastOpenedAt: Self.day(5)),
            Book(title: "B", createdAt: Self.day(1), lastOpenedAt: nil),
        ]
        books[1].lastOpenedAt = Self.day(6)
        #expect(BookshelfOrdering.sorted(books).map(\.title) == ["B", "A"])
    }

    @Test func tiesAreBrokenByTitle() {
        let books = ["第10卷", "第2卷", "第1卷"].map {
            Book(title: $0, createdAt: Self.day(1), lastOpenedAt: Self.day(2))
        }
        #expect(BookshelfOrdering.sorted(books).map(\.title) == ["第1卷", "第2卷", "第10卷"])
    }
}

struct ReadingPositionTests {
    let keys = ["a", "b", "c"]

    @Test func restoresByChapterKey() throws {
        // Chapter "b" moved from index 1 to index 2 after a TOC refresh.
        let saved = ReadingPosition(chapterKey: "b", chapterIndex: 1, paragraphIndex: 4, characterOffset: 7)
        let resolved = try #require(ReadingPositionResolver.resolve(saved, chapterKeys: ["a", "x", "b"]) { _ in 10 })
        #expect(resolved == .init(chapterIndex: 2, paragraphIndex: 4, characterOffset: 7, match: .exact))
    }

    @Test func clampsParagraphWhenChapterGotShorter() throws {
        let saved = ReadingPosition(chapterKey: "c", chapterIndex: 2, paragraphIndex: 50, characterOffset: 7)
        let resolved = try #require(ReadingPositionResolver.resolve(saved, chapterKeys: keys) { _ in 3 })
        #expect(resolved == .init(chapterIndex: 2, paragraphIndex: 2, characterOffset: 0, match: .exact))
    }

    @Test func fallsBackToNearestIndexWhenChapterIsGone() throws {
        let saved = ReadingPosition(chapterKey: "deleted", chapterIndex: 7, paragraphIndex: 4)
        let resolved = try #require(ReadingPositionResolver.resolve(saved, chapterKeys: keys) { _ in 10 })
        #expect(resolved == .init(chapterIndex: 2, paragraphIndex: 0, characterOffset: 0, match: .nearestIndex))
    }

    @Test func noChaptersMeansNoPosition() {
        let saved = ReadingPosition(chapterKey: "a", chapterIndex: 0)
        #expect(ReadingPositionResolver.resolve(saved, chapterKeys: []) { _ in 0 } == nil)
    }

    @Test func normalizedProgress() {
        let position = ReadingPosition(chapterKey: nil, chapterIndex: 1, paragraphIndex: 5)
        #expect(position.normalizedProgress(chapterCount: 4, paragraphCount: 10) == 0.375)
        #expect(position.normalizedProgress(chapterCount: 0, paragraphCount: 10) == 0)
    }

    @Test func positionRoundTripsThroughJSON() throws {
        let position = ReadingPosition(chapterKey: "b", chapterIndex: 1, paragraphIndex: 2, characterOffset: 3)
        let data = try JSONEncoder().encode(position)
        #expect(try JSONDecoder().decode(ReadingPosition.self, from: data) == position)
    }
}
