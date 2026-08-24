Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'PersistenceIO.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'RuntimeManifest.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'LifecycleEpoch.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'StateStore.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ScheduledTask.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'KernelObjects.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'CompatibilityProbe.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'UiPreferences.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'LifecycleTransaction.psm1') -Force

$script:CcodLifecycleTaskName = 'Codex Control Other Devices Supervisor'
$script:CcodLifecycleDefaultInstallRoot = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'CodexControlOtherDevices'
$script:CcodActivationReceiptFields = @('schemaVersion','activationId','phase','runtimeId','previousRuntimeId','startedAtUtc','updatedAtUtc','ready','errorCode')
$script:CcodActivationPhases = @('StoppingPreviousRuntime','InstallingRuntime','ActivatingRuntime','StartingProtection','Ready','Failed')

function Throw-CcodLifecycleError {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Message,
        $Target
    )

    throw [Management.Automation.ErrorRecord]::new(
        [InvalidOperationException]::new($Message),
        $Id,
        [Management.Automation.ErrorCategory]::InvalidData,
        $Target
    )
}

function Get-CcodLifecycleErrorId {
    param($ErrorRecord)
    return ([string]$ErrorRecord.FullyQualifiedErrorId -split ',')[0]
}

function Test-CcodActivationExactProperties {
    param($Value)
    if ($null -eq $Value -or $Value -isnot [pscustomobject]) { return $false }
    $actual = @($Value.PSObject.Properties.Name)
    if ($actual.Count -ne $script:CcodActivationReceiptFields.Count) { return $false }
    for ($index = 0; $index -lt $actual.Count; $index++) {
        if ($actual[$index] -cne $script:CcodActivationReceiptFields[$index]) { return $false }
    }
    return $true
}

function Test-CcodLifecycleCanonicalGuid {
    param($Value)
    $parsed = [guid]::Empty
    return $Value -is [string] -and [guid]::TryParseExact($Value, 'D', [ref]$parsed) -and $parsed.ToString('D') -ceq $Value
}

