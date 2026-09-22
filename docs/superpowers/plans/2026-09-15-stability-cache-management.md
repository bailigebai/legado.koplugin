# Stability and Cache Management Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Prevent independent-reader settings actions from escaping into KOReader and provide bounded, configurable Legado cache cleanup.

**Architecture:** Keep the existing Presenter and CacheStore boundaries. Presenter wraps plugin-owned widget presentation and menu callbacks with the existing structured error path, preserving the Legado backdrop. CacheStore adds a bounded scan/eviction operation over its existing safe root validation; Settings persists three scalar limits and the settings UI exposes them.

**Tech Stack:** LuaJIT, KOReader widgets, existing Fs/LuaSettings/JSON test harness.

**Spec:** User request 2026-09-15: immersive settings stability and configurable cache management.

## Global Constraints

- No new dependencies.
- Default cache limit is 500 MiB; automatic cleanup starts above 300 MiB and retains 200 MiB.
- Cache cleanup must preserve active book data and refuse unsafe paths.
- UI errors must remain inside the plugin backdrop and never escape a KOReader callback.

### Task 1: Reproduce and contain immersive settings callbacks

**Files:**
- Modify: `legado.koplugin/legado/ui/presenter.lua`
- Modify: `legado.koplugin/legado/ui/leko_reader.lua`
- Test: `spec/phase3_presenter_overlay_spec.lua`
- Test: `spec/phase3/leko_reader_core_spec.lua`

- [ ] Add a regression assertion that the immersive reader settings action remains callable when the callback raises.
- [ ] Wrap plugin widget `show` and settings/menu callback execution at the shared Presenter boundary; report through `_info` while retaining the backdrop.
- [ ] Make Leko menu closing and action dispatch tolerant of a close/widget exception.
- [ ] Run the focused specs.

### Task 2: Add bounded cache accounting and eviction

**Files:**
- Modify: `legado.koplugin/legado/lib/cache_store.lua`
- Modify: `legado.koplugin/legado/lib/settings.lua`
- Modify: `legado.koplugin/legado/ui/settings.lua`
- Modify: `legado.koplugin/legado/ui/presenter.lua`
- Test: `spec/reading_cache_spec.lua`
- Test: `spec/atomic_reading_settings_spec.lua`

- [ ] Add defaults and validation for `cache_limit_mb`, `cache_cleanup_threshold_mb`, and `cache_retain_mb`.
- [ ] Add `CacheStore:usage()` and `CacheStore:enforceLimit(limit, threshold, retain, keep)` using the existing safe scan and oldest mtime order.
- [ ] Trigger bounded cleanup after successful body/html/cover writes; expose current usage, limit, threshold, and retain values in settings.
- [ ] Keep manual full cleanup and active-download guard behavior.
- [ ] Run focused cache/settings specs.

### Task 3: Release verification

**Files:**
- Modify: `docs/testing.md`
- Modify: `_meta.lua` or version metadata only if required by packaging rules.

- [ ] Run the full Lua/spec suite and KOReader compatibility checks.
- [ ] Rebuild a deterministic package and inspect root/entry count/hash.
- [ ] Report hardware Kindle acceptance separately.
