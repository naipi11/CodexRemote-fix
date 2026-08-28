[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [string]$InstallRoot,
    [switch]$EnableCandidateCompatibleUpdates,
    [switch]$RepairState,
    [switch]$DoNotStart,
    [string]$ActivationId,
    [string]$ExpectedVersion,
    [string]$PayloadManifestPath,
    [string]$ExpectedPayloadManifestSha256
)

$ErrorActionPreference = 'Stop'

function Get-CcodInstallerBytesSha256 {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash($Bytes)).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Open-CcodInstallerLockedBytes {
    param([Parameter(Mandatory)][string]$Path,[int64]$MaximumBytes = 268435456)
    $full = [IO.Path]::GetFullPath($Path)
    $stream = [IO.File]::Open($full,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try {
        if ($stream.Length -lt 0 -or $stream.Length -gt $MaximumBytes) { throw 'CCOD_INSTALL_PAYLOAD_MANIFEST_INVALID' }
        $memory = [IO.MemoryStream]::new()
        try { $stream.CopyTo($memory); $bytes = $memory.ToArray() } finally { $memory.Dispose() }
        return [pscustomobject]@{Path=$full;Stream=$stream;Bytes=$bytes}
    } catch { $stream.Dispose(); throw }
}

function Assert-CcodInstallerPayloadPath {
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$Path)
    $canonicalRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $candidate = [IO.Path]::GetFullPath($Path)
    $prefix = $canonicalRoot + '\'
    if (-not ($candidate.Equals($canonicalRoot,[StringComparison]::OrdinalIgnoreCase) -or $candidate.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase))) {
        throw 'CCOD_INSTALL_PAYLOAD_PATH_INVALID'
    }
    $cursor = $candidate
    while ($true) {
        $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'CCOD_INSTALL_SOURCE_REPARSE' }
        if ($cursor.Equals($canonicalRoot,[StringComparison]::OrdinalIgnoreCase)) { break }
        $cursor = Split-Path $cursor -Parent
    }
    return $candidate
}

function Test-CcodInstallerAlternateDataStreams {
    param([Parameter(Mandatory)][string]$Path)
    try {
        foreach ($stream in @(Get-Item -LiteralPath $Path -Stream * -ErrorAction Stop)) {
            if ([string]$stream.Stream -cnotin @(':$DATA','::$DATA','$DATA')) { return $true }
        }
        return $false
    } catch { throw 'CCOD_INSTALL_PAYLOAD_MANIFEST_INVALID' }
}

