/// A saved place in a book (spec §7). Offsets refer to the cleaned chapter
/// text: `paragraphIndex` into its paragraphs, `characterOffset` within that
/// paragraph.
public struct ReadingPosition: Sendable, Equatable, Codable {
    /// Stable chapter identifier (the app's chapter UUID string or the
    /// source chapter ID), tried first when restoring.
    public var chapterKey: String?
    public var chapterIndex: Int
    public var paragraphIndex: Int
    public var characterOffset: Int

    public init(chapterKey: String?, chapterIndex: Int, paragraphIndex: Int = 0, characterOffset: Int = 0) {
        self.chapterKey = chapterKey
        self.chapterIndex = chapterIndex
        self.paragraphIndex = paragraphIndex
        self.characterOffset = characterOffset
    }

    /// Progress through the whole book, 0...1.
    public func normalizedProgress(chapterCount: Int, paragraphCount: Int) -> Double {
        guard chapterCount > 0 else { return 0 }
        let withinChapter = paragraphCount > 0 ? Double(paragraphIndex) / Double(paragraphCount) : 0
        return min(1, (Double(chapterIndex) + min(withinChapter, 1)) / Double(chapterCount))
    }
}

/// Restores a saved position after the chapter list may have changed
/// (spec §7): stable key first, then the nearest chapter index.
public enum ReadingPositionResolver {
    public enum Match: Sendable, Equatable {
        /// Same chapter found by its key; paragraph position is kept.
        case exact
        /// Chapter key missing or not found; fell back to the saved index.
        case nearestIndex
    }

    public struct Resolved: Sendable, Equatable {
        public var chapterIndex: Int
        public var paragraphIndex: Int
        public var characterOffset: Int
        public var match: Match
    }

    /// - Parameters:
    ///   - chapterKeys: current chapter keys in reading order.
    ///   - paragraphCount: number of paragraphs in a chapter, by index.
    public static func resolve(
        _ position: ReadingPosition,
        chapterKeys: [String],
        paragraphCount: (Int) -> Int
    ) -> Resolved? {
        guard !chapterKeys.isEmpty else { return nil }

        if let key = position.chapterKey, let index = chapterKeys.firstIndex(of: key) {
            let paragraphs = paragraphCount(index)
            let paragraph = min(position.paragraphIndex, max(paragraphs - 1, 0))
            let offset = paragraph == position.paragraphIndex ? position.characterOffset : 0
            return Resolved(chapterIndex: index, paragraphIndex: paragraph, characterOffset: offset, match: .exact)
        }
        // Chapter renumbered or deleted: start of the nearest chapter.
        let index = min(max(position.chapterIndex, 0), chapterKeys.count - 1)
        return Resolved(chapterIndex: index, paragraphIndex: 0, characterOffset: 0, match: .nearestIndex)
    }
}
