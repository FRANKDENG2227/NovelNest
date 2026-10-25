import Foundation
import NovelNestCore
import SwiftData

// SwiftData models for the local library (spec §11). Books found with a
// book source keep where they came from; their chapters' text is fetched
// when first read. New fields are optional or defaulted so existing stores
// migrate automatically.

@Model
final class Book: BookshelfItem {
    @Attribute(.unique) var id: UUID
    var title: String
    var author: String?
    /// Title with whitespace and punctuation removed, for search (§10A.7).
    var normalizedTitle: String
    /// `ChineseScript` raw value; picks the speech voice.
    var originalScript: String
    /// Encoding the imported file was decoded with.
    var sourceEncoding: String
    var importedFileName: String?
    var isFinished: Bool
    var createdAt: Date
    var updatedAt: Date
    /// Set only when the user opens the book (§6).
    var lastOpenedAt: Date?
    var lastReadAt: Date?

    // From a book source; nil for imported files.
    /// `bookSourceUrl` of the `BookSource` it was found with.
    var sourceURL: String?
    var sourceName: String?
    /// The book page; may carry Legado `,{options}`.
    var bookURL: String?
    var tocURL: String?
    var coverURL: String?
    var intro: String?
    var category: String?
    /// `SerialStatus` raw value.
    var serialStatus: String?
    var latestChapterTitle: String?
    /// False while a web book is only being read from a search result; it
    /// is deleted on leaving unless the reader adds it.
    var isOnShelf: Bool = true

    @Relationship(deleteRule: .cascade, inverse: \Chapter.book)
    var chapters: [Chapter] = []

    @Relationship(deleteRule: .cascade, inverse: \ReadingProgress.book)
    var progress: ReadingProgress?

    init(title: String, author: String?, script: ChineseScript, encoding: TextEncoding, importedFileName: String?) {
        id = UUID()
        self.title = title
        self.author = author
        normalizedTitle = Book.normalize(title)
        originalScript = script.rawValue
        sourceEncoding = encoding.rawValue
        self.importedFileName = importedFileName
        isFinished = false
        createdAt = .now
        updatedAt = .now
    }

    var script: ChineseScript { ChineseScript(rawValue: originalScript) ?? .unknown }

    var isWebBook: Bool { bookURL != nil }

    /// Chapters in reading order. SwiftData relationships are unordered.
    var orderedChapters: [Chapter] { chapters.sorted { $0.chapterIndex < $1.chapterIndex } }

    static func normalize(_ text: String) -> String {
        String(text.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.punctuationCharacters.contains($0)
        }.map(Character.init)).lowercased()
    }
}

@Model
final class Chapter {
    @Attribute(.unique) var id: UUID
    var book: Book?
    /// Source/file order; canonical (§10A.5).
    var chapterIndex: Int
    var title: String
    var rawTitle: String
    /// `ChapterKind` raw value.
    var chapterKind: String
    var parsedNumber: Int?
    var volumeTitle: String?
    /// Cleaned paragraphs joined by "\n". Stored outside the database row so
    /// listing chapters doesn't load every chapter's text.
    @Attribute(.externalStorage) var content: String
    var paragraphCount: Int
    var wordCount: Int
    /// The chapter page for web books; may carry Legado `,{options}`.
    var sourceURL: String?
    /// False for a web chapter whose text hasn't been fetched yet.
    var isDownloaded: Bool = true

    init(index: Int, split: SplitChapter) {
        id = UUID()
        chapterIndex = index
        title = split.title
        rawTitle = split.title
        chapterKind = split.kind.rawValue
        parsedNumber = split.parsedNumber
        volumeTitle = split.volumeTitle
        content = split.content
        paragraphCount = split.paragraphs.count
        wordCount = split.paragraphs.reduce(0) { $0 + $1.count }
    }

