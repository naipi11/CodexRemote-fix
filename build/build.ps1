[CmdletBinding()]
param(
    [string]$Version,
    [switch]$UseExistingTrayHost,
    [string]$TrayHostArtifactDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-CcodBuildFileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    $stream = $null
    try {
        $stream = [IO.File]::Open([IO.Path]::GetFullPath($Path),[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        return [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '').ToLowerInvariant()
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
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
    if ($LASTEXITCODE -ne 0) { throw 'The release candidate checkout cleanliness could not be determined.' }
    if (@($status | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count -ne 0) {
        throw 'Refusing to build a release candidate from a dirty checkout.'
    }
}

function Assert-CcodBuildRegularFile {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Kind)
    $full = [IO.Path]::GetFullPath($Path)
    if (-not [IO.File]::Exists($full)) { throw "$Kind is missing: $full" }
    $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw "$Kind must be a regular non-reparse file: $full"
    }
    return $full
}

function Test-CcodBuildPayloadRelativePath {
    param([Parameter(Mandatory)][string]$Path)
    return $Path -cmatch '^[A-Za-z0-9][A-Za-z0-9._/-]{0,255}$' -and -not $Path.Contains('//') -and -not $Path.Contains('..') -and -not $Path.Contains(':')
}

function Copy-CcodBuildPayloadFile {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$PayloadRoot,
        [Parameter(Mandatory)][string]$Relative
    )
    if (-not (Test-CcodBuildPayloadRelativePath $Relative)) { throw "Portable payload path is invalid: $Relative" }
    $sourcePath = Assert-CcodBuildRegularFile -Path $Source -Kind 'Portable payload source'
    $destination = [IO.Path]::GetFullPath((Join-Path $PayloadRoot ($Relative.Replace('/',[IO.Path]::DirectorySeparatorChar.ToString()))))
    $prefix = $PayloadRoot.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $destination.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { throw "Portable payload path escaped its root: $Relative" }
    $parent = Split-Path $destination -Parent
    if (-not [IO.Directory]::Exists($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    if ([IO.File]::Exists($destination) -or [IO.Directory]::Exists($destination)) { throw "Portable payload would contain a duplicate path: $Relative" }
    [IO.File]::Copy($sourcePath,$destination,$false)
    if ((Get-CcodBuildFileSha256 -Path $sourcePath) -cne (Get-CcodBuildFileSha256 -Path $destination)) {
        throw "Portable payload copy hash mismatch: $Relative"
    }
}

function Get-CcodBuildPayloadRecords {
    param([Parameter(Mandatory)][string]$PayloadRoot)
    $root = [IO.Path]::GetFullPath($PayloadRoot)
    $prefix = $root.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $records = [Collections.Generic.List[object]]::new()
    foreach ($item in @(Get-ChildItem -LiteralPath $root -Force -Recurse -File -ErrorAction Stop)) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Portable payload contains a reparse point: $($item.FullName)" }
        $full = [IO.Path]::GetFullPath($item.FullName)
        if (-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { throw "Portable payload escaped its root: $full" }
        $relative = $full.Substring($prefix.Length).Replace([IO.Path]::DirectorySeparatorChar,'/')
        if (-not (Test-CcodBuildPayloadRelativePath $relative)) { throw "Portable payload path is invalid: $relative" }
        $records.Add([pscustomobject][ordered]@{
            path = $relative
            length = [int64]$item.Length
            sha256 = Get-CcodBuildFileSha256 -Path $full
        })
    }
    $comparison = [System.Comparison[object]]{ param($left,$right) [StringComparer]::Ordinal.Compare([string]$left.path,[string]$right.path) }
    $records.Sort($comparison)
    if ($records.Count -eq 0) { throw 'Portable payload is empty.' }
    return @($records)
}

function Write-CcodBuildUtf8 {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Text)
    if ([IO.File]::Exists($Path) -or [IO.Directory]::Exists($Path)) { throw "Refusing to overwrite immutable release output: $Path" }
    [IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($false))
}

$repoRoot = Split-Path $PSScriptRoot -Parent
$package = Get-Content -LiteralPath (Join-Path $repoRoot 'package.json') -Raw | ConvertFrom-Json
$packageVersion = ([string]$package.version).TrimStart('v')
if ($packageVersion -notmatch '^\d+\.\d+\.\d+$') { throw "package.json has an invalid project version: $packageVersion" }
if ([string]::IsNullOrWhiteSpace($Version)) { $Version = $packageVersion }
$Version = $Version.TrimStart('v')
if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw "Invalid project version for the portable bundle: $Version" }
if ($Version -cne $packageVersion) { throw "Requested release version $Version does not match package.json version $packageVersion" }
Assert-CcodBuildCleanCheckout -RepositoryRoot $repoRoot
$gitCommit = Get-CcodBuildGitCommit -RepositoryRoot $repoRoot
$buildTimestampUtc = [DateTime]::UtcNow.ToString('o',[Globalization.CultureInfo]::InvariantCulture)

$trayHostArtifact = if ([string]::IsNullOrWhiteSpace($TrayHostArtifactDirectory)) { Join-Path $PSScriptRoot 'generated\trayhost' } else { [IO.Path]::GetFullPath($TrayHostArtifactDirectory) }
Import-Module (Join-Path $PSScriptRoot 'TrayHostBuild.psm1') -Force
if ($UseExistingTrayHost) {
    Test-CcodTrayHostArtifact -RepositoryRoot $repoRoot -Version $Version -ArtifactDirectory $trayHostArtifact -ExpectedGitCommit $gitCommit | Out-Null
} else {
    Invoke-CcodTrayHostBuild -RepositoryRoot $repoRoot -Version $Version -OutputDirectory $trayHostArtifact -GitCommit $gitCommit -BuildTimestampUtc $buildTimestampUtc | Out-Null
}

$dist = Join-Path $PSScriptRoot 'dist'
[IO.Directory]::CreateDirectory($dist) | Out-Null
$bundle = Join-Path $dist "CodexRemote-fix-$Version-windows-x64.zip"
$checksum = "$bundle.sha256.txt"
$provenance = Join-Path $dist "CodexRemote-fix-$Version-trayhost-provenance.json"
$payloadManifestAsset = Join-Path $dist "CodexRemote-fix-$Version-payload-manifest.json"
$releaseManifest = Join-Path $dist "CodexRemote-fix-$Version-release-manifest.json"
$setupExe = Join-Path $dist "CodexRemote-fix-$Version-setup.exe"
$setupChecksum = "$setupExe.sha256.txt"
foreach ($path in @($bundle,$checksum,$provenance,$payloadManifestAsset,$releaseManifest,$setupExe,$setupChecksum)) {
    if ([IO.File]::Exists($path) -or [IO.Directory]::Exists($path)) { throw "Refusing to overwrite immutable release output: $path" }
}

$stageRoot = Join-Path $PSScriptRoot ('.portable-stage-' + [guid]::NewGuid().ToString('N'))
try {
    [IO.Directory]::CreateDirectory($stageRoot) | Out-Null
    $payloadRoot = Join-Path $stageRoot 'payload'
    [IO.Directory]::CreateDirectory($payloadRoot) | Out-Null

    Copy-CcodBuildPayloadFile -Source (Join-Path $repoRoot 'package.json') -PayloadRoot $payloadRoot -Relative 'package.json'
    foreach ($relative in @(
        'Install-CodexControlOtherDevices.ps1',
        'Uninstall-CodexControlOtherDevices.ps1',
        'Test-CodexControlOtherDevices.ps1',
        'Start-CodexControlOtherDevices.ps1',
        'Reset-CodexControlOtherDevices.ps1',
        'src/check-package.mjs',
        'src/persistence/Supervisor.ps1',
        'src/persistence/SessionController.ps1',
        'src/persistence/StaticProbeWorker.ps1',
        'src/persistence/LifecycleWorker.ps1',
        'src/persistence/bootstrap.ps1',
        'src/persistence/UninstallBootstrap.ps1',
        'src/persistence/PortableUninstallFinalizer.ps1'
    )) {
        Copy-CcodBuildPayloadFile -Source (Join-Path $repoRoot ($relative.Replace('/','\'))) -PayloadRoot $payloadRoot -Relative $relative
    }
    foreach ($module in @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'src\persistence\modules') -Filter '*.psm1' -File -Force | Sort-Object Name)) {
        Copy-CcodBuildPayloadFile -Source $module.FullName -PayloadRoot $payloadRoot -Relative ('src/persistence/modules/' + $module.Name)
    }
    foreach ($resource in @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'src\persistence\resources') -File -Force | Sort-Object Name)) {
        Copy-CcodBuildPayloadFile -Source $resource.FullName -PayloadRoot $payloadRoot -Relative ('src/persistence/resources/' + $resource.Name)
    }
    $runtimeRoot = Join-Path $repoRoot 'src\runtime'
    foreach ($runtimeFile in @(Get-ChildItem -LiteralPath $runtimeRoot -File -Force -Recurse | Sort-Object FullName)) {
        $relative = $runtimeFile.FullName.Substring($runtimeRoot.TrimEnd('\').Length + 1).Replace('\','/')
        Copy-CcodBuildPayloadFile -Source $runtimeFile.FullName -PayloadRoot $payloadRoot -Relative ('src/runtime/' + $relative)
    }
    Invoke-CcodPortableLauncherBuild -RepositoryRoot $repoRoot -Version $Version -OutputDirectory (Join-Path $PSScriptRoot 'generated\portable') -GitCommit $gitCommit -BuildTimestampUtc $buildTimestampUtc | Out-Null
    foreach ($trayHostFile in @('CodexRemote.TrayHost.exe','CodexRemote.TrayHost.exe.config','trayhost-build-provenance.json')) {
        Copy-CcodBuildPayloadFile -Source (Join-Path $trayHostArtifact $trayHostFile) -PayloadRoot $payloadRoot -Relative ('bin/' + $trayHostFile)
    }
    foreach ($portableFile in @('CodexRemote.Portable.exe','CodexRemote.Portable.exe.config','portable-launcher-provenance.json')) {
        Copy-CcodBuildPayloadFile -Source (Join-Path $PSScriptRoot ('generated\portable\' + $portableFile)) -PayloadRoot $payloadRoot -Relative ('bin/' + $portableFile)
    }
    $lifecycleModule = Import-Module (Join-Path $payloadRoot 'src\persistence\modules\InstallLifecycle.psm1') -Force -PassThru
    try {
        & $lifecycleModule { param($Root) Get-CcodLifecycleSourceFiles -SourceRoot $Root -RequireTrayHost | Out-Null } $payloadRoot
    } finally {
        Remove-Module -Name $lifecycleModule.Name -Force -ErrorAction SilentlyContinue
    }
    $payloadRecords = Get-CcodBuildPayloadRecords -PayloadRoot $payloadRoot
    $payloadManifestPath = Join-Path $stageRoot 'payload-manifest.json'
    $payloadManifest = [ordered]@{
        schemaVersion = 1
        product = 'CodexRemote-fix'
        version = $Version
        gitCommit = $gitCommit
        buildTimestampUtc = $buildTimestampUtc
        files = $payloadRecords
    }
    Write-CcodBuildUtf8 -Path $payloadManifestPath -Text (($payloadManifest | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
    [IO.File]::Copy((Assert-CcodBuildRegularFile -Path (Join-Path $repoRoot 'Install-CodexRemote-fix.ps1') -Kind 'Portable bundle entrypoint'),(Join-Path $stageRoot 'Install-CodexRemote-fix.ps1'),$false)
    [IO.File]::Copy((Assert-CcodBuildRegularFile -Path (Join-Path $PSScriptRoot 'generated\portable\CodexRemote.Portable.exe') -Kind 'Portable launcher'),(Join-Path $stageRoot 'CodexRemote-fix.exe'),$false)
    [IO.File]::Copy((Assert-CcodBuildRegularFile -Path (Join-Path $PSScriptRoot 'generated\portable\CodexRemote.Portable.exe.config') -Kind 'Portable launcher config'),(Join-Path $stageRoot 'CodexRemote-fix.exe.config'),$false)

    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    [IO.Compression.ZipFile]::CreateFromDirectory($stageRoot,$bundle,[IO.Compression.CompressionLevel]::Optimal,$false)
    [IO.File]::Copy($payloadManifestPath,$payloadManifestAsset,$false)
    [IO.File]::Copy((Assert-CcodBuildRegularFile -Path (Join-Path $trayHostArtifact 'trayhost-build-provenance.json') -Kind 'TrayHost provenance'),$provenance,$false)
    $bundleHash = Get-CcodBuildFileSha256 -Path $bundle
    Write-CcodBuildUtf8 -Path $checksum -Text ("{0} *{1}" -f $bundleHash,[IO.Path]::GetFileName($bundle))
    $releaseRecord = [ordered]@{
        schemaVersion = 2
        product = 'CodexRemote-fix'
        version = $Version
        gitCommit = $gitCommit
        buildTimestampUtc = $buildTimestampUtc
        distribution = 'portable-zip'
        assets = @(
            [ordered]@{ name = [IO.Path]::GetFileName($bundle); sha256 = $bundleHash },
            [ordered]@{ name = [IO.Path]::GetFileName($checksum); sha256 = Get-CcodBuildFileSha256 -Path $checksum },
            [ordered]@{ name = [IO.Path]::GetFileName($provenance); sha256 = Get-CcodBuildFileSha256 -Path $provenance },
            [ordered]@{ name = [IO.Path]::GetFileName($payloadManifestAsset); sha256 = Get-CcodBuildFileSha256 -Path $payloadManifestAsset },
            [ordered]@{ name = 'CodexRemote-fix.exe'; sha256 = Get-CcodBuildFileSha256 -Path (Join-Path $stageRoot 'CodexRemote-fix.exe') },
            [ordered]@{ name = 'CodexRemote-fix.exe.config'; sha256 = Get-CcodBuildFileSha256 -Path (Join-Path $stageRoot 'CodexRemote-fix.exe.config') }
        )
    }
    Write-CcodBuildUtf8 -Path $releaseManifest -Text (($releaseRecord | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
    $releaseValidationTool = Join-Path $repoRoot 'tools\Test-ReleaseDefender.ps1'
    if (-not (Test-Path -LiteralPath $releaseValidationTool -PathType Leaf)) { throw "Release manifest validator is missing: $releaseValidationTool" }
    . $releaseValidationTool -Library
    Test-CcodReleaseAssetManifest -ManifestPath $releaseManifest -AssetDirectory $dist -ExpectedVersion $Version | Out-Null
} finally {
    if ([IO.Directory]::Exists($stageRoot)) {
        $stageFull = [IO.Path]::GetFullPath($stageRoot)
        $buildFull = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') + '\'
        if ($stageFull.StartsWith($buildFull,[StringComparison]::OrdinalIgnoreCase) -and -not ((Get-Item -LiteralPath $stageFull -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            Remove-Item -LiteralPath $stageFull -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Write-Host ''
Write-Host 'Portable release bundle completed:' -ForegroundColor Green
Write-Host ("  ZIP:      {0}" -f $bundle)
Write-Host ("  SHA-256:  {0}" -f $checksum)
Write-Host ("  Hash:     {0}" -f (Get-CcodBuildFileSha256 -Path $bundle))
Write-Host ("  TrayHost: {0}" -f $provenance)
Write-Host ("  Payload:  {0}" -f $payloadManifestAsset)
Write-Host ("  Manifest: {0}" -f $releaseManifest)
Write-Host ''

# Build the Inno Setup installer from the same verified source tree.
$isccCandidates = @(
    (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
    (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe')
)
$iscc = $isccCandidates | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and [IO.File]::Exists($_) } | Select-Object -First 1
if (-not $iscc) { throw 'Inno Setup 6 (ISCC.exe) was not found. Install it with: winget install --id JRSoftware.InnoSetup --exact' }
$issPath = Join-Path $PSScriptRoot 'CodexControlOtherDevices.iss'
& $iscc "/DProjectVersion=$Version" "/DTrayHostArtifactDirectory=$trayHostArtifact" "/O$dist\." $issPath
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $setupExe -PathType Leaf)) {
    throw "Inno Setup compilation failed with exit code $LASTEXITCODE"
}
$setupHash = Get-CcodBuildFileSha256 -Path $setupExe
Write-CcodBuildUtf8 -Path $setupChecksum -Text ("{0} *{1}" -f $setupHash,[IO.Path]::GetFileName($setupExe))
$setupReleaseManifest = Join-Path $dist "CodexRemote-fix-$Version-setup-release-manifest.json"
$setupRecord = [ordered]@{
    schemaVersion = 1
    product = 'CodexRemote-fix'
    version = $Version
    gitCommit = $gitCommit
    buildTimestampUtc = $buildTimestampUtc
    assets = @(
        [ordered]@{ name = [IO.Path]::GetFileName($setupExe); sha256 = $setupHash },
        [ordered]@{ name = [IO.Path]::GetFileName($setupChecksum); sha256 = Get-CcodBuildFileSha256 -Path $setupChecksum },
        [ordered]@{ name = [IO.Path]::GetFileName($provenance); sha256 = Get-CcodBuildFileSha256 -Path $provenance }
    )
}
Write-CcodBuildUtf8 -Path $setupReleaseManifest -Text (($setupRecord | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
Test-CcodReleaseAssetManifest -ManifestPath $setupReleaseManifest -AssetDirectory $dist -ExpectedVersion $Version | Out-Null

Write-Host ''
Write-Host 'Installer build completed:' -ForegroundColor Green
Write-Host ("  Setup:    {0}" -f $setupExe)
Write-Host ("  SHA-256:  {0}" -f $setupChecksum)
Write-Host ("  Manifest: {0}" -f $setupReleaseManifest)
Write-Host ''
