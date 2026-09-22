#!/usr/bin/env python3
from __future__ import annotations

import argparse
import re
import subprocess
from pathlib import Path


PATTERNS = (
    re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
    re.compile(rb"AKIA[0-9A-Z]{16}"),
    re.compile(rb"gh[pousr]_[A-Za-z0-9]{30,}"),
    re.compile(rb"sk-[A-Za-z0-9_-]{32,}"),
    re.compile(rb"https?://[^/\s:@]+:[^/\s@]+@", re.IGNORECASE),
)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository-root", required=True, type=Path)
    args = parser.parse_args()
    root = args.repository_root.resolve()
    listed = subprocess.run(
        ["git", "-C", str(root), "ls-files", "-co", "--exclude-standard"],
        check=True, text=True, stdout=subprocess.PIPE,
    ).stdout.splitlines()
    violations = []
    checked = 0
    for relative in listed:
        path = root / relative
        release_scoped = relative.startswith("legado.koplugin/") or relative.startswith("docs/") or relative in {
            "README.md", "LICENSE", "THIRD_PARTY_NOTICES.md",
        }
        if not release_scoped or not path.is_file():
            continue
        checked += 1
        data = path.read_bytes()
        for pattern in PATTERNS:
            if pattern.search(data):
                violations.append(relative)
                break
    if violations:
        raise SystemExit("Sensitive-data scan failed: " + ", ".join(sorted(violations)))
    print(f"Sensitive-data scan passed ({checked} release-scoped files checked).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
