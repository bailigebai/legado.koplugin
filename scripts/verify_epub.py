#!/usr/bin/env python3
"""Verify an EPUB ZIP, with a self-test generated from production Lua entries."""

from __future__ import annotations

import argparse
import json
import posixpath
import tempfile
import zipfile
from pathlib import Path
from xml.etree import ElementTree


def verify_epub(path: Path) -> int:
    with zipfile.ZipFile(path, "r") as archive:
        entries = archive.infolist()
        if not entries or entries[0].filename != "mimetype":
            raise ValueError("mimetype must be the first ZIP entry")
        if entries[0].compress_type != zipfile.ZIP_STORED:
            raise ValueError("mimetype must be stored without compression")
        if archive.read("mimetype") != b"application/epub+zip":
            raise ValueError("invalid EPUB mimetype bytes")
        corrupt = archive.testzip()
        if corrupt:
            raise ValueError(f"corrupt ZIP entry: {corrupt}")
        names = [entry.filename for entry in entries]
        required = {
            "META-INF/container.xml",
            "META-INF/legado-source.json",
            "OEBPS/content.opf",
            "OEBPS/nav.xhtml",
            "OEBPS/intro.xhtml",
            "OEBPS/styles/structure.css",
        }
        missing = required.difference(names)
        if missing:
            raise ValueError(f"missing EPUB entries: {sorted(missing)}")
        if len(names) != len(set(names)):
            raise ValueError("duplicate EPUB entry names")

        for name in names:
            if name.endswith((".xml", ".xhtml")):
                xml_text = archive.read(name).decode("utf-8", errors="strict")
                try:
                    ElementTree.fromstring(xml_text)
                except ElementTree.ParseError as error:
                    raise ValueError(f"malformed XML/XHTML entry: {name}") from error

        container = ElementTree.fromstring(archive.read("META-INF/container.xml"))
        rootfile = container.find("{urn:oasis:names:tc:opendocument:xmlns:container}rootfiles/{urn:oasis:names:tc:opendocument:xmlns:container}rootfile")
        if rootfile is None or rootfile.attrib.get("full-path") != "OEBPS/content.opf":
            raise ValueError("container rootfile does not select OEBPS/content.opf")

        package = ElementTree.fromstring(archive.read("OEBPS/content.opf"))
        opf = "{http://www.idpf.org/2007/opf}"
        dc = "{http://purl.org/dc/elements/1.1/}"
        metadata = package.find(opf + "metadata")
        if metadata is None or metadata.find(dc + "identifier") is None or metadata.find(dc + "title") is None:
            raise ValueError("EPUB metadata is incomplete")
        manifest = package.find(opf + "manifest")
        spine = package.find(opf + "spine")
        if manifest is None or spine is None:
            raise ValueError("EPUB manifest or spine is missing")
        manifest_ids: dict[str, str] = {}
        for item in manifest.findall(opf + "item"):
            item_id, href = item.attrib.get("id"), item.attrib.get("href")
            if not item_id or not href:
                raise ValueError("manifest item lacks id or href")
            resolved = posixpath.normpath(posixpath.join("OEBPS", href))
            if resolved.startswith("../") or resolved not in names:
                raise ValueError(f"manifest target is missing or unsafe: {href}")
            manifest_ids[item_id] = resolved
        for itemref in spine.findall(opf + "itemref"):
            if itemref.attrib.get("idref") not in manifest_ids:
                raise ValueError("spine references an unknown manifest item")

        nav = ElementTree.fromstring(archive.read("OEBPS/nav.xhtml"))
        for link in nav.findall(".//{http://www.w3.org/1999/xhtml}a"):
            href = link.attrib.get("href")
            resolved = posixpath.normpath(posixpath.join("OEBPS", href or ""))
            if not href or resolved.startswith("../") or resolved not in names:
                raise ValueError(f"navigation target is missing or unsafe: {href}")

        source_manifest = json.loads(archive.read("META-INF/legado-source.json"))
        if set(source_manifest) != {"book", "chapter_count", "generated_by", "sources", "version"}:
            raise ValueError("source manifest exposes unexpected fields")
        archive_text = b"\n".join(archive.read(name) for name in names if not name.endswith((".jpg", ".png", ".gif")))
        for secret in (b"secret-token", b"secret-cookie", b"Authorization", b"user:pass"):
            if secret in archive_text:
                raise ValueError("source manifest or EPUB leaked credential material")
    return len(entries)


