import SwiftUI
import UIKit

/// Chapters laid out into screen-sized pages with TextKit and shown in a
/// `UIPageViewController`, turned left/right or up/down depending on the
/// mode. Turning past a chapter's last page continues with the next one.
struct PagedReaderView: UIViewControllerRepresentable {
    let store: ChapterStore
    let metrics: ReaderMetrics
    let theme: ReaderTheme
    let mode: PageTurnMode
    let size: CGSize
    /// Changes when a chapter's text arrives (web books).
    var contentVersion = 0
    @Binding var location: ReaderLocation
    let jump: ReaderJump?
    /// Paragraph being read aloud (only chapter and paragraph are used).
    let highlight: ReaderLocation?
    let onTap: () -> Void
    /// The reader turned the page by swiping (not a jump or speech
    /// following along), with the new page's first character.
    let onPageTurn: (ReaderLocation) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let controller = UIPageViewController(transitionStyle: .scroll,
                                              navigationOrientation: mode == .vertical ? .vertical : .horizontal)
        controller.dataSource = context.coordinator
        controller.delegate = context.coordinator
        controller.view.backgroundColor = .clear
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped))
        controller.view.addGestureRecognizer(tap)
        return controller
    }

    func updateUIViewController(_ controller: UIPageViewController, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update(controller)
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: PagedReaderView
        /// Paginated chapters for `layout`; cleared when the layout changes.
        private var chapters: [Int: PaginatedChapter] = [:]
        /// `ChapterStore.revision` each paginated chapter was laid out from.
        private var revisions: [Int: Int] = [:]
        private var contentVersion = 0
        private var layout: PageLayout?
        private var theme: ReaderTheme?
        private var jumpID: UUID?
        private var highlight: ReaderLocation?
        /// The page on screen, tracked here because `viewControllers` lags
        /// behind while a turn is animating.
        private var shown: PageRef?
        /// An animated turn started in code is still running.
        private var turningInCode = false
        /// A turn started by the reader's finger (`willTransitionTo` is only
        /// called for those) is in progress.
        private var swiping = false

        init(_ parent: PagedReaderView) {
            self.parent = parent
        }

        @objc func tapped() { parent.onTap() }

        /// Re-renders only when the layout, theme or a jump changed; the
        /// reader's own location updates come back through here too.
        func update(_ controller: UIPageViewController) {
            guard parent.store.count > 0, parent.size.width > 0, parent.size.height > 0 else { return }
            if parent.highlight != highlight {
                highlight = parent.highlight
                for page in controller.viewControllers?.compactMap({ $0 as? PageController }) ?? [] {
                    page.highlight = highlightRange(in: page.page.chapter)
                }
            }
            let layout = PageLayout(size: parent.size, metrics: parent.metrics)
            let jump = parent.jump.flatMap { $0.id == jumpID ? nil : $0 }
            // New chapter text is laid out once no turn is in progress.
            var contentChanged = false
            if parent.contentVersion != contentVersion, !swiping, !turningInCode {
                contentVersion = parent.contentVersion
                let stale = revisions.filter { parent.store.revision($0.key) != $0.value }.map(\.key)
                for chapter in stale {
                    chapters[chapter] = nil
                    revisions[chapter] = nil
                }
                // The page view keeps the neighbouring pages, so the next
                // or previous chapter changing matters too.
                if let shown, stale.contains(where: { abs($0 - shown.chapter) <= 1 }) { contentChanged = true }
            }
            guard layout != self.layout || parent.theme != theme || jump != nil || contentChanged else { return }

            let restyle = layout != self.layout || parent.theme != theme || contentChanged
            if layout != self.layout {
                chapters = [:]
                revisions = [:]
            }
            self.layout = layout
            theme = parent.theme
            jumpID = parent.jump?.id

            let current = shown
            let target = page(containing: jump?.location ?? parent.location)
            // Speech moving to a paragraph on the page already shown.
            if !restyle && target == current { return }
            let direction: UIPageViewController.NavigationDirection =
                current.map { target < $0 } == true ? .reverse : .forward
            // Starting a turn while another is animating leaves the page
            // view on the wrong page and reports the old turn as finished.
            let animated = jump?.animated == true && current != nil && !turningInCode
            shown = target
            turningInCode = turningInCode || animated
            controller.setViewControllers([pageController(target)], direction: direction, animated: animated) { _ in
                guard animated else { return }
                // After an animated turn the page view can keep stale
                // neighbouring pages; setting the page again without
                // animation resets them, and lands on any jump made meanwhile.
                DispatchQueue.main.async {
                    self.turningInCode = false
                    guard let shown = self.shown else { return }
                    controller.setViewControllers([self.pageController(shown)], direction: .forward, animated: false)
                }
            }
            // Turning pages in code doesn't call the delegate, so report the
            // new page (after this view update) for saving and progress.
            if jump != nil {
                let location = paginated(target.chapter).location(onPage: target.index, chapter: target.chapter)
                DispatchQueue.main.async { self.parent.location = location }
            }
        }

        /// The highlighted paragraph's range in a chapter's text, if it is
        /// in that chapter.
        private func highlightRange(in chapter: Int) -> NSRange? {
            guard let highlight, highlight.chapter == chapter else { return nil }
            return paginated(chapter).range(ofParagraph: highlight.paragraph)
        }

        private func paginated(_ chapter: Int) -> PaginatedChapter {
            if let cached = chapters[chapter] { return cached }
            let result = PaginatedChapter(title: parent.store.title(chapter), paragraphs: parent.store.paragraphs(chapter),
                                          metrics: parent.metrics, textSize: layout?.textSize ?? .zero)
            chapters[chapter] = result
            revisions[chapter] = parent.store.revision(chapter)
            return result
        }

        private func page(containing location: ReaderLocation) -> PageRef {
            let chapter = min(max(location.chapter, 0), parent.store.count - 1)
            return PageRef(chapter: chapter, index: paginated(chapter).page(containing: location))
        }

        private func pageController(_ page: PageRef) -> PageController {
            let chapter = paginated(page.chapter)
            let controller = PageController(page: page, chapter: chapter, chapterTitle: parent.store.title(page.chapter),
                                            layout: layout ?? PageLayout(size: parent.size, metrics: parent.metrics),
                                            theme: parent.theme)
            controller.highlight = highlightRange(in: page.chapter)
            return controller
        }

        func pageViewController(_ controller: UIPageViewController,
                                viewControllerBefore viewController: UIViewController) -> UIViewController? {
            guard let page = (viewController as? PageController)?.page else { return nil }
            if page.index > 0 { return pageController(PageRef(chapter: page.chapter, index: page.index - 1)) }
            guard page.chapter > 0 else { return nil }
            let previous = paginated(page.chapter - 1)
            return pageController(PageRef(chapter: page.chapter - 1, index: previous.pages.count - 1))
        }

        func pageViewController(_ controller: UIPageViewController,
                                viewControllerAfter viewController: UIViewController) -> UIViewController? {
            guard let page = (viewController as? PageController)?.page else { return nil }
            if page.index + 1 < paginated(page.chapter).pages.count {
                return pageController(PageRef(chapter: page.chapter, index: page.index + 1))
            }
            guard parent.store.contains(page.chapter + 1) else { return nil }
            return pageController(PageRef(chapter: page.chapter + 1, index: 0))
        }

        func pageViewController(_ controller: UIPageViewController,
                                willTransitionTo pendingViewControllers: [UIViewController]) {
            swiping = true
        }

        /// Only swipes count as the reader turning the page; this is also
        /// called late for turns made in code.
        func pageViewController(_ controller: UIPageViewController, didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            let wasSwipe = swiping
            swiping = false
            guard wasSwipe, completed, let page = (controller.viewControllers?.first as? PageController)?.page else {
                return
            }
            shown = page
            let location = paginated(page.chapter).location(onPage: page.index, chapter: page.chapter)
            parent.location = location
            parent.onPageTurn(location)
        }
    }
}

