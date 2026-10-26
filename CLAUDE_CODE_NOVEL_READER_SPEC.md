# NovelNest iOS --- Product Requirements & Engineering Brief for Claude Code

> Project status: initial specification\
> Primary goal: a personal iOS novel reader/library with text-to-speech,
> lawful source integration, offline downloads, reading-position sync,
> and a recently-opened-first bookshelf.

## 1. Product vision

Build an iOS app for reading novels from multiple permitted sources and
from user-imported files. Users can search/browse supported sources, add
books to a personal library, read online or offline, listen using
text-to-speech, resume exactly where they stopped, and see books sorted
by most recently opened.

The app must be useful even when a source is unavailable: locally
imported or lawfully downloaded books remain readable offline.

Primary content is **Chinese web novels**. Source adapters, text
cleaning, chapter parsing, and the data model are designed around
Chinese novel-site page structures (书页 / 目录 / 正文), legacy
encodings (GBK/GB18030/Big5), and multi-page chapters. See §10A.

### Non-goals for MVP

-   Do not attempt to bypass paywalls, authentication, CAPTCHAs, bot
    protection, rate limits, or other access controls.
-   Do not rotate IPs/proxies, spoof identities, or otherwise evade a
    site's ban/throttling mechanisms.
-   Do not scrape every arbitrary website automatically.
-   Do not redistribute copyrighted books or expose a public library.
-   Do not build AI summarization or social/community features in the
    first release.
-   No simplified/traditional (简繁) display conversion; text is shown
    in its original script.

## 2. Source
base on yck web https://www.yckceo.com/yuedu/tools/index.html. using thire shuyuan rule to obtain xiaoshuo.
## 3. Platforms and suggested architecture

### iOS client

Recommended MVP stack: - Swift + SwiftUI. - SwiftData for local metadata
and reading state, or SQLite/Core Data if cross-version migrations or
advanced querying justify it. - AVSpeechSynthesizer for on-device
text-to-speech. - AVAudioSession for audio-session configuration;
implement interruption and route-change handling. - URLSession for
permitted source/API requests and downloads. - EPUB/TXT import using
SwiftUI fileImporter and Uniform Type Identifiers. - BackgroundTasks
only for best-effort refresh tasks; do not promise continuous background
crawling on iOS. - XCTest for unit/integration tests.

Prefer an offline-first design. Reading position, library metadata, and
downloaded content should work without a server.

### Optional self-hosted backend

Use this only if the user wants multiple devices, centralized source
adapters, or a web UI: - Python 3.12+ / FastAPI. - PostgreSQL for
metadata, source registry, jobs, and sync state. - SQLAlchemy +
Alembic. - httpx + BeautifulSoup4/lxml for permitted static HTML
sources. - Playwright only when a permitted source genuinely requires
JavaScript rendering. - Docker Compose for deployment. - A
worker/scheduler can be added later; do not add Redis/Celery until
actual concurrency needs justify it.

Suggested separation: - iOS app: UI, local library, reader, audio
playback, downloads, reading progress. - Source adapters: isolated
implementation per permitted source. - Policy/permission registry:
controls whether a source can be queried/downloaded. - Backend
(optional): source crawling and metadata sync, only for approved
sources. - Database: source metadata, book/chapter metadata, task state,
reading progress sync. - Local file store: downloaded EPUB/TXT or
chapter content, with checksums and provenance.

Do not make the backend a generic arbitrary-URL fetch proxy. Validate
hosts and redirect targets against an allowlist to prevent SSRF and
access to localhost, private networks, link-local addresses, cloud
metadata services, or other internal resources.

## 4. Main user stories

1.  As a user, I can add a book from a supported/authorized source or
    import a local EPUB/TXT file.
2.  As a user, I can search books from enabled sources.
3.  As a user, I can open a book and read chapters.
4.  As a user, I can download permitted content for offline reading and
    see progress, errors, and storage size.
5.  As a user, I can listen to the current chapter using iOS
    text-to-speech.
6.  As a user, I can pause/resume speech, skip forward/backward by
    paragraph, adjust speaking rate, and continue with the next chapter.
7.  As a user, the app saves the current chapter and approximate reading
    position automatically.
