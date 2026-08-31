from __future__ import annotations

import argparse
import hashlib
import shutil
import subprocess
import tempfile
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

    def verify_command(path: Path) -> list[str]:
        return [powershell, "-ExecutionPolicy", "Bypass", "-File", str(verify), "-Archive", str(path), "-Version", "0.1.0"]
    run(verify_command(artifact), True, "valid package verifies")

    with tempfile.TemporaryDirectory(prefix="legado-package-test-") as temporary:
        temporary_path = Path(temporary)
        forbidden = temporary_path / "forbidden.zip"
        rewrite(artifact, forbidden, lambda name, data: (name, data))
        with zipfile.ZipFile(forbidden, "a", zipfile.ZIP_DEFLATED) as changed:
            changed.writestr("legado.koplugin/spec/forbidden.lua", b"return true")
        run(verify_command(forbidden), False, "forbidden entry is rejected")

        mismatch = temporary_path / "mismatch.zip"
        def change_version(name: str, data: bytes):
            if name == "legado.koplugin/_meta.lua":
                data = data.replace(b'version = "0.1.0"', b'version = "9.9.9"')
            return name, data
        rewrite(artifact, mismatch, change_version)
        run(verify_command(mismatch), False, "version mismatch is rejected")

    print("Package behavior checks passed (reproducible, forbidden entry, version mismatch).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
