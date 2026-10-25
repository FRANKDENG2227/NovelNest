import Foundation
import NovelNestCore
import SwiftData
import Testing
@testable import NovelNest

@MainActor
struct WebLibraryTests {
    let container: ModelContainer
    let library: LibraryService

    init() throws {
        let schema = Schema(NovelNestSchema.models)
        container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        library = LibraryService(context: container.mainContext)
    }

    static let detail = WebBookDetail(
        sourceURL: "https://books.example.com", sourceName: "示例书源", bookURL: "https://books.example.com/book/9/",
        tocURL: "https://books.example.com/book/9/list/", title: "云海行", author: "山月", category: "仙侠",
        latestChapter: "第三章 归途", intro: "少年出山。", coverURL: nil, wordCount: nil, serialStatus: .ongoing)

    static let toc = [
        WebTOCItem(title: "第一章 出山", url: "https://books.example.com/book/9/1.html", volumeTitle: "正文卷"),
        WebTOCItem(title: "第二章 云海", url: "https://books.example.com/book/9/2.html", volumeTitle: "正文卷"),
        WebTOCItem(title: "完本感言", url: "https://books.example.com/book/9/3.html"),
    ]

    static func source(name: String = "示例书源", searchUrl: String = "/s?q={{key}}") -> LegadoSource {
        LegadoSource(bookSourceUrl: "https://books.example.com", bookSourceName: name, searchUrl: searchUrl,
                     ruleSearch: .init(bookList: "tag.li", name: "tag.a@text", bookUrl: "tag.a@href"),
                     ruleContent: .init(content: "id.content@html"))
    }

    @Test func addsBookWithUndownloadedChaptersInOrder() throws {
        let book = library.addWebBook(Self.detail, toc: Self.toc)
        #expect(book.isWebBook)
        #expect(book.lastOpenedAt == nil)
        #expect(book.sourceName == "示例书源")
        let chapters = book.orderedChapters
        #expect(chapters.map(\.title) == ["第一章 出山", "第二章 云海", "完本感言"])
        #expect(chapters.allSatisfy { !$0.isDownloaded && $0.content.isEmpty })
        #expect(chapters[0].parsedNumber == 1)
        #expect(chapters[0].volumeTitle == "正文卷")
        #expect(chapters[2].kind == .authorNote)
    }

    @Test func addingTwiceKeepsOneBook() throws {
        let first = library.addWebBook(Self.detail, toc: Self.toc)
        let second = library.addWebBook(Self.detail, toc: Self.toc)
        #expect(first.id == second.id)
        #expect(library.webBook(bookURL: Self.detail.bookURL)?.id == first.id)
        #expect(try container.mainContext.fetch(FetchDescriptor<Book>()).count == 1)
    }

    @Test func storesFetchedText() throws {
        let book = library.addWebBook(Self.detail, toc: Self.toc)
        let chapter = book.orderedChapters[0]
        library.storeChapterText(chapter, paragraphs: ["山中无岁月。", "他推门而出。"])
        #expect(chapter.isDownloaded)
        #expect(chapter.paragraphs == ["山中无岁月。", "他推门而出。"])
        #expect(chapter.paragraphCount == 2)
        library.discardChapterText(chapter)
        #expect(!chapter.isDownloaded)
    }

    @Test func upsertKeepsTheUsersChoice() throws {
        let summary = library.upsert([Self.source(), Self.source(name: "重复")], subscriptionURL: "https://www.yckceo.com/a.json")
        #expect(summary == .init(added: 1, updated: 0, unsupported: 0))
        let source = try #require(try container.mainContext.fetch(FetchDescriptor<BookSource>()).first)
        #expect(source.isEnabled)
        source.isEnabled = false

        let again = library.upsert([Self.source(name: "改名")], subscriptionURL: nil)
        #expect(again == .init(added: 0, updated: 1, unsupported: 0))
        #expect(source.name == "改名")
        #expect(!source.isEnabled)
        #expect(source.subscriptionURL == "https://www.yckceo.com/a.json")
        #expect(library.searchableSources().isEmpty)
    }

