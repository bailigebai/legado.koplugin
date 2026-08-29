$ErrorActionPreference = "Stop"

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$runtimeRoot = Join-Path $repositoryRoot "legado.koplugin"
$allowedExternalModules = @(
    "^ui/",
    "^ffi/",
    "^socket$",
    "^socket\\.",
    "^ssl$",
    "^ssl\\.",
    "^ltn12$",
    "^mime$",
    "^gettext$",
    "^logger$",
    "^json$",
    "^rapidjson$",
    "^lfs$",
    "^luasettings$"
)
$violations = @()

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
            $isExternal = $allowedExternalModules | Where-Object { $moduleName -match $_ }
            if (-not $isLegadoModule -and -not $isExternal) {
                $violations += "{0}:{1}: legacy or unapproved module key '{2}'" -f $file.FullName, $lineNumber, $moduleName
            }
        }
    }
}

if ($violations.Count -gt 0) {
    $violations | ForEach-Object { Write-Error $_ }
    exit 1
}

Write-Host "Namespace check passed."
