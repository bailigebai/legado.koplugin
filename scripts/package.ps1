param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$Version,
    [switch]$SkipTests
)

$ErrorActionPreference = "Stop"
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$python = Join-Path $repositoryRoot ".tools\python\python.exe"

if (-not $SkipTests) {
    & (Join-Path $PSScriptRoot "run-specs.ps1")
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

if (-not (Test-Path -LiteralPath $python -PathType Leaf)) {
    Write-Error "Test runtime is missing. Run scripts/bootstrap-tests.ps1 first."
    exit 1
}

$output = Join-Path $repositoryRoot ("dist\legado.koplugin-v{0}.zip" -f $Version)
& $python (Join-Path $PSScriptRoot "package_release.py") --repository-root $repositoryRoot --version $Version --output $output
exit $LASTEXITCODE
