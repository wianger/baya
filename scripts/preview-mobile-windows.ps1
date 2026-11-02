param(
    [string]$SourceApp = (Join-Path (Split-Path $PSScriptRoot -Parent) 'app'),
    [string]$BuildRoot = (Join-Path $env:LOCALAPPDATA 'RemotePiMobileBuild'),
    [string]$OutputDirectory = (Join-Path $env:USERPROFILE 'Downloads\Baya-UI-Preview'),
    [string]$ProxyUrl = $env:HTTPS_PROXY,
    [string]$FlutterRoot = 'C:\Scoop\apps\flutter\current',
    [ValidateSet('dark', 'light')][string]$Theme = 'dark'
)
$ErrorActionPreference = 'Stop'
$flutter = Join-Path $flutterRoot 'bin\flutter.bat'
if (-not (Test-Path -LiteralPath $flutter)) { throw 'Install Flutter with Scoop first.' }
$source = (Resolve-Path -LiteralPath $SourceApp).ProviderPath
$buildRootPath = [IO.Path]::GetFullPath($BuildRoot).TrimEnd('\')
$buildApp = [IO.Path]::GetFullPath((Join-Path $BuildRoot 'app')).TrimEnd('\')
if ([IO.Path]::GetFullPath($source).TrimEnd('\') -eq $buildApp) {
    throw 'Source and build snapshot must be different directories.'
}
$buildAppPrefix = "$buildRootPath$([IO.Path]::DirectorySeparatorChar)"
if (-not $buildApp.StartsWith($buildAppPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Build snapshot must stay inside BuildRoot.'
}
if (Test-Path -LiteralPath $buildApp) {
    Remove-Item -LiteralPath $buildApp -Recurse -Force
}
New-Item -ItemType Directory -Path $buildApp -Force | Out-Null
& robocopy $source $buildApp /E /XD .dart_tool build .gradle /XF local.properties key.properties /NFL /NDL /NJH /NJS /NP
if ($LASTEXITCODE -ge 8) { throw 'Source snapshot copy failed.' }

# The desktop test engine lacks Android's installed CJK fallback. Cache the
# open Noto face for previews only; the APK uses the device's system font.
$fontDirectory = Join-Path $OutputDirectory 'fonts'
New-Item -ItemType Directory -Path $fontDirectory -Force | Out-Null
$cjk = Join-Path $fontDirectory 'NotoSansCJKsc-Regular.otf'
$notoBase = 'https://raw.githubusercontent.com/notofonts/noto-cjk/f8d157532fbfaeda587e826d4cd5b21a49186f7c/Sans'
foreach ($entry in @(
    @{ Path = $cjk; Url = "$notoBase/OTF/SimplifiedChinese/NotoSansCJKsc-Regular.otf" },
    @{ Path = (Join-Path $fontDirectory 'NotoSansCJK-OFL.txt'); Url = "$notoBase/LICENSE" }
)) {
    if (-not (Test-Path -LiteralPath $entry.Path)) {
        $curlArguments = @('-fLsS', '--connect-timeout', '10', '--max-time', '120')
        if ($ProxyUrl) { $curlArguments += @('--proxy', $ProxyUrl) }
        & curl.exe @curlArguments $entry.Url '-o' $entry.Path
        if ($LASTEXITCODE -ne 0) { throw 'Noto preview font/license download failed.' }
    }
}
if ((Get-FileHash -LiteralPath $cjk -Algorithm SHA256).Hash -ne '2C76254F6FC379FDDFCE0A7E84FB5385BB135D3E399294F6EEB6680D0365B74B') {
    throw 'Noto preview font checksum mismatch.'
}
$savedEnvironment = @{}
foreach ($name in @('BAYA_PREVIEW_DIR', 'BAYA_PREVIEW_THEME', 'BAYA_PREVIEW_CJK_FONT')) {
    $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
try {
    $env:BAYA_PREVIEW_DIR = [IO.Path]::GetFullPath($OutputDirectory)
    $env:BAYA_PREVIEW_THEME = $Theme
    $env:BAYA_PREVIEW_CJK_FONT = $cjk
    Push-Location $buildApp
    try {
        & $flutter pub get
        if ($LASTEXITCODE -ne 0) { throw 'flutter pub get failed.' }
        & $flutter test --no-pub --timeout 60s test/ui/workspaces/ui_preview_gallery_test.dart
        if ($LASTEXITCODE -ne 0) { throw 'UI preview rendering failed.' }
    } finally { Pop-Location }
    Write-Output "Preview images: $OutputDirectory"
} finally {
    foreach ($name in $savedEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process')
    }
}
