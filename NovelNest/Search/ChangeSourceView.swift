import NovelNestCore
import SwiftData
import SwiftUI

/// 换源: the same title from the other enabled sources, for when a source's
/// text is garbled or missing. Choosing one moves the book there and keeps
/// the reading position at the matching chapter.
struct ChangeSourceView: View {
    let book: Book
    /// Switches to the result; returns an error message if it failed.
    let select: (WebSearchResult) async -> String?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @AppStorage(AppStorageKey.theme) private var theme = ReaderTheme.light
    @AppStorage(AppStorageKey.defaultSource) private var defaultSource = ""

    @State private var results: [WebSearchResult] = []
    @State private var finishedCount = 0
    @State private var sourceCount = 0
    @State private var isSearching = true
    @State private var switchingID: String?
    @State private var error: String?

    private var library: LibraryService { LibraryService(context: context) }

    /// Same author first, then the default source, then arrival order.
    private var ranked: [WebSearchResult] {
        let author = book.author.map(Book.normalize)
        return results.enumerated().sorted { lhs, rhs in
            func rank(_ result: WebSearchResult) -> (Int, Int) {
                (author != nil && result.author.map(Book.normalize) == author ? 0 : 1, result.sourceURL == defaultSource ? 0 : 1)
            }
            let (a, b) = (rank(lhs.element), rank(rhs.element))
            return (a.0, a.1, lhs.offset) < (b.0, b.1, rhs.offset)
        }.map(\.element)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("当前书源") {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(book.sourceName ?? "未知书源")
                        if let latest = book.latestChapterTitle {
                            Text("最新：\(latest)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .listRowBackground(theme.secondaryBackground)

                Section {
                    ForEach(ranked) { result in
                        Button { choose(result) } label: { row(result) }
                            .foregroundStyle(theme.text)
                            .disabled(switchingID != nil)
                    }
                } header: {
                    HStack(spacing: 8) {
                        if isSearching { ProgressView().controlSize(.small) }
                        Text(isSearching ? "正在搜索 \(finishedCount)/\(sourceCount) 个书源…" : "其他书源 \(results.count) 个")
                    }
                    .textCase(nil)
                } footer: {
                    if !isSearching && results.isEmpty { Text("其他已启用的书源里没有找到《\(book.title)》。") }
                }
                .listRowBackground(theme.secondaryBackground)
            }
            .scrollContentBackground(.hidden)
            .background(theme.background.ignoresSafeArea())
            .navigationTitle("换源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
            .alert("换源失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("好") {}
            } message: {
                Text(error ?? "")
            }
            .task { await search() }
        }
    }

    private func row(_ result: WebSearchResult) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(result.sourceName).lineLimit(1)
                    if result.sourceURL == defaultSource { Text("默认").font(.caption2).foregroundStyle(.secondary) }
                }
                Text([result.author, result.latestChapter.map { "最新：\($0)" }].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if switchingID == result.id { ProgressView() }
        }
    }

    private func search() async {
        let sources = library.searchableSources(defaultSource: defaultSource)
        sourceCount = sources.count
        let title = book.normalizedTitle
        for await event in WebSearch.searchAll(sources, key: book.title) {
            library.recordCheck(event)
            if case .results(let found) = event.outcome {
                results += found.filter {
                    Book.normalize($0.title) == title && $0.bookURL != book.bookURL && !results.map(\.id).contains($0.id)
                }
            }
            finishedCount += 1
        }
        isSearching = false
    }

    private func choose(_ result: WebSearchResult) {
        switchingID = result.id
        Task {
            let failure = await select(result)
            switchingID = nil
            if let failure { error = failure } else { dismiss() }
        }
    }
}