    @Test func unsupportedSourcesStayOff() throws {
        let summary = library.upsert([Self.source(searchUrl: "@js:java.createSymmetricCrypto('AES', k).decrypt(x)")],
                                     subscriptionURL: nil)
        #expect(summary.unsupported == 1)
        let source = try #require(try container.mainContext.fetch(FetchDescriptor<BookSource>()).first)
        #expect(!source.isEnabled)
        #expect(source.unsupportedReasons.contains("需要解密"))
    }

    @Test(arguments: [
        ("https://www.yckceo.com/yuedu/shuyuan/json/id/1.json", "https://www.yckceo.com/yuedu/shuyuan/json/id/1.json"),
        ("yuedu://booksource/importonline?src=https://www.yckceo.com/yuedu/shuyuans/json/id/2.json",
         "https://www.yckceo.com/yuedu/shuyuans/json/id/2.json"),
    ])
    func readsSubscriptionLinks(link: String, expected: String) {
        #expect(LibraryService.subscriptionURL(from: link)?.absoluteString == expected)
    }

    @Test func rejectsOtherLinks() {
        #expect(LibraryService.subscriptionURL(from: "file:///etc/passwd") == nil)
        #expect(LibraryService.subscriptionURL(from: "书源") == nil)
    }
}

@MainActor
struct ReadingFromSearchTests {
    let container: ModelContainer
    let library: LibraryService

