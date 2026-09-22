"""Inspect an imported collection and sample live sources with the production Lua parser.

Transport/encoding use Python on the development PC, not Kindle LuaSocket/iconv.
No source JavaScript is executed. Reports omit response text and credentials.
"""

from __future__ import annotations

import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import socket
import time
import urllib.error
import urllib.parse
import urllib.request

from lupa.luajit21 import LuaRuntime

ROOT = Path(__file__).resolve().parent.parent


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args):
        return None


def safe_site(url: str) -> str:
    try:
        parsed = urllib.parse.urlsplit(url)
        return f"{parsed.scheme}://{parsed.hostname or ''}"
    except ValueError:
        return "invalid"


def public_url(url: str) -> str:
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme not in {"http", "https"} or not parsed.hostname or parsed.username or parsed.password:
        raise ValueError("invalid public HTTP URL")
    addresses = socket.getaddrinfo(parsed.hostname, parsed.port or (443 if parsed.scheme == "https" else 80))
    if not addresses or any(not ipaddress.ip_address(item[4][0]).is_global for item in addresses):
        raise ValueError("non-public address")
    return urllib.parse.quote(urllib.parse.urldefrag(url)[0], safe=":/?=&%+#;,@!$'()*[]~-._")


def has_credentials(source: dict) -> bool:
    header = source.get("header") or {}
    if isinstance(header, str):
        try:
            header = json.loads(header)
        except (ValueError, TypeError):
            return any(word in header.lower() for word in ("cookie", "authorization", "token", "api-key"))
    return isinstance(header, dict) and any(
        any(word in str(key).lower() for word in ("cookie", "authorization", "token", "api-key"))
        for key in header
    )


def read_response(response, sink, deadline):
    if isinstance(response, urllib.error.HTTPError):
        response = response.fp
    # urllib HTTP(S) wraps the socket here; read1 returns after one socket read.
    transport_socket = response.fp.raw._sock
    while not response.isclosed():
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("response deadline exceeded")
        transport_socket.settimeout(remaining)
        chunk = response.read1(65536)
        if not chunk:
            return True
        accepted = sink(chunk)
        if isinstance(accepted, tuple):
            accepted = accepted[0]
        if not accepted:
            return False
    return True


