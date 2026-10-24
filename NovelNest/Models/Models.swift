import Foundation
import NovelNestCore
import SwiftData

// SwiftData models for the local library (spec §11). Fields for web
// sources (sourceId, sourceURL, page counts, …) come with Phase 4.

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

enum NovelNestSchema {
    static let models: [any PersistentModel.Type] = [Book.self, Chapter.self, ReadingProgress.self]
}
