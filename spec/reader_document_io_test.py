#!/usr/bin/env python3
"""Exercise the website-to-KOReader document path with real filesystem I/O."""

from __future__ import annotations

import tempfile
from pathlib import Path

from lupa.luajit21 import LuaRuntime


ROOT = Path(__file__).resolve().parent.parent
PLUGIN = ROOT / "legado.koplugin"
SPEC = ROOT / "spec"


def lua_string(value: str) -> str:
    return repr(value.replace("\\", "/"))


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="legado-reader-") as temporary:
        cache_root = Path(temporary) / "cache"
        runtime = LuaRuntime(unpack_returned_tuples=True)
        runtime.execute(
            f"package.path = {lua_string(PLUGIN.as_posix() + '/?.lua;' + PLUGIN.as_posix() + '/?/init.lua;' + SPEC.as_posix() + '/?.lua;')} .. package.path"
        )
        runtime.globals().cache_root = cache_root.as_posix()
        runtime.globals().ensure_cache_paths = lambda source_id, book_id: (
            (cache_root / source_id / book_id / "chapters").mkdir(parents=True),
            (cache_root / source_id / book_id / "html").mkdir(parents=True),
        )
        document, pending_error, error_code, error_stage, exposed_cause = runtime.execute(
            r'''
            local Json = require("legado.lib.json_codec")
            local Safe = require("legado.lib.safe_functions")
            local Rules = require("legado.lib.rule_engine")
            local Service = require("legado.lib.book_service")
            local Templates = require("legado.lib.url_template")
            local Models = require("legado.lib.models")
            local Fs = require("legado.lib.fs")
            local CacheStore = require("legado.lib.cache_store")
            local ReaderSession = require("legado.lib.reader_session")

            local source = {
                id = "website-source",
                bookSourceUrl = "https://fiction.test/",
                ruleContent = { content = ".content p@text" },
            }
            local book = { id = "website-book", source_id = Models.sourceId(source), name = "Sample" }
            local chapter = {
                uid = "chapter-one", index = 1, title = "One",
                url = "https://fiction.test/chapter/1",
                source_id = book.source_id, book_id = book.id,
            }
            ensure_cache_paths(book.source_id, book.id)
            local rules = Rules.new({
                json_decoder = Json,
                html_parser = require("legado.vendor.htmlparser"),
                safe_functions = Safe.functions,
                url_resolver = Safe.resolve_url,
            })
            local request_callback
            local service = Service.new({
                storage = {}, rule_engine = rules,
                url_template = Templates.new({ rule_engine = rules }),
                request_engine = { execute = function(_, request, callback)
                    assert(request.url == chapter.url)
                    request_callback = function()
                        callback({
                            body = '<main class="content"><p>First paragraph.</p><p>Second paragraph.</p></main>',
                            status = 200, final_url = request.url,
                        })
                    end
                    return { cancel = function() return false end }
                end },
            })

            local html_path
            local session = ReaderSession.new({
                cache = CacheStore.new({ fs = Fs.new(), root = cache_root }),
                storage = { putProgress = function() return true end },
                service = service,
                settings = { get = function() return 0 end },
                ui = { openDocument = function(_, path, callbacks)
                    html_path = path
                    local opened = { getProgressFraction = function() return 0 end }
                    callbacks.ready(opened)
                    return opened
                end },
            })
            local completion_error
            local opened, err = session:open(source, book, { chapter }, 1, {
                on_complete = function(_, error_value) completion_error = error_value end,
            })
            assert(opened, err and (err.code .. ': ' .. err.message .. ' [' .. tostring(err.details and err.details.reason or '') .. ']'))
            local initial_error = err and err.code
            request_callback()
            assert(html_path, completion_error and Json.encode(completion_error))
            local file = assert(io.open(html_path, "rb"))
            local bytes = file:read("*a")
            file:close()

            local failed_session = ReaderSession.new({
                cache = CacheStore.new({ fs = Fs.new(), root = cache_root }),
                storage = { putProgress = function() return true end },
                settings = { get = function() return 0 end },
                ui = { openDocument = function()
                    error("https://user:secret@private.test")
                end },
            })
            local _, open_error = failed_session:open(source, book, { chapter }, 1)
            return bytes, initial_error, open_error and open_error.code,
                open_error and open_error.details and open_error.details.stage,
                open_error and open_error.details and open_error.details.cause
            '''
        )
        assert document.startswith("<!doctype html>"), (
            "KOReader received a JSON cache envelope instead of HTML: "
            + document[:80]
        )
        assert pending_error is None
        assert "<p>First paragraph.</p><p>Second paragraph.</p>" in document
        assert document.endswith("</body></html>")
        assert error_code == "STORAGE_ERROR"
        assert error_stage == "reader_open"
        assert exposed_cause is None
    print("[PASS] website extraction -> real HTML file -> reader entry")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