8.  As a user, the bookshelf sorts by the most recent time I opened a
    book, not by last download/update time.
9.  As a user, I can manually refresh a book and optionally enable a
    permitted periodic update check.
10. As a user, I can delete a book and its downloaded content.
11. As a user, I can see where each book came from and whether it is
    available offline.
12. As a user, I can export or back up my own reading progress and
    metadata where practical.

## 5. Navigation and screens

Use a simple tab-based SwiftUI app: - **Bookshelf**: recently opened
first; filters for All / Downloaded / In progress / Finished; search and
sorting controls. - **Discover**: search enabled sources, with source
attribution and source status. - **Downloads**: active, queued,
completed, failed, and paused downloads; cancel/retry controls. -
**Settings**: speech voice/rate, download policy, storage usage, source
permissions/attribution, privacy, backup/sync settings.

Reader screen: - Chapter title and book title. - Typography controls
(font size, line spacing, theme, margins). - Previous/next chapter. -
Reading progress and chapter navigation. - Listen / pause / resume /
stop controls. - Offline indicator. - Save position on scroll changes
with debouncing, and on scene backgrounding. - Optional sleep timer if
reliable with AVSpeechSynthesizer; defer if not.

## 6. Recently opened bookshelf ordering

Use a dedicated `lastOpenedAt` field on each library item. Update it
when the user explicitly opens the book/reader, not when background sync
runs, a download finishes, or a notification arrives.

Default sort: `lastOpenedAt DESC NULLS LAST`, with never-opened books
below opened books. For local SwiftData, implement equivalent ordering
and test null behavior. Keep `lastReadAt` separately if the product
needs to distinguish opening a book from actually reading.

Do not sort the main bookshelf by `updatedAt`, `lastDownloadedAt`, or
`lastSyncedAt`.

## 7. Reading progress model

Persist at least: - `bookId` - `chapterId` or stable source chapter
identifier - `chapterIndex` - `position`: normalized progress or
character/paragraph offset - `scrollOffset` only if needed and stable -
`updatedAt` - `deviceId` if multi-device sync is implemented

For EPUB, use a stable EPUB CFI or equivalent location reference where
supported; do not rely only on a raw pixel scroll offset. For plain
text, use chapter ID plus character/paragraph offset. Debounce frequent
writes (for example 500--1000 ms) and force-save when leaving the reader
or entering background. Do not lose progress when the app is killed.

When content changes, attempt to restore by stable chapter ID; if that
fails, fall back to nearest chapter index and then normalized progress.
Clearly handle deleted/renumbered chapters.

If syncing between devices is implemented, use a deterministic conflict
policy based on `updatedAt` initially, and document its limitations.
Avoid overwriting a newer position with a stale background update.

## 8. Text-to-speech / listening requirements

MVP should use `AVSpeechSynthesizer` for on-device TTS; it does not
require uploading book text to a third-party speech service.

Requirements: - Play, pause, continue, stop. - Select available system
voices and speaking rate. - Sentence/paragraph-aware chunking to avoid
feeding a huge novel as one utterance. - Queue chapters and move to the
next chapter after completion. - Persist the approximate speech location
so listening can resume. - Handle phone calls, Siri, headphones,
Bluetooth route changes, and audio interruptions. - Avoid reading
navigation labels or duplicated headers. - Provide a setting for whether
audio may continue when the screen locks, subject to iOS audio-session
behavior and App Store policy. - Test long chapters, punctuation,
Chinese text, English text, mixed-language text, and unavailable
voices. - TTS is not the same as downloadable audiobook audio. Do not
imply a generated audio file exists unless an explicit audio-export
feature is implemented.

For Chinese novels, test punctuation-aware chunking and paragraph
boundaries. Preserve original text and do not silently alter the saved
chapter to improve speech.

Chinese-specific rules: - Chunk on sentence-ending punctuation
`。！？…；` and closing quotes `」』”` that follow them; never split
inside a quotation pair if avoidable. - Speak the cleaned text (§10A.4);
never speak removed boilerplate, navigation text, or the duplicated
chapter title. - Pick a zh-CN voice for simplified text and
zh-TW/zh-HK for traditional text (`Book.originalScript`, §10A.7),
falling back to any available Chinese voice. - Optionally skip `authorNote` chapters
(`ttsSkipAuthorNotes`).

