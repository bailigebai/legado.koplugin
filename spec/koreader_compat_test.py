from __future__ import annotations

import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import check_koreader_compat as check  # noqa: E402


plugin = ROOT / "legado.koplugin"
modules = check.referenced_modules(plugin)
assert "ffi/archiver" in modules, "pcall(require, ...) must be parsed"
assert "apps/reader/readerui" in modules, "reader UI dependency must be parsed"
assert "fontlist" in modules, "independent font selector must use the real frontend/fontlist module"
assert check.EXPECTED_COMMIT == "9192014d8bd82a91dc1012473be0f238dedfdb54"

archive = ROOT / ".tools" / "koreader-kindlehf-v2026.07.1.zip"
with tempfile.TemporaryDirectory(prefix="legado-koreader-spec-") as temporary:
    source = Path(temporary)
    for module in sorted(item for item in modules if item == "datastorage" or item.startswith("ui/")):
        path = source / "frontend" / (module + ".lua")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("return {}", encoding="utf-8")
    try:
        check.validate(plugin, source, archive)
    except ValueError as error:
        message = str(error)
        assert "source:ffi/archiver" in message
        assert "source:apps/reader/readerui" in message
        assert "source:fontlist" in message
    else:
        raise AssertionError("checker accepted source fixture without archiver and reader UI")

print("KOReader compatibility parser and source-boundary tests passed.")
