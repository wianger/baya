[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Apk,
    [Parameter(Mandatory)][string]$NotesFile,
    [string]$SourceRoot = (Split-Path $PSScriptRoot -Parent),
    [string]$Branch = 'codex/baya-standalone-20261101',
    [string]$AndroidSdk = 'C:\Scoop\persist\android-clt',
    [string]$JdkRoot = 'C:\Scoop\apps\temurin17-jdk\17.0.20-101',
    [string]$GhExe = 'gh',
    [string]$ExpectedCertificateSha256 = 'bdaba7b38a226cf6bcf2673d24a8f56453ffdce66f3b3402e48e0bca7b884eaa',
    [switch]$Publish
)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path -LiteralPath $SourceRoot).ProviderPath
$apkFile = (Resolve-Path -LiteralPath $Apk).ProviderPath
$notes = (Resolve-Path -LiteralPath $NotesFile).ProviderPath
$branch = (& git -C $repo branch --show-current).Trim()
if ($LASTEXITCODE -ne 0 -or $branch -ne $Branch) { throw "Use the $Branch development branch." }
$dirty = & git -C $repo status --porcelain
if ($LASTEXITCODE -ne 0 -or $dirty) { throw 'Commit the development source and keep the checkout clean before publishing.' }
$commit = (& git -C $repo rev-parse HEAD).Trim()
$remote = (& $GhExe api "repos/wianger/baya/commits/$Branch" --jq '.sha').Trim()
if ($LASTEXITCODE -ne 0 -or $remote -ne $commit) { throw 'Push this exact development commit before publishing.' }
$pubspec = [IO.File]::ReadAllText((Join-Path $repo 'app\pubspec.yaml'))
$versionMatch = [regex]::Match($pubspec, '(?m)^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$')
if (-not $versionMatch.Success) { throw 'pubspec needs version x.y.z+buildNumber.' }
$version = $versionMatch.Groups[1].Value
$build = [int]$versionMatch.Groups[2].Value
$java = Join-Path $JdkRoot 'bin\java.exe'
if (-not (Test-Path -LiteralPath $java)) { throw "Missing Java runtime: $java" }
$env:JAVA_HOME = $JdkRoot
$env:PATH = "$(Join-Path $JdkRoot 'bin');$env:PATH"
$tools = Join-Path $AndroidSdk 'build-tools\36.0.0'
$badging = & (Join-Path $tools 'aapt2.exe') dump badging $apkFile
if ($LASTEXITCODE -ne 0) { throw 'Could not inspect APK.' }
$package = [regex]::Match(($badging -join "`n"), "package: name='([^']+)' versionCode='(\d+)' versionName='([^']+)'")
if (-not $package.Success -or $package.Groups[1].Value -ne 'dev.wianger.baya' -or
    [int]$package.Groups[2].Value -ne $build -or $package.Groups[3].Value -ne $version) {
    throw 'APK package/version does not match the development source.'
}
$signature = & (Join-Path $tools 'apksigner.bat') verify --print-certs $apkFile
if ($LASTEXITCODE -ne 0) { throw 'APK signature verification failed.' }
$certificate = [regex]::Match(($signature -join "`n"), 'certificate SHA-256 digest:\s*([0-9a-fA-F]+)')
if (-not $certificate.Success -or $certificate.Groups[1].Value -ne $ExpectedCertificateSha256) {
    throw 'APK was not signed by the personal development key; existing installs could not update.'
}
$published = & $GhExe api 'repos/wianger/baya/releases?per_page=100'
if ($LASTEXITCODE -ne 0) { throw 'Could not check existing release version codes.' }
$releases = $published | ConvertFrom-Json
$tag = "android-dev-v$version+$build"
$existingCurrent = @($releases | Where-Object { $_.tag_name -eq $tag })
foreach ($release in $releases) {
    $previous = [regex]::Match($release.tag_name, '^android-dev-v\d+\.\d+\.\d+\+(\d+)$')
    if ($previous.Success -and [int]$previous.Groups[1].Value -ge $build -and
        $release.tag_name -ne $tag -and $release.draft -ne $true) {
        throw 'Increment the Android build number before publishing. Existing releases are never overwritten.'
    }
}
$stage = Join-Path ([IO.Path]::GetTempPath()) ('BayaRelease-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage | Out-Null
$stagedApk = Join-Path $stage 'Baya-Android.apk'
Copy-Item -LiteralPath $apkFile -Destination $stagedApk
$hash = (Get-FileHash -LiteralPath $stagedApk -Algorithm SHA256).Hash.ToLowerInvariant()
$sums = Join-Path $stage 'SHA256SUMS.txt'
[IO.File]::WriteAllText($sums, "$hash  Baya-Android.apk`n", [Text.UTF8Encoding]::new($false))
if ($existingCurrent.Count -gt 0) {
    if ($existingCurrent[0].draft -ne $true) {
        throw 'This release is already published and will not be overwritten.'
    }
    & $GhExe release upload $tag $stagedApk $sums --repo wianger/baya --clobber
    if ($LASTEXITCODE -ne 0) { throw 'Draft release asset re-upload failed.' }
    & $GhExe release edit $tag --repo wianger/baya --target $commit `
        --title "Baya Android $version ($build)" --notes-file $notes
    if ($LASTEXITCODE -ne 0) { throw 'Draft release metadata update failed.' }
} else {
    & $GhExe release create $tag $stagedApk $sums --repo wianger/baya --target $commit `
        --prerelease --draft --title "Baya Android $version ($build)" --notes-file $notes
    if ($LASTEXITCODE -ne 0) { throw 'Draft release creation/upload failed. Inspect the draft before retrying.' }
}
$view = & $GhExe release view $tag --repo wianger/baya --json assets,isDraft,url | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or -not $view.isDraft -or
    @($view.assets | Where-Object { $_.name -eq 'Baya-Android.apk' -and $_.size -eq (Get-Item -LiteralPath $stagedApk).Length }).Count -ne 1 -or
    @($view.assets | Where-Object { $_.name -eq 'SHA256SUMS.txt' }).Count -ne 1) {
    throw 'Draft asset verification failed. The release remains unpublished.'
}
if ($Publish) {
    & $GhExe release edit $tag --repo wianger/baya --draft=false --prerelease
    if ($LASTEXITCODE -ne 0) { throw 'Publishing failed; inspect the existing draft.' }
}
[pscustomobject]@{ Tag = $tag; Commit = $commit; Published = [bool]$Publish; Sha256 = $hash; Stage = $stage }