function Assert-CcodActivationReceipt {
    param($Receipt)
    if (-not (Test-CcodActivationExactProperties $Receipt) -or
        $Receipt.schemaVersion -isnot [int] -or $Receipt.schemaVersion -ne 1 -or
        $Receipt.activationId -isnot [string] -or $Receipt.activationId -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' -or
        $Receipt.phase -isnot [string] -or $script:CcodActivationPhases -cnotcontains $Receipt.phase -or
        ($null -ne $Receipt.runtimeId -and ($Receipt.runtimeId -isnot [string] -or $Receipt.runtimeId -cnotmatch '^[A-Za-z0-9._-]{1,96}$')) -or
        ($null -ne $Receipt.previousRuntimeId -and ($Receipt.previousRuntimeId -isnot [string] -or $Receipt.previousRuntimeId -cnotmatch '^[A-Za-z0-9._-]{1,96}$')) -or
        $Receipt.startedAtUtc -isnot [string] -or $Receipt.updatedAtUtc -isnot [string] -or
        $Receipt.ready -isnot [bool] -or
        (($Receipt.phase -ceq 'Ready') -ne [bool]$Receipt.ready) -or
        (($Receipt.phase -ceq 'Failed') -and ($Receipt.errorCode -isnot [string] -or $Receipt.errorCode -cnotmatch '^CCOD_[A-Z0-9_]{1,96}$')) -or
        (($Receipt.phase -cne 'Failed') -and $null -ne $Receipt.errorCode)) {
        Throw-CcodLifecycleError 'CCOD_INSTALL_ACTIVATION_RECEIPT_INVALID' 'Activation receipt contract is invalid' $null
    }
    try {
        $started = [DateTime]::ParseExact($Receipt.startedAtUtc, 'o', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
        $updated = [DateTime]::ParseExact($Receipt.updatedAtUtc, 'o', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
        if ($updated -lt $started) { throw 'timestamp order' }
    } catch {
        Throw-CcodLifecycleError 'CCOD_INSTALL_ACTIVATION_RECEIPT_INVALID' 'Activation receipt timestamps are invalid' $null
    }
    return $true
}

function Write-CcodActivationReceiptFile {
    param([Parameter(Mandatory)][string]$InstallRoot, [Parameter(Mandatory)]$Receipt)
    [void](Assert-CcodActivationReceipt $Receipt)
    $stateRoot = Join-Path $InstallRoot 'state'
    [IO.Directory]::CreateDirectory($stateRoot) | Out-Null
    Write-CcodAtomicJson -Path (Join-Path $stateRoot 'post-install-activation.json') -Value $Receipt
}

function Write-CcodInstallActivationPhase {
    param(
        [Parameter(Mandatory)]$Activation,
        [Parameter(Mandatory)][string]$Phase,
        [AllowNull()]$RuntimeId,
        [AllowNull()]$PreviousRuntimeId,
        [AllowNull()]$ErrorCode,
        [Parameter(Mandatory)][hashtable]$Adapters,
        [Parameter(Mandatory)][string]$InstallRoot
    )
    $now = & $Adapters.UtcNow
    if ($now -isnot [DateTime]) { Throw-CcodLifecycleError 'CCOD_INSTALL_CLOCK_INVALID' 'Activation clock must return DateTime' $null }
    $receipt = [pscustomobject][ordered]@{
        schemaVersion = 1
        activationId = [string]$Activation.ActivationId
        phase = $Phase
        runtimeId = $RuntimeId
        previousRuntimeId = $PreviousRuntimeId
        startedAtUtc = [string]$Activation.StartedAtUtc
        updatedAtUtc = $now.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        ready = [bool]($Phase -ceq 'Ready')
        errorCode = $ErrorCode
    }
    [void](Assert-CcodActivationReceipt $receipt)
    try { & $Adapters.WriteActivationReceipt $InstallRoot $receipt }
    catch { Throw-CcodLifecycleError 'CCOD_INSTALL_ACTIVATION_RECEIPT_FAILED' 'Activation receipt could not be persisted' $null }
    $Activation.LastPhase = $Phase
    return $receipt
}

function Get-CcodLifecycleCanonicalRoot {
    param([Parameter(Mandatory)][string]$Path, [string]$Kind)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathRooted($Path)) {
        Throw-CcodLifecycleError 'CCOD_INSTALL_INPUT_INVALID' "$Kind must be an absolute path" $Path
    }
    try { $root = [IO.Path]::GetFullPath($Path) } catch {
        Throw-CcodLifecycleError 'CCOD_INSTALL_INPUT_INVALID' "$Kind could not be canonicalized" $Path
    }
    if ($root.Length -eq 3 -and $root[1] -eq ':') {
        return $root
    }
    return $root.TrimEnd('\')
}

function Test-CcodLifecycleReparse {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    return (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Get-CcodLifecycleFileSha256 {
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

function Test-CcodLifecycleAlternateDataStreams {
    param([Parameter(Mandatory)][string]$Path)

    try {
        if ($null -eq ('CcodLifecycleStreamNative' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class CcodLifecycleStreamNative
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct WIN32_FIND_STREAM_DATA
    {
        public long StreamSize;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 296)]
        public string StreamName;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr FindFirstStreamW(string path, int infoLevel, out WIN32_FIND_STREAM_DATA streamData, int flags);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool FindNextStreamW(IntPtr handle, out WIN32_FIND_STREAM_DATA streamData);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool FindClose(IntPtr handle);
}
'@
        }
        $streamData = New-Object CcodLifecycleStreamNative+WIN32_FIND_STREAM_DATA
        $handle = [CcodLifecycleStreamNative]::FindFirstStreamW($Path, 0, [ref]$streamData, 0)
        if ($handle -eq [IntPtr](-1)) {
            $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            if ($errorCode -eq 38) { return $false }
            throw [ComponentModel.Win32Exception]::new($errorCode)
        }
        try {
            while ($true) {
                if ($streamData.StreamName -cne '::$DATA') { return $true }
                $streamData = New-Object CcodLifecycleStreamNative+WIN32_FIND_STREAM_DATA
                if (-not [CcodLifecycleStreamNative]::FindNextStreamW($handle, [ref]$streamData)) {
                    $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
                    if ($errorCode -eq 38) { break }
                    throw [ComponentModel.Win32Exception]::new($errorCode)
                }
            }
        } finally {
            [CcodLifecycleStreamNative]::FindClose($handle) | Out-Null
        }
    } catch {
        Throw-CcodLifecycleError 'CCOD_INSTALL_SOURCE_INCOMPLETE' 'Unable to inspect source alternate data streams.' $Path
    }
    return $false
}

function Test-CcodLifecycleRemovePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Path
    )

    $root = Get-CcodLifecycleCanonicalRoot -Path $Root -Kind 'Install root'
    $candidate = [IO.Path]::GetFullPath($Path)
    $prefix = $root.TrimEnd('\') + '\'
    if (-not $candidate.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        Throw-CcodLifecycleError 'CCOD_INSTALL_PATH_OUTSIDE_ROOT' 'Refusing to remove a path outside the install root' $candidate
    }
    if (Test-CcodLifecycleReparse -Path $root) {
        Throw-CcodLifecycleError 'CCOD_INSTALL_REPARSE_PATH' 'Install root is a reparse point' $root
    }
    $relative = $candidate.Substring($prefix.Length)
    $cursor = $root
    foreach ($segment in ($relative -split '\\' | Where-Object { $_.Length -gt 0 })) {
        $cursor = Join-Path $cursor $segment
        if (-not (Test-Path -LiteralPath $cursor)) { break }
        if (Test-CcodLifecycleReparse -Path $cursor) {
            Throw-CcodLifecycleError 'CCOD_INSTALL_REPARSE_PATH' 'Refusing to remove a path through a reparse point' $cursor
        }
    }
    return $true
}

function Get-CcodLifecycleSourceFiles {
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [switch]$RequireTrayHost
    )

    $root = Get-CcodLifecycleCanonicalRoot -Path $SourceRoot -Kind 'Source root'
    if (-not [IO.Directory]::Exists($root)) {
        Throw-CcodLifecycleError 'CCOD_INSTALL_SOURCE_MISSING' 'Source checkout does not exist' $root
    }
    if (Test-CcodLifecycleReparse -Path $root) {
        Throw-CcodLifecycleError 'CCOD_INSTALL_SOURCE_REPARSE' 'Source root is a reparse point' $root
    }
    $relative = [System.Collections.Generic.List[string]]::new()
    $required = @(
        'src\check-package.mjs',
        'src\persistence\Supervisor.ps1',
        'src\persistence\SessionController.ps1',
        'src\persistence\StaticProbeWorker.ps1',
        'src\persistence\LifecycleWorker.ps1',
        'Test-CodexControlOtherDevices.ps1',
        'Start-CodexControlOtherDevices.ps1',
        'Reset-CodexControlOtherDevices.ps1'
    )
    foreach ($leaf in $required) { $relative.Add($leaf) }
    $trayHostRoot = Join-Path $root 'bin'
    if ([IO.Directory]::Exists($trayHostRoot)) {
        $expectedTrayHost = @('CodexRemote.TrayHost.exe','CodexRemote.TrayHost.exe.config','trayhost-build-provenance.json')
        $actualTrayHost = @(Get-ChildItem -LiteralPath $trayHostRoot -Force -ErrorAction Stop)
        if (@($actualTrayHost | Where-Object { $_.PSIsContainer -or $expectedTrayHost -cnotcontains $_.Name }).Count -gt 0 -or
            (@($actualTrayHost.Name | Sort-Object) -join ',') -cne (@($expectedTrayHost | Sort-Object) -join ',')) {
            Throw-CcodLifecycleError 'CCOD_INSTALL_SOURCE_INCOMPLETE' 'TrayHost artifact set is incomplete or contains unknown files.' $trayHostRoot
        }
        foreach ($trayFile in $actualTrayHost) {
            $trayReparse = Test-CcodLifecycleReparse -Path $trayFile.FullName
            $trayAds = Test-CcodLifecycleAlternateDataStreams -Path $trayFile.FullName
            if ($trayReparse -or $trayAds) {
                Throw-CcodLifecycleError 'CCOD_INSTALL_SOURCE_REPARSE' 'TrayHost artifact is a reparse point or has alternate data streams.' $trayFile.FullName
            }
            $relative.Add('bin\' + $trayFile.Name)
        }
    } elseif ($RequireTrayHost) {
        Throw-CcodLifecycleError 'CCOD_INSTALL_SOURCE_INCOMPLETE' 'TrayHost artifact directory is missing.' $trayHostRoot
    }
    $runtimeRoot = Join-Path $root 'src\runtime'
    foreach ($item in Get-ChildItem -LiteralPath $runtimeRoot -Force -Recurse -ErrorAction Stop) {
        if (Test-CcodLifecycleReparse -Path $item.FullName) {
            Throw-CcodLifecycleError 'CCOD_INSTALL_SOURCE_REPARSE' 'Source runtime contains a reparse point' $item.FullName
        }
        if (-not $item.PSIsContainer) {
            $relative.Add('src\runtime\' + $item.FullName.Substring($runtimeRoot.TrimEnd('\').Length + 1))
        }
    }
    foreach ($module in Get-ChildItem -LiteralPath (Join-Path $root 'src\persistence\modules') -Filter '*.psm1' -File -Force -ErrorAction Stop) {
        if (Test-CcodLifecycleReparse -Path $module.FullName) {
            Throw-CcodLifecycleError 'CCOD_INSTALL_SOURCE_REPARSE' 'Source module is a reparse point' $module.FullName
        }
        $relative.Add('src\persistence\modules\' + $module.Name)
    }
    $resourcesRoot = Join-Path $root 'src\persistence\resources'
    if (-not [IO.Directory]::Exists($resourcesRoot)) {
        Throw-CcodLifecycleError 'CCOD_INSTALL_SOURCE_INCOMPLETE' 'UI resource directory is missing.' $resourcesRoot
    }
    if (Test-CcodLifecycleReparse -Path $resourcesRoot) {
        Throw-CcodLifecycleError 'CCOD_INSTALL_SOURCE_REPARSE' 'UI resource directory is a reparse point.' $resourcesRoot
    }
    if (Test-CcodLifecycleAlternateDataStreams -Path $resourcesRoot) {
        Throw-CcodLifecycleError 'CCOD_INSTALL_SOURCE_INCOMPLETE' 'UI resource directory contains alternate data streams.' $resourcesRoot
    }
    $expectedResources = @('ui.en-US.json', 'ui.zh-CN.json')
    $resourceEntries = @(Get-ChildItem -LiteralPath $resourcesRoot -Force -ErrorAction Stop)
    $resourceNames = [Collections.Generic.List[string]]::new()
    foreach ($resourceEntry in $resourceEntries) {
        if (($resourceEntry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            Throw-CcodLifecycleError 'CCOD_INSTALL_SOURCE_REPARSE' 'UI resource is a reparse point.' $resourceEntry.FullName
        }
        if ($resourceEntry.PSIsContainer -or $expectedResources -cnotcontains $resourceEntry.Name) {
            Throw-CcodLifecycleError 'CCOD_INSTALL_SOURCE_INCOMPLETE' 'The UI resource set is incomplete or contains unknown files.' $resourceEntry.FullName
        }
        if (Test-CcodLifecycleAlternateDataStreams -Path $resourceEntry.FullName) {
            Throw-CcodLifecycleError 'CCOD_INSTALL_SOURCE_INCOMPLETE' 'UI resource contains alternate data streams.' $resourceEntry.FullName
        }
        $resourceNames.Add($resourceEntry.Name)
        $relative.Add(('src\persistence\resources\' + $resourceEntry.Name))
    }
    if ((@($resourceNames | Sort-Object) -join ',') -cne (@($expectedResources | Sort-Object) -join ',')) {
        Throw-CcodLifecycleError 'CCOD_INSTALL_SOURCE_INCOMPLETE' 'The UI resource set is incomplete or contains unknown files.' $resourcesRoot
    }
    $uninstaller = Join-Path $root 'Uninstall-CodexControlOtherDevices.ps1'
    if ([IO.File]::Exists($uninstaller) -and -not (Test-CcodLifecycleReparse -Path $uninstaller)) {
        $relative.Add('Uninstall-CodexControlOtherDevices.ps1')
    }
    $unique = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $files = [System.Collections.Generic.List[object]]::new()
    foreach ($leaf in $relative) {
        if (-not $unique.Add($leaf)) { continue }
        $source = [IO.Path]::GetFullPath((Join-Path $root $leaf))
        $prefix = $root.TrimEnd('\') + '\'
        if (-not $source.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or -not [IO.File]::Exists($source)) {
            Throw-CcodLifecycleError 'CCOD_INSTALL_SOURCE_INCOMPLETE' "Required source file is missing: $leaf" $source
        }
        if (Test-CcodLifecycleReparse -Path $source) {
            Throw-CcodLifecycleError 'CCOD_INSTALL_SOURCE_REPARSE' 'Source file is a reparse point' $source
        }
        $files.Add([pscustomobject][ordered]@{ Relative = $leaf; Source = $source })
    }
    return @($files)
}

function Copy-CcodLifecycleStaging {
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][hashtable]$Adapters,
        [Parameter(Mandatory)][object[]]$Files
    )

    $stagingRoot = [IO.Path]::GetFullPath((Join-Path $InstallRoot '.staging'))
    [IO.Directory]::CreateDirectory($stagingRoot) | Out-Null
    $stagingDirectory = Join-Path $stagingRoot ([guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($stagingDirectory) | Out-Null
    $bootstrapPath = Join-Path $InstallRoot 'bootstrap.ps1'
    $uninstallerPath = Join-Path $InstallRoot 'Uninstall-CodexControlOtherDevices.ps1'
    $bootstrapExistedBefore = [IO.File]::Exists($bootstrapPath)
    $uninstallerExistedBefore = [IO.File]::Exists($uninstallerPath)
    $copiedStableBootstrap = $false
    $copiedStableUninstaller = $false
    try {
        $resourcesRoot = Join-Path $SourceRoot 'src\persistence\resources'
        if (Test-CcodLifecycleReparse -Path $resourcesRoot) {
            Throw-CcodLifecycleError 'CCOD_INSTALL_SOURCE_REPARSE' 'UI resource directory became a reparse point before staging.' $resourcesRoot
        }
        if (Test-CcodLifecycleAlternateDataStreams -Path $resourcesRoot) {
            Throw-CcodLifecycleError 'CCOD_INSTALL_SOURCE_INCOMPLETE' 'UI resource directory contains alternate data streams before staging.' $resourcesRoot
        }
        foreach ($resourceFile in @($Files | Where-Object { $_.Relative -like 'src\persistence\resources\*' })) {
            if (Test-CcodLifecycleReparse -Path $resourceFile.Source) {
                Throw-CcodLifecycleError 'CCOD_INSTALL_SOURCE_REPARSE' 'UI resource became a reparse point before staging.' $resourceFile.Source
            }
            if (Test-CcodLifecycleAlternateDataStreams -Path $resourceFile.Source) {
                Throw-CcodLifecycleError 'CCOD_INSTALL_SOURCE_INCOMPLETE' 'UI resource contains alternate data streams before staging.' $resourceFile.Source
            }
        }
        foreach ($file in $Files) {
            $destination = [IO.Path]::GetFullPath((Join-Path $stagingDirectory $file.Relative))
            $prefix = $stagingDirectory.TrimEnd('\') + '\'
            if (-not $destination.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                Throw-CcodLifecycleError 'CCOD_INSTALL_STAGING_PATH_INVALID' 'Staging path escaped the staging root' $destination
            }
            & $Adapters.CopyFile $file.Source $destination
        }
        foreach ($file in $Files) {
            $destination = [IO.Path]::GetFullPath((Join-Path $stagingDirectory $file.Relative))
            $expected = Get-CcodLifecycleFileSha256 -Path $file.Source
            $actual = Get-CcodLifecycleFileSha256 -Path $destination
            if ($actual -cne $expected) {
                Throw-CcodLifecycleError 'CCOD_INSTALL_FILE_HASH_MISMATCH' 'A staged runtime file failed its source hash comparison' $destination
            }
        }
        $bootstrapSource = [IO.Path]::GetFullPath((Join-Path (Split-Path $PSScriptRoot -Parent) 'bootstrap.ps1'))
        if (-not [IO.File]::Exists($bootstrapSource)) {
            Throw-CcodLifecycleError 'CCOD_INSTALL_SOURCE_INCOMPLETE' 'The bootstrap script is missing from the persistence source' $bootstrapSource
        }
        & $Adapters.CopyFile $bootstrapSource $bootstrapPath
        $copiedStableBootstrap = $true
        $uninstallerSource = Join-Path $SourceRoot 'Uninstall-CodexControlOtherDevices.ps1'
        if ([IO.File]::Exists($uninstallerSource)) {
            & $Adapters.CopyFile $uninstallerSource $uninstallerPath
            $copiedStableUninstaller = $true
        }
        return $stagingDirectory
    } catch {
        if ([IO.Directory]::Exists($stagingDirectory)) {
            try { Remove-Item -LiteralPath $stagingDirectory -Recurse -Force -ErrorAction Stop } catch { }
        }
        if ($copiedStableBootstrap -and -not $bootstrapExistedBefore -and [IO.File]::Exists($bootstrapPath)) {
            try { Remove-Item -LiteralPath $bootstrapPath -Force -ErrorAction Stop } catch { }
        }
        if ($copiedStableUninstaller -and -not $uninstallerExistedBefore -and [IO.File]::Exists($uninstallerPath)) {
            try { Remove-Item -LiteralPath $uninstallerPath -Force -ErrorAction Stop } catch { }
        }
        $candidateId = ([string]$_.FullyQualifiedErrorId -split ',')[0]
        if ($candidateId -clike 'CCOD_INSTALL_*' -or $candidateId -clike 'CCOD_*') {
            throw
        }
        Throw-CcodLifecycleError 'CCOD_INSTALL_STAGING_FAILED' 'Runtime staging failed safely' $stagingDirectory
    }
}

function Get-CcodLifecycleProjectVersion {
    param([Parameter(Mandatory)][string]$SourceRoot)

    $packagePath = Join-Path $SourceRoot 'package.json'
    if (-not [IO.File]::Exists($packagePath)) {
        Throw-CcodLifecycleError 'CCOD_INSTALL_SOURCE_INCOMPLETE' 'Source package.json is missing' $packagePath
    }
    try {
        $package = Get-Content -LiteralPath $packagePath -Raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Throw-CcodLifecycleError 'CCOD_INSTALL_SOURCE_INVALID' 'Source package.json is not valid JSON' $packagePath
    }
    if ($null -eq $package.PSObject.Properties['version'] -or $package.version -isnot [string] -or [string]::IsNullOrWhiteSpace($package.version)) {
        Throw-CcodLifecycleError 'CCOD_INSTALL_SOURCE_INVALID' 'Source package.json lacks a version' $packagePath
    }
    return [string]$package.version
}

function Get-CcodLifecycleNodeCandidates {
    param([Parameter(Mandatory)][hashtable]$Adapters)

    $candidates = @(& $Adapters.DiscoverNodeCandidates)
    $validated = [System.Collections.Generic.List[string]]::new()
    foreach ($candidate in @($candidates)) {
        if ($candidate -isnot [string] -or [string]::IsNullOrWhiteSpace($candidate) -or -not [IO.Path]::IsPathRooted($candidate)) { continue }
        try { $canonical = [IO.Path]::GetFullPath($candidate) } catch { continue }
        if (-not (& $Adapters.ValidateNodeCandidate $canonical)) { continue }
        if (-not $validated.Contains($canonical)) { $validated.Add($canonical) }
    }
    return @($validated)
}

function Write-CcodLifecycleLog {
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][hashtable]$Adapters,
        [Parameter(Mandatory)][string]$Stage,
        [Parameter(Mandatory)][string]$Code,
        [Parameter(Mandatory)][string]$Outcome,
        [switch]$ThrowOnFailure
    )

    try {
        $now = & $Adapters.UtcNow
        $record = [ordered]@{
            schemaVersion = 1
            timestampUtc = $now.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            component = 'Install'
            stage = $Stage
            code = $Code
            outcome = $Outcome
        }
        & $Adapters.WriteLog $InstallRoot $record
    } catch {
        if ($ThrowOnFailure) { throw }
    }
}

function Get-CcodLifecycleSupervisorIdentity {
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        $Identity,
        [Parameter(Mandatory)][hashtable]$Adapters
    )

    $stateRoot = Join-Path $InstallRoot 'state'
    if (Test-Path -LiteralPath (Join-Path $stateRoot 'status.json') -PathType Leaf) {
        try {
            $status = Read-CcodStatus -StateRoot $stateRoot
        } catch {
            $status = $null
        }
        if ($null -ne $status -and $null -ne $status.session -and
            $status.session.supervisorPid -is [int] -and $status.session.supervisorPid -ge 1 -and
            $status.session.supervisorCreationTimeUtc -is [string] -and -not [string]::IsNullOrWhiteSpace($status.session.supervisorCreationTimeUtc) -and
            $status.session.sessionId -is [string]) {
            $sessionId = 0
            if ([int]::TryParse($status.session.sessionId, [ref]$sessionId)) {
                return [pscustomobject][ordered]@{
                    Pid = [int]$status.session.supervisorPid
                    CreationTimeUtc = [string]$status.session.supervisorCreationTimeUtc
                    SessionId = [int]$sessionId
                    UserSid = [string]$Identity.UserSid
                }
            }
        }
    }
    return (& $Adapters.FindSupervisorFallback $InstallRoot $Identity)
}

function Get-CcodLifecycleVerifiedSupervisorFallback {
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        $Identity,
        [Parameter(Mandatory)][scriptblock]$ProcessEnumerator,
        [Parameter(Mandatory)][scriptblock]$OwnerSidResolver
    )

    try {
        if ($null -eq $Identity -or $Identity.UserSid -isnot [string] -or [string]::IsNullOrWhiteSpace($Identity.UserSid)) { return $null }
        $expectedSessionId = [int]$Identity.SessionId
        $root = Get-CcodLifecycleCanonicalRoot -Path $InstallRoot -Kind 'Install root'
        $bootstrapPath = [IO.Path]::GetFullPath((Join-Path $root 'bootstrap.ps1'))
        if (-not [IO.File]::Exists($bootstrapPath) -or (Test-CcodLifecycleReparse -Path $bootstrapPath)) { return $null }
        $runtimeRoot = Get-CcodLifecycleCanonicalRoot -Path (Join-Path $root 'runtime') -Kind 'Runtime root'
        $runtimePrefix = $runtimeRoot.TrimEnd('\') + '\'
        $bootstrapFilePattern = '(?i)(?:^|\s)-File\s+"' + [regex]::Escape($bootstrapPath) + '"(?=\s|$)'
        $bootstrapRootPattern = '(?i)(?:^|\s)-InstallRoot\s+"' + [regex]::Escape($root) + '"(?=\s|$)'
        $supervisorFilePattern = '(?i)(?:^|\s)-File\s+"(?<path>' + [regex]::Escape($runtimeRoot) + '\\[^"\\]+\\src\\persistence\\Supervisor\.ps1)"(?=\s|$)'
        $tokenPattern = '(?i)(?:^|\s)-ReadyToken\s+[0-9a-f]{64}(?=\s|$)'
        $processes = @(& $ProcessEnumerator)
        $byPid = @{}
        foreach ($process in $processes) {
            if ($null -eq $process -or $null -eq $process.PSObject.Properties['ProcessId']) { continue }
            $pid = 0
            if (-not [int]::TryParse([string]$process.ProcessId, [ref]$pid) -or $pid -lt 1) { continue }
            if ($byPid.ContainsKey($pid)) { return $null }
            $byPid[$pid] = $process
        }
        $matches = [Collections.Generic.List[object]]::new()
        foreach ($process in $byPid.Values) {
            if ($null -eq $process.PSObject.Properties['SessionId'] -or $null -eq $process.PSObject.Properties['ParentProcessId'] -or
                [int]$process.SessionId -ne $expectedSessionId -or [string]::IsNullOrWhiteSpace([string]$process.CommandLine)) { continue }
            $supervisorMatch = [regex]::Match([string]$process.CommandLine, $supervisorFilePattern)
            if (-not $supervisorMatch.Success -or -not [regex]::IsMatch([string]$process.CommandLine, $tokenPattern)) { continue }
            $supervisorPath = [IO.Path]::GetFullPath($supervisorMatch.Groups['path'].Value)
            if (-not $supervisorPath.StartsWith($runtimePrefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
            $parentPid = [int]$process.ParentProcessId
            if ($parentPid -lt 1 -or -not $byPid.ContainsKey($parentPid)) { continue }
            $parent = $byPid[$parentPid]
            if ([int]$parent.SessionId -ne $expectedSessionId -or [string]::IsNullOrWhiteSpace([string]$parent.CommandLine) -or
                -not [regex]::IsMatch([string]$parent.CommandLine, $bootstrapFilePattern) -or
                -not [regex]::IsMatch([string]$parent.CommandLine, $bootstrapRootPattern)) { continue }
            $supervisorOwner = & $OwnerSidResolver $process
            $parentOwner = & $OwnerSidResolver $parent
            if ($null -eq $supervisorOwner -or $null -eq $parentOwner -or
                [int]$supervisorOwner.ReturnValue -ne 0 -or [int]$parentOwner.ReturnValue -ne 0 -or
                [string]$supervisorOwner.Sid -cne [string]$Identity.UserSid -or [string]$parentOwner.Sid -cne [string]$Identity.UserSid) { continue }
            $creation = ([datetime]$process.CreationDate).ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            $matches.Add([pscustomobject][ordered]@{
                Pid = [int]$process.ProcessId
                CreationTimeUtc = $creation
                SessionId = [int]$process.SessionId
                UserSid = [string]$supervisorOwner.Sid
            })
        }
        if ($matches.Count -eq 0) { return $null }
        if ($matches.Count -ne 1) {
            Throw-CcodLifecycleError 'CCOD_INSTALL_SUPERVISOR_AMBIGUOUS' 'More than one verified legacy supervisor is present; upgrade cannot safely choose one' $matches
        }
        return $matches[0]
    } catch {
        if (([string]$_.FullyQualifiedErrorId -split ',')[0] -ceq 'CCOD_INSTALL_SUPERVISOR_AMBIGUOUS') { throw }
        return $null
    }
}

function Stop-CcodLifecycleSupervisor {
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][hashtable]$Adapters,
        $Identity
    )

    if ($null -eq $Identity) { return $true }
    & $Adapters.SignalSupervisorShutdown $Identity.UserSid $Identity.SessionId
    $exited = & $Adapters.WaitSupervisorExit $Identity 10000
    if ($exited) { return $true }
    if (-not (& $Adapters.IsSupervisorIdentityCurrent $Identity)) {
        return $true
    }
    $terminated = & $Adapters.TerminateSupervisor $Identity
    if ($terminated -isnot [bool] -or -not $terminated) { return $false }
    $forcedExit = & $Adapters.WaitSupervisorExit $Identity 5000
    return ($forcedExit -is [bool] -and $forcedExit)
}

function Invoke-CcodLifecycleControllerRecover {
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$RuntimeId,
        [Parameter(Mandatory)]$Identity
    )

    $runtimeRoot = [IO.Path]::GetFullPath((Join-Path (Join-Path $InstallRoot 'runtime') $RuntimeId))
    $validation = Test-CcodRuntimeManifest -RuntimeDirectory $runtimeRoot -ExpectedRuntimeId $RuntimeId
    if (-not $validation.Valid) {
        Throw-CcodLifecycleError 'CCOD_UNINSTALL_RUNTIME_INVALID' 'Active runtime failed manifest validation during uninstall' $runtimeRoot
    }
    $controller = [IO.Path]::GetFullPath((Join-Path $runtimeRoot 'src\persistence\SessionController.ps1'))
    if (-not [IO.File]::Exists($controller)) {
        Throw-CcodLifecycleError 'CCOD_UNINSTALL_RUNTIME_INVALID' 'Active runtime lacks SessionController.ps1' $controller
    }
    $supervisorIdentity = [pscustomobject][ordered]@{
        pid = [int]$Identity.Pid
        creationTimeUtc = [string]$Identity.CreationTimeUtc
        sessionId = [string]$Identity.SessionId
    }
    $request = [pscustomobject][ordered]@{
        schemaVersion = 1
        action = 'Recover'
        transactionId = [guid]::NewGuid().ToString('D')
        runtimeId = $RuntimeId
        supervisorIdentity = $supervisorIdentity
        source = $null
        existingOnly = $true
        rendererPort = $null
        mainPort = $null
        timeoutMilliseconds = 30000
        restartOrdinary = $true
    }
    $requestDirectory = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) 'CodexControlOtherDevices'))
    [IO.Directory]::CreateDirectory($requestDirectory) | Out-Null
    $nonce = [guid]::NewGuid().ToString('N')
    $requestPath = [IO.Path]::GetFullPath((Join-Path $requestDirectory "uninstall-$nonce-request.json"))
    $resultPath = [IO.Path]::GetFullPath((Join-Path $requestDirectory "uninstall-$nonce-result.json"))
    $stderrPath = [IO.Path]::GetFullPath((Join-Path $requestDirectory "uninstall-$nonce.stderr.log"))
    try {
        [IO.File]::WriteAllText($requestPath, ($request | ConvertTo-Json -Depth 16 -Compress), [Text.UTF8Encoding]::new($false))
        $resultPlaceholder = [IO.File]::Open($resultPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $resultPlaceholder.Dispose()
        $powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
        $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $controller, '-RequestPath', $requestPath, '-ResultPath', $resultPath)
        $stdout = @(& $powershell @arguments 2>$stderrPath)
        $exitCode = $LASTEXITCODE
        $lines = @($stdout | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($lines.Count -ne 1 -or -not [IO.File]::Exists($resultPath)) {
            Throw-CcodLifecycleError 'CCOD_UNINSTALL_NORMALIZATION_FAILED' 'The controller did not return one persisted machine-readable result' $resultPath
        }
        try {
            $fromStdout = $lines[0] | ConvertFrom-Json -ErrorAction Stop
            $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json -ErrorAction Stop
        } catch {
            Throw-CcodLifecycleError 'CCOD_UNINSTALL_NORMALIZATION_FAILED' 'The controller returned invalid JSON' $resultPath
        }
        if (($fromStdout | ConvertTo-Json -Depth 16 -Compress) -cne ($result | ConvertTo-Json -Depth 16 -Compress) -or
            $result.transactionId -cne $request.transactionId -or $result.action -cne 'Recover' -or
            $exitCode -ne 0 -or $result.ok -ne $true -or $null -ne $result.error) {
            Throw-CcodLifecycleError 'CCOD_UNINSTALL_NORMALIZATION_FAILED' 'The controller could not normalize the session safely' $result
        }
        $specialPresent = $null -ne $result.special -and
            $result.special -is [pscustomobject] -and
            $null -ne $result.special.PSObject.Properties['pid'] -and
            $result.special.pid -is [int] -and $result.special.pid -gt 0
        return [pscustomobject][ordered]@{
            SchemaVersion = 1
            SpecialPresent = [bool]$specialPresent
            Normalized = $true
            Outcome = [string]$result.outcome
        }
    } finally {
        foreach ($path in @($requestPath, $resultPath, $stderrPath)) {
            if ([IO.File]::Exists($path)) { try { [IO.File]::Delete($path) } catch { } }
        }
    }
}

function Get-CcodLifecycleAdapters {
    param([hashtable]$Adapters)

    $defaults = @{
        ValidateSource = {
            param($SourceRoot)
            try {
                $files = @(Get-CcodLifecycleSourceFiles -SourceRoot $SourceRoot -RequireTrayHost)
                return $files.Count -gt 0
            } catch {
                return $false
            }
        }
        GetProjectVersion = { param($SourceRoot) Get-CcodLifecycleProjectVersion -SourceRoot $SourceRoot }
        DiscoverNodeCandidates = {
            $candidates = [System.Collections.Generic.List[string]]::new()
            $node = Get-Command node.exe -ErrorAction SilentlyContinue
            if ($null -ne $node -and $node.Source -is [string] -and -not [string]::IsNullOrWhiteSpace($node.Source)) {
                $candidates.Add([IO.Path]::GetFullPath($node.Source))
            }
            @($candidates)
        }
        ValidateNodeCandidate = {
            param($Path)
            try {
                $candidate = Resolve-CcodNodeCandidate -NodeCandidates @([string]$Path)
                return $null -ne $candidate -and $candidate.Found -eq $true
            } catch { return $false }
        }
        GetCurrentIdentity = {
            $windowsIdentity = $null
            $process = $null
            try {
                $windowsIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
                $process = [Diagnostics.Process]::GetCurrentProcess()
                [pscustomobject][ordered]@{
                    UserSid = $windowsIdentity.User.Value
                    SessionId = [int]$process.SessionId
                    Pid = [int]$process.Id
                    CreationTimeUtc = $process.StartTime.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
                }
            } finally {
                if ($null -ne $process) { $process.Dispose() }
                if ($null -ne $windowsIdentity) { $windowsIdentity.Dispose() }
            }
        }
        FindSupervisorFallback = {
            param($InstallRoot, $Identity)
            Get-CcodLifecycleVerifiedSupervisorFallback -InstallRoot $InstallRoot -Identity $Identity -ProcessEnumerator {
                Get-CimInstance -ClassName Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction Stop
            } -OwnerSidResolver {
                param($Process)
                Invoke-CimMethod -InputObject $Process -MethodName GetOwnerSid -ErrorAction Stop
            }
        }
        IsSupervisorIdentityCurrent = {
            param($SupervisorIdentity)
            try {
                $process = Get-Process -Id $SupervisorIdentity.Pid -ErrorAction SilentlyContinue
                if ($null -eq $process) { return $false }
                try {
                    return $process.StartTime.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture) -ceq $SupervisorIdentity.CreationTimeUtc
                } finally { $process.Dispose() }
            } catch { return $false }
        }
        UtcNow = { [DateTime]::UtcNow }
        NewActivationId = { [guid]::NewGuid().ToString('D') }
        WriteActivationReceipt = {
            param($InstallRoot, $Receipt)
            Write-CcodActivationReceiptFile -InstallRoot $InstallRoot -Receipt $Receipt
        }
        ReadActiveLifecycleRequest = {
            param($StateRoot)
            Read-CcodLifecycleRequest -StateRoot $StateRoot
        }
        WaitNewRuntimeReady = {
            param($InstallRoot, $RuntimeId, $RuntimeGeneration, $Identity, $TaskStartedAtUtc, $TimeoutMilliseconds)
            Wait-CcodLifecycleNewRuntimeReady -InstallRoot $InstallRoot -RuntimeId $RuntimeId -RuntimeGeneration $RuntimeGeneration -Identity $Identity -TaskStartedAtUtc $TaskStartedAtUtc -TimeoutMilliseconds $TimeoutMilliseconds
        }
        InstallSupervisorTask = {
            param($InstallRoot, $UserSid)
            $spec = Get-CcodSupervisorTaskSpec -InstallRoot $InstallRoot -UserSid $UserSid
            $definition = New-CcodSupervisorTaskDefinition -Spec $spec
            Install-CcodSupervisorTask -Definition $definition -TaskName $spec.TaskName
        }
        RemoveSupervisorTask = {
            Remove-CcodSupervisorTask -TaskName $script:CcodLifecycleTaskName
        }
        StartSupervisorTask = {
            Start-ScheduledTask -TaskName $script:CcodLifecycleTaskName -ErrorAction Stop | Out-Null
        }
        WaitSupervisorTaskIdle = {
            param($TimeoutMilliseconds)
            $stopwatch = [Diagnostics.Stopwatch]::StartNew()
            while ($stopwatch.ElapsedMilliseconds -lt [long]$TimeoutMilliseconds) {
                $task = Get-ScheduledTask -TaskName $script:CcodLifecycleTaskName -ErrorAction Stop
                if ([string]$task.State -cne 'Running') { return $true }
                Start-Sleep -Milliseconds 100
            }
            return $false
        }
        SignalSupervisorShutdown = {
            param($UserSid, $SessionId)
            try {
                $event = Open-CcodEvent -Kind 'Shutdown' -UserSid $UserSid -SessionId $SessionId
            } catch [Threading.WaitHandleCannotBeOpenedException] {
                return
            }
            try { [void]$event.Handle.Set() } finally { $event.Handle.Dispose() }
        }
        WaitSupervisorExit = {
            param($SupervisorIdentity, $TimeoutMilliseconds)
            $stopwatch = [Diagnostics.Stopwatch]::StartNew()
            while ($stopwatch.ElapsedMilliseconds -lt [long]$TimeoutMilliseconds) {
                $process = Get-Process -Id $SupervisorIdentity.Pid -ErrorAction SilentlyContinue
                if ($null -eq $process) { return $true }
                try {
                    if ($process.StartTime.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture) -cne $SupervisorIdentity.CreationTimeUtc) { return $true }
                } finally { $process.Dispose() }
                Start-Sleep -Milliseconds 250
            }
            return $false
        }
        TerminateSupervisor = {
            param($SupervisorIdentity)
            $process = $null
            try {
                $process = Get-Process -Id $SupervisorIdentity.Pid -ErrorAction SilentlyContinue
                if ($null -eq $process) { return $true }
                if ($process.StartTime.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture) -cne $SupervisorIdentity.CreationTimeUtc) { return $true }
                $process.Kill()
                return $true
            } catch { return $false } finally { if ($null -ne $process) { $process.Dispose() } }
        }
        EnterInstallLease = {
            param($UserSid)
            Enter-CcodMutex -Kind 'AccountTransition' -UserSid $UserSid -TimeoutMilliseconds 30000
        }
        ExitInstallLease = {
            param($Lease)
            Exit-CcodMutex -Lease $Lease
        }
        EnterLifecycleOwnership = {
            param($InstallRoot, $RuntimeId, $RuntimeGeneration, $OwnerIdentity, $UserSid, $SessionId)
            Enter-CcodLifecycleOwnership -InstallRoot $InstallRoot -RuntimeId $RuntimeId -RuntimeGeneration $RuntimeGeneration -OwnerIdentity $OwnerIdentity -UserSid $UserSid -SessionId $SessionId
        }
        SetActiveRuntime = {
            param($InstallRoot, $RuntimeId, $Ownership)
            Set-CcodActiveRuntime -InstallRoot $InstallRoot -NewRuntimeId $RuntimeId -Ownership $Ownership
        }
        ExitLifecycleOwnership = {
            param($Ownership)
            Exit-CcodLifecycleOwnership -Ownership $Ownership
        }
        CreateSupervisorShutdownGate = {
            param($UserSid, $SessionId)
            $event = New-CcodEvent -Kind Shutdown -UserSid $UserSid -SessionId $SessionId
            try { [void]$event.Handle.Set(); return $event } catch { $event.Handle.Dispose(); throw }
        }
        CloseSupervisorShutdownGate = {
            param($Event)
            $Event.Handle.Dispose()
        }
        NormalizeSpecialSession = {
            param($InstallRoot, $RuntimeId, $Identity)
            Invoke-CcodLifecycleControllerRecover -InstallRoot $InstallRoot -RuntimeId $RuntimeId -Identity $Identity
        }
        SetAutomationEnabled = {
            param($StateRoot, $Enabled)
            Set-CcodAutomationEnabled -StateRoot $StateRoot -Enabled ([bool]$Enabled)
        }
        EnterTransitionLease = {
            param($UserSid, $SessionId)
            Enter-CcodMutex -Kind 'Transition' -UserSid $UserSid -SessionId $SessionId -TimeoutMilliseconds 10000
        }
        ExitTransitionLease = {
            param($Lease)
            Exit-CcodMutex -Lease $Lease
        }
        ResolveDeviceKeyStore = {
            Resolve-CcodDeviceKeyStorePath
        }
        BackupDeviceKeyStore = {
            param($Path, $BackupPath)
            [IO.Directory]::CreateDirectory((Split-Path $BackupPath -Parent)) | Out-Null
            [IO.File]::Move($Path, $BackupPath)
            $BackupPath
        }
        RemoveDeviceKeyStore = {
            param($Path)
            if ([IO.File]::Exists($Path)) { [IO.File]::Delete($Path) }
        }
        CopyFile = {
            param($Source, $Destination)
            [IO.Directory]::CreateDirectory((Split-Path $Destination -Parent)) | Out-Null
            [IO.File]::Copy($Source, $Destination, $true)
        }
        WriteLog = {
            param($InstallRoot, $Record)
            $logDirectory = Join-Path $InstallRoot 'logs'
            [IO.Directory]::CreateDirectory($logDirectory) | Out-Null
            Write-CcodRotatingLog -Path (Join-Path $logDirectory 'install.log') -Message ($Record | ConvertTo-Json -Depth 6 -Compress)
        }
    }
    if ($null -eq $Adapters) { return $defaults }
    if ($Adapters -isnot [hashtable]) {
        Throw-CcodLifecycleError 'CCOD_INSTALL_ADAPTER_INVALID' 'Lifecycle adapters must be a hashtable' $Adapters
    }
    $resolved = @{}
    foreach ($name in $defaults.Keys) { $resolved[$name] = $defaults[$name] }
    foreach ($key in $Adapters.Keys) {
        if ($key -isnot [string] -or -not $resolved.ContainsKey($key) -or $Adapters[$key] -isnot [scriptblock]) {
            Throw-CcodLifecycleError 'CCOD_INSTALL_ADAPTER_INVALID' 'Lifecycle adapter contract is invalid' $key
        }
        $resolved[$key] = $Adapters[$key]
    }
    return $resolved
}

function Install-CcodLifecycleTask {
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][hashtable]$Adapters,
        $Identity
    )

    & $Adapters.InstallSupervisorTask $InstallRoot $Identity.UserSid
}

