# Legado Core Completion

Goal: Continue the existing standalone Kindle plugin using weread.koplugin's
native KOReader menu, bookshelf, cached-document reading, and download approach.
The user confirmed standalone Kindle operation and common source compatibility.
No phone service, JavaScript runtime, or Android bridge is required for this release.

References (read locally under .tools):
- weread.koplugin: 2943080c2493a1ae262cc97c74908ed62928c935
- Legado_Max: cf9594db7eb342b4c8fd4431574e3858a13f3d7e
- KOReader: v2026.07.1

Constraints: Preserve existing data, work only in this linked worktree, reuse
Lua/LuaJIT services and the existing parser, keep licenses, no device deployment.
Existing compatibility subsets remain explicit; do not claim all Max rules work.

1. [x] Native integration: register the plugin with the host menu; handle the
   real EndOfBook event and retain native final-document behavior. Cover these
   with runnable contract checks using the upstream event module.
2. [x] Source core: preserve HTML elements for search/catalog extraction;
   support common class/tag/id/chained selectors and object-shaped source rules.
   Exercise real imported JSON through the production rule engine and book service.
3. [x] Finding books: implement static exploreUrl categories and ruleExplore
   using the existing request/parser flow; expose discovery and search pagination,
   and report actual source import counts. Verify cancellation and malformed input.
4. [x] Delivery: run Lua specs, upstream compatibility and package checks;
   document supported rules and reference mapping; produce a new versioned ZIP.
   Physical Kindle screen, sleep, networking and third-party sources remain device checks.

File ownership: parser task owns rule_engine.lua, compatibility_scanner.lua and
its new specs. Controller owns main.lua, reader adapter, book_service.lua, UI,
release metadata and documentation. parseElements(input, rule, context) returns
element-preserving HTML strings for HTML/XPath, and objects for JSONPath; service
list extraction calls it, scalar extraction continues to call parse.

Verification baseline: 55 Lua spec files passed, 3218 assertions, before edits.

Completed verification: 60 Lua spec files, 3390 assertions; full run-specs,
pinned KOReader compatibility including real Event, sensitive-data scan and
65-entry version 0.2.0 package verification all passed. Review findings fixed.
Evidence and physical-device limitations: docs/acceptance-2026-09-08.md.
