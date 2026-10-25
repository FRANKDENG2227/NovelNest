import Foundation

/// Finds the chapter to continue from after switching a book to another
/// source, whose contents may have extra or missing entries.
public enum ChapterMatcher {
    /// The index in `titles` of the chapter titled `title`: the same title
    /// (ignoring spaces and punctuation), else the same 第N章 number, else
    /// `fallback` clamped to the list. Ties go to the one nearest `fallback`.
    public static func index(of title: String?, in titles: [String], fallback: Int) -> Int {
        guard !titles.isEmpty else { return 0 }
        let clamped = min(max(fallback, 0), titles.count - 1)
        guard let title else { return clamped }
        func nearest(_ candidates: [Int]) -> Int? { candidates.min { abs($0 - clamped) < abs($1 - clamped) } }

        let key = normalize(title)
        if !key.isEmpty, let match = nearest(titles.indices.filter { normalize(titles[$0]) == key }) { return match }
        if let number = number(in: title),
           let match = nearest(titles.indices.filter { Self.number(in: titles[$0]) == number }) {
            return match
        }
        return clamped
    }

    static func normalize(_ text: String) -> String {
        String(text.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.punctuationCharacters.contains($0)
                && !CharacterSet.symbols.contains($0)
        }.map(Character.init)).lowercased()
    }

    private static func number(in title: String) -> Int? {
        guard let parsed = ChapterTitleParser.parse(title), case .chapter = parsed.role else { return nil }
        return parsed.number
    }
}