function Start-CcodLifecycleTask {
    param([Parameter(Mandatory)][hashtable]$Adapters)
    $idle = & $Adapters.WaitSupervisorTaskIdle 10000
    if ($idle -isnot [bool] -or -not $idle) {
        Throw-CcodLifecycleError 'CCOD_INSTALL_SUPERVISOR_TASK_BUSY' 'The previous IgnoreNew supervisor task instance did not exit before restart' $script:CcodLifecycleTaskName
    }
    & $Adapters.StartSupervisorTask
}

function Get-CcodLifecycleReadinessAdapters {
    param([hashtable]$Adapters)
    $defaults = @{
        EnumerateProcesses = { Get-CimInstance -ClassName Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction Stop }
        GetProcessOwnerSid = {
            param($Process)
            $owner = Invoke-CimMethod -InputObject $Process -MethodName GetOwnerSid -ErrorAction Stop
            if ($null -eq $owner -or [int]$owner.ReturnValue -ne 0) { return $null }
            return [string]$owner.Sid
        }
        OpenReadyEvent = { param($UserSid,$SessionId,$ReadyToken) Open-CcodEvent -Kind Ready -UserSid $UserSid -SessionId $SessionId -ReadyToken $ReadyToken }
        WaitReadyEvent = { param($Event,$TimeoutMilliseconds) [bool]$Event.Handle.WaitOne($TimeoutMilliseconds) }
        IsSupervisorIdentityCurrent = {
            param($SupervisorIdentity)
            $process = $null
            try {
                $process = Get-Process -Id $SupervisorIdentity.Pid -ErrorAction SilentlyContinue
                if ($null -eq $process) { return $false }
                return $process.StartTime.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture) -ceq $SupervisorIdentity.CreationTimeUtc
            } catch { return $false }
            finally { if ($null -ne $process) { $process.Dispose() } }
        }
        CloseReadyEvent = { param($Event) $Event.Handle.Dispose() }
        StartClock = { [Diagnostics.Stopwatch]::StartNew() }
        GetElapsedMilliseconds = { param($Clock) [long]$Clock.ElapsedMilliseconds }
        Sleep = { param($Milliseconds) Start-Sleep -Milliseconds $Milliseconds }
    }
    if ($null -eq $Adapters) { return $defaults }
    if ($Adapters -isnot [hashtable]) { Throw-CcodLifecycleError 'CCOD_INSTALL_ADAPTER_INVALID' 'Readiness adapters must be a hashtable' $null }
    $resolved = @{}
    foreach ($name in $defaults.Keys) { $resolved[$name] = $defaults[$name] }
    foreach ($key in $Adapters.Keys) {
        if ($key -isnot [string] -or -not $resolved.ContainsKey($key) -or $Adapters[$key] -isnot [scriptblock]) {
            Throw-CcodLifecycleError 'CCOD_INSTALL_ADAPTER_INVALID' 'Readiness adapter contract is invalid' $key
        }
        $resolved[$key] = $Adapters[$key]
    }
    return $resolved
}

