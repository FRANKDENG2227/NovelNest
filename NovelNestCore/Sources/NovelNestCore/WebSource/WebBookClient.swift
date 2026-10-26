import Foundation

/// Runs one source's rules: search, book page + table of contents, and
/// chapter text. Requests stay on the source's domains, are spaced per host
/// and stop on blocks (spec §9).
public struct WebBookClient: Sendable {
    public static let maxTOCPages = 50
    public static let maxPagesPerChapter = 10

    public let source: LegadoSource
    let fetcher: any HTTPFetching
    let policy: HostPolicy
    /// Shared by this client's scripts; `cancelScripts()` stops their requests.
    let budget = ScriptBudget()

    public init(source: LegadoSource, fetcher: any HTTPFetching = URLSessionFetcher.shared) {
        self.source = source
        self.fetcher = fetcher
        policy = HostPolicy(source: source)
    }

    /// Whether runaway scripts can be stopped by time (see `ScriptWatchdog`).
    public static var scriptTimeLimitAvailable: Bool { ScriptWatchdog.isAvailable }

    /// Makes scripts still running for this client fail their requests at
    /// once, e.g. after a search timed out or the reader left.
    public func cancelScripts() {
        budget.cancel()
    }

    struct Page: Sendable {
        var text: String
        var url: URL
    }

    func fetch(_ request: SourceRequest) async throws -> Page {
        let response = try await fetcher.send(request, allowedHosts: policy)
        return Page(text: try PageDecoder.text(of: response, request: request, policy: policy), url: response.url)
    }

    func fetch(_ url: String) async throws -> Page {
        let request = if source.header.map(RuleSyntax.hasScript) == true {
            try await Offload.run { [self] in try SourceRequest.page(url, base: source.baseURL, source: source, scripts: host()) }
        } else {
            try SourceRequest.page(url, base: source.baseURL, source: source)
        }
        return try await fetch(request)
    }

    /// A script host whose `java.ajax` goes through this client, so script
    /// requests get the same domain policy, spacing and block handling.
    func host(_ environment: ScriptEnvironment = ScriptEnvironment()) -> ScriptHost {
        let client = self
        let reference = WeakHost()
        let created = ScriptHost(source: source, environment: environment, budget: budget) { url in
            client.blockingFetch(url, scripts: reference.host)
        }
        reference.host = created
        return created
    }

    /// Waits on the calling (GCD) thread for a page; nil on any failure.
    /// The request is built here, with the calling script's host for a
    /// script header, so no further `Offload` work is waited on.
    private func blockingFetch(_ url: String, scripts: ScriptHost?) -> ScriptResponse? {
        guard !budget.isCancelled,
              let request = try? SourceRequest.page(url, base: source.baseURL, source: source, scripts: scripts) else { return nil }
        let box = ResponseBox()
        let done = DispatchSemaphore(value: 0)
        let client = self
        Task.detached {
            if let page = try? await client.fetch(request) {
                box.value = ScriptResponse(body: page.text, url: page.url.absoluteString, code: 200)
            }
            done.signal()
        }
        guard done.wait(timeout: .now() + 20) == .success else { return nil }
        return box.value
    }

    private func checkSupported() throws {
        let compatibility = SourceCompatibility.check(source)
        guard compatibility.isSupported else { throw WebSourceError.unsupported(compatibility.reasons) }
    }

    // MARK: Search

    public func search(_ key: String, page: Int = 1) async throws -> [WebSearchResult] {
        try checkSupported()
        guard let rule = source.ruleSearch else { throw WebSourceError.missingRule("ruleSearch") }
        let environment = ScriptEnvironment(key: key, page: page)
        let request = try await Offload.run { [self] in
            try SourceRequest.search(source, key: key, page: page, scripts: host(environment))
        }
        let fetched = try await fetch(request)
        return try await Offload.run { [self] in try searchResults(on: fetched, rule: rule, environment: environment) }
    }

