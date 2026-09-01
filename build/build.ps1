[CmdletBinding()]
param(
    [string]$Version,
    [switch]$UseExistingTrayHost,
    [string]$TrayHostArtifactDirectory,
    [switch]$Library
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

function Assert-CcodBuildInstallerDestinationInventory {
    param([Parameter(Mandatory)][string]$Path)
    $inventoryPath = Assert-CcodBuildRegularFile -Path $Path -Kind 'Installer destination inventory'
    foreach ($line in [IO.File]::ReadAllLines($inventoryPath,[Text.UTF8Encoding]::new($false))) {
        if ($line -match '^\s*\[[^\[\]\r\n]+\]\s*(?:;.*)?$') {
            throw "Installer destination inventory contains an Inno section header: $line"
        }
    }
    return $inventoryPath
}

function Assert-CcodBuildInnoPreprocessorLines {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines,
        [Parameter(Mandatory)][string]$Kind
    )
    $allowedSimpleDirectives = @(
        '#ifndef TrayHostArtifactDirectory',
        '#define TrayHostArtifactDirectory SourcePath + "\generated\trayhost"',
        '#ifndef PortableArtifactDirectory',
        '#define PortableArtifactDirectory SourcePath + "\generated\portable"',
        '#ifndef InstallerPayloadDirectory',
        '#error InstallerPayloadDirectory must be supplied by the release builder',
        '#ifndef InstallerPayloadManifestSha256',
        '#error InstallerPayloadManifestSha256 must be supplied by the release builder',
        '#ifndef ProjectVersion',
        '#error ProjectVersion must be supplied by the release builder',
        '#ifndef InstallerPackagePath',
        '#error InstallerPackagePath must be supplied by the release builder',
        '#ifndef InstallerPackageManifestPath',
        '#error InstallerPackageManifestPath must be supplied by the release builder',
        '#ifndef InstallerPackageSha256',
        '#error InstallerPackageSha256 must be supplied by the release builder',
        '#ifndef InstallerPackageManifestSha256',
        '#error InstallerPackageManifestSha256 must be supplied by the release builder',
        '#define InstallerPackageManifestSha256First Copy(InstallerPackageManifestSha256, 1, 32)',
        '#define InstallerPackageManifestSha256Last Copy(InstallerPackageManifestSha256, 33, 32)',
        '#ifndef ActivationBootstrapPath',
        '#error ActivationBootstrapPath must be supplied by the release builder',
        '#ifndef ActivationBootstrapSha256',
        '#error ActivationBootstrapSha256 must be supplied by the release builder',
        '#define ActivationBootstrapSha256First Copy(ActivationBootstrapSha256, 1, 32)',
        '#define ActivationBootstrapSha256Last Copy(ActivationBootstrapSha256, 33, 32)',
        '#ifndef SetupGitCommit',
        '#error SetupGitCommit must be supplied by the release builder',
        '#ifndef SetupProvenancePath',
        '#error SetupProvenancePath must be supplied by the release builder',
        '#endif'
    )
    $allowedInlineConstructs = @(
        '{#ProjectVersion}',
        '{#TrayHostArtifactDirectory}',
        '{#PortableArtifactDirectory}',
        '{#InstallerPayloadDirectory}',
        '{#InstallerPayloadManifestSha256}',
        '{#InstallerPackagePath}',
        '{#InstallerPackageManifestPath}',
        '{#InstallerPackageSha256}',
        '{#InstallerPackageManifestSha256}',
        '{#InstallerPackageManifestSha256First}',
        '{#InstallerPackageManifestSha256Last}',
        '{#ActivationBootstrapPath}',
        '{#ActivationBootstrapSha256}',
        '{#ActivationBootstrapSha256First}',
        '{#ActivationBootstrapSha256Last}',
        '{#SetupGitCommit}',
        '{#SetupProvenancePath}'
    )
    for ($lineIndex = 0; $lineIndex -lt $Lines.Count; $lineIndex++) {
        $line = [string]$Lines[$lineIndex]
        $lineNumber = $lineIndex + 1
        if ($line -match '\\\s*$') {
            throw "$Kind requires an include-free simple preprocessor source; line continuation is not permitted at line $lineNumber."
        }
        if ($line -match '^\s*#' -and $allowedSimpleDirectives -cnotcontains $line) {
            throw "$Kind requires an include-free exact preprocessor source; unsafe simple directive at line ${lineNumber}: $line"
        }
        $inlineStart = $line.IndexOf('{#',[StringComparison]::Ordinal)
        while ($inlineStart -ge 0) {
            $inlineEnd = $line.IndexOf('}',$inlineStart + 2)
            if ($inlineEnd -lt 0) {
                throw "$Kind contains an unterminated inline preprocessor construct at line $lineNumber."
            }
            $inlineConstruct = $line.Substring($inlineStart,$inlineEnd - $inlineStart + 1)
            if ($allowedInlineConstructs -cnotcontains $inlineConstruct) {
                throw "$Kind contains an unsafe inline preprocessor construct at line ${lineNumber}: $inlineConstruct"
            }
            $inlineStart = $line.IndexOf('{#',$inlineEnd + 1,[StringComparison]::Ordinal)
        }
    }
}

