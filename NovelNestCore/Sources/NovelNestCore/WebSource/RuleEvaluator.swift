import Foundation
import SwiftSoup

/// What a rule runs against: an HTML element, a JSON value or plain text.
enum RuleNode {
    case element(Element)
    case json(Any)
    case text(String)
}

/// Evaluates Legado rules against one page: default (JSoup) chains such
/// as `class.list@tag.a.0@href`, `@css:` selectors, JSONPath (`$.a[*].b`,
/// also bare paths on JSON pages), `&&` / `||` / `%%`, a leading `-` to
/// reverse a list, `{{…}}` templates, `##regex##replacement[###]`
/// suffixes, and with a `ScriptHost`, `@js:` / `<js>` and `@put` / `@get`.
struct RuleEvaluator {
    let baseURL: URL
    let root: RuleNode
    /// Runs `@js:`, `<js>`, script `{{…}}` and `@put`/`@get`; without it
    /// those are refused.
    let scripts: ScriptHost?

    init(text: String, baseURL: URL, scripts: ScriptHost? = nil) throws {
        self.baseURL = baseURL
        self.scripts = scripts
        root = try Self.parse(text, baseURL: baseURL)
        scripts?.setContent(text, baseURL: baseURL)
    }

    init(root: RuleNode, baseURL: URL, scripts: ScriptHost? = nil) {
        self.root = root
        self.baseURL = baseURL
        self.scripts = scripts
    }

    static func parse(_ text: String, baseURL: URL) throws -> RuleNode {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("["), let json = JSONPath.parse(trimmed) { return .json(json) }
        return .element(try SwiftSoup.parse(text, baseURL.absoluteString))
    }

    // MARK: Lists

    /// The nodes a list rule (`bookList`, `chapterList`, `init`) selects.
    func nodes(_ rule: String?, in given: RuleNode? = nil) throws -> [RuleNode] {
        guard var rule = rule?.trimmingCharacters(in: .whitespacesAndNewlines), !rule.isEmpty else { return [] }
        let node = given ?? root
        var reversed = false
        if rule.hasPrefix("-") {
            reversed = true
            rule.removeFirst()
        } else if rule.hasPrefix("+") {
            rule.removeFirst()
        }
        rule = try applyingVariables(rule, in: node)
        let segments = RuleSyntax.scriptSegments(rule)
        let (input, last) = try runLeading(segments, from: node, isRoot: given == nil)
        let result: [RuleNode] = switch last {
        case .rule(let rule): try declarativeNodes(rule, in: Self.node(from: input, baseURL: baseURL))
        case .script(let code): Self.nodes(fromScript: try script(code, input: input), baseURL: baseURL)
        }
        return reversed ? result.reversed() : result
    }

    private func declarativeNodes(_ rule: String, in node: RuleNode) throws -> [RuleNode] {
        let (parts, combinator) = RuleSyntax.splitCombinators(rule)
        var lists: [[RuleNode]] = []
        for part in parts {
            let result = try singleNodes(part.trimmingCharacters(in: .whitespacesAndNewlines), in: node)
            if combinator == .or, !result.isEmpty {
                lists = [result]
                break
            }
            lists.append(result)
        }
        return combine(lists, combinator)
    }

    private func singleNodes(_ rule: String, in node: RuleNode) throws -> [RuleNode] {
        guard !rule.isEmpty else { return [] }
        switch try mode(of: rule, node) {
        case .css(let selector):
            guard case .element(let element) = node else { return [] }
            return try element.select(selector).array().map(RuleNode.element)
        case .json(let path):
            let values = try JSONPath.evaluate(path, on: jsonValue(node))
            if values.count == 1, let array = values[0] as? [Any] { return array.map(RuleNode.json) }
            return values.map(RuleNode.json)
        case .jsoup(let steps):
            guard case .element(let element) = node else { return [] }
            return try JSoupSteps.select(steps, from: [element]).map(RuleNode.element)
        }
    }