    private func searchResults(on page: Page, rule: LegadoSource.SearchRule, environment: ScriptEnvironment) throws -> [WebSearchResult] {
        let evaluator = try RuleEvaluator(text: page.text, baseURL: page.url, scripts: host(environment))

        var results: [WebSearchResult] = []
        for item in try evaluator.nodes(rule.bookList) {
            guard let title = try evaluator.string(rule.name, in: item).map(Self.clean), !title.isEmpty else { continue }
            let bookURL = try evaluator.string(rule.bookUrl, in: item).flatMap { Self.absolute($0, base: page.url) }
                ?? page.url.absoluteString
            results.append(WebSearchResult(
                sourceURL: source.bookSourceUrl, sourceName: source.bookSourceName, title: title,
                author: try evaluator.string(rule.author, in: item).map(Self.cleanAuthor),
                kind: try evaluator.string(rule.kind, in: item).map(Self.clean),
                latestChapter: try evaluator.string(rule.lastChapter, in: item).map(Self.clean),
                intro: try evaluator.string(rule.intro, in: item),
                coverURL: try evaluator.string(rule.coverUrl, in: item).flatMap { cover($0, base: page.url) },
                bookURL: bookURL,
                wordCount: try evaluator.string(rule.wordCount, in: item)))
        }
        // Some sites answer an exact match with the book page itself.
        if results.isEmpty, source.ruleBookInfo?.name != nil,
           let detail = try? detail(from: page, bookURL: page.url.absoluteString, fallback: nil), !detail.title.isEmpty {
            results.append(WebSearchResult(
                sourceURL: source.bookSourceUrl, sourceName: source.bookSourceName, title: detail.title,
                author: detail.author, kind: detail.category, latestChapter: detail.latestChapter, intro: detail.intro,
                coverURL: detail.coverURL, bookURL: page.url.absoluteString, wordCount: detail.wordCount))
        }
        return results
    }

    // MARK: Book page and contents

    /// The book page and its table of contents. The book page is reused as
    /// the contents page when the source has no separate one.
    public func book(at bookURL: String, from result: WebSearchResult? = nil) async throws -> (WebBookDetail, [WebTOCItem]) {
        try checkSupported()
        let page = try await fetch(bookURL)
        let detail = try await Offload.run { [self] in try detail(from: page, bookURL: bookURL, fallback: result) }
        let reuse = detail.tocURL == bookURL || detail.tocURL == page.url.absoluteString
        return (detail, try await toc(at: detail.tocURL, firstPage: reuse ? page : nil, book: detail))
    }

    static func environment(for book: WebBookDetail?) -> ScriptEnvironment {
        guard let book else { return ScriptEnvironment() }
        return ScriptEnvironment(book: ["name": book.title, "author": book.author ?? "", "bookUrl": book.bookURL,
                                        "tocUrl": book.tocURL, "kind": book.category ?? "", "intro": book.intro ?? ""])
    }

    func detail(from page: Page, bookURL: String, fallback: WebSearchResult?) throws -> WebBookDetail {
        let rule = source.ruleBookInfo ?? LegadoSource.BookInfoRule()
        let environment = ScriptEnvironment(book: fallback.map { ["name": $0.title, "author": $0.author ?? "", "bookUrl": bookURL] })
        let evaluator = try RuleEvaluator(text: page.text, baseURL: page.url, scripts: host(environment))
        let node = try rule.`init`.flatMap { try evaluator.nodes($0).first } ?? evaluator.root

        func field(_ rule: String?, meta: String) throws -> String? {
            try evaluator.string(rule, in: node) ?? evaluator.meta(meta)
        }
        let title = try field(rule.name, meta: "og:novel:book_name").map(Self.clean) ?? fallback?.title ?? ""
        let category = try field(rule.kind, meta: "og:novel:category").map(Self.clean) ?? fallback?.kind
        let tocURL = try evaluator.string(rule.tocUrl, in: node).flatMap { Self.absolute($0, base: page.url) } ?? bookURL
        let cover = try evaluator.string(rule.coverUrl, in: node).flatMap { self.cover($0, base: page.url) }
            ?? evaluator.meta("og:image").flatMap { self.cover($0, base: page.url) }
        return WebBookDetail(
            sourceURL: source.bookSourceUrl, sourceName: source.bookSourceName, bookURL: bookURL, tocURL: tocURL,
            title: title,
            author: try field(rule.author, meta: "og:novel:author").map(Self.cleanAuthor) ?? fallback?.author,
            category: category,
            latestChapter: try field(rule.lastChapter, meta: "og:novel:latest_chapter_name").map(Self.clean) ?? fallback?.latestChapter,
            intro: try field(rule.intro, meta: "og:description").map(Self.cleanIntro) ?? fallback?.intro,
            coverURL: cover ?? fallback?.coverURL.flatMap { policy.allows($0) ? $0 : nil },
            wordCount: try evaluator.string(rule.wordCount, in: node) ?? fallback?.wordCount,
            serialStatus: SerialStatus(text: evaluator.meta("og:novel:status") ?? category))
    }

    /// Follows `nextTocUrl` (at most `maxTOCPages` pages). Entries without
    /// a URL are volume headers. Duplicate URLs keep their last position,
    /// which drops a leading 最新章节 block (spec §10A.1).
    public func toc(at tocURL: String) async throws -> [WebTOCItem] {
        try checkSupported()
        return try await toc(at: tocURL, firstPage: nil, book: nil)
    }

