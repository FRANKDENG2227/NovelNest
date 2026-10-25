import NovelNestCore
import SwiftData
import SwiftUI

/// 找书: searches every enabled book source at once, the default source
/// first, and lists the books found, merging the same title and author
/// from different sources. Tapping a book opens it in the reader straight
/// away; it joins the shelf only if the reader adds it.
struct SearchView: View {
    @Environment(\.modelContext) private var context
    @Query private var sources: [BookSource]
    @AppStorage(AppStorageKey.theme) private var theme = ReaderTheme.light
    @AppStorage(AppStorageKey.defaultSource) private var defaultSource = ""
    @AppStorage(AppStorageKey.searchHistory) private var storedHistory = ""

    @State private var query = ""
    @State private var searchedQuery = ""
    @State private var groups: [WebSearchGroup] = []
    @State private var failures: [(source: String, message: String)] = []
    @State private var finishedCount = 0
    @State private var sourceCount = 0
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    /// The group whose book is being fetched to open.
    @State private var openingID: String?
    @State private var openedBook: Book?
    @State private var previewGroup: WebSearchGroup?
    @State private var openError: String?

    private var library: LibraryService { LibraryService(context: context) }
    private var usableCount: Int { sources.filter { $0.isEnabled && $0.isSupported }.count }

    var body: some View {
        NavigationStack {
            content
                .background(theme.background.ignoresSafeArea())
                .navigationTitle("找书")
                .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "书名或作者")
                .onSubmit(of: .search, search)
                .searchSuggestions {
                    if query.isEmpty {
                        ForEach(history.terms, id: \.self) { term in
                            Label(term, systemImage: "clock.arrow.circlepath").searchCompletion(term)
                        }
                    }
                }
                // Clearing the field goes back to the search history.
                .onChange(of: query) { _, text in
                    if text.isEmpty, !searchedQuery.isEmpty { reset() }
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        NavigationLink { SourceListView() } label: { Label("书源", systemImage: "server.rack") }
                    }
                }
                .navigationDestination(item: $openedBook) { ReaderView(book: $0) }
                .navigationDestination(item: $previewGroup) { BookPreviewView(group: $0) }
                .alert("打不开这本书", isPresented: Binding(get: { openError != nil }, set: { if !$0 { openError = nil } })) {
                    Button("好") {}
                } message: {
                    Text(openError ?? "")
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if sources.isEmpty {
            ContentUnavailableView {
                Label("还没有书源", systemImage: "server.rack")
            } description: {
                Text("在源仓库（yckceo.com）复制书源订阅链接，导入后就可以搜索。")
            } actions: {
                NavigationLink("导入书源") { SourceListView() }.buttonStyle(.borderedProminent)
            }
        } else if usableCount == 0 {
            ContentUnavailableView {
                Label("没有可用的书源", systemImage: "exclamationmark.triangle")
            } description: {
                Text("已导入的书源都已关闭或不支持（需要 JavaScript、XPath 等）。")
            } actions: {
                NavigationLink("管理书源") { SourceListView() }
            }
        } else if searchedQuery.isEmpty {
            if history.terms.isEmpty {
                ContentUnavailableView("搜索书名或作者", systemImage: "magnifyingglass",
                                       description: Text(searchHint))
            } else {
                historyList
            }
        } else if groups.isEmpty && !isSearching {
            ContentUnavailableView.search(text: searchedQuery)
                .safeAreaInset(edge: .bottom) { failureSummary.padding() }
        } else {
            results
        }
    }

