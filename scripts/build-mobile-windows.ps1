param(
    [string]$SourceApp = (Join-Path (Split-Path $PSScriptRoot -Parent) 'app'),
    [string]$BuildRoot = (Join-Path $env:LOCALAPPDATA 'RemotePiMobileBuild'),
    [string]$OutputApk = (Join-Path $env:USERPROFILE 'Downloads\Baya-Android.apk'),
    [string]$ProxyUrl = $env:HTTPS_PROXY,
    [string]$FlutterRoot = 'C:\Scoop\apps\flutter\current',
    [string]$JdkRoot = 'C:\Scoop\apps\temurin17-jdk\current',
    [string]$AndroidSdkRoot = 'C:\Scoop\apps\android-clt\current',
    [string]$AndroidBuildToolsRoot = 'C:\Scoop\persist\android-clt\build-tools\36.0.0'
)
$ErrorActionPreference = 'Stop'
$flutter = Join-Path $FlutterRoot 'bin\flutter.bat'
$jdk = $JdkRoot
$sdk = $AndroidSdkRoot
$apksigner = Join-Path $AndroidBuildToolsRoot 'apksigner.bat'
foreach ($toolPath in @($flutter, "$jdk\bin\keytool.exe", "$sdk\platform-tools\adb.exe", $apksigner)) {
    if (-not (Test-Path -LiteralPath $toolPath)) { throw "Missing development tool: $toolPath" }
}
$source = (Resolve-Path -LiteralPath $SourceApp).ProviderPath
$buildRootPath = [IO.Path]::GetFullPath($BuildRoot).TrimEnd('\')
$buildApp = [IO.Path]::GetFullPath((Join-Path $BuildRoot 'app')).TrimEnd('\')
$outputDirectory = Split-Path -Parent $OutputApk
if (-not $outputDirectory) { throw 'OutputApk must include a parent directory.' }
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
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

# Keep this compatibility path: it already contains the private key that signs
# the installed dev.wianger.remotepi app. Moving the key would break in-place
# Android updates. The password remains protected with Windows DPAPI.
$signing = Join-Path $BuildRoot 'signing'
New-Item -ItemType Directory -Path $signing -Force | Out-Null
$metadataPath = Join-Path $signing 'personal-key.json'
$keyPath = Join-Path $signing 'remotepi-personal.jks'
$env:JAVA_HOME = $jdk
$env:ANDROID_HOME = $sdk
$previousGradleOptions = $env:GRADLE_OPTS
if ($ProxyUrl) {
    $proxy = [uri]$ProxyUrl
    if ($proxy.Scheme -ne 'http' -or $proxy.UserInfo) { throw 'Use an HTTP proxy URL without embedded credentials.' }
    $env:GRADLE_OPTS = "$previousGradleOptions -Dhttps.proxyHost=$($proxy.Host) -Dhttps.proxyPort=$($proxy.Port) -Dhttp.proxyHost=$($proxy.Host) -Dhttp.proxyPort=$($proxy.Port)"
}
try {
    if (Test-Path -LiteralPath $metadataPath) {
        $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
        if (-not (Test-Path -LiteralPath $keyPath)) { throw 'Signing key is missing. Restore it before building an update.' }
        $credential = [pscredential]::new('signing', (ConvertTo-SecureString $metadata.password))
        $env:BAYA_KEY_PASSWORD = $credential.GetNetworkCredential().Password
    } else {
        if (Test-Path -LiteralPath $keyPath) { throw 'A signing key already exists without its metadata. Restore its metadata first.' }
        $env:BAYA_KEY_PASSWORD = [guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N')
        & "$jdk\bin\keytool.exe" -genkeypair -keystore $keyPath -alias remotepi-personal `
            -storepass:env BAYA_KEY_PASSWORD -keypass:env BAYA_KEY_PASSWORD `
            -keyalg RSA -keysize 3072 -validity 10000 -dname 'CN=Remote Pi Personal'
        if ($LASTEXITCODE -ne 0) { throw 'Creating the personal signing key failed.' }
        $protected = ConvertTo-SecureString $env:BAYA_KEY_PASSWORD -AsPlainText -Force | ConvertFrom-SecureString
        @{ password = $protected; alias = 'remotepi-personal' } | ConvertTo-Json | Set-Content -LiteralPath $metadataPath
    }
    $properties = @(
        "storeFile=$($keyPath.Replace('\','/'))"
        "storePassword=$env:BAYA_KEY_PASSWORD"
        "keyPassword=$env:BAYA_KEY_PASSWORD"
        'keyAlias=remotepi-personal'
    ) -join "`n"
    [IO.File]::WriteAllText((Join-Path $buildApp 'android\key.properties'), $properties)
    Push-Location $buildApp
    try {
        & $flutter pub get
        if ($LASTEXITCODE -ne 0) { throw 'flutter pub get failed.' }
        & $flutter build apk --release --target-platform android-arm64
        if ($LASTEXITCODE -ne 0) { throw 'Android build failed.' }
    } finally { Pop-Location }
    $apk = Join-Path $buildApp 'build\app\outputs\flutter-apk\app-release.apk'
    & $apksigner verify --print-certs $apk
    if ($LASTEXITCODE -ne 0) { throw 'APK signature verification failed.' }
    Copy-Item -LiteralPath $apk -Destination $OutputApk -Force
    Get-FileHash -LiteralPath $OutputApk -Algorithm SHA256
} finally {
    $env:GRADLE_OPTS = $previousGradleOptions
    Remove-Item Env:\BAYA_KEY_PASSWORD -ErrorAction SilentlyContinue
    # Keep private key material outside the source tree and out of snapshots.
    $propertiesPath = Join-Path $buildApp 'android\key.properties'
    if (Test-Path -LiteralPath $propertiesPath) { Remove-Item -LiteralPath $propertiesPath }
}