    func toc(at tocURL: String, firstPage: Page?, book: WebBookDetail?) async throws -> [WebTOCItem] {
        guard let rule = source.ruleToc, rule.chapterList != nil else { throw WebSourceError.missingRule("ruleToc") }
        var items: [WebTOCItem] = []
        var queue = [tocURL]
        var visited: Set<String> = []
        var volume: String?
        var pageCount = 0
        while !queue.isEmpty, pageCount < Self.maxTOCPages {
            let url = queue.removeFirst()
            guard visited.insert(url).inserted else { continue }
            let page = if pageCount == 0, let firstPage { firstPage } else { try await fetch(url) }
            pageCount += 1
            visited.insert(page.url.absoluteString)

            let startVolume = volume
            let environment = Self.environment(for: book)
            let (pageItems, endVolume, nextURLs) = try await Offload.run { [self] in
                var volume = startVolume
                var items: [WebTOCItem] = []
                let evaluator = try RuleEvaluator(text: page.text, baseURL: page.url, scripts: host(environment))
                for node in try evaluator.nodes(rule.chapterList) {
                    guard let title = try evaluator.string(rule.chapterName, in: node).map(Self.clean), !title.isEmpty else { continue }
                    guard let chapterURL = try evaluator.string(rule.chapterUrl, in: node).flatMap({ Self.absolute($0, base: page.url) }) else {
                        volume = title
                        continue
                    }
                    items.append(WebTOCItem(title: title, url: chapterURL, volumeTitle: volume))
                }
                let next = try evaluator.strings(rule.nextTocUrl).compactMap { Self.absolute($0, base: page.url) }
                return (items, volume, next)
            }
            items += pageItems
            volume = endVolume
            for next in nextURLs where !visited.contains(next) && !queue.contains(next) {
                queue.append(next)
            }
        }
        return Self.dedupeKeepingLast(items)
    }

    static func dedupeKeepingLast(_ items: [WebTOCItem]) -> [WebTOCItem] {
        var seen: Set<String> = []
        return items.reversed().filter { seen.insert($0.url).inserted }.reversed()
    }

    // MARK: Chapter text

    /// The chapter's paragraphs, merging pages linked by `nextContentUrl`
    /// (at most `maxPagesPerChapter`, never into the next chapter, §10A.6).
    public func chapterText(at url: String, title: String? = nil, nextChapterURL: String? = nil) async throws -> [String] {
        try checkSupported()
        guard let rule = source.ruleContent, rule.content != nil else { throw WebSourceError.missingRule("ruleContent") }
        var texts: [String] = []
        var queue = [url]
        var visited: Set<String> = []
        while !queue.isEmpty, visited.count < Self.maxPagesPerChapter {
            let current = queue.removeFirst()
            guard visited.insert(current).inserted else { continue }
            let page = try await fetch(current)
            let environment = ScriptEnvironment(chapter: ["title": title ?? "", "url": url], title: title)
            let (content, nextURLs) = try await Offload.run { [self] in
                let evaluator = try RuleEvaluator(text: page.text, baseURL: page.url, scripts: host(environment))
                return (try evaluator.string(rule.content),
                        try evaluator.strings(rule.nextContentUrl).compactMap { Self.absolute($0, base: page.url) })
            }
            if let content { texts.append(HTMLText.text(of: content)) }
            for next in nextURLs where !visited.contains(next) && !queue.contains(next) && next != nextChapterURL && next != url {
                queue.append(next)
            }
        }
        let joined = texts.joined(separator: "\n")
        // Off the cooperative pool: even time-limited, regexes block a thread.
        let paragraphs = try await Offload.run {
            var text = joined
            if let replaceRegex = rule.replaceRegex, case (_, let replacement?) = RuleSyntax.splitReplacement(replaceRegex) {
                text = try RegexGuard.apply(replacement, to: text)
            }
            return HTMLText.removingRepeatedTitle(PlainTextCleaner.paragraphs(of: text), title: title)
        }
        guard !paragraphs.isEmpty else { throw WebSourceError.emptyContent }
        return paragraphs
    }

    // MARK: Helpers

    /// A cover image URL, only on the source's own site: the app loads
    /// covers directly, so other hosts (trackers, local devices) are dropped.
    func cover(_ text: String, base: URL) -> URL? {
        SourceRequest.resolve(text, base: base).flatMap { policy.allows($0) ? $0 : nil }
    }

