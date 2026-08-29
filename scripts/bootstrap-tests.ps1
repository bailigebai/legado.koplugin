$ErrorActionPreference = "Stop"

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$toolsRoot = Join-Path $repositoryRoot ".tools"
$venvRoot = Join-Path $toolsRoot "python"
$venvPython = Join-Path $venvRoot "python.exe"
$bundledCodexPython = "C:\Users\98199\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe"

function Invoke-Python {
    param([string]$Executable, [string[]]$Arguments)

    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Python command failed with exit code ${LASTEXITCODE}: $Executable $($Arguments -join ' ')"
    }
}

function Get-CurrentPython {
    if ($env:CODEX_BUNDLED_PYTHON -and (Test-Path -LiteralPath $env:CODEX_BUNDLED_PYTHON)) {
        return @{ Executable = $env:CODEX_BUNDLED_PYTHON; PrefixArguments = @() }
    }

    if (Test-Path -LiteralPath $bundledCodexPython) {
        return @{ Executable = $bundledCodexPython; PrefixArguments = @() }
    }

    $pythonLauncher = Get-Command py -ErrorAction SilentlyContinue
    if ($null -ne $pythonLauncher) {
        return @{ Executable = $pythonLauncher.Source; PrefixArguments = @("-3") }
    }

    $pythonCommand = Get-Command python -ErrorAction SilentlyContinue
    if ($null -ne $pythonCommand -and $pythonCommand.Source -notmatch "WindowsApps") {
        return @{ Executable = $pythonCommand.Source; PrefixArguments = @() }
    }

    throw "Python was not found. Set CODEX_BUNDLED_PYTHON or install a current Python and rerun this script."
}

if (-not (Test-Path -LiteralPath $venvPython)) {
    $currentPython = Get-CurrentPython
    New-Item -ItemType Directory -Force -Path $toolsRoot | Out-Null
    Invoke-Python -Executable $currentPython.Executable -Arguments ($currentPython.PrefixArguments + @("-m", "venv", $venvRoot))
}

Invoke-Python -Executable $venvPython -Arguments @("-m", "ensurepip", "--upgrade")
Invoke-Python -Executable $venvPython -Arguments @("-m", "pip", "install", "--disable-pip-version-check", "--upgrade", "pip")
Invoke-Python -Executable $venvPython -Arguments @("-m", "pip", "install", "--disable-pip-version-check", "lupa==2.8")
Invoke-Python -Executable $venvPython -Arguments @("-c", "import lupa.luajit21")

Write-Host "LuaJIT test environment is ready: $venvPython"
