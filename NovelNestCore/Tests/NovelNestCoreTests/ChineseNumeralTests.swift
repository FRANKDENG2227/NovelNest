import Testing
@testable import NovelNestCore

struct ChineseNumeralTests {
    @Test(arguments: [
        ("一", 1), ("十", 10), ("十二", 12), ("二十", 20), ("二十三", 23),
        ("一百", 100), ("一百零五", 105), ("一百一十", 110), ("三百二十一", 321),
        ("两千", 2000), ("兩千零八", 2008), ("一千零一", 1001),
        ("一万", 10_000), ("一万零一", 10_001), ("十二万三千四百五十六", 123_456),
        ("一亿两千万", 120_000_000),
        ("〇", 0), ("零", 0), ("二〇二", 202),
        ("1024", 1024), ("０２３", 23), ("3千", 3000), ("12万", 120_000),
    ])
    func parses(text: String, value: Int) {
        #expect(ChineseNumeral.parse(text) == value)
    }

    @Test(arguments: ["", "章", "一a", "第一"])
    func rejectsNonNumerals(text: String) {
        #expect(ChineseNumeral.parse(text) == nil)
    }
}