private struct PageRef: Hashable, Comparable {
    var chapter: Int
    var index: Int

    static func < (lhs: PageRef, rhs: PageRef) -> Bool {
        (lhs.chapter, lhs.index) < (rhs.chapter, rhs.index)
    }
}

/// Space around the text on each page: a header line with the chapter
/// title and a footer with the page number.
private struct PageLayout: Equatable {
    static let headerHeight: CGFloat = 36
    static let footerHeight: CGFloat = 32

    var size: CGSize
    var metrics: ReaderMetrics

    var margin: CGFloat { metrics.margin(forWidth: size.width) }

    var textSize: CGSize {
        CGSize(width: max(size.width - margin * 2, 1),
               height: max(size.height - Self.headerHeight - Self.footerHeight, 1))
    }
}

/// One chapter as an attributed string split into page-sized ranges.
private struct PaginatedChapter {
    let text: NSAttributedString
    /// Character ranges of each page.
    let pages: [NSRange]
    /// Start offset of the title (element 0) and of each paragraph.
    private let starts: [Int]

    /// Two ideographic spaces before each paragraph. Not counted in a
    /// location's `offset`, which is into the paragraph's own text.
    private static let indent = "\u{3000}\u{3000}"
    private static let indentLength = (indent as NSString).length

    init(title: String, paragraphs: [String], metrics: ReaderMetrics, textSize: CGSize) {
        let titleStyle = NSMutableParagraphStyle()
        titleStyle.lineSpacing = metrics.lineSpacing / 2
        titleStyle.paragraphSpacing = metrics.paragraphSpacing * 2
        let bodyStyle = NSMutableParagraphStyle()
        bodyStyle.lineSpacing = metrics.lineSpacing
        bodyStyle.paragraphSpacing = metrics.paragraphSpacing
        // Even right edge where line-breaking rules leave a line short.
        bodyStyle.alignment = .justified

        let text = NSMutableAttributedString(string: title + (paragraphs.isEmpty ? "" : "\n"), attributes: [
            .font: UIFont.systemFont(ofSize: metrics.titleSize, weight: .semibold),
            .paragraphStyle: titleStyle,
        ])
        var starts = [0]
        let bodyAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: metrics.fontSize),
            .paragraphStyle: bodyStyle,
        ]
        for (index, paragraph) in paragraphs.enumerated() {
            starts.append(text.length)
            let line = Self.indent + paragraph + (index == paragraphs.count - 1 ? "" : "\n")
            text.append(NSAttributedString(string: line, attributes: bodyAttributes))
        }
        self.text = text
        self.starts = starts
        pages = Self.paginate(text, size: textSize)
    }

    /// Lays the text out into page-sized text containers until it is used up.
    private static func paginate(_ text: NSAttributedString, size: CGSize) -> [NSRange] {
        let storage = NSTextStorage(attributedString: text)
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        var pages: [NSRange] = []
        var end = 0
        while end < storage.length {
            let container = NSTextContainer(size: size)
            container.lineFragmentPadding = 0
            layoutManager.addTextContainer(container)
            let glyphs = layoutManager.glyphRange(for: container)
            let range = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            // A line taller than the page would never fit; stop instead of looping.
            guard range.length > 0 else { break }
            pages.append(range)
            end = NSMaxRange(range)
        }
        if end < storage.length {
            pages.append(NSRange(location: end, length: storage.length - end))
        }
        return pages.isEmpty ? [NSRange(location: 0, length: storage.length)] : pages
    }

    /// The page showing a location's character, so a page that starts
    /// partway into a paragraph is found again rather than the page where
    /// that paragraph begins.
    func page(containing location: ReaderLocation) -> Int {
        let index = location.paragraph + 1
        guard starts.indices.contains(index) else { return location.paragraph < 0 ? 0 : pages.count - 1 }
        let indent = location.paragraph == ReaderLocation.title ? 0 : Self.indentLength
        let end = starts.indices.contains(index + 1) ? starts[index + 1] : text.length
        let offset = min(starts[index] + indent + max(location.offset, 0), max(end - 1, starts[index]))
        return pages.firstIndex { NSMaxRange($0) > offset } ?? pages.count - 1
    }

    /// A paragraph's text (with its indent, without the line break).
    func range(ofParagraph paragraph: Int) -> NSRange? {
        let index = paragraph + 1
        guard index > 0, starts.indices.contains(index) else { return nil }
        let end = starts.indices.contains(index + 1) ? starts[index + 1] - 1 : text.length
        return NSRange(location: starts[index], length: max(end - starts[index], 0))
    }

    /// The location of a page's first character.
    func location(onPage page: Int, chapter: Int) -> ReaderLocation {
        guard pages.indices.contains(page) else { return .start(of: chapter) }
        let start = pages[page].location
        let index = starts.lastIndex { $0 <= start } ?? 0
        let indent = index == 0 ? 0 : Self.indentLength
        return ReaderLocation(chapter: chapter, paragraph: index - 1, offset: max(start - starts[index] - indent, 0))
    }
}

