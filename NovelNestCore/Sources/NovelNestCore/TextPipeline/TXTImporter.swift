import Foundation

public struct ImportedBook: Sendable {
    public var title: String
    public var author: String?
    public var encoding: TextEncoding
    public var quality: TextQuality
    public var script: ChineseScript
    public var chapters: [SplitChapter]
}

public enum TXTImportError: Error, Equatable {
    case undecodable
    case empty
}

/// Turns the bytes of a TXT file into a book ready to be stored.
public enum TXTImporter {
    public static func importBook(data: Data, fileName: String) throws -> ImportedBook {
        guard let decoded = EncodingDetector.decode(data) else { throw TXTImportError.undecodable }
        let chapters = TXTChapterSplitter.split(decoded.text)
        guard !chapters.isEmpty else { throw TXTImportError.empty }

        let (title, author) = parseFileName(fileName)
        return ImportedBook(
            title: title,
            author: author ?? findAuthor(in: decoded.text),
            encoding: decoded.encoding,
            quality: decoded.quality,
            script: ScriptDetector.detect(decoded.text),
            chapters: chapters
        )
    }

    /// Reads names such as `《书名》作者：某某.txt` or `书名.txt`.
    static func parseFileName(_ fileName: String) -> (title: String, author: String?) {
        var name = fileName
        if name.lowercased().hasSuffix(".txt") { name.removeLast(4) }

        var author: String?
        for marker in ["作者：", "作者:", "作者"] {
            if let range = name.range(of: marker) {
                author = String(name[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                name = String(name[..<range.lowerBound])
                break
            }
        }
        if let open = name.firstIndex(of: "《"), let close = name[open...].firstIndex(of: "》") {
            name = String(name[name.index(after: open)..<close])
        }
        let title = name.trimmingCharacters(in: .whitespaces)
        return (title.isEmpty ? fileName : title, author?.isEmpty == true ? nil : author)
    }

    /// Looks for an `作者：某某` line near the start of the file.
    static func findAuthor(in text: String) -> String? {
        for line in PlainTextCleaner.paragraphs(of: String(text.prefix(2_000))).prefix(20) {
            for marker in ["作者：", "作者:"] where line.hasPrefix(marker) {
                let author = line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
                if !author.isEmpty { return author }
            }
        }
        return nil
    }
}
