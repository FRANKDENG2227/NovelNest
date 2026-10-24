import Foundation

public struct SplitChapter: Sendable, Equatable {
    public var title: String
    public var kind: ChapterKind
    public var parsedNumber: Int?
    public var volumeTitle: String?
    /// Cleaned paragraphs without leading indentation; the reader adds it.
    public var paragraphs: [String]

    public var content: String { paragraphs.joined(separator: "\n") }
}

/// Splits a plain-text novel into chapters (spec §10A.5).
public enum TXTChapterSplitter {
    /// Size of the parts used when a file contains no chapter titles at all.
    public static let fallbackPartLength = 5_000

    public static func split(_ text: String) -> [SplitChapter] {
        var chapters: [SplitChapter] = []
        var volumeTitle: String?
        var current = SplitChapter(title: "前言", kind: .prologue, parsedNumber: nil, volumeTitle: nil, paragraphs: [])
        var sawTitle = false

        func finishCurrent() {
            // Empty chapters are dropped. This also discards the title-only
            // table of contents that many TXT files start with.
            if !current.paragraphs.isEmpty { chapters.append(current) }
        }

        for line in PlainTextCleaner.paragraphs(of: text) {
            // A title repeated on the next line starts an empty chapter that
            // finishCurrent() drops, so duplicates need no special case.
            guard let parsed = ChapterTitleParser.parse(line) else {
                current.paragraphs.append(line)
                continue
            }
            switch parsed.role {
            case .volume:
                volumeTitle = parsed.title
            case .chapter(let kind):
                finishCurrent()
                sawTitle = true
                current = SplitChapter(title: parsed.title, kind: kind, parsedNumber: parsed.number,
                                       volumeTitle: volumeTitle, paragraphs: [])
            }
        }
        finishCurrent()

        if !sawTitle, let only = chapters.first {
            return splitIntoParts(only.paragraphs)
        }
        return chapters
    }

    /// Fallback for files without titles: parts of roughly equal length,
    /// broken only at paragraph boundaries.
    static func splitIntoParts(_ paragraphs: [String]) -> [SplitChapter] {
        var parts: [[String]] = [[]]
        var length = 0
        for paragraph in paragraphs {
            if length >= fallbackPartLength {
                parts.append([])
                length = 0
            }
            parts[parts.count - 1].append(paragraph)
            length += paragraph.count
        }
        return parts.enumerated().map { index, paragraphs in
            SplitChapter(title: "第\(index + 1)部分", kind: .normal, parsedNumber: index + 1,
                         volumeTitle: nil, paragraphs: paragraphs)
        }
    }
}

/// Layout-only cleanup for imported plain text. Wording and punctuation are
/// never changed (spec §10A.4).
public enum PlainTextCleaner {
    private static let zeroWidth: Set<Unicode.Scalar> = ["\u{200B}", "\u{200C}", "\u{200D}", "\u{FEFF}"]

    /// Non-empty, trimmed paragraphs. Full-width (U+3000) indentation,
    /// tabs and zero-width characters are removed.
    public static func paragraphs(of text: String) -> [String] {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: text.unicodeScalars.filter { !zeroWidth.contains($0) })
        return String(scalars)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
