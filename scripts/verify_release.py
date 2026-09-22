#!/usr/bin/env python3
from __future__ import annotations

import argparse
import re
import stat
import tempfile
import zipfile
from pathlib import Path

from lupa.luajit21 import LuaError, LuaRuntime

from release_policy import MAX_COMPRESSION_RATIO, TOP, validate_entry_metadata, validate_payload


def lua_quote(value: str) -> str:
    return '"' + value.replace("\\", "/").replace('"', '\\"') + '"'


def declared_version(meta: bytes) -> str:
    match = re.search(rb'\bversion\s*=\s*["\']([^"\']+)["\']', meta)
    if not match:
        raise ValueError("_meta.lua has no version")
    return match.group(1).decode("ascii")


def validate_names(infos: list[zipfile.ZipInfo]) -> set[str]:
    for info in infos:
        name = info.filename
        if info.is_dir():
            raise ValueError(f"directory entries are forbidden: {name}")
        if info.create_system == 3:
            mode = info.external_attr >> 16
            if not stat.S_ISREG(mode):
                raise ValueError(f"non-regular Unix archive entry: {name}")
        if info.file_size and info.compress_size == 0:
            raise ValueError(f"invalid zero compressed size: {name}")
        if info.compress_size and info.file_size / info.compress_size > MAX_COMPRESSION_RATIO:
            raise ValueError(f"archive compression ratio exceeds limit: {name}")
    return set(validate_entry_metadata((info.filename, info.file_size) for info in infos))


def validate_content(archive: zipfile.ZipFile, names: set[str]) -> None:
    for name in names:
        validate_payload(name, archive.read(name))


def verify_lua(plugin_root: Path) -> None:
    runtime = LuaRuntime(unpack_returned_tuples=True)
    package_path = f"{plugin_root.as_posix()}/?.lua"
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
        validate_content(archive, names)
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
