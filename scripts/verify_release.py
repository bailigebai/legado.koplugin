#!/usr/bin/env python3
from __future__ import annotations

import argparse
import re
import tempfile
import zipfile
from pathlib import Path, PurePosixPath

from lupa.luajit21 import LuaError, LuaRuntime


TOP = "legado.koplugin"
REQUIRED = {f"{TOP}/_meta.lua", f"{TOP}/main.lua", f"{TOP}/LICENSE", f"{TOP}/README.md"}
FORBIDDEN_SEGMENTS = {".tools", ".git", ".superpowers", "spec", "scripts", "tests", "credentials"}


def lua_quote(value: str) -> str:
    return '"' + value.replace("\\", "/").replace('"', '\\"') + '"'


def declared_version(meta: bytes) -> str:
    match = re.search(rb'\bversion\s*=\s*["\']([^"\']+)["\']', meta)
    if not match:
        raise ValueError("_meta.lua has no version")
    return match.group(1).decode("ascii")


def validate_names(infos: list[zipfile.ZipInfo]) -> set[str]:
    names: set[str] = set()
    for info in infos:
        name = info.filename
        if "\\" in name or name.startswith("/"):
            raise ValueError(f"unsafe archive path: {name}")
        path = PurePosixPath(name)
        if not path.parts or path.parts[0] != TOP or ".." in path.parts or "." in path.parts:
            raise ValueError(f"archive must use one {TOP}/ top-level directory: {name}")
        lowered = {part.lower() for part in path.parts}
        if lowered & FORBIDDEN_SEGMENTS:
            raise ValueError(f"forbidden archive entry: {name}")
        basename = path.name.lower()
        if basename.endswith(".json"):
            raise ValueError(f"book-source JSON is forbidden in release package: {name}")
        if any(token in basename for token in ("credential", "secret", ".env")):
            raise ValueError(f"credential-like file is forbidden in release package: {name}")
        if name in names:
            raise ValueError(f"duplicate archive entry: {name}")
        names.add(name)
    missing = REQUIRED - names
    if missing:
        raise ValueError("missing required archive entries: " + ", ".join(sorted(missing)))
    return names


def verify_lua(plugin_root: Path) -> None:
    runtime = LuaRuntime(unpack_returned_tuples=True)
    package_path = f"{plugin_root.as_posix()}/?.lua;{plugin_root.as_posix()}/?/init.lua"
    runtime.execute(f"package.path = {lua_quote(package_path)} .. ';' .. package.path")
    runtime.execute("""
        package.preload['ui/widget/container/widgetcontainer'] = function()
            local Widget = {}
            function Widget:extend(value)
                value.__index = value
                return setmetatable(value, { __index = self })
            end
            return Widget
        end
    """)
    for path in sorted(plugin_root.rglob("*.lua")):
        runtime.execute(f"assert(loadfile({lua_quote(path.as_posix())}))")
    plugin = runtime.execute(f"return dofile({lua_quote((plugin_root / 'main.lua').as_posix())})")
    if plugin is None:
        raise ValueError("main.lua did not return a plugin class")
    metadata = runtime.execute(f"return dofile({lua_quote((plugin_root / '_meta.lua').as_posix())})")
    if metadata is None:
        raise ValueError("_meta.lua did not return metadata")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--archive", required=True, type=Path)
    parser.add_argument("--version", required=True)
    parser.add_argument("--extract-root", type=Path)
    args = parser.parse_args()
    archive_path = args.archive.resolve()
    if not archive_path.is_file():
        raise SystemExit(f"archive does not exist: {archive_path}")
    with zipfile.ZipFile(archive_path) as archive:
        names = validate_names(archive.infolist())
        actual = declared_version(archive.read(f"{TOP}/_meta.lua"))
        if actual != args.version:
            raise ValueError(f"version mismatch: expected {args.version}, package declares {actual}")
        if args.extract_root:
            extract_root = args.extract_root.resolve()
            extract_root.mkdir(parents=True, exist_ok=True)
            archive.extractall(extract_root)
            verify_lua(extract_root / TOP)
        else:
            with tempfile.TemporaryDirectory(prefix="legado-verify-") as temporary:
                extract_root = Path(temporary)
                archive.extractall(extract_root)
                verify_lua(extract_root / TOP)
    print(f"Package verification passed: {len(names)} entries, version {args.version}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, zipfile.BadZipFile, LuaError) as error:
        raise SystemExit(f"Package verification failed: {error}")