    /// An absolute URL, keeping any `,{options}` suffix.
    static func absolute(_ text: String, base: URL) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var urlPart = trimmed
        var options = ""
        if let comma = trimmed.range(of: #"\s*,\s*(?=\{)"#, options: .regularExpression) {
            urlPart = String(trimmed[..<comma.lowerBound])
            options = "," + trimmed[comma.upperBound...]
        }
        guard !urlPart.lowercased().hasPrefix("javascript:"), let url = SourceRequest.resolve(urlPart, base: base) else { return nil }
        return url.absoluteString + options
    }

    static func clean(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func cleanAuthor(_ text: String) -> String {
        var author = clean(text)
        for prefix in ["作者：", "作者:", "作者", "作 者：", "作　者："] where author.hasPrefix(prefix) {
            author = String(author.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        return author
    }

    static func cleanIntro(_ text: String) -> String {
        PlainTextCleaner.paragraphs(of: HTMLText.text(of: text)).joined(separator: "\n")
    }
}

/// One source's answer to a search.
public struct SourceSearchEvent: Sendable {
    public enum Failure: Sendable, Equatable {
        /// Rate limits and cancellation say nothing about the source.
        case temporary
        /// The site refused, timed out or errored.
        case failure
        /// A script hit a time, request or nesting limit; the source
        /// should be turned off.
        case runaway
    }

    public enum Outcome: Sendable {
        case results([WebSearchResult])
        case failed(message: String, kind: Failure)
    }

    public var sourceURL: String
    public var sourceName: String
    public var outcome: Outcome

    public init(sourceURL: String, sourceName: String, outcome: Outcome) {
        self.sourceURL = sourceURL
        self.sourceName = sourceName
        self.outcome = outcome
    }
}

/// Searches several sources at once, each with a time limit, in the order
/// given (so a default source starts first). Results stream in per source.
public enum WebSearch {
    public static func searchAll(_ sources: [LegadoSource], key: String,
                                 fetcher: any HTTPFetching = URLSessionFetcher.shared,
                                 concurrency: Int = 12, timeout: Duration = .seconds(10)) -> AsyncStream<SourceSearchEvent> {
        AsyncStream { continuation in
            let task = Task {
                await withTaskGroup(of: SourceSearchEvent.self) { group in
                    var pending = sources.makeIterator()
                    func addNext() {
                        guard let source = pending.next() else { return }
                        group.addTask { await search(source, key: key, fetcher: fetcher, timeout: timeout) }
                    }
                    for _ in 0..<concurrency { addNext() }
                    for await event in group {
                        continuation.yield(event)
                        addNext()
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Returns when the search finishes or `timeout` passes, whichever is
    /// first. A task group would wait for a stuck script; this doesn't, and
    /// cancels the client's scripts so they stop making requests.
    static func search(_ source: LegadoSource, key: String, fetcher: any HTTPFetching, timeout: Duration) async -> SourceSearchEvent {
        let client = WebBookClient(source: source, fetcher: fetcher)
        let result = await firstOf(timeout: timeout) { try await client.search(key) }
        func event(_ outcome: SourceSearchEvent.Outcome) -> SourceSearchEvent {
            SourceSearchEvent(sourceURL: source.bookSourceUrl, sourceName: source.bookSourceName, outcome: outcome)
        }
        switch result {
        case .success(let results):
            return event(.results(results))
        case .failure(let error):
            client.cancelScripts()
            return event(.failed(message: error.localizedDescription, kind: failureKind(error)))
        }
    }

    static func failureKind(_ error: Error) -> SourceSearchEvent.Failure {
        switch error as? WebSourceError {
        case .rateLimited?: .temporary
        case .runawayScript?: .runaway
        default: error is CancellationError ? .temporary : .failure
        }
    }

    /// The operation's result, or `timedOut` if it takes longer than
    /// `timeout`, or `CancellationError` if the caller is cancelled. The
    /// operation is cancelled but not waited for.
    static func firstOf<T: Sendable>(timeout: Duration,
                                     _ operation: @escaping @Sendable () async throws -> T) async -> Result<T, Error> {
        let gate = ResultGate<T>()
        let work = Task {
            do { gate.resolve(.success(try await operation())) } catch { gate.resolve(.failure(error)) }
        }
        let timer = Task {
            try? await Task.sleep(for: timeout)
            gate.resolve(.failure(WebSourceError.timedOut))
        }
        let result = await withTaskCancellationHandler {
            await gate.value()
        } onCancel: {
            gate.resolve(.failure(CancellationError()))
        }
        work.cancel()
        timer.cancel()
        return result
    }
}

private final class ResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: ScriptResponse?

    var value: ScriptResponse? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// Holds the first result handed to it and gives it to one waiter.
private final class ResultGate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, Error>?
    private var waiter: CheckedContinuation<Result<T, Error>, Never>?

    func resolve(_ value: Result<T, Error>) {
        let waiter: CheckedContinuation<Result<T, Error>, Never>? = lock.withLock {
            guard result == nil else { return nil }
            result = value
            defer { self.waiter = nil }
            return self.waiter
        }
        waiter?.resume(returning: value)
    }

    func value() async -> Result<T, Error> {
        await withCheckedContinuation { continuation in
            let ready: Result<T, Error>? = lock.withLock {
                if let result { return result }
                waiter = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }
}

/// The host a script's requests come from, without a retain cycle.
private final class WeakHost {
    weak var host: ScriptHost?
}
