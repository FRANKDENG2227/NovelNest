import AVFoundation
import MediaPlayer
import NovelNestCore
import Observation

/// On-device text-to-speech with AVSpeechSynthesizer (spec §8).
///
/// Speaks one sentence-sized chunk at a time, so a rate change applies from
/// the next sentence, and moves on to the next chapter when a chapter ends.
/// `characterOffset` follows the word being spoken so the reader can
/// highlight the paragraph and turn the page when speech reaches it.
/// Speech keeps going with the screen locked (the `audio` background mode)
/// with a lock-screen banner for play/pause and previous/next chapter. A
/// sleep timer pauses it after a set time. Interruption and route-change handling and saving the
/// listening position come with Phase 2.
@MainActor @Observable
final class SpeechController: NSObject, AVSpeechSynthesizerDelegate {
    private(set) var bookID: UUID?
    private(set) var chapterIndex: Int?
    private(set) var paragraphIndex: Int?
    /// UTF-16 offset into the current paragraph of the word being spoken.
    private(set) var characterOffset = 0
    private(set) var isSpeaking = false
    private(set) var isPaused = false
    /// When the sleep timer pauses speech; nil while the timer is off.
    private(set) var sleepDeadline: Date?
    /// The sleep timer's length when it's turned on.
    private(set) var sleepMinutes = 20

    static let sleepStep = 5
    static let sleepMinutesRange = 5...180

    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private let silence = SilentAudio()
    @ObservationIgnored private var chapters: [Chapter] = []
    @ObservationIgnored private var paragraphs: [String] = []
    /// The current paragraph's chunks with where each starts in it.
    @ObservationIgnored private var chunks: [(text: String, offset: Int)] = []
    @ObservationIgnored private var chunkIndex = 0
    @ObservationIgnored private var voice: AVSpeechSynthesisVoice?
    /// The utterance being spoken. Callbacks from one that was cut off by
    /// `move` or `stop` can still arrive and are ignored.
    @ObservationIgnored private var currentUtterance: ObjectIdentifier?
    /// Where `resume()` starts after a `move` while paused.
    @ObservationIgnored private var resumeFrom: (paragraph: Int, offset: Int)?
    @ObservationIgnored private var bookTitle = ""
    @ObservationIgnored private var sleepTask: Task<Void, Never>?
    /// Fetches a web chapter's text before it's spoken; false if it failed.
    @ObservationIgnored private var ensureChapter: ((Int) async -> Bool)?

    override init() {
        super.init()
        synthesizer.delegate = self
        configureRemoteCommands()
    }

    /// Starts at the chunk containing `characterOffset`, so speech begins
    /// at the top of a page that starts partway into a paragraph.
    func start(book: Book, chapters: [Chapter], chapterIndex: Int, paragraphIndex: Int, characterOffset: Int = 0,
               ensureChapter: ((Int) async -> Bool)? = nil) {
        stop()
        guard chapters.indices.contains(chapterIndex) else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)

