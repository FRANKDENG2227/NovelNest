# NovelNest

A personal iOS reader for Chinese web novels: local TXT/EPUB import,
recently-opened bookshelf, reading-position restore, and on-device
text-to-speech. See [`CLAUDE_CODE_NOVEL_READER_SPEC.md`](CLAUDE_CODE_NOVEL_READER_SPEC.md).

## Status

Phase 1 in progress.

| Part | State |
|------|-------|
| `NovelNestCore` Swift package (text pipeline, speech chunking, bookshelf order, reading position) | Done, 41 tests pass |
| SwiftUI iOS app: bookshelf, TXT import, reader, TOC, typography, progress save/restore, read aloud | Compiles; not yet run in a simulator |
| App tests (SwiftData import, ordering, progress, delete) | Compile; not yet run |
| EPUB import | Not started |

## Layout

```
project.yml                    XcodeGen definition of NovelNest.xcodeproj
NovelNest/                     SwiftUI app (iOS 17+)
  Models/Models.swift          SwiftData Book / Chapter / ReadingProgress
  Library/                     Bookshelf view, import/progress/delete service
  Reader/                      Reader, table of contents, typography settings
  Speech/SpeechController.swift  AVSpeechSynthesizer playback
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
    Library/
      BookshelfOrdering.swift  lastOpenedAt DESC NULLS LAST
      ReadingPosition.swift    Save/restore position across chapter changes
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
`swift test`.