    // MARK: Strings

    /// The rule's results joined by newlines, or nil when empty.
    func string(_ rule: String?, in node: RuleNode? = nil) throws -> String? {
        let text = try values(rule, in: node, joined: true).first ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Each result separately, e.g. several next-page URLs.
    func strings(_ rule: String?, in node: RuleNode? = nil) throws -> [String] {
        try values(rule, in: node, joined: false).compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    private func values(_ rule: String?, in given: RuleNode?, joined: Bool) throws -> [String] {
        guard var rule = rule?.trimmingCharacters(in: .whitespacesAndNewlines), !rule.isEmpty else { return [] }
        let node = given ?? root
        // `@get:{name}` on its own is the stored value itself.
        if rule.hasPrefix("@get:{"), rule.hasSuffix("}"), rule.filter({ $0 == "{" }).count == 1 {
            guard let scripts else { throw WebSourceError.unsupported(["需要变量"]) }
            return [scripts.variable(String(rule.dropFirst(6).dropLast())) ?? ""]
        }
        rule = try applyingVariables(rule, in: node)
        let segments = RuleSyntax.scriptSegments(rule)
        let (input, last) = try runLeading(segments, from: node, isRoot: given == nil)
        switch last {
        case .rule(let rule):
            return try declarativeStrings(rule, in: Self.node(from: input, baseURL: baseURL), joined: joined)
        case .script(let code):
            let output = Self.strings(fromScript: try script(code, input: input))
            return joined ? [output.joined(separator: "\n")] : output
        }
    }

    /// `rule##regex##replacement`: the replacement applies to the joined
    /// text, or to each result when they're kept apart.
    private func declarativeStrings(_ rule: String, in node: RuleNode, joined: Bool) throws -> [String] {
        let (body, replacement) = RuleSyntax.splitReplacement(rule)
        let raw = try rawStrings(body, in: node)
        let values = joined ? [raw.joined(separator: "\n")] : raw
        guard let replacement else { return values }
        return try values.map { try RegexGuard.apply(replacement, to: $0) }
    }

    private func rawStrings(_ body: String, in node: RuleNode) throws -> [String] {
        let body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return [] }
        if body.contains("{{") || (isJSON(node) && body.contains("{$.")) {
            return [try fillTemplates(body, in: node)]
        }
        let (parts, combinator) = RuleSyntax.splitCombinators(body)
        var lists: [[String]] = []
        for part in parts {
            let result = try singleStrings(part.trimmingCharacters(in: .whitespacesAndNewlines), in: node)
            if combinator == .or, !result.isEmpty {
                lists = [result]
                break
            }
            lists.append(result)
        }
        return combine(lists, combinator)
    }

    private func singleStrings(_ rule: String, in node: RuleNode) throws -> [String] {
        guard !rule.isEmpty else { return [] }
        if case .text(let text) = node { return [text] }
        switch try mode(of: rule, node) {
        case .css(let text):
            guard case .element(let element) = node else { return [] }
            var selector = text
            var extractor = "text"
            if let at = text.lastIndex(of: "@") {
                selector = String(text[..<at])
                extractor = String(text[text.index(after: at)...])
            }
            let elements = selector.trimmingCharacters(in: .whitespaces).isEmpty ? [element] : try element.select(selector).array()
            return try elements.flatMap { try Self.extract(extractor, from: $0) }
        case .json(let path):
            return try JSONPath.evaluate(path, on: jsonValue(node)).flatMap(JSONPath.strings)
        case .jsoup(let steps):
            guard case .element(let element) = node, let extractor = steps.last else { return [] }
            let elements = try JSoupSteps.select(Array(steps.dropLast()), from: [element])
            return try elements.flatMap { try Self.extract(extractor, from: $0) }
        }
    }

    /// Text such as `https://x/book/{{$.id}}` or `{$.id}` with each
    /// template replaced by its rule's (or script expression's) result.
    private func fillTemplates(_ body: String, in node: RuleNode) throws -> String {
        var text = try RuleSyntax.replacingTemplates(in: body) { inner in
            if RuleSyntax.isRuleExpression(inner) { return try string(inner, in: node) ?? "" }
            return Self.strings(fromScript: try script(inner, input: node)).joined()
        }
        if isJSON(node) {
            let pattern = try RegexGuard.regex(#"\{(\$[.\[][^{}]*)\}"#)
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
                guard let whole = Range(match.range, in: text), let path = Range(match.range(at: 1), in: text) else { continue }
                text.replaceSubrange(whole, with: try string(String(text[path]), in: node) ?? "")
            }
        }
        return text
    }

    static func extract(_ name: String, from element: Element) throws -> [String] {
        let value: String
        switch name.trimmingCharacters(in: .whitespaces) {
        case "text": value = try element.text()
        case "textNodes":
            value = element.textNodes().map { $0.getWholeText().trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }.joined(separator: "\n")
        case "ownText": value = element.ownText()
        case "html":
            try element.select("script, style").remove()
            value = try element.html()
        case "all": value = try element.outerHtml()
        case "": value = try element.text()
        case let attribute: value = try element.attr(attribute)
        }
        return value.isEmpty ? [] : [value]
    }

    // MARK: Scripts and variables

    /// Runs every segment but the last; returns the value the last one
    /// starts from (the node itself when there was nothing before it).
    /// A script on the whole page gets the page's text as `result`, as in
    /// Legado; on a list item it gets the item.
    private func runLeading(_ segments: [RuleSyntax.ScriptSegment], from node: RuleNode,
                            isRoot: Bool) throws -> (Any, RuleSyntax.ScriptSegment) {
        var value: Any = node
        if isRoot, case .script? = segments.first, let page = scripts?.content, !page.isEmpty { value = page }
        for segment in segments.dropLast() {
            switch segment {
            case .rule(let rule):
                let results = try declarativeStrings(rule, in: Self.node(from: value, baseURL: baseURL), joined: false)
                value = results.count == 1 ? results[0] : results
            case .script(let code):
                value = try script(code, input: value) ?? ""
            }
        }
        return (value, segments.last ?? .rule(""))
    }

    private func script(_ code: String, input: Any?) throws -> Any? {
        guard let scripts else { throw WebSourceError.unsupported(["需要 JavaScript"]) }
        return try scripts.evaluate(code, result: ScriptHost.bridge(input), baseURL: baseURL)
    }

    /// `@put:{"name":"rule"}` stores results; `@get:{name}` reads them back.
    private func applyingVariables(_ rule: String, in node: RuleNode) throws -> String {
        guard rule.contains("@put:") || rule.contains("@get:") else { return rule }
        guard let scripts else { throw WebSourceError.unsupported(["需要变量"]) }
        var rule = rule
        while let put = rule.range(of: #"@put:\{[^{}]*\}"#, options: .regularExpression) {
            let json = String(rule[put].dropFirst(5))
            for (name, value) in SourceRequest.jsonObject(json) ?? [:] {
                if let valueRule = value as? String { scripts.setVariable(name, try string(valueRule, in: node) ?? "") }
            }
            rule.removeSubrange(put)
        }
        while let get = rule.range(of: #"@get:\{[^{}]*\}"#, options: .regularExpression) {
            let name = String(rule[get].dropFirst(6).dropLast())
            rule.replaceSubrange(get, with: scripts.variable(name) ?? "")
        }
        return rule
    }

    /// A script's or rule's result as something rules can run on.
    static func node(from value: Any, baseURL: URL) throws -> RuleNode {
        switch value {
        case let node as RuleNode: return node
        case let text as String: return try parse(text, baseURL: baseURL)
        case let strings as [String]: return try parse(strings.joined(separator: "\n"), baseURL: baseURL)
        case is [Any], is [String: Any]: return .json(value)
        default: return .text(JSONPath.strings(value).joined())
        }
    }

    /// List items from a script: arrays item by item; HTML strings become
    /// elements, JSON strings and objects JSON nodes.
    static func nodes(fromScript value: Any?, baseURL: URL) -> [RuleNode] {
        func item(_ value: Any) -> RuleNode? {
            if let text = value as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("{") || trimmed.hasPrefix("["), let json = JSONPath.parse(trimmed) { return .json(json) }
                guard let body = (try? SwiftSoup.parseBodyFragment(text, baseURL.absoluteString))?.body() else { return .text(text) }
                let children = body.children()
                return .element(children.size() == 1 ? children.get(0) : body)
            }
            if value is NSNull { return nil }
            return .json(value)
        }
        switch value {
        case nil: return []
        case let array as [Any]: return array.compactMap(item)
        case let text as String:
            if let json = JSONPath.parse(text.trimmingCharacters(in: .whitespacesAndNewlines)) as? [Any] { return json.compactMap(item) }
            return item(text).map { [$0] } ?? []
        case let value?: return item(value).map { [$0] } ?? []
        }
    }

