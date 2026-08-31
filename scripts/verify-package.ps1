param(
    [Parameter(Mandatory = $true)]
    [string]$Archive,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$Version
)

$ErrorActionPreference = "Stop"
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$python = Join-Path $repositoryRoot ".tools\python\python.exe"
$archivePath = if ([System.IO.Path]::IsPathRooted($Archive)) { $Archive } else { Join-Path $repositoryRoot $Archive }

if (-not (Test-Path -LiteralPath $python -PathType Leaf)) {
    Write-Error "Test runtime is missing. Run scripts/bootstrap-tests.ps1 first."
    exit 1
}

$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("legado-package-verify-" + [System.Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
try {
    & $python (Join-Path $PSScriptRoot "verify_release.py") --archive $archivePath --version $Version --extract-root $temporaryRoot
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    & (Join-Path $PSScriptRoot "check-namespace.ps1") -RuntimeRoot (Join-Path $temporaryRoot "legado.koplugin")
    exit $LASTEXITCODE
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}
