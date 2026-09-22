$ErrorActionPreference = "Stop"

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$venvPython = Join-Path $repositoryRoot ".tools\python\python.exe"

if (-not (Test-Path -LiteralPath $venvPython)) {
    & (Join-Path $PSScriptRoot "bootstrap-tests.ps1")
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
}

& $venvPython (Join-Path $PSScriptRoot "run_lua_specs.py")
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

& (Join-Path $PSScriptRoot "check-namespace.ps1")
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

& $venvPython (Join-Path $repositoryRoot "spec\probe_transport_test.py")
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

& $venvPython (Join-Path $repositoryRoot "spec\reader_document_io_test.py")
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

& powershell -ExecutionPolicy Bypass -File (Join-Path $repositoryRoot "spec\namespace_checker_spec.ps1")
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

& $venvPython (Join-Path $PSScriptRoot "run_lua_specs.py") "--spec" "spec/plugin_smoke_spec.lua"
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

& powershell -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "verify-epub.ps1") -SelfTest
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

& powershell -ExecutionPolicy Bypass -File (Join-Path $repositoryRoot "spec\package_spec.ps1")
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

& powershell -ExecutionPolicy Bypass -File (Join-Path $repositoryRoot "spec\koreader_compat_spec.ps1")
exit $LASTEXITCODE
