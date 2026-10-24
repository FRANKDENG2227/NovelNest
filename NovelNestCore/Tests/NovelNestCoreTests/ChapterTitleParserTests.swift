import Testing
@testable import NovelNestCore

struct ChapterTitleParserTests {
    @Test(arguments: [
        ("第一章 初入江湖", 1),
        ("第一章初入江湖", 1),
        ("  第12章  ", 12),
        ("第一百零五回 风雨", 105),
        ("第二十章：結局", 20),
        ("第三节 入门", 3),
        ("第 8 章 空格", 8),
    ])
    func numberedChapters(line: String, number: Int) throws {
        let parsed = try #require(ChapterTitleParser.parse(line))
        #expect(parsed.role == .chapter(.normal))
        #expect(parsed.number == number)
        #expect(parsed.title == line.trimmingCharacters(in: .whitespaces))
    }

    @Test(arguments: [("第一卷 少年", 1), ("第三部", 3), ("第二集：归来", 2)])
    func volumes(line: String, number: Int) throws {
        let parsed = try #require(ChapterTitleParser.parse(line))
        #expect(parsed.role == .volume)
        #expect(parsed.number == number)
    }

    @Test(arguments: [
        ("楔子", ChapterKind.prologue), ("序章 风起", .prologue), ("前言", .prologue),
        ("番外一 春日", .extra), ("後記", .extra), ("尾声", .extra),
        ("完本感言", .authorNote), ("請假條", .authorNote), ("上架感言", .authorNote),
    ])
    func specialKinds(line: String, kind: ChapterKind) throws {
        let parsed = try #require(ChapterTitleParser.parse(line))
        #expect(parsed.role == .chapter(kind))
        #expect(parsed.number == nil)
    }

    @Test(arguments: [
        "第三节课的时候，他还没来",
        "第一章已经写完了，大家觉得怎么样。",
        "第一次见面",
        "他说：第一章呢？",
        "第一章" + String(repeating: "长", count: 40),
        "",
        "普通的一句话",
    ])
    func proseIsNotATitle(line: String) {
        #expect(ChapterTitleParser.parse(line) == nil)
    }
}