## 9. Downloading and refresh behavior

The goal is reliable, polite downloading---not avoiding bans by evading
a website's controls.

-   Download from yck provided web.
-   Prefer a site's official bulk download/export/API when available.
-   Use a per-domain concurrency limit, conservative configurable
    request interval, connection/read timeouts, bounded retries,
    exponential backoff with jitter, and `Retry-After`.
-   Use ETag/If-Modified-Since when supported.
-   Cache successful responses and avoid re-fetching unchanged chapters.
-   Do not fetch all chapters repeatedly when only new chapters are
    needed.
-   Pause a source on 401, 403, CAPTCHA, explicit block response, or
    rights/permission uncertainty. Do not rotate IPs, use proxy pools,
    spoof user agents to bypass blocks, or replay unauthorized cookies.
-   On 429/503, honor server instructions and pause as required.
-   Display download queue status and errors to the user.
-   Store a source-specific `lastCheckedAt`, `lastSuccessfulSyncAt`,
    `lastSeenChapterId`, and error status.
-   Do not claim iOS can run a continuous background crawler; background
    execution is opportunistic. For reliable scheduled source checks,
    use a user-controlled self-hosted backend only for permitted
    sources.

Downloads must be resumable where the server supports range requests.
Write to a temporary file, verify file size/type/checksum where
possible, then atomically move into the library. Never mark a partial
download as complete.

## 10. Source adapter and rule format

Define a documented, versioned, declarative schema, for example: -
`schemaVersion` - `sourceId` - `displayName` - `baseURL` - `termsURL` -
`licenseNotes` - `permissionStatus`: `approved`, `manual_review`, or
`disabled` - `allowedDomains` - `rateLimit`: minimum interval and
concurrency - `search`: URL template or documented API endpoint -
`bookInfo`: field extraction definitions - `toc`: chapter list and
pagination definitions - `chapter`: content extraction definitions -
`selectors`: CSS selectors and allowed attributes - `encoding` -
`attributionTemplate` - `storageAllowed` - `lastReviewedAt`

Rules should support only a small safe subset: - CSS selector
selection. - Text extraction. - Attribute extraction. - Relative URL
resolution. - Documented pagination. - Explicit JSON field paths for
documented APIs.

Rules must not support arbitrary Python/JavaScript execution, shell
commands, dynamic module loading, arbitrary headers/cookies from
untrusted files, or unrestricted URL templates. Validate every URL and
redirect target against approved domains. Reject malformed/unknown rule
fields rather than guessing. Require a manual permission review before
enabling a source.

