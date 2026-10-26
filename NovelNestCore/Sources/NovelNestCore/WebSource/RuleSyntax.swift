import Foundation

/// Parsing helpers for the Legado rule syntax.
enum RuleSyntax {
    enum Combinator: String {
        /// First part with a non-empty result.
        case or = "||"
        /// All parts' results, one after another.
        case and = "&&"
        /// Parts' results interleaved.
        case interleave = "%%"
    }

    /// Splits a rule on the first kind of combinator found outside
    /// brackets, quotes and `{{…}}`.
    static func splitCombinators(_ rule: String) -> (parts: [String], combinator: Combinator?) {
        let chars = Array(rule)
        var depth = 0
        var quote: Character?
        var found: Combinator?
        var parts: [String] = []
        var current = ""
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if let q = quote {
                if c == q { quote = nil }
                current.append(c)
                i += 1
                continue
            }
            switch c {
            case "'", "\"": quote = c
            case "[", "(", "{": depth += 1
            case "]", ")", "}": depth = max(depth - 1, 0)
            default: break
            }
            if depth == 0, i + 1 < chars.count {
                let pair = String(chars[i...i + 1])
                if let combinator = Combinator(rawValue: pair), found == nil || found == combinator {
                    found = combinator
                    parts.append(current)
                    current = ""
                    i += 2
                    continue
                }
            }
            current.append(c)
            i += 1
        }
        parts.append(current)
        return (parts, found)
    }

    /// The insides of every `{{…}}` in the text.
    static func templates(in text: String) -> [String] {
        var result: [String] = []
        var rest = text[...]
        while let open = rest.range(of: "{{") {
            guard let close = rest[open.upperBound...].range(of: "}}") else { break }
            result.append(String(rest[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespaces))
            rest = rest[close.upperBound...]
        }
        return result
    }

    /// Replaces every `{{…}}` with the result of `value` for its inside.
    static func replacingTemplates(in text: String, _ value: (String) throws -> String) rethrows -> String {
        var result = ""
        var rest = text[...]
        while let open = rest.range(of: "{{") {
            guard let close = rest[open.upperBound...].range(of: "}}") else { break }
            result += rest[..<open.lowerBound]
            result += try value(String(rest[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespaces))
            rest = rest[close.upperBound...]
        }
        return result + rest
    }

    /// A `{{…}}` inside that is a rule (CSS, JSONPath, default) rather than
    /// a script expression.
    static func isRuleExpression(_ inner: String) -> Bool {
        inner.hasPrefix("@") || inner.hasPrefix("$.") || inner.hasPrefix("$[")
    }

    enum ScriptSegment: Equatable {
        case rule(String)
        case script(String)
    }

    /// A rule split into declarative parts and the scripts that process
    /// their result: `rule<js>code</js>rule2` or `rule@js:code` (to the end).
    static func scriptSegments(_ rule: String) -> [ScriptSegment] {
        var segments: [ScriptSegment] = []
        var rest = rule[...]
        func addRule(_ text: Substring) {
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { segments.append(.rule(String(text))) }
        }
        while !rest.isEmpty {
            let tag = rest.range(of: "<js>", options: .caseInsensitive)
            let prefix = rest.range(of: "@js:", options: .caseInsensitive)
            if let prefix, tag.map({ prefix.lowerBound < $0.lowerBound }) ?? true {
                addRule(rest[..<prefix.lowerBound])
                segments.append(.script(String(rest[prefix.upperBound...])))
                break
            }
            guard let tag else {
                addRule(rest)
                break
            }
            addRule(rest[..<tag.lowerBound])
            let body = rest[tag.upperBound...]
            if let close = body.range(of: "</js>", options: .caseInsensitive) {
                segments.append(.script(String(body[..<close.lowerBound])))
                rest = body[close.upperBound...]
            } else {
                segments.append(.script(String(body)))
                break
            }
        }
        return segments.isEmpty ? [.rule(rule)] : segments
    }

    static func hasScript(_ text: String) -> Bool {
        text.range(of: "@js:", options: .caseInsensitive) != nil || text.range(of: "<js>", options: .caseInsensitive) != nil
    }

    /// A rule with its `##regex##replacement[###]` suffix split off.
    struct Replacement {
        var pattern: String
        var replacement: String
        var firstOnly: Bool
    }

    static func splitReplacement(_ rule: String) -> (rule: String, replacement: Replacement?) {
        guard let range = rule.range(of: "##") else { return (rule, nil) }
        var tail = String(rule[range.upperBound...])
        let firstOnly = tail.hasSuffix("###")
        if firstOnly { tail.removeLast(3) }
        let pieces = tail.components(separatedBy: "##")
        let replacement = Replacement(pattern: pieces[0], replacement: pieces.count > 1 ? pieces[1] : "", firstOnly: firstOnly)
        return (String(rule[..<range.lowerBound]), replacement)
    }
}

/// Regular expressions from source files are untrusted (spec §10A.2):
/// backreferences and nested quantifiers are refused, pattern and input
/// sizes are capped, and matching stops after `timeLimit`, which catches
/// the catastrophic patterns no syntax check can rule out.
enum RegexGuard {
    static let maxPatternLength = 500
    static let maxInputLength = 2_000_000
    static let timeLimit: TimeInterval = 0.5

    private static let backreference = try! NSRegularExpression(pattern: #"\\[1-9]|\\k<"#)
    /// A quantified group with a quantifier inside, e.g. `(a+)+`, `(a?){25}`.
    private static let nestedQuantifier = try! NSRegularExpression(pattern: #"\((?:[^()\\]|\\.)*[+*?}](?:[^()\\]|\\.)*\)\s*[+*{]"#)
    /// `(?:`, `(?=`, `(?<name>` and similar openers, whose `?` isn't a quantifier.
    private static let groupOpener = try! NSRegularExpression(pattern: #"\(\?(?:<?[=!]|[:>]|<[A-Za-z]\w*>|[imsx-]+:?)"#)
    private static let cache = RegexCache()

    static func regex(_ pattern: String) throws -> NSRegularExpression {
        guard pattern.count <= maxPatternLength else { throw WebSourceError.unsafeRegex(pattern) }
        let whole = NSRange(pattern.startIndex..., in: pattern)
        let plain = groupOpener.stringByReplacingMatches(in: pattern, range: whole, withTemplate: "(")
        if backreference.firstMatch(in: pattern, range: whole) != nil
            || nestedQuantifier.firstMatch(in: plain, range: NSRange(plain.startIndex..., in: plain)) != nil {
            throw WebSourceError.unsafeRegex(pattern)
        }
        if let cached = cache.get(pattern) { return cached }
        do {
            let regex = try NSRegularExpression(pattern: pattern)
            cache.set(pattern, regex)
            return regex
        } catch {
            throw WebSourceError.unsafeRegex(pattern)
        }
    }

    static func apply(_ replacement: RuleSyntax.Replacement, to text: String) throws -> String {
        guard !replacement.pattern.isEmpty, text.utf16.count <= maxInputLength else { return text }
        let regex = try regex(replacement.pattern)
        // Java-style `$1` and the escaped `\$` both work with NSRegularExpression templates.
        let template = replacement.replacement
        let matches = try matches(of: regex, in: text, firstOnly: replacement.firstOnly)
        if replacement.firstOnly {
            guard let match = matches.first else { return "" }
            return regex.replacementString(for: match, in: text, offset: 0, template: template)
        }
        let source = text as NSString
        var result = ""
        var location = 0
        for match in matches {
            result += source.substring(with: NSRange(location: location, length: match.range.location - location))
            result += regex.replacementString(for: match, in: text, offset: 0, template: template)
            location = NSMaxRange(match.range)
        }
        return result + source.substring(from: location)
    }

    /// The matches, giving up (and refusing the pattern) once matching
    /// has run for `timeLimit`; `.reportProgress` lets a single long match
    /// attempt be stopped too.
    static func matches(of regex: NSRegularExpression, in text: String, firstOnly: Bool = false) throws -> [NSTextCheckingResult] {
        let deadline = Date().addingTimeInterval(timeLimit)
        var found: [NSTextCheckingResult] = []
        var expired = false
        regex.enumerateMatches(in: text, options: [.reportProgress], range: NSRange(text.startIndex..., in: text)) { match, _, stop in
            if let match {
                found.append(match)
                if firstOnly { stop.pointee = true }
            }
            if Date() > deadline {
                expired = true
                stop.pointee = true
            }
        }
        if expired { throw WebSourceError.unsafeRegex(regex.pattern) }
        return found
    }
}

private final class RegexCache: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: NSRegularExpression] = [:]

    func get(_ key: String) -> NSRegularExpression? { lock.withLock { storage[key] } }
    func set(_ key: String, _ value: NSRegularExpression) { lock.withLock { if storage.count < 500 { storage[key] = value } } }
}
