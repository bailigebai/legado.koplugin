$ErrorActionPreference = "Stop"
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$python = Join-Path $repositoryRoot ".tools\python\python.exe"
if (-not (Test-Path -LiteralPath $python -PathType Leaf)) {
    Write-Error "Test runtime is missing. Run scripts/bootstrap-tests.ps1 first."
    exit 1
}
& $python (Join-Path $PSScriptRoot "scan_sensitive.py") --repository-root $repositoryRoot
exit $LASTEXITCODE
