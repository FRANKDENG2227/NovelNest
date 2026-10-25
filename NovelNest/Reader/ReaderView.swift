import NovelNestCore
import SwiftData
import SwiftUI

/// Immersive reader: only the text shows until the page is tapped, which
/// brings up the top bar and the control panel; tapping again hides them.
struct ReaderView: View {
    let book: Book

    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @Environment(SpeechController.self) private var speech
    @AppStorage(AppStorageKey.fontSize) private var fontSize = 19.0
    @AppStorage(AppStorageKey.theme) private var theme = ReaderTheme.light
    @AppStorage(AppStorageKey.dayTheme) private var dayTheme = ReaderTheme.light
    @AppStorage(AppStorageKey.pageTurnMode) private var pageTurnMode = PageTurnMode.vertical

    @State private var store: ChapterStore?
    /// Where the reader is: the first character on the page.
    @State private var location = ReaderLocation.start(of: 0)
    @State private var jump: ReaderJump?
    @State private var showControls = false
    @State private var showContents = false
    @State private var showSpeechSettings = false
    @State private var showReaderSettings = false
    @State private var pendingSave: Task<Void, Never>?

    private var library: LibraryService { LibraryService(context: context) }
    private var metrics: ReaderMetrics { ReaderMetrics(fontSize: fontSize) }
    private var isSpeakingBook: Bool { speech.bookID == book.id }

    var body: some View {
        ZStack {
            theme.background.ignoresSafeArea()
            if let store, store.count > 0 {
                pages(store)
            } else if store != nil {
                ContentUnavailableView("这本书没有章节", systemImage: "book.closed")
            }
        }
        .overlay(alignment: .top) {
            if showControls { topBar.transition(.move(edge: .top).combined(with: .opacity)) }
        }
        .overlay(alignment: .bottom) {
            if showControls, let store { controlPanel(store).transition(.move(edge: .bottom).combined(with: .opacity)) }
        }
        .overlay(alignment: .leading) {
            ZStack(alignment: .leading) {
                if showContents {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                        .onTapGesture { setContents(visible: false) }
                        .transition(.opacity)
                }
                if showContents, let store {
                    ContentsDrawer(chapters: store.chapters, current: location.chapter, theme: theme,
                                   select: { go(to: .start(of: $0)) }, close: { setContents(visible: false) })
                        .transition(.move(edge: .leading))
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .statusBarHidden(!showControls)
        .sheet(isPresented: $showSpeechSettings) {
            SpeechSettingsView()
                .environment(speech)
                .presentationDetents([.medium, .large])
                .presentationBackground(theme.background)
        }
        .sheet(isPresented: $showReaderSettings) {
            NavigationStack {
                ReaderSettingsView()
                    .navigationTitle("设置")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.medium])
            .presentationBackground(theme.background)
        }
        .onAppear(perform: restore)
        .onDisappear {
            saveNow()
            // Leaving the book ends listening; sheets over the reader and
            // going to the background don't trigger this.
            if isSpeakingBook { speech.stop() }
        }
        .onChange(of: location) { scheduleSave() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { saveNow() } }
        // Follow the speech word by word, turning the page when it gets there.
        .onChange(of: speech.characterOffset) { followSpeech() }
        .onChange(of: speech.paragraphIndex) { followSpeech() }
        .onChange(of: speech.chapterIndex) { followSpeech() }
    }

    private func pages(_ store: ChapterStore) -> some View {
        GeometryReader { proxy in
            PagedReaderView(store: store, metrics: metrics, theme: theme, mode: pageTurnMode, size: proxy.size,
                            location: $location, jump: jump,
                            highlight: speechLocation.map { ReaderLocation(chapter: $0.chapter, paragraph: $0.paragraph) },
                            onTap: toggleControls, onPageTurn: moveSpeech(to:))
        }
        // The page view's orientation is fixed when it is created.
        .id(pageTurnMode)
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left").font(.title3.weight(.semibold)).frame(width: 44, height: 44)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(book.title).font(.headline).lineLimit(1)
                if let store, store.contains(location.chapter) {
                    Text(store.title(location.chapter)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Menu {
                Button(book.isFinished ? "标记为未读完" : "标记为读完") {
                    book.isFinished.toggle()
                    try? context.save()
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.title3).frame(width: 44, height: 44)
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
        .background(.bar)
    }

    /// Chapter buttons and progress, then four large buttons. Typography,
    /// background and page turning live in the 设置 sheet; speech controls
    /// in the sheet the 朗读 button opens once reading has started.
    private func controlPanel(_ store: ChapterStore) -> some View {
        VStack(spacing: 18) {
            progressRow(store)
            HStack(spacing: 0) {
                panelButton("目录", systemImage: "list.bullet") { setContents(visible: true) }
                panelButton(theme == .dark ? "白天" : "夜间", systemImage: theme == .dark ? "sun.max" : "moon") {
                    ReaderTheme.setNight(theme != .dark, theme: &theme, dayTheme: &dayTheme)
                }
                if isSpeakingBook {
                    panelButton(speech.isPaused ? "已暂停" : "朗读中", systemImage: "waveform") {
                        showSpeechSettings = true
                    }
                } else {
                    panelButton("朗读", systemImage: "headphones") { startSpeech(store) }
                }
                panelButton("设置", systemImage: "textformat.size") { showReaderSettings = true }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 6)
        .background(.bar)
    }

    private func panelButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage).font(.title)
                Text(title).font(.callout)
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.text)
    }

    /// How much of the book has been read; display only.
    private func progressRow(_ store: ChapterStore) -> some View {
        let value = store.progress(at: location)
        return VStack(spacing: 8) {
            HStack {
                Text(store.title(location.chapter)).lineLimit(1)
                Spacer()
                Text(value, format: .percent.precision(.fractionLength(1))).monospacedDigit()
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            HStack(spacing: 16) {
                Button("上一章") { go(to: .start(of: location.chapter - 1)) }
                    .disabled(location.chapter == 0)
                ProgressView(value: value)
                Button("下一章") { go(to: .start(of: location.chapter + 1)) }
                    .disabled(location.chapter + 1 >= store.count)
            }
            .font(.body)
        }
    }

    /// Reads from the top of the page, even partway into a paragraph.
    private func startSpeech(_ store: ChapterStore) {
        let (paragraph, offset) = speechStart(location)
        speech.start(book: book, chapters: store.chapters, chapterIndex: location.chapter,
                     paragraphIndex: paragraph, characterOffset: offset)
    }

    /// When the reader turns the page or jumps while listening, reading
    /// carries on from the top of the new page.
    private func moveSpeech(to target: ReaderLocation) {
        guard isSpeakingBook else { return }
        let (paragraph, offset) = speechStart(target)
        speech.move(toChapter: target.chapter, paragraph: paragraph, characterOffset: offset)
    }

    /// Speech has no title paragraph; the title page starts at paragraph 0.
    private func speechStart(_ location: ReaderLocation) -> (paragraph: Int, offset: Int) {
        location.paragraph == ReaderLocation.title ? (0, 0) : (location.paragraph, location.offset)
    }

    private var speechLocation: ReaderLocation? {
        guard isSpeakingBook, let chapter = speech.chapterIndex, let paragraph = speech.paragraphIndex else { return nil }
        return ReaderLocation(chapter: chapter, paragraph: paragraph, offset: speech.characterOffset)
    }

    /// The contents drawer replaces the control panel while it is open. It
    /// springs out with a slight overshoot and closes without one.
    private func setContents(visible: Bool) {
        withAnimation(visible ? .spring(response: 0.4, dampingFraction: 0.72) : .easeIn(duration: 0.2)) {
            showContents = visible
            if visible { showControls = false }
        }
    }

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() }
    }

    private func restore() {
        guard store == nil else { return }
        let store = ChapterStore(chapters: book.orderedChapters)
        if let resolved = library.restorePosition(for: book) {
            location = ReaderLocation(chapter: resolved.chapterIndex, paragraph: resolved.paragraphIndex,
                                      offset: resolved.characterOffset)
        }
        self.store = store
    }

    /// A jump the user asked for (contents, chapter buttons).
    private func go(to target: ReaderLocation) {
        guard let store, store.contains(target.chapter) else { return }
        moveSpeech(to: target)
        location = target
        jump = ReaderJump(location: target)
        saveNow()
    }

    /// The page view ignores jumps to the page already shown, so this only
    /// turns the page once the spoken word is on the next one.
    private func followSpeech() {
        guard let target = speechLocation else { return }
        jump = ReaderJump(location: target, animated: true)
    }

    /// Debounced save while reading (spec §7: 500–1000 ms).
    private func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task {
            try? await Task.sleep(for: .milliseconds(800))
            if !Task.isCancelled { saveNow() }
        }
    }

    private func saveNow() {
        pendingSave?.cancel()
        guard let store, store.contains(location.chapter) else { return }
        let chapter = store.chapters[location.chapter]
        let onTitle = location.paragraph == ReaderLocation.title
        let position = ReadingPosition(chapterKey: chapter.id.uuidString, chapterIndex: location.chapter,
                                       paragraphIndex: onTitle ? 0 : location.paragraph,
                                       characterOffset: onTitle ? 0 : location.offset)
        library.saveProgress(book, position: position)
    }
}

/// Table of contents as a drawer two thirds of the screen wide, pulled out
/// from the left. Swipe it left (or tap outside it) to close.
private struct ContentsDrawer: View {
    let chapters: [Chapter]
    let current: Int
    let theme: ReaderTheme
    let select: (Int) -> Void
    let close: () -> Void

