import CryptoKit
import Foundation
import JavaScriptCore

/// A page fetched for a script (`java.ajax`, `java.connect`).
struct ScriptResponse: Sendable {
    var body: String
    var url: String
    var code: Int
}

/// Globals scripts see besides `result`, `baseUrl` and `src`.
struct ScriptEnvironment: Sendable {
    var key: String?
    var page: Int?
    var book: [String: String]?
    var chapter: [String: String]?
    var title: String?

    var globals: [String: Any] {
        var globals: [String: Any] = [:]
        if let key { globals["key"] = key }
        if let page { globals["page"] = page }
        if let book { globals["book"] = book }
        if let chapter { globals["chapter"] = chapter }
        if let title { globals["title"] = title }
        return globals
    }
}

/// `java.put` / `java.get` and `@put` / `@get` values, per source, kept in
/// memory for the app's lifetime.
final class SourceVariables: @unchecked Sendable {
    static let shared = SourceVariables()

    private let lock = NSLock()
    private var storage: [String: String] = [:]

    func get(_ key: String, source: String) -> String? { lock.withLock { storage[source + "\u{1}" + key] } }
    func set(_ key: String, _ value: String, source: String) { lock.withLock { storage[source + "\u{1}" + key] = value } }
}

/// Runs a source's JavaScript (`@js:`, `<js>…</js>`, `{{…}}`) in
/// JavaScriptCore with a small `java` object modelled on Legado's.
///
/// Only helpers that don't touch protected content are offered: requests
/// to the source's own domains (`ajax`, `connect`), variables, Base64/hex,
/// MD5, URL encoding, time formatting and rule evaluation. Decryption,
/// browsers, cookies, logins, device IDs, files and Java classes aren't;
/// `SourceCompatibility` keeps sources that need them disabled.
///
/// A host is used on one thread at a time; network helpers block that
/// thread, so hosts run on `Offload`, never on the cooperative pool.
final class ScriptHost {
    let source: LegadoSource
    let variables: SourceVariables
    var environment: ScriptEnvironment
    private(set) var content = ""
    private(set) var contentURL: URL
    private let fetchPage: (String) -> ScriptResponse?
    private var context: JSContext?

    init(source: LegadoSource, environment: ScriptEnvironment = ScriptEnvironment(), variables: SourceVariables = .shared,
         fetch: @escaping (String) -> ScriptResponse?) {
        self.source = source
        self.environment = environment
        self.variables = variables
        contentURL = source.baseURL
        fetchPage = fetch
    }

    /// The page `java.getString` and `src` refer to.
    func setContent(_ text: String, baseURL: URL) {
        content = text
        contentURL = baseURL
    }

    /// Runs `code` with `result` bound to `input`; returns the value of the
    /// last expression as a Swift value (String, NSNumber, array, dictionary).
    func evaluate(_ code: String, result input: Any?, baseURL: URL? = nil) throws -> Any? {
        let context = try preparedContext()
        context.setObject(Self.bridge(input), forKeyedSubscript: "result" as NSString)
        context.setObject((baseURL ?? contentURL).absoluteString, forKeyedSubscript: "baseUrl" as NSString)
        context.setObject(content, forKeyedSubscript: "src" as NSString)
        for (name, value) in environment.globals { context.setObject(value, forKeyedSubscript: name as NSString) }
        context.exception = nil
        let value = context.evaluateScript(code)
        if let exception = context.exception {
            context.exception = nil
            throw WebSourceError.script(exception.toString() ?? "未知错误")
        }
        return value.flatMap(Self.swiftValue)
    }

    func variable(_ key: String) -> String? { variables.get(key, source: source.bookSourceUrl) }
    func setVariable(_ key: String, _ value: String) { variables.set(key, value, source: source.bookSourceUrl) }

    // MARK: Context

