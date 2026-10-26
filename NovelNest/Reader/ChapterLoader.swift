import Foundation
import NovelNestCore
import Observation
import SwiftData

/// Fetches a web book's chapter text when it's read, keeps it locally, and
/// prefetches the next two chapters. After a block or rate limit it stops
/// fetching on its own until the reader asks to reload (spec §9).
@MainActor @Observable
final class ChapterLoader {
    /// Bumped whenever a chapter's text arrives or fails.
    private(set) var version = 0

    @ObservationIgnored private let store: ChapterStore
    @ObservationIgnored private let library: LibraryService
    @ObservationIgnored private let client: WebBookClient?
    @ObservationIgnored private var tasks: [Int: Task<Bool, Never>] = [:]
    /// Why fetching stopped (blocked, CAPTCHA); cleared by `reload`.
    @ObservationIgnored private var halted: String?
    @ObservationIgnored private var retryAfter: Date?

    init(store: ChapterStore, book: Book, context: ModelContext) {
        self.store = store
        let library = LibraryService(context: context)
        self.library = library
        client = book.sourceURL.flatMap { library.source(withURL: $0) }.map { WebBookClient(source: $0) }
    }

    /// The chapter's text, fetching it if needed. False when it couldn't be had.
    @discardableResult
    func ensure(_ index: Int) async -> Bool {
        guard store.contains(index) else { return false }
        let chapter = store.chapters[index]
        if chapter.isDownloaded { return true }
        if let task = tasks[index] { return await task.value }
        if let reason = blockReason() {
            fail(index, reason)
            return false
        }
        guard let client, let url = chapter.sourceURL else {
            fail(index, "书源已删除或不可用")
            return false
        }
        let next = store.contains(index + 1) ? store.chapters[index + 1].sourceURL : nil
        let title = chapter.title
        let task = Task { () -> Bool in
            do {
                let paragraphs = try await client.chapterText(at: url, title: title, nextChapterURL: next)
                // 换源 may have replaced the chapters meanwhile.
                guard !Task.isCancelled, !chapter.isDeleted else { return false }
                library.storeChapterText(chapter, paragraphs: paragraphs)
                store.contentChanged(index)
                version += 1
                return true
            } catch {
                guard !Task.isCancelled, !chapter.isDeleted else { return false }
                record(error)
                fail(index, error.localizedDescription)
                return false
            }
        }
        tasks[index] = task
        let loaded = await task.value
        tasks[index] = nil
        return loaded
    }

    /// Stops fetching, e.g. before the chapters are replaced.
    func cancel() {
        client?.cancelScripts()
        for task in tasks.values { task.cancel() }
        tasks = [:]
        halted = "已停止"
    }

    /// The chapter being read, then the next two, one at a time.
    func prepare(around index: Int) {
        Task {
            guard await ensure(index) else { return }
            for next in [index + 1, index + 2] where store.contains(next) {
                guard await ensure(next) else { return }
            }
        }
    }

    /// Fetches the chapter again, also after a block.
    func reload(_ index: Int) {
        guard store.contains(index) else { return }
        halted = nil
        retryAfter = nil
        library.discardChapterText(store.chapters[index])
        store.contentChanged(index)
        version += 1
        prepare(around: index)
    }

    private func fail(_ index: Int, _ message: String) {
        store.contentChanged(index, failure: message)
        version += 1
    }

    private func record(_ error: Error) {
        switch error as? WebSourceError {
        case .blocked, .captcha, .disallowedHost, .runawayScript: halted = error.localizedDescription
        case .rateLimited(let after): retryAfter = .now.addingTimeInterval(after ?? 60)
        default: break
        }
    }

    private func blockReason() -> String? {
        if let halted { return halted }
        if let retryAfter, retryAfter > .now { return WebSourceError.rateLimited(retryAfter: retryAfter.timeIntervalSinceNow).localizedDescription }
        return nil
    }
}
