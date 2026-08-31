$ErrorActionPreference = "Stop"

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$python = Join-Path $repositoryRoot ".tools\python\python.exe"
& $python (Join-Path $repositoryRoot "scripts\check_koreader_compat.py") --self-test
exit $LASTEXITCODE
