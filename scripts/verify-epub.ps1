param(
    [string]$Path,
    [switch]$SelfTest
)

$ErrorActionPreference = "Stop"
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$python = Join-Path $repositoryRoot ".tools\python\python.exe"
if (-not (Test-Path -LiteralPath $python -PathType Leaf)) {
    & (Join-Path $PSScriptRoot "bootstrap-tests.ps1")
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

$arguments = @((Join-Path $PSScriptRoot "verify_epub.py"), "--repository-root", $repositoryRoot)
if ($SelfTest) {
    $arguments += "--self-test"
} elseif ($Path) {
    $arguments += @("--path", (Resolve-Path -LiteralPath $Path).Path)
} else {
    Write-Error "Specify -Path or -SelfTest."
    exit 2
}

& $python $arguments
exit $LASTEXITCODE
