$ErrorActionPreference = "Stop"

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("legado-namespace-" + [guid]::NewGuid().ToString("N"))
$runtimeRoot = Join-Path $testRoot "legado.koplugin"
$scriptRoot = Join-Path $testRoot "scripts"

try {
    New-Item -ItemType Directory -Force -Path $runtimeRoot, $scriptRoot | Out-Null
    Copy-Item -LiteralPath (Join-Path $repositoryRoot "scripts\check-namespace.ps1") -Destination $scriptRoot

    @'
local device = require("device")
local data_storage = require("datastorage")
local util = require("util")
'@ | Set-Content -LiteralPath (Join-Path $runtimeRoot "main.lua") -NoNewline

    & powershell -ExecutionPolicy Bypass -File (Join-Path $scriptRoot "check-namespace.ps1")
    if ($LASTEXITCODE -ne 0) {
        throw "KOReader-owned device, datastorage, and util imports must be allowed."
    }

    @'
local legacy = require("oldservice")
'@ | Set-Content -LiteralPath (Join-Path $runtimeRoot "main.lua") -NoNewline
    New-Item -ItemType Directory -Force -Path (Join-Path $runtimeRoot "legado") | Out-Null
    Set-Content -LiteralPath (Join-Path $runtimeRoot "legado\oldservice.lua") -Value "return {}" -NoNewline

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $legacyOutput = & powershell -ExecutionPolicy Bypass -File (Join-Path $scriptRoot "check-namespace.ps1") 2>&1
    $legacyExitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousErrorActionPreference
    if ($legacyExitCode -eq 0) {
        throw "A project-local legacy module key must fail the namespace check."
    }
    if (($legacyOutput | Out-String) -notmatch "oldservice") {
        throw "Legacy module failure must identify the offending key."
    }

    Write-Host "Namespace checker behavior passed."
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        [System.IO.Directory]::Delete($testRoot, $true)
    }
}
