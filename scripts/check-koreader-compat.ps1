param([switch]$Offline)

$ErrorActionPreference = "Stop"
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$toolsRoot = Join-Path $repositoryRoot ".tools"
$sourceRoot = Join-Path $toolsRoot "koreader"
$archivePath = Join-Path $toolsRoot "koreader-kindlehf-v2026.07.1.zip"
$python = Join-Path $toolsRoot "python\python.exe"
$tag = "v2026.07.1"
$expectedCommit = "9192014d8bd82a91dc1012473be0f238dedfdb54"
$archiveUrl = "https://github.com/koreader/koreader/releases/download/v2026.07.1/koreader-kindlehf-v2026.07.1.zip"
$archiveSha256 = "3343a916d12f36c01b59df1f65bd83ff5616e6c2a4dfbe919e7fa1400b8b1bbb"

if (-not (Test-Path -LiteralPath $toolsRoot -PathType Container)) {
    New-Item -ItemType Directory -Path $toolsRoot | Out-Null
}
if (-not (Test-Path -LiteralPath $python -PathType Leaf)) {
    & (Join-Path $PSScriptRoot "bootstrap-tests.ps1")
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) {
    if ($Offline) { Write-Error "KOReader source is absent in offline mode: $sourceRoot"; exit 1 }
    & git clone --quiet --depth 1 --branch $tag https://github.com/koreader/koreader.git $sourceRoot
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
$headCommit = (& git -C $sourceRoot rev-parse HEAD 2>$null).Trim()
if ($LASTEXITCODE -ne 0) { Write-Error "Unable to read KOReader checkout: $sourceRoot"; exit 1 }
$tagCommit = (& git -C $sourceRoot rev-parse ("refs/tags/{0}^{{commit}}" -f $tag) 2>$null).Trim()
if ($LASTEXITCODE -ne 0 -or $headCommit -ne $expectedCommit -or $tagCommit -ne $expectedCommit) {
    Write-Error "KOReader source must be an exact $tag checkout: $sourceRoot"
    exit 1
}
$dirty = & git -C $sourceRoot status --porcelain=v1 --untracked-files=all --ignore-submodules=none
if ($LASTEXITCODE -ne 0 -or $dirty) {
    Write-Error "KOReader source cache has tracked/index/worktree changes: $sourceRoot"
    exit 1
}

$archiverSource = Join-Path $sourceRoot "base\ffi\archiver.lua"
if (-not (Test-Path -LiteralPath $archiverSource -PathType Leaf)) {
    if ($Offline) { Write-Error "KOReader base submodule is absent in offline mode: $archiverSource"; exit 1 }
    & git -C $sourceRoot submodule update --init --depth 1 base
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
$dirty = & git -C $sourceRoot status --porcelain=v1 --untracked-files=all --ignore-submodules=none
if ($LASTEXITCODE -ne 0 -or $dirty) {
    Write-Error "KOReader source cache changed after submodule initialization: $sourceRoot"
    exit 1
}

if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
    if ($Offline) { Write-Error "kindlehf archive is absent in offline mode: $archivePath"; exit 1 }
    $temporaryArchive = $archivePath + ".part"
    Invoke-WebRequest -UseBasicParsing -Uri $archiveUrl -OutFile $temporaryArchive
    $downloadHash = (Get-FileHash -LiteralPath $temporaryArchive -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($downloadHash -ne $archiveSha256) {
        Remove-Item -LiteralPath $temporaryArchive -Force
        Write-Error "Downloaded kindlehf archive hash mismatch."
        exit 1
    }
    Move-Item -LiteralPath $temporaryArchive -Destination $archivePath
}
$actualHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actualHash -ne $archiveSha256) {
    Write-Error "Cached kindlehf archive hash mismatch: $archivePath"
    exit 1
}

& $python (Join-Path $PSScriptRoot "check_koreader_compat.py") --plugin-root (Join-Path $repositoryRoot "legado.koplugin") --source-root $sourceRoot --kindlehf-archive $archivePath --tag $tag
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$previousSource = $env:LEGADO_KOREADER_SOURCE
try {
    $env:LEGADO_KOREADER_SOURCE = $sourceRoot
    & $python (Join-Path $PSScriptRoot "run_lua_specs.py") --spec spec/native_entry_spec.lua --spec spec/native_menu_startup_spec.lua --spec spec/native_home_widget_spec.lua --spec spec/native_reader_toolbar_spec.lua --spec spec/native_reading_screen_spec.lua --spec spec/native_reading_flow_spec.lua --spec spec/native_progress_bar_spec.lua --spec spec/native_receipt_screen_spec.lua --spec spec/receipt_repaint_spec.lua --spec spec/native_session_workflow_spec.lua --spec spec/session_shell_spec.lua --spec spec/book_reader_settings_spec.lua
    $contractExit = $LASTEXITCODE
} finally {
    $env:LEGADO_KOREADER_SOURCE = $previousSource
}
if ($contractExit -ne 0) { exit $contractExit }
& $python (Join-Path $repositoryRoot "spec\official_sqlite_test.py")
exit $LASTEXITCODE