        bookID = book.id
        bookTitle = book.title
        self.chapters = chapters
        self.ensureChapter = ensureChapter
        voice = Self.voice(for: book.script)
        withChapter(chapterIndex) {
            self.load(chapter: chapterIndex)
            self.speak(paragraph: min(paragraphIndex, max(self.paragraphs.count - 1, 0)), from: characterOffset)
        }
    }

    func pause() {
        if synthesizer.pauseSpeaking(at: .word) {
            isSpeaking = false
            isPaused = true
            silence.pause()
            updateNowPlaying()
        }
    }

    func resume() {
        if let resumeFrom {
            self.resumeFrom = nil
            speak(paragraph: resumeFrom.paragraph, from: resumeFrom.offset)
        } else if synthesizer.continueSpeaking() {
            isSpeaking = true
            isPaused = false
            silence.play()
            updateNowPlaying()
        }
    }

    /// Continues reading from another place in the same book, e.g. the top
    /// of a page the reader turned to. While paused it stays paused and
    /// `resume()` starts there.
    func move(toChapter chapter: Int, paragraph: Int, characterOffset offset: Int) {
        guard bookID != nil, chapters.indices.contains(chapter) else { return }
        currentUtterance = nil
        synthesizer.stopSpeaking(at: .immediate)
        guard chapters[chapter].isDownloaded || ensureChapter == nil else {
            // Wait for the text; until then the placeholder would be read.
            return withChapter(chapter) { self.move(toChapter: chapter, paragraph: paragraph, characterOffset: offset) }
        }
        load(chapter: chapter)
        let paragraph = min(paragraph, max(paragraphs.count - 1, 0))
        if isPaused {
            resumeFrom = (paragraph, offset)
            paragraphIndex = paragraph
            characterOffset = offset
        } else {
            speak(paragraph: paragraph, from: offset)
        }
    }

    func stop() {
        currentUtterance = nil
        resumeFrom = nil
        chunks = []
        synthesizer.stopSpeaking(at: .immediate)
        bookID = nil
        ensureChapter = nil
        chapterIndex = nil
        paragraphIndex = nil
        characterOffset = 0
        isSpeaking = false
        isPaused = false
        silence.pause()
        setSleepTimer(on: false)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPRemoteCommandCenter.shared().nextTrackCommand.isEnabled = false
        MPRemoteCommandCenter.shared().previousTrackCommand.isEnabled = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Turns the sleep timer on for `sleepMinutes`, or off.
    func setSleepTimer(on: Bool) {
        sleepTask?.cancel()
        sleepTask = nil
        sleepDeadline = on ? .now.addingTimeInterval(Double(sleepMinutes * 60)) : nil
        if on { scheduleSleep() }
    }

    /// Lengthens or shortens the timer by `steps` × 5 minutes: the time
    /// left while it runs, otherwise the length it starts with.
    func changeSleepTimer(by steps: Int) {
        let delta = steps * Self.sleepStep
        if let sleepDeadline {
            let deadline = sleepDeadline.addingTimeInterval(Double(delta * 60))
            guard deadline > .now else { return }
            self.sleepDeadline = deadline
            sleepTask?.cancel()
            scheduleSleep()
        } else {
            sleepMinutes = min(max(sleepMinutes + delta, Self.sleepMinutesRange.lowerBound),
                               Self.sleepMinutesRange.upperBound)
        }
    }

    private func scheduleSleep() {
        guard let sleepDeadline else { return }
        sleepTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(sleepDeadline.timeIntervalSinceNow, 0)))
            guard !Task.isCancelled, let self, self.sleepDeadline == sleepDeadline else { return }
            self.sleepDeadline = nil
            self.sleepTask = nil
            self.pause()
        }
    }

    private func load(chapter index: Int) {
        chapterIndex = index
        paragraphs = chapters[index].paragraphs
        updateNowPlaying()
    }

    /// The book and chapter on the lock screen, with play/pause and
    /// previous/next chapter.
    private func updateNowPlaying() {
        guard let chapterIndex, chapters.indices.contains(chapterIndex) else { return }
        let center = MPRemoteCommandCenter.shared()
        center.previousTrackCommand.isEnabled = chapterIndex > 0
        center.nextTrackCommand.isEnabled = chapterIndex < chapters.count - 1
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: chapters[chapterIndex].title,
            MPMediaItemPropertyArtist: bookTitle,
            MPMediaItemPropertyAlbumTitle: "第 \(chapterIndex + 1) / \(chapters.count) 章",
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyPlaybackRate: isPaused ? 0.0 : 1.0,
        ]
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            guard let self, self.isPaused else { return .commandFailed }
            self.resume()
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self, self.isSpeaking else { return .commandFailed }
            self.pause()
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self, self.bookID != nil else { return .commandFailed }
            if self.isPaused { self.resume() } else { self.pause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.skipChapter(by: 1) == true ? .success : .noSuchContent
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.skipChapter(by: -1) == true ? .success : .noSuchContent
        }
        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false
    }

    /// Reads from the start of the next or previous chapter, as the lock
    /// screen's skip buttons do. The reader follows along.
    @discardableResult
    func skipChapter(by delta: Int) -> Bool {
        guard bookID != nil, let chapterIndex, chapters.indices.contains(chapterIndex + delta) else { return false }
        move(toChapter: chapterIndex + delta, paragraph: 0, characterOffset: 0)
        return true
    }

    private func speak(paragraph index: Int, from offset: Int = 0) {
        guard paragraphs.indices.contains(index) else { return advanceChapter() }
        paragraphIndex = index
        chunks = Self.locatedChunks(of: paragraphs[index])
        guard !chunks.isEmpty else { return speak(paragraph: index + 1) }
        chunkIndex = chunks.lastIndex { $0.offset <= offset } ?? 0
        // Start exactly at `offset`, partway into the sentence if need be:
        // the sentence's start may be on the previous page, and following
        // it would turn back a page.
        let chunk = chunks[chunkIndex]
        let skip = offset - chunk.offset
        if skip > 0, skip < (chunk.text as NSString).length {
            chunks[chunkIndex] = ((chunk.text as NSString).substring(from: skip), offset)
        }
        characterOffset = chunks[chunkIndex].offset
        speakCurrentChunk()
        let wasSpeaking = isSpeaking
        isSpeaking = true
        isPaused = false
        if !wasSpeaking {
            silence.play()
            updateNowPlaying()
        }
    }

    private func speakCurrentChunk() {
        let rate = UserDefaults.standard.object(forKey: AppStorageKey.speechRate) as? Double
            ?? Double(AVSpeechUtteranceDefaultSpeechRate)
        let utterance = AVSpeechUtterance(string: chunks[chunkIndex].text)
        utterance.voice = voice
        utterance.rate = Float(rate)
        currentUtterance = ObjectIdentifier(utterance)
        synthesizer.speak(utterance)
    }

    /// A paragraph's chunks with where each starts in it. Chunks are
    /// trimmed, so their lengths can't simply be added up.
    static func locatedChunks(of paragraph: String) -> [(text: String, offset: Int)] {
        let text = paragraph as NSString
        var cursor = 0
        return SpeechChunker.chunks(of: paragraph).map { chunk in
            let found = text.range(of: chunk, range: NSRange(location: cursor, length: text.length - cursor))
            guard found.location != NSNotFound else { return (chunk, cursor) }
            cursor = NSMaxRange(found)
            return (chunk, found.location)
        }
    }

    private func advanceChapter() {
        guard let chapterIndex, chapters.indices.contains(chapterIndex + 1) else { return stop() }
        withChapter(chapterIndex + 1) {
            self.load(chapter: chapterIndex + 1)
            self.speak(paragraph: 0)
        }
    }

    /// Runs `body` once the chapter's text is there, fetching it first for
    /// web books. Stops if it can't be fetched or the book changed meanwhile.
    private func withChapter(_ index: Int, _ body: @escaping () -> Void) {
        guard !chapters[index].isDownloaded, let ensureChapter else { return body() }
        let book = bookID
        Task {
            let loaded = await ensureChapter(index)
            guard bookID == book, book != nil else { return }
            if loaded { body() } else { stop() }
        }
    }

    private func utteranceFinished(_ utterance: ObjectIdentifier) {
        guard utterance == currentUtterance, bookID != nil, chunks.indices.contains(chunkIndex) else { return }
        chunkIndex += 1
        if chunks.indices.contains(chunkIndex) {
            characterOffset = chunks[chunkIndex].offset
            speakCurrentChunk()
        } else if let paragraphIndex {
            speak(paragraph: paragraphIndex + 1)
        }
    }

    private func willSpeak(range: NSRange, of utterance: ObjectIdentifier) {
        guard utterance == currentUtterance, chunks.indices.contains(chunkIndex) else { return }
        characterOffset = chunks[chunkIndex].offset + range.location
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.utteranceFinished(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString range: NSRange,
                                       utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.willSpeak(range: range, of: id) }
    }

    /// zh-TW / zh-HK for traditional text, zh-CN otherwise, then any Chinese voice.
    static func voice(for script: ChineseScript) -> AVSpeechSynthesisVoice? {
        let preferred = script == .hant ? ["zh-TW", "zh-HK", "zh-CN"] : ["zh-CN", "zh-TW", "zh-HK"]
        for language in preferred {
            if let voice = AVSpeechSynthesisVoice(language: language) { return voice }
        }
        return AVSpeechSynthesisVoice.speechVoices().first { $0.language.hasPrefix("zh") }
    }
}
