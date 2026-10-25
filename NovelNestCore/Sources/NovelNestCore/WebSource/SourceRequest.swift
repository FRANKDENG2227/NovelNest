import Foundation

/// One HTTP request built from a Legado URL: `url` or `url,{options}` where
/// options may set `method`, `body`, `charset` and `headers`.
public struct SourceRequest: Sendable, Equatable {
    public var url: URL
    public var method: String
    public var body: Data?
    public var headers: [String: String]
    /// Charset the response is declared in, if the rule says so.
    public var charset: TextEncoding?

    /// Headers a source file may set. Cookies and credentials never come
    /// from untrusted rules (spec §10).
    static let allowedHeaders = ["user-agent", "referer", "accept", "accept-language", "content-type"]
    static let keyNames: Set<String> = ["key", "searchKey"]

    /// The search request for `key` on result page `page` (from 1). A
    /// script `searchUrl` or `{{expression}}` needs `scripts`.
    static func search(_ source: LegadoSource, key: String, page: Int = 1, scripts: ScriptHost? = nil) throws -> SourceRequest {
        guard var text = source.searchUrl else { throw WebSourceError.missingRule("searchUrl") }
        if RuleSyntax.hasScript(text) {
            guard let scripts else { throw WebSourceError.unsupported(["需要 JavaScript"]) }
            text = try runScripts(in: text, scripts: scripts)
        }
        // Legacy placeholders without braces.
        text = text.replacingOccurrences(of: "searchKey", with: "{{key}}")
            .replacingOccurrences(of: "searchPage", with: "{{page}}")
            .replacingOccurrences(of: "{{{{key}}}}", with: "{{key}}")
            .replacingOccurrences(of: "{{{{page}}}}", with: "{{page}}")
        text = choosingPageAlternative(in: text, page: page)
        text = try RuleSyntax.replacingTemplates(in: text) { inner in
            if keyNames.contains(inner) { return key }
            if let value = evaluatePage(inner, page: page) { return String(value) }
            guard let scripts else { throw WebSourceError.unsupported(["需要 JavaScript"]) }
            return RuleEvaluator.strings(fromScript: try scripts.evaluate(inner, result: nil)).joined()
        }
        return try parse(text, base: source.baseURL, sourceHeaders: try headers(of: source, scripts: scripts), encodeQuery: true)
    }

    /// A request for a URL found on a page (book, TOC, chapter), which may
    /// itself carry `,{options}`.
    static func page(_ text: String, base: URL, source: LegadoSource, scripts: ScriptHost? = nil) throws -> SourceRequest {
        try parse(text, base: base, sourceHeaders: try headers(of: source, scripts: scripts), encodeQuery: false)
    }

    /// The source's `header`, run first when it's a script.
    static func headers(of source: LegadoSource, scripts: ScriptHost?) throws -> String? {
        guard let header = source.header, RuleSyntax.hasScript(header) else { return source.header }
        guard let scripts else { return nil }
        return try runScripts(in: header, scripts: scripts)
    }

    /// `text<js>code</js>` or `@js:code`: literal parts are the scripts' input.
    static func runScripts(in text: String, scripts: ScriptHost) throws -> String {
        var value: Any = ""
        for segment in RuleSyntax.scriptSegments(text) {
            switch segment {
            case .rule(let literal): value = literal.trimmingCharacters(in: .whitespacesAndNewlines)
            case .script(let code): value = try scripts.evaluate(code, result: value) ?? ""
            }
        }
        if let object = value as? [String: Any] { return jsonString(object) ?? "" }
        return RuleEvaluator.strings(fromScript: value).joined()
    }