function Open-CcodInstallerPayloadSeal {
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$ManifestPath,
        [Parameter(Mandatory)][string]$ExpectedManifestSha256
    )
    if ($Version -cnotmatch '^\d+\.\d+\.\d+$' -or $ExpectedManifestSha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'CCOD_INSTALL_PAYLOAD_VERSION_MISMATCH' }
    $root = [IO.Path]::GetFullPath($SourceRoot).TrimEnd('\')
    [void](Assert-CcodInstallerPayloadPath -Root $root -Path $root)
    $manifestFile = Assert-CcodInstallerPayloadPath -Root $root -Path $ManifestPath
    $locks = [Collections.Generic.List[object]]::new()
    try {
        $manifestLock = Open-CcodInstallerLockedBytes -Path $manifestFile -MaximumBytes 4194304
        $locks.Add($manifestLock)
        if ((Test-CcodInstallerAlternateDataStreams -Path $manifestFile) -or
            (Get-CcodInstallerBytesSha256 -Bytes $manifestLock.Bytes) -cne $ExpectedManifestSha256) { throw 'CCOD_INSTALL_PAYLOAD_MANIFEST_INVALID' }
        try {
            $manifestText = [Text.UTF8Encoding]::new($false,$true).GetString($manifestLock.Bytes)
            $manifest = $manifestText | ConvertFrom-Json -ErrorAction Stop
        } catch { throw 'CCOD_INSTALL_PAYLOAD_MANIFEST_INVALID' }
        $fields = @($manifest.PSObject.Properties.Name)
        if ($manifest -isnot [pscustomobject] -or ($fields -join ',') -cne 'schemaVersion,projectVersion,files' -or
            $manifest.schemaVersion -isnot [int] -or $manifest.schemaVersion -ne 1 -or
            $manifest.projectVersion -isnot [string] -or $manifest.projectVersion -cne $Version) { throw 'CCOD_INSTALL_PAYLOAD_VERSION_MISMATCH' }
        $records = @($manifest.files)
        if ($records.Count -eq 0) { throw 'CCOD_INSTALL_PAYLOAD_MANIFEST_INVALID' }
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $previous = $null
        $packageBytes = $null
        foreach ($record in $records) {
            $recordFields = @($record.PSObject.Properties.Name)
            if ($record -isnot [pscustomobject] -or ($recordFields -join ',') -cne 'path,length,sha256' -or
                $record.path -isnot [string] -or $record.path -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._/-]{0,255}$' -or
                $record.path.Contains('//') -or $record.path.Contains('..') -or $record.path.Contains(':') -or $record.path.Contains('\') -or
                $record.length -isnot [ValueType] -or [decimal]$record.length -ne [decimal][int64]$record.length -or [int64]$record.length -lt 0 -or
                $record.sha256 -isnot [string] -or $record.sha256 -cnotmatch '^[0-9a-f]{64}$' -or
                ($null -ne $previous -and [StringComparer]::Ordinal.Compare([string]$previous,[string]$record.path) -ge 0) -or
                -not $seen.Add([string]$record.path)) { throw 'CCOD_INSTALL_PAYLOAD_MANIFEST_INVALID' }
            $previous = [string]$record.path
            $source = Assert-CcodInstallerPayloadPath -Root $root -Path (Join-Path $root ([string]$record.path).Replace('/','\'))
            $locked = Open-CcodInstallerLockedBytes -Path $source
            $locks.Add($locked)
            $item = Get-Item -LiteralPath $source -Force -ErrorAction Stop
            if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                (Test-CcodInstallerAlternateDataStreams -Path $source) -or [int64]$locked.Bytes.Length -ne [int64]$record.length -or
                (Get-CcodInstallerBytesSha256 -Bytes $locked.Bytes) -cne [string]$record.sha256) { throw 'CCOD_INSTALL_FILE_HASH_MISMATCH' }
            if ([string]$record.path -ceq 'package.json') { $packageBytes = $locked.Bytes }
        }
        foreach ($required in @('package.json','Install-CodexControlOtherDevices.ps1','src/persistence/modules/InstallLifecycle.psm1','src/persistence/modules/RuntimeManifest.psm1')) {
            if (-not $seen.Contains($required)) { throw 'CCOD_INSTALL_PAYLOAD_MANIFEST_INVALID' }
        }
        $actual = [Collections.Generic.List[string]]::new()
        foreach ($item in @(Get-ChildItem -LiteralPath $root -Force -Recurse -ErrorAction Stop)) {
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'CCOD_INSTALL_SOURCE_REPARSE' }
            if ($item.PSIsContainer -or $item.FullName.Equals($manifestFile,[StringComparison]::OrdinalIgnoreCase)) { continue }
            $actual.Add($item.FullName.Substring($root.Length + 1).Replace('\','/'))
        }
        if ($actual.Count -ne $records.Count) { throw 'CCOD_INSTALL_PAYLOAD_MANIFEST_INVALID' }
        foreach ($relative in $actual) { if (-not $seen.Contains($relative)) { throw 'CCOD_INSTALL_PAYLOAD_MANIFEST_INVALID' } }
        try { $package = [Text.UTF8Encoding]::new($false,$true).GetString([byte[]]$packageBytes) | ConvertFrom-Json -ErrorAction Stop }
        catch { throw 'CCOD_INSTALL_PAYLOAD_MANIFEST_INVALID' }
        if ($package.version -isnot [string] -or [string]$package.version -cne $Version) { throw 'CCOD_INSTALL_PAYLOAD_VERSION_MISMATCH' }
        return [pscustomobject]@{ManifestBytes=$manifestLock.Bytes;Locks=@($locks | ForEach-Object {$_.Stream})}
    } catch {
        foreach ($locked in @($locks)) { try { $locked.Stream.Dispose() } catch { } }
        throw
    }
}

function Close-CcodInstallerPayloadSeal {
    param($Seal)
    if ($null -eq $Seal) { return }
    foreach ($stream in @($Seal.Locks)) { if ($null -ne $stream) { try { $stream.Dispose() } catch { } } }
}

function Resolve-CcodInstallerModule {
    param([Parameter(Mandatory)][string]$CheckoutRoot)

    $modulePath = [IO.Path]::GetFullPath((Join-Path $CheckoutRoot 'src\persistence\modules\InstallLifecycle.psm1'))
    if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
        throw [Management.Automation.ErrorRecord]::new(
            [InvalidOperationException]::new('InstallLifecycle.psm1 is missing from this checkout. Run the installer from a complete repository checkout.'),
            'CCOD_INSTALLER_MODULE_MISSING',
            [Management.Automation.ErrorCategory]::ObjectNotFound,
            $modulePath
        )
    }
    return $modulePath
}

if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
    $InstallRoot = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'CodexControlOtherDevices'
}