function New-CcodLifecycleNotReadyProof {
    return [pscustomobject][ordered]@{ SupervisorReady=$false; TrayReady=$false }
}

function Wait-CcodLifecycleNewRuntimeReady {
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$RuntimeId,
        [Parameter(Mandatory)][UInt64]$RuntimeGeneration,
        [Parameter(Mandatory)]$Identity,
        [Parameter(Mandatory)][DateTime]$TaskStartedAtUtc,
        [Parameter(Mandatory)][ValidateRange(1,120000)][int]$TimeoutMilliseconds,
        [hashtable]$Adapters
    )
    $adapter = Get-CcodLifecycleReadinessAdapters -Adapters $Adapters
    $readyEvent = $null
    $readyToken = $null
    try {
        $root = Get-CcodLifecycleCanonicalRoot -Path $InstallRoot -Kind 'Install root'
        $pointer = Read-CcodActiveRuntime -InstallRoot $root
        if ($pointer.activeRuntime -cne $RuntimeId -or [UInt64]$pointer.generation -ne $RuntimeGeneration) { return New-CcodLifecycleNotReadyProof }
        $runtimeRoot = [IO.Path]::GetFullPath((Join-Path (Join-Path $root 'runtime') $RuntimeId))
        $validation = Test-CcodRuntimeManifest -RuntimeDirectory $runtimeRoot -ExpectedRuntimeId $RuntimeId
        if (-not $validation.Valid) { return New-CcodLifecycleNotReadyProof }
        if ($null -eq $Identity -or $Identity.UserSid -isnot [string] -or $Identity.SessionId -isnot [int]) { return New-CcodLifecycleNotReadyProof }
        $supervisorPath = [IO.Path]::GetFullPath((Join-Path $runtimeRoot 'src\persistence\Supervisor.ps1'))
        $bootstrapPath = [IO.Path]::GetFullPath((Join-Path $root 'bootstrap.ps1'))
        $hostPrefix = '^\s*(?:"[^"]*powershell\.exe"|[^\s"]*powershell\.exe)'
        $supervisorPattern = $hostPrefix + '\s+-NoProfile\s+-ExecutionPolicy\s+Bypass\s+-STA\s+-File\s+"(?<path>[^"]+)"\s+-ReadyToken\s+(?<token>[0-9a-f]{64})\s*$'
        $bootstrapPattern = $hostPrefix + '\s+-NoProfile\s+-ExecutionPolicy\s+Bypass\s+-STA\s+-WindowStyle\s+Hidden\s+-File\s+"(?<path>[^"]+)"\s+-InstallRoot\s+"(?<root>[^"]+)"\s+-EntryMode\s+Task\s*$'
        $started = $TaskStartedAtUtc.ToUniversalTime()
        $clock = & $adapter.StartClock
        while ([long](& $adapter.GetElapsedMilliseconds $clock) -lt $TimeoutMilliseconds) {
            $snapshots = @(& $adapter.EnumerateProcesses)
            $byPid = @{}
            $duplicatePid = $false
            foreach ($snapshot in $snapshots) {
                if ($null -eq $snapshot -or $null -eq $snapshot.PSObject.Properties['ProcessId']) { continue }
                $snapshotPid = 0
                if (-not [int]::TryParse([string]$snapshot.ProcessId, [ref]$snapshotPid) -or $snapshotPid -lt 1) { continue }
                if ($byPid.ContainsKey($snapshotPid)) { $duplicatePid = $true; break }
                $byPid[$snapshotPid] = $snapshot
            }
            if ($duplicatePid) { return New-CcodLifecycleNotReadyProof }
            $matches = [Collections.Generic.List[object]]::new()
            foreach ($snapshot in $byPid.Values) {
                if ($null -eq $snapshot.PSObject.Properties['Name'] -or [string]$snapshot.Name -ine 'powershell.exe' -or
                    $null -eq $snapshot.PSObject.Properties['SessionId'] -or [int]$snapshot.SessionId -ne $Identity.SessionId -or
                    $null -eq $snapshot.PSObject.Properties['ParentProcessId'] -or $null -eq $snapshot.PSObject.Properties['CreationDate'] -or
                    $null -eq $snapshot.PSObject.Properties['CommandLine'] -or [string]::IsNullOrWhiteSpace([string]$snapshot.CommandLine)) { continue }
                $created = ([DateTime]$snapshot.CreationDate).ToUniversalTime()
                if ($created -lt $started) { continue }
                $match = [regex]::Match([string]$snapshot.CommandLine, $supervisorPattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
                if (-not $match.Success) { continue }
                try { $candidatePath = [IO.Path]::GetFullPath($match.Groups['path'].Value) } catch { continue }
                if ($candidatePath -cne $supervisorPath) { continue }
                $parentPid = [int]$snapshot.ParentProcessId
                if ($parentPid -lt 1 -or -not $byPid.ContainsKey($parentPid)) { continue }
                $parent = $byPid[$parentPid]
                if ($null -eq $parent.PSObject.Properties['SessionId'] -or [int]$parent.SessionId -ne $Identity.SessionId -or
                    $null -eq $parent.PSObject.Properties['CreationDate'] -or ([DateTime]$parent.CreationDate).ToUniversalTime() -lt $started -or
                    $null -eq $parent.PSObject.Properties['CommandLine']) { continue }
                $parentMatch = [regex]::Match([string]$parent.CommandLine, $bootstrapPattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
                if (-not $parentMatch.Success) { continue }
                try {
                    $candidateBootstrap = [IO.Path]::GetFullPath($parentMatch.Groups['path'].Value)
                    $candidateRoot = [IO.Path]::GetFullPath($parentMatch.Groups['root'].Value)
                } catch { continue }
                if ($candidateBootstrap -cne $bootstrapPath -or $candidateRoot -cne $root) { continue }
                if ((& $adapter.GetProcessOwnerSid $snapshot) -cne $Identity.UserSid -or (& $adapter.GetProcessOwnerSid $parent) -cne $Identity.UserSid) { continue }
                $matches.Add([pscustomobject][ordered]@{
                    Identity = [pscustomobject][ordered]@{ Pid=[int]$snapshot.ProcessId; CreationTimeUtc=$created.ToString('o', [Globalization.CultureInfo]::InvariantCulture); SessionId=[int]$snapshot.SessionId; UserSid=[string]$Identity.UserSid }
                    Token = [string]$match.Groups['token'].Value
                })
            }
            if ($matches.Count -gt 1) { return New-CcodLifecycleNotReadyProof }
            if ($matches.Count -eq 1) {
                $candidate = $matches[0]
                if (-not (& $adapter.IsSupervisorIdentityCurrent $candidate.Identity)) { return New-CcodLifecycleNotReadyProof }
                $readyToken = [string]$candidate.Token
                try { $readyEvent = & $adapter.OpenReadyEvent $Identity.UserSid $Identity.SessionId $readyToken }
                catch { return New-CcodLifecycleNotReadyProof }
                while ([long](& $adapter.GetElapsedMilliseconds $clock) -lt $TimeoutMilliseconds) {
                    if (-not (& $adapter.IsSupervisorIdentityCurrent $candidate.Identity)) { return New-CcodLifecycleNotReadyProof }
                    $remaining = $TimeoutMilliseconds - [long](& $adapter.GetElapsedMilliseconds $clock)
                    $slice = [int][Math]::Min(100, [Math]::Max(1, $remaining))
                    $signaled = $false
                    try { $signaled = & $adapter.WaitReadyEvent $readyEvent $slice } catch { return New-CcodLifecycleNotReadyProof }
                    if ($signaled -isnot [bool]) { return New-CcodLifecycleNotReadyProof }
                    if ($signaled) {
                        if (-not (& $adapter.IsSupervisorIdentityCurrent $candidate.Identity)) { return New-CcodLifecycleNotReadyProof }
                        return [pscustomobject][ordered]@{ SupervisorReady=$true; TrayReady=$true }
                    }
                }
                return New-CcodLifecycleNotReadyProof
            }
            & $adapter.Sleep 20
        }
        return New-CcodLifecycleNotReadyProof
    } catch {
        return New-CcodLifecycleNotReadyProof
    } finally {
        $readyToken = $null
        if ($null -ne $readyEvent) { try { & $adapter.CloseReadyEvent $readyEvent } catch { } }
    }
}

function Assert-CcodLifecycleTaskIdle {
    param([Parameter(Mandatory)][hashtable]$Adapters)
    $idle = & $Adapters.WaitSupervisorTaskIdle 10000
    if ($idle -isnot [bool] -or -not $idle) {
        Throw-CcodLifecycleError 'CCOD_INSTALL_SUPERVISOR_TASK_BUSY' 'The previous IgnoreNew supervisor task instance did not exit before activation' $script:CcodLifecycleTaskName
    }
    return $true
}

function Remove-CcodLifecycleInstallTree {
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][hashtable]$Adapters
    )

    $root = Get-CcodLifecycleCanonicalRoot -Path $InstallRoot -Kind 'Install root'
    if (-not [IO.Directory]::Exists($root)) { return }
    if (Test-CcodLifecycleReparse -Path $root) {
        Throw-CcodLifecycleError 'CCOD_INSTALL_REPARSE_PATH' 'Install root is a reparse point' $root
    }
    foreach ($item in Get-ChildItem -LiteralPath $root -Force -ErrorAction Stop) {
        [void](Test-CcodLifecycleRemovePath -Root $root -Path $item.FullName)
    }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop
}

