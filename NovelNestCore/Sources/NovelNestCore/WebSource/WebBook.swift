import Foundation

/// 连载 / 完结 (spec §10A.1).
public enum SerialStatus: String, Sendable, Codable {
    case ongoing
    case completed
    case unknown

    public init(text: String?) {
        guard let text else { self = .unknown; return }
        if ["完结", "完結", "完本", "全本"].contains(where: text.contains) { self = .completed }
        else if ["连载", "連載"].contains(where: text.contains) { self = .ongoing }
        else { self = .unknown }
    }
}

public struct WebSearchResult: Sendable, Hashable, Identifiable {
    /// `bookSourceUrl` of the source that found it.
    public var sourceURL: String
    public var sourceName: String
    public var title: String
    public var author: String?
    public var kind: String?
    public var latestChapter: String?
    public var intro: String?
    public var coverURL: URL?
    /// Absolute; may carry Legado `,{options}`.
    public var bookURL: String
    public var wordCount: String?

    public var id: String { sourceURL + "|" + bookURL }
}

public struct WebBookDetail: Sendable, Hashable {
    public var sourceURL: String
    public var sourceName: String
    public var bookURL: String
    public var tocURL: String
    public var title: String
    public var author: String?
    public var category: String?
    public var latestChapter: String?
    public var intro: String?
    public var coverURL: URL?
    public var wordCount: String?
    public var serialStatus: SerialStatus

    public init(sourceURL: String, sourceName: String, bookURL: String, tocURL: String, title: String,
                author: String?, category: String?, latestChapter: String?, intro: String?, coverURL: URL?,
                wordCount: String?, serialStatus: SerialStatus) {
        self.sourceURL = sourceURL
        self.sourceName = sourceName
        self.bookURL = bookURL
        self.tocURL = tocURL
        self.title = title
        self.author = author
        self.category = category
        self.latestChapter = latestChapter
        self.intro = intro
        self.coverURL = coverURL
        self.wordCount = wordCount
        self.serialStatus = serialStatus
    }
}

public struct WebTOCItem: Sendable, Hashable {
    public var title: String
    /// Absolute; may carry Legado `,{options}`.
    public var url: String
    public var volumeTitle: String?

    public init(title: String, url: String, volumeTitle: String? = nil) {
        self.title = title
        self.url = url
        self.volumeTitle = volumeTitle
    }
}

/// Search results from several sources for the same book.
public struct WebSearchGroup: Sendable, Hashable, Identifiable {
    public var id: String
    public var results: [WebSearchResult]

    public var best: WebSearchResult { results[0] }

    /// Adds results, merging those with the same title and author.
    public static func merge(_ results: [WebSearchResult], into groups: inout [WebSearchGroup]) {
        for result in results {
            let key = normalize(result.title) + "|" + normalize(result.author ?? "")
            if let index = groups.firstIndex(where: { $0.id == key }) {
                if !groups[index].results.contains(where: { $0.id == result.id }) { groups[index].results.append(result) }
            } else {
                groups.append(WebSearchGroup(id: key, results: [result]))
            }
        }
    }

    static func normalize(_ text: String) -> String {
        String(text.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.punctuationCharacters.contains($0)
        }.map(Character.init)).lowercased()
    }
}
