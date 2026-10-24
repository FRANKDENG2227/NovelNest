import Foundation

/// Kinds of chapters stored in `Chapter.chapterKind` (spec §11).
public enum ChapterKind: String, Sendable, Codable, CaseIterable {
    case normal
    case prologue
    case extra
    case authorNote
    case unknown
}

public struct ParsedTitle: Sendable, Equatable {
    public enum Role: Sendable, Equatable {
        case chapter(ChapterKind)
        case volume
    }

    public var role: Role
    /// Trimmed title line, exactly as written.
    public var title: String
    /// Number from 第N章 / 第N卷, used only for gap and duplicate warnings.
    public var number: Int?
}

/// Recognises chapter and volume title lines (spec §10A.5).
///
/// Simplified and traditional keywords are both listed because text is never
/// converted between scripts.
public enum ChapterTitleParser {
    /// Longer lines are treated as prose, never as titles.
    public static let maxTitleLength = 40

    private static let number = "([\(ChineseNumeral.characterClass)]+)"
    /// 章 and 回 may run straight into the title (第一章初入江湖); 节 needs a
    /// separator so prose such as 第三节课 is not mistaken for a title.
    private static let chapterPattern = try! NSRegularExpression(
        pattern: "^第\\s*\(number)\\s*(?:[章回]|[节節](?=$|[\\s:：、.．\\-—·]))")
    private static let volumePattern = try! NSRegularExpression(
        pattern: "^第\\s*\(number)\\s*[卷集部篇](?=$|[\\s:：、.．\\-—·])")

    private static let specialKeywords: [(ChapterKind, [String])] = [
        (.authorNote, ["完本感言", "上架感言", "请假条", "請假條", "单章", "單章", "感言", "公告"]),
        (.prologue, ["序章", "楔子", "引子", "序言", "前言"]),
        (.extra, ["番外", "外传", "外傳", "后记", "後記", "尾声", "尾聲"]),
    ]

    public static func parse(_ line: String) -> ParsedTitle? {
        let title = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= maxTitleLength,
              !title.contains("。"), !title.hasSuffix("！"), !title.hasSuffix("？") else { return nil }

        if let digits = numberText(in: title, matching: volumePattern) {
            return ParsedTitle(role: .volume, title: title, number: ChineseNumeral.parse(digits))
        }
        if let digits = numberText(in: title, matching: chapterPattern) {
            return ParsedTitle(role: .chapter(.normal), title: title, number: ChineseNumeral.parse(digits))
        }
        for (kind, keywords) in specialKeywords where keywords.contains(where: title.hasPrefix) {
            return ParsedTitle(role: .chapter(kind), title: title, number: nil)
        }
        return nil
    }

    /// The numeral captured by `pattern`, or nil if the title doesn't match.
    private static func numberText(in title: String, matching pattern: NSRegularExpression) -> String? {
        let range = NSRange(title.startIndex..., in: title)
        guard let match = pattern.firstMatch(in: title, range: range),
              let numberRange = Range(match.range(at: 1), in: title) else { return nil }
        return String(title[numberRange])
    }
}
