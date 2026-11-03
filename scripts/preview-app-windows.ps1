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

$savedEnvironment = @{}
foreach ($name in @('BAYA_PREVIEW_DIR', 'BAYA_PREVIEW_THEME')) {
    $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
try {
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    $env:BAYA_PREVIEW_DIR = [IO.Path]::GetFullPath($OutputDirectory)
    $env:BAYA_PREVIEW_THEME = $Theme
    Push-Location $buildApp
    try {
        & $flutter pub get
        if ($LASTEXITCODE -ne 0) { throw 'flutter pub get failed.' }
        & $flutter test --no-pub --timeout 60s test/ui/design_gallery_test.dart test/ui/chat/chat_preview_test.dart
        if ($LASTEXITCODE -ne 0) { throw 'UI preview rendering failed.' }
    } finally { Pop-Location }
    Write-Output "Preview images: $OutputDirectory"
} finally {
    foreach ($name in $savedEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process')
    }
}
