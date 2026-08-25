[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [switch]$EnableCandidateCompatibleUpdates,
    [switch]$DoNotStart
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Throw-CcodPortableInstallerError {
    param([Parameter(Mandatory)][string]$Id,[Parameter(Mandatory)][string]$Message,$Target)
    throw [Management.Automation.ErrorRecord]::new(
        [InvalidOperationException]::new($Message),$Id,[Management.Automation.ErrorCategory]::InvalidData,$Target)
}

function Assert-CcodPortableInstallerPlainDirectory {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Kind)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathRooted($Path)) {
        Throw-CcodPortableInstallerError 'CCOD_PORTABLE_INSTALLER_PATH_INVALID' "$Kind must be an absolute path" $Path
    }
    try {
        $full = [IO.Path]::GetFullPath($Path)
        $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    } catch {
        Throw-CcodPortableInstallerError 'CCOD_PORTABLE_INSTALLER_PATH_INVALID' "$Kind is missing or inaccessible" $Path
    }
    if (-not $item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        Throw-CcodPortableInstallerError 'CCOD_PORTABLE_INSTALLER_PATH_INVALID' "$Kind must be a plain directory" $full
    }
    return $full
}

function Assert-CcodPortableInstallerRegularFile {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Kind)
    try {
        $full = [IO.Path]::GetFullPath($Path)
        $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    } catch {
        Throw-CcodPortableInstallerError 'CCOD_PORTABLE_INSTALLER_PATH_INVALID' "$Kind is missing or inaccessible" $Path
    }
    if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        Throw-CcodPortableInstallerError 'CCOD_PORTABLE_INSTALLER_PATH_INVALID' "$Kind must be a regular non-reparse file" $full
    }
    return $full
}

function Get-CcodPortableInstallerDetectionKeys {
    param($Records)
    $keys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($record in @($Records)) {
        if ($null -eq $record) { continue }
        $threat = if ($null -ne $record.PSObject.Properties['ThreatID']) { [string]$record.ThreatID } else { '' }
        $time = if ($null -ne $record.PSObject.Properties['InitialDetectionTime']) { [string]$record.InitialDetectionTime } else { '' }
        $resources = if ($null -ne $record.PSObject.Properties['Resources']) { (@($record.Resources) -join '|') } else { '' }
        if (-not [string]::IsNullOrWhiteSpace($threat) -or -not [string]::IsNullOrWhiteSpace($time) -or -not [string]::IsNullOrWhiteSpace($resources)) {
            [void]$keys.Add("$threat|$time|$resources")
        }
    }
    return $keys
}

