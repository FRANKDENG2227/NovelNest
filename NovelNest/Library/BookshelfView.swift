import NovelNestCore
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct BookshelfView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "全部"
        case inProgress = "在读"
        case finished = "读完"
        var id: Self { self }
    }

    @Environment(\.modelContext) private var context
    @Query private var books: [Book]
    @State private var filter = Filter.all
    @State private var searchText = ""
    @State private var isImporting = false
    @State private var isWorking = false
    @State private var importMessage: String?
    @State private var bookToDelete: Book?
    @State private var openedBook: Book?

    private var library: LibraryService { LibraryService(context: context) }

    /// `@Query` can't sort NULLS LAST, so ordering is done in memory (§6).
    private var visibleBooks: [Book] {
        let query = Book.normalize(searchText)
        let filtered = books.filter { book in
            switch filter {
            case .all: true
            case .inProgress: book.lastOpenedAt != nil && !book.isFinished
            case .finished: book.isFinished
            }
        }.filter { query.isEmpty || $0.normalizedTitle.contains(query) || ($0.author ?? "").contains(searchText) }
        return BookshelfOrdering.sorted(filtered)
    }

    var body: some View {
        NavigationStack {
            Group {
                if books.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("书架")
            .navigationDestination(item: $openedBook) { ReaderView(book: $0) }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { isImporting = true } label: { Label("导入", systemImage: "plus") }
                        .disabled(isWorking)
                }
            }
            .overlay { if isWorking { ProgressView("正在导入…").padding().background(.regularMaterial, in: .rect(cornerRadius: 12)) } }
            .fileImporter(isPresented: $isImporting, allowedContentTypes: [.plainText], allowsMultipleSelection: true) { result in
                Task { await importFiles(result) }
            }
            .alert("导入", isPresented: Binding(get: { importMessage != nil }, set: { if !$0 { importMessage = nil } })) {
                Button("好") {}
            } message: {
                Text(importMessage ?? "")
            }
            .confirmationDialog("删除这本书？", isPresented: Binding(get: { bookToDelete != nil }, set: { if !$0 { bookToDelete = nil } }),
                                titleVisibility: .visible, presenting: bookToDelete) { book in
                Button("删除《\(book.title)》和阅读进度", role: .destructive) { library.delete(book) }
            } message: { _ in
                Text("本地保存的章节内容也会一起删除。")
            }
        }
    }

    private var list: some View {
        List {
            Picker("筛选", selection: $filter) {
                ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .listRowSeparator(.hidden)

            ForEach(visibleBooks) { book in
                Button {
                    library.recordOpen(book)
                    openedBook = book
                } label: {
                    BookRow(book: book)
                }
                .foregroundStyle(.primary)
                .swipeActions {
                    Button("删除", role: .destructive) { bookToDelete = book }
                }
            }
        }
        .listStyle(.plain)
        .searchable(text: $searchText, prompt: "书名或作者")
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("书架是空的", systemImage: "books.vertical")
        } description: {
            Text("导入 TXT 文件开始阅读。支持 UTF-8、GBK/GB18030 和 Big5 编码。")
        } actions: {
            Button("导入 TXT") { isImporting = true }
                .buttonStyle(.borderedProminent)
        }
    }

    private func importFiles(_ result: Result<[URL], Error>) async {
        guard case .success(let urls) = result else {
            if case .failure(let error) = result { importMessage = error.localizedDescription }
            return
        }
        isWorking = true
        defer { isWorking = false }

        var messages: [String] = []
        for url in urls {
            do {
                let imported = try await library.importTXT(at: url)
                let book = imported.book
                var line = "《\(book.title)》：\(book.chapters.count) 章，编码 \(book.sourceEncoding.uppercased())"
                if imported.looksGarbled { line += "。⚠️ 文字可能是乱码，请检查文件编码。" }
                messages.append(line)
            } catch {
                messages.append("\(url.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        importMessage = messages.joined(separator: "\n")
    }
}

private struct BookRow: View {
    let book: Book

    var body: some View {
        HStack(spacing: 12) {
            Text(String(book.title.prefix(1)))
                .font(.title2.weight(.semibold))
                .frame(width: 44, height: 60)
                .background(Color.accentColor.opacity(0.15), in: .rect(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 4) {
                Text(book.title).font(.headline).lineLimit(1)
                if let author = book.author {
                    Text(author).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var detail: String {
        var parts = ["\(book.chapters.count) 章"]
        if let progress = book.progress {
            parts.append("已读 \(Int(progress.normalizedProgress * 100))%")
        }
        if let opened = book.lastOpenedAt {
            parts.append(opened.formatted(.relative(presentation: .named)))
        } else {
            parts.append("未打开")
        }
        return parts.joined(separator: " · ")
    }
}
