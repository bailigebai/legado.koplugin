$ErrorActionPreference = "Stop"

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$python = Join-Path $repositoryRoot ".tools\python\python.exe"
& $python (Join-Path $repositoryRoot "scripts\check_koreader_compat.py") --self-test
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $python (Join-Path $PSScriptRoot "koreader_compat_test.py")
exit $LASTEXITCODE
