import NovelNestCore
import SwiftData
import SwiftUI

/// A search result's book page: details, table of contents and a sample
/// of the first chapter, with 加入书架. When several sources have the book,
/// the source can be switched.
struct BookPreviewView: View {
    let group: WebSearchGroup

    @Environment(\.modelContext) private var context
    @AppStorage(AppStorageKey.theme) private var theme = ReaderTheme.light

    @State private var selectedID: String
    @State private var detail: WebBookDetail?
    @State private var toc: [WebTOCItem] = []
    @State private var client: WebBookClient?
    @State private var error: String?
    @State private var isLoading = false
    @State private var shelfBook: Book?
    @State private var openedBook: Book?
    @State private var showFullIntro = false
    @State private var showAllChapters = false

    init(group: WebSearchGroup) {
        self.group = group
        _selectedID = State(initialValue: group.best.id)
    }

    private var library: LibraryService { LibraryService(context: context) }
    private var selected: WebSearchResult { group.results.first { $0.id == selectedID } ?? group.best }
    private static let chapterPreviewCount = 30

    var body: some View {
        List {
            header.listRowBackground(Color.clear)
            if group.results.count > 1 {
                Picker("书源", selection: $selectedID) {
                    ForEach(group.results) { Text($0.sourceName).tag($0.id) }
                }
                .listRowBackground(theme.secondaryBackground)
            }
            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                    Button("重试") { Task { await load() } }
                }
                .listRowBackground(theme.secondaryBackground)
            }
            if let intro = detail?.intro ?? selected.intro {
                Section("简介") {
                    Text(intro).lineLimit(showFullIntro ? nil : 5)
                        .onTapGesture { showFullIntro.toggle() }
                }
                .listRowBackground(theme.secondaryBackground)
            }
            if !toc.isEmpty { contents }
        }
        .scrollContentBackground(.hidden)
        .background(theme.background.ignoresSafeArea())
        .navigationTitle(selected.title)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { actions }
        .navigationDestination(item: $openedBook) { ReaderView(book: $0) }
        .task(id: selectedID) { await load() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            BookCover(url: detail?.coverURL ?? selected.coverURL, title: selected.title, width: 90)
            VStack(alignment: .leading, spacing: 6) {
                Text(detail?.title ?? selected.title).font(.title3.weight(.semibold))
                if let author = detail?.author ?? selected.author { Text(author).foregroundStyle(.secondary) }
                Text(facts).font(.footnote).foregroundStyle(.secondary)
                if let latest = detail?.latestChapter ?? selected.latestChapter {
                    Text("最新：\(latest)").font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                }
                Text("来源：\(selected.sourceName)").font(.caption).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
    }

    private var facts: String {
        var parts: [String] = []
        if let category = detail?.category ?? selected.kind { parts.append(category) }
        switch detail?.serialStatus {
        case .ongoing: parts.append("连载中")
        case .completed: parts.append("已完结")
        default: break
        }
        if let words = detail?.wordCount ?? selected.wordCount { parts.append(words) }
        if !toc.isEmpty { parts.append("\(toc.count) 章") }
        return parts.joined(separator: " · ")
    }

    private var contents: some View {
        Section("目录（\(toc.count) 章）") {
            let shown = showAllChapters ? toc : Array(toc.prefix(Self.chapterPreviewCount))
            ForEach(shown.indices, id: \.self) { index in
                if let client {
                    NavigationLink(shown[index].title) { chapterPreview(index, client: client) }
                        .lineLimit(1)
                }
            }
            if !showAllChapters, toc.count > Self.chapterPreviewCount {
                Button("显示全部 \(toc.count) 章") { showAllChapters = true }
            }
        }
        .listRowBackground(theme.secondaryBackground)
    }

    private var actions: some View {
        HStack(spacing: 12) {
            if let client, !toc.isEmpty {
                NavigationLink { chapterPreview(0, client: client) } label: {
                    Text("试读第一章").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            if let shelfBook {
                Button {
                    library.recordOpen(shelfBook)
                    openedBook = shelfBook
                } label: {
                    Text("已在书架 · 开始阅读").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button {
                    if let detail { shelfBook = library.addWebBook(detail, toc: toc) }
                } label: {
                    Text("加入书架").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(detail == nil || toc.isEmpty)
            }
        }
        .controlSize(.large)
        .padding()
        .background(.bar)
        .overlay { if isLoading { ProgressView() } }
    }

    private func chapterPreview(_ index: Int, client: WebBookClient) -> some View {
        ChapterPreviewView(client: client, item: toc[index], nextURL: toc.indices.contains(index + 1) ? toc[index + 1].url : nil)
    }

    private func load() async {
        let result = selected
        shelfBook = library.webBook(bookURL: result.bookURL).flatMap { $0.isOnShelf ? $0 : nil }
        guard let source = library.source(withURL: result.sourceURL) else {
            error = "书源已删除"
            return
        }
        let client = WebBookClient(source: source)
        self.client = client
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let (detail, toc) = try await client.book(at: result.bookURL, from: result)
            guard result.id == selectedID else { return }
            self.detail = detail
            self.toc = toc
            if toc.isEmpty { error = "没有找到目录" }
        } catch is CancellationError {
        } catch {
            guard result.id == selectedID else { return }
            detail = nil
            toc = []
            self.error = error.localizedDescription
        }
    }
}

/// One chapter's text fetched for a look before adding the book.
struct ChapterPreviewView: View {
    let client: WebBookClient
    let item: WebTOCItem
    let nextURL: String?

    @AppStorage(AppStorageKey.fontSize) private var fontSize = 19.0
    @AppStorage(AppStorageKey.theme) private var theme = ReaderTheme.light
    @State private var paragraphs: [String]?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: fontSize * 0.8) {
                Text(item.title).font(.system(size: fontSize * 1.3, weight: .semibold))
                if let paragraphs {
                    ForEach(paragraphs.indices, id: \.self) { index in
                        Text("　　" + paragraphs[index]).font(.system(size: fontSize)).lineSpacing(fontSize * 0.5)
                    }
                } else if let error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .foregroundStyle(theme.text)
            .padding()
        }
        .background(theme.background.ignoresSafeArea())
        .navigationTitle("试读")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                paragraphs = try await client.chapterText(at: item.url, title: item.title, nextChapterURL: nextURL)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
