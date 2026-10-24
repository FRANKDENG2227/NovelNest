# NovelNest

A personal iOS reader for Chinese web novels: local TXT/EPUB import,
recently-opened bookshelf, reading-position restore, and on-device
text-to-speech. See [`CLAUDE_CODE_NOVEL_READER_SPEC.md`](CLAUDE_CODE_NOVEL_READER_SPEC.md).

## Status

Phase 1 in progress.

| Part | State |
|------|-------|
| `NovelNestCore` Swift package (text pipeline, bookshelf order, reading position) | Done, tested |
| SwiftUI iOS app (bookshelf, reader, file import, SwiftData) | Not started; needs Xcode |
| EPUB import | Not started |

## Layout

```
NovelNestCore/                 Pure-Swift package, no UI (iOS 17+, macOS 14+)
  Sources/NovelNestCore/
    TextPipeline/
      EncodingDetector.swift   UTF-8 / GB18030 (GBK) / Big5 detection, 乱码 scoring
      ChineseNumeral.swift     十二, 一百零五, 二〇二, 1024 → Int
      ChapterTitleParser.swift 第N章 / 第N卷 / 楔子 / 番外 / 感言 …
      TXTChapterSplitter.swift Splits TXT into chapters; layout-only cleanup
      TXTImporter.swift        Bytes + file name → ImportedBook
      ScriptDetector.swift     简/繁 detection, only to pick a TTS voice
    Library/
      BookshelfOrdering.swift  lastOpenedAt DESC NULLS LAST
      ReadingPosition.swift    Save/restore position across chapter changes
  Tests/NovelNestCoreTests/    Swift Testing suites with synthetic fixtures
scripts/test-core.sh           Runs the package tests
```

## Requirements

- macOS with Swift 6 (Command Line Tools are enough for `NovelNestCore`).
- **Xcode 16 or later** for the iOS app and simulator (install from the
  Mac App Store, then run `sudo xcode-select -s /Applications/Xcode.app`).

## Test

```sh
scripts/test-core.sh
```

With only the Command Line Tools installed, the script adds the
framework search paths Swift Testing needs. With Xcode, it runs plain
`swift test`.
