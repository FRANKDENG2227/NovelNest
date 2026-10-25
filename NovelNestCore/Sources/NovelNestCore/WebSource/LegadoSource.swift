import Foundation

/// A Legado (阅读) "book source" as published on yck (源仓库), reduced to the
/// fields NovelNest translates (spec §10). Other Legado keys are ignored;
/// what the app can run is decided by `SourceCompatibility`.
public struct LegadoSource: Sendable, Codable, Equatable {
    public var bookSourceUrl: String
    public var bookSourceName: String
    public var bookSourceGroup: String?
    /// 0 is text; audio, image and file sources aren't supported.
    public var bookSourceType: Int?
    public var enabled: Bool?
    /// JSON object of request headers, as a string.
    public var header: String?
    public var loginUrl: String?
    /// Shared JavaScript run before the source's scripts.
    public var jsLib: String?
    public var searchUrl: String?
    public var ruleSearch: SearchRule?
    public var ruleBookInfo: BookInfoRule?
    public var ruleToc: TocRule?
    public var ruleContent: ContentRule?

    public struct SearchRule: Sendable, Codable, Equatable {
        public var bookList, name, author, kind, lastChapter, intro, coverUrl, bookUrl, wordCount: String?

        public init(bookList: String?, name: String?, author: String? = nil, kind: String? = nil, lastChapter: String? = nil,
                    intro: String? = nil, coverUrl: String? = nil, bookUrl: String?, wordCount: String? = nil) {
            self.bookList = bookList; self.name = name; self.author = author; self.kind = kind
            self.lastChapter = lastChapter; self.intro = intro; self.coverUrl = coverUrl; self.bookUrl = bookUrl
            self.wordCount = wordCount
        }
    }

    public struct BookInfoRule: Sendable, Codable, Equatable {
        public var `init`, name, author, kind, lastChapter, intro, coverUrl, tocUrl, wordCount: String?

        public init(name: String? = nil, author: String? = nil, kind: String? = nil, lastChapter: String? = nil,
                    intro: String? = nil, coverUrl: String? = nil, tocUrl: String? = nil) {
            self.name = name; self.author = author; self.kind = kind; self.lastChapter = lastChapter
            self.intro = intro; self.coverUrl = coverUrl; self.tocUrl = tocUrl
        }
    }

    public struct TocRule: Sendable, Codable, Equatable {
        public var chapterList, chapterName, chapterUrl, nextTocUrl: String?

        public init(chapterList: String?, chapterName: String?, chapterUrl: String?, nextTocUrl: String? = nil) {
            self.chapterList = chapterList; self.chapterName = chapterName
            self.chapterUrl = chapterUrl; self.nextTocUrl = nextTocUrl
        }
    }

    public struct ContentRule: Sendable, Codable, Equatable {
        public var content, nextContentUrl, replaceRegex: String?

        public init(content: String?, nextContentUrl: String? = nil, replaceRegex: String? = nil) {
            self.content = content; self.nextContentUrl = nextContentUrl; self.replaceRegex = replaceRegex
        }
    }

    public init(bookSourceUrl: String, bookSourceName: String, searchUrl: String? = nil,
                ruleSearch: SearchRule? = nil, ruleBookInfo: BookInfoRule? = nil,
                ruleToc: TocRule? = nil, ruleContent: ContentRule? = nil) {
        self.bookSourceUrl = bookSourceUrl
        self.bookSourceName = bookSourceName
        self.searchUrl = searchUrl
        self.ruleSearch = ruleSearch
        self.ruleBookInfo = ruleBookInfo
        self.ruleToc = ruleToc
        self.ruleContent = ruleContent
    }

    /// Decodes a yck export: a JSON array of sources or a single source.
    /// Entries that aren't sources are skipped.
    public static func decodeList(_ data: Data) throws -> [LegadoSource] {
        let entries = try decodeEntries(data)
        return entries.map(\.source)
    }

    /// Like `decodeList`, keeping each source's JSON object as it came, with
    /// the Legado fields NovelNest doesn't use, so it can be exported intact.
    public static func decodeEntries(_ data: Data) throws -> [LegadoSourceEntry] {
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        let objects = object as? [Any] ?? [object]
        let entries: [LegadoSourceEntry] = objects.compactMap { item in
            guard item is [String: Any], let original = try? JSONSerialization.data(withJSONObject: item),
                  let source = try? JSONDecoder().decode(LegadoSource.self, from: original) else { return nil }
            return LegadoSourceEntry(source: source, original: original)
        }
        if entries.isEmpty, !(object is [Any]) {
            // A single object that isn't a source: report why.
            _ = try JSONDecoder().decode(LegadoSource.self, from: data)
        }
        return entries
    }

    /// The JSON to store, so a source can be re-read after an app update.
    public func encoded() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data()
    }
}

/// A decoded source with its original JSON object.
public struct LegadoSourceEntry: Sendable {
    public var source: LegadoSource
    public var original: Data

