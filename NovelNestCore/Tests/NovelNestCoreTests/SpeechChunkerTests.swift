import Testing
@testable import NovelNestCore

struct SpeechChunkerTests {
    @Test func keepsClosingQuotesAndRepeatedPunctuationWithTheSentence() {
        let sentences = SpeechChunker.sentences(of: "他说：「走吧。」她没回答……为什么？！好。")
        #expect(sentences == ["他说：「走吧。」", "她没回答……", "为什么？！", "好。"])
    }

    @Test func packsSentencesUpToMaxLength() {
        let chunks = SpeechChunker.chunks(of: "一二三。四五六。七八九。", maxLength: 8)
        #expect(chunks == ["一二三。四五六。", "七八九。"])
    }

    @Test func longSentenceIsCutAtCommas() {
        let sentence = String(repeating: "字", count: 6) + "，" + String(repeating: "字", count: 6) + "。"
        let chunks = SpeechChunker.chunks(of: sentence, maxLength: 10)
        #expect(chunks == [String(repeating: "字", count: 6) + "，", String(repeating: "字", count: 6) + "。"])
    }

    @Test func textWithoutPunctuationIsHardCut() {
        let chunks = SpeechChunker.chunks(of: String(repeating: "字", count: 25), maxLength: 10)
        #expect(chunks.map(\.count) == [10, 10, 5])
    }

    @Test func noTextIsLostOrRepeated() {
        let paragraph = Fixtures.simplified + "「对吗？」" + String(repeating: "长", count: 450) + "完。"
        #expect(SpeechChunker.chunks(of: paragraph, maxLength: 50).joined() == paragraph)
    }

    @Test func emptyParagraphHasNoChunks() {
        #expect(SpeechChunker.chunks(of: "  ").isEmpty)
    }
}
