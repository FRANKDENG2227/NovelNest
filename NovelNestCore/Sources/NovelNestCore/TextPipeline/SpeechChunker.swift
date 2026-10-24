import Foundation

/// Splits paragraphs into utterances for text-to-speech (spec §8).
///
/// Breaks after sentence-ending punctuation 。！？…； (and ASCII . ! ? ;),
/// keeping any closing quotes that follow with the sentence, then packs
/// sentences into chunks of at most `maxLength` characters. A single
/// sentence longer than that is cut at commas, or hard-cut as a last resort.
public enum SpeechChunker {
    public static let defaultMaxLength = 200

    private static let sentenceEnds: Set<Character> = ["。", "！", "？", "…", "；", "!", "?", ";", "."]
    private static let closingQuotes: Set<Character> = ["」", "』", "”", "’", "\"", "'", "）", ")"]
    private static let softBreaks: Set<Character> = ["，", "、", "：", ",", ":"]

    public static func chunks(of paragraph: String, maxLength: Int = defaultMaxLength) -> [String] {
        var chunks: [String] = []
        var current = ""
        for sentence in sentences(of: paragraph).flatMap({ split($0, at: softBreaks, maxLength: maxLength) }) {
            if !current.isEmpty, current.count + sentence.count > maxLength {
                chunks.append(current)
                current = ""
            }
            current += sentence
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func sentences(of text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        var endedSentence = false
        for character in text {
            // Close the sentence at the first character that is neither more
            // end punctuation (……, ！？) nor a closing quote.
            if endedSentence, !sentenceEnds.contains(character), !closingQuotes.contains(character) {
                sentences.append(current)
                current = ""
                endedSentence = false
            }
            current.append(character)
            if sentenceEnds.contains(character) { endedSentence = true }
        }
        if !current.isEmpty { sentences.append(current) }
        return sentences
    }

    /// Cuts `text` after characters in `breaks` so pieces fit `maxLength`.
    private static func split(_ text: String, at breaks: Set<Character>, maxLength: Int) -> [String] {
        guard text.count > maxLength else { return [text] }
        var pieces: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if current.count >= maxLength || (breaks.contains(character) && current.count >= maxLength / 2) {
                pieces.append(current)
                current = ""
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }
}
