#!/usr/bin/env python3
from __future__ import annotations

import argparse
import re
import tempfile
import zipfile
from pathlib import Path


BASELINE = "v2026.07.1"
EXPECTED_COMMIT = "9192014d8bd82a91dc1012473be0f238dedfdb54"
KNOWN_EXTERNAL = {
    "apps/filemanager/filemanager",
    "apps/reader/readerui", "bit", "datastorage", "device", "ffi", "ffi/archiver", "ffi/blitbuffer", "ffi/png", "ffi/loadlib", "ffi/sha2", "ffi/util",
    "json", "lfs", "libs/libkoreader-lfs", "ltn12", "lua-ljsqlite3/init", "luasettings", "socket", "socket.http",
    "ssl", "ssl.https",
    "document/documentregistry", "fontlist", "logger", "util",
}


def referenced_modules(plugin_root: Path) -> set[str]:
    patterns = (
        re.compile(r'\brequire\s*\(?\s*["\']([^"\']+)["\']'),
        re.compile(r'\bpcall\s*\(\s*require\s*,\s*["\']([^"\']+)["\']'),
        re.compile(r'\b(?:optional_require|optional|loaded)\s*\(\s*["\']([^"\']+)["\']'),
    )
    modules: set[str] = set()
    for path in plugin_root.rglob("*.lua"):
        text = path.read_text(encoding="utf-8")
        for pattern in patterns:
            modules.update(pattern.findall(text))
    return modules


def suffix_present(names: set[str], suffix: str) -> bool:
    suffix = suffix.replace("\\", "/").lower()
    return any(name.lower() == suffix or name.lower().endswith("/" + suffix) for name in names)


def source_names(source_root: Path) -> set[str]:
    return {path.relative_to(source_root).as_posix() for path in source_root.rglob("*") if path.is_file()}


def validate(plugin_root: Path, source_root: Path, archive_path: Path) -> list[str]:
    modules = referenced_modules(plugin_root)
    external = {module for module in modules if not module.startswith("legado.")}
    unknown = sorted(module for module in external if not module.startswith("ui/") and module not in KNOWN_EXTERNAL)
    if unknown:
        raise ValueError("unclassified external modules: " + ", ".join(unknown))
    ui_modules = sorted(module for module in modules if module == "datastorage" or module.startswith("ui/"))
    source = source_names(source_root)
    with zipfile.ZipFile(archive_path) as archive:
        release = {item.filename.replace("\\", "/") for item in archive.infolist() if not item.is_dir()}

    missing: list[str] = []
    for module in ui_modules:
        relative = module + ".lua"
        if not (suffix_present(source, "frontend/" + relative) or suffix_present(source, relative)):
            missing.append("source:" + module)
        if not (suffix_present(release, "frontend/" + relative) or suffix_present(release, relative)):
            missing.append("kindlehf:" + module)

    paired_modules = {
        "apps/filemanager/filemanager": ("frontend/apps/filemanager/filemanager.lua",),
        "apps/reader/readerui": ("frontend/apps/reader/readerui.lua",),
        "document/documentregistry": ("frontend/document/documentregistry.lua",),
        "fontlist": ("frontend/fontlist.lua",),
        "device": ("frontend/device.lua",),
        "logger": ("frontend/logger.lua",),
        "util": ("frontend/util.lua",),
        "ffi/archiver": ("base/ffi/archiver.lua", "ffi/archiver.lua"),
        "ffi/blitbuffer": ("base/ffi/blitbuffer.lua", "ffi/blitbuffer.lua"),
        "ffi/png": ("base/ffi/png.lua", "ffi/png.lua"),
    }
    for module, candidates in paired_modules.items():
        if module in external:
            if not any(suffix_present(source, candidate) for candidate in candidates):
                missing.append("source:" + module)
            release_candidates = tuple(candidate.removeprefix("base/") for candidate in candidates)
            if not any(suffix_present(release, candidate) for candidate in release_candidates):
                missing.append("kindlehf:" + module)

    runtime_groups = {
        "ffi/util": ("ffi/util.lua",),
        "ffi/loadlib": ("ffi/loadlib.lua",),
        "LuaSocket HTTP": ("socket/http.lua",),
        "LuaSocket core": ("socket/core.so", "socket/score.so", "socket/core.dll"),
        "LuaSec HTTPS": ("ssl/https.lua",),
        "LuaSec core": ("ssl.so", "ssl/core.so"),
        "Ltn12": ("ltn12.lua",),
        "SQLite": ("lua-ljsqlite3/init.lua",),
        "JSON": ("json.lua",),
        "Lua settings": ("luasettings.lua",),
        "LuaSocket entry": ("socket.lua",),
        "LuaJIT core": ("luajit",),
        "filesystem": ("libs/libkoreader-lfs.so", "lfs.so"),
        "ffi/sha2": ("ffi/sha2.lua",),
        "zlib": ("libs/libz.so.1",),
    }
    for label, alternatives in runtime_groups.items():
        if not any(suffix_present(release, item) for item in alternatives):
            missing.append("kindlehf:" + label)

    for relative, label in (
        ("legado/lib/archive_writer.lua", "self-contained archive writer"),
        ("legado/lib/subprocess_adapter.lua", "subprocess adapter"),
        ("legado/lib/socket_transport.lua", "socket transport"),
    ):
        if not (plugin_root / relative).is_file():
            missing.append("plugin:" + label)

    if missing:
        raise ValueError("missing compatibility modules: " + ", ".join(missing))
    return ui_modules