private final class PageController: UIViewController {
    let page: PageRef
    private let chapter: PaginatedChapter
    private let chapterTitle: String
    private let layout: PageLayout
    private let theme: ReaderTheme

    /// Range in the chapter's text to highlight; the part on this page is.
    var highlight: NSRange? {
        didSet { if isViewLoaded, highlight != oldValue { renderText() } }
    }

    private let header = UILabel()
    private let footer = UILabel()
    private let textView = UITextView(usingTextLayoutManager: false)

    init(page: PageRef, chapter: PaginatedChapter, chapterTitle: String, layout: PageLayout, theme: ReaderTheme) {
        self.page = page
        self.chapter = chapter
        self.chapterTitle = chapterTitle
        self.layout = layout
        self.theme = theme
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        let textColor = UIColor(theme.text)
        view.backgroundColor = UIColor(theme.background)

        for label in [header, footer] {
            label.font = .systemFont(ofSize: 12)
            label.textColor = textColor.withAlphaComponent(0.5)
            view.addSubview(label)
        }
        // The first page already shows the chapter title in large type.
        header.text = page.index == 0 ? nil : chapterTitle
        footer.text = "\(page.index + 1) / \(chapter.pages.count)"
        footer.textAlignment = .right

        renderText()
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isSelectable = false
        textView.isScrollEnabled = false
        textView.isUserInteractionEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        view.addSubview(textView)
    }

    private func renderText() {
        let pageRange = chapter.pages[page.index]
        let pageText = NSMutableAttributedString(attributedString: chapter.text.attributedSubstring(from: pageRange))
        pageText.addAttribute(.foregroundColor, value: UIColor(theme.text),
                              range: NSRange(location: 0, length: pageText.length))
        if let highlight, let overlap = highlight.intersection(pageRange) {
            pageText.addAttribute(.backgroundColor, value: UIColor(Color.accentColor).withAlphaComponent(0.22),
                                  range: NSRange(location: overlap.location - pageRange.location, length: overlap.length))
        }
        textView.attributedText = pageText
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bounds = view.bounds
        let margin = layout.margin
        let width = layout.textSize.width
        header.frame = CGRect(x: margin, y: 8, width: width, height: 20)
        footer.frame = CGRect(x: margin, y: bounds.height - PageLayout.footerHeight + 6, width: width, height: 20)
        // Extra height so a rounding difference never clips the last line;
        // the page's text already ends where the layout said it would.
        textView.frame = CGRect(x: margin, y: PageLayout.headerHeight, width: width,
                                height: layout.textSize.height + layout.metrics.lineSpacing)
    }
}