$payloadBound = -not [string]::IsNullOrWhiteSpace($ExpectedVersion) -or -not [string]::IsNullOrWhiteSpace($PayloadManifestPath) -or -not [string]::IsNullOrWhiteSpace($ExpectedPayloadManifestSha256)
$payloadSeal = $null
$installerModule = $null
try {
    if ($payloadBound) {
        if ([string]::IsNullOrWhiteSpace($ExpectedVersion) -or [string]::IsNullOrWhiteSpace($PayloadManifestPath) -or [string]::IsNullOrWhiteSpace($ExpectedPayloadManifestSha256)) {
            throw 'CCOD_INSTALL_INPUT_INVALID'
        }
        $payloadSeal = Open-CcodInstallerPayloadSeal -SourceRoot $PSScriptRoot -Version $ExpectedVersion -ManifestPath $PayloadManifestPath -ExpectedManifestSha256 $ExpectedPayloadManifestSha256
    }
    $script:InstallerModule = Resolve-CcodInstallerModule -CheckoutRoot $PSScriptRoot
    $installerModule = Import-Module $script:InstallerModule -Force -PassThru
    $invoke = @{
        SourceRoot = $PSScriptRoot
        InstallRoot = $InstallRoot
        EnableCandidateCompatibleUpdates = [bool]$EnableCandidateCompatibleUpdates
        RepairState = [bool]$RepairState
        DoNotStart = [bool]$DoNotStart
        ActivationId = $ActivationId
    }
    if ($payloadBound) {
        $invoke.ExpectedVersion = $ExpectedVersion
        $invoke.PayloadManifestPath = $PayloadManifestPath
        $invoke.ExpectedPayloadManifestSha256 = $ExpectedPayloadManifestSha256
        $invoke.PayloadManifestBytesBase64 = [Convert]::ToBase64String([byte[]]$payloadSeal.ManifestBytes)
    }
    $receipt = Invoke-CcodInstall @invoke
} finally {
    if ($null -ne $installerModule) { Remove-Module -Name $installerModule.Name -Force -ErrorAction SilentlyContinue }
    Close-CcodInstallerPayloadSeal -Seal $payloadSeal
}

Write-Host ''
Write-Host 'CodexRemote-fix - install result' -ForegroundColor Cyan
Write-Host ('  Outcome:          {0}' -f $receipt.Outcome)
if ($receipt.RuntimeId) { Write-Host ('  Runtime ID:       {0}' -f $receipt.RuntimeId) }
if ($receipt.PreviousRuntimeId) { Write-Host ('  Previous runtime: {0}' -f $receipt.PreviousRuntimeId) }
if ($receipt.Outcome -eq 'Repaired') {
    Write-Host '  State was recreated with automation and candidate-compatible updates disabled.' -ForegroundColor Yellow
    Write-Host '  Re-enable them from the tray after confirming the package and Node environment.' -ForegroundColor Yellow
}
Write-Host ''
if ($receipt.Outcome -eq 'Installed' -or $receipt.Outcome -eq 'Upgraded') {
    Write-Host 'The persistent tray supervisor is installed and runs at next logon (or now).' -ForegroundColor Green
    Write-Host 'Open Settings > Connections > Control other devices after starting Codex normally.' -ForegroundColor Green
    Write-Host ''
}
return $receipt
