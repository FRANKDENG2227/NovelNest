# NovelNest

A personal iOS reader for Chinese web novels: local TXT/EPUB import,
recently-opened bookshelf, reading-position restore, and on-device
text-to-speech. See [`CLAUDE_CODE_NOVEL_READER_SPEC.md`](CLAUDE_CODE_NOVEL_READER_SPEC.md).

## Status

Phase 1 in progress.

| Part | State |
|------|-------|
| `NovelNestCore` Swift package (text pipeline, speech chunking, bookshelf order, reading position, book-source rules and scripts) | Done, 97 tests pass |
| SwiftUI iOS app: bookshelf, TXT import, reader, progress save/restore, read aloud | Runs in the simulator |
| Immersive paged reader: tap to show/hide controls, left/right or up/down page turning across chapters, contents drawer, day backgrounds and night mode | Runs in the simulator |
| Read aloud: paragraph highlight, automatic page turning, restart from the current page, volume/brightness/rate sheet | Runs in the simulator |
| 找书: yck (源仓库) book sources with JavaScript, default source, read straight from a search, 加入书架, 换源 | Runs in the simulator |
| App tests (SwiftData import, ordering, progress, delete, web books, sources, 换源, source checks, export, script limits on iOS, pagination) | 28 tests pass |
| EPUB import | Not started |

## Reader

- Only the text shows while reading. Tap the page to bring up the top bar
  and the panel (上一章 / 下一章, reading progress, 目录, 白天/夜间, 朗读,
  设置); tap again to hide them.
- Pages are laid out with TextKit and turned left/right or up/down;
  turning past a chapter's last page continues with the next chapter.
  Line and paragraph spacing follow the font size.
- Each chapter is laid out once and every page draws its glyphs from
  that layout, so no line can fall between pages (laying a page's text
  out again used to break lines differently and hide the last ones).
- The position is saved to the character at the top of the page, so
  switching page-turn mode or reopening the book returns to the same page.
- The day background (white, beige, green, grey) is chosen in 设置;
  night mode is always dark. The bookshelf and settings use the same colour.
- 朗读 reads from the top of the current page, highlights the paragraph
  and turns pages as it goes. Turning the page or jumping to a chapter
  continues from there; leaving the book stops it. While reading, the
  朗读 button opens pause/stop, a sleep timer (20 minutes by default,
  changed in 5-minute steps), volume, brightness and speed. Reading
  aloud continues with the screen locked; the lock-screen banner pauses
  and continues it and skips to the previous or next chapter.

## 找书 (book sources)

- In 找书 → 书源, paste a yck (yckceo.com) source link: the `.json`
  link or the `yuedu://booksource/importonline?src=…` 网络导入 link.
  Importing again updates the sources and keeps each one's on/off switch.
- Rules: default (JSoup) chains, `@css:`, JSONPath, `&&` / `||` / `%%`,
  `##regex##`, `@put` / `@get`, `{{…}}` templates, URL options (POST,
  GBK) and JavaScript (`@js:`, `<js>`, `jsLib`) in JavaScriptCore with
  Legado's common `java.*` helpers: `ajax` / `connect` (source's own
  domains only), `put` / `get`, Base64, hex, MD5, `encodeURI`,
  `timeFormat`, `getString`. Sources needing decryption, a built-in
  browser, cookies or logins, device IDs, files, Java classes or XPath
  are imported but stay off, with the reason shown. In a sample of 40
  yck sources, 10 qualified.
- Every search records whether each source answered. Sources whose
  site refused access, asked for verification, timed out or errored are
  marked 失效 with the reason; 检测已启用的书源 checks them all at once.
  The 不能用 filter lists unsupported and failing sources, and 删除不能用的
  书源 removes them (all, or only one kind); books already on the shelf
  stay.
- 导出 (top right of 书源) writes the usable, enabled or all sources as
  a Legado (阅读) book-source JSON array, shared as a file or copied to
  the clipboard, for 阅读 and compatible apps. Each source is exported
  as it was imported, with the fields NovelNest doesn't use and its
  current on/off state; sources imported before this keep only the
  fields NovelNest uses until they're imported again.
- Swipe a source right (or long-press it) for 设为默认: it's searched
  first and its results are ranked first.
- Search runs on up to 12 sources at once, 10 seconds each, and shows
  results as each source answers, merging the same title and author.
  Tap a book to read it right away; long-press for its details and
  sources.
- The last 6 searches are kept on the device and shown before searching
  (and as suggestions in the search field); tap one to search again,
  swipe to delete it, or 清空 to clear them.
- A book opened from a search isn't on the shelf yet: 加入书架 is in the
  reader's top bar, and leaving asks whether to add it. Books not added
  are removed. The same title from different sources can each be added.
- 换源 (top bar, for web books) searches the other sources for the same
  title and moves the book there, continuing at the matching chapter;
  useful when a source's text is garbled.
- A chapter's text is fetched when it's read, with the next two
  prefetched, and then kept locally; 重新加载本章 fetches it again.