    static func strings(fromScript value: Any?) -> [String] {
        guard let value else { return [] }
        return JSONPath.strings(value)
    }

    // MARK: Helpers

    private enum Mode {
        case css(String)
        case json(String)
        case jsoup([String])
    }

    private func mode(of rule: String, _ node: RuleNode) throws -> Mode {
        let lower = rule.lowercased()
        if lower.hasPrefix("@css:") { return .css(String(rule.dropFirst(5))) }
        if lower.hasPrefix("@json:") { return .json(String(rule.dropFirst(6))) }
        if lower.hasPrefix("@xpath:") || rule.hasPrefix("/") { throw WebSourceError.unsupported(["使用 XPath"]) }
        if rule.hasPrefix("$.") || rule.hasPrefix("$[") { return .json(rule) }
        if isJSON(node) { return .json(rule) }
        let jsoup = rule.hasPrefix("@@") ? String(rule.dropFirst(2)) : rule
        return .jsoup(jsoup.components(separatedBy: "@"))
    }

    private func isJSON(_ node: RuleNode) -> Bool {
        if case .json = node { true } else { false }
    }

    private func jsonValue(_ node: RuleNode) throws -> Any {
        switch node {
        case .json(let value): return value
        case .text(let text): return JSONPath.parse(text) ?? text
        case .element(let element):
            let text = try element.text()
            return JSONPath.parse(text) ?? text
        }
    }