    private func preparedContext() throws -> JSContext {
        if let context { return context }
        guard let context = JSContext() else { throw WebSourceError.script("无法启动脚本引擎") }
        let java = JSValue(newObjectIn: context)!
        func define(_ name: String, _ block: Any) {
            java.setObject(block, forKeyedSubscript: name as NSString)
        }

        let fetch: @convention(block) (String) -> Any? = { [weak self] url in
            guard let response = self?.fetchPage(url) else { return nil }
            return ["body": response.body, "url": response.url, "code": response.code]
        }
        define("__fetch", fetch)

        let put: @convention(block) (String, JSValue) -> JSValue = { [weak self] key, value in
            self?.setVariable(key, value.isUndefined || value.isNull ? "" : value.toString())
            return value
        }
        let get: @convention(block) (String) -> String = { [weak self] key in self?.variable(key) ?? "" }
        define("put", put)
        define("get", get)

        let base64Encode: @convention(block) (String) -> String = { Data($0.utf8).base64EncodedString() }
        let base64Decode: @convention(block) (String, JSValue) -> String = { text, charset in
            guard let data = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines),
                                  options: .ignoreUnknownCharacters) else { return "" }
            return Self.decode(data, charset: charset)
        }
        define("base64Encode", base64Encode)
        define("base64Decode", base64Decode)

        let md5: @convention(block) (String) -> String = { Self.md5Hex($0) }
        let md5Short: @convention(block) (String) -> String = { String(Self.md5Hex($0).dropFirst(8).prefix(16)) }
        define("md5Encode", md5)
        define("md5Encode16", md5Short)

        let encodeURI: @convention(block) (String, JSValue) -> String = { text, charset in
            let encoding = charset.isString ? TextEncoding(label: charset.toString()) ?? .utf8 : .utf8
            return SourceRequest.percentEncode(text, charset: encoding)
        }
        define("encodeURI", encodeURI)

        let hexDecode: @convention(block) (String) -> String = { hex in
            var bytes: [UInt8] = []
            var index = hex.startIndex
            while let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex), index < hex.endIndex {
                guard let byte = UInt8(hex[index..<next], radix: 16) else { break }
                bytes.append(byte)
                index = next
            }
            return String(decoding: bytes, as: UTF8.self)
        }
        let hexEncode: @convention(block) (String) -> String = { $0.utf8.map { String(format: "%02x", $0) }.joined() }
        define("hexDecodeToString", hexDecode)
        define("hexEncodeToString", hexEncode)

        let timeFormat: @convention(block) (Double) -> String = { Self.format(milliseconds: $0, pattern: "yyyy/MM/dd HH:mm", offset: nil) }
        let timeFormatUTC: @convention(block) (Double, String, Double) -> String = { ms, pattern, offset in
            Self.format(milliseconds: ms, pattern: pattern, offset: offset)
        }
        define("timeFormat", timeFormat)
        define("timeFormatUTC", timeFormatUTC)

        let htmlFormat: @convention(block) (String) -> String = { HTMLText.paragraphs(of: $0).joined(separator: "\n") }
        define("htmlFormat", htmlFormat)
        // No simplified/traditional conversion (spec): text stays as written.
        let identity: @convention(block) (String) -> String = { $0 }
        define("t2s", identity)
        define("s2t", identity)
        let uuid: @convention(block) () -> String = { UUID().uuidString.lowercased() }
        define("randomUUID", uuid)
        let log: @convention(block) (JSValue) -> JSValue = { $0 }
        define("log", log)
        let toast: @convention(block) (JSValue) -> Void = { _ in }
        define("toast", toast)
        define("longToast", toast)

        let getString: @convention(block) (String, JSValue) -> String = { [weak self] rule, _ in
            (try? self?.ruleEvaluator().string(rule)) ?? ""
        }
        let getStringList: @convention(block) (String) -> [String] = { [weak self] rule in
            (try? self?.ruleEvaluator().strings(rule)) ?? []
        }
        let getElements: @convention(block) (String) -> [Any] = { [weak self] rule in
            guard let self, let nodes = try? self.ruleEvaluator().nodes(rule) else { return [] }
            return nodes.map(Self.bridge).compactMap { $0 }
        }
        let setContent: @convention(block) (JSValue, JSValue) -> Void = { [weak self] text, base in
            guard let self else { return }
            let url = base.isString ? URL(string: base.toString()) ?? self.contentURL : self.contentURL
            self.setContent(text.isString ? text.toString() : (Self.swiftValue(text).flatMap(JSONPath.strings)?.joined() ?? ""), baseURL: url)
        }
        define("getString", getString)
        define("getStringList", getStringList)
        define("getElements", getElements)
        define("setContent", setContent)

        context.setObject(java, forKeyedSubscript: "java" as NSString)
        context.setObject(["bookSourceUrl": source.bookSourceUrl, "bookSourceName": source.bookSourceName],
                          forKeyedSubscript: "source" as NSString)
        context.evaluateScript(Self.prelude)
        if let library = source.jsLib, !library.trimmingCharacters(in: .whitespaces).hasPrefix("{") {
            context.evaluateScript(library)
            if let exception = context.exception {
                throw WebSourceError.script("jsLib: \(exception.toString() ?? "")")
            }
        }
        self.context = context
        return context
    }

    /// Wrappers in JavaScript around the native helpers.
    private static let prelude = """
    (function () {
      function response(u) {
        var r = java.__fetch(String(u)) || { body: '', url: String(u), code: 0 };
        return {
          body: function () { return r.body; }, url: function () { return r.url; },
          code: function () { return r.code; }, statusCode: function () { return r.code; },
          header: function () { return null; }, headers: function () { return {}; },
          toString: function () { return r.body; }
        };
      }
      java.connect = response;
      java.ajax = function (u) { var r = java.__fetch(String(u)); return r ? r.body : null; };
      java.ajaxAll = function (us) { var a = []; for (var i = 0; i < us.length; i++) a.push(response(us[i])); return a; };
      java.getVariable = function (k) { return java.get(k); };
      java.setVariable = function (k, v) { return java.put(k, v); };
      source.getKey = function () { return source.bookSourceUrl; };
      source.put = java.put; source.get = java.get;
      source.getVariable = function () { return java.get('__source_variable'); };
      source.setVariable = function (v) { java.put('__source_variable', v); };
      this.cache = {
        put: function (k, v) { java.put('__cache_' + k, v); return v; },
        get: function (k) { return java.get('__cache_' + k); },
        putMemory: function (k, v) { java.put('__cache_' + k, v); return v; },
        getFromMemory: function (k) { return java.get('__cache_' + k); }
      };
    }).call(this);
    """

    private func ruleEvaluator() throws -> RuleEvaluator {
        try RuleEvaluator(text: content, baseURL: contentURL, scripts: self)
    }

    // MARK: Conversions

    /// A Swift value scripts can use: elements as their HTML.
    static func bridge(_ value: Any?) -> Any? {
        switch value {
        case nil: return nil
        case let node as RuleNode:
            switch node {
            case .element(let element): return (try? element.outerHtml()) ?? ""
            case .json(let json): return json
            case .text(let text): return text
            }
        case let nodes as [RuleNode]: return nodes.map { bridge($0) ?? NSNull() }
        default: return value
        }
    }

    static func swiftValue(_ value: JSValue) -> Any? {
        if value.isUndefined || value.isNull { return nil }
        if value.isString { return value.toString() }
        if value.isNumber || value.isBoolean { return value.toObject() }
        if value.isArray { return value.toArray() }
        if value.isObject, let object = value.toObject() {
            if let dictionary = object as? [String: Any] { return dictionary }
            return value.toString()
        }
        return value.toString()
    }

    private static func decode(_ data: Data, charset: JSValue) -> String {
        if charset.isString, let encoding = TextEncoding(label: charset.toString()),
           let text = String(data: data, encoding: encoding.stringEncoding) {
            return text
        }
        return EncodingDetector.decode(data)?.text ?? ""
    }

    private static func md5Hex(_ text: String) -> String {
        Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func format(milliseconds: Double, pattern: String, offset: Double?) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = pattern
        if let offset { formatter.timeZone = TimeZone(secondsFromGMT: Int(offset / 1000)) }
        return formatter.string(from: Date(timeIntervalSince1970: milliseconds / 1000))
    }
}

/// Runs blocking work (scripts that wait on requests) on a GCD thread so
/// the cooperative pool is never blocked.
enum Offload {
    static let queue = DispatchQueue(label: "NovelNest.scripts", qos: .userInitiated, attributes: .concurrent)

    static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }
}
