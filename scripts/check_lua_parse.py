#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path

from lupa.luajit21 import LuaRuntime


def quote(value: str) -> str:
    return '"' + value.replace("\\", "/").replace('"', '\\"') + '"'


root = Path(__file__).resolve().parent.parent
paths = sorted((root / "legado.koplugin").rglob("*.lua")) + sorted((root / "spec").rglob("*.lua"))
runtime = LuaRuntime(unpack_returned_tuples=True)
for path in paths:
    runtime.execute(f"assert(loadfile({quote(path.as_posix())}))")
print(f"LuaJIT parse check passed ({len(paths)} Lua files).")
