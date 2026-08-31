$ErrorActionPreference = "Stop"

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$python = Join-Path $repositoryRoot ".tools\python\python.exe"

& $python (Join-Path $PSScriptRoot "package_behavior_test.py") --repository-root $repositoryRoot
exit $LASTEXITCODE