function Remove-CcodLifecycleOldRuntimes {
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$ActiveRuntimeId,
        [AllowNull()][string]$PreviousRuntimeId
    )

    $runtimeRoot = Join-Path $InstallRoot 'runtime'
    if (-not [IO.Directory]::Exists($runtimeRoot)) { return }
    foreach ($directory in Get-ChildItem -LiteralPath $runtimeRoot -Directory -Force -ErrorAction Stop) {
        if ($directory.Name -ceq $ActiveRuntimeId -or $directory.Name -ceq $PreviousRuntimeId) { continue }
        [void](Test-CcodLifecycleRemovePath -Root $InstallRoot -Path $directory.FullName)
        Remove-Item -LiteralPath $directory.FullName -Recurse -Force -ErrorAction Stop
    }
}

function Invoke-CcodRepairState {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [hashtable]$Adapters
    )

    $adapters = Get-CcodLifecycleAdapters -Adapters $Adapters
    $root = Get-CcodLifecycleCanonicalRoot -Path $InstallRoot -Kind 'Install root'
    if (-not [IO.Directory]::Exists($root)) {
        Throw-CcodLifecycleError 'CCOD_INSTALL_REQUIRED' 'Install root does not exist; run a full install first' $root
    }
    $should = $PSCmdlet.ShouldProcess($root, 'Repair the Codex Control Other Devices state files')
    if ($should) {
        $nodeCandidates = @(Get-CcodLifecycleNodeCandidates -Adapters $adapters)
        $stateRoot = Join-Path $root 'state'
        Repair-CcodState -StateRoot $stateRoot | Out-Null
        $settings = [ordered]@{
            schemaVersion = 1
            automationEnabled = $false
            candidateCompatibleOptIn = $false
            nodeCandidates = @($nodeCandidates)
            updatedAtUtc = (& $adapters.UtcNow).ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        }
        Write-CcodSettings -StateRoot $stateRoot -Settings $settings -Adapters @{
            TestVerifiedNodeCandidate = { param($Path) & $adapters.ValidateNodeCandidate $Path }.GetNewClosure()
        }
        Write-CcodLifecycleLog -InstallRoot $root -Adapters $adapters -Stage 'RepairState' -Code 'CCOD_INSTALL_STATE_REPAIRED' -Outcome 'Repaired'
    }
    return [pscustomobject][ordered]@{
        Outcome = if ($should) { 'Repaired' } else { 'WhatIf' }
        RepairCompleted = [bool]$should
    }
}

