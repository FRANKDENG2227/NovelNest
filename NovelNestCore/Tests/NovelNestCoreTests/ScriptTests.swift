import Foundation
import Testing
@testable import NovelNestCore

struct ScriptTests {
    static let base = URL(string: "https://books.example.com/s/")!
    static let source = WebBookClientTests.source

    func host(fetch: @escaping (String) -> ScriptResponse? = { _ in nil }) -> ScriptHost {
        ScriptHost(source: Self.source, environment: ScriptEnvironment(key: "云海", page: 2), variables: SourceVariables(), fetch: fetch)
    }

    func evaluator(_ text: String = WebSourceRuleTests.html, host: ScriptHost? = nil) throws -> RuleEvaluator {
        try RuleEvaluator(text: text, baseURL: Self.base, scripts: host ?? self.host())
    }

    @Test func scriptAfterRule() throws {
        let e = try evaluator()
        #expect(try e.string("class.a.0@text@js:result.replace('作者：', '')") == "山月")
        #expect(try e.string("class.t.0@text<js>result + '·' + key</js>") == "云海行·云海")
        #expect(try e.string("@js:baseUrl") == "https://books.example.com/s/")
    }

    @Test func scriptBuildsAList() throws {
        let e = try evaluator()
        let nodes = try e.nodes("@js:JSON.stringify([{n:'甲',u:'/1'},{n:'乙',u:'/2'}])")
        #expect(nodes.count == 2)
        #expect(try e.string("$.n", in: nodes[1]) == "乙")
        let html = try e.nodes(#"<js>['<a href="/x">X</a>', '<a href="/y">Y</a>']</js>"#)
        #expect(try html.map { try e.string("@css:a@href", in: $0) } == ["/x", "/y"])
    }

    @Test func scriptTemplatesAndVariables() throws {
        let e = try evaluator()
        #expect(try e.string("/book/{{page * 10}}/") == "/book/20/")
        #expect(try e.string(#"class.t.0@text@put:{"first":"class.t.1@text"}"#) == "云海行")
        #expect(try e.string("@get:{first}") == "云海行外传")
        #expect(try e.string("@js:java.put('n', 3); java.get('n') + '章'") == "3章")
    }

    @Test func helpers() throws {
        let e = try evaluator()
        #expect(try e.string("@js:java.base64Decode(java.base64Encode('云海'))") == "云海")
        #expect(try e.string("@js:java.md5Encode('abc')") == "900150983cd24fb0d6963f7d28e17f72")
        #expect(try e.string("@js:java.encodeURI('云海', 'gbk')") == "%D4%C6%BA%A3")
        #expect(try e.string("@js:java.hexDecodeToString(java.hexEncodeToString('ab'))") == "ab")
        #expect(try e.string("@js:java.getString('class.t.2@text')") == "云海")
        #expect(try e.string("@js:java.t2s('雲海')") == "雲海")
    }

    @Test func ajaxGoesThroughTheHost() throws {
        var asked: [String] = []
        let host = host { url in
            asked.append(url)
            return ScriptResponse(body: #"{"title":"云海行"}"#, url: url, code: 200)
        }
        let e = try evaluator(host: host)
        #expect(try e.string("@js:JSON.parse(java.ajax('https://books.example.com/api/9')).title") == "云海行")
        #expect(try e.string("@js:java.connect('https://books.example.com/api/9').body().length > 0") == "true")
        #expect(asked == ["https://books.example.com/api/9", "https://books.example.com/api/9"])
    }

    @Test func scriptErrorsAreReported() throws {
        let e = try evaluator()
        #expect(throws: WebSourceError.self) { try e.string("@js:undefinedFunction()") }
    }

    @Test func scriptSearchURL() throws {
        var source = Self.source
        source.searchUrl = "@js:'/search?q=' + java.encodeURI(key) + '&p=' + page"
        let request = try SourceRequest.search(source, key: "云海", page: 2, scripts: host())
        #expect(request.url.absoluteString == "https://books.example.com/search?q=%E4%BA%91%E6%B5%B7&p=2")
        source.searchUrl = "/s?q={{key}}&t={{String(page + 1)}}"
        #expect(try SourceRequest.search(source, key: "a", page: 2, scripts: host()).url.absoluteString
            == "https://books.example.com/s?q=a&t=3")
    }

    @Test func segments() {
        #expect(RuleSyntax.scriptSegments("a@text<js>x</js>b@href@js:y") ==
            [.rule("a@text"), .script("x"), .rule("b@href"), .script("y")])
        #expect(RuleSyntax.scriptSegments("tag.a@href") == [.rule("tag.a@href")])
    }

    @Test func clientRunsScriptsWithAjaxOnTheStub() async throws {
        let stub = StubFetcher()
        stub.add("https://books.example.com/api/search?k=%E4%BA%91%E6%B5%B7", #"{"ids":[9]}"#, headers: ["Content-Type": "application/json"])
        stub.add("https://books.example.com/api/book/9", #"{"name":"云海行","author":"山月"}"#, headers: ["Content-Type": "application/json"])
        var source = Self.source
        source.searchUrl = "/api/search?k={{key}}"
        source.ruleSearch = .init(
            bookList: "@js:JSON.parse(result).ids.map(function (id) { return java.ajax('https://books.example.com/api/book/' + id) })",
            name: "$.name", author: "$.author", bookUrl: "https://books.example.com/book/{{$.name}}/")
        let results = try await WebBookClient(source: source, fetcher: stub).search("云海")
        #expect(results.map(\.title) == ["云海行"])
        #expect(results.first?.author == "山月")
    }
}