function Invoke-CcodPortableInstallerDefenderGate {
    param([Parameter(Mandatory)][string]$PayloadRoot)
    try {
        $status = Get-MpComputerStatus -ErrorAction Stop
        if ($null -eq $status -or $null -eq $status.PSObject.Properties['AMProductVersion'] -or
            $null -eq $status.PSObject.Properties['AntivirusSignatureVersion'] -or
            $status.AMProductVersion -isnot [string] -or [string]::IsNullOrWhiteSpace($status.AMProductVersion) -or
            $status.AntivirusSignatureVersion -isnot [string] -or [string]::IsNullOrWhiteSpace($status.AntivirusSignatureVersion) -or
            $null -eq $status.PSObject.Properties['RealTimeProtectionEnabled'] -or $status.RealTimeProtectionEnabled -isnot [bool] -or
            -not $status.RealTimeProtectionEnabled) {
            throw 'Defender status is incomplete or real-time protection is not enabled.'
        }
        $before = Get-CcodPortableInstallerDetectionKeys -Records @(Get-MpThreatDetection -ErrorAction Stop)
        $started = [DateTime]::UtcNow
        $scanError = $null
        try { Start-MpScan -ScanType CustomScan -ScanPath $PayloadRoot -ErrorAction Stop }
        catch { $scanError = $_ }
        $completed = [DateTime]::UtcNow
        $after = Get-CcodPortableInstallerDetectionKeys -Records @(Get-MpThreatDetection -ErrorAction Stop)
        $newDetections = @($after | Where-Object { -not $before.Contains($_) })
        if ($null -ne $scanError) {
            Throw-CcodPortableInstallerError 'CCOD_PORTABLE_DEFENDER_SCAN_FAILED' 'Microsoft Defender could not complete the portable payload scan.' $scanError
        }
        if ($newDetections.Count -ne 0) {
            Throw-CcodPortableInstallerError 'CCOD_PORTABLE_DEFENDER_DETECTIONS_FOUND' 'Microsoft Defender reported a new detection while scanning the portable payload.' $newDetections.Count
        }
        if (-not [IO.Directory]::Exists($PayloadRoot)) {
            Throw-CcodPortableInstallerError 'CCOD_PORTABLE_DEFENDER_DETECTIONS_FOUND' 'The portable payload disappeared during its Defender scan.' $PayloadRoot
        }
        return [pscustomobject][ordered]@{
            defenderPlatformVersion = [string]$status.AMProductVersion
            signatureVersion = [string]$status.AntivirusSignatureVersion
            scanStartedAtUtc = $started.ToString('o',[Globalization.CultureInfo]::InvariantCulture)
            scanCompletedAtUtc = $completed.ToString('o',[Globalization.CultureInfo]::InvariantCulture)
        }
    } catch {
        if ($_.FullyQualifiedErrorId -match '^CCOD_PORTABLE_') { throw }
        Throw-CcodPortableInstallerError 'CCOD_PORTABLE_DEFENDER_STATUS_INVALID' 'Microsoft Defender status or detection history could not be verified.' $_
    }
}

function Get-CcodPortableInstallerActiveRuntime {
    param([Parameter(Mandatory)][string]$InstallRoot,[Parameter(Mandatory)][string]$ExpectedRuntimeId)
    $activePath = Join-Path $InstallRoot 'active.json'
    $activeFile = Assert-CcodPortableInstallerRegularFile -Path $activePath -Kind 'Active runtime pointer'
    try { $active = [IO.File]::ReadAllText($activeFile,[Text.UTF8Encoding]::new($false,$true)) | ConvertFrom-Json -ErrorAction Stop }
    catch { Throw-CcodPortableInstallerError 'CCOD_PORTABLE_INSTALL_RECEIPT_INVALID' 'The installed active runtime pointer is malformed.' $activeFile }
    $fields = @($active.PSObject.Properties.Name)
    $expectedFields = @('schemaVersion','activeRuntime','previousRuntime','generation','updatedAtUtc')
    if (($fields.Count -ne $expectedFields.Count) -or (($fields | Sort-Object) -join '|') -cne (($expectedFields | Sort-Object) -join '|') -or
        ($active.schemaVersion -isnot [int] -and $active.schemaVersion -isnot [long]) -or [int]$active.schemaVersion -ne 2 -or
        $active.activeRuntime -isnot [string] -or $active.activeRuntime -cne $ExpectedRuntimeId) {
        Throw-CcodPortableInstallerError 'CCOD_PORTABLE_INSTALL_RECEIPT_INVALID' 'The installed active runtime pointer does not bind the installation receipt.' $activeFile
    }
    try {
        $generation = [uint64]$active.generation
        if ($generation -lt 1) { throw 'generation must be positive' }
    } catch {
        Throw-CcodPortableInstallerError 'CCOD_PORTABLE_INSTALL_RECEIPT_INVALID' 'The installed active runtime generation is invalid.' $activeFile
    }
    return [pscustomobject][ordered]@{ RuntimeId=$active.activeRuntime; Generation=$generation }
}

$bundleRoot = Assert-CcodPortableInstallerPlainDirectory -Path $PSScriptRoot -Kind 'Portable bundle root'
$payloadRoot = Assert-CcodPortableInstallerPlainDirectory -Path (Join-Path $bundleRoot 'payload') -Kind 'Portable payload root'
$payloadManifestPath = Assert-CcodPortableInstallerRegularFile -Path (Join-Path $bundleRoot 'payload-manifest.json') -Kind 'Portable payload manifest'
$portableModulePath = Assert-CcodPortableInstallerRegularFile -Path (Join-Path $payloadRoot 'src\persistence\modules\PortableRelease.psm1') -Kind 'Portable release module'
$packagePath = Assert-CcodPortableInstallerRegularFile -Path (Join-Path $payloadRoot 'package.json') -Kind 'Portable package metadata'