function New-CcodBuildGeneratedInnoScript {
    param(
        [Parameter(Mandatory)][string]$TemplatePath,
        [Parameter(Mandatory)][string]$InventoryPath,
        [Parameter(Mandatory)][string]$OutputPath
    )
    $template = Assert-CcodBuildRegularFile -Path $TemplatePath -Kind 'Inno Setup template'
    $inventory = Assert-CcodBuildInstallerDestinationInventory -Path $InventoryPath
    $output = [IO.Path]::GetFullPath($OutputPath)
    if ([IO.File]::Exists($output) -or [IO.Directory]::Exists($output)) {
        throw "Refusing to overwrite generated Inno Setup script: $output"
    }
    $templateDirectory = [IO.Path]::GetFullPath((Split-Path $template -Parent)).TrimEnd('\')
    $outputDirectory = [IO.Path]::GetFullPath((Split-Path $output -Parent)).TrimEnd('\')
    if (-not $outputDirectory.Equals($templateDirectory,[StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetExtension($output) -cne '.iss') {
        throw 'The generated Inno Setup script must be a sibling .iss file of its template.'
    }

    $marker = '// CCOD_INSTALLER_DESTINATION_INVENTORY'
    $templateSource = [IO.File]::ReadAllText($template,[Text.UTF8Encoding]::new($false))
    Assert-CcodBuildInnoPreprocessorLines -Lines ([IO.File]::ReadAllLines($template,[Text.UTF8Encoding]::new($false))) -Kind 'The Inno Setup template'
    $markerCount = [regex]::Matches($templateSource,[regex]::Escape($marker)).Count
    $markerLineCount = [regex]::Matches($templateSource,'(?m)^\s*// CCOD_INSTALLER_DESTINATION_INVENTORY\s*$').Count
    if ($markerCount -ne 1 -or $markerLineCount -ne 1) {
        throw "The Inno Setup template must contain exactly one inventory marker comment; found $markerCount."
    }

    $inventorySource = [IO.File]::ReadAllText($inventory,[Text.UTF8Encoding]::new($false)).TrimEnd("`r","`n")
    $generatedSource = $templateSource.Replace($marker,$inventorySource)
    if ($generatedSource.Contains($marker)) {
        throw 'The generated Inno Setup script contains an unresolved inventory marker.'
    }
    Assert-CcodBuildInnoPreprocessorLines -Lines ([regex]::Split($generatedSource,'\r\n|\n|\r')) -Kind 'The generated Inno Setup script'

    try {
        Write-CcodBuildUtf8 -Path $output -Text $generatedSource
        $writtenSource = [IO.File]::ReadAllText((Assert-CcodBuildRegularFile -Path $output -Kind 'Generated Inno Setup script'),[Text.UTF8Encoding]::new($false))
        if (-not $writtenSource.Equals($generatedSource,[StringComparison]::Ordinal)) {
            throw 'The generated Inno Setup script changed during write verification.'
        }
        return $output
    } catch {
        if ([IO.File]::Exists($output)) { Remove-Item -LiteralPath $output -Force -ErrorAction SilentlyContinue }
        throw
    }
}

function Invoke-CcodBuildInnoCompiler {
    param(
        [Parameter(Mandatory)][string]$TemplatePath,
        [Parameter(Mandatory)][string]$InventoryPath,
        [Parameter(Mandatory)][string]$IsccPath,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Arguments,
        [Parameter(Mandatory)][string]$SetupPath
    )
    $template = Assert-CcodBuildRegularFile -Path $TemplatePath -Kind 'Inno Setup template'
    $compiler = Assert-CcodBuildRegularFile -Path $IsccPath -Kind 'Inno Setup compiler'
    $setup = [IO.Path]::GetFullPath($SetupPath)
    if ([IO.File]::Exists($setup) -or [IO.Directory]::Exists($setup)) {
        throw "Refusing to compile over an existing setup output: $setup"
    }
    $generatedScriptPath = Join-Path (Split-Path $template -Parent) ('.ccod-generated-setup-' + [guid]::NewGuid().ToString('N') + '.iss')
    try {
        $generatedScript = New-CcodBuildGeneratedInnoScript -TemplatePath $template -InventoryPath $InventoryPath -OutputPath $generatedScriptPath
        $compilerArguments = @($Arguments) + @($generatedScript)
        & $compiler @compilerArguments
        $compilerExitCode = $LASTEXITCODE
        if ($compilerExitCode -ne 0 -or -not (Test-Path -LiteralPath $setup -PathType Leaf)) {
            throw "Inno Setup compilation failed with exit code $compilerExitCode"
        }
    } finally {
        if ([IO.File]::Exists($generatedScriptPath)) {
            $generatedFull = [IO.Path]::GetFullPath($generatedScriptPath)
            $templateDirectory = [IO.Path]::GetFullPath((Split-Path $template -Parent)).TrimEnd('\') + '\'
            $generatedItem = Get-Item -LiteralPath $generatedFull -Force -ErrorAction Stop
            if (-not $generatedFull.StartsWith($templateDirectory,[StringComparison]::OrdinalIgnoreCase) -or
                [IO.Path]::GetFileName($generatedFull) -cnotmatch '^\.ccod-generated-setup-[0-9a-f]{32}\.iss$' -or
                (($generatedItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
                throw "Refusing to clean an unexpected generated Inno Setup path: $generatedFull"
            }
            Remove-Item -LiteralPath $generatedFull -Force -ErrorAction Stop
        }
    }
}

function Remove-CcodBuildTemporarySetupInput {
    param(
        [Parameter(Mandatory)][string]$BuildRoot,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('PayloadDirectory','DestinationInventory')][string]$Kind
    )
    $root = [IO.Path]::GetFullPath($BuildRoot).TrimEnd('\')
    $candidate = [IO.Path]::GetFullPath($Path)
    $parent = [IO.Path]::GetFullPath((Split-Path $candidate -Parent)).TrimEnd('\')
    $leaf = [IO.Path]::GetFileName($candidate)
    $expectedPattern = if ($Kind -ceq 'PayloadDirectory') { '^\.installer-payload-stage-[0-9a-f]{32}$' } else { '^\.installer-destination-inventory-[0-9a-f]{32}\.iss$' }
    if (-not $parent.Equals($root,[StringComparison]::OrdinalIgnoreCase) -or $leaf -cnotmatch $expectedPattern) {
        throw "Refusing to clean an unexpected temporary Setup input: $candidate"
    }
    if ($Kind -ceq 'PayloadDirectory') {
        if (-not [IO.Directory]::Exists($candidate)) { return }
        $rootItem = Get-Item -LiteralPath $candidate -Force -ErrorAction Stop
        if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Refusing to clean a reparse Setup payload stage: $candidate" }
        foreach ($item in @(Get-ChildItem -LiteralPath $candidate -Force -Recurse -ErrorAction Stop)) {
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Refusing to clean a Setup payload stage containing a reparse point: $($item.FullName)" }
        }
        Remove-Item -LiteralPath $candidate -Recurse -Force -ErrorAction Stop
        return
    }
    if (-not [IO.File]::Exists($candidate)) { return }
    $inventory = Get-Item -LiteralPath $candidate -Force -ErrorAction Stop
    if ($inventory.PSIsContainer -or ($inventory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Refusing to clean an unsafe Setup destination inventory: $candidate" }
    Remove-Item -LiteralPath $candidate -Force -ErrorAction Stop
}

function Invoke-CcodBuildTemporarySetupScope {
    param(
        [Parameter(Mandatory)][string]$BuildRoot,
        [Parameter(Mandatory)][string]$InstallerPayloadDirectory,
        [Parameter(Mandatory)][string]$DestinationInventoryPath,
        [Parameter(Mandatory)][scriptblock]$Action
    )
    try { & $Action $InstallerPayloadDirectory $DestinationInventoryPath }
    finally {
        Remove-CcodBuildTemporarySetupInput -BuildRoot $BuildRoot -Path $InstallerPayloadDirectory -Kind PayloadDirectory
        Remove-CcodBuildTemporarySetupInput -BuildRoot $BuildRoot -Path $DestinationInventoryPath -Kind DestinationInventory
    }
}

if ($Library) { return }

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
$setupProvenance = Join-Path $dist "CodexRemote-fix-$Version-setup-provenance.json"
$setupPayloadInput = Join-Path $dist "CodexRemote-fix-$Version-setup-payload-manifest.json"
$setupInventoryInput = Join-Path $dist "CodexRemote-fix-$Version-setup-destination-inventory.iss"
$setupReleaseManifest = Join-Path $dist "CodexRemote-fix-$Version-setup-release-manifest.json"
foreach ($path in @($bundle,$checksum,$provenance,$payloadManifestAsset,$releaseManifest,$setupExe,$setupChecksum,$setupProvenance,$setupPayloadInput,$setupInventoryInput,$setupReleaseManifest)) {
    if ([IO.File]::Exists($path) -or [IO.Directory]::Exists($path)) { throw "Refusing to overwrite immutable release output: $path" }
}

$stageRoot = Join-Path $PSScriptRoot ('.portable-stage-' + [guid]::NewGuid().ToString('N'))
$installerPayloadDirectory = Join-Path $PSScriptRoot ('.installer-payload-stage-' + [guid]::NewGuid().ToString('N'))
$installerDestinationInventoryPath = Join-Path $PSScriptRoot ('.installer-destination-inventory-' + [guid]::NewGuid().ToString('N') + '.iss')
Invoke-CcodBuildTemporarySetupScope -BuildRoot $PSScriptRoot -InstallerPayloadDirectory $installerPayloadDirectory -DestinationInventoryPath $installerDestinationInventoryPath -Action ({
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
        'src/persistence/PortableUninstallFinalizer.ps1',
        'src/persistence/InstalledUninstallFinalizer.ps1'
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
    $portableArtifact = Join-Path $PSScriptRoot 'generated\portable'
    Invoke-CcodPortableLauncherBuild -RepositoryRoot $repoRoot -Version $Version -OutputDirectory $portableArtifact -GitCommit $gitCommit -BuildTimestampUtc $buildTimestampUtc | Out-Null
    Test-CcodPortableLauncherArtifact -RepositoryRoot $repoRoot -Version $Version -ArtifactDirectory $portableArtifact -ExpectedGitCommit $gitCommit | Out-Null
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
    [IO.Directory]::CreateDirectory($installerPayloadDirectory) | Out-Null
    foreach ($record in $payloadRecords) {
        Copy-CcodBuildPayloadFile -Source (Join-Path $payloadRoot ([string]$record.path).Replace('/','\')) -PayloadRoot $installerPayloadDirectory -Relative ([string]$record.path)
    }
    $installerPayloadManifestPath = Join-Path $installerPayloadDirectory 'installer-payload.manifest.json'
    $installerPayloadGenerator = Join-Path $repoRoot 'tools\New-InstallerPayloadManifest.ps1'
    if (-not [IO.File]::Exists($installerPayloadGenerator)) { throw "Installer payload manifest generator is missing: $installerPayloadGenerator" }
    $installerPayloadManifest = & $installerPayloadGenerator -PayloadRoot $installerPayloadDirectory -ProjectVersion $Version -OutputPath $installerPayloadManifestPath
    if (@($installerPayloadManifest.files).Count -ne $payloadRecords.Count) { throw 'Installer payload generator record count differs from the verified portable payload.' }
    for ($recordIndex = 0; $recordIndex -lt $payloadRecords.Count; $recordIndex++) {
        if ([string]$installerPayloadManifest.files[$recordIndex].path -cne [string]$payloadRecords[$recordIndex].path -or
            [int64]$installerPayloadManifest.files[$recordIndex].length -ne [int64]$payloadRecords[$recordIndex].length -or
            [string]$installerPayloadManifest.files[$recordIndex].sha256 -cne [string]$payloadRecords[$recordIndex].sha256) {
            throw 'Installer payload generator records differ from the verified portable payload.'
        }
    }
    $installerPayloadManifestSha256 = Get-CcodBuildFileSha256 -Path $installerPayloadManifestPath
    $installerPackagePath = Join-Path $installerPayloadDirectory 'installer-package.zip'
    $installerPackageManifestPath = Join-Path $installerPayloadDirectory 'installer-package.manifest.json'
    Import-Module (Join-Path $PSScriptRoot 'InstallerPackage.psm1') -Force
    $installerPackage = New-CcodInstallerPackage -PayloadRoot $installerPayloadDirectory -PayloadManifestPath $installerPayloadManifestPath -Version $Version -GitCommit $gitCommit -OutputPath $installerPackagePath -ManifestOutputPath $installerPackageManifestPath
    Test-CcodInstallerPackage -PackagePath $installerPackagePath -ManifestPath $installerPackageManifestPath -ExpectedPackageSha256 $installerPackage.PackageSha256 -ExpectedManifestSha256 $installerPackage.ManifestSha256 -ExpectedVersion $Version -ExpectedGitCommit $gitCommit | Out-Null
    $activationBootstrapPath = Assert-CcodBuildRegularFile -Path (Join-Path $repoRoot 'Activate-CcodRemoteFix.ps1') -Kind 'Activation bootstrap'
    $activationBootstrapSha256 = Get-CcodBuildFileSha256 -Path $activationBootstrapPath
    $destinationInventoryGenerator = Join-Path $repoRoot 'tools\New-InstallerDestinationInventory.ps1'
    if (-not [IO.File]::Exists($destinationInventoryGenerator)) { throw "Installer destination inventory generator is missing: $destinationInventoryGenerator" }
    & $destinationInventoryGenerator -RepositoryRoot $repoRoot -PayloadRoot $installerPayloadDirectory -ProjectVersion $Version -InnoScriptPath (Join-Path $PSScriptRoot 'CodexControlOtherDevices.iss') -OutputPath $installerDestinationInventoryPath | Out-Null
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
Import-Module (Join-Path $PSScriptRoot 'SetupArtifact.psm1') -Force
[IO.File]::Copy((Assert-CcodBuildRegularFile -Path $installerPackageManifestPath -Kind 'Installer package manifest'),$setupPayloadInput,$false)
[IO.File]::Copy((Assert-CcodBuildRegularFile -Path $installerDestinationInventoryPath -Kind 'Installer destination inventory'),$setupInventoryInput,$false)
$setupProvenanceRecord = New-CcodSealedSetupBuildProvenance -Version $Version -GitCommit $gitCommit -BuildTimestampUtc $buildTimestampUtc -PackagePath $installerPackagePath -PackageManifestPath $installerPackageManifestPath -ActivationBootstrapPath $activationBootstrapPath -InnoTemplatePath $issPath -DestinationInventoryPath $installerDestinationInventoryPath -CompilerPath $iscc -OutputPath $setupProvenance
Test-CcodSealedSetupBuildProvenance -ProvenancePath $setupProvenance -ExpectedVersion $Version -ExpectedGitCommit $gitCommit -ExpectedPackageSha256 $installerPackage.PackageSha256 -ExpectedPackageManifestSha256 $installerPackage.ManifestSha256 -ExpectedActivationBootstrapSha256 $activationBootstrapSha256 -ExpectedBuildTimestampUtc $buildTimestampUtc -PackagePath $installerPackagePath -PackageManifestPath $installerPackageManifestPath -ActivationBootstrapPath $activationBootstrapPath -InnoTemplatePath $issPath -DestinationInventoryPath $installerDestinationInventoryPath -CompilerPath $iscc | Out-Null
$isccArguments = @(
    "/DProjectVersion=$Version",
    "/DInstallerPackagePath=$installerPackagePath",
    "/DInstallerPackageManifestPath=$installerPackageManifestPath",
    "/DInstallerPackageSha256=$($installerPackage.PackageSha256)",
    "/DInstallerPackageManifestSha256=$($installerPackage.ManifestSha256)",
    "/DActivationBootstrapPath=$activationBootstrapPath",
    "/DActivationBootstrapSha256=$activationBootstrapSha256",
    "/DSetupGitCommit=$gitCommit",
    "/DSetupProvenancePath=$setupProvenance",
    "/O$dist\."
)
Invoke-CcodBuildInnoCompiler -TemplatePath $issPath -InventoryPath $installerDestinationInventoryPath -IsccPath $iscc -Arguments $isccArguments -SetupPath $setupExe
$setupValidation = Test-CcodSetupArtifact -SetupPath $setupExe -ExpectedVersion $Version -ExpectedGitCommit $gitCommit -ExpectedPackageSha256 $installerPackage.PackageSha256 -ExpectedPackageManifestSha256 $installerPackage.ManifestSha256 -ExpectedActivationBootstrapSha256 $activationBootstrapSha256
$setupHash = [string]$setupValidation.Sha256
Write-CcodBuildUtf8 -Path $setupChecksum -Text ("{0} *{1}" -f $setupHash,[IO.Path]::GetFileName($setupExe))
$setupRecord = [ordered]@{
    schemaVersion = 1
    product = 'CodexRemote-fix'
    version = $Version
    gitCommit = $gitCommit
    buildTimestampUtc = $buildTimestampUtc
    assets = @(
        [ordered]@{ name = [IO.Path]::GetFileName($setupExe); sha256 = $setupHash },
        [ordered]@{ name = [IO.Path]::GetFileName($setupChecksum); sha256 = Get-CcodBuildFileSha256 -Path $setupChecksum },
        [ordered]@{ name = [IO.Path]::GetFileName($provenance); sha256 = Get-CcodBuildFileSha256 -Path $provenance },
        [ordered]@{ name = [IO.Path]::GetFileName($setupProvenance); sha256 = Get-CcodBuildFileSha256 -Path $setupProvenance },
        [ordered]@{ name = [IO.Path]::GetFileName($setupPayloadInput); sha256 = Get-CcodBuildFileSha256 -Path $setupPayloadInput },
        [ordered]@{ name = [IO.Path]::GetFileName($setupInventoryInput); sha256 = Get-CcodBuildFileSha256 -Path $setupInventoryInput }
    )
}
Write-CcodBuildUtf8 -Path $setupReleaseManifest -Text (($setupRecord | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
Test-CcodReleaseAssetManifest -ManifestPath $setupReleaseManifest -AssetDirectory $dist -ExpectedVersion $Version | Out-Null

Write-Host ''
Write-Host 'Installer build completed:' -ForegroundColor Green
Write-Host ("  Setup:    {0}" -f $setupExe)
Write-Host ("  SHA-256:  {0}" -f $setupChecksum)
Write-Host ("  Provenance: {0}" -f $setupProvenance)
Write-Host ("  Manifest: {0}" -f $setupReleaseManifest)
Write-Host ''
}.GetNewClosure())
