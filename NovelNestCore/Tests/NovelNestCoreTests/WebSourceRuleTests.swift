import Foundation
import Testing
@testable import NovelNestCore

struct WebSourceRuleTests {
    static let base = URL(string: "https://books.example.com/s/")!

    static let html = """
    <html><head><meta property="og:novel:book_name" content="云海行"></head><body>
    <div class="list">
      <ul id="results">
        <li><a class="t" href="/book/1/">云海行</a><span class="a">作者：山月</span></li>
        <li><a class="t" href="/book/2/">云海行外传</a><span class="a">作者：山月</span></li>
        <li><a class="t" href="https://books.example.com/book/3/">云海</a><span class="a">林风</span></li>
      </ul>
    </div>
    <div id="content">第一段<br>第二段<br><br>第三段<script>ad()</script></div>
    </body></html>
    """

    func evaluator() throws -> RuleEvaluator { try RuleEvaluator(text: Self.html, baseURL: Self.base) }

    @Test func defaultChains() throws {
        let e = try evaluator()
        #expect(try e.nodes("id.results@tag.li").count == 3)
        #expect(try e.string("class.t.0@text") == "云海行")
        #expect(try e.string("tag.li.-1@class.a@text") == "林风")
        #expect(try e.nodes("tag.li!0").count == 2)
        #expect(try e.nodes("tag.li[0,2]").count == 2)
        #expect(try e.nodes("tag.li[1:2]").count == 2)
        #expect(try e.nodes("-tag.li").first.flatMap { try e.string("class.t@text", in: $0) } == "云海")
        #expect(try e.string("text.外传@href") == "/book/2/")
    }

    @Test func cssAndCombinators() throws {
        let e = try evaluator()
        #expect(try e.nodes("@css:#results > li").count == 3)
        #expect(try e.string("@css:li:nth-child(2) a@text") == "云海行外传")
        #expect(try e.string("class.missing@text||class.t.1@text") == "云海行外传")
        #expect(try e.strings("class.t.0@text&&class.a.2@text") == ["云海行", "林风"])
        #expect(try e.strings("class.t[0,1]@text%%class.a[0,1]@text") == ["云海行", "作者：山月", "云海行外传", "作者：山月"])
    }

    @Test func regexSuffix() throws {
        let e = try evaluator()
        #expect(try e.string("class.a.0@text##作者：") == "山月")
        #expect(try e.string("class.t.0@href##/book/(\\d+)/##$1") == "1")
        #expect(try e.string("class.t.0@href##\\d+##N###") == "N")
    }

    @Test func extractors() throws {
        let e = try evaluator()
        let html = try #require(try e.string("id.content@html"))
        #expect(!html.contains("script"))
        #expect(HTMLText.paragraphs(of: html) == ["第一段", "第二段", "第三段"])
        #expect(try e.string("id.content@textNodes") == "第一段\n第二段\n第三段")
        #expect(e.meta("og:novel:book_name") == "云海行")
    }

    @Test func jsonPaths() throws {
        let json = #"{"data":{"list":[{"name":"云海行","id":7,"tags":["仙侠"]},{"name":"山月","id":8,"done":true}]}}"#
        let e = try RuleEvaluator(text: json, baseURL: Self.base)
        let items = try e.nodes("$.data.list[*]")
        #expect(items.count == 2)
        #expect(try e.string("$.name", in: items[0]) == "云海行")
        #expect(try e.string("name", in: items[1]) == "山月")
        #expect(try e.string("$.id", in: items[0]) == "7")
        #expect(try e.string("$.done", in: items[1]) == "true")
        #expect(try e.string("/book/{{$.id}}.html", in: items[0]) == "/book/7.html")
        #expect(try e.string("/book/{$.id}/", in: items[1]) == "/book/8/")
        #expect(try e.strings("$..name") == ["云海行", "山月"])
        #expect(try e.string("$.data.list[-1].name") == "山月")
    }

