from __future__ import annotations

import os
import re
import stat
import unicodedata
from pathlib import Path, PurePosixPath


TOP = "legado.koplugin"
RUNTIME_FILES = frozenset({
    "_meta.lua",
    "main.lua",
    "legado/lib/archive_writer.lua",
    "legado/lib/book_service.lua",
    "legado/lib/cache_store.lua",
    "legado/lib/charset.lua",
    "legado/lib/compatibility_scanner.lua",
    "legado/lib/content_cleaner.lua",
    "legado/lib/cookie_jar.lua",
    "legado/lib/cover_loader.lua",
    "legado/lib/diagnostic_sanitizer.lua",
    "legado/lib/diagnostics.lua",
    "legado/lib/download_manager.lua",
    "legado/lib/epub_builder.lua",
    "legado/lib/errors.lua",
    "legado/lib/fs.lua",
    "legado/lib/iconv_adapter.lua",
    "legado/lib/identity.lua",
    "legado/lib/json_codec.lua",
    "legado/lib/koreader_reader_ui.lua",
    "legado/lib/logger.lua",
    "legado/lib/models.lua",
    "legado/lib/reader_session.lua",
    "legado/lib/request_engine.lua",
    "legado/lib/rule_capabilities.lua",
    "legado/lib/rule_engine.lua",
    "legado/lib/safe_functions.lua",
    "legado/lib/settings.lua",
    "legado/lib/socket_transport.lua",
    "legado/lib/source_importer.lua",
    "legado/lib/speech_provider.lua",
    "legado/lib/sqlite_backend.lua",
    "legado/lib/standby_guard.lua",
    "legado/lib/storage.lua",
    "legado/lib/subprocess_adapter.lua",
    "legado/lib/url_template.lua",
    "legado/lib/wire_codec.lua",
    "legado/lib/xhtml_serializer.lua",
    "legado/lib/xml_text.lua",
    "legado/ui/about.lua",
    "legado/ui/app.lua",
    "legado/ui/book_detail.lua",
    "legado/ui/bookshelf.lua",
    "legado/ui/bootstrap.lua",
    "legado/ui/catalog.lua",
    "legado/ui/compatibility_report.lua",
    "legado/ui/cover_grid.lua",
    "legado/ui/downloads.lua",
    "legado/ui/navigation.lua",
    "legado/ui/presenter.lua",
    "legado/ui/search.lua",
    "legado/ui/settings.lua",
    "legado/ui/source_manager.lua",
    "legado/vendor/htmlparser/init.lua",
    "legado/vendor/htmlparser/ElementNode.lua",
    "legado/vendor/htmlparser/voidelements.lua",
    "legado/vendor/htmlparser/LICENSE",
    "legado/vendor/htmlparser/COPYING.LESSER",
})
DOCUMENTS = frozenset({
    "README.md",
    "LICENSE",
    "THIRD_PARTY_NOTICES.md",
    "docs/rule-compatibility.md",
    "docs/privacy-and-copyright.md",
    "docs/testing.md",
    "docs/kpw6-checklist.md",
})
ARCHIVE_FILES = frozenset(f"{TOP}/{relative}" for relative in RUNTIME_FILES | DOCUMENTS)
RUNTIME_DIRECTORIES = frozenset(
    parent.as_posix()
    for relative in RUNTIME_FILES
    for parent in PurePosixPath(relative).parents
    if parent.as_posix() != "."
)
MAX_ENTRIES = 128
MAX_ENTRY_BYTES = 8 * 1024 * 1024
MAX_TOTAL_BYTES = 32 * 1024 * 1024
MAX_COMPRESSION_RATIO = 200
SENSITIVE_NAME_TOKENS = ("auth", "credential", "secret")
SENSITIVE_CONTENT = (
    re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
    re.compile(rb"AKIA[0-9A-Z]{16}"),
    re.compile(rb"gh[pousr]_[A-Za-z0-9]{30,}"),
    re.compile(rb"sk-[A-Za-z0-9_-]{32,}"),
    re.compile(rb"https?://[^/\s:@]+:[^/\s@]+@", re.IGNORECASE),
)


def sensitive_name(name: str) -> bool:
    folded = name.casefold()
    stem = PurePosixPath(folded).stem
    return stem == "env" or folded.startswith(".env") or any(token in folded for token in SENSITIVE_NAME_TOKENS)


def validate_canonical_name(name: str) -> str:
    if not isinstance(name, str) or not name or "\\" in name or name.startswith("/") or name.endswith("/"):
        raise ValueError(f"unsafe archive path: {name!r}")
    if unicodedata.normalize("NFC", name) != name:
        raise ValueError(f"archive path is not Unicode NFC: {name!r}")
    if any(unicodedata.category(character).startswith("C") for character in name):
        raise ValueError(f"control character in archive path: {name!r}")
    segments = name.split("/")
    if any(segment in {"", ".", ".."} for segment in segments):
        raise ValueError(f"non-canonical archive path: {name}")
    if segments[0] != TOP:
        raise ValueError(f"archive must use one {TOP}/ top-level directory: {name}")
    if any(segment.casefold() == TOP.casefold() for segment in segments[1:]):
        raise ValueError(f"nested plugin wrapper is forbidden: {name}")
    return name


