import Foundation
import Testing
@testable import NovelNestCore

/// Serves fixed pages by URL and records what was requested.
final class StubFetcher: HTTPFetching, @unchecked Sendable {
    var pages: [String: HTTPResponse] = [:]
    private(set) var requested: [String] = []
    private let lock = NSLock()

    func add(_ url: String, _ body: String, status: Int = 200, encoding: String.Encoding = .utf8,
             headers: [String: String] = ["Content-Type": "text/html"], finalURL: String? = nil) {
        pages[url] = HTTPResponse(url: URL(string: finalURL ?? url)!, status: status, headers: headers,
                                  data: body.data(using: encoding)!)
    }

    func send(_ request: SourceRequest, allowedHosts: HostPolicy) async throws -> HTTPResponse {
        lock.withLock { requested.append(request.url.absoluteString) }
        guard allowedHosts.allows(request.url) else { throw WebSourceError.disallowedHost(request.url.host ?? "") }
        guard let page = pages[request.url.absoluteString] else { return HTTPResponse(url: request.url, status: 404, data: Data()) }
        return page
    }
}

struct WebBookClientTests {
    static let source = LegadoSource(
        bookSourceUrl: "https://books.example.com#示例", bookSourceName: "示例书源",
        searchUrl: "/search?q={{key}}",
        ruleSearch: .init(bookList: "class.result", name: "tag.h3@text", author: "class.author@text",
                          lastChapter: "class.last@text", bookUrl: "tag.a.0@href"),
        ruleBookInfo: .init(intro: "id.intro@html", coverUrl: "tag.img@src", tocUrl: "class.toc-link@href"),
        ruleToc: .init(chapterList: "id.list@dl@children", chapterName: "text", chapterUrl: "tag.a@href",
                       nextTocUrl: "text.下一页@href"),
        ruleContent: .init(content: "id.content@html", nextContentUrl: "text.下一页@href", replaceRegex: "##本站广告[^\\n]*"))

    func stub() -> StubFetcher {
        let stub = StubFetcher()
        stub.add("https://books.example.com/search?q=%E4%BA%91%E6%B5%B7", """
        <div class="result"><a href="/book/9/"><h3>云海行</h3></a><p class="author">作者：山月</p><p class="last">第三章 归途</p></div>
        <div class="result"><a href="/book/10/"><h3> </h3></a></div>
        """)
        stub.add("https://books.example.com/book/9/", """
        <html><head>
        <meta property="og:novel:book_name" content="云海行"><meta property="og:novel:author" content="山月">
        <meta property="og:novel:category" content="仙侠"><meta property="og:novel:status" content="连载中">
        </head><body><img src="/cover/9.jpg"><div id="intro"><p>少年出山。</p><p>行于云海。</p></div>
        <a class="toc-link" href="/book/9/list/">目录</a></body></html>
        """)
        stub.add("https://books.example.com/book/9/list/", """
        <div id="list"><dl>
          <dt>最新章节</dt><dd><a href="/book/9/3.html">第三章 归途</a></dd>
          <dt>正文卷</dt>
          <dd><a href="/book/9/1.html">第一章 出山</a></dd><dd><a href="/book/9/2.html">第二章 云海</a></dd>
        </dl></div><a href="/book/9/list/2/">下一页</a>
        """)
        stub.add("https://books.example.com/book/9/list/2/", """
        <div id="list"><dl><dd><a href="/book/9/3.html">第三章 归途</a></dd></dl></div><a href="/book/9/list/">上一页</a>
        """)
        stub.add("https://books.example.com/book/9/1.html", """
        <div id="content">第一章 出山<br>&nbsp;&nbsp;&nbsp;&nbsp;山中无岁月。<br>本站广告请收藏<br>他推门而出。</div>
        <a href="/book/9/1_2.html">下一页</a>
        """)
        stub.add("https://books.example.com/book/9/1_2.html", """
        <div id="content">　　云在脚下。</div><a href="/book/9/2.html">下一页</a>
        """)
        return stub
    }

    @Test func searchesAndSkipsEmptyTitles() async throws {
        let client = WebBookClient(source: Self.source, fetcher: stub())
        let results = try await client.search("云海")
        #expect(results.count == 1)
        #expect(results[0].title == "云海行")
        #expect(results[0].author == "山月")
        #expect(results[0].latestChapter == "第三章 归途")
        #expect(results[0].bookURL == "https://books.example.com/book/9/")
        #expect(results[0].sourceName == "示例书源")
    }

