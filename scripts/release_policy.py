from __future__ import annotations

import os
import stat
from pathlib import Path, PurePosixPath


TOP = "legado.koplugin"
ROOT_RUNTIME = {"_meta.lua", "main.lua"}
VENDOR_RUNTIME = {
    "legado/vendor/htmlparser/init.lua",
    "legado/vendor/htmlparser/ElementNode.lua",
    "legado/vendor/htmlparser/voidelements.lua",
    "legado/vendor/htmlparser/LICENSE",
    "legado/vendor/htmlparser/COPYING.LESSER",
}
RUNTIME_DIRECTORIES = {
    "legado",
    "legado/lib",
    "legado/ui",
    "legado/vendor",
    "legado/vendor/htmlparser",
}
DOCUMENTS = (
    "README.md",
    "LICENSE",
    "THIRD_PARTY_NOTICES.md",
    "docs/rule-compatibility.md",
    "docs/privacy-and-copyright.md",
    "docs/testing.md",
    "docs/kpw6-checklist.md",
)
SENSITIVE_NAME_TOKENS = ("auth", "credential", "secret")


def sensitive_name(name: str) -> bool:
    folded = name.casefold()
    stem = PurePosixPath(folded).stem
    return stem == "env" or folded.startswith(".env") or any(token in folded for token in SENSITIVE_NAME_TOKENS)


def is_reparse(path: Path) -> bool:
    metadata = path.lstat()
    attributes = getattr(metadata, "st_file_attributes", 0)
    reparse_flag = getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400)
    return path.is_symlink() or bool(attributes & reparse_flag)


def is_allowed_runtime(relative: str) -> bool:
    path = PurePosixPath(relative)
    if sensitive_name(path.name):
        return False
    if relative in ROOT_RUNTIME or relative in VENDOR_RUNTIME:
        return True
    return len(path.parts) == 3 and path.parts[0] == "legado" and path.parts[1] in {"lib", "ui"} and path.suffix == ".lua"


def allowed_archive_name(name: str) -> bool:
    prefix = TOP + "/"
    if not name.startswith(prefix):
        return False
    relative = name[len(prefix):]
    return is_allowed_runtime(relative) or relative in DOCUMENTS


def collect_runtime(plugin_root: Path) -> dict[str, bytes]:
    if is_reparse(plugin_root) or not plugin_root.is_dir():
        raise ValueError("plugin root must be a real directory")
    files: dict[str, bytes] = {}
    for current, directory_names, file_names in os.walk(plugin_root, topdown=True, followlinks=False):
        current_path = Path(current)
        for name in list(directory_names):
            directory = current_path / name
            relative_directory = directory.relative_to(plugin_root).as_posix()
            if is_reparse(directory):
                raise ValueError(f"runtime reparse point is forbidden: {relative_directory}")
            if relative_directory not in RUNTIME_DIRECTORIES:
                raise ValueError(f"runtime directory is outside the release allowlist: {relative_directory}")
        for name in file_names:
            path = current_path / name
            relative = path.relative_to(plugin_root).as_posix()
            if is_reparse(path) or not stat.S_ISREG(path.lstat().st_mode):
                raise ValueError(f"runtime entry must be a regular file: {relative}")
            if not is_allowed_runtime(relative):
                raise ValueError(f"runtime entry is outside the release allowlist: {relative}")
            files[f"{TOP}/{relative}"] = path.read_bytes()
    required = {f"{TOP}/{item}" for item in ROOT_RUNTIME | VENDOR_RUNTIME}
    missing = required - files.keys()
    if missing:
        raise ValueError("required runtime files are missing: " + ", ".join(sorted(missing)))
    return files


def read_document(root: Path, relative: str) -> bytes:
    path = root / relative
    if is_reparse(path) or not path.is_file() or not stat.S_ISREG(path.lstat().st_mode):
        raise ValueError(f"release document must be a regular non-link file: {relative}")
    return path.read_bytes()