function Invoke-CcodInstall {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [string]$InstallRoot,
        [switch]$EnableCandidateCompatibleUpdates,
        [switch]$RepairState,
        [switch]$DoNotStart,
        [string]$ActivationId,
        [hashtable]$Adapters
    )

    $adapters = Get-CcodLifecycleAdapters -Adapters $Adapters
    if ([string]::IsNullOrWhiteSpace($InstallRoot)) { $InstallRoot = $script:CcodLifecycleDefaultInstallRoot }
    $root = Get-CcodLifecycleCanonicalRoot -Path $InstallRoot -Kind 'Install root'
    $sourceRoot = Get-CcodLifecycleCanonicalRoot -Path $SourceRoot -Kind 'Source root'

    if ($RepairState) {
        return Invoke-CcodRepairState -InstallRoot $root -Adapters $adapters
    }
    if (-not $PSCmdlet.ShouldProcess($root, 'Install, upgrade, or repair the Codex Control Other Devices supervisor')) {
        return [pscustomobject][ordered]@{
            Outcome = 'WhatIf'
            Installed = $false
            RuntimeId = $null
            PreviousRuntimeId = $null
            RepairCompleted = $false
        }
    }

    if (-not [IO.Directory]::Exists($sourceRoot)) {
        Throw-CcodLifecycleError 'CCOD_INSTALL_SOURCE_MISSING' 'Source checkout does not exist' $sourceRoot
    }
    if (-not (& $adapters.ValidateSource $sourceRoot)) {
        Throw-CcodLifecycleError 'CCOD_INSTALL_SOURCE_INVALID' 'Source checkout failed hermetic validation' $sourceRoot
    }
    $identity = & $adapters.GetCurrentIdentity
    if ($null -eq $identity -or $identity.UserSid -isnot [string] -or $identity.SessionId -isnot [int]) {
        Throw-CcodLifecycleError 'CCOD_INSTALL_IDENTITY_INVALID' 'Current user identity is unavailable' $null
    }
    $projectVersion = & $adapters.GetProjectVersion $sourceRoot
    $nodeCandidates = @(Get-CcodLifecycleNodeCandidates -Adapters $adapters)
    $files = @(Get-CcodLifecycleSourceFiles -SourceRoot $sourceRoot -RequireTrayHost)

    $existingPointer = $null
    $activePath = Join-Path $root 'active.json'
    if ([IO.File]::Exists($activePath)) {
        $existingPointer = Read-CcodActiveRuntime -InstallRoot $root
    }

    if ([string]::IsNullOrWhiteSpace($ActivationId)) { $ActivationId = & $adapters.NewActivationId }
    if (-not (Test-CcodLifecycleCanonicalGuid $ActivationId)) {
        Throw-CcodLifecycleError 'CCOD_ACTIVATION_ID_INVALID' 'ActivationId must be a canonical lowercase GUID' $null
    }
    $startedAt = & $adapters.UtcNow
    if ($startedAt -isnot [DateTime]) { Throw-CcodLifecycleError 'CCOD_INSTALL_CLOCK_INVALID' 'Activation clock must return DateTime' $null }
    $activation = [pscustomobject]@{
        ActivationId = [string]$ActivationId
        StartedAtUtc = $startedAt.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        LastPhase = $null
    }
    $stagingDirectory = $null
    $runtimeId = $null
    $runtimeRoot = $null
    $runtimeCreated = $false
    $pointerCommitted = $false
    $pointer = $existingPointer
    $upgrade = $null -ne $existingPointer
    $installLease = $null
    $shutdownGate = $null
    $lifecycleOwnership = $null
    $previousProtectionStopped = $false
    try {
        if ($upgrade) {
            $pending = & $adapters.ReadActiveLifecycleRequest (Join-Path $root 'state')
            if ($null -ne $pending) {
                Throw-CcodLifecycleError 'CCOD_INSTALL_LIFECYCLE_BUSY' 'A nonterminal lifecycle transaction must complete before upgrade' $null
            }
            Write-CcodInstallActivationPhase -Activation $activation -Phase 'StoppingPreviousRuntime' -RuntimeId $null -PreviousRuntimeId ([string]$existingPointer.activeRuntime) -ErrorCode $null -Adapters $adapters -InstallRoot $root | Out-Null
            $shutdownGate = & $adapters.CreateSupervisorShutdownGate $identity.UserSid $identity.SessionId
            if ($null -eq $shutdownGate) {
                Throw-CcodLifecycleError 'CCOD_INSTALL_SHUTDOWN_GATE_FAILED' 'The upgrade shutdown gate could not be created' $root
            }
            $oldSupervisor = Get-CcodLifecycleSupervisorIdentity -InstallRoot $root -Identity $identity -Adapters $adapters
            if ($null -ne $oldSupervisor -and -not (Stop-CcodLifecycleSupervisor -InstallRoot $root -Adapters $adapters -Identity $oldSupervisor)) {
                Throw-CcodLifecycleError 'CCOD_INSTALL_PREVIOUS_RUNTIME_BUSY' 'The verified previous Supervisor did not exit exactly' $null
            }
            $previousProtectionStopped = $true
            [void](Assert-CcodLifecycleTaskIdle -Adapters $adapters)
            $installLease = & $adapters.EnterInstallLease $identity.UserSid
            if ($null -eq $installLease -or $installLease.Outcome -isnot [string] -or @('Acquired', 'TimedOut') -cnotcontains $installLease.Outcome) {
                Throw-CcodLifecycleError 'CCOD_INSTALL_LEASE_INVALID' 'The installation lease contract is invalid' $installLease
            }
            if ($installLease.Outcome -ceq 'TimedOut') {
                Throw-CcodLifecycleError 'CCOD_INSTALL_BUSY' 'Another transition or bootstrap launch is in progress; retry the upgrade shortly' $root
            }
            $pending = & $adapters.ReadActiveLifecycleRequest (Join-Path $root 'state')
            if ($null -ne $pending) {
                Throw-CcodLifecycleError 'CCOD_INSTALL_LIFECYCLE_BUSY' 'A nonterminal lifecycle transaction appeared during upgrade shutdown' $null
            }
        }

        Write-CcodInstallActivationPhase -Activation $activation -Phase 'InstallingRuntime' -RuntimeId $null -PreviousRuntimeId $(if ($upgrade) { [string]$existingPointer.activeRuntime } else { $null }) -ErrorCode $null -Adapters $adapters -InstallRoot $root | Out-Null
        $stagingDirectory = Copy-CcodLifecycleStaging -SourceRoot $sourceRoot -InstallRoot $root -Adapters $adapters -Files $files
        $manifest = New-CcodRuntimeManifest -RuntimeDirectory $stagingDirectory -ProjectVersion $projectVersion
        [IO.File]::WriteAllText(
            (Join-Path $stagingDirectory 'manifest.json'),
            ($manifest | ConvertTo-Json -Depth 16),
            [Text.UTF8Encoding]::new($false)
        )
        $runtimeId = [string]$manifest.runtimeId
        $validation = Test-CcodRuntimeManifest -RuntimeDirectory $stagingDirectory -ExpectedRuntimeId $runtimeId
        if (-not $validation.Valid) {
            Throw-CcodLifecycleError 'CCOD_INSTALL_MANIFEST_INVALID' ("Staged runtime failed manifest validation: {0}" -f $validation.Code) $stagingDirectory
        }
        $runtimeRoot = [IO.Path]::GetFullPath((Join-Path (Join-Path $root 'runtime') $runtimeId))
        if ([IO.Directory]::Exists($runtimeRoot)) {
            $existingValidation = Test-CcodRuntimeManifest -RuntimeDirectory $runtimeRoot -ExpectedRuntimeId $runtimeId
            if (-not $existingValidation.Valid) {
                Throw-CcodLifecycleError 'CCOD_INSTALL_RUNTIME_CONFLICT' 'An invalid runtime already occupies the target runtime id' $runtimeRoot
            }
            if ([IO.Directory]::Exists($stagingDirectory)) {
                try { Remove-Item -LiteralPath $stagingDirectory -Recurse -Force -ErrorAction Stop } catch { }
            }
        } else {
            [IO.Directory]::CreateDirectory((Split-Path $runtimeRoot -Parent)) | Out-Null
            [IO.Directory]::Move($stagingDirectory, $runtimeRoot)
            $runtimeCreated = $true
        }
        $stagingDirectory = $null
        if (-not $upgrade) {
            $stateRoot = Join-Path $root 'state'
            Initialize-CcodState -StateRoot $stateRoot -NodeCandidates $nodeCandidates -CandidateCompatibleOptIn ([bool]$EnableCandidateCompatibleUpdates)
            Initialize-CcodUiPreference -StateRoot $stateRoot | Out-Null
        }
        Write-CcodInstallActivationPhase -Activation $activation -Phase 'ActivatingRuntime' -RuntimeId $runtimeId -PreviousRuntimeId $(if ($upgrade) { [string]$existingPointer.activeRuntime } else { $null }) -ErrorCode $null -Adapters $adapters -InstallRoot $root | Out-Null
        $process = [Diagnostics.Process]::GetCurrentProcess()
        try {
            $ownerIdentity = [pscustomobject][ordered]@{ pid=[int]$process.Id; creationTimeUtc=$process.StartTime.ToUniversalTime().ToString('o') }
            $ownershipRuntimeId = if ($null -ne $existingPointer) { [string]$existingPointer.activeRuntime } else { $runtimeId }
            [UInt64]$ownershipGeneration = if ($null -ne $existingPointer) { [UInt64]$existingPointer.generation } else { 1 }
            $lifecycleOwnership = & $adapters.EnterLifecycleOwnership $root $ownershipRuntimeId $ownershipGeneration $ownerIdentity $identity.UserSid $identity.SessionId
            $pointer = & $adapters.SetActiveRuntime $root $runtimeId $lifecycleOwnership
        } finally { $process.Dispose() }
        [UInt64]$expectedGeneration = if ($null -ne $existingPointer) { [UInt64]$existingPointer.generation + 1 } else { 1 }
        if ($null -eq $pointer -or $pointer.activeRuntime -cne $runtimeId -or [UInt64]$pointer.generation -ne $expectedGeneration) {
            Throw-CcodLifecycleError 'CCOD_INSTALL_RUNTIME_ACTIVATION_UNPROVEN' 'The active runtime generation commit could not be proven' $null
        }
        $pointerCommitted = $true
        if ($null -ne $shutdownGate) {
            & $adapters.CloseSupervisorShutdownGate $shutdownGate
            $shutdownGate = $null
        }
        Write-CcodInstallActivationPhase -Activation $activation -Phase 'StartingProtection' -RuntimeId $runtimeId -PreviousRuntimeId $pointer.previousRuntime -ErrorCode $null -Adapters $adapters -InstallRoot $root | Out-Null
        Install-CcodLifecycleTask -InstallRoot $root -Adapters $adapters -Identity $identity
        if ($DoNotStart) {
            Throw-CcodLifecycleError 'CCOD_INSTALL_NEW_RUNTIME_NOT_READY' 'Activation cannot succeed without starting and proving the new runtime' $null
        }
        $taskStartedAt = & $adapters.UtcNow
        try { & $adapters.StartSupervisorTask }
        catch { Throw-CcodLifecycleError 'CCOD_INSTALL_SUPERVISOR_START_FAILED' 'The existing scheduled task could not start the new runtime' $null }
        $ownershipReleased = & $adapters.ExitLifecycleOwnership $lifecycleOwnership
        if ($ownershipReleased -isnot [bool] -or -not $ownershipReleased -or -not $lifecycleOwnership.released) {
            Throw-CcodLifecycleError 'CCOD_INSTALL_LIFECYCLE_RELEASE_FAILED' 'Generation ownership could not be released for scheduled-task bootstrap' $null
        }
        if ($null -ne $installLease -and $installLease.Outcome -ceq 'Acquired') {
            $installReleased = & $adapters.ExitInstallLease $installLease
            if ($installReleased -isnot [bool] -or -not $installReleased) {
                Throw-CcodLifecycleError 'CCOD_INSTALL_LIFECYCLE_RELEASE_FAILED' 'Installation lease could not be released for scheduled-task bootstrap' $null
            }
            $installLease = $null
        }
        $readyProof = & $adapters.WaitNewRuntimeReady $root $runtimeId ([UInt64]$pointer.generation) $identity $taskStartedAt 15000
        if ($null -eq $readyProof -or $readyProof.SupervisorReady -isnot [bool] -or $readyProof.TrayReady -isnot [bool] -or
            -not $readyProof.SupervisorReady -or -not $readyProof.TrayReady) {
            Throw-CcodLifecycleError 'CCOD_INSTALL_NEW_RUNTIME_NOT_READY' 'The new Supervisor and authenticated TrayHost readiness were not proven' $null
        }
        Write-CcodInstallActivationPhase -Activation $activation -Phase 'Ready' -RuntimeId $runtimeId -PreviousRuntimeId $pointer.previousRuntime -ErrorCode $null -Adapters $adapters -InstallRoot $root | Out-Null
        if ($upgrade) {
            try { Remove-CcodLifecycleOldRuntimes -InstallRoot $root -ActiveRuntimeId $runtimeId -PreviousRuntimeId $pointer.previousRuntime }
            catch {
                try { Write-CcodLifecycleLog -InstallRoot $root -Adapters $adapters -Stage 'OldRuntimeCleanup' -Code 'CCOD_INSTALL_OLD_RUNTIME_CLEANUP_FAILED' -Outcome 'Retained' } catch { }
            }
        }
        try {
            Write-CcodLifecycleLog -InstallRoot $root -Adapters $adapters -Stage $(if ($upgrade) { 'Upgrade' } else { 'Install' }) -Code 'CCOD_INSTALL_COMPLETED' -Outcome $(if ($upgrade) { 'Upgraded' } else { 'Installed' }) -ThrowOnFailure
        } catch {
            try { Write-CcodLifecycleLog -InstallRoot $root -Adapters $adapters -Stage 'PostReady' -Code 'CCOD_INSTALL_POST_READY_LOG_FAILED' -Outcome 'ReadyRetained' } catch { }
        }
    } catch {
        $caught = $_
        $errorCode = Get-CcodLifecycleErrorId $caught
        if ($errorCode -notmatch '^CCOD_[A-Z0-9_]+$') {
            $errorCode = switch ([string]$activation.LastPhase) {
                'StoppingPreviousRuntime' { 'CCOD_INSTALL_PREVIOUS_RUNTIME_BUSY' }
                'InstallingRuntime' { 'CCOD_INSTALL_STAGING_FAILED' }
                'ActivatingRuntime' { 'CCOD_INSTALL_RUNTIME_ACTIVATION_UNPROVEN' }
                'StartingProtection' { 'CCOD_INSTALL_NEW_RUNTIME_NOT_READY' }
                default { 'CCOD_INSTALL_FAILED' }
            }
        }
        if (-not $pointerCommitted -and $null -ne $runtimeId -and [IO.File]::Exists($activePath)) {
            try {
                $observedPointer = Read-CcodActiveRuntime -InstallRoot $root
                if ($observedPointer.activeRuntime -ceq $runtimeId -and ($null -eq $existingPointer -or [UInt64]$observedPointer.generation -gt [UInt64]$existingPointer.generation)) {
                    $pointerCommitted = $true
                }
            } catch { }
        }
        if (-not $pointerCommitted -and $upgrade -and $previousProtectionStopped) {
            $rollbackFailure = $null
            try {
                if ($null -ne $shutdownGate) {
                    & $adapters.CloseSupervisorShutdownGate $shutdownGate
                    $shutdownGate = $null
                }
                if ($null -ne $lifecycleOwnership -and -not $lifecycleOwnership.released) {
                    $ownershipReleased = & $adapters.ExitLifecycleOwnership $lifecycleOwnership
                    if ($ownershipReleased -isnot [bool] -or -not $ownershipReleased -or -not $lifecycleOwnership.released) {
                        throw 'Previous runtime ownership release was not proven'
                    }
                }
                if ($null -ne $installLease -and $installLease.Outcome -ceq 'Acquired') {
                    $installReleased = & $adapters.ExitInstallLease $installLease
                    if ($installReleased -isnot [bool] -or -not $installReleased) {
                        throw 'Previous runtime installation lease release was not proven'
                    }
                    $installLease = $null
                }
                $rollbackStartedAt = & $adapters.UtcNow
                if ($rollbackStartedAt -isnot [DateTime]) { throw 'Previous runtime restart clock is invalid' }
                & $adapters.StartSupervisorTask
                $rollbackProof = & $adapters.WaitNewRuntimeReady $root ([string]$existingPointer.activeRuntime) ([UInt64]$existingPointer.generation) $identity $rollbackStartedAt 15000
                if ($null -eq $rollbackProof -or $rollbackProof.SupervisorReady -isnot [bool] -or $rollbackProof.TrayReady -isnot [bool] -or
                    -not $rollbackProof.SupervisorReady -or -not $rollbackProof.TrayReady) {
                    throw 'Previous runtime readiness was not proven'
                }
                try { Write-CcodLifecycleLog -InstallRoot $root -Adapters $adapters -Stage 'UpgradeRollback' -Code 'CCOD_INSTALL_PREVIOUS_RUNTIME_RESTORED' -Outcome 'Restored' } catch { }
            } catch {
                $rollbackFailure = $_
            }
            if ($null -ne $rollbackFailure) {
                $errorCode = 'CCOD_INSTALL_ROLLBACK_FAILED'
                try { Write-CcodLifecycleLog -InstallRoot $root -Adapters $adapters -Stage 'UpgradeRollback' -Code $errorCode -Outcome 'Failed' } catch { }
            }
        }
        if (-not $pointerCommitted -and $runtimeCreated -and $null -ne $runtimeRoot -and [IO.Directory]::Exists($runtimeRoot)) {
            try { Remove-Item -LiteralPath $runtimeRoot -Recurse -Force -ErrorAction Stop } catch { }
        }
        if ($errorCode -cne 'CCOD_INSTALL_ACTIVATION_RECEIPT_FAILED') {
            try {
                Write-CcodInstallActivationPhase -Activation $activation -Phase 'Failed' -RuntimeId $runtimeId -PreviousRuntimeId $(if ($null -ne $existingPointer) { [string]$existingPointer.activeRuntime } else { $null }) -ErrorCode $errorCode -Adapters $adapters -InstallRoot $root | Out-Null
            } catch { }
        }
        if ((Get-CcodLifecycleErrorId $caught) -ceq $errorCode) { throw $caught }
        Throw-CcodLifecycleError $errorCode 'Installation failed at a protected activation boundary' $null
    } finally {
        if ($null -ne $shutdownGate) {
            try { & $adapters.CloseSupervisorShutdownGate $shutdownGate } catch { }
        }
        if ($null -ne $installLease -and $installLease.Outcome -ceq 'Acquired') {
            try { [void](& $adapters.ExitInstallLease $installLease) } catch { }
        }
        if ($null -ne $lifecycleOwnership -and -not $lifecycleOwnership.released) {
            try { & $adapters.ExitLifecycleOwnership $lifecycleOwnership | Out-Null } catch { }
        }
        if ($null -ne $stagingDirectory -and [IO.Directory]::Exists($stagingDirectory)) {
            try { Remove-Item -LiteralPath $stagingDirectory -Recurse -Force -ErrorAction Stop } catch { }
        }
        $stagingRoot = [IO.Path]::GetFullPath((Join-Path $root '.staging'))
        if ([IO.Directory]::Exists($stagingRoot) -and -not (Test-CcodLifecycleReparse -Path $stagingRoot)) {
            try { Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction Stop } catch { }
        }
    }

    return [pscustomobject][ordered]@{
        Outcome = if ($upgrade) { 'Upgraded' } else { 'Installed' }
        Installed = $true
        RuntimeId = $runtimeId
        PreviousRuntimeId = $pointer.previousRuntime
        RepairCompleted = $false
    }
}

