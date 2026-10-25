import AVFoundation
import NovelNestCore
import Observation

/// On-device text-to-speech with AVSpeechSynthesizer (spec §8).
///
/// Speaks one sentence-sized chunk at a time, so a rate change applies from
/// the next sentence, and moves on to the next chapter when a chapter ends.
/// `characterOffset` follows the word being spoken so the reader can
/// highlight the paragraph and turn the page when speech reaches it.
/// Interruption and route-change handling, background audio, and saving the
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

    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
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

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Starts at the chunk containing `characterOffset`, so speech begins
    /// at the top of a page that starts partway into a paragraph.
    func start(book: Book, chapters: [Chapter], chapterIndex: Int, paragraphIndex: Int, characterOffset: Int = 0) {
        stop()
        guard chapters.indices.contains(chapterIndex) else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)

        bookID = book.id
        self.chapters = chapters
        voice = Self.voice(for: book.script)
        load(chapter: chapterIndex)
        speak(paragraph: min(paragraphIndex, max(paragraphs.count - 1, 0)), from: characterOffset)
    }

    func pause() {
        if synthesizer.pauseSpeaking(at: .word) {
            isSpeaking = false
            isPaused = true
        }
    }

    func resume() {
        if let resumeFrom {
            self.resumeFrom = nil
            speak(paragraph: resumeFrom.paragraph, from: resumeFrom.offset)
        } else if synthesizer.continueSpeaking() {
            isSpeaking = true
            isPaused = false
        }
    }

    /// Continues reading from another place in the same book, e.g. the top
    /// of a page the reader turned to. While paused it stays paused and
    /// `resume()` starts there.
    func move(toChapter chapter: Int, paragraph: Int, characterOffset offset: Int) {
        guard bookID != nil, chapters.indices.contains(chapter) else { return }
        currentUtterance = nil
        synthesizer.stopSpeaking(at: .immediate)
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
        chapterIndex = nil
        paragraphIndex = nil
        characterOffset = 0
        isSpeaking = false
        isPaused = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func load(chapter index: Int) {
        chapterIndex = index
        paragraphs = chapters[index].paragraphs
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
        isSpeaking = true
        isPaused = false
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
        load(chapter: chapterIndex + 1)
        speak(paragraph: 0)
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
