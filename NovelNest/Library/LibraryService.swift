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

    // MARK: Book sources

    struct SourceImportSummary: Equatable {
        var added = 0
        var updated = 0
        /// Imported but can't run (scripts, XPath, …); left disabled.
        var unsupported = 0
    }

    enum SourceImportError: LocalizedError, Equatable {
        case invalidLink
        /// Plain http: anyone on the network could swap in other sources.
        case insecure
        case download(String)
        case notSources

        var errorDescription: String? {
            switch self {
            case .invalidLink: "链接无效。请粘贴 http(s) 书源链接或 yuedu:// 导入链接。"
            case .insecure: "这个链接没有加密（http）。在公共 Wi-Fi 等网络上，别人可以把内容换成恶意书源。"
            case .download(let reason): "下载书源失败：\(reason)"
            case .notSources: "这个链接里没有书源。"
            }
        }
    }

    /// The JSON link inside a yck link: plain `https://…json`, or
    /// `yuedu://booksource/importonline?src=…` from the 网络导入 button.
    nonisolated static func subscriptionURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) ?? URL(string: trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "") else { return nil }
        if url.scheme?.lowercased() == "yuedu" {
            let src = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "src" }?.value
            return src.flatMap { subscriptionURL(from: $0) }
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
        return url
    }

    /// Downloads a yck subscription and adds or updates its sources. A
    /// source already here keeps the user's on/off choice. Plain http
    /// links need `allowInsecure`, after the user has been warned.
    func importSources(from link: String, allowInsecure: Bool = false) async throws -> SourceImportSummary {
        guard let url = Self.subscriptionURL(from: link) else { throw SourceImportError.invalidLink }
        guard url.scheme?.lowercased() == "https" || allowInsecure else { throw SourceImportError.insecure }
        let data: Data
        do {
            var request = URLRequest(url: url, timeoutInterval: 30)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (body, response) = try await URLSession.shared.limitedData(for: request, maxBytes: 20_000_000)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw SourceImportError.download("HTTP \(http.statusCode)")
            }
            data = body
        } catch let error as SourceImportError {
            throw error
        } catch WebSourceError.tooLarge {
            throw SourceImportError.download("文件太大（超过 20 MB）")
        } catch {
            throw SourceImportError.download(error.localizedDescription)
        }
        let entries = try await Task.detached(priority: .userInitiated) {
            (try? LegadoSource.decodeEntries(data)) ?? []
        }.value
        guard !entries.isEmpty else { throw SourceImportError.notSources }
        return upsert(entries, subscriptionURL: url.absoluteString)
    }

    @discardableResult
    func upsert(_ sources: [LegadoSource], subscriptionURL: String?) -> SourceImportSummary {
        upsert(sources.map { LegadoSourceEntry(source: $0, original: $0.encoded()) }, subscriptionURL: subscriptionURL)
    }

    @discardableResult
    func upsert(_ entries: [LegadoSourceEntry], subscriptionURL: String?) -> SourceImportSummary {
        let existing = Dictionary(((try? context.fetch(FetchDescriptor<BookSource>())) ?? []).map { ($0.sourceURL, $0) },
                                  uniquingKeysWith: { first, _ in first })
        var summary = SourceImportSummary()
        var seen: Set<String> = []
        for entry in entries where seen.insert(entry.source.bookSourceUrl).inserted {
            let source = entry.source
            let model: BookSource
            if let current = existing[source.bookSourceUrl] {
                current.update(from: source, original: entry.original, subscriptionURL: subscriptionURL)
                model = current
                summary.updated += 1
            } else {
                model = BookSource(source, original: entry.original, subscriptionURL: subscriptionURL)
                context.insert(model)
                summary.added += 1
            }
            if !model.isSupported { summary.unsupported += 1 }
        }
        try? context.save()
        return summary
    }

    /// Enabled, supported sources to search, the default one first.
    func searchableSources(defaultSource: String? = nil) -> [LegadoSource] {
        let descriptor = FetchDescriptor<BookSource>(predicate: #Predicate { $0.isEnabled }, sortBy: [SortDescriptor(\.importedAt)])
        let sources = ((try? context.fetch(descriptor)) ?? []).filter(\.isSupported).compactMap(\.legado)
        return sources.filter { $0.bookSourceUrl == defaultSource } + sources.filter { $0.bookSourceUrl != defaultSource }
    }

    func source(withURL sourceURL: String) -> LegadoSource? {
        let descriptor = FetchDescriptor<BookSource>(predicate: #Predicate { $0.sourceURL == sourceURL })
        return (try? context.fetch(descriptor))?.first?.legado
    }

    /// Remembers whether a source answered a search. Rate limits aren't
    /// counted against it; a runaway script (time, request or nesting
    /// limit) turns the source off.
    func recordCheck(_ event: SourceSearchEvent) {
        let url = event.sourceURL
        let descriptor = FetchDescriptor<BookSource>(predicate: #Predicate { $0.sourceURL == url })
        guard let source = (try? context.fetch(descriptor))?.first else { return }
        switch event.outcome {
        case .results:
            source.lastError = nil
            source.failureCount = 0
        case .failed(_, .temporary):
            return
        case .failed(let message, let kind):
            source.lastError = message
            source.failureCount += 1
            if kind == .runaway { source.isEnabled = false }
        }
        source.lastCheckedAt = .now
        try? context.save()
    }

    /// The sources as a Legado book-source JSON array, with each one's
    /// on/off state, for other apps to import.
    func exportSources(_ sources: [BookSource]) throws -> Data {
        try LegadoSourceExport.json(sources.compactMap { model in
            model.legado.map { LegadoSourceExport.Item(original: model.originalJSON, source: $0, isEnabled: model.isEnabled) }
        })
    }

    /// Writes the export to a temporary file named for sharing.
    func exportSourcesFile(_ sources: [BookSource]) throws -> URL {
        let data = try exportSources(sources)
        let stamp = Date.now.formatted(.iso8601.year().month().day().dateSeparator(.omitted))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("NovelNest书源-\(stamp)-\(sources.count)个.json")
        try data.write(to: url, options: .atomic)
        return url
    }

    func deleteSources(_ sources: [BookSource]) {
        for source in sources { context.delete(source) }
        try? context.save()
    }

    // MARK: Web books

    /// The copy of a web book already here (on the shelf or being read).
    func webBook(bookURL: String) -> Book? {
        let descriptor = FetchDescriptor<Book>(predicate: #Predicate { $0.bookURL == bookURL })
        return (try? context.fetch(descriptor))?.first
    }

    /// Adds a book found with a source: its details and table of contents.
    /// Chapter text is fetched when the chapter is read. Adding isn't
    /// opening, so `lastOpenedAt` stays nil (spec §6). With `onShelf`
    /// false it's only kept while it's being read. Books are told apart by
    /// their page, so the same title from another source is another book.
    @discardableResult
    func addWebBook(_ detail: WebBookDetail, toc: [WebTOCItem], onShelf: Bool = true) -> Book {
        if let existing = webBook(bookURL: detail.bookURL) {
            if onShelf { addToShelf(existing) }
            return existing
        }
        let sample = ([detail.title, detail.intro ?? ""] + toc.prefix(50).map(\.title)).joined(separator: "\n")
        let book = Book(title: detail.title, author: detail.author, script: ScriptDetector.detect(sample),
                        encoding: .utf8, importedFileName: nil)
        book.sourceURL = detail.sourceURL
        book.sourceName = detail.sourceName
        book.bookURL = detail.bookURL
        book.tocURL = detail.tocURL
        book.coverURL = detail.coverURL?.absoluteString
        book.intro = detail.intro
        book.category = detail.category
        book.serialStatus = detail.serialStatus.rawValue
        book.latestChapterTitle = detail.latestChapter
        book.isFinished = false
        book.isOnShelf = onShelf
        context.insert(book)
        book.chapters = toc.enumerated().map { Chapter(index: $0, toc: $1) }
        try? context.save()
        return book
    }

    func addToShelf(_ book: Book) {
        guard !book.isOnShelf else { return }
        book.isOnShelf = true
        try? context.save()
    }

    /// Removes a book that was read without being added to the shelf,
    /// unless it was opened again after `leftAt`.
    func deleteIfNotOnShelf(_ book: Book, leftAt: Date = .now) {
        guard !book.isDeleted, !book.isOnShelf, (book.lastOpenedAt ?? .distantPast) <= leftAt else { return }
        delete(book)
    }

    /// Books left over from reading without adding, e.g. when the app quit.
    func purgeBooksNotOnShelf() {
        let descriptor = FetchDescriptor<Book>(predicate: #Predicate { !$0.isOnShelf })
        for book in (try? context.fetch(descriptor)) ?? [] { context.delete(book) }
        try? context.save()
    }

    /// Moves a web book to another source (换源): its details and contents
    /// are replaced, and reading continues at the matching chapter, whose
    /// index is returned. Downloaded text from the old source is dropped.
    @discardableResult
    func switchSource(_ book: Book, to detail: WebBookDetail, toc: [WebTOCItem], currentChapter: Int) -> Int {
        let old = book.orderedChapters
        let title = old.indices.contains(currentChapter) ? old[currentChapter].title : nil
        for chapter in old { context.delete(chapter) }

        book.sourceURL = detail.sourceURL
        book.sourceName = detail.sourceName
        book.bookURL = detail.bookURL
        book.tocURL = detail.tocURL
        book.coverURL = detail.coverURL?.absoluteString ?? book.coverURL
        book.intro = detail.intro ?? book.intro
        book.category = detail.category ?? book.category
        book.serialStatus = detail.serialStatus.rawValue
        book.latestChapterTitle = detail.latestChapter
        book.updatedAt = .now
        let chapters = toc.enumerated().map { Chapter(index: $0, toc: $1) }
        book.chapters = chapters

        let target = ChapterMatcher.index(of: title, in: toc.map(\.title), fallback: currentChapter)
        if chapters.indices.contains(target) {
            let position = ReadingPosition(chapterKey: chapters[target].id.uuidString, chapterIndex: target)
            if let progress = book.progress {
                progress.chapterKey = position.chapterKey
                progress.chapterIndex = target
                progress.paragraphIndex = 0
                progress.characterOffset = 0
                progress.updatedAt = .now
            } else {
                book.progress = ReadingProgress(position: position, normalizedProgress: 0)
            }
        }
        try? context.save()
        return target
    }

    /// Keeps a fetched chapter's text locally.
    func storeChapterText(_ chapter: Chapter, paragraphs: [String]) {
        chapter.content = paragraphs.joined(separator: "\n")
        chapter.paragraphCount = paragraphs.count
        chapter.wordCount = paragraphs.reduce(0) { $0 + $1.count }
        chapter.isDownloaded = true
        try? context.save()
    }

    /// Fetches the chapter again next time it's read.
    func discardChapterText(_ chapter: Chapter) {
        guard chapter.sourceURL != nil else { return }
        chapter.isDownloaded = false
        try? context.save()
    }
}
