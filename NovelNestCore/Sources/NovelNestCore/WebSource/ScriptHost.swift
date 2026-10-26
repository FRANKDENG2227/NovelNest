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

/// Lets a client stop its scripts' network use, e.g. once a search timed
/// out: from then on `java.ajax` fails at once.
public final class ScriptBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public var isCancelled: Bool { lock.withLock { cancelled } }
    public func cancel() { lock.withLock { cancelled = true } }
}

/// JavaScriptCore's execution time limit. It isn't in the public headers,
/// so it is looked up at run time; when missing, scripts are only bounded
/// by the request and nesting limits and by cancellation.
enum ScriptWatchdog {
    private typealias SetLimit = @convention(c) (JSContextGroupRef, Double, OpaquePointer?, UnsafeMutableRawPointer?) -> Void

    private static let setLimit: SetLimit? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "JSContextGroupSetExecutionTimeLimit") else { return nil }
        return unsafeBitCast(symbol, to: SetLimit.self)
    }()

    static var isAvailable: Bool { setLimit != nil }

    /// Stops any single evaluation in `context` after `seconds` of running.
    static func limit(_ context: JSContext, seconds: Double) {
        setLimit?(JSContextGetGroup(context.jsGlobalContextRef), seconds, nil, nil)
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
///
/// Limits, so a broken or hostile source can't hang or crash the app or
/// keep hitting a site: each evaluation runs at most `timeLimit` seconds,
/// a host makes at most `maxRequests` requests, rules and scripts nest at
/// most `maxDepth` deep, and a cancelled budget stops requests at once.
final class ScriptHost {
    static let timeLimit = 5.0
    static let maxRequests = 30
    static let maxDepth = 8

    let source: LegadoSource
    let variables: SourceVariables
    let budget: ScriptBudget
    private var requestCount = 0
    private var depth = 0
    var environment: ScriptEnvironment
    private(set) var content = ""
    private(set) var contentURL: URL
    private let fetchPage: (String) -> ScriptResponse?
    private var context: JSContext?

    init(source: LegadoSource, environment: ScriptEnvironment = ScriptEnvironment(), variables: SourceVariables = .shared,
         budget: ScriptBudget = ScriptBudget(), fetch: @escaping (String) -> ScriptResponse?) {
        self.source = source
        self.environment = environment
        self.variables = variables
        self.budget = budget
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
        if budget.isCancelled { throw CancellationError() }
        guard depth < Self.maxDepth else {
            runawayReason = "嵌套太深"
            throw WebSourceError.runawayScript("嵌套太深")
        }
        depth += 1
        defer { depth -= 1 }
        let context = try preparedContext()
        // Values from an outer evaluation, restored after a nested one.
        let saved = depth > 1 ? ["result", "baseUrl", "src"].map { context.objectForKeyedSubscript($0) } : []
        defer {
            for (name, value) in zip(["result", "baseUrl", "src"], saved) { context.setObject(value, forKeyedSubscript: name as NSString) }
        }
        context.setObject(Self.bridge(input), forKeyedSubscript: "result" as NSString)
        context.setObject((baseURL ?? contentURL).absoluteString, forKeyedSubscript: "baseUrl" as NSString)
        context.setObject(content, forKeyedSubscript: "src" as NSString)
        for (name, value) in environment.globals { context.setObject(value, forKeyedSubscript: name as NSString) }
        context.exception = nil
        let value = context.evaluateScript(code)
        // A limit hit in a nested call that the script swallowed still ends it.
        if depth == 1, let runaway = runawayReason {
            context.exception = nil
            throw WebSourceError.runawayScript(runaway)
        }
        if let exception = context.exception {
            context.exception = nil
            let message = exception.toString() ?? "未知错误"
            if let runaway = runawayReason { throw WebSourceError.runawayScript(runaway) }
            if message.contains("execution terminated") { throw WebSourceError.runawayScript("运行超过 \(Int(Self.timeLimit)) 秒") }
            if budget.isCancelled { throw CancellationError() }
            throw WebSourceError.script(message)
        }
        return value.flatMap(Self.swiftValue)
    }

    /// Set when a limit stopped the script, so a script that catches the
    /// error still ends up reported as runaway.
    private var runawayReason: String?

    /// Counts a request against the limits; nil when it may go ahead,
    /// otherwise the error to throw into the script.
    private func admitRequest() -> String? {
        if budget.isCancelled { return "已取消" }
        guard requestCount < Self.maxRequests else {
            runawayReason = "请求超过 \(Self.maxRequests) 次"
            return runawayReason
        }
        requestCount += 1
        return nil
    }

    func variable(_ key: String) -> String? { variables.get(key, source: source.bookSourceUrl) }
    func setVariable(_ key: String, _ value: String) { variables.set(key, value, source: source.bookSourceUrl) }

    // MARK: Context

    private func preparedContext() throws -> JSContext {
        if let context { return context }
        guard let context = JSContext() else { throw WebSourceError.script("无法启动脚本引擎") }
        ScriptWatchdog.limit(context, seconds: Self.timeLimit)
        let java = JSValue(newObjectIn: context)!
        func define(_ name: String, _ block: Any) {
            java.setObject(block, forKeyedSubscript: name as NSString)
        }

        let fetch: @convention(block) (String) -> Any? = { [weak self] url in
            guard let self else { return nil }
            if let refusal = admitRequest() {
                // Thrown into the script, which stops a request loop.
                if let current = JSContext.current() {
                    current.exception = JSValue(newErrorFromMessage: "NovelNest: \(refusal)", in: current)
                }
                return nil
            }
            guard let response = fetchPage(url) else { return nil }
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

/// Runs blocking work (scripts that wait on requests, regular
/// expressions) on a GCD thread so the cooperative pool is never blocked,
/// at most `width` at a time so stuck work can't use up every thread.
enum Offload {
    static let width = 6
    static let queue = DispatchQueue(label: "NovelNest.scripts", qos: .userInitiated, attributes: .concurrent)
    private static let slots = AsyncSemaphore(width)

    static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        await slots.wait()
        defer { slots.signal() }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }
}

/// A counting semaphore for async code.
final class AsyncSemaphore: @unchecked Sendable {
    private let lock = NSLock()
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(_ count: Int) {
        available = count
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock {
                if available > 0 {
                    available -= 1
                    return true
                }
                waiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }

    func signal() {
        let next = lock.withLock {
            if waiters.isEmpty {
                available += 1
                return nil as CheckedContinuation<Void, Never>?
            }
            return waiters.removeFirst()
        }
        next?.resume()
    }
}
