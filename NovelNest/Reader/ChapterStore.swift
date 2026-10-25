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
/// book doesn't load every chapter's text up front.
final class ChapterStore {
    let chapters: [Chapter]
    private var paragraphCache: [Int: [String]] = [:]

    init(chapters: [Chapter]) {
        self.chapters = chapters
    }

    var count: Int { chapters.count }

    func contains(_ index: Int) -> Bool { chapters.indices.contains(index) }

    func title(_ index: Int) -> String { chapters[index].title }

    func paragraphs(_ index: Int) -> [String] {
        if let cached = paragraphCache[index] { return cached }
        let paragraphs = chapters[index].paragraphs
        paragraphCache[index] = paragraphs
        return paragraphs
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