def self_test(plugin_root: Path) -> None:
    modules = referenced_modules(plugin_root)
    ui = sorted(module for module in modules if module == "datastorage" or module.startswith("ui/"))
    with tempfile.TemporaryDirectory(prefix="legado-koreader-check-") as temporary:
        root = Path(temporary)
        source = root / "source"
        source.mkdir()
        archive = root / "kindlehf.zip"
        entries = []
        for module in ui:
            relative = Path("frontend") / (module + ".lua")
            path = source / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("return {}", encoding="utf-8")
            entries.append("koreader/" + relative.as_posix())
        for relative in ("base/ffi/archiver.lua", "base/ffi/blitbuffer.lua", "base/ffi/png.lua", "frontend/apps/reader/readerui.lua", "frontend/apps/filemanager/filemanager.lua", "frontend/device.lua", "frontend/logger.lua", "frontend/document/documentregistry.lua", "frontend/fontlist.lua", "frontend/util.lua"):
            path = source / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("return {}", encoding="utf-8")
        entries.extend(("koreader/ffi/archiver.lua", "koreader/ffi/blitbuffer.lua", "koreader/ffi/png.lua", "koreader/frontend/apps/reader/readerui.lua", "koreader/frontend/apps/filemanager/filemanager.lua", "koreader/frontend/device.lua", "koreader/frontend/logger.lua", "koreader/frontend/document/documentregistry.lua", "koreader/frontend/fontlist.lua", "koreader/frontend/util.lua"))
        entries.extend(
            "koreader/" + item for item in (
                "ffi/util.lua", "ffi/loadlib.lua", "socket/http.lua", "socket/score.so",
                "ssl/https.lua", "ssl.so", "ltn12.lua", "lua-ljsqlite3/init.lua", "json.lua", "luasettings.lua",
                "socket.lua", "luajit", "libs/libkoreader-lfs.so", "libs/libz.so.1", "ffi/sha2.lua",
            )
        )
        with zipfile.ZipFile(archive, "w") as output:
            for name in entries:
                output.writestr(name, b"fixture")
        validate(plugin_root, source, archive)

        broken = root / "broken.zip"
        with zipfile.ZipFile(broken, "w") as output:
            for name in entries:
                if not name.endswith("ltn12.lua"):
                    output.writestr(name, b"fixture")
        try:
            validate(plugin_root, source, broken)
        except ValueError as error:
            if "Ltn12" not in str(error):
                raise AssertionError("missing module failure is not specific") from error
        else:
            raise AssertionError("checker accepted a kindlehf fixture without Ltn12")
        for missing_suffix, expected in (
            ("frontend/apps/filemanager/filemanager.lua", "kindlehf:apps/filemanager/filemanager"),
            ("ffi/archiver.lua", "kindlehf:ffi/archiver"),
            ("ffi/blitbuffer.lua", "kindlehf:ffi/blitbuffer"),
            ("libs/libz.so.1", "kindlehf:zlib"),
            ("apps/reader/readerui.lua", "kindlehf:apps/reader/readerui"),
            ("document/documentregistry.lua", "kindlehf:document/documentregistry"),
            ("frontend/fontlist.lua", "kindlehf:fontlist"),
            ("frontend/util.lua", "kindlehf:util"),
        ):
            broken = root / ("broken-" + missing_suffix.replace("/", "-") + ".zip")
            with zipfile.ZipFile(broken, "w") as output:
                for name in entries:
                    if not name.endswith(missing_suffix):
                        output.writestr(name, b"fixture")
            try:
                validate(plugin_root, source, broken)
            except ValueError as error:
                if expected not in str(error):
                    raise AssertionError(f"missing {missing_suffix} failure is not specific") from error
            else:
                raise AssertionError(f"checker accepted kindlehf fixture without {missing_suffix}")
    print("KOReader compatibility checker self-test passed.")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--plugin-root", type=Path)
    parser.add_argument("--source-root", type=Path)
    parser.add_argument("--kindlehf-archive", type=Path)
    parser.add_argument("--tag", default=BASELINE)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    repository_root = Path(__file__).resolve().parent.parent
    plugin_root = (args.plugin_root or repository_root / "legado.koplugin").resolve()
    if args.tag != BASELINE:
        raise SystemExit(f"unsupported compatibility baseline: {args.tag}")
    try:
        if args.self_test:
            self_test(plugin_root)
            return 0
        if not args.source_root or not args.kindlehf_archive:
            raise ValueError("source root and kindlehf archive are required")
        modules = validate(plugin_root, args.source_root.resolve(), args.kindlehf_archive.resolve())
    except (ValueError, zipfile.BadZipFile) as error:
        raise SystemExit(f"KOReader compatibility check failed: {error}")
    print(f"KOReader {BASELINE} compatibility check passed ({len(modules)} UI modules; FFI/archive/network/subprocess runtime verified).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