    @AppStorage(AppStorageKey.hideAuthorNotes) private var hideAuthorNotes = false
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        list
            .containerRelativeFrame(.horizontal) { width, _ in width * 2 / 3 }
            // Reaches past the left edge so the spring's overshoot shows no gap.
            .background(theme.background.padding(.leading, -60).ignoresSafeArea())
            .shadow(color: .black.opacity(0.2), radius: 12)
            .offset(x: min(dragOffset, 0))
            // Simultaneous so the list still scrolls; only sideways drags move it.
            .simultaneousGesture(DragGesture()
                .onChanged { value in
                    if abs(value.translation.width) > abs(value.translation.height) {
                        dragOffset = value.translation.width
                    }
                }
                .onEnded { value in
                    if dragOffset < -80 {
                        close()
                    }
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { dragOffset = 0 }
                })
    }

    private var list: some View {
        ScrollViewReader { proxy in
            List {
                Section {
                    ForEach(chapters.indices, id: \.self) { index in
                        let chapter = chapters[index]
                        if !(hideAuthorNotes && chapter.kind == .authorNote) {
                            if let volume = chapter.volumeTitle, index == 0 || chapters[index - 1].volumeTitle != volume {
                                Text(volume).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Button {
                                select(index)
                                close()
                            } label: {
                                Text(chapter.title)
                                    .lineLimit(1)
                                    .foregroundStyle(index == current ? Color.accentColor : theme.text)
                            }
                            .id(index)
                        }
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("目录（\(chapters.count) 章）").font(.headline).foregroundStyle(theme.text)
                        Toggle("隐藏作者感言/请假条", isOn: $hideAuthorNotes).font(.footnote)
                    }
                    .textCase(nil)
                    .padding(.vertical, 8)
                }
                .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .onAppear { proxy.scrollTo(current, anchor: .center) }
        }
    }
}