def successful_probe(live, *, reader_required=False, discovery=False):
    if live.get("status") != "completed" or any(step.get("status") not in {"passed", "success"} for step in live.get("steps", [])):
        return False
    if reader_required:
        document = live.get("sample", {}).get("reader_document", {})
        if document.get("status") != "passed" or document.get("format") != "html" or document.get("reader_entry") is not True:
            return False
    if discovery and (not live.get("detail_intro_bytes") or not live.get("detail_has_cover")
                      or not live.get("cover_image_signature")):
        return False
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-json", required=True, type=Path)
    parser.add_argument("--report", required=True, type=Path)
    parser.add_argument("--online", action="store_true")
    parser.add_argument("--indices", help="one-based comma-separated source indices")
    parser.add_argument("--limit", type=int, default=12)
    parser.add_argument("--keyword")
    parser.add_argument("--discovery", action="store_true", help="probe categories, first category page, details and one cover")
    parser.add_argument("--timeout", type=int, default=10)
    parser.add_argument("--max-requests", type=int, default=8, help="per-source request ceiling for multi-page catalogs, at most 160")
    parser.add_argument("--catalog-pages", type=int, help="limit catalog pages to exercise quick-start parsing")
    parser.add_argument("--catalog-chapters", type=int, help="limit initial chapter metadata, as in first-book startup")
    parser.add_argument("--reader-output-root", type=Path, help="write parsed chapter HTML through the production reader cache")
    parser.add_argument("--require-success", action="store_true", help="exit nonzero unless every selected online flow completes, including requested HTML or discovery metadata")
    args = parser.parse_args()
    if not 1 <= args.timeout <= 20 or not 1 <= args.limit <= 100:
        parser.error("timeout must be 1..20; limit must be 1..100")
    if not 1 <= args.max_requests <= 160 or (args.catalog_pages is not None and not 1 <= args.catalog_pages <= 64):
        parser.error("max-requests must be 1..160; catalog-pages must be 1..64")
    if args.catalog_chapters is not None and not 1 <= args.catalog_chapters <= 10000:
        parser.error("catalog-chapters must be 1..10000")
    if args.require_success and not args.online:
        parser.error("--require-success needs --online")
    if args.discovery and args.reader_output_root:
        parser.error("probe discovery and reader document output in separate runs")
    raw = args.source_json.read_bytes()
    collection = json.loads(raw.decode("utf-8-sig"))
    if not isinstance(collection, list):
        collection = [collection]
    by_url = {source["bookSourceUrl"].strip(): source for source in collection}
    lua = LuaRuntime(unpack_returned_tuples=True, encoding=None)
    module_path = ";".join((ROOT / "legado.koplugin" / suffix).as_posix() for suffix in ("?.lua", "?/init.lua"))
    lua.execute(b"package.path = " + json.dumps(module_path).encode() + b" .. ';' .. package.path")
    lua.globals()[b"probe_zlib_path"] = os.environ.get("LEGADO_ZLIB", "C:/Program Files/Git/mingw64/bin/zlib1.dll" if os.name == "nt" else "libz.so.1").encode()
    lua.execute(b'local ffi=require("ffi"); ffi.loadlib=function(name) assert(name=="z"); return ffi.load(probe_zlib_path) end')
    opener = urllib.request.build_opener(NoRedirect())
    requests = []
    budget_exhausted = False

    def fetch(request, sink):
        nonlocal budget_exhausted
        if len(requests) >= args.max_requests:
            budget_exhausted = True
            return None, b"probe request budget reached"
        url = request[b"url"].decode("utf-8")
        item = {"site": safe_site(url), "method": request[b"method"].decode("ascii")}
        requests.append(item)
        started = time.monotonic()
        deadline = started + float(request[b"timeout"])
        try:
            url = public_url(url)
            headers = {key.decode(): value.decode() for key, value in request[b"headers"].items()}
            headers.setdefault("User-Agent", "Mozilla/5.0 (compatible; KOReader-source-check)")
            headers["Accept-Encoding"] = "identity"
            operation = urllib.request.Request(url, data=request[b"body"], headers=headers, method=item["method"])
            try:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError("request deadline exceeded")
                response = opener.open(operation, timeout=remaining)
            except urllib.error.HTTPError as error:
                response = error
            with response:
                item["http_status"] = response.status
                item["content_type"] = response.headers.get("Content-Type", "")
                item["content_encoding"] = response.headers.get("Content-Encoding", "identity")
                response_headers = {}
                for name in response.headers:
                    values = response.headers.get_all(name)
                    response_headers[name.lower().encode()] = lua.table_from([v.encode() for v in values]) if name.lower() == "set-cookie" else values[-1].encode()
                if not read_response(response, sink, deadline):
                    return None, b"response limit reached"
                return lua.table_from({b"status": response.status, b"headers": lua.table_from(response_headers)}), None
        except Exception as error:
            item["transport_error"] = type(error).__name__
            if isinstance(error, urllib.error.URLError):
                item["transport_cause"] = type(error.reason).__name__
            return None, type(error).__name__.encode()
        finally:
            item["duration_ms"] = round((time.monotonic() - started) * 1000)

    def convert(value, source, target):
        try:
            return value.decode(source.decode()).encode(target.decode())
        except (UnicodeError, LookupError):
            return None, b"character conversion failed"

    reader_root = args.reader_output_root.resolve() if args.reader_output_root else None
    if reader_root:
        reader_root.mkdir(parents=True, exist_ok=True)

    def ensure_reader_paths(source_id, book_id):
        source = source_id.decode("ascii")
        book = book_id.decode("ascii")
        for kind in ("chapters", "html"):
            (reader_root / source / book / kind).mkdir(parents=True, exist_ok=True)

    probe = lua.execute((ROOT / "scripts" / "probe_sources.lua").read_bytes())[b"new"](
        raw, fetch, convert, time.monotonic, args.timeout,
        reader_root.as_posix().encode() if reader_root else None,
        ensure_reader_paths if reader_root else None, args.catalog_pages, args.catalog_chapters)
    inventory = json.loads(probe[b"inventory"]())
    status_counts = Counter(row["status"] for row in inventory)
    requested = {int(item) for item in args.indices.split(",")} if args.indices else None
    report = {"checked_at": datetime.now(timezone.utc).isoformat(),
              "collection_sha256": hashlib.sha256(raw).hexdigest(), "input_entries": len(collection),
              "imported_entries": len(inventory), "static_status_counts": dict(status_counts),
              "transport": "desktop urllib; production Lua RequestEngine normalization/response, parser and Diagnostics",
              "sources": []}
    tested = 0
    sites = set()
    for row in inventory:
        source = by_url[row["url"]]
        site = safe_site(row.pop("url"))
        row["site"] = site
        eligible = row["status"] != "unsupported" and row["enabled"] and not has_credentials(source)
        selected = row["index"] in requested if requested else eligible and site not in sites
        row["live"] = {"status": "not_tested"}
        if args.online and selected and tested < args.limit:
            if has_credentials(source):
                row["live"] = {"status": "skipped_credentials"}
            else:
                tested += 1
                sites.add(site)
                requests.clear()
                budget_exhausted = False
                check_rule = source.get("ruleSearch")
                keyword = args.keyword or (check_rule.get("checkKeyWord") if isinstance(check_rule, dict) else None) or "三国"
                try:
                    row["live"] = json.loads(probe[b"explore"](row["index"]) if args.discovery else probe[b"run"](row["index"], keyword.encode()))
                except Exception as error:
                    row["live"] = {"status": "probe_error", "error_type": type(error).__name__}
                row["live"]["requests"] = list(requests)
                if budget_exhausted:
                    row["live"]["status"] = "probe_limited"
                    row["live"]["probe_limit"] = f"{args.max_requests} HTTP requests per source"
                row["live"]["query"] = keyword
                failure = next((step for step in row["live"].get("steps", []) if step["status"] == "failed"), {})
                print(json.dumps({"index": row["index"], "site": site, "status": row["live"]["status"],
                                  "failed_step": failure.get("name"), "error": failure.get("error", {}).get("code")}), flush=True)
        report["sources"].append(row)
        # Incremental evidence survives an interrupted network batch.
        if args.online and row["live"]["status"] != "not_tested":
            args.report.parent.mkdir(parents=True, exist_ok=True)
            args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    if args.require_success:
        checked = [row["live"] for row in report["sources"] if row["live"]["status"] != "not_tested"]
        passed = sum(successful_probe(live, reader_required=reader_root is not None,
                                      discovery=args.discovery) for live in checked)
        report["validation"] = {"status": "passed" if checked and passed == len(checked) else "failed",
                                "passed": passed, "failed": len(checked) - passed}
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({"input_entries": len(collection), "imported_entries": len(inventory),
                      "static": dict(status_counts), "live_attempted": tested,
                      "validation": report.get("validation")}), flush=True)
    if args.require_success:
        return 0 if report["validation"]["status"] == "passed" else 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