    /// A web chapter from the table of contents; its text comes later.
    init(index: Int, toc item: WebTOCItem) {
        id = UUID()
        chapterIndex = index
        title = item.title
        rawTitle = item.title
        let parsed = ChapterTitleParser.parse(item.title)
        if case .chapter(let kind)? = parsed?.role { chapterKind = kind.rawValue } else { chapterKind = ChapterKind.normal.rawValue }
        parsedNumber = parsed?.number
        volumeTitle = item.volumeTitle
        content = ""
        paragraphCount = 0
        wordCount = 0
        sourceURL = item.url
        isDownloaded = false
    }

    var kind: ChapterKind { ChapterKind(rawValue: chapterKind) ?? .unknown }

    var paragraphs: [String] {
        content.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }
}

@Model
final class ReadingProgress {
    var book: Book?
    /// `Chapter.id.uuidString` of the chapter being read.
    var chapterKey: String?
    var chapterIndex: Int
    var paragraphIndex: Int
    var characterOffset: Int
    var normalizedProgress: Double
    var updatedAt: Date

    init(position: ReadingPosition, normalizedProgress: Double) {
        chapterKey = position.chapterKey
        chapterIndex = position.chapterIndex
        paragraphIndex = position.paragraphIndex
        characterOffset = position.characterOffset
        self.normalizedProgress = normalizedProgress
        updatedAt = .now
    }

    var position: ReadingPosition {
        ReadingPosition(chapterKey: chapterKey, chapterIndex: chapterIndex,
                        paragraphIndex: paragraphIndex, characterOffset: characterOffset)
    }
}

/// A Legado book source imported from yck (源仓库). Only supported sources
/// can be enabled; the enabled ones are the sources the app may fetch from.
@Model
final class BookSource {
    /// `bookSourceUrl`, the source's identity.
    @Attribute(.unique) var sourceURL: String
    var name: String
    var group: String?
    /// The translated `LegadoSource` as JSON.
    var rawJSON: Data
    /// The source's JSON object as imported, with the Legado fields the app
    /// doesn't use, for exporting. Nil for sources imported before export.
    var originalJSON: Data?
    var isEnabled: Bool
    /// Why the app can't run it; empty when supported.
    var unsupportedReasons: [String]
    /// The yck link it was imported from.
    var subscriptionURL: String?
    /// Why the last search on it failed (blocked, CAPTCHA, timeout, script
    /// error); nil after it last answered.
    var lastError: String?
    var lastCheckedAt: Date?
    /// Failed searches in a row.
    var failureCount: Int = 0
    var importedAt: Date
    var updatedAt: Date

    init(_ source: LegadoSource, original: Data?, subscriptionURL: String?) {
        sourceURL = source.bookSourceUrl
        name = source.bookSourceName
        group = source.bookSourceGroup
        rawJSON = source.encoded()
        originalJSON = original
        let reasons = SourceCompatibility.check(source).reasons
        unsupportedReasons = reasons
        isEnabled = reasons.isEmpty && source.enabled != false
        self.subscriptionURL = subscriptionURL
        importedAt = .now
        updatedAt = .now
    }

    func update(from source: LegadoSource, original: Data?, subscriptionURL: String?) {
        name = source.bookSourceName
        group = source.bookSourceGroup
        rawJSON = source.encoded()
        originalJSON = original ?? originalJSON
        unsupportedReasons = SourceCompatibility.check(source).reasons
        if !unsupportedReasons.isEmpty { isEnabled = false }
        self.subscriptionURL = subscriptionURL ?? self.subscriptionURL
        updatedAt = .now
    }

    var isSupported: Bool { unsupportedReasons.isEmpty }

    /// Can't be used: rules the app can't run, or the site failed last time.
    var isUnusable: Bool { !isSupported || lastError != nil }

    var legado: LegadoSource? { try? JSONDecoder().decode(LegadoSource.self, from: rawJSON) }
}

enum NovelNestSchema {
    static let models: [any PersistentModel.Type] = [Book.self, Chapter.self, ReadingProgress.self, BookSource.self]
}
