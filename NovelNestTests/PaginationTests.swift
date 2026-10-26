import Testing
import UIKit
@testable import NovelNest

/// Pages must show every character exactly once: what a page draws is what
/// its range says, nothing is drawn below the visible area, and reading
/// aloud never reaches text that no page shows.
@MainActor
struct PaginationTests {
    /// Synthetic paragraphs of varied length and punctuation.
    static func paragraphs(seed: Int, count: Int = 60) -> [String] {
        let pieces = ["他推开门，", "山中无岁月，", "“你来了。”", "云在脚下。", "她笑了笑，没有说话。", "远处传来钟声，",
                      "这一年，他十七岁。", "——", "……", "风吹过竹林，沙沙作响。", "第三天清晨，", "“走吧！”他说。", "Hello, world. "]
        var state = UInt64(seed &* 7919 &+ 17)
        func next(_ n: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(n))
        }
        return (0..<count).map { _ in (0..<(1 + next(16))).map { _ in pieces[next(pieces.count)] }.joined() }
    }

    static let sizes = [CGSize(width: 402, height: 778), CGSize(width: 402, height: 820), CGSize(width: 375, height: 600),
                        CGSize(width: 874, height: 360), CGSize(width: 1024, height: 1300)]

    @Test(arguments: [14.0, 17.0, 19.0, 23.0, 28.0, 32.0])
    func everyCharacterIsOnExactlyOnePageAndVisible(fontSize: Double) {
        let metrics = ReaderMetrics(fontSize: fontSize)
        for size in Self.sizes {
            let layout = PageLayout(size: size, metrics: metrics)
            let visibleHeight = layout.textSize.height + metrics.lineSpacing
            for seed in 0..<4 {
                let chapter = PaginatedChapter(title: "第一章 出山", paragraphs: Self.paragraphs(seed: seed), metrics: metrics,
                                               textSize: layout.textSize)
                #expect(chapter.pages.count == chapter.containers.count)
                var expectedStart = 0
                for (index, range) in chapter.pages.enumerated() {
                    // Contiguous, no gaps or overlaps.
                    #expect(range.location == expectedStart, "font \(fontSize) \(size) page \(index)")
                    expectedStart = NSMaxRange(range)

                    // The page draws exactly its own characters.
                    let view = PageTextView(chapter: chapter, page: index)
                    let drawn = chapter.layoutManager.characterRange(forGlyphRange: view.glyphRange, actualGlyphRange: nil)
                    #expect(drawn == range, "font \(fontSize) \(size) page \(index)")

                    // Every line is inside the page's visible text area.
                    var lowest: CGFloat = 0
                    chapter.layoutManager.enumerateLineFragments(forGlyphRange: view.glyphRange) { _, used, _, _, _ in
                        lowest = max(lowest, used.maxY)
                    }
                    if index < chapter.pages.count - 1 || chapter.containers[index].size.height < .greatestFiniteMagnitude {
                        #expect(lowest <= visibleHeight, "font \(fontSize) \(size) page \(index): \(lowest) > \(visibleHeight)")
                    }
                }
                #expect(expectedStart == chapter.text.length)
            }
        }
    }

    @Test func pageLookupStillMatchesLocations() {
        let metrics = ReaderMetrics(fontSize: 23)
        let layout = PageLayout(size: CGSize(width: 402, height: 778), metrics: metrics)
        let chapter = PaginatedChapter(title: "第一章", paragraphs: Self.paragraphs(seed: 1), metrics: metrics, textSize: layout.textSize)
        for page in chapter.pages.indices {
            let location = chapter.location(onPage: page, chapter: 0)
            #expect(chapter.page(containing: location) == page)
        }
    }

    @Test func emptyAndTinyChaptersHaveOnePage() {
        let metrics = ReaderMetrics(fontSize: 19)
        let empty = PaginatedChapter(title: "", paragraphs: [], metrics: metrics, textSize: CGSize(width: 300, height: 500))
        #expect(empty.pages.count == 1)
        #expect(empty.containers.count == 1)
        // A page too short for even one line still shows everything, on one page.
        let tiny = PaginatedChapter(title: "标题", paragraphs: ["正文"], metrics: metrics, textSize: CGSize(width: 300, height: 4))
        #expect(tiny.pages.count == tiny.containers.count)
        #expect(tiny.pages.last.map(NSMaxRange) == tiny.text.length)
    }
}
