# Kindle KOReader Legado Plugin Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Follow strict TDD and commit each task.

**Goal:** Build `legado.koplugin` v0.1.0 for KPW6 with safe Legado source compatibility, bookshelf, online/offline reading, and complete EPUB downloads.

**Architecture:** A thin KOReader plugin entry point composes focused Lua services for importing sources, executing safe rules, networking, persistence, reading, caching, downloads, and UI. SQLite stores metadata with a Lua-file fallback; content and EPUB files use atomic filesystem writes.

**Tech Stack:** Lua 5.1/LuaJIT 2.1, KOReader stable plugin APIs, LuaSocket/LuaSec/Ltn12, lua-ljsqlite3, ffi/archive, Lupa 2.8 luajit21 test harness, PowerShell packaging scripts.

**Spec:** `docs/superpowers/specs/2026-08-29-legado-koplugin-design.md`

## Global Constraints

- Plugin directory and module namespace: `legado.koplugin` and `legado.*`.
- Release version: `0.1.0`.
- Target: KPW6, Kindle firmware 5.19.5, KOReader v2026.07.1 and later.
- Pure Lua plugin runtime; no additional Kindle executable or remote companion service.
- Never execute `@js:`, `<js>`, WebView, login UI, Android, or Java API code.
- Do not bundle or recommend book sources or copyrighted book content.
- Reading appearance remains controlled by KOReader; generated HTML/EPUB must not hard-code fonts, colors, or backgrounds.
- Defaults: timeout 20 seconds, response 4 MiB, redirects 5, concurrency 2 (maximum 3), pagination 20, prefetch 3 (range 0-10), shelf page 20.
- AGPL-3.0 project license; retain licenses for vendored dependencies.
- Preserve and ignore `.dotnet-sdk-10.0.302/`; test tools live in ignored `.tools/`.

---

### Task 1: Project Skeleton and Test Harness

Create the KOReader plugin entry point, metadata, module directories, license and third-party notices. Add PowerShell scripts that install Lupa 2.8 under `.tools/`, execute specs with `lupa.luajit21`, check namespaces, and smoke-load the plugin using KOReader service fakes. Follow RED/GREEN and commit `chore: scaffold legado koreader plugin`.

### Task 2: Settings, Errors, and Persistence

Implement versioned settings, structured error values, redacting logger, safe directory creation, atomic file writes, and a storage facade backed by `lua-ljsqlite3/init` with Lua-file fallback. Persist sources, books, chapters, progress, and download tasks. Test missing SQLite, corrupt fallback, failed migration, atomic replacement, and restart recovery. Commit `feat: add versioned storage and settings`.

### Task 3: Source Import and Compatibility Scan

Implement `SourceImporter:importJson(text, origin)` for one source or arrays up to 5 MiB, preserving enabled state by `bookSourceUrl`; support local and remote origins and retain update origin metadata. Implement `CompatibilityScanner:scan(source)` returning `usable`, `partial`, or `unsupported` with field-level issues. Test duplicates, malformed/oversize JSON, HTTP warnings, and JS/WebView/Java detection. Commit `feat: import and validate legado sources`.

### Task 4: Safe Rule Engine

Vendor `lua-htmlparser` commit `5ce9a775a345cf458c0388d7288e246bb1b82bff` with LGPL notice. Implement `RuleEngine:parse(input, rule, context, want_list)` supporting the approved CSS selectors and value extractors, JSONPath fields/arrays/wildcards/simple filters, XPath descendant/attribute/text/position predicates, `&&`, `||`, `##`, `{{...}}`, and safe encoding/string/hash functions. Return `UNSUPPORTED_RULE` for executable constructs. Use synthetic fixtures and strict TDD. Commit `feat: add safe legado rule engine`.

### Task 5: Request and Charset Engine

Implement cancellable callback-based requests using KOReader LuaSocket/LuaSec/Ltn12 and `ffi/util` subprocesses with a scheduled synchronous fallback. Support GET, POST, JSON/form bodies, headers, source-scoped cookies, redirects, relative URLs, charset detection, and iconv GBK/GB18030 conversion. Enforce all network limits and redact credentials. Test timeout, cancellation, redirect, cookies, oversize response, encoding failure, and fallback. Commit `feat: add cancellable source request engine`.

### Task 6: Book Services and Core UI

Implement `BookService:search`, `getBookInfo`, `getChapters`, and `getContent` with normalized Book/Chapter models and source failure isolation. Add main menu, source manager, search, details, catalog, paginated list/cover shelf, downloads, settings, about, and physical-key focus navigation. Aggregate identical search results while preserving source choices. Test empty/partial/error flows and navigation. Commit `feat: add bookshelf and source search ui`.

### Task 7: Online Reading, Cache, and Progress

Generate semantic chapter HTML atomically, open through KOReader, save/restore chapter-fraction progress, handle guarded end-of-chapter navigation, prefetch 0-10 chapters, isolate caches by source, and recover position after catalog insertions using URL then title/neighbor fallback. Test offline reading, cache corruption, re-entry guards, document isolation, and progress persistence. Commit `feat: add chapter reading and offline cache`.

### Task 8: Complete EPUB and Download Manager

Implement a single resumable download queue, cancellation/retry, standby guard, and EPUB 3 generation through `ffi/archive`. Include cover, metadata, introduction, navigation, per-chapter XHTML, and source manifest. Write `.part` and publish only when every chapter succeeds; retain usable chapter cache on failure. Test EPUB entries/order/escaping, cancellation, resume, partial failure, replacement, and standby restoration. Commit `feat: download and build complete epub books`.

### Task 9: Diagnostics, Speech Stub, Docs, and Package

Implement four-step per-source diagnostics and compatibility display. Add the fixed no-op `SpeechProvider` interface and unavailable UI. Finish Chinese README, compatibility/privacy/copyright docs, KPW6 manual checklist, packaging and ZIP verification scripts. Produce `dist/legado.koplugin-v0.1.0.zip` whose top level is `legado.koplugin/`. Run all verification and commit `docs: document and package v0.1.0`.