    public init(source: LegadoSource, original: Data) {
        self.source = source
        self.original = original
    }
}

/// Writes sources as a Legado (阅读) book-source JSON array, the format
/// yck and 阅读-compatible apps import.
public enum LegadoSourceExport {
    public struct Item: Sendable {
        /// The JSON object as imported; nil falls back to the fields
        /// NovelNest kept.
        public var original: Data?
        public var source: LegadoSource
        public var isEnabled: Bool

        public init(original: Data?, source: LegadoSource, isEnabled: Bool) {
            self.original = original
            self.source = source
            self.isEnabled = isEnabled
        }
    }

    /// Each source's original object with `enabled` set to the user's
    /// choice here; everything else is exported as imported.
    public static func json(_ items: [Item]) throws -> Data {
        let objects: [[String: Any]] = items.compactMap { item in
            let data = item.original ?? item.source.encoded()
            guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
            object["enabled"] = item.isEnabled
            return object
        }
        return try JSONSerialization.data(withJSONObject: objects, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
}

// Rule values in the wild are sometimes numbers or booleans; read them as
// text rather than failing the whole source.
extension LegadoSource {
    enum CodingKeys: String, CodingKey {
        case bookSourceUrl, bookSourceName, bookSourceGroup, bookSourceType, enabled, header, loginUrl, jsLib
        case searchUrl, ruleSearch, ruleBookInfo, ruleToc, ruleContent
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bookSourceUrl = try c.decode(String.self, forKey: .bookSourceUrl)
        bookSourceName = c.decodeLenient(.bookSourceName) ?? bookSourceUrl
        bookSourceGroup = c.decodeLenient(.bookSourceGroup)
        bookSourceType = (try? c.decodeIfPresent(Int.self, forKey: .bookSourceType)) ?? nil
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? nil
        header = c.decodeLenient(.header)
        loginUrl = c.decodeLenient(.loginUrl)
        jsLib = c.decodeLenient(.jsLib)
        searchUrl = c.decodeLenient(.searchUrl)
        ruleSearch = (try? c.decodeIfPresent(SearchRule.self, forKey: .ruleSearch)) ?? nil
        ruleBookInfo = (try? c.decodeIfPresent(BookInfoRule.self, forKey: .ruleBookInfo)) ?? nil
        ruleToc = (try? c.decodeIfPresent(TocRule.self, forKey: .ruleToc)) ?? nil
        ruleContent = (try? c.decodeIfPresent(ContentRule.self, forKey: .ruleContent)) ?? nil
    }
}

extension LegadoSource.SearchRule {
    enum CodingKeys: String, CodingKey { case bookList, name, author, kind, lastChapter, intro, coverUrl, bookUrl, wordCount }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bookList = c.decodeLenient(.bookList); name = c.decodeLenient(.name); author = c.decodeLenient(.author)
        kind = c.decodeLenient(.kind); lastChapter = c.decodeLenient(.lastChapter); intro = c.decodeLenient(.intro)
        coverUrl = c.decodeLenient(.coverUrl); bookUrl = c.decodeLenient(.bookUrl); wordCount = c.decodeLenient(.wordCount)
    }
}

extension LegadoSource.BookInfoRule {
    enum CodingKeys: String, CodingKey { case `init`, name, author, kind, lastChapter, intro, coverUrl, tocUrl, wordCount }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        `init` = c.decodeLenient(.`init`); name = c.decodeLenient(.name); author = c.decodeLenient(.author)
        kind = c.decodeLenient(.kind); lastChapter = c.decodeLenient(.lastChapter); intro = c.decodeLenient(.intro)
        coverUrl = c.decodeLenient(.coverUrl); tocUrl = c.decodeLenient(.tocUrl); wordCount = c.decodeLenient(.wordCount)
    }
}

extension LegadoSource.TocRule {
    enum CodingKeys: String, CodingKey { case chapterList, chapterName, chapterUrl, nextTocUrl }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        chapterList = c.decodeLenient(.chapterList); chapterName = c.decodeLenient(.chapterName)
        chapterUrl = c.decodeLenient(.chapterUrl); nextTocUrl = c.decodeLenient(.nextTocUrl)
    }
}

extension LegadoSource.ContentRule {
    enum CodingKeys: String, CodingKey { case content, nextContentUrl, replaceRegex }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        content = c.decodeLenient(.content); nextContentUrl = c.decodeLenient(.nextContentUrl)
        replaceRegex = c.decodeLenient(.replaceRegex)
    }
}

extension KeyedDecodingContainer {
    /// A string, number or boolean as text; nil when missing or empty.
    func decodeLenient(_ key: Key) -> String? {
        let text: String? = if let string = try? decodeIfPresent(String.self, forKey: key) { string }
            else if let int = try? decodeIfPresent(Int.self, forKey: key) { String(int) }
            else if let double = try? decodeIfPresent(Double.self, forKey: key) { String(double) }
            else if let bool = try? decodeIfPresent(Bool.self, forKey: key) { String(bool) }
            else { nil }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
}