- Requests stay on the source's own site (never this device or the local
  network), are spaced 0.5 s apart per host, stop on 401/403, CAPTCHA
  pages and 429/503 (spec §9), and are cut off past 5 MB as they stream.
  Covers load only from the source's site. Plain-http subscription links
  ask for confirmation first.
- Limits for broken or hostile sources: a script runs at most 5 s per
  evaluation, makes at most 30 requests, nests at most 8 deep; one that
  hits a limit is stopped and its source turned off. Regular expressions
  stop after 0.5 s. A search gives up on a source after 10 s without
  waiting for its scripts, which then can't make further requests.

## Layout

```
project.yml                    XcodeGen definition of NovelNest.xcodeproj
NovelNest/                     SwiftUI app (iOS 17+)
  Models/Models.swift          SwiftData Book / Chapter / ReadingProgress
  Library/                     Bookshelf view, import/progress/delete/source service
  Search/
    SearchView.swift           找书 tab: search all enabled sources
    BookPreviewView.swift      Book page, contents, 试读, 加入书架
    SourceListView.swift       Import yck links, turn sources on/off, default
    ChangeSourceView.swift     换源: the same title from other sources
  Reader/
    ReaderView.swift           Immersive reader, control panel, contents drawer
    PagedReaderView.swift      TextKit pagination in a UIPageViewController
    ChapterStore.swift         Chapters loaded on demand, reading locations
    ChapterLoader.swift        Fetches web chapters' text while reading
    ReaderAppearance.swift     Themes, font metrics, page-turn mode, settings
  Speech/
    SpeechController.swift     AVSpeechSynthesizer, one sentence at a time
    SpeechSettingsView.swift   Pause/stop, sleep timer, volume, brightness, rate
    SilentAudio.swift          Silence that keeps the app the Now Playing app
  Settings/SettingsView.swift
NovelNestTests/                App tests with an in-memory SwiftData store
NovelNestCore/                 Pure-Swift package, no UI (iOS 17+, macOS 14+)
  Sources/NovelNestCore/
    TextPipeline/
      EncodingDetector.swift   UTF-8 / GB18030 (GBK) / Big5 detection, 乱码 scoring
      ChineseNumeral.swift     十二, 一百零五, 二〇二, 1024 → Int
      ChapterTitleParser.swift 第N章 / 第N卷 / 楔子 / 番外 / 感言 …
      TXTChapterSplitter.swift Splits TXT into chapters; layout-only cleanup
      TXTImporter.swift        Bytes + file name → ImportedBook
      ScriptDetector.swift     简/繁 detection, only to pick a TTS voice
      SpeechChunker.swift      Splits paragraphs into utterances at 。！？…；
    WebSource/
      LegadoSource.swift       Legado/yck book-source JSON
      SourceCompatibility.swift Which sources can run (no JS/XPath/WebView)
      SourceRequest.swift      URL templates, `,{options}`, GBK encoding
      RuleEvaluator.swift      JSoup chains, CSS, JSONPath, combinators
      RuleSyntax.swift         Rule parsing, script segments, regex limits
      ScriptHost.swift         JavaScriptCore with the `java.*` helpers
      SourceFetcher.swift      HTTP, domain policy, throttle, block detection
      WebBookClient.swift      Search, book page + contents, chapter text
      HTMLText.swift           Chapter HTML → paragraphs
    Library/
      BookshelfOrdering.swift  lastOpenedAt DESC NULLS LAST
      ReadingPosition.swift    Save/restore position across chapter changes
      ChapterMatcher.swift     Matching chapter after 换源
  Tests/NovelNestCoreTests/    Swift Testing suites with synthetic fixtures
scripts/test-core.sh           Runs the package tests
```

## Requirements

- macOS with Swift 6 (Command Line Tools are enough for `NovelNestCore`).
- **Xcode 26 or later** with an iOS simulator runtime for the app. After
  installing Xcode, finish its one-time setup:

  ```sh
  sudo xcode-select -s /Applications/Xcode.app
  sudo xcodebuild -runFirstLaunch
  xcodebuild -downloadPlatform iOS
  ```
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
  only if you change `project.yml`; the generated project is committed.

## Build and run

Open `NovelNest.xcodeproj` in Xcode, pick an iPhone simulator, and press
Run. From the command line:

```sh
xcodegen generate   # only after editing project.yml
xcodebuild -project NovelNest.xcodeproj -scheme NovelNest \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
```

To import a book in the simulator, drag a `.txt` file onto the simulator
window (it lands in Files), then tap **+** on the bookshelf.

## Test

```sh
scripts/test-core.sh                         # core package
xcodebuild -project NovelNest.xcodeproj -scheme NovelNest \
  -destination 'platform=iOS Simulator,name=iPhone 17' test   # app
```

With only the Command Line Tools installed, the script adds the
framework search paths Swift Testing needs. With Xcode, it runs plain
`swift test`. If codesigning the test bundle fails with "resource fork,
Finder information, or similar detritus not allowed" (common for
projects on the Desktop), build outside the folder:
`scripts/test-core.sh --scratch-path /tmp/novelnest-core`.
