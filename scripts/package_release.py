#!/usr/bin/env python3
from __future__ import annotations

import argparse
import re
import zipfile
from pathlib import Path

from release_policy import DOCUMENTS, TOP, collect_runtime, read_document


FIXED_TIME = (1980, 1, 1, 0, 0, 0)


def plugin_version(meta: bytes) -> str:
    match = re.search(rb'\bversion\s*=\s*["\']([^"\']+)["\']', meta)
    if not match:
        raise ValueError("_meta.lua does not declare a version")
    return match.group(1).decode("ascii")


def collect(root: Path) -> dict[str, bytes]:
    plugin = root / TOP
    entries = collect_runtime(plugin)
    for relative in DOCUMENTS:
        entries[f"{TOP}/{relative}"] = read_document(root, relative)
    return entries


def write_archive(entries: dict[str, bytes], output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_suffix(output.suffix + ".part")
    if temporary.exists():
        temporary.unlink()
    with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name in sorted(entries):
            info = zipfile.ZipInfo(name, FIXED_TIME)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.create_system = 3
            info.external_attr = 0o100644 << 16
            archive.writestr(info, entries[name])
    temporary.replace(output)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository-root", required=True, type=Path)
    parser.add_argument("--version", required=True)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    root = args.repository_root.resolve()
    entries = collect(root)
    actual = plugin_version(entries[f"{TOP}/_meta.lua"])
    if actual != args.version:
        raise SystemExit(f"version mismatch: requested {args.version}, _meta.lua declares {actual}")
    write_archive(entries, args.output.resolve())
    print(args.output.resolve())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
