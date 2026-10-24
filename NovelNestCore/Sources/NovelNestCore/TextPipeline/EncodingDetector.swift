import Foundation

/// Text encodings NovelNest can decode (spec §10A.3).
public enum TextEncoding: String, Sendable, CaseIterable, Codable {
    case utf8 = "utf-8"
    case utf16LE = "utf-16le"
    case utf16BE = "utf-16be"
    /// Also used for GBK and GB2312, which it is a superset of.
    case gb18030
    /// Decoded as Big5-HKSCS, a superset of Big5.
    case big5

    var stringEncoding: String.Encoding {
        switch self {
        case .utf8: .utf8
        case .utf16LE: .utf16LittleEndian
        case .utf16BE: .utf16BigEndian
        case .gb18030: Self.cfEncoding(.GB_18030_2000)
        case .big5: Self.cfEncoding(.big5_HKSCS_1999)
        }
    }

    private static func cfEncoding(_ encoding: CFStringEncodings) -> String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding.rawValue)))
    }

    /// Maps a charset label from HTTP headers, `<meta>` tags or source rules.
    public init?(label: String) {
        switch label.trimmingCharacters(in: .whitespaces).lowercased() {
        case "utf-8", "utf8": self = .utf8
        case "utf-16le": self = .utf16LE
        case "utf-16be": self = .utf16BE
        case "gb18030", "gbk", "gb2312", "x-gbk", "cp936", "euc-cn": self = .gb18030
        case "big5", "big5-hkscs", "cp950", "x-x-big5": self = .big5
        default: return nil
        }
    }
}

/// Heuristic measurements of how plausible a decoded Chinese text is.
public struct TextQuality: Sendable, Equatable {
    /// Share of U+FFFD replacement characters among all characters.
    public var replacementRatio: Double
    /// Share of CJK ideographs among non-whitespace characters.
    public var cjkRatio: Double
    /// Share of very common characters among CJK ideographs.
    public var frequentRatio: Double
    /// Occurrences of known mojibake signatures such as 锟斤拷.
    public var mojibakeHits: Int
    /// Non-ASCII, non-whitespace characters: the sample size for judging
    /// whether Chinese text was decoded correctly.
    public var nonASCIICount: Int
    /// Share of very common Chinese characters among `nonASCIICount`.
    public var frequentShareOfNonASCII: Double

    public var score: Double {
        0.3 * cjkRatio + 0.7 * frequentRatio - 5 * replacementRatio - 0.1 * Double(min(mojibakeHits, 10))
    }

    /// True when the text is very likely 乱码 rather than readable text.
    public var isGarbled: Bool {
        if replacementRatio > 0.01 || mojibakeHits >= 3 { return true }
        // In correct Chinese prose ~85% of non-ASCII characters are common
        // ideographs. Wrong-encoding output is mostly rare ideographs and
        // stray symbols (~5%). Too few characters to judge (e.g. a short
        // title) is not reported as garbled.
        return nonASCIICount >= 20 && frequentShareOfNonASCII < 0.4
    }

    static let mojibakeSignatures = ["锟斤拷", "烫烫烫", "屯屯屯", "Ã", "â€", "Â"]

    public init(text: String) {
        var total = 0, nonSpace = 0, nonASCII = 0, replacements = 0, cjk = 0, frequent = 0
        for character in text {
            total += 1
            if character.isWhitespace { continue }
            nonSpace += 1
            if !character.isASCII { nonASCII += 1 }
            if character == "\u{FFFD}" {
                replacements += 1
            } else if character.isCJKIdeograph {
                cjk += 1
                if CommonCharacters.frequent.contains(character) { frequent += 1 }
            }
        }
        replacementRatio = total == 0 ? 0 : Double(replacements) / Double(total)
        cjkRatio = nonSpace == 0 ? 0 : Double(cjk) / Double(nonSpace)
        frequentRatio = cjk == 0 ? 0 : Double(frequent) / Double(cjk)
        nonASCIICount = nonASCII
        frequentShareOfNonASCII = nonASCII == 0 ? 0 : Double(frequent) / Double(nonASCII)
        mojibakeHits = Self.mojibakeSignatures.reduce(0) { $0 + text.components(separatedBy: $1).count - 1 }
    }
}

public struct DecodedText: Sendable {
    public var text: String
    public var encoding: TextEncoding
    public var quality: TextQuality
}

/// Decodes bytes of unknown encoding (spec §10A.3).
///
/// Order: byte-order mark, then the declared charset (HTTP header, `<meta>`
/// or source rule) if it decodes cleanly, then the best-scoring candidate.
public enum EncodingDetector {
    static let candidates: [TextEncoding] = [.utf8, .gb18030, .big5]

    public static func decode(_ data: Data, declared: TextEncoding? = nil) -> DecodedText? {
        if let (encoding, bomLength) = byteOrderMark(of: data) {
            return decode(data.dropFirst(bomLength), as: encoding)
        }
        if let declared, let decoded = decode(data, as: declared), !decoded.quality.isGarbled {
            return decoded
        }
        // `max(by:)` keeps the first of equal scores, so pure-ASCII text
        // (identical in every candidate) stays UTF-8.
        return candidates
            .compactMap { decode(data, as: $0) }
            .max { $0.quality.score < $1.quality.score }
    }

    static func decode(_ data: Data, as encoding: TextEncoding) -> DecodedText? {
        guard let text = String(data: data, encoding: encoding.stringEncoding) else { return nil }
        return DecodedText(text: text, encoding: encoding, quality: TextQuality(text: text))
    }

    static func byteOrderMark(of data: Data) -> (TextEncoding, Int)? {
        let bytes = [UInt8](data.prefix(3))
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { return (.utf8, 3) }
        if bytes.starts(with: [0xFF, 0xFE]) { return (.utf16LE, 2) }
        if bytes.starts(with: [0xFE, 0xFF]) { return (.utf16BE, 2) }
        return nil
    }
}

extension Character {
    /// CJK Unified Ideographs, Extension A, and Compatibility Ideographs.
    var isCJKIdeograph: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF, 0x20000...0x2FA1F: return true
        default: return false
        }
    }
}