def validate_entry_size(name: str, size: int) -> None:
    if not isinstance(size, int) or isinstance(size, bool) or size < 0 or size > MAX_ENTRY_BYTES:
        raise ValueError(f"archive entry exceeds size limit: {name}")


def validate_entry_metadata(entries) -> frozenset[str]:
    items = list(entries)
    if len(items) > MAX_ENTRIES:
        raise ValueError(f"archive entry count exceeds {MAX_ENTRIES}")
    names: set[str] = set()
    folded_names: set[str] = set()
    total_bytes = 0
    for name, size in items:
        validate_canonical_name(name)
        folded = name.casefold()
        if name in names:
            raise ValueError(f"duplicate archive entry: {name}")
        if folded in folded_names:
            raise ValueError(f"case/Unicode-normalized duplicate archive entry: {name}")
        if sensitive_name(PurePosixPath(name).name):
            raise ValueError(f"credential-like archive entry is forbidden: {name}")
        validate_entry_size(name, size)
        names.add(name)
        folded_names.add(folded)
        total_bytes += size
        if total_bytes > MAX_TOTAL_BYTES:
            raise ValueError("archive uncompressed size exceeds limit")
    missing = ARCHIVE_FILES - names
    unexpected = names - ARCHIVE_FILES
    if missing or unexpected:
        details = []
        if missing:
            details.append("missing: " + ", ".join(sorted(missing)))
        if unexpected:
            details.append("unexpected: " + ", ".join(sorted(unexpected)))
        raise ValueError("archive entries do not match the release manifest (" + "; ".join(details) + ")")
    return frozenset(names)


def validate_payload(name: str, data: bytes) -> None:
    if not isinstance(data, bytes):
        raise ValueError(f"archive payload must be bytes: {name}")
    validate_entry_size(name, len(data))
    relative = name[len(TOP) + 1:]
    textual = relative.endswith((".lua", ".md")) or relative in {"LICENSE"} or relative.endswith(("/LICENSE", "/COPYING.LESSER"))
    if textual and any(pattern.search(data) for pattern in SENSITIVE_CONTENT):
        raise ValueError(f"sensitive credential material detected in: {name}")


def validate_release_entries(entries: dict[str, bytes]) -> None:
    names = validate_entry_metadata((name, len(data)) for name, data in entries.items())
    for name in names:
        validate_payload(name, entries[name])


def allowed_archive_name(name: str) -> bool:
    return name in ARCHIVE_FILES


def is_reparse(path: Path) -> bool:
    metadata = path.lstat()
    attributes = getattr(metadata, "st_file_attributes", 0)
    reparse_flag = getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400)
    return path.is_symlink() or bool(attributes & reparse_flag)


def collect_runtime(plugin_root: Path) -> dict[str, bytes]:
    if is_reparse(plugin_root) or not plugin_root.is_dir():
        raise ValueError("plugin root must be a real directory")
    files: dict[str, bytes] = {}
    for current, directory_names, file_names in os.walk(plugin_root, topdown=True, followlinks=False):
        current_path = Path(current)
        for name in list(directory_names):
            directory = current_path / name
            relative_directory = directory.relative_to(plugin_root).as_posix()
            validate_canonical_name(f"{TOP}/{relative_directory}")
            if is_reparse(directory):
                raise ValueError(f"runtime reparse point is forbidden: {relative_directory}")
            if relative_directory not in RUNTIME_DIRECTORIES:
                raise ValueError(f"runtime directory is outside the release allowlist: {relative_directory}")
        for name in file_names:
            path = current_path / name
            relative = path.relative_to(plugin_root).as_posix()
            archive_name = validate_canonical_name(f"{TOP}/{relative}")
            metadata = path.lstat()
            if is_reparse(path) or not stat.S_ISREG(metadata.st_mode):
                raise ValueError(f"runtime entry must be a regular file: {relative}")
            if relative not in RUNTIME_FILES:
                raise ValueError(f"runtime entry is outside the release manifest: {relative}")
            validate_entry_size(archive_name, metadata.st_size)
            files[archive_name] = path.read_bytes()
    expected = {f"{TOP}/{item}" for item in RUNTIME_FILES}
    missing = expected - files.keys()
    if missing:
        raise ValueError("required runtime files are missing: " + ", ".join(sorted(missing)))
    return files


def read_document(root: Path, relative: str) -> bytes:
    path = root / relative
    archive_name = validate_canonical_name(f"{TOP}/{relative}")
    metadata = path.lstat()
    if is_reparse(path) or not path.is_file() or not stat.S_ISREG(metadata.st_mode):
        raise ValueError(f"release document must be a regular non-link file: {relative}")
    validate_entry_size(archive_name, metadata.st_size)
    return path.read_bytes()