    private func combine<T>(_ lists: [[T]], _ combinator: RuleSyntax.Combinator?) -> [T] {
        guard combinator == .interleave else { return lists.flatMap { $0 } }
        var result: [T] = []
        for index in 0..<(lists.map(\.count).max() ?? 0) {
            for list in lists where index < list.count { result.append(list[index]) }
        }
        return result
    }

    /// `<meta property="og:novel:…" content="…">` (spec §10A.1).
    func meta(_ property: String) -> String? {
        guard case .element(let element) = root,
              let value = try? element.select("meta[property=\(property)], meta[name=\(property)]").first()?.attr("content")
        else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Steps of a default (JSoup) rule: `class.name`, `id.name`, `tag.name`,
/// `text.words`, `children`, or a CSS selector, each optionally indexed
/// with `.0`, `.-1`, `!0`, `.0:2` or `[0,2]`, `[1:3]`, `[!0]`.
enum JSoupSteps {
    static func select(_ steps: [String], from elements: [Element]) throws -> [Element] {
        var current = elements
        for step in steps {
            let step = step.trimmingCharacters(in: .whitespaces)
            guard !step.isEmpty else { continue }
            current = try current.flatMap { try apply(step, to: $0) }
        }
        return current
    }

    static func apply(_ step: String, to element: Element) throws -> [Element] {
        let (base, index) = splitIndex(step)
        let parts = base.split(separator: ".", maxSplits: 1).map(String.init)
        let name = parts.count > 1 ? parts[1] : ""
        let found: [Element] = switch parts.first ?? "" {
        case "class": try element.getElementsByClass(name).array()
        case "id": try element.getElementById(name).map { [$0] } ?? []
        case "tag": try element.getElementsByTag(name).array()
        case "text": try element.getElementsContainingOwnText(name).array()
        case "children": element.children().array()
        default: try element.select(base).array()
        }
        return index?.apply(found) ?? found
    }

    private static let knownTypes = ["class.", "id.", "tag.", "text.", "children"]
    private static let dotIndex = try! NSRegularExpression(pattern: #"^(.+?)([.!])(-?\d+(?::-?\d+)*)$"#)

    static func splitIndex(_ step: String) -> (String, IndexSpec?) {
        if step.hasSuffix("]"), let open = step.lastIndex(of: "["),
           let spec = IndexSpec(bracket: String(step[step.index(after: open)..<step.index(before: step.endIndex)])) {
            return (String(step[..<open]), spec)
        }
        guard knownTypes.contains(where: step.hasPrefix),
              let match = dotIndex.firstMatch(in: step, range: NSRange(step.startIndex..., in: step)),
              let base = Range(match.range(at: 1), in: step), let mark = Range(match.range(at: 2), in: step),
              let digits = Range(match.range(at: 3), in: step) else { return (step, nil) }
        let baseText = String(step[base])
        // `tag.p.1` but not `class.1` (a class named "1").
        guard baseText.contains(".") || baseText == "children" else { return (step, nil) }
        let items = step[digits].split(separator: ":").compactMap { Int($0) }.map(IndexSpec.Item.index)
        return (baseText, IndexSpec(exclude: step[mark] == "!", items: items))
    }
}

struct IndexSpec: Equatable {
    enum Item: Equatable {
        case index(Int)
        /// Inclusive range; nil ends mean the list's start or end.
        case range(Int?, Int?, step: Int)
    }

    var exclude: Bool
    var items: [Item]

    init(exclude: Bool, items: [Item]) {
        self.exclude = exclude
        self.items = items
    }

    /// The inside of `[…]`: `0`, `-1`, `0,2`, `1:3`, `::2`, `!0`.
    init?(bracket text: String) {
        var text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text.allSatisfy({ "-0123456789:,! ".contains($0) }) else { return nil }
        exclude = text.hasPrefix("!")
        if exclude { text.removeFirst() }
        var items: [Item] = []
        for piece in text.split(separator: ",") {
            let bounds = piece.split(separator: ":", omittingEmptySubsequences: false)
                .map { Int($0.trimmingCharacters(in: .whitespaces)) }
            if bounds.count == 1 {
                guard let value = bounds[0] else { return nil }
                items.append(.index(value))
            } else {
                items.append(.range(bounds[0], bounds[1], step: bounds.count > 2 ? max(bounds[2] ?? 1, 1) : 1))
            }
        }
        guard !items.isEmpty else { return nil }
        self.items = items
    }

    func apply<T>(_ list: [T]) -> [T] {
        let count = list.count
        func resolve(_ index: Int) -> Int { index < 0 ? count + index : index }
        var indices: [Int] = []
        for item in items {
            switch item {
            case .index(let index): indices.append(resolve(index))
            case .range(let start, let end, let step):
                guard count > 0 else { continue }
                let from = resolve(start ?? 0), to = resolve(end ?? count - 1)
                indices += Array(stride(from: from, through: to, by: from <= to ? step : -step))
            }
        }
        let valid = indices.filter { list.indices.contains($0) }
        if exclude {
            let excluded = Set(valid)
            return list.enumerated().filter { !excluded.contains($0.offset) }.map(\.element)
        }
        return valid.map { list[$0] }
    }
}

/// The JSONPath subset sources use: `$.a.b`, `$..a`, `$['a']`, `[n]`,
/// `[-1]`, `[*]`, `[a,b]`, `[1:3]`. Filters are refused.
enum JSONPath {
    static func parse(_ text: String) -> Any? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    static func evaluate(_ path: String, on root: Any) throws -> [Any] {
        var chars = Array(path.trimmingCharacters(in: .whitespaces))
        if chars.first == "$" || chars.first == "@" { chars.removeFirst() }
        else if let first = chars.first, first != ".", first != "[" { chars.insert(".", at: 0) }

        var current: [Any] = [root]
        var i = 0
        func readName() -> String {
            var name = ""
            while i < chars.count, chars[i] != ".", chars[i] != "[" {
                name.append(chars[i])
                i += 1
            }
            return name.trimmingCharacters(in: .whitespaces)
        }
        while i < chars.count {
            if chars[i] == ".", i + 1 < chars.count, chars[i + 1] == "." {
                i += 2
                let all = current.flatMap(descendants)
                if i < chars.count, chars[i] == "[" { current = all; continue }
                let name = readName()
                // Arrays are visited item by item already.
                current = all.filter { !($0 is [Any]) }.flatMap { child(name, of: $0) }
            } else if chars[i] == "." {
                i += 1
                let name = readName()
                current = current.flatMap { child(name, of: $0) }
            } else if chars[i] == "[" {
                guard let close = chars[i...].firstIndex(of: "]") else { throw WebSourceError.missingRule(path) }
                let inside = String(chars[(i + 1)..<close]).trimmingCharacters(in: .whitespaces)
                i = close + 1
                current = try current.flatMap { try subscriptValues(inside, of: $0) }
            } else {
                throw WebSourceError.missingRule(path)
            }
        }
        return current
    }

    private static func child(_ name: String, of value: Any) -> [Any] {
        if name == "*" { return children(of: value) }
        if let dict = value as? [String: Any] {
            guard let child = dict[name], !(child is NSNull) else { return [] }
            return [child]
        }
        if let array = value as? [Any] { return array.flatMap { child(name, of: $0) } }
        return []
    }

    private static func children(of value: Any) -> [Any] {
        if let dict = value as? [String: Any] { return Array(dict.values) }
        if let array = value as? [Any] { return array }
        return []
    }

    private static func descendants(of value: Any) -> [Any] {
        [value] + children(of: value).flatMap(descendants)
    }

    private static func subscriptValues(_ inside: String, of value: Any) throws -> [Any] {
        if inside.hasPrefix("?") { throw WebSourceError.unsupported(["使用 JSONPath 过滤"]) }
        if inside == "*" { return children(of: value) }
        if inside.hasPrefix("'") || inside.hasPrefix("\"") {
            return inside.split(separator: ",").flatMap { name in
                child(name.trimmingCharacters(in: CharacterSet(charactersIn: "'\" ")), of: value)
            }
        }
        guard let array = value as? [Any], let spec = IndexSpec(bracket: inside) else { return [] }
        // JSONPath slices exclude the end; IndexSpec ranges include it.
        let adjusted = IndexSpec(exclude: spec.exclude, items: spec.items.map { item in
            if case .range(let start, let end, let step) = item, let end { return .range(start, end - 1, step: step) }
            return item
        })
        return adjusted.apply(array)
    }

    /// A JSON value as text: strings as is, numbers without a trailing
    /// `.0`, arrays item by item, objects as JSON.
    static func strings(_ value: Any) -> [String] {
        switch value {
        case let string as String: return [string]
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return [number.boolValue ? "true" : "false"] }
            let double = number.doubleValue
            return [double == double.rounded() && abs(double) < 1e15 ? String(Int64(double)) : number.stringValue]
        case is NSNull: return []
        case let array as [Any]: return array.flatMap(strings)
        default:
            guard JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(withJSONObject: value) else { return [] }
            return [String(decoding: data, as: UTF8.self)]
        }
    }
}
