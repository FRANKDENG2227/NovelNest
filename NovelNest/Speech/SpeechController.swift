import AVFoundation
import NovelNestCore
import Observation

/// On-device text-to-speech with AVSpeechSynthesizer (spec §8).
///
/// Speaks one paragraph at a time, split into sentence-sized utterances,
/// and moves on to the next chapter when a chapter ends. Interruption and
/// route-change handling, background audio, and saving the listening
/// position come with Phase 2.
@MainActor @Observable
final class SpeechController: NSObject, AVSpeechSynthesizerDelegate {
    private(set) var bookID: UUID?
    private(set) var chapterIndex: Int?
    private(set) var paragraphIndex: Int?
    private(set) var isSpeaking = false
    private(set) var isPaused = false

    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var chapters: [Chapter] = []
    @ObservationIgnored private var paragraphs: [String] = []
    @ObservationIgnored private var pendingUtterances = 0
    @ObservationIgnored private var voice: AVSpeechSynthesisVoice?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func start(book: Book, chapters: [Chapter], chapterIndex: Int, paragraphIndex: Int) {
        stop()
        guard chapters.indices.contains(chapterIndex) else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)

        bookID = book.id
        self.chapters = chapters
        voice = Self.voice(for: book.script)
        load(chapter: chapterIndex)
        speak(paragraph: min(paragraphIndex, max(paragraphs.count - 1, 0)))
    }

    func pause() {
        if synthesizer.pauseSpeaking(at: .word) {
            isSpeaking = false
            isPaused = true
        }
    }

    func resume() {
        if synthesizer.continueSpeaking() {
            isSpeaking = true
            isPaused = false
        }
    }

    func stop() {
        pendingUtterances = 0
        synthesizer.stopSpeaking(at: .immediate)
        bookID = nil
        chapterIndex = nil
        paragraphIndex = nil
        isSpeaking = false
        isPaused = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func load(chapter index: Int) {
        chapterIndex = index
        paragraphs = chapters[index].paragraphs
    }

    /// Queues every chunk of one paragraph. `didFinish` of the last chunk
    /// moves on, so the reader can highlight the paragraph being spoken.
    private func speak(paragraph index: Int) {
        guard paragraphs.indices.contains(index) else { return advanceChapter() }
        paragraphIndex = index
        let chunks = SpeechChunker.chunks(of: paragraphs[index])
        guard !chunks.isEmpty else { return speak(paragraph: index + 1) }

        let rate = UserDefaults.standard.object(forKey: AppStorageKey.speechRate) as? Double
            ?? Double(AVSpeechUtteranceDefaultSpeechRate)
        pendingUtterances = chunks.count
        for chunk in chunks {
            let utterance = AVSpeechUtterance(string: chunk)
            utterance.voice = voice
            utterance.rate = Float(rate)
            synthesizer.speak(utterance)
        }
        isSpeaking = true
        isPaused = false
    }

    private func advanceChapter() {
        guard let chapterIndex, chapters.indices.contains(chapterIndex + 1) else { return stop() }
        load(chapter: chapterIndex + 1)
        speak(paragraph: 0)
    }

    private func utteranceFinished() {
        guard bookID != nil, pendingUtterances > 0 else { return }
        pendingUtterances -= 1
        if pendingUtterances == 0, let paragraphIndex { speak(paragraph: paragraphIndex + 1) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.utteranceFinished() }
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
