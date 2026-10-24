/// Parses chapter numbers written in Chinese numerals, Arabic digits, or a
/// mix of both: 十二, 一百零五, 两千, 二〇二, 1024, ２３ (spec §10A.5).
public enum ChineseNumeral {
    static let digits: [Character: Int] = [
        "〇": 0, "零": 0, "一": 1, "二": 2, "两": 2, "兩": 2, "三": 3, "四": 4,
        "五": 5, "六": 6, "七": 7, "八": 8, "九": 9,
    ]
    static let smallUnits: [Character: Int] = ["十": 10, "拾": 10, "百": 100, "佰": 100, "千": 1000, "仟": 1000]
    static let largeUnits: [Character: Int] = ["万": 10_000, "萬": 10_000, "亿": 100_000_000, "億": 100_000_000]

    /// Characters that may appear in a numeral, for building title patterns.
    static let characterClass = "〇零一二两兩三四五六七八九十拾百佰千仟万萬亿億0-9０-９"

    public static func parse(_ text: String) -> Int? {
        let normalized = String(text.map(halfWidthDigit))
        guard !normalized.isEmpty else { return nil }

        if normalized.allSatisfy(\.isASCIIDigit) {
            return Int(normalized)
        }
        // A run of digits without units, e.g. 二〇二 = 202.
        if normalized.allSatisfy({ digitValue($0) != nil }) {
            return normalized.reduce(0) { $0 * 10 + digitValue($1)! }
        }

        var total = 0      // completed 万/亿 groups
        var section = 0    // value below the current 万 group
        var number = 0     // pending digit(s) awaiting a unit
        var sawDigit = false
        for character in normalized {
            if let value = digitValue(character) {
                // Arabic digits may form multi-digit numbers, as in 3千.
                number = character.isASCIIDigit && sawDigit ? number * 10 + value : value
                sawDigit = true
            } else if let unit = smallUnits[character] {
                // A leading 十 means 一十, as in 十二.
                section += (sawDigit ? number : 1) * unit
                number = 0
                sawDigit = false
            } else if let unit = largeUnits[character] {
                // 万 scales only the group before it (一亿两千万); 亿 scales everything.
                if unit == 10_000 {
                    total += (section + number) * unit
                } else {
                    total = (total + section + number) * unit
                }
                section = 0
                number = 0
                sawDigit = false
            } else {
                return nil
            }
        }
        return total + section + number
    }

    private static func digitValue(_ character: Character) -> Int? {
        character.isASCIIDigit ? character.wholeNumberValue : digits[character]
    }

    private static func halfWidthDigit(_ character: Character) -> Character {
        guard let scalar = character.unicodeScalars.first,
              (0xFF10...0xFF19).contains(scalar.value),
              let ascii = Unicode.Scalar(scalar.value - 0xFF10 + 0x30) else { return character }
        return Character(ascii)
    }
}

extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
