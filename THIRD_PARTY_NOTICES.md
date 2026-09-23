# Third-Party Notices

| Dependency | Exact source revision | License | Vendored runtime files |
| --- | --- | --- | --- |
| [msva/lua-htmlparser](https://github.com/msva/lua-htmlparser) | commit `5ce9a775a345cf458c0388d7288e246bb1b82bff` | LGPL-3.0 with the upstream iOS relinking exception | `legado.koplugin/legado/vendor/htmlparser/` |

The files `init.lua`, `ElementNode.lua`, and `voidelements.lua` come from
`src/htmlparser.lua`, `src/htmlparser/ElementNode.lua`, and
`src/htmlparser/voidelements.lua` at the exact revision above. The two local
`require` keys in `init.lua` are namespaced under `legado.vendor` so the
vendored module obeys the plugin's module namespace. Attribute parsing also
consumes whitespace around `=` and starts unquoted values immediately after
that separator, fixing valid links such as `href = /chapter/1`.
`ElementNode.lua` also has two trailing spaces removed;
this is a whitespace-only modification with no parser behavior change.

The upstream license notice and exception are reproduced verbatim in
`legado.koplugin/legado/vendor/htmlparser/LICENSE`. The complete GNU Lesser
General Public License version 3 terms referenced by that notice are included
alongside it in `legado.koplugin/legado/vendor/htmlparser/COPYING.LESSER`.

## Adapted reading statistics

`legado/lib/koreader_statistics.lua` adapts `Leko/KOReaderStatisticsBridge.lua`
from [jnjnnjzch/leko-reader](https://github.com/jnjnnjzch/leko-reader),
commit `57dff8958dd43a5d95cb2dac22ca363d874de29b` (v0.16.0),
AGPL-3.0-or-later. Local changes use Legado book identities, bound SQL,
schema checks, transaction rollback, a bounded retry queue and existing reading
lifecycle callbacks. The AGPL version 3 text is included in the root `LICENSE`;
the unchanged upstream license is also included at
`legado.koplugin/legado/vendor/licenses/leko-LICENSE`.
The distributed Lua files are the corresponding modified source; no compiled
Leko reader, JavaScript bridge or native binary is included.

## Adapted independent reader and page animation

The independent text reader adapts source from
[jnjnnjzch/leko-reader](https://github.com/jnjnnjzch/leko-reader),
commit `57dff8958dd43a5d95cb2dac22ca363d874de29b` (v0.16.0),
licensed AGPL-3.0-or-later. Upstream paths below are relative to its
`leko.koplugin/Leko/` directory; local paths are relative to this release's
`legado.koplugin/legado/` directory.

| Local modified source | Upstream source | Local changes |
| --- | --- | --- |
| `lib/leko_paginator.lua` | `Paginator.lua`, `ReaderMargins.lua` | Use the supplied chapter model and real font measurements; adapt header/footer space and margins; remove the upstream book-service dependency. |
| `lib/leko_text.lua` | UTF-8 window and position functions in `Util.lua` | Use the existing entity decoder and add bounded HTML-to-paragraph conversion; reject image chapters instead of dropping their images. |
| `ui/leko_reader.lua` | Reading layout and drawing in `ReaderView.lua` | Connect the existing session through callbacks; add background masks, incremental page indexing and separate per-book text styles. |
| `ui/leko_font_selection.lua` | `FontSelectionView.lua` | Namespace imports, localize style labels, preserve font paths/TTC face indices and adapt the return callback to KOReader's real `fontlist` module. |
| `lib/leko_native_swipe.lua` | `SwipeAnimation.lua` | Namespace the capability adapter and retain local, one-shot native swipe ownership. |
| `lib/leko_chapter_wave.lua` | `ChapterWaveRefresh.lua` | Namespace the chapter cleanup wave and retain its local cancellation and buffer ownership. |
| `lib/leko_animation.lua` | `SwipeRefresh.lua` | Coordinate reader-local original/wipe transitions and cancellation; adapt the strip algorithm identified below without global hooks or blocking sleeps. |

`lib/leko_reader_ui.lua` is this plugin's session adapter for the modified
reader. It connects construction, progress, style persistence and lifecycle
callbacks to the existing Legado session; it does not bundle another book
service, database, QuickJS engine, native binary or Android integration.

The strip-edge and wipe-reveal logic in `lib/leko_animation.lua` also adapts
`patches/2-swipe-animation-core.lua` from
[koplugin-swipe-animation/Swipe_Animation.koplugin](https://github.com/koplugin-swipe-animation/Swipe_Animation.koplugin),
commit `59dce480c38538976325f7ebc0831e36bc4c6ed4` (v4.3), under GPL version 3.
The upstream README credits original author `xhs:5699990012`, nuku, Echoes,
小红薯6809667F and 斯普特尼克的漫游. Local adaptation removes the upstream
global UIManager/Screen replacements and ReaderUI detection, and exposes
reader-local refresh mode and frame-delay settings.

The circular `ripple` reveal is a local extension, not an upstream effect.
It shares the aligned refresh regions, UI/Fast selection and orientation-specific
frame timing above, using the existing cancellable reader-local scheduler.

The two original license files are reproduced without modification at
`legado.koplugin/legado/vendor/licenses/leko-LICENSE` (AGPLv3) and
`legado.koplugin/legado/vendor/licenses/swipe-LICENSE` (GPLv3).
These upstream notices and terms are retained alongside the project's root
`LICENSE`. The distributed Lua files are the corresponding modified source;
the original standalone plugins and their global patches are not included.

## Reading and rule references

The standalone Lua plugin follows the projects below for native reading flows
and source rule formats. Their Android applications, account integrations,
JavaScript engines and service endpoints are not bundled in the release.

| Project | Reviewed revision | Upstream license | Referenced code and local implementation |
| --- | --- | --- | --- |
| [finlater/weread.koplugin](https://github.com/finlater/weread.koplugin) | `2943080c2493a1ae262cc97c74908ed62928c935` | AGPL-3.0 | `main.lua` menu registration and bookshelf/download initialization; `weread/lib/reader_lifecycle.lua` chapter completion, cached reading and prefetch lifecycle. Local equivalents: `main.lua`, `legado/ui/presenter.lua`, `legado/lib/reader_session.lua`, `legado/lib/koreader_reader_ui.lua`, `legado/lib/download_manager.lua`. |
| [wangyisll1/Legado_Max](https://github.com/wangyisll1/Legado_Max) | `cf9594db7eb342b4c8fd4431574e3858a13f3d7e` | GPL-3.0 | `app/src/main/java/io/legado/app/model/analyzeRule/AnalyzeByJSoup.kt` common default selectors; `app/src/main/java/io/legado/app/help/source/BookSourceExtensions.kt` static explore categories. Local equivalents: `legado/lib/rule_engine.lua` and `legado/lib/book_service.lua`. Only the documented Lua subset is implemented. |
| [koreader/koreader](https://github.com/koreader/koreader) | v2026.07.1, `9192014d8bd82a91dc1012473be0f238dedfdb54` | AGPL-3.0 | `frontend/ui/widget/menu.lua`, `frontend/ui/event.lua` and ReaderUI APIs are checked against the host's native menu and event contracts. The compatibility test loads the pinned upstream event module from the local tool cache; KOReader itself is not included. |