    @Test func refusesScriptsWithoutAHostAndXPath() throws {
        let e = try evaluator()
        #expect(throws: WebSourceError.self) { try e.string("//div[@id='content']/text()") }
        #expect(throws: WebSourceError.self) { try e.string("@js:result.trim()") }
        #expect(throws: WebSourceError.self) { try e.string("{{java.ajax(baseUrl)}}") }
    }

    @Test func regexGuard() {
        #expect(throws: WebSourceError.self) { try RegexGuard.regex("(a+)+$") }
        #expect(throws: WebSourceError.self) { try RegexGuard.regex("(\\w)\\1") }
        #expect(throws: WebSourceError.self) { try RegexGuard.regex(String(repeating: "a", count: 600)) }
        #expect((try? RegexGuard.regex("作者[:：]\\s*")) != nil)
    }

    @Test func indexSpecs() {
        let list = Array(0..<6)
        #expect(IndexSpec(bracket: "-1")!.apply(list) == [5])
        #expect(IndexSpec(bracket: "!0,1")!.apply(list) == [2, 3, 4, 5])
        #expect(IndexSpec(bracket: "1:3")!.apply(list) == [1, 2, 3])
        #expect(IndexSpec(bracket: "::2")!.apply(list) == [0, 2, 4])
        #expect(IndexSpec(bracket: "href") == nil)
    }
}

struct SourceCompatibilityTests {
    static func source(searchUrl: String = "/search?q={{key}}&p={{page}}", name: String = "class.t@text",
                       content: String = "id.content@html") -> LegadoSource {
        LegadoSource(bookSourceUrl: "https://books.example.com", bookSourceName: "示例",
                     searchUrl: searchUrl,
                     ruleSearch: .init(bookList: "id.results@tag.li", name: name, bookUrl: "class.t@href"),
                     ruleToc: .init(chapterList: "tag.dd", chapterName: "tag.a@text", chapterUrl: "tag.a@href"),
                     ruleContent: .init(content: content))
    }

    @Test func supportsDeclarativeRules() {
        #expect(SourceCompatibility.check(Self.source()) == .supported)
        #expect(SourceCompatibility.check(Self.source(searchUrl: "/s?q={{key}}&o={{(page-1)*20}}")) == .supported)
    }

    @Test func scriptsAreSupportedButUnsafeHelpersAreNot() {
        #expect(SourceCompatibility.check(Self.source(searchUrl: "@js:java.ajax('x')")) == .supported)
        #expect(SourceCompatibility.check(Self.source(name: "class.t@text<js>result.trim()</js>")) == .supported)
        #expect(SourceCompatibility.check(Self.source(content: "@get:{c}")) == .supported)
        #expect(SourceCompatibility.check(Self.source(content: "@js:java.createSymmetricCrypto('AES', k).decrypt(result)"))
            .reasons.contains("需要解密"))
        #expect(SourceCompatibility.check(Self.source(searchUrl: "@js:java.startBrowserAwait(url, '验证')"))
            .reasons.contains("需要内置浏览器"))
        #expect(SourceCompatibility.check(Self.source(content: "@js:java.lang.String(result)")).reasons.contains("使用 Java 类"))
        #expect(SourceCompatibility.check(Self.source(name: "//a/text()")).reasons.contains("使用 XPath"))
        #expect(SourceCompatibility.check(Self.source(name: "@js:result.match(/\\/\\/x/)")) == .supported)
    }

    @Test func exportKeepsFieldsNovelNestDoesntUse() throws {
        let json = """
        [{"bookSourceUrl":"https://a.example.com","bookSourceName":"甲","enabled":true,"searchUrl":"/s?k={{key}}",
          "ruleSearch":{"bookList":"tag.li","name":"tag.a@text","bookUrl":"tag.a@href","checkKeyWord":"我的"},
          "ruleContent":{"content":"id.c@html"},"ruleExplore":{"bookList":"tag.li"},"exploreUrl":"热门::/hot",
          "bookSourceComment":"说明","customOrder":3}]
        """
        let entries = try LegadoSource.decodeEntries(Data(json.utf8))
        let exported = try LegadoSourceExport.json(entries.map {
            LegadoSourceExport.Item(original: $0.original, source: $0.source, isEnabled: false)
        })
        let object = try #require((try JSONSerialization.jsonObject(with: exported) as? [[String: Any]])?.first)
        #expect(object["enabled"] as? Bool == false)
        #expect(object["exploreUrl"] as? String == "热门::/hot")
        #expect(object["bookSourceComment"] as? String == "说明")
        #expect((object["ruleSearch"] as? [String: Any])?["checkKeyWord"] as? String == "我的")
        #expect(try LegadoSource.decodeList(exported) == entries.map { entry in
            var source = entry.source
            source.enabled = false
            return source
        })
        #expect(String(decoding: exported, as: UTF8.self).contains("https://a.example.com"))
    }

    @Test func exportWithoutOriginalUsesKeptFields() throws {
        let source = SourceCompatibilityTests.source()
        let exported = try LegadoSourceExport.json([.init(original: nil, source: source, isEnabled: true)])
        var expected = source
        expected.enabled = true
        #expect(try LegadoSource.decodeList(exported) == [expected])
    }

    @Test func decodesYckExport() throws {
        let json = """
        [{"bookSourceUrl":"https://a.example.com#备注","bookSourceName":"甲","bookSourceType":0,"searchUrl":"/s?k={{key}}",
          "ruleSearch":{"bookList":"tag.li","name":"tag.a@text","bookUrl":"tag.a@href"},"ruleContent":{"content":"id.c@html"},
          "customOrder":3,"weight":0},
         {"bookSourceName":"缺地址"},
         {"bookSourceUrl":"https://b.example.com","bookSourceName":"乙","bookSourceType":1}]
        """
        let sources = try LegadoSource.decodeList(Data(json.utf8))
        #expect(sources.map(\.bookSourceName) == ["甲", "乙"])
        #expect(sources[0].baseURL.absoluteString == "https://a.example.com")
        #expect(SourceCompatibility.check(sources[1]).reasons.contains("不是文字书源"))
    }
}