    init() throws {
        container = try ModelContainer(for: Schema(NovelNestSchema.models),
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        library = LibraryService(context: container.mainContext)
    }

    func shelf() throws -> [Book] {
        try container.mainContext.fetch(FetchDescriptor<Book>(predicate: #Predicate { $0.isOnShelf }))
    }

    @Test func bookOpenedFromSearchIsOffTheShelfUntilAdded() throws {
        let book = library.addWebBook(WebLibraryTests.detail, toc: WebLibraryTests.toc, onShelf: false)
        #expect(try shelf().isEmpty)
        library.addToShelf(book)
        #expect(try shelf().map(\.id) == [book.id])
        library.deleteIfNotOnShelf(book)
        #expect(!book.isDeleted)
    }

    @Test func notAddedBooksAreRemoved() throws {
        let book = library.addWebBook(WebLibraryTests.detail, toc: WebLibraryTests.toc, onShelf: false)
        let leftAt = Date.now
        library.recordOpen(book, at: leftAt.addingTimeInterval(1))
        library.deleteIfNotOnShelf(book, leftAt: leftAt)
        #expect(!book.isDeleted)   // opened again meanwhile
        library.deleteIfNotOnShelf(book, leftAt: leftAt.addingTimeInterval(2))
        #expect(try container.mainContext.fetch(FetchDescriptor<Book>()).isEmpty)

        library.addWebBook(WebLibraryTests.detail, toc: WebLibraryTests.toc, onShelf: false)
        library.purgeBooksNotOnShelf()
        #expect(try container.mainContext.fetch(FetchDescriptor<Book>()).isEmpty)
        #expect(try container.mainContext.fetch(FetchDescriptor<Chapter>()).isEmpty)
    }

    @Test func sameTitleFromAnotherSourceIsAnotherBook() throws {
        var other = WebLibraryTests.detail
        other.sourceURL = "https://other.example.org"
        other.bookURL = "https://other.example.org/b/1"
        let first = library.addWebBook(WebLibraryTests.detail, toc: WebLibraryTests.toc)
        let second = library.addWebBook(other, toc: WebLibraryTests.toc)
        #expect(first.id != second.id)
        #expect(try shelf().count == 2)
    }

    @Test func switchingSourceKeepsTheChapter() throws {
        let book = library.addWebBook(WebLibraryTests.detail, toc: WebLibraryTests.toc)
        library.saveProgress(book, position: ReadingPosition(chapterKey: book.orderedChapters[1].id.uuidString,
                                                             chapterIndex: 1, paragraphIndex: 4))
        var other = WebLibraryTests.detail
        other.sourceURL = "https://other.example.org"
        other.sourceName = "另一个书源"
        other.bookURL = "https://other.example.org/b/1"
        let toc = [WebTOCItem(title: "作品相关", url: "https://other.example.org/b/1/0"),
                   WebTOCItem(title: "第1章 出山", url: "https://other.example.org/b/1/1"),
                   WebTOCItem(title: "第2章 云海", url: "https://other.example.org/b/1/2")]

        let target = library.switchSource(book, to: other, toc: toc, currentChapter: 1)
        #expect(target == 2)
        #expect(book.sourceName == "另一个书源")
        #expect(book.bookURL == "https://other.example.org/b/1")
        #expect(book.orderedChapters.map(\.title) == toc.map(\.title))
        #expect(try container.mainContext.fetch(FetchDescriptor<Chapter>()).count == 3)
        let restored = try #require(library.restorePosition(for: book))
        #expect(restored.chapterIndex == 2)
    }
}

@MainActor
struct SourceCheckTests {
    let container: ModelContainer
    let library: LibraryService

    init() throws {
        container = try ModelContainer(for: Schema(NovelNestSchema.models),
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        library = LibraryService(context: container.mainContext)
    }

    func event(_ outcome: SourceSearchEvent.Outcome) -> SourceSearchEvent {
        SourceSearchEvent(sourceURL: "https://books.example.com", sourceName: "示例书源", outcome: outcome)
    }

    @Test func failuresMarkASourceUnusableUntilItAnswers() throws {
        library.upsert([WebLibraryTests.source()], subscriptionURL: nil)
        let source = try #require(try container.mainContext.fetch(FetchDescriptor<BookSource>()).first)
        #expect(!source.isUnusable)

        library.recordCheck(event(.failed(message: "网站拒绝访问（403）", isTemporary: false)))
        library.recordCheck(event(.failed(message: "网站要求验证", isTemporary: false)))
        #expect(source.isUnusable)
        #expect(source.failureCount == 2)
        #expect(source.lastError == "网站要求验证")

        library.recordCheck(event(.failed(message: "请求太频繁", isTemporary: true)))
        #expect(source.failureCount == 2)

        library.recordCheck(event(.results([])))
        #expect(!source.isUnusable)
        #expect(source.failureCount == 0)
    }

    @Test func deletingSourcesKeepsBooks() throws {
        library.upsert([WebLibraryTests.source()], subscriptionURL: nil)
        let book = library.addWebBook(WebLibraryTests.detail, toc: WebLibraryTests.toc)
        library.deleteSources(try container.mainContext.fetch(FetchDescriptor<BookSource>()))
        #expect(try container.mainContext.fetch(FetchDescriptor<BookSource>()).isEmpty)
        #expect(!book.isDeleted)
        #expect(book.orderedChapters.count == 3)
    }
}

@MainActor
struct SourceExportTests {
    @Test func exportsImportedJSONWithTheOnOffState() throws {
        let container = try ModelContainer(for: Schema(NovelNestSchema.models),
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let library = LibraryService(context: container.mainContext)
        let json = """
        [{"bookSourceUrl":"https://a.example.com","bookSourceName":"甲","searchUrl":"/s?k={{key}}","exploreUrl":"热门::/hot",
          "ruleSearch":{"bookList":"tag.li","name":"tag.a@text","bookUrl":"tag.a@href"},"ruleContent":{"content":"id.c@html"}}]
        """
        library.upsert(try LegadoSource.decodeEntries(Data(json.utf8)), subscriptionURL: nil)
        let sources = try container.mainContext.fetch(FetchDescriptor<BookSource>())
        sources[0].isEnabled = false

        let url = try library.exportSourcesFile(sources)
        #expect(url.pathExtension == "json")
        let object = try #require((try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])?.first)
        #expect(object["exploreUrl"] as? String == "热门::/hot")
        #expect(object["enabled"] as? Bool == false)
        #expect(try LegadoSource.decodeList(Data(contentsOf: url)).map(\.bookSourceName) == ["甲"])
    }
}
