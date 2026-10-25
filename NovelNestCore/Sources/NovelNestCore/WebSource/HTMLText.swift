import Foundation
import SwiftSoup

/// Turns chapter content from a page into paragraphs. Only layout changes:
/// tags become line breaks, entities are decoded, and the cleanup of
/// `PlainTextCleaner` applies; wording is never changed (spec §10A.4).
public enum HTMLText {
    private static let blockTags: Set<String> = ["p", "div", "br", "h1", "h2", "h3", "h4", "h5", "h6", "li", "tr", "section", "article", "dd", "dt"]

    public static func paragraphs(of content: String) -> [String] {
        PlainTextCleaner.paragraphs(of: text(of: content))
    }

    /// The content with block tags and `<br>` as newlines.
    static func text(of content: String) -> String {
        guard content.contains("<") || content.contains("&"),
              let document = try? SwiftSoup.parseBodyFragment(content), let body = document.body() else {
            return content
        }
        // Source line breaks only matter when there is no markup for them.
        let hasMarkupBreaks = content.range(of: #"<(br|p|div)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
        var output = ""
        func walk(_ node: Node) {
            if let text = node as? TextNode {
                var piece = text.getWholeText().replacingOccurrences(of: "\u{00A0}", with: " ")
                if hasMarkupBreaks { piece = piece.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "") }
                output += piece
                return
            }
            guard let element = node as? Element else { return }
            let tag = element.tagName().lowercased()
            if tag == "script" || tag == "style" { return }
            let isBlock = blockTags.contains(tag)
            if isBlock { output += "\n" }
            for child in element.getChildNodes() { walk(child) }
            if isBlock, tag != "br" { output += "\n" }
        }
        walk(body)
        return output
    }

    /// Drops a first paragraph that only repeats the chapter title; the
    /// reader shows the title itself.
    static func removingRepeatedTitle(_ paragraphs: [String], title: String?) -> [String] {
        guard let title, let first = paragraphs.first else { return paragraphs }
        let normalize = { (text: String) in text.filter { !$0.isWhitespace } }
        return normalize(first) == normalize(title) ? Array(paragraphs.dropFirst()) : paragraphs
    }
}