    static func parse(_ text: String, base: URL, sourceHeaders: String?, encodeQuery: Bool) throws -> SourceRequest {
        var urlText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var options: [String: Any] = [:]
        if let comma = urlText.range(of: #"\s*,\s*(?=\{)"#, options: .regularExpression),
           let parsed = jsonObject(String(urlText[comma.upperBound...])) {
            options = parsed
            urlText = String(urlText[..<comma.lowerBound])
        }
        let charset = (options["charset"] as? String).flatMap(TextEncoding.init(label:))
        let method = ((options["method"] as? String) ?? "GET").uppercased()

        var body: Data?
        if let bodyText = options["body"] as? String ?? (options["body"].flatMap(jsonString)) {
            let trimmed = bodyText.trimmingCharacters(in: .whitespaces)
            let isJSON = trimmed.hasPrefix("{") || trimmed.hasPrefix("[")
            let encoded = isJSON || !encodeQuery ? bodyText : encodeForm(bodyText, charset: charset)
            body = Data(encoded.utf8)
        }

        if encodeQuery, let question = urlText.firstIndex(of: "?") {
            let query = String(urlText[urlText.index(after: question)...])
            urlText = String(urlText[...question]) + encodeForm(query, charset: charset)
        }
        guard let url = resolve(urlText, base: base) else { throw WebSourceError.invalidURL(urlText) }

        var headers: [String: String] = [:]
        for source in [sourceHeaders.flatMap(jsonObject), options["headers"] as? [String: Any]
                       ?? (options["headers"] as? String).flatMap(jsonObject)] {
            for (name, value) in source ?? [:] where allowedHeaders.contains(name.lowercased()) {
                if let value = value as? String { headers[name] = value }
            }
        }
        if method == "POST", body != nil, !headers.keys.contains(where: { $0.lowercased() == "content-type" }) {
            let isJSON = body.flatMap { String(data: $0, encoding: .utf8) }?.trimmingCharacters(in: .whitespaces).hasPrefix("{") == true
            headers["Content-Type"] = isJSON ? "application/json; charset=utf-8" : "application/x-www-form-urlencoded"
        }
        return SourceRequest(url: url, method: method, body: body, headers: headers, charset: charset)
    }

    /// Resolves a possibly relative URL, percent-encoding characters such
    /// as Chinese in the path.
    public static func resolve(_ text: String, base: URL?) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let allowed = CharacterSet.urlQueryAllowed.union(CharacterSet(charactersIn: "#%"))
        let escaped = trimmed.addingPercentEncoding(withAllowedCharacters: allowed) ?? trimmed
        guard let url = URL(string: escaped, relativeTo: base)?.absoluteURL,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    /// Percent-encodes the values of `a=b&c=d` in the given charset,
    /// leaving values that are already encoded alone.
    static func encodeForm(_ text: String, charset: TextEncoding?) -> String {
        text.split(separator: "&", omittingEmptySubsequences: false).map { pair in
            guard let equals = pair.firstIndex(of: "=") else { return String(pair) }
            let name = pair[..<equals]
            let value = String(pair[pair.index(after: equals)...])
            if value.range(of: #"%[0-9A-Fa-f]{2}"#, options: .regularExpression) != nil { return String(pair) }
            return "\(name)=\(percentEncode(value, charset: charset ?? .utf8))"
        }.joined(separator: "&")
    }

    static func percentEncode(_ text: String, charset: TextEncoding) -> String {
        guard let data = text.data(using: charset.stringEncoding) else { return text }
        let unreserved = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".utf8)
        return data.map { unreserved.contains($0) ? String(UnicodeScalar($0)) : String(format: "%%%02X", $0) }.joined()
    }

    /// `<a,b,c>` picks the entry for the page (the last one after that).
    static func choosingPageAlternative(in text: String, page: Int) -> String {
        guard let range = text.range(of: #"<[^<>]*,[^<>]*>"#, options: .regularExpression) else { return text }
        let choices = text[range].dropFirst().dropLast().split(separator: ",", omittingEmptySubsequences: false)
        let choice = choices[min(max(page - 1, 0), choices.count - 1)]
        return text.replacingCharacters(in: range, with: choice)
    }

    /// `page`, or integer arithmetic on it such as `(page-1)*20`.
    static func isPageExpression(_ text: String) -> Bool { evaluatePage(text, page: 1) != nil }

    static func evaluatePage(_ text: String, page: Int) -> Int? {
        let text = text.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "searchPage", with: "page")
        var parser = ArithmeticParser(Array(text), page: page)
        guard let value = parser.expression(), parser.atEnd else { return nil }
        return value
    }

    static func jsonObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed])) as? [String: Any]
    }

    static func jsonString(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// `+ - * /` and parentheses over integers and the variable `page`.
private struct ArithmeticParser {
    let chars: [Character]
    let page: Int
    var index = 0

    init(_ chars: [Character], page: Int) {
        self.chars = chars
        self.page = page
    }

    var atEnd: Bool { index == chars.count }

    mutating func expression() -> Int? {
        guard var value = term() else { return nil }
        while index < chars.count, chars[index] == "+" || chars[index] == "-" {
            let op = chars[index]
            index += 1
            guard let rhs = term() else { return nil }
            value = op == "+" ? value + rhs : value - rhs
        }
        return value
    }

    mutating func term() -> Int? {
        guard var value = factor() else { return nil }
        while index < chars.count, chars[index] == "*" || chars[index] == "/" {
            let op = chars[index]
            index += 1
            guard let rhs = factor(), op == "*" || rhs != 0 else { return nil }
            value = op == "*" ? value * rhs : value / rhs
        }
        return value
    }

    mutating func factor() -> Int? {
        guard index < chars.count else { return nil }
        if chars[index] == "(" {
            index += 1
            guard let value = expression(), index < chars.count, chars[index] == ")" else { return nil }
            index += 1
            return value
        }
        if chars[index...].starts(with: "page") {
            index += 4
            return page
        }
        var digits = ""
        while index < chars.count, chars[index].isASCII, chars[index].isNumber {
            digits.append(chars[index])
            index += 1
        }
        return Int(digits)
    }
}

extension LegadoSource {
    /// `bookSourceUrl` without the `#comment` some sources append.
    public var baseURL: URL {
        let text = bookSourceUrl.split(separator: "#", maxSplits: 1).first.map(String.init) ?? bookSourceUrl
        return SourceRequest.resolve(text, base: nil) ?? URL(string: "https://invalid.invalid")!
    }
}