    @Test func readsBookPageAndPaginatedContents() async throws {
        let client = WebBookClient(source: Self.source, fetcher: stub())
        let (detail, toc) = try await client.book(at: "https://books.example.com/book/9/")
        #expect(detail.title == "云海行")
        #expect(detail.author == "山月")
        #expect(detail.category == "仙侠")
        #expect(detail.serialStatus == .ongoing)
        #expect(detail.intro == "少年出山。\n行于云海。")
        #expect(detail.coverURL?.absoluteString == "https://books.example.com/cover/9.jpg")
        // The leading 最新章节 entry is dropped; volume headers label chapters.
        #expect(toc.map(\.title) == ["第一章 出山", "第二章 云海", "第三章 归途"])
        #expect(toc[0].volumeTitle == "正文卷")
        #expect(toc[0].url == "https://books.example.com/book/9/1.html")
    }

    @Test func mergesChapterPagesWithoutRunningIntoTheNextChapter() async throws {
        let stub = stub()
        let client = WebBookClient(source: Self.source, fetcher: stub)
        let paragraphs = try await client.chapterText(at: "https://books.example.com/book/9/1.html", title: "第一章 出山",
                                                      nextChapterURL: "https://books.example.com/book/9/2.html")
        #expect(paragraphs == ["山中无岁月。", "他推门而出。", "云在脚下。"])
        #expect(!stub.requested.contains("https://books.example.com/book/9/2.html"))
    }

    @Test func stopsOnBlocksAndChallenges() async throws {
        let stub = StubFetcher()
        stub.add("https://books.example.com/book/1/", "", status: 403)
        stub.add("https://books.example.com/book/2/", "<title>Just a moment...</title><div class=cf-browser-verification></div>")
        stub.add("https://books.example.com/book/3/", "", status: 429, headers: ["Retry-After": "30"])
        stub.add("https://books.example.com/book/4/", "<p>x</p>", finalURL: "https://elsewhere.test/")
        let client = WebBookClient(source: Self.source, fetcher: stub)
        await #expect(throws: WebSourceError.blocked(403)) { try await client.book(at: "https://books.example.com/book/1/") }
        await #expect(throws: WebSourceError.captcha) { try await client.book(at: "https://books.example.com/book/2/") }
        await #expect(throws: WebSourceError.rateLimited(retryAfter: 30)) { try await client.book(at: "https://books.example.com/book/3/") }
        await #expect(throws: WebSourceError.disallowedHost("elsewhere.test")) { try await client.book(at: "https://books.example.com/book/4/") }
        await #expect(throws: WebSourceError.disallowedHost("evil.test")) { try await client.book(at: "https://evil.test/book/") }
    }

    @Test func decodesGBKPages() async throws {
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let stub = StubFetcher()
        stub.add("https://books.example.com/book/9/1.html", "<meta charset=gbk><div id=\"content\">山中无岁月。</div>",
                 encoding: gb18030, headers: ["Content-Type": "text/html"])
        let client = WebBookClient(source: Self.source, fetcher: stub)
        #expect(try await client.chapterText(at: "https://books.example.com/book/9/1.html") == ["山中无岁月。"])
    }

    @Test func refusesUnsupportedSources() async throws {
        var source = Self.source
        source.searchUrl = "@js:java.ajax('x')"
        await #expect(throws: WebSourceError.self) { try await WebBookClient(source: source, fetcher: StubFetcher()).search("a") }
    }

    @Test func searchAllReportsEachSource() async throws {
        var broken = Self.source
        broken.bookSourceName = "坏书源"
        broken.bookSourceUrl = "https://broken.example.org"
        var events: [SourceSearchEvent] = []
        for await event in WebSearch.searchAll([Self.source, broken], key: "云海", fetcher: stub()) { events.append(event) }
        var groups: [WebSearchGroup] = []
        var failures: [String] = []
        for event in events {
            switch event.outcome {
            case .results(let results): WebSearchGroup.merge(results, into: &groups)
            case .failed(_, let isTemporary):
                failures.append(event.sourceName)
                #expect(!isTemporary)
            }
        }
        #expect(groups.count == 1)
        #expect(failures == ["坏书源"])
    }
}