    private var results: some View {
        List {
            Section {
                ForEach(rankedGroups) { group in
                    Button { open(group) } label: {
                        SearchResultRow(group: group, preferred: preferredResult(in: group))
                            .overlay(alignment: .trailing) { if openingID == group.id { ProgressView() } }
                    }
                    .foregroundStyle(theme.text)
                    .disabled(openingID != nil)
                    .listRowBackground(Color.clear)
                    .contextMenu {
                        Button("书籍详情 / 选择书源", systemImage: "info.circle") { previewGroup = group }
                    }
                    .swipeActions {
                        Button("详情") { previewGroup = group }.tint(.accentColor)
                    }
                }
            } header: {
                HStack(spacing: 8) {
                    if isSearching { ProgressView().controlSize(.small) }
                    Text(isSearching ? "正在搜索 \(finishedCount)/\(sourceCount) 个书源…" : "找到 \(groups.count) 本书")
                }
                .textCase(nil)
            } footer: {
                failureSummary
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private var failureSummary: some View {
        if !failures.isEmpty {
            DisclosureGroup("\(failures.count) 个书源出错") {
                ForEach(failures.indices, id: \.self) { index in
                    Text("\(failures[index].source)：\(failures[index].message)").font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    private var history: SearchHistory { SearchHistory(stored: storedHistory) }

    /// The last few searches; tap one to search it again.
    private var historyList: some View {
        List {
            Section {
                ForEach(history.terms, id: \.self) { term in
                    Button {
                        query = term
                        search()
                    } label: {
                        Label(term, systemImage: "clock.arrow.circlepath")
                    }
                    .foregroundStyle(theme.text)
                    .swipeActions {
                        Button("删除", role: .destructive) {
                            var history = history
                            history.remove(term)
                            storedHistory = history.stored
                        }
                    }
                }
            } header: {
                HStack {
                    Text("搜索记录")
                    Spacer()
                    Button("清空") { storedHistory = "" }.font(.footnote)
                }
                .textCase(nil)
            } footer: {
                Text(searchHint)
            }
            .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func reset() {
        searchTask?.cancel()
        searchedQuery = ""
        groups = []
        failures = []
        isSearching = false
    }

    private var searchHint: String {
        let name = sources.first { $0.sourceURL == defaultSource && $0.isEnabled && $0.isSupported }?.name
        return "将在 \(usableCount) 个书源中搜索" + (name.map { "，优先「\($0)」" } ?? "") + "。点书名直接阅读，长按查看详情。"
    }

    /// Exact title matches first, then titles containing the query, then
    /// the rest; within each, books the default source has come first,
    /// then the order they arrived.
    private var rankedGroups: [WebSearchGroup] {
        let key = searchedQuery.trimmingCharacters(in: .whitespaces)
        func rank(_ group: WebSearchGroup) -> (Int, Int) {
            let title = group.best.title
            let match = title == key || group.best.author == key ? 0
                : title.contains(key) || (group.best.author ?? "").contains(key) ? 1 : 2
            return (match, group.results.contains { $0.sourceURL == defaultSource } ? 0 : 1)
        }
        return groups.enumerated().sorted {
            let (a, b) = (rank($0.element), rank($1.element))
            return (a.0, a.1, $0.offset) < (b.0, b.1, $1.offset)
        }.map(\.element)
    }

    /// The default source's copy when it has the book.
    private func preferredResult(in group: WebSearchGroup) -> WebSearchResult {
        group.results.first { $0.sourceURL == defaultSource } ?? group.best
    }

    /// Opens the book in the reader: the copy already here, or a new one
    /// that's off the shelf until the reader adds it.
    private func open(_ group: WebSearchGroup) {
        let result = preferredResult(in: group)
        if let book = library.webBook(bookURL: result.bookURL) {
            library.recordOpen(book)
            openedBook = book
            return
        }
        guard let source = library.source(withURL: result.sourceURL) else {
            openError = "书源已删除"
            return
        }
        openingID = group.id
        Task {
            defer { openingID = nil }
            do {
                let (detail, toc) = try await WebBookClient(source: source).book(at: result.bookURL, from: result)
                guard !toc.isEmpty else {
                    openError = "\(result.sourceName) 没有找到目录。长按书名可以换一个书源。"
                    return
                }
                let book = library.addWebBook(detail, toc: toc, onShelf: false)
                library.recordOpen(book)
                openedBook = book
            } catch {
                openError = error.localizedDescription
            }
        }
    }

    private func search() {
        let key = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        searchTask?.cancel()
        var history = history
        history.add(key)
        storedHistory = history.stored
        let sources = library.searchableSources(defaultSource: defaultSource)
        searchedQuery = key
        groups = []
        failures = []
        finishedCount = 0
        sourceCount = sources.count
        isSearching = true
        searchTask = Task {
            for await event in WebSearch.searchAll(sources, key: key) {
                guard !Task.isCancelled else { return }
                library.recordCheck(event)
                switch event.outcome {
                case .results(let results): WebSearchGroup.merge(results, into: &groups)
                case .failed(let message, _): failures.append((event.sourceName, message))
                }
                finishedCount += 1
            }
            if !Task.isCancelled { isSearching = false }
        }
    }
}

private struct SearchResultRow: View {
    let group: WebSearchGroup
    let preferred: WebSearchResult

    var body: some View {
        let book = preferred
        HStack(alignment: .top, spacing: 12) {
            BookCover(url: book.coverURL, title: book.title)
            VStack(alignment: .leading, spacing: 4) {
                Text(book.title).font(.headline).lineLimit(1)
                Text([book.author, book.kind].compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                if let latest = book.latestChapter {
                    Text("最新：\(latest)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(group.results.count > 1 ? "\(book.sourceName) 等 \(group.results.count) 个书源" : book.sourceName)
                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }
}

/// A cover image, or the title's first character while there is none.
struct BookCover: View {
    let url: URL?
    let title: String
    var width: CGFloat = 44

    var body: some View {
        let placeholder = Text(String(title.prefix(1)))
            .font(width > 60 ? .largeTitle.weight(.semibold) : .title2.weight(.semibold))
            .frame(width: width, height: width * 1.36)
            .background(Color.accentColor.opacity(0.15), in: .rect(cornerRadius: 6))
        if let url {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                        .frame(width: width, height: width * 1.36)
                        .clipShape(.rect(cornerRadius: 6))
                } else {
                    placeholder
                }
            }
        } else {
            placeholder
        }
    }
}
