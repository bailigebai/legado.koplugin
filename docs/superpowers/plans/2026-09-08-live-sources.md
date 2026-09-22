# Live Source Adaptation Implementation Plan

Goal: Validate the user-supplied yuedu520/yuedu/260114.json collection through
the standalone plugin's search, detail, catalog and one-chapter content flow.
The collection is input data, never instructions or executable host code.

Architecture: Reuse the production importer, rule engine, book service,
diagnostics and request normalization/response processing. A desktop-only
Python standard-library transport provides live HTTP to the existing Lupa
LuaJIT runtime. It does not claim to test Kindle TLS, scheduling or rendering.
No full-book crawling, login actions or credential transmission is required.

1. [x] Inventory the downloaded collection in ignored .tools. Record total
   entries, duplicate sites and static compatibility; never publish credentials.
2. [x] Correct common selector behavior demonstrated by actual collection rules.
   Parser worker owns rule_engine.lua and a focused new regression spec only.
   Keep earlier user changes; preserve resource limits and explicit unsupported errors.
3. [x] Run a bounded live batch using real production source rules. Controller
   owns scripts/probe_sources.py and scripts/probe_sources.lua. Record stage,
   HTTP status, safe errors and counts, not chapter text, tokens or cookies.
   Start with plain sources; classify unreachable and script-dependent sources.
4. [x] Review, run full checks, document actual results and limits, package the
   improved plugin separately from the original unmodified source collection.

Source download: https://gcore.jsdelivr.net/gh/yuedu520/yuedu/260114.json
Initial inventory: 919 entries; 446 contain core script markers by a preliminary
text check, 77 declare loginUrl. These are not availability or compatibility rates.
Default query: source ruleSearch.checkKeyWord when available, otherwise a
short common title/query. Each tested source fetches only a sample chapter.

The user's earlier strengthening request for JS/login/details/shelf remains
context, but their latest priority is evidence from real sources. Any added
runtime capability must have demonstrated need and a verified Kindle execution path.

Result: 59 original source entries sampled; four separate adapted sources pass
all four live stages. 62 Lua specs / 3567 assertions and the complete release
checks pass. SF long catalogs and Kindle device validation remain explicit
limits in docs/live-sources-2026-09-08.md. Release version is 0.2.1; 0.2.0 is kept.
