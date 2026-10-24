import NovelNestCore
import SwiftData
import SwiftUI

struct ReaderView: View {
    let book: Book

    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Environment(SpeechController.self) private var speech
    @AppStorage(AppStorageKey.fontSize) private var fontSize = 19.0
    @AppStorage(AppStorageKey.lineSpacing) private var lineSpacing = 8.0
    @AppStorage(AppStorageKey.horizontalMargin) private var margin = 20.0
    @AppStorage(AppStorageKey.theme) private var theme = ReaderTheme.light

    @State private var chapters: [Chapter] = []
    @State private var chapterIndex = 0
    /// The current chapter's paragraphs, split once per chapter change.
    @State private var paragraphs: [String] = []
    /// Paragraph at the top of the screen; `titleID` while the title shows.
    @State private var topParagraph: Int?
    @State private var restored = false
    @State private var showContents = false
    @State private var showSettings = false
    @State private var pendingSave: Task<Void, Never>?

    private static let titleID = -1
    private var library: LibraryService { LibraryService(context: context) }
    private var chapter: Chapter? { chapters.indices.contains(chapterIndex) ? chapters[chapterIndex] : nil }
    private var isSpeakingHere: Bool { speech.bookID == book.id && speech.chapterIndex == chapterIndex }

    var body: some View {
        ScrollView {
            if let chapter {
                LazyVStack(alignment: .leading, spacing: lineSpacing * 1.6) {
                    Text(chapter.title)
                        .font(.system(size: fontSize * 1.3, weight: .semibold))
                        .padding(.vertical, 12)
                        .id(Self.titleID)
                    ForEach(Array(paragraphs.enumerated()), id: \.offset) { index, paragraph in
                        Text("\u{3000}\u{3000}" + paragraph)
                            .font(.system(size: fontSize))
                            .lineSpacing(lineSpacing)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(isSpeakingHere && speech.paragraphIndex == index
                                        ? Color.accentColor.opacity(0.15) : .clear)
                            .id(index)
                    }
                    chapterFooter
                }
                .scrollTargetLayout()
                .padding(.horizontal, margin)
                .padding(.bottom, 40)
                .foregroundStyle(theme.text)
            }
        }
        .scrollPosition(id: $topParagraph, anchor: .top)
        .background(theme.background.ignoresSafeArea())
        .preferredColorScheme(theme.colorScheme)
        .navigationTitle(book.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .sheet(isPresented: $showContents) {
            ContentsView(chapters: chapters, current: chapterIndex) { go(to: $0) }
        }
        .sheet(isPresented: $showSettings) {
            ReaderSettingsView().presentationDetents([.medium])
        }
        .onAppear(perform: restore)
        .onDisappear { saveNow() }
        .onChange(of: topParagraph) { scheduleSave() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { saveNow() } }
        // Follow the speech into the next chapter and down the page.
        .onChange(of: speech.chapterIndex) { _, index in
            if speech.bookID == book.id, let index, index != chapterIndex { show(chapter: index, paragraph: 0) }
        }
        .onChange(of: speech.paragraphIndex) { _, index in
            if isSpeakingHere, let index { withAnimation { topParagraph = index } }
        }
    }

    private var chapterFooter: some View {
        HStack {
            Button("上一章") { go(to: chapterIndex - 1) }.disabled(chapterIndex == 0)
            Spacer()
            Text("\(chapterIndex + 1) / \(chapters.count)").font(.footnote).foregroundStyle(.secondary)
            Spacer()
            Button("下一章") { go(to: chapterIndex + 1) }.disabled(chapterIndex + 1 >= chapters.count)
        }
        .buttonStyle(.bordered)
        .padding(.top, 24)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .bottomBar) {
            Button { showContents = true } label: { Label("目录", systemImage: "list.bullet") }
            Spacer()
            speechButton
            if speech.bookID == book.id {
                Button { speech.stop() } label: { Label("停止", systemImage: "stop.fill") }
            }
            Spacer()
            Button { showSettings = true } label: { Label("设置", systemImage: "textformat.size") }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button(book.isFinished ? "标记为未读完" : "标记为读完") {
                    book.isFinished.toggle()
                    try? context.save()
                }
            } label: {
                Label("更多", systemImage: "ellipsis.circle")
            }
        }
    }

    @ViewBuilder
    private var speechButton: some View {
        if speech.bookID == book.id && speech.isSpeaking {
            Button { speech.pause() } label: { Label("暂停", systemImage: "pause.fill") }
        } else if speech.bookID == book.id && speech.isPaused {
            Button { speech.resume() } label: { Label("继续", systemImage: "play.fill") }
        } else {
            Button {
                speech.start(book: book, chapters: chapters, chapterIndex: chapterIndex, paragraphIndex: currentParagraph)
            } label: {
                Label("朗读", systemImage: "headphones")
            }
        }
    }

    private var currentParagraph: Int { max(topParagraph ?? 0, 0) }

    private func restore() {
        guard !restored else { return }
        restored = true
        chapters = book.orderedChapters
        let resolved = library.restorePosition(for: book)
        show(chapter: resolved?.chapterIndex ?? 0, paragraph: resolved?.paragraphIndex ?? 0)
    }

    private func go(to index: Int) {
        guard chapters.indices.contains(index) else { return }
        if speech.bookID == book.id { speech.stop() }
        show(chapter: index, paragraph: 0)
        saveNow()
    }

    private func show(chapter index: Int, paragraph: Int) {
        chapterIndex = index
        paragraphs = chapters[index].paragraphs
        topParagraph = paragraph == 0 ? Self.titleID : paragraph
    }

    /// Debounced save while scrolling (spec §7: 500–1000 ms).
    private func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task {
            try? await Task.sleep(for: .milliseconds(800))
            if !Task.isCancelled { saveNow() }
        }
    }

    private func saveNow() {
        pendingSave?.cancel()
        guard let chapter else { return }
        let position = ReadingPosition(chapterKey: chapter.id.uuidString, chapterIndex: chapterIndex,
                                       paragraphIndex: currentParagraph)
        library.saveProgress(book, position: position)
    }
}

private struct ContentsView: View {
    let chapters: [Chapter]
    let current: Int
    let select: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppStorageKey.hideAuthorNotes) private var hideAuthorNotes = false

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    Toggle("隐藏作者感言/请假条", isOn: $hideAuthorNotes)
                    ForEach(chapters.indices, id: \.self) { index in
                        let chapter = chapters[index]
                        if !(hideAuthorNotes && chapter.kind == .authorNote) {
                            if let volume = chapter.volumeTitle, index == 0 || chapters[index - 1].volumeTitle != volume {
                                Text(volume).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                            }
                            Button {
                                select(index)
                                dismiss()
                            } label: {
                                Text(chapter.title)
                                    .foregroundStyle(index == current ? Color.accentColor : .primary)
                                    .fontWeight(index == current ? .semibold : .regular)
                            }
                            .id(index)
                        }
                    }
                }
                .listStyle(.plain)
                .onAppear { proxy.scrollTo(current, anchor: .center) }
            }
            .navigationTitle("目录（\(chapters.count) 章）")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}
