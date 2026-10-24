import Foundation
import Testing
@testable import NovelNestCore

struct TXTChapterSplitterTests {
    static let sample = """
    《测试之书》
    作者：测试作者

    目录
    第一章 开始
    第二章 继续

    第一卷 起点
    第一章 开始
    第一章 开始
    　　他走进院子的时候，天已经黑了。
    \u{200B}　　第二段。\r
    第二章 继续
    \t内容二。
    番外 春日
    　　番外内容。
    """

    @Test func splitsChaptersVolumesAndPrologue() {
        let chapters = TXTChapterSplitter.split(Self.sample)
        #expect(chapters.map(\.title) == ["前言", "第一章 开始", "第二章 继续", "番外 春日"])
        #expect(chapters.map(\.kind) == [.prologue, .normal, .normal, .extra])
        #expect(chapters.map(\.parsedNumber) == [nil, 1, 2, nil])
        #expect(chapters.map(\.volumeTitle) == [nil, "第一卷 起点", "第一卷 起点", "第一卷 起点"])
    }

    @Test func cleansParagraphLayoutOnly() {
        let chapters = TXTChapterSplitter.split(Self.sample)
        #expect(chapters[0].paragraphs == ["《测试之书》", "作者：测试作者", "目录"])
        #expect(chapters[1].paragraphs == ["他走进院子的时候，天已经黑了。", "第二段。"])
        #expect(chapters[2].content == "内容二。")
    }

    @Test func fileWithoutTitlesIsSplitIntoParts() {
        let paragraph = String(repeating: "字", count: 1_000)
        let text = Array(repeating: paragraph, count: 12).joined(separator: "\n")
        let chapters = TXTChapterSplitter.split(text)
        #expect(chapters.map(\.title) == ["第1部分", "第2部分", "第3部分"])
        #expect(chapters.map(\.paragraphs.count) == [5, 5, 2])
    }

    @Test func emptyTextHasNoChapters() {
        #expect(TXTChapterSplitter.split(" \n\u{3000}\n").isEmpty)
    }
}

struct TXTImporterTests {
    @Test func importsGB18030File() throws {
        let text = "作者：某某\n第一章 开始\n" + Fixtures.simplified + "\n第二章 继续\n" + Fixtures.simplified
        let book = try TXTImporter.importBook(data: Fixtures.encode(text, as: .gb18030), fileName: "测试.txt")
        #expect(book.title == "测试")
        #expect(book.author == "某某")
        #expect(book.encoding == .gb18030)
        #expect(book.script == .hans)
        #expect(book.chapters.map(\.title) == ["前言", "第一章 开始", "第二章 继续"])
    }

    @Test func importsBig5File() throws {
        let text = "第一章 開始\n" + Fixtures.traditional
        let book = try TXTImporter.importBook(data: Fixtures.encode(text, as: .big5), fileName: "繁體.TXT")
        #expect(book.encoding == .big5)
        #expect(book.script == .hant)
        #expect(book.title == "繁體")
        #expect(book.chapters.first?.paragraphs == [Fixtures.traditional])
    }

    @Test func emptyFileFails() {
        #expect(throws: TXTImportError.empty) {
            try TXTImporter.importBook(data: Data("\n\n".utf8), fileName: "空.txt")
        }
    }

    @Test(arguments: [
        ("《斗转星河》作者：某人.txt", "斗转星河", "某人" as String?),
        ("《斗转星河》.txt", "斗转星河", nil),
        ("斗转星河 作者:某人.txt", "斗转星河", "某人"),
        ("plain.txt", "plain", nil),
        (".txt", ".txt", nil),
    ])
    func fileNames(fileName: String, title: String, author: String?) {
        let parsed = TXTImporter.parseFileName(fileName)
        #expect(parsed.title == title)
        #expect(parsed.author == author)
    }
}

struct ScriptDetectorTests {
    @Test func detectsScripts() {
        #expect(ScriptDetector.detect(Fixtures.simplified) == .hans)
        #expect(ScriptDetector.detect(Fixtures.traditional) == .hant)
        #expect(ScriptDetector.detect(Fixtures.simplified + Fixtures.traditional) == .mixed)
        #expect(ScriptDetector.detect("Hello, world") == .unknown)
    }

    @Test func speechLanguageFollowsScript() {
        #expect(ChineseScript.hant.speechLanguage == "zh-TW")
        #expect(ChineseScript.hans.speechLanguage == "zh-CN")
        #expect(ChineseScript.unknown.speechLanguage == "zh-CN")
    }
}
