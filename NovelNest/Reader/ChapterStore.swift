import Foundation
import NovelNestCore

/// A place in the book. `paragraph == ReaderLocation.title` is the chapter
/// title above the first paragraph; `offset` counts characters (UTF-16)
/// into the paragraph, for pages that start partway through one.
struct ReaderLocation: Hashable {
    static let title = -1

    var chapter: Int
    var paragraph: Int
    var offset = 0

    static func start(of chapter: Int) -> ReaderLocation {
        ReaderLocation(chapter: chapter, paragraph: title)
    }
}

/// A request to move the reader, e.g. from the chapter buttons, the table of
/// contents or speech. A new `id` makes repeated jumps to the same place
/// distinct.
struct ReaderJump: Equatable {
    let id = UUID()
    var location: ReaderLocation
    /// Small moves (speech advancing a paragraph) animate; big ones don't.
    var animated = false
}

/// The book's chapters with their paragraphs split on demand, so a long
/// book doesn't load every chapter's text up front. A web chapter whose
/// text hasn't arrived shows a one-line placeholder.
final class ChapterStore {
    let chapters: [Chapter]
    private var paragraphCache: [Int: [String]] = [:]
    /// Bumped when a chapter's text arrives or fails, so its pages are
    /// laid out again.
    private var revisions: [Int: Int] = [:]
    private var failures: [Int: String] = [:]

    init(chapters: [Chapter]) {
        self.chapters = chapters
    }

    var count: Int { chapters.count }

    func contains(_ index: Int) -> Bool { chapters.indices.contains(index) }

    func title(_ index: Int) -> String { chapters[index].title }

    func paragraphs(_ index: Int) -> [String] {
        guard chapters[index].isDownloaded else {
            if let failure = failures[index] { return ["加载失败：\(failure)", "可以在右上角菜单中重新加载本章。"] }
            return ["正在加载…"]
        }
        if let cached = paragraphCache[index] { return cached }
        let paragraphs = chapters[index].paragraphs
        paragraphCache[index] = paragraphs
        return paragraphs
    }

    func revision(_ index: Int) -> Int { revisions[index, default: 0] }

    /// The chapter's text arrived, failed or is being fetched again.
    func contentChanged(_ index: Int, failure: String? = nil) {
        paragraphCache[index] = nil
        failures[index] = failure
        revisions[index, default: 0] += 1
    }

    /// Progress through the whole book, 0...1, from the stored paragraph
    /// counts (no chapter text is loaded).
    func progress(at location: ReaderLocation) -> Double {
        guard contains(location.chapter) else { return 0 }
        let position = ReadingPosition(chapterKey: nil, chapterIndex: location.chapter,
                                       paragraphIndex: max(location.paragraph, 0))
        return position.normalizedProgress(chapterCount: count,
                                           paragraphCount: chapters[location.chapter].paragraphCount)
    }
}
