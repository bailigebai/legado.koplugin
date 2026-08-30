$ErrorActionPreference = "Stop"

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$runtimeRoot = Join-Path $repositoryRoot "legado.koplugin"
$violations = @()

function Test-ProjectLocalLegacyModule {
    param([string]$ModuleName)

    if ($ModuleName -notmatch "^[A-Za-z0-9_./-]+$") {
        return $false
    }

    $modulePath = $ModuleName -replace "\\.", [System.IO.Path]::DirectorySeparatorChar
    $candidates = @(
        (Join-Path $runtimeRoot "$modulePath.lua"),
        (Join-Path $runtimeRoot "$modulePath\init.lua"),
        (Join-Path $runtimeRoot "legado\$modulePath.lua"),
        (Join-Path $runtimeRoot "legado\$modulePath\init.lua")
    )

    return [bool]($candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1)
}

Get-ChildItem -LiteralPath $runtimeRoot -Recurse -File -Filter *.lua | ForEach-Object {
    $file = $_
    $lineNumber = 0
    Get-Content -LiteralPath $file.FullName | ForEach-Object {
        $lineNumber += 1
        $line = $_
        $matches = [regex]::Matches($line, 'require\s*\(?\s*["'']([^"'']+)["'']')
        foreach ($match in $matches) {
            $moduleName = $match.Groups[1].Value
            $isLegadoModule = $moduleName -match "^legado\\."
            if (-not $isLegadoModule -and (Test-ProjectLocalLegacyModule $moduleName)) {
                $violations += "{0}:{1}: project-local legacy module key '{2}'" -f $file.FullName, $lineNumber, $moduleName
            }
        }
    }
}

if ($violations.Count -gt 0) {
    $violations | ForEach-Object { Write-Error $_ }
    exit 1
}

Write-Host "Namespace check passed."