function Invoke-CcodUninstall {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$InstallRoot,
        [switch]$KeepCurrentSpecialSession,
        [switch]$BackupDeviceKeyStore,
        [switch]$RemoveDeviceKeyStore,
        [hashtable]$Adapters
    )

    $adapters = Get-CcodLifecycleAdapters -Adapters $Adapters
    if ([string]::IsNullOrWhiteSpace($InstallRoot)) { $InstallRoot = $script:CcodLifecycleDefaultInstallRoot }
    $root = Get-CcodLifecycleCanonicalRoot -Path $InstallRoot -Kind 'Install root'
    if ([bool]$BackupDeviceKeyStore -and [bool]$RemoveDeviceKeyStore) {
        Throw-CcodLifecycleError 'CCOD_UNINSTALL_KEY_CONFLICT' 'Backup and removal of the device key store are mutually exclusive' $null
    }
    if (-not $PSCmdlet.ShouldProcess($root, 'Uninstall the Codex Control Other Devices supervisor')) {
        return [pscustomobject][ordered]@{
            Outcome = 'WhatIf'
            KeptDeviceKeyStore = $true
            BackupPath = $null
        }
    }
    if (-not [IO.Directory]::Exists($root)) {
        Throw-CcodLifecycleError 'CCOD_INSTALL_REQUIRED' 'Install root does not exist' $root
    }
    $activePath = Join-Path $root 'active.json'
    if (-not [IO.File]::Exists($activePath)) {
        Throw-CcodLifecycleError 'CCOD_INSTALL_REQUIRED' 'Install root has no active runtime pointer' $root
    }
    $pointer = Read-CcodActiveRuntime -InstallRoot $root
    $identity = & $adapters.GetCurrentIdentity
    $supervisor = Get-CcodLifecycleSupervisorIdentity -InstallRoot $root -Identity $identity -Adapters $adapters
    $lease = $null
    $keptKeyStore = $false
    $backupPath = $null
    try {
        $lease = & $adapters.EnterTransitionLease $identity.UserSid $identity.SessionId
        & $adapters.SetAutomationEnabled (Join-Path $root 'state') $false
        if ($KeepCurrentSpecialSession) {
            Write-CcodLifecycleLog -InstallRoot $root -Adapters $adapters -Stage 'Uninstall' -Code 'CCOD_UNINSTALL_UNMONITORED_CDP' -Outcome 'Warning'
        } else {
            $receipt = & $adapters.NormalizeSpecialSession $root $pointer.activeRuntime $identity
            if ($null -ne $receipt -and $null -ne $receipt.PSObject.Properties['SpecialPresent'] -and [bool]$receipt.SpecialPresent -and
                ($null -eq $receipt.PSObject.Properties['Normalized'] -or -not [bool]$receipt.Normalized)) {
                Throw-CcodLifecycleError 'CCOD_UNINSTALL_NORMALIZATION_FAILED' 'A validated special session could not be normalized to an ordinary session' $receipt
            }
        }
        & $adapters.RemoveSupervisorTask
        if ($null -ne $supervisor) {
            Stop-CcodLifecycleSupervisor -InstallRoot $root -Adapters $adapters -Identity $supervisor
        }
        $keyPath = & $adapters.ResolveDeviceKeyStore
        if ($BackupDeviceKeyStore -and -not [string]::IsNullOrWhiteSpace($keyPath) -and [IO.File]::Exists($keyPath)) {
            $now = & $adapters.UtcNow
            $base = $keyPath + '.backup.' + $now.ToUniversalTime().ToString('yyyyMMdd-HHmmss')
            $destination = $base
            $suffix = 0
            while ([IO.File]::Exists($destination)) { $suffix++; $destination = "$base.$suffix" }
            $backupPath = & $adapters.BackupDeviceKeyStore $keyPath $destination
        } elseif ($RemoveDeviceKeyStore -and -not [string]::IsNullOrWhiteSpace($keyPath) -and [IO.File]::Exists($keyPath)) {
            & $adapters.RemoveDeviceKeyStore $keyPath
            Write-CcodLifecycleLog -InstallRoot $root -Adapters $adapters -Stage 'Uninstall' -Code 'CCOD_UNINSTALL_REVOKE_REMINDER' -Outcome 'Warning'
        } else {
            $keptKeyStore = $true
        }
        Write-CcodLifecycleLog -InstallRoot $root -Adapters $adapters -Stage 'Uninstall' -Code 'CCOD_UNINSTALL_COMPLETED' -Outcome 'Uninstalled'
        Remove-CcodLifecycleInstallTree -InstallRoot $root -Adapters $adapters
    } finally {
        if ($null -ne $lease) {
            try { [void](& $adapters.ExitTransitionLease $lease) } catch { }
        }
    }
    return [pscustomobject][ordered]@{
        Outcome = 'Uninstalled'
        KeptDeviceKeyStore = [bool]$keptKeyStore
        BackupPath = $backupPath
    }
}

Export-ModuleMember -Function Invoke-CcodInstall, Invoke-CcodRepairState, Invoke-CcodUninstall, Test-CcodLifecycleRemovePath