If importing a third-party reader-app rule (for example a JSON "book
source"), treat it as a format that may need translation into this app's
schema. Do not assume the original rule syntax is directly executable.

Implemented for yck (Legado) sources: default JSoup chains, `@css:`,
JSONPath without filters, `&&` / `||` / `%%`,
`##regex##replacement[###]` (guarded against ReDoS), `@put` / `@get`,
`{{…}}` templates, URL options `,{method, body, charset, headers}`, and
JavaScript (`@js:`, `<js>`, `jsLib`) in JavaScriptCore with a limited
`java` object: `ajax` / `connect` through the same fetcher (source's own
domains, throttled, stops on blocks), variables, Base64, hex, MD5, URL
encoding, time formatting and rule evaluation. Only User-Agent, Referer,
Accept, Accept-Language and Content-Type headers are taken from a source.
Sources needing decryption, a built-in browser, cookies or logins, device
IDs, files, Java classes, XPath or WebView are imported but cannot be
enabled. Imported, enabled sources form the allowlist; requests and
redirects must stay on a source's own site, never loopback, private or
link-local addresses. Limits for untrusted sources: 5 s per script
evaluation (JavaScriptCore's execution time limit, looked up at run time
because it isn't public API), 30 requests per script host, 8 levels of
rule/script nesting, 0.5 s per regular expression, 5 MB per response
(enforced while streaming). A source whose script hits a limit is
disabled. JavaScript heap size is not limited (no API); the time limit
and at most 6 concurrent evaluations bound it.
## 10A. Chinese web-novel source adaptation

Everything in this section describes **page structures and text
processing only**. A structural template never enables a source by
itself: each concrete site still needs the permission review in §2 and
§10, and no real site is hard-coded in the app. Do not ship adapters for
unreviewed sites.

### 10A.1 Common page structures

Chinese novel sites usually have four page types. Rules target each one
separately.

| Page | Chinese name | Typical content |
|------|--------------|-----------------|
| Search results | 搜索结果 | List of title / author / latest chapter / book URL |
| Book info | 书页 / 简介页 | Title, author, category, 连载/完结 status, cover, intro, latest chapter, link to TOC |
| Table of contents | 目录 / 章节列表 | Ordered chapter links, optionally grouped by volume |
| Chapter | 正文 / 阅读页 | Chapter title, body, prev / 目录 / next links |

**Book info.** Many sites expose structured metadata; prefer it over CSS
selectors when present:

```html
<meta property="og:novel:book_name" content="…">
<meta property="og:novel:author" content="…">
<meta property="og:novel:category" content="…">
<meta property="og:novel:status" content="连载中 | 已完结">
<meta property="og:novel:latest_chapter_name" content="…">
<meta property="og:novel:update_time" content="…">
```

Map status text to `serialStatus`: 连载/连载中 → `ongoing`,
完结/已完结/完本 → `completed`, otherwise `unknown`.

**Table of contents.** Common layouts:

- `dl > dt + dd > a` — `dt` holds a volume or section header
  (第一卷 …, 正文, 作品相关), `dd > a` holds chapter links.
- `ul > li > a` (or `div.list > a`) — flat chapter list.
- A leading **"最新章节" block** (the latest ~9–12 chapters, often newest
  first) placed *before* the full list, usually separated by a `dt`
  such as 《书名》正文. The rule must skip it (`toc.startAfterSelector`
  or `toc.skipLeadingItems`), and dedupe by URL as a safety net.
- **Paginated TOC**: page links in a `<select><option value=…>` or
  下一页 links. Follow only documented pagination, with a page cap.
- **Order**: some lists are newest-first; `toc.order: desc` reverses
  them so `chapterIndex` always increases from the first chapter.

**Chapter page.** Body in a single container (`#content`-style div),
with prev / 目录 / next links nearby. Long chapters are often **split
into several pages**:

- URL pattern such as `{chapterId}.html`, `{chapterId}_2.html`,
  `{chapterId}_3.html`.
- Page indicators such as 第(1/3)页 in the title or body.
- A link labelled **下一页** (next page of the same chapter) instead of
  **下一章** (next chapter).

See §10A.6 for merging.

**Desktop vs mobile.** A desktop domain and its `m.` mobile domain are
separate entries in `allowedDomains` and are reviewed separately. Their
page structures usually differ, so each has its own rule set.

### 10A.2 Rule schema extensions

Add these fields to the §10 schema. All are declarative; unknown fields
are rejected.

- `encoding`: `auto | utf-8 | gb18030 | big5` (GBK/GB2312 map to
  `gb18030`).
- `defaultScript`: `hans | hant | unknown`.
- `bookInfo.metaProperties`: map from book fields to `og:novel:*` meta
  names.
- `bookInfo.statusMap`: text → `ongoing | completed`.
- `toc.itemSelector`: chapter link selector.
- `toc.volumeSelector`: volume header selector (e.g. `dt`).
- `toc.startAfterSelector` / `toc.skipLeadingItems`: skip the 最新章节
  block.
- `toc.pagination`: selector for TOC page links, plus `maxPages`.
- `toc.order`: `asc | desc`.
- `chapter.titleSelector`, `chapter.contentSelector`.
- `chapter.nextPage`: `{ selector, textMatches: ["下一页"],
  urlPattern: "{chapterId}_{n}.html" }`.
- `chapter.maxPagesPerChapter`: hard cap (default 10).
- `chapter.removeSelectors`: elements removed before text extraction.
- `chapter.removeLines`: literal strings; a line containing one is
  dropped. Regex is allowed only from a restricted subset (no
  backreferences, no nested quantifiers) and runs with a time/length
  limit to prevent ReDoS.

### 10A.3 Encoding detection and 乱码 handling

Many Chinese sites and most older TXT files use GBK/GB18030 or Big5.
Decode in this order and stop at the first trusted answer:

1. `charset` in the HTTP `Content-Type` header.
2. Byte-order mark (UTF-8 / UTF-16).
3. `<meta charset>` or `<meta http-equiv="Content-Type">`.
4. The rule's `encoding` (if not `auto`).
5. Heuristic: try UTF-8, GB18030, Big5 and keep the best quality score.

Always decode GB2312/GBK with the **GB18030** decoder (a superset) and
Big5 with **Big5-HKSCS**. On iOS, use
`CFStringConvertEncodingToNSStringEncoding` with
`kCFStringEncodingGB_18030_2000` / `kCFStringEncodingBig5_HKSCS_1999`.

**Quality score** (higher is better), computed on decoded text:
- ratio of U+FFFD replacement characters (penalty);
- ratio of CJK characters to letters overall (reward for Chinese
  sources);
- known mojibake signatures (penalty): `锟斤拷`, `烫烫烫`, `屯屯屯`, and
  Latin-1 artefacts such as `Ã`, `â€`, `å`, `æ` sequences inside
  otherwise Chinese text.

If every decoder scores below the threshold, store the chapter with
`contentQuality = garbled`, show a "garbled text" notice, and **never
overwrite an existing good copy** with the garbled one. Record the
chosen encoding in `Chapter.contentEncoding`.

The same detector runs for imported TXT files.

### 10A.4 Content cleaning pipeline

Cleaning is deterministic, versioned (`cleanerVersion`), and
re-runnable when the cleaner improves. It changes layout and removes
non-story text, but **never rewrites wording or punctuation**.

Steps, in order:
1. Remove `chapter.removeSelectors`, `<script>`, `<style>`, hidden
   elements.
2. Convert `<br>`, `<p>`, `<div>` boundaries into paragraph breaks.
3. Decode HTML entities; normalize `&nbsp;`, full-width space U+3000
   indentation (`　　`), and tabs into a single leading-indent style.
4. Remove zero-width characters (U+200B–U+200D, U+FEFF).
5. Remove a duplicated chapter title in the first lines of the body.
6. Drop boilerplate lines: rule `removeLines` plus a small built-in
   list, for example 本章未完，请点击下一页继续阅读 / 一秒记住 /
   最新网址 / 手机用户请浏览 / 请收藏本站 / bare URLs and domain names.
7. Collapse runs of blank lines; trim each paragraph.
8. **Placeholder detection**: bodies such as 正在手打中 / 内容更新中 /
   章节内容正在努力恢复, or bodies far shorter than the book's median
   chapter, get `contentQuality = placeholder` and are re-checked on the
   next refresh.

**Obfuscated text is an access control.** If a site renders text
through custom-font glyph mapping, injects deliberately scrambled
characters, or otherwise hides text from automated readers, mark the
source unsupported. Do not try to de-obfuscate it.

### 10A.5 Chapter title parsing and numbering

Parse each raw title into a number, kind, and display title. Keep the
original as `rawTitle`.

- Numbered chapter:
  `第([〇零一二两三四五六七八九十百千万\d]+)[章节回]`.
- Volume: `第([〇零一二两三四五六七八九十百千万\d]+)[卷集部篇]`,
  or a TOC `dt` header.
- Special kinds:
  - `prologue`: 序章 / 楔子 / 引子 / 序言 / 前言
  - `extra`: 番外 / 外传 / 后记 / 尾声
  - `authorNote`: 完本感言 / 上架感言 / 请假条 / 单章 / 感言 / 公告
- Chinese-numeral parser: handles 〇/零, 两, 十 at the start (十二 = 12),
  百/千/万 units, and mixed Arabic digits. Covered by a table-driven test.

`chapterIndex` is always the **source TOC order** and is canonical.
`parsedNumber` is used only to warn about gaps or duplicates (sites
often misnumber chapters), never to reorder them.

The same parser splits imported TXT files into chapters: a line that
matches a chapter or special-kind pattern, is short (≤ 40 characters),
and stands alone becomes a chapter boundary. Text before the first
match becomes a `prologue` chapter titled 前言 if it is non-empty.

`hideAuthorNotes` hides `authorNote` chapters in the TOC and reader
without deleting them.

### 10A.6 Chapter merging and deduplication

**(a) Multi-page chapters.** Starting from the chapter URL, follow
`chapter.nextPage` while the link stays within the same chapter (URL
pattern matches or the link text is 下一页, not 下一章 or 目录). Stop at
`maxPagesPerChapter`. Concatenate the cleaned pages, dropping
overlapping lines repeated at a page boundary. The chapter is complete
only when **all pages** were fetched; otherwise it stays incomplete and
the job retries it (same atomic rule as §9). Store `pageCount`.

**(b) Split chapters in the TOC.** Titles such as …（上）/（下） or
…（1）/（2） stay separate `Chapter` records. They share a
`mergeGroupKey` (title without the suffix) so the reader can optionally
show them as one chapter.

**(c) TOC deduplication.**
- Same normalized URL twice (e.g. the 最新章节 block) → one record.
- Same title, different URL → keep both, set `isDuplicateTitle`, and
  let the user hide one.

**(d) Cross-source merging** of the same book from different sources is
a non-goal for MVP.

### 10A.7 Simplified / traditional script

**No 简繁 conversion.** Text is always displayed and spoken exactly in
the script the source or file provides. Simplified/traditional display
conversion is a non-goal.

- Script detection (count characters unique to simplified vs
  traditional) is used only to pick a TTS voice; store the result in
  `Book.originalScript`.
- Search and dedupe use `normalizedTitle` / `normalizedAuthor`: the
  original title/author with whitespace and punctuation removed (no
  script conversion).

## 11. Suggested data model

Use stable UUIDs for internal IDs and separate source-specific
identifiers.

### Source

-   `id: UUID`
-   `name: String`
-   `baseURL: URL`
-   `termsURL: URL?`
-   `licenseNotes: String`
-   `permissionStatus: enum`
-   `allowedDomains: [String]`
-   `minimumRequestIntervalSeconds: Double`
-   `maxConcurrency: Int`
-   `storageAllowed: Bool`
-   `lastReviewedAt: Date?`
-   `enabled: Bool`
-   `mobileBaseURL: URL?` (separate reviewed domain, §10A.1)
-   `encoding: auto | utf-8 | gb18030 | big5`
-   `defaultScript: hans | hant | unknown`
-   `ruleSchemaVersion: Int`
-   `cleanerRuleSetVersion: Int`

### Book

-   `id: UUID`
-   `title: String`
-   `author: String?`
-   `language: String?`
-   `descriptionText: String?`
-   `coverURL: URL?`
-   `sourceId: UUID?`
-   `sourceBookId: String?`
-   `sourceURL: URL?`
-   `rights/attributionNotes: String?`
-   `isFinished: Bool`
-   `createdAt: Date`
-   `updatedAt: Date`
-   `lastOpenedAt: Date?`
-   `lastReadAt: Date?`
-   `isDownloaded: Bool`
-   `downloadState: enum`
-   `originalScript: hans | hant | mixed | unknown`
-   `normalizedTitle: String` (no whitespace/punctuation; §10A.7)
-   `normalizedAuthor: String?`
-   `category: String?`
-   `serialStatus: ongoing | completed | unknown` (连载 / 完结)
-   `latestChapterTitle: String?` (as reported by the source)
-   `sourceUpdatedAt: Date?` (source's own update time, not ours)
-   `tocURL: URL?`
-   `wordCount: Int?`

Unique: (`sourceId`, `sourceBookId`).

### Volume (optional)

-   `id: UUID`
-   `bookId: UUID`
-   `title: String` (e.g. 第一卷 …)
-   `volumeIndex: Int`

### Chapter

-   `id: UUID`
-   `bookId: UUID`
-   `sourceChapterId: String?`
-   `title: String` (display title)
-   `rawTitle: String` (exactly as in the source TOC)
-   `chapterIndex: Int` (source TOC order; canonical)
-   `volumeId: UUID?`
-   `parsedNumber: Int?` (from 第N章; for warnings only)
-   `chapterKind: normal | prologue | extra | authorNote | unknown`
-   `content: String` or local file reference (cleaned text)
-   `contentHash: String` (of cleaned text)
-   `rawContentHash: String?` (of decoded text before cleaning)
-   `contentEncoding: String?` (encoding actually used to decode)
-   `contentQuality: ok | garbled | placeholder | truncated | empty`
-   `cleanerVersion: Int`
-   `pageCount: Int` (pages merged into this chapter; §10A.6)
-   `wordCount: Int?`
-   `mergeGroupKey: String?` (groups （上）/（下） parts)
-   `isDuplicateTitle: Bool`
-   `sourceURL: URL?`
-   `publishedAt: Date?`
-   `fetchedAt: Date?`
-   `isAvailableOffline: Bool`

Unique: (`bookId`, `sourceChapterId`); when the source has no stable
chapter ID, (`bookId`, normalized `sourceURL`).

### ReadingProgress

-   `id: UUID`
-   `bookId: UUID`
-   `chapterId: UUID?`
-   `chapterIndex: Int`
-   `locationReference: String?`
-   `paragraphIndex: Int?`
-   `characterOffset: Int?` (within the paragraph)
-   `normalizedProgress: Double`
-   `updatedAt: Date`

`paragraphIndex` and `characterOffset` refer to the cleaned chapter
text.

### UserPreferences

-   `hideAuthorNotes: Bool`
-   `ttsSkipAuthorNotes: Bool`

### DownloadJob

-   `id: UUID`
-   `bookId: UUID`
-   `state: queued | running | paused | completed | failed | cancelled`
-   `completedItems: Int`
-   `totalItems: Int?`
-   `bytesDownloaded: Int64`
-   `lastError: String?`
-   `createdAt: Date`
-   `updatedAt: Date`

For a local-only MVP, SwiftData models can implement these entities. If
a backend is later introduced, define matching server-side models and
versioned API DTOs rather than sharing database objects directly across
the network.

## 12. Security and privacy

-   Store secrets in Keychain; never commit secrets.
-   Avoid collecting user accounts or analytics unless needed and
    clearly disclosed.
-   Treat downloaded HTML, JSON, EPUB, and source rules as untrusted
    data.
-   Sanitize displayed HTML and avoid rendering arbitrary scripts.
-   Restrict server-side outbound requests to allowlisted domains and
    public IP addresses; validate redirects and DNS resolution to reduce
    SSRF risk.
-   Apply response-size limits, timeouts, content-type validation, and
    decompression limits.
-   Keep the database private; do not expose PostgreSQL directly to the
    internet.
-   Use HTTPS for remote APIs.
-   Provide deletion and backup/restore workflows.
-   Do not transmit reading history or novel text to external services
    by default.
-   TTS should be local by default; clearly disclose any future cloud
    TTS option.

## 13. Testing and acceptance criteria

### Bookshelf

-   Opening a book moves it to the top of the bookshelf immediately.
-   Downloading or background syncing a book does not change
    `lastOpenedAt`.
-   Never-opened books appear after opened books.
-   Sorting remains correct after app restart.

### Reading progress

-   Leave a chapter and reopen it: position is restored within a
    reasonable tolerance.
-   Force quit and relaunch: last saved position is restored.
-   Switching chapters updates the stored chapter ID/index correctly.
-   Content updates do not silently reset progress.

### TTS

-   Play/pause/resume/stop work.
-   Speech advances through paragraphs and chapters without repeating or
    skipping text.
-   Audio interruption and headphone route changes are handled.
-   Large chapters are chunked safely.
-   Chinese punctuation and mixed-language text are tested.

### Downloads

-   Offline content opens in airplane mode.
-   Interrupted downloads are not marked complete.
-   Retrying a failed job does not duplicate chapters.
-   `Retry-After` is honored.
-   401/403/CAPTCHA/block responses pause the source rather than
    triggering evasion.
-   Disallowed sources cannot be enabled through a crafted configuration
    file.

### Data integrity

-   Unique source IDs prevent duplicate books/chapters.
-   Database migrations preserve existing reading progress.
-   Delete-book removes associated local content and jobs according to
    confirmation.
-   Backup can be restored in a clean installation.

### Chinese text pipeline

Use small **synthetic** HTML/TXT fixtures for each structural template
in §10A.1. Do not copy pages from real sites into the repository.

-   GB18030, Big5, and UTF-8 (with and without BOM) fixtures decode
    correctly; a mislabelled charset is recovered by the heuristic.
-   Mojibake fixtures (`锟斤拷`, Latin-1 artefacts) are flagged
    `garbled` and do not overwrite a good existing chapter.
-   Chinese-numeral table: 一, 十, 十二, 二十, 一百零五, 两千, 一万零一,
    〇, mixed digits.
-   TXT import splits chapters correctly, including 序章/番外/感言 and a
    leading untitled section.
-   The 最新章节 block is skipped; duplicate URLs produce one chapter;
    `desc` TOCs are reversed.
-   A three-page chapter merges into one; a failure on page 2 leaves
    the chapter incomplete.
-   Boilerplate lines and the repeated title are removed; story text and
    punctuation are byte-for-byte unchanged otherwise.
-   Placeholder bodies are flagged `placeholder`.

## 14. Implementation phases

### Phase 1 --- Local reader foundation

-   Create SwiftUI project and tab navigation.
-   Import EPUB/TXT through fileImporter.
-   TXT: encoding detection (UTF-8/GB18030/Big5) and chapter splitting
    (§10A.3, §10A.5).
-   Build reader view, typography settings, chapter navigation.
-   Add local persistence and recently-opened sorting.
-   Add progress save/restore.

### Phase 2 --- Text-to-speech

-   Add AVSpeechSynthesizer controls and voice/rate settings.
-   Implement paragraph chunking and chapter queue.
-   Handle interruptions and persist listening position.

### Phase 3 --- Offline library

-   Add download manager, storage status, cancel/retry, integrity
    checks.
-   Store content in app-managed files and metadata in SwiftData.
-   Add backup/export options where practical.

### Phase 4 --- Source framework

-   Implement source registry and permission review.
-   Define versioned safe rule schema and parser, including the §10A.2
    extensions.
-   Content cleaner, placeholder detection, multi-page chapter merging,
    and TOC dedupe (§10A.4, §10A.6).
-   Add one verified, permitted source adapter.
-   Add polite incremental refresh and task logs.

### Phase 5 --- Optional backend and sync

-   Add FastAPI/PostgreSQL only if multi-device sync or centralized
    crawling is needed.
-   Add authentication, API versioning, sync conflict handling,
    monitoring and backups.
-   Keep the app useful without the backend.

## 15. Instructions to Claude Code

Before coding: 1. Inspect the existing repository and report its
structure. 2. If the repository is empty, scaffold a native SwiftUI iOS
app; do not silently substitute a web app or React Native. 3. Write a
short implementation plan and identify assumptions. 4. Build in small
phases and keep the project compiling after each phase. 5. Start with
Phase 1; do not attempt all features at once. 6. Add tests for
persistence, sorting, and reading progress. 7. Use current stable Apple
APIs and verify availability against the project's deployment target. 8.
Do not invent working source adapters for websites that have not been
reviewed. 9. Do not implement anti-ban evasion, proxy rotation, CAPTCHA
bypass, paywall bypass. 10. Document setup,
build, test, and simulator steps in README.md. 11. If a capability
depends on Apple platform limitations, explain it and provide the
closest compliant implementation. 12. Ask before adding paid services,
external analytics, cloud storage, or transmitting reading data. 13. Put
the Chinese text pipeline in a pure-Swift module (e.g. a local Swift
package `TextPipeline`) with no UI dependencies: `EncodingDetector`,
`ChineseNumeral`, `ChapterTitleParser`, `ContentCleaner`,
`ChapterMerger`. Each is unit-tested with the §13
fixtures.

### Definition of done for the first milestone

A native iOS app can import a local TXT/EPUB file, display a bookshelf
sorted by most recently opened, open and read the book, save/restore the
reading position after relaunch, and speak the text using
AVSpeechSynthesizer. Source crawling and backend work come later.
