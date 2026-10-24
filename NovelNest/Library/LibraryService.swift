import Foundation
import NovelNestCore
import SwiftData

/// Library operations shared by the views and the tests.
struct LibraryService {
    let context: ModelContext

    enum ImportError: LocalizedError {
        case unreadable(String)
        case notText
        case empty

        var errorDescription: String? {
            switch self {
            case .unreadable(let reason): "无法读取文件 / Could not read the file: \(reason)"
            case .notText: "无法识别文件编码 / Could not detect the text encoding."
            case .empty: "文件里没有内容 / The file is empty."
            }
        }
    }

    struct ImportResult {
        var book: Book
        /// The text still looks like 乱码 after trying every encoding.
        var looksGarbled: Bool
    }

    /// Reads a TXT file picked with `fileImporter`. Decoding and chapter
    /// splitting run off the main actor; only inserting touches the context.
    func importTXT(at url: URL) async throws -> ImportResult {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw ImportError.unreadable(error.localizedDescription)
        }
        let fileName = url.lastPathComponent
        let imported = try await Task.detached(priority: .userInitiated) {
            try Self.parse(data: data, fileName: fileName)
        }.value
        return ImportResult(book: insert(imported, fileName: fileName), looksGarbled: imported.quality.isGarbled)
    }

    nonisolated static func parse(data: Data, fileName: String) throws -> ImportedBook {
        do {
            return try TXTImporter.importBook(data: data, fileName: fileName)
        } catch TXTImportError.undecodable {
            throw ImportError.notText
        } catch TXTImportError.empty {
            throw ImportError.empty
        }
    }

    @discardableResult
    func insert(_ imported: ImportedBook, fileName: String?) -> Book {
        let book = Book(title: imported.title, author: imported.author, script: imported.script,
                        encoding: imported.encoding, importedFileName: fileName)
        context.insert(book)
        book.chapters = imported.chapters.enumerated().map { Chapter(index: $0, split: $1) }
        try? context.save()
        return book
    }

    /// Called only when the user explicitly opens a book (spec §6).
    func recordOpen(_ book: Book, at date: Date = .now) {
        book.lastOpenedAt = date
        try? context.save()
    }

    /// Saves the reading position, creating the progress record if needed.
    func saveProgress(_ book: Book, position: ReadingPosition, at date: Date = .now) {
        let chapters = book.orderedChapters
        let paragraphCount = chapters.indices.contains(position.chapterIndex)
            ? chapters[position.chapterIndex].paragraphCount : 0
        let progress = position.normalizedProgress(chapterCount: chapters.count, paragraphCount: paragraphCount)

        if let existing = book.progress {
            existing.chapterKey = position.chapterKey
            existing.chapterIndex = position.chapterIndex
            existing.paragraphIndex = position.paragraphIndex
            existing.characterOffset = position.characterOffset
            existing.normalizedProgress = progress
            existing.updatedAt = date
        } else {
            book.progress = ReadingProgress(position: position, normalizedProgress: progress)
        }
        book.lastReadAt = date
        try? context.save()
    }

    /// Where to open the book: the saved position, restored by chapter ID
    /// and falling back to the nearest chapter (spec §7).
    func restorePosition(for book: Book) -> ReadingPositionResolver.Resolved? {
        let chapters = book.orderedChapters
        let saved = book.progress?.position ?? ReadingPosition(chapterKey: nil, chapterIndex: 0)
        return ReadingPositionResolver.resolve(saved, chapterKeys: chapters.map(\.id.uuidString)) {
            chapters[$0].paragraphCount
        }
    }

    /// Deletes the book with its chapters and progress (cascade).
    func delete(_ book: Book) {
        context.delete(book)
        try? context.save()
    }
}
