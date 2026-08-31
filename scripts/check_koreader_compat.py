#!/usr/bin/env python3
from __future__ import annotations

import argparse
import re
import tempfile
import zipfile
from pathlib import Path


BASELINE = "v2026.07.1"


def referenced_modules(plugin_root: Path) -> set[str]:
    pattern = re.compile(r'(?:require|optional_require|optional|loaded)\s*\(?\s*["\']([^"\']+)["\']')
    modules: set[str] = set()
    for path in plugin_root.rglob("*.lua"):
        modules.update(pattern.findall(path.read_text(encoding="utf-8")))
    return modules


def suffix_present(names: set[str], suffix: str) -> bool:
    suffix = suffix.replace("\\", "/").lower()
    return any(name.lower() == suffix or name.lower().endswith("/" + suffix) for name in names)


def source_names(source_root: Path) -> set[str]:
    return {path.relative_to(source_root).as_posix() for path in source_root.rglob("*") if path.is_file()}


def validate(plugin_root: Path, source_root: Path, archive_path: Path) -> list[str]:
    modules = referenced_modules(plugin_root)
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

    runtime_groups = {
        "ffi/util": ("ffi/util.lua",),
        "ffi/loadlib": ("ffi/loadlib.lua",),
        "LuaSocket HTTP": ("socket/http.lua",),
        "LuaSocket core": ("socket/core.so", "socket/score.so", "socket/core.dll"),
        "LuaSec HTTPS": ("ssl/https.lua",),
        "LuaSec core": ("ssl.so", "ssl/core.so"),
        "Ltn12": ("ltn12.lua",),
        "SQLite": ("lua-ljsqlite3/init.lua",),
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
        entries.extend(
            "koreader/" + item for item in (
                "ffi/util.lua", "ffi/loadlib.lua", "socket/http.lua", "socket/score.so",
                "ssl/https.lua", "ssl.so", "ltn12.lua", "lua-ljsqlite3/init.lua",
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
