/// Writing script of a text, stored in `Book.originalScript` (spec §10A.7).
public enum ChineseScript: String, Sendable, Codable {
    case hans
    case hant
    case mixed
    case unknown

    /// BCP-47 language for choosing a speech voice.
    public var speechLanguage: String {
        self == .hant ? "zh-TW" : "zh-CN"
    }
}

/// Detects simplified vs traditional text. Used only to pick a TTS voice;
/// text is never converted between scripts.
public enum ScriptDetector {
    private static let simplified = Set(CommonCharacters.simplifiedOnly)
    private static let traditional = Set(CommonCharacters.traditionalOnly)

    public static func detect(_ text: String) -> ChineseScript {
        var hans = 0, hant = 0
        for character in text {
            if simplified.contains(character) { hans += 1 } else if traditional.contains(character) { hant += 1 }
        }
        let total = hans + hant
        guard total > 0 else { return .unknown }
        let hansShare = Double(hans) / Double(total)
        if hansShare >= 0.8 { return .hans }
        if hansShare <= 0.2 { return .hant }
        return .mixed
    }
}
