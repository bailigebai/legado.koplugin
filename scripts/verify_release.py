#!/usr/bin/env python3
from __future__ import annotations

import argparse
import re
import stat
import tempfile
import unicodedata
import zipfile
from pathlib import Path, PurePosixPath

from lupa.luajit21 import LuaError, LuaRuntime

from release_policy import DOCUMENTS, TOP, allowed_archive_name


REQUIRED = {f"{TOP}/_meta.lua", f"{TOP}/main.lua", f"{TOP}/LICENSE", f"{TOP}/README.md"}
MAX_ENTRIES = 128
MAX_ENTRY_BYTES = 8 * 1024 * 1024
MAX_TOTAL_BYTES = 32 * 1024 * 1024
MAX_COMPRESSION_RATIO = 200
SENSITIVE_CONTENT = (
    re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
    re.compile(rb"AKIA[0-9A-Z]{16}"),
    re.compile(rb"gh[pousr]_[A-Za-z0-9]{30,}"),
    re.compile(rb"sk-[A-Za-z0-9_-]{32,}"),
    re.compile(rb"https?://[^/\s:@]+:[^/\s@]+@", re.IGNORECASE),
)


def lua_quote(value: str) -> str:
    return '"' + value.replace("\\", "/").replace('"', '\\"') + '"'


def declared_version(meta: bytes) -> str:
    match = re.search(rb'\bversion\s*=\s*["\']([^"\']+)["\']', meta)
    if not match:
        raise ValueError("_meta.lua has no version")
    return match.group(1).decode("ascii")


def validate_names(infos: list[zipfile.ZipInfo]) -> set[str]:
    if len(infos) > MAX_ENTRIES:
        raise ValueError(f"archive entry count exceeds {MAX_ENTRIES}")
    names: set[str] = set()
    normalized_names: set[str] = set()
    total_bytes = 0
    for info in infos:
        name = info.filename
        if not name or "\\" in name or name.startswith("/") or name.endswith("/"):
            raise ValueError(f"unsafe archive path: {name}")
        if any(ord(character) < 32 or ord(character) == 127 for character in name):
            raise ValueError(f"control character in archive path: {name!r}")
        segments = name.split("/")
        if any(segment in {"", ".", ".."} for segment in segments):
            raise ValueError(f"non-canonical archive path: {name}")
        path = PurePosixPath(name)
        if not path.parts or path.parts[0] != TOP:
            raise ValueError(f"archive must use one {TOP}/ top-level directory: {name}")
        if any(segment.casefold() == TOP.casefold() for segment in segments[1:]):
            raise ValueError(f"nested plugin wrapper is forbidden: {name}")
        canonical = unicodedata.normalize("NFC", name)
        folded = canonical.casefold()
        if canonical != name:
            raise ValueError(f"archive path is not Unicode NFC: {name!r}")
        if folded in normalized_names:
            raise ValueError(f"case/Unicode-normalized duplicate archive entry: {name}")
        normalized_names.add(folded)
        if name in names:
            raise ValueError(f"duplicate archive entry: {name}")
        if not allowed_archive_name(name):
            raise ValueError(f"archive entry is outside the release allowlist: {name}")
        if info.is_dir():
            raise ValueError(f"directory entries are forbidden: {name}")
        if info.create_system == 3:
            mode = info.external_attr >> 16
            if not stat.S_ISREG(mode):
                raise ValueError(f"non-regular Unix archive entry: {name}")
        if info.file_size < 0 or info.file_size > MAX_ENTRY_BYTES:
            raise ValueError(f"archive entry exceeds size limit: {name}")
        total_bytes += info.file_size
        if total_bytes > MAX_TOTAL_BYTES:
            raise ValueError("archive uncompressed size exceeds limit")
        if info.file_size and info.compress_size == 0:
            raise ValueError(f"invalid zero compressed size: {name}")
        if info.compress_size and info.file_size / info.compress_size > MAX_COMPRESSION_RATIO:
            raise ValueError(f"archive compression ratio exceeds limit: {name}")
        names.add(name)
    missing = REQUIRED - names
    if missing:
        raise ValueError("missing required archive entries: " + ", ".join(sorted(missing)))
    return names


def validate_content(archive: zipfile.ZipFile, names: set[str]) -> None:
    for name in names:
        relative = name[len(TOP) + 1:]
        textual = relative.endswith((".lua", ".md")) or relative in {"LICENSE"} or relative.endswith(("/LICENSE", "/COPYING.LESSER"))
        if not textual:
            continue
        data = archive.read(name)
        if any(pattern.search(data) for pattern in SENSITIVE_CONTENT):
            raise ValueError(f"sensitive credential material detected in: {name}")


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
