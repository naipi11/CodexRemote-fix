[CmdletBinding()]
param(
    [string]$Version,
    [switch]$UseExistingTrayHost,
    [string]$TrayHostArtifactDirectory
)

$ErrorActionPreference = 'Stop'

function Get-CcodBuildFileSha256 {
    param([Parameter(Mandatory)][string]$Path)

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $stream = [IO.File]::OpenRead([IO.Path]::GetFullPath($Path))
        try {
            return [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '').ToLowerInvariant()
        } finally {
            $stream.Dispose()
        }
    } finally {
        $sha.Dispose()
    }
}

function Get-CcodBuildGitCommit {
    param([Parameter(Mandatory)][string]$RepositoryRoot)

    $commit = @(& git -C $RepositoryRoot rev-parse HEAD 2>$null)
    if ($LASTEXITCODE -ne 0 -or $commit.Count -ne 1 -or [string]$commit[0] -cnotmatch '^[0-9a-f]{40}$') {
        throw 'The release candidate must be built from a checkout with one canonical git commit.'
    }
    return ([string]$commit[0]).ToLowerInvariant()
}

function Assert-CcodBuildCleanCheckout {
    param([Parameter(Mandatory)][string]$RepositoryRoot)

    $status = @(& git -C $RepositoryRoot status --porcelain --untracked-files=all 2>$null)
    if ($LASTEXITCODE -ne 0) {
        throw 'The release candidate checkout cleanliness could not be determined.'
    }
    if (@($status | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count -ne 0) {
        throw 'Refusing to build a release candidate from a dirty checkout.'
    }
}

$repoRoot = Split-Path $PSScriptRoot -Parent
$package = Get-Content -LiteralPath (Join-Path $repoRoot 'package.json') -Raw | ConvertFrom-Json
$packageVersion = ([string]$package.version).TrimStart('v')
if ($packageVersion -notmatch '^\d+\.\d+\.\d+$') {
    throw "package.json has an invalid project version: $packageVersion"
}
if ([string]::IsNullOrWhiteSpace($Version)) {
    $Version = $packageVersion
}
$Version = $Version.TrimStart('v')
if ($Version -notmatch '^\d+\.\d+\.\d+$') {
    throw "Invalid project version for the installer: $Version"
}
if ($Version -cne $packageVersion) {
    throw "Requested release version $Version does not match package.json version $packageVersion"
}
Assert-CcodBuildCleanCheckout -RepositoryRoot $repoRoot
$gitCommit = Get-CcodBuildGitCommit -RepositoryRoot $repoRoot
$buildTimestampUtc = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)

$trayHostArtifact = if ([string]::IsNullOrWhiteSpace($TrayHostArtifactDirectory)) {
    Join-Path $PSScriptRoot 'generated\trayhost'
} else {
    [IO.Path]::GetFullPath($TrayHostArtifactDirectory)
}
Import-Module (Join-Path $PSScriptRoot 'TrayHostBuild.psm1') -Force
if ($UseExistingTrayHost) {
    Test-CcodTrayHostArtifact -RepositoryRoot $repoRoot -Version $Version -ArtifactDirectory $trayHostArtifact -ExpectedGitCommit $gitCommit | Out-Null
} else {
    Invoke-CcodTrayHostBuild -RepositoryRoot $repoRoot -Version $Version -OutputDirectory $trayHostArtifact -GitCommit $gitCommit -BuildTimestampUtc $buildTimestampUtc | Out-Null
}

$isccCandidates = @(
    (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
    (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe')
)
$iscc = $isccCandidates | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and [IO.File]::Exists($_) } | Select-Object -First 1
if (-not $iscc) {
    throw 'Inno Setup 6 (ISCC.exe) was not found. Install it with: winget install --id JRSoftware.InnoSetup --exact'
}

$scriptPath = Join-Path $PSScriptRoot 'CodexControlOtherDevices.iss'
$dist = Join-Path $PSScriptRoot 'dist'
New-Item -ItemType Directory -Path $dist -Force | Out-Null

& $iscc "/DProjectVersion=$Version" "/DTrayHostArtifactDirectory=$trayHostArtifact" "/O$dist\" $scriptPath
if ($LASTEXITCODE -ne 0) {
    throw "Inno Setup compilation failed with exit code $LASTEXITCODE"
}

$exe = Join-Path $dist "CodexRemote-fix-$Version-setup.exe"
if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
    throw "Inno Setup completed but the installer was not produced: $exe"
}

$hash = Get-CcodBuildFileSha256 -Path $exe
$sha256File = Join-Path $dist ("CodexRemote-fix-$Version-setup.exe.sha256.txt")
Set-Content -LiteralPath $sha256File -Value ("{0} *{1}" -f $hash, [IO.Path]::GetFileName($exe)) -Encoding ascii
$provenanceFile = Join-Path $dist ("CodexRemote-fix-$Version-trayhost-provenance.json")
Copy-Item -LiteralPath (Join-Path $trayHostArtifact 'trayhost-build-provenance.json') -Destination $provenanceFile -Force
$releaseManifestFile = Join-Path $dist ("CodexRemote-fix-$Version-release-manifest.json")
$releaseManifest = [ordered]@{
    schemaVersion = 1
    product = 'CodexRemote-fix'
    version = $Version
    gitCommit = $gitCommit
    buildTimestampUtc = $buildTimestampUtc
    assets = @(
        [ordered]@{ name = [IO.Path]::GetFileName($exe); sha256 = $hash },
        [ordered]@{ name = [IO.Path]::GetFileName($sha256File); sha256 = Get-CcodBuildFileSha256 -Path $sha256File },
        [ordered]@{ name = [IO.Path]::GetFileName($provenanceFile); sha256 = Get-CcodBuildFileSha256 -Path $provenanceFile }
    )
}
$releaseManifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $releaseManifestFile -Encoding UTF8
$releaseValidationTool = Join-Path $repoRoot 'tools\Test-ReleaseDefender.ps1'
if (-not (Test-Path -LiteralPath $releaseValidationTool -PathType Leaf)) {
    throw "Release manifest validator is missing: $releaseValidationTool"
}
. $releaseValidationTool -Library
Test-CcodReleaseAssetManifest -ManifestPath $releaseManifestFile -AssetDirectory $dist -ExpectedVersion $Version | Out-Null

Write-Host ''
Write-Host 'Installer build completed:' -ForegroundColor Green
Write-Host ("  Setup:    {0}" -f $exe)
Write-Host ("  SHA-256:  {0}" -f $sha256File)
Write-Host ("  Hash:     {0}" -f $hash)
Write-Host ("  TrayHost: {0}" -f $provenanceFile)
Write-Host ("  Manifest: {0}" -f $releaseManifestFile)
Write-Host ''