struct SourceRequestTests {
    let source = SourceCompatibilityTests.source(searchUrl: "/modules/search.php?searchkey={{key}}&page={{page}},{\"charset\":\"gbk\"}")

    @Test func encodesKeyInSourceCharset() throws {
        let request = try SourceRequest.search(source, key: "云海", page: 2)
        // 云海 in GBK is D4 C6 BA A3.
        #expect(request.url.absoluteString == "https://books.example.com/modules/search.php?searchkey=%D4%C6%BA%A3&page=2")
        #expect(request.charset == .gb18030)
    }

    @Test func postBodyAndHeaders() throws {
        var source = SourceCompatibilityTests.source(
            searchUrl: "https://books.example.com/search,{'method':'POST','body':'q={{key}}&p={{page}}','headers':{'Cookie':'x','Referer':'https://books.example.com/'}}")
        source.header = #"{"User-Agent":"Custom","Authorization":"secret"}"#
        let request = try SourceRequest.search(source, key: "云海")
        #expect(request.method == "POST")
        #expect(String(data: request.body!, encoding: .utf8) == "q=%E4%BA%91%E6%B5%B7&p=1")
        #expect(request.headers["User-Agent"] == "Custom")
        #expect(request.headers["Referer"] == "https://books.example.com/")
        #expect(request.headers["Cookie"] == nil && request.headers["Authorization"] == nil)
    }

    @Test func pageAlternativesAndArithmetic() throws {
        let source = SourceCompatibilityTests.source(searchUrl: "/s/{{key}}/<,_{{page}}>?o={{(page-1)*20}}")
        #expect(try SourceRequest.search(source, key: "a", page: 1).url.absoluteString == "https://books.example.com/s/a/?o=0")
        #expect(try SourceRequest.search(source, key: "a", page: 3).url.absoluteString == "https://books.example.com/s/a/_3?o=40")
    }

    @Test func hostPolicy() {
        let policy = HostPolicy(source: source)
        #expect(policy.allows(URL(string: "https://m.example.com/book/1")!))
        #expect(!policy.allows(URL(string: "https://evil.test/")!))
        #expect(HostPolicy.registrableDomain("m.site.com.cn") == "site.com.cn")
    }
}