Import-Module $portableModulePath -Force -ErrorAction Stop
try { $package = [IO.File]::ReadAllText($packagePath,[Text.UTF8Encoding]::new($false,$true)) | ConvertFrom-Json -ErrorAction Stop }
catch { Throw-CcodPortableInstallerError 'CCOD_PORTABLE_MANIFEST_INVALID' 'Portable package metadata is malformed.' $packagePath }
if ($null -eq $package -or $package.version -isnot [string] -or $package.version -cnotmatch '^\d+\.\d+\.\d+$') {
    Throw-CcodPortableInstallerError 'CCOD_PORTABLE_MANIFEST_INVALID' 'Portable package metadata has no valid version.' $packagePath
}

$payload = Test-CcodPortablePayloadManifest -PayloadRoot $payloadRoot -ManifestPath $payloadManifestPath -ExpectedVersion $package.version
$defender = Invoke-CcodPortableInstallerDefenderGate -PayloadRoot $payloadRoot
Test-CcodPortablePayloadManifest -PayloadRoot $payloadRoot -ManifestPath $payloadManifestPath -ExpectedVersion $package.version -ExpectedGitCommit $payload.GitCommit | Out-Null

$localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
if ([string]::IsNullOrWhiteSpace($localAppData) -or -not [IO.Path]::IsPathRooted($localAppData)) {
    Throw-CcodPortableInstallerError 'CCOD_PORTABLE_INSTALLER_PATH_INVALID' 'Local application data is unavailable.' $localAppData
}
$installRoot = [IO.Path]::GetFullPath((Join-Path $localAppData 'CodexControlOtherDevices'))
if (-not $PSCmdlet.ShouldProcess($installRoot,'Install the verified CodexRemote-fix portable payload for the current user')) {
    return [pscustomobject][ordered]@{ Outcome='WhatIf'; KeptDeviceKeyStore=$true }
}

$copied = Copy-CcodPortablePayload -PayloadRoot $payloadRoot -ManifestPath $payloadManifestPath
$installerPath = Assert-CcodPortableInstallerRegularFile -Path (Join-Path $copied.InstallerRoot 'Install-CodexControlOtherDevices.ps1') -Kind 'Installed lifecycle installer'
try {
    $installReceipt = & $installerPath -InstallRoot $installRoot -EnableCandidateCompatibleUpdates:([bool]$EnableCandidateCompatibleUpdates) -DoNotStart:([bool]$DoNotStart)
} catch {
    Throw-CcodPortableInstallerError 'CCOD_PORTABLE_INSTALL_FAILED' 'The verified portable payload could not activate the protected runtime.' $_
}
if ($null -eq $installReceipt -or $installReceipt.RuntimeId -isnot [string] -or [string]::IsNullOrWhiteSpace($installReceipt.RuntimeId) -or
    $installReceipt.Outcome -isnot [string] -or $installReceipt.Outcome -notin @('Installed','Upgraded')) {
    Throw-CcodPortableInstallerError 'CCOD_PORTABLE_INSTALL_RECEIPT_INVALID' 'The lifecycle installer did not return a successful portable installation receipt.' $installReceipt
}
$active = Get-CcodPortableInstallerActiveRuntime -InstallRoot $installRoot -ExpectedRuntimeId $installReceipt.RuntimeId
Write-CcodPortableInstalledMarker -InstallerRoot $copied.InstallerRoot -Manifest $copied.Manifest -RuntimeId $active.RuntimeId -Generation $active.Generation | Out-Null

return [pscustomobject][ordered]@{
    Outcome = [string]$installReceipt.Outcome
    Version = [string]$payload.Version
    RuntimeId = [string]$active.RuntimeId
    Generation = [uint64]$active.Generation
    InstallerRoot = [string]$copied.InstallerRoot
    Defender = $defender
    KeptDeviceKeyStore = $true
}
