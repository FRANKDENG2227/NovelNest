import Foundation

/// Whether NovelNest can run a source's rules. Scripts run in
/// JavaScriptCore (`ScriptHost`), but sources that need what the app
/// doesn't offer stay disabled: decrypting protected content, a browser
/// (often to get past bot checks), cookies or logins, device IDs, files,
/// Java classes, XPath (spec §10, §9).
public enum SourceCompatibility: Sendable, Equatable {
    case supported
    case unsupported([String])

    public var isSupported: Bool { self == .supported }

    public var reasons: [String] {
        if case .unsupported(let reasons) = self { reasons } else { [] }
    }

    /// Script features that are refused, by reason.
    static let refused: [(reason: String, markers: [String])] = [
        ("需要解密", ["createSymmetricCrypto", "createAsymmetricCrypto", "createSign", "aesDecode", "aesEncode",
                   "aesBase64Decode", "aesDecodeToString", "desDecode", "desEncode", "tripleDES", "rsaDecode"]),
        ("需要内置浏览器", ["startBrowser", "showBrowser", "showReadingBrowser", "getWebViewUA", "webView"]),
        ("需要登录或 Cookie", ["getCookie", "cookie.get", "cookie.set", "cookie.remove", "removeCookie",
                          "getLoginInfo", "putLoginInfo", "getLoginHeader", "putLoginHeader", "login("]),
        ("需要设备标识", ["androidId", "deviceID", "getDeviceId"]),
        ("需要验证码", ["getVerificationCode"]),
        ("需要文件或下载", ["importScript", "cacheFile", "downloadFile", "readFile", "readTxtFile", "unzip", "getZip",
                       "un7z", "unrar", "unArchive"]),
        ("使用 Java 类", ["Packages.", "java.lang", "java.util", "java.io", "java.net", "javax.", "org.jsoup",
                       "JavaImporter", "importPackage", "importClass"]),
    ]

    public static func check(_ source: LegadoSource) -> SourceCompatibility {
        var reasons: [String] = []
        func add(_ reason: String) { if !reasons.contains(reason) { reasons.append(reason) } }

        if let type = source.bookSourceType, type != 0 { add("不是文字书源") }
        if source.searchUrl == nil || source.ruleSearch?.bookList == nil || source.ruleSearch?.name == nil {
            add("没有搜索规则")
        }
        if source.ruleContent?.content == nil { add("没有正文规则") }
        if let library = source.jsLib, library.trimmingCharacters(in: .whitespaces).hasPrefix("{") { add("需要外部脚本库") }

        let texts = [source.searchUrl, source.header, source.jsLib].compactMap { $0 } + source.ruleStrings
        for text in texts {
            for (reason, markers) in refused where markers.contains(where: text.contains) { add(reason) }
        }
        for rule in source.ruleStrings {
            if usesXPath(rule) { add("使用 XPath") }
            if rule.contains("[?(") { add("使用 JSONPath 过滤") }
        }
        if let list = source.ruleSearch?.bookList, list.trimmingCharacters(in: .whitespaces).hasPrefix(":") {
            add("使用正则列表")
        }
        return reasons.isEmpty ? .supported : .unsupported(reasons)
    }

    /// XPath rules start with `//` or `@XPath:` (also after `-` or a
    /// combinator); script parts aren't rules.
    static func usesXPath(_ rule: String) -> Bool {
        RuleSyntax.scriptSegments(rule).contains { segment in
            guard case .rule(let text) = segment else { return false }
            return RuleSyntax.splitCombinators(text.components(separatedBy: "##")[0]).parts.contains { part in
                let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines).droppingPrefix("-")
                return trimmed.hasPrefix("/") || trimmed.lowercased().hasPrefix("@xpath:")
            }
        }
    }
}

extension LegadoSource {
    /// Every extraction rule, for compatibility checks.
    var ruleStrings: [String] {
        let search = ruleSearch.map { [$0.bookList, $0.name, $0.author, $0.kind, $0.lastChapter, $0.intro, $0.coverUrl, $0.bookUrl, $0.wordCount] } ?? []
        let info = ruleBookInfo.map { [$0.`init`, $0.name, $0.author, $0.kind, $0.lastChapter, $0.intro, $0.coverUrl, $0.tocUrl, $0.wordCount] } ?? []
        let toc = ruleToc.map { [$0.chapterList, $0.chapterName, $0.chapterUrl, $0.nextTocUrl] } ?? []
        let content = ruleContent.map { [$0.content, $0.nextContentUrl, $0.replaceRegex] } ?? []
        return (search + info + toc + content).compactMap { $0 }
    }
}

extension String {
    func droppingPrefix(_ prefix: String) -> String {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : self
    }
}