def production_entries(repository_root: Path):
    from lupa.luajit21 import LuaRuntime

    runtime = LuaRuntime(unpack_returned_tuples=True)
    plugin = (repository_root / "legado.koplugin").as_posix()
    package_path = f"{plugin}/?.lua;{plugin}/?/init.lua"
    runtime.execute(f"package.path = {json.dumps(package_path)} .. ';' .. package.path")
    module = runtime.eval('require("legado.lib.epub_builder")')
    if isinstance(module, tuple):
        module = module[0]
    book = runtime.table_from({
        "id": "synthetic-book",
        "source_id": "synthetic-source",
        "source_name": "合成书源",
        "name": "合成测试书",
        "author": "测试作者",
        "intro": "仅用于结构验证",
        "url": "https://user:pass@example.invalid/book?token=secret-token",
    })
    chapters = runtime.table_from([
        runtime.table_from({"uid": "synthetic-chapter-1", "index": 1, "title": "第一章", "vip": False}),
        runtime.table_from({"uid": "synthetic-chapter-2", "index": 2, "title": "第二章", "vip": False}),
    ])
    bodies = runtime.table_from({
        "synthetic-chapter-1": "<p>这是无版权的合成正文一。</p>",
        "synthetic-chapter-2": "<p>这是无版权的合成正文二。</p>",
    })
    assets = runtime.table_from({"modified": "2026-08-31T00:00:00Z"})
    result = module.buildEntries(book, chapters, bodies, assets)
    if isinstance(result, tuple):
        entries, error = result
        if entries is None:
            raise RuntimeError(f"Lua EPUB builder failed: {error}")
    else:
        entries = result
    output = []
    index = 1
    while entries[index] is not None:
        entry = entries[index]
        output.append({"path": entry["path"], "data": entry["data"], "compression": entry["compression"]})
        index += 1
    return output


def write_synthetic(path: Path, entries) -> None:
    with zipfile.ZipFile(path, "w") as archive:
        for entry in entries:
            info = zipfile.ZipInfo(entry["path"], date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_STORED if entry["compression"] == "store" else zipfile.ZIP_DEFLATED
            data = entry["data"]
            if isinstance(data, str):
                data = data.encode("utf-8")
            archive.writestr(info, data)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository-root", type=Path, required=True)
    parser.add_argument("--path", type=Path)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        with tempfile.TemporaryDirectory(prefix="legado-epub-") as directory:
            path = Path(directory) / "synthetic.epub"
            entries = production_entries(args.repository_root.resolve())
            write_synthetic(path, entries)
            count = verify_epub(path)
            malformed = [dict(entry) for entry in entries]
            for entry in malformed:
                if entry["path"].endswith("chapter-0001.xhtml"):
                    entry["data"] = "<html><body><p>broken</body></html>"
            malformed_path = Path(directory) / "malformed.epub"
            write_synthetic(malformed_path, malformed)
            try:
                verify_epub(malformed_path)
            except (ElementTree.ParseError, ValueError):
                pass
            else:
                raise RuntimeError("EPUB verifier accepted malformed chapter XHTML")
        print(f"Synthetic EPUB ZIP structure passed ({count} entries).")
        return 0
    if not args.path:
        parser.error("--path or --self-test is required")
    count = verify_epub(args.path.resolve())
    print(f"EPUB ZIP structure passed ({count} entries): {args.path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
