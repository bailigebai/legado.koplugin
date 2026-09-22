#!/usr/bin/env python3
"""Run each Lua behavioral spec in an isolated LuaJIT 2.1 runtime."""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

try:
    from lupa.luajit21 import LuaError, LuaRuntime
except ImportError as error:
    raise SystemExit(
        "lupa.luajit21 is unavailable; run scripts/bootstrap-tests.ps1 first. "
        f"({error})"
    )


REPOSITORY_ROOT = Path(__file__).resolve().parent.parent
PLUGIN_ROOT = REPOSITORY_ROOT / "legado.koplugin"
SPEC_ROOT = REPOSITORY_ROOT / "spec"


def lua_string(value: str) -> str:
    return json.dumps(value.replace("\\", "/"))


def run_spec(spec_path: Path) -> int:
    runtime = LuaRuntime(unpack_returned_tuples=True)
    package_path = ";".join(
        [
            f"{PLUGIN_ROOT.as_posix()}/?.lua",
            f"{PLUGIN_ROOT.as_posix()}/?/init.lua",
            f"{SPEC_ROOT.as_posix()}/?.lua",
        ]
    )
    runtime.execute(
        f"package.path = {lua_string(package_path)} .. ';' .. package.path"
    )
    result = runtime.execute(f"return dofile({lua_string(str(spec_path))})")
    if not isinstance(result, (int, float)):
        raise RuntimeError("spec must return its assertion count as a number")
    return int(result)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--spec",
        action="append",
        help="run one spec path (relative to the repository root or absolute)",
    )
    arguments = parser.parse_args()

    os.environ["LEGADO_PLUGIN_ROOT"] = str(PLUGIN_ROOT)
    specs = (
        [
            (REPOSITORY_ROOT / item).resolve()
            if not Path(item).is_absolute()
            else Path(item)
            for item in arguments.spec
        ]
        if arguments.spec
        else sorted(SPEC_ROOT.rglob("*_spec.lua"))
    )
    if not specs:
        print("No Lua specs found.", file=sys.stderr)
        return 1

    passed = 0
    failed = 0
    assertions = 0
    for spec_path in specs:
        try:
            count = run_spec(spec_path)
        except (LuaError, OSError, RuntimeError) as error:
            failed += 1
            print(f"[FAIL] {spec_path.relative_to(REPOSITORY_ROOT)}: {error}")
        else:
            passed += 1
            assertions += count
            print(f"[PASS] {spec_path.relative_to(REPOSITORY_ROOT)} ({count} assertions)")

    print(f"Specs: {passed} passed, {failed} failed; Assertions: {assertions}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
