import Foundation
import Testing
@testable import NovelNestCore

struct EncodingDetectorTests {
    @Test(arguments: [
        (Fixtures.simplified, TextEncoding.utf8),
        (Fixtures.simplified, TextEncoding.gb18030),
        (Fixtures.traditional, TextEncoding.utf8),
        (Fixtures.traditional, TextEncoding.big5),
    ])
    func detectsEncodingWithoutHint(text: String, encoding: TextEncoding) throws {
        let decoded = try #require(EncodingDetector.decode(Fixtures.encode(text, as: encoding)))
        #expect(decoded.encoding == encoding)
        #expect(decoded.text == text)
        #expect(!decoded.quality.isGarbled)
    }

    @Test func utf8ByteOrderMarkIsStripped() throws {
        let data = Data([0xEF, 0xBB, 0xBF]) + Fixtures.encode(Fixtures.simplified, as: .utf8)
        let decoded = try #require(EncodingDetector.decode(data))
        #expect(decoded.encoding == .utf8)
        #expect(decoded.text == Fixtures.simplified)
    }

    @Test func wrongDeclaredCharsetIsRecovered() throws {
        let data = Fixtures.encode(Fixtures.simplified, as: .gb18030)
        let decoded = try #require(EncodingDetector.decode(data, declared: .big5))
        #expect(decoded.encoding == .gb18030)
        #expect(decoded.text == Fixtures.simplified)
    }

    @Test func correctDeclaredCharsetIsUsed() throws {
        let data = Fixtures.encode(Fixtures.traditional, as: .big5)
        let decoded = try #require(EncodingDetector.decode(data, declared: .big5))
        #expect(decoded.encoding == .big5)
    }

    @Test func asciiStaysUTF8() throws {
        let decoded = try #require(EncodingDetector.decode(Data("Chapter 1\nHello".utf8)))
        #expect(decoded.encoding == .utf8)
    }

    @Test func big5ReadAsGB18030IsGarbled() throws {
        let data = Fixtures.encode(Fixtures.traditional, as: .big5)
        let wrong = try #require(EncodingDetector.decode(data, as: .gb18030))
        #expect(wrong.quality.isGarbled)
    }

    @Test(arguments: [
        "锟斤拷锟斤拷锟斤拷锟斤拷",
        "Ã¤Â½Â Ã¥Â¥Â½Ã¯Â¼ÂŒ",
        "他走进\u{FFFD}\u{FFFD}院子\u{FFFD}",
    ])
    func mojibakeIsGarbled(text: String) {
        #expect(TextQuality(text: text).isGarbled)
    }

    @Test func normalProseIsNotGarbled() {
        #expect(!TextQuality(text: Fixtures.simplified).isGarbled)
        #expect(!TextQuality(text: Fixtures.traditional).isGarbled)
        // Too short to judge, even though these characters are uncommon.
        #expect(!TextQuality(text: "鬼斧神工·饕餮").isGarbled)
    }

    @Test(arguments: [
        ("GBK", TextEncoding.gb18030), ("gb2312", .gb18030), ("Big5", .big5), (" UTF-8 ", .utf8),
    ])
    func charsetLabels(label: String, encoding: TextEncoding) {
        #expect(TextEncoding(label: label) == encoding)
    }

    @Test func unknownCharsetLabel() {
        #expect(TextEncoding(label: "shift_jis") == nil)
    }
}
