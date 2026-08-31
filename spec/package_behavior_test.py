from __future__ import annotations

import argparse
import hashlib
import stat
import shutil
import subprocess
import tempfile
import warnings
import zipfile
from pathlib import Path


def run(command: list[str], expect_success: bool, label: str) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if (result.returncode == 0) != expect_success:
        raise AssertionError(f"{label}: exit={result.returncode}\n{result.stdout}")
    return result


def rewrite(source: Path, destination: Path, mutate) -> None:
    with zipfile.ZipFile(source) as original, zipfile.ZipFile(destination, "w", zipfile.ZIP_DEFLATED) as changed:
        for info in original.infolist():
            name, data = info.filename, original.read(info)
            name, data = mutate(name, data)
            changed.writestr(name, data)


def clone(source: Path, destination: Path, additions: list[tuple[zipfile.ZipInfo | str, bytes]]) -> None:
    with zipfile.ZipFile(source) as original, zipfile.ZipFile(destination, "w", zipfile.ZIP_DEFLATED) as changed:
        for info in original.infolist():
            changed.writestr(info, original.read(info))
        for info, data in additions:
            with warnings.catch_warnings():
                warnings.filterwarnings("ignore", message="Duplicate name:.*", category=UserWarning)
                changed.writestr(info, data)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository-root", required=True, type=Path)
    args = parser.parse_args()
    root = args.repository_root.resolve()
    powershell = shutil.which("powershell") or "powershell"
    package = root / "scripts" / "package.ps1"
    verify = root / "scripts" / "verify-package.ps1"
    artifact = root / "dist" / "legado.koplugin-v0.1.0.zip"

    build = [powershell, "-ExecutionPolicy", "Bypass", "-File", str(package), "-Version", "0.1.0", "-SkipTests"]
    run(build, True, "package succeeds")
    first_hash = hashlib.sha256(artifact.read_bytes()).hexdigest()
    run(build, True, "package succeeds repeatedly")
    second_hash = hashlib.sha256(artifact.read_bytes()).hexdigest()
    if first_hash != second_hash:
        raise AssertionError("package output is not reproducible")

    accidental = root / "legado.koplugin" / "accidental.txt"
    accidental.write_text("must not enter release", encoding="utf-8")
    try:
        run(build, False, "builder rejects files outside the explicit allowlist")
    finally:
        accidental.unlink()
    run(build, True, "package recovers after an unexpected file is removed")
    accidental_directory = root / "legado.koplugin" / "legado" / "lib" / "unexpected"
    accidental_directory.mkdir()
    try:
        run(build, False, "builder rejects directories outside the explicit allowlist")
    finally:
        accidental_directory.rmdir()
    run(build, True, "package recovers after an unexpected directory is removed")
    sensitive_name = root / "legado.koplugin" / "legado" / "lib" / "secret.lua"
    sensitive_name.write_text("return {}", encoding="utf-8")
    try:
        run(build, False, "builder rejects credential-like names even inside an allowed directory")
    finally:
        sensitive_name.unlink()
    run(build, True, "package recovers after a credential-like file is removed")

    accepted_sources: list[str] = []
    extra_lua = root / "legado.koplugin" / "legado" / "lib" / "review_extra.lua"
    extra_lua.write_text("return {}", encoding="utf-8")
    try:
        result = subprocess.run(build, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if result.returncode == 0:
            accepted_sources.append("ordinary extra Lua")
    finally:
        extra_lua.unlink()

    decomposed = root / "legado.koplugin" / "legado" / "lib" / "revie\u0301w.lua"
    decomposed.write_text("return {}", encoding="utf-8")
    try:
        result = subprocess.run(build, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if result.returncode == 0:
            accepted_sources.append("decomposed Unicode filename")
    finally:
        decomposed.unlink()

    oversized = root / "legado.koplugin" / "legado" / "lib" / "diagnostics.lua"
    original_diagnostics = oversized.read_bytes()
    oversized.write_bytes(b"-- oversized source probe\n" + b" " * (9 * 1024 * 1024))
    try:
        result = subprocess.run(build, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if result.returncode == 0:
            accepted_sources.append("oversized manifest file")
    finally:
        oversized.write_bytes(original_diagnostics)
    if accepted_sources:
        raise AssertionError("builder accepted forbidden source entries: " + ", ".join(accepted_sources))
    run(build, True, "package recovers after source-boundary probes are removed")

    import sys
    sys.path.insert(0, str(root / "scripts"))
    from release_policy import ARCHIVE_FILES
    with zipfile.ZipFile(artifact) as archive:
        actual_names = {info.filename for info in archive.infolist()}
    if actual_names != ARCHIVE_FILES:
        raise AssertionError("valid package entries do not exactly match the reviewed release manifest")

    def verify_command(path: Path) -> list[str]:
        return [powershell, "-ExecutionPolicy", "Bypass", "-File", str(verify), "-Archive", str(path), "-Version", "0.1.0"]
    run(verify_command(artifact), True, "valid package verifies")

    with tempfile.TemporaryDirectory(prefix="legado-package-test-") as temporary:
        temporary_path = Path(temporary)
        attacks: list[tuple[str, list[tuple[zipfile.ZipInfo | str, bytes]]]] = [
            ("forbidden directory", [("legado.koplugin/spec/forbidden.lua", b"return true")]),
            ("ordinary extra Lua", [("legado.koplugin/legado/lib/review_extra.lua", b"return true")]),
            ("unexpected root file", [("legado.koplugin/notes.txt", b"notes")]),
            ("nested wrapper", [("wrapper/legado.koplugin/main.lua", b"return {}")]),
            ("nested plugin segment", [("legado.koplugin/docs/legado.koplugin/readme.md", b"nested")]),
            ("path traversal", [("legado.koplugin/docs/../main.lua", b"return {}")]),
            ("empty segment", [("legado.koplugin//main.lua", b"return {}")]),
            ("backslash", [("legado.koplugin\\main.lua", b"return {}")]),
            ("control character", [("legado.koplugin/docs/bad\x01.md", b"bad")]),
            ("case collision", [("legado.koplugin/readme.md", b"collision")]),
            ("unicode collision", [
                ("legado.koplugin/docs/\u00e9.md", b"one"),
                ("legado.koplugin/docs/e\u0301.md", b"two"),
            ]),
            ("directory entry", [("legado.koplugin/docs/", b"")]),
            ("compression bomb", [("legado.koplugin/docs/bomb.md", b"A" * (9 * 1024 * 1024))]),
            ("entry count", [(f"legado.koplugin/docs/extra-{index}.md", b"x") for index in range(300)]),
            ("sensitive text", [("legado.koplugin/docs/leak.md", b"-----BEGIN PRIVATE KEY-----")]),
        ]
        symlink = zipfile.ZipInfo("legado.koplugin/docs/link.md")
        symlink.create_system = 3
        symlink.external_attr = (stat.S_IFLNK | 0o777) << 16
        attacks.append(("symlink", [(symlink, b"../../outside")]))
        device = zipfile.ZipInfo("legado.koplugin/docs/device.md")
        device.create_system = 3
        device.external_attr = (stat.S_IFCHR | 0o600) << 16
        attacks.append(("device", [(device, b"")]))

        accepted = []
        for index, (label, additions) in enumerate(attacks):
            malicious = temporary_path / f"attack-{index}.zip"
            clone(artifact, malicious, additions)
            result = run(verify_command(malicious), False, label + " is rejected")
            if result.returncode == 0:
                accepted.append(label)

        duplicate = temporary_path / "duplicate.zip"
        clone(artifact, duplicate, [("legado.koplugin/README.md", b"duplicate")])
        run(verify_command(duplicate), False, "duplicate exact name is rejected")

        mismatch = temporary_path / "mismatch.zip"
        def change_version(name: str, data: bytes):
            if name == "legado.koplugin/_meta.lua":
                data = data.replace(b'version = "0.1.0"', b'version = "9.9.9"')
            return name, data
        rewrite(artifact, mismatch, change_version)
        run(verify_command(mismatch), False, "version mismatch is rejected")

        sensitive = temporary_path / "sensitive.zip"
        def add_sensitive_content(name: str, data: bytes):
            if name == "legado.koplugin/README.md":
                data += b"\n-----BEGIN PRIVATE KEY-----\n"
            return name, data
        rewrite(artifact, sensitive, add_sensitive_content)
        run(verify_command(sensitive), False, "sensitive content in an allowed entry is rejected")

    print("Package behavior checks passed (allowlist, reproducibility, malicious ZIPs, version mismatch).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
