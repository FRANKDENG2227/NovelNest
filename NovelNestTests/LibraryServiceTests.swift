import Foundation
import NovelNestCore
import SwiftData
import Testing
@testable import NovelNest

@MainActor
struct LibraryServiceTests {
    let container: ModelContainer
    let library: LibraryService

    init() throws {
        let schema = Schema(NovelNestSchema.models)
        container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        library = LibraryService(context: container.mainContext)
    }

    static let text = """
    作者：测试作者
    第一章 开始
    　　他走进院子的时候，天已经黑了。
    　　第二段。
    第二章 继续
    　　内容二。
    　　内容三。
    　　内容四。
    """

    func importSample(named name: String = "《测试之书》.txt", encoding: TextEncoding = .gb18030) throws -> Book {
        let encoded = try #require(Self.text.data(using: encoding == .utf8 ? .utf8 : Self.gb18030))
        let imported = try LibraryService.parse(data: encoded, fileName: name)
        return library.insert(imported, fileName: name)
    }

    static let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))

    func fetchBooks() throws -> [Book] {
        try container.mainContext.fetch(FetchDescriptor<Book>())
    }

    @Test func importStoresChaptersInOrder() throws {
        let book = try importSample()
        #expect(book.title == "测试之书")
        #expect(book.author == "测试作者")
        #expect(book.sourceEncoding == "gb18030")
        #expect(book.orderedChapters.map(\.title) == ["前言", "第一章 开始", "第二章 继续"])
        #expect(book.orderedChapters[2].paragraphs == ["内容二。", "内容三。", "内容四。"])
        #expect(book.lastOpenedAt == nil)
    }

    @Test func openingMovesBookToTopAndImportDoesNot() throws {
        let first = try importSample(named: "甲.txt")
        let second = try importSample(named: "乙.txt")
        library.recordOpen(first, at: Date(timeIntervalSinceNow: -60))
        library.recordOpen(second)
        #expect(BookshelfOrdering.sorted(try fetchBooks()).map(\.title) == ["乙", "甲"])

        library.recordOpen(first)
        _ = try importSample(named: "丙.txt")
        // Importing a new book doesn't change anyone's lastOpenedAt.
        #expect(BookshelfOrdering.sorted(try fetchBooks()).map(\.title) == ["甲", "乙", "丙"])
    }

    @Test func savingProgressDoesNotChangeLastOpened() throws {
        let book = try importSample()
        let opened = Date(timeIntervalSinceNow: -100)
        library.recordOpen(book, at: opened)
        let chapter = book.orderedChapters[2]
        library.saveProgress(book, position: ReadingPosition(chapterKey: chapter.id.uuidString, chapterIndex: 2, paragraphIndex: 1))
        #expect(book.lastOpenedAt == opened)
        #expect(book.lastReadAt != nil)
    }

    @Test func progressRestoresAfterReload() throws {
        let book = try importSample()
        let chapter = book.orderedChapters[2]
        library.saveProgress(book, position: ReadingPosition(chapterKey: chapter.id.uuidString, chapterIndex: 2, paragraphIndex: 1))
        library.saveProgress(book, position: ReadingPosition(chapterKey: chapter.id.uuidString, chapterIndex: 2, paragraphIndex: 2))

        // A fresh context reads only what was saved.
        let other = ModelContext(container)
        let reloaded = try #require(try other.fetch(FetchDescriptor<Book>()).first)
        let resolved = try #require(LibraryService(context: other).restorePosition(for: reloaded))
        #expect(resolved.chapterIndex == 2)
        #expect(resolved.paragraphIndex == 2)
        #expect(resolved.match == .exact)
        #expect(try other.fetch(FetchDescriptor<ReadingProgress>()).count == 1)
        #expect(abs((reloaded.progress?.normalizedProgress ?? 0) - (2 + 2.0 / 3) / 3) < 0.0001)
    }

    @Test func neverReadBookOpensAtStart() throws {
        let book = try importSample()
        let resolved = try #require(library.restorePosition(for: book))
        #expect(resolved.chapterIndex == 0)
        #expect(resolved.paragraphIndex == 0)
    }

    @Test func deleteRemovesChaptersAndProgress() throws {
        let book = try importSample()
        library.saveProgress(book, position: ReadingPosition(chapterKey: nil, chapterIndex: 1))
        library.delete(book)
        #expect(try fetchBooks().isEmpty)
        #expect(try container.mainContext.fetch(FetchDescriptor<Chapter>()).isEmpty)
        #expect(try container.mainContext.fetch(FetchDescriptor<ReadingProgress>()).isEmpty)
    }

    @Test func undecodableFileGivesReadableError() {
        #expect(throws: LibraryService.ImportError.self) {
            try LibraryService.parse(data: Data(), fileName: "空.txt")
        }
    }

    @Test func titleNormalizationIgnoresSpacesAndPunctuation() {
        #expect(Book.normalize("《斗转 星河》！") == "斗转星河")
        #expect(Book.normalize("Hello, World") == "helloworld")
    }
}
