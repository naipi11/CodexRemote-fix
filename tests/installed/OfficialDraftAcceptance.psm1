Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# BEGIN CCOD TRUSTED IMPORT BOOTSTRAP
# Embedded in each independently trusted entrypoint; an unheld helper import
# cannot bootstrap its own protection. Keep copies identical (self-test enforced).
function Initialize-CcodTrustedImportLease {
    if ($null -ne ('CcodTrustedImportLeaseV1' -as [type])) { return }
    Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

public sealed class CcodTrustedImportLeaseV1 : IDisposable
{
    [StructLayout(LayoutKind.Sequential)] private struct NativeTime { public uint Low, High; }
    [StructLayout(LayoutKind.Sequential)] private struct NativeInfo
    {
        public uint Attributes;
        public NativeTime Creation, Access, Write;
        public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
    }
    private sealed class Entry
    {
        public SafeFileHandle Handle;
        public string Path;
        public bool Directory;
        public uint Volume;
        public ulong FileId;
    }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    private static extern SafeFileHandle CreateFileW(string path, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError=true)]
    private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out NativeInfo info);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    private static extern uint GetFinalPathNameByHandleW(SafeFileHandle handle, StringBuilder value, uint length, uint flags);

    private readonly List<Entry> entries = new List<Entry>();
    private bool disposed;
    public string Path { get; private set; }
    private CcodTrustedImportLeaseV1(string path) { Path = path; }

    public static CcodTrustedImportLeaseV1 Acquire(string path)
    {
        if (String.IsNullOrWhiteSpace(path) || !System.IO.Path.IsPathRooted(path) ||
            path.StartsWith(@"\\?\", StringComparison.Ordinal) || path.StartsWith(@"\\.\", StringComparison.Ordinal))
            throw new ArgumentException("Unsupported module path");
        string full = System.IO.Path.GetFullPath(path);
        string root = System.IO.Path.GetPathRoot(full);
        string extension = System.IO.Path.GetExtension(full);
        if (!String.Equals(full, path, StringComparison.OrdinalIgnoreCase) || String.IsNullOrEmpty(root) ||
            full.Substring(root.Length).IndexOf(':') >= 0 ||
            (!String.Equals(extension, ".psm1", StringComparison.OrdinalIgnoreCase) && !String.Equals(extension, ".ps1", StringComparison.OrdinalIgnoreCase)))
            throw new ArgumentException("Noncanonical module path");
        var lease = new CcodTrustedImportLeaseV1(full);
        try
        {
            var parents = new List<string>();
            for (DirectoryInfo parent = Directory.GetParent(full); parent != null; parent = parent.Parent)
                parents.Add(parent.FullName);
            parents.Reverse();
            if (parents.Count == 0 || !SamePath(parents[0], root)) throw new IOException("Missing module root");
            // Retain root-to-leaf authority before traversing the next component.
            foreach (string parent in parents) lease.Open(parent, true);
            lease.Open(full, false);
            lease.Revalidate();
            return lease;
        }
        catch { lease.Dispose(); throw; }
    }

    private void Open(string path, bool directory)
    {
        uint access = directory ? 0x00100081U : 0x80100080U;
        uint flags = 0x00200000U | (directory ? 0x02000000U : 0U);
        // FILE_SHARE_READ only: preexisting writers/deleters must fail closed.
        SafeFileHandle handle = CreateFileW(path, access, 1U, IntPtr.Zero, 3U, flags, IntPtr.Zero);
        if (handle.IsInvalid) { int error = Marshal.GetLastWin32Error(); handle.Dispose(); throw new Win32Exception(error); }
        try
        {
            NativeInfo info = Inspect(handle, path, directory);
            entries.Add(new Entry { Handle = handle, Path = path, Directory = directory, Volume = info.Volume, FileId = FileId(info) });
        }
        catch { handle.Dispose(); throw; }
    }

    private static ulong FileId(NativeInfo info) { return ((ulong)info.IndexHigh << 32) | info.IndexLow; }
    private static bool SamePath(string left, string right)
    {
        return String.Equals(left.TrimEnd('\\'), right.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase);
    }
    private static NativeInfo Inspect(SafeFileHandle handle, string expected, bool directory)
    {
        NativeInfo info;
        if (!GetFileInformationByHandle(handle, out info)) throw new Win32Exception(Marshal.GetLastWin32Error());
        if ((info.Attributes & 0x400U) != 0 || ((info.Attributes & 0x10U) != 0) != directory)
            throw new IOException("Unsafe module path kind");
        var value = new StringBuilder(512);
        uint length = GetFinalPathNameByHandleW(handle, value, (uint)value.Capacity, 0);
        if (length == 0) throw new Win32Exception(Marshal.GetLastWin32Error());
        if (length >= value.Capacity)
        {
            value.Capacity = checked((int)length + 1);
            length = GetFinalPathNameByHandleW(handle, value, (uint)value.Capacity, 0);
            if (length == 0 || length >= value.Capacity) throw new IOException("Module final path unavailable");
        }
        string final = value.ToString();
        if (final.StartsWith(@"\\?\UNC\", StringComparison.OrdinalIgnoreCase)) final = @"\\" + final.Substring(8);
        else if (final.StartsWith(@"\\?\", StringComparison.OrdinalIgnoreCase)) final = final.Substring(4);
        if (!SamePath(final, expected)) throw new IOException("Module final path mismatch");
        return info;
    }

    public void Revalidate()
    {
        if (disposed) throw new ObjectDisposedException("trusted module import lease");
        foreach (Entry entry in entries)
        {
            NativeInfo info = Inspect(entry.Handle, entry.Path, entry.Directory);
            if (info.Volume != entry.Volume || FileId(info) != entry.FileId) throw new IOException("Module identity changed");
        }
    }
    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        for (int index = entries.Count - 1; index >= 0; index--) entries[index].Handle.Dispose();
        entries.Clear();
    }
}
'@
}

function Open-CcodTrustedImportLease {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$ErrorId)
    try {
        Initialize-CcodTrustedImportLease
        return [CcodTrustedImportLeaseV1]::Acquire($Path)
    } catch {
        throw [Management.Automation.ErrorRecord]::new(
            [InvalidOperationException]::new('Trusted module import authority could not be acquired.'),
            $ErrorId,[Management.Automation.ErrorCategory]::InvalidData,$Path)
    }
}
# END CCOD TRUSTED IMPORT BOOTSTRAP

$script:CcodOfficialDraftExpectedVersion = '2.5.22'
$script:CcodOfficialDraftPhases = @(
    'Preflight',
    'LegacyUpgrade',
    'Uninstall',
    'FreshInstall',
    'PreReboot',
    'PostReboot',
    'ReadyForManualEvidence'
)
$script:CcodOfficialDraftPhaseFiles = @{
    Preflight = '01-Preflight.json'
    LegacyUpgrade = '02-LegacyUpgrade.json'
    Uninstall = '03-Uninstall.json'
    FreshInstall = '04-FreshInstall.json'
    PreReboot = '05-PreReboot.json'
    PostReboot = '06-PostReboot.json'
    ReadyForManualEvidence = '07-ReadyForManualEvidence.json'
}
$script:CcodOfficialDraftReceiptFields = @('schemaVersion','phase','candidate','draft','facts')
$script:CcodOfficialDraftDefenderReceiptFields = @(
    'schemaVersion','assetType','assetName','assetSha256','checksumName','checksumSha256',
    'manifestName','manifestSha256','version','gitCommit','origin','workflowArtifactIdentity',
    'zoneId','defenderServiceEnabled','antivirusEnabled','realTimeProtectionEnabled',
    'defenderPlatformVersion','defenderEngineVersion','signatureVersion','signatureUpdatedAtUtc',
    'scanStartedAtUtc','scanCompletedAtUtc','detectionCount','outcome','errorCode'
)
$script:CcodOfficialDraftAssetModule = $null
$script:CcodOfficialDraftDefenderModule = $null
$script:CcodOfficialDraftIntegrationModule = $null
$script:CcodOfficialDraftInstallRoot = $null
$script:CcodOfficialDraftManualAcknowledgement = $null
$script:CcodOfficialDraftLifecycleLoaded = $false
$script:CcodOfficialDraftCompletionFile = '08-Complete.json'
$script:CcodOfficialDraftManualDirectoryName = 'manual-evidence'
$script:CcodOfficialDraftManualArtifactRootName = 'official-draft-artifacts'
$script:CcodOfficialDraftManualOperations = @('About','Language','OpenLogs','Repair','SecondDeviceControl')
$script:CcodOfficialDraftManualFiles = @{
    About = 'TrayEvidence-About.json'
    Language = 'TrayEvidence-Language.json'
    OpenLogs = 'TrayEvidence-OpenLogs.json'
    Repair = 'TrayEvidence-Repair.json'
    SecondDeviceControl = 'RemoteEvidence-SecondDeviceControl.json'
}
$script:CcodOfficialDraftManualTerminalStates = @{
    About = 'AboutVisible'
    Language = 'LanguageChanged'
    OpenLogs = 'LogsOpened'
    Repair = 'RepairCompleted'
    SecondDeviceControl = 'SecondDeviceControlled'
}
$script:CcodOfficialDraftManualResultCodes = @{
    About = 'CCOD_TRAYABOUT_COMPLETED'
    Language = 'CCOD_TRAYLANGUAGE_COMPLETED'
    OpenLogs = 'CCOD_TRAYOPENLOGS_COMPLETED'
    Repair = 'CCOD_TRAYREPAIR_COMPLETED'
    SecondDeviceControl = 'CCOD_SECONDDEVICE_COMPLETED'
}
$script:CcodOfficialDraftManualRecordFields = @(
    'schemaVersion','kind','phase','operation','terminalState','result','proof','reviewState',
    'version','gitCommit','candidateManifestSha256','screenshotSha256','redactedLogSha256'
)

function Throw-CcodOfficialDraftError {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Message,
        $Target
    )
    throw [Management.Automation.ErrorRecord]::new(
        [InvalidOperationException]::new($Message),
        $Id,
        [Management.Automation.ErrorCategory]::InvalidOperation,
        $Target
    )
}

function Get-CcodOfficialDraftAssetModule {
    if ($null -eq $script:CcodOfficialDraftAssetModule) {
        $repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $path = Join-Path $repositoryRoot 'tools\ReleaseAssetContract.psm1'
        if (-not [IO.File]::Exists($path)) {
            Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_ASSET_CONTRACT_MISSING' 'The exact release asset contract module is missing.' $null
        }
        try {
            $lease = Open-CcodTrustedImportLease -Path $path -ErrorId 'CCOD_ACCEPTANCE_ASSET_CONTRACT_MISSING'
            try {
                $lease.Revalidate()
                $script:CcodOfficialDraftAssetModule = Import-Module $path -Force -PassThru -DisableNameChecking -ErrorAction Stop
                $lease.Revalidate()
            } finally { $lease.Dispose() }
        } catch {
            Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_ASSET_CONTRACT_MISSING' 'The exact release asset contract module could not be loaded.' $null
        }
    }
    return $script:CcodOfficialDraftAssetModule
}

function Get-CcodOfficialDraftDefenderModule {
    if ($null -eq $script:CcodOfficialDraftDefenderModule) {
        $repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $path = Join-Path $repositoryRoot 'tools\ReleaseDefender.psm1'
        if (-not [IO.File]::Exists($path)) {
            Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_DEFENDER_MODULE_MISSING' 'The release Defender module is missing.' $null
        }
        try {
            $lease = Open-CcodTrustedImportLease -Path $path -ErrorId 'CCOD_ACCEPTANCE_DEFENDER_MODULE_MISSING'
            try {
                $lease.Revalidate()
                $script:CcodOfficialDraftDefenderModule = Import-Module $path -Force -PassThru -DisableNameChecking -ErrorAction Stop
                $lease.Revalidate()
            } finally { $lease.Dispose() }
        } catch {
            Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_DEFENDER_MODULE_MISSING' 'The release Defender module could not be loaded.' $null
        }
    }
    return $script:CcodOfficialDraftDefenderModule
}

function Get-CcodOfficialDraftIntegrationModule {
    if ($null -eq $script:CcodOfficialDraftIntegrationModule) {
        $path = Join-Path $PSScriptRoot 'Invoke-InstalledLifecycleIntegration.ps1'
        if (-not [IO.File]::Exists($path)) {
            Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_INTEGRATION_MISSING' 'The installed-lifecycle integration entry point is missing.' $null
        }
        try {
            $lease = Open-CcodTrustedImportLease -Path $path -ErrorId 'CCOD_ACCEPTANCE_INTEGRATION_MISSING'
            try {
                $lease.Revalidate()
                $script:CcodOfficialDraftIntegrationModule = New-Module -Name ('CcodOfficialDraftIntegration-' + [guid]::NewGuid().ToString('N')) -ArgumentList $path -ScriptBlock {
                    param($IntegrationPath)
                    . $IntegrationPath -Library
                } -ErrorAction Stop
                $lease.Revalidate()
            } finally { $lease.Dispose() }
        } catch {
            Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_INTEGRATION_MISSING' 'The installed-lifecycle integration entry point could not be loaded safely.' $null
        }
    }
    return $script:CcodOfficialDraftIntegrationModule
}

function Assert-CcodOfficialDraftSafeDirectory {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ErrorId,
        [switch]$AllowMissing
    )
    try {
        if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathRooted($Path)) { throw 'absolute' }
        $full = [IO.Path]::GetFullPath($Path)
        $root = [IO.Path]::GetPathRoot($full)
        if ([string]::IsNullOrWhiteSpace($root)) { throw 'root' }
        $canonical = if ($full.Length -gt $root.Length) { $full.TrimEnd('\') } else { $full }
        $presented = if ($Path.Length -gt $root.Length) { $Path.TrimEnd('\') } else { $Path }
        if ($canonical -cne $presented) { throw 'noncanonical' }
        if ([IO.File]::Exists($canonical)) { throw 'file' }
        if (-not [IO.Directory]::Exists($canonical)) {
            if (-not $AllowMissing) { throw 'missing' }
            $parent = [IO.Directory]::GetParent($canonical)
            if ($null -eq $parent) { throw 'parent' }
            [void](Assert-CcodOfficialDraftSafeDirectory -Path $parent.FullName -ErrorId $ErrorId)
            [IO.Directory]::CreateDirectory($canonical) | Out-Null
        }
        $current = $canonical
        while (-not [string]::IsNullOrWhiteSpace($current)) {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if (-not $item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { throw 'unsafe' }
            $currentRoot = [IO.Path]::GetPathRoot($current)
            if ($current.TrimEnd('\') -ceq $currentRoot.TrimEnd('\')) { break }
            $parent = [IO.Directory]::GetParent($current)
            if ($null -eq $parent) { throw 'parent' }
            $next = if ($parent.FullName.Length -gt $currentRoot.Length) { $parent.FullName.TrimEnd('\') } else { $parent.FullName }
            if ($next -ceq $current) { break }
            $current = $next
        }
        return $canonical
    } catch {
        Throw-CcodOfficialDraftError $ErrorId 'Official-draft evidence root is missing, noncanonical, or unsafe.' $null
    }
}

function Assert-CcodOfficialDraftRegularFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ErrorId
    )
    try {
        if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathRooted($Path)) { throw 'absolute' }
        $full = [IO.Path]::GetFullPath($Path)
        $root = [IO.Path]::GetPathRoot($full)
        if ([string]::IsNullOrWhiteSpace($root) -or $full.TrimEnd('\') -cne $Path.TrimEnd('\')) { throw 'canonical' }
        if ([IO.File]::Exists($full) -eq $false) { throw 'missing' }
        $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
        if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { throw 'unsafe' }
        $parent = [IO.Directory]::GetParent($full)
        if ($null -eq $parent) { throw 'parent' }
        [void](Assert-CcodOfficialDraftSafeDirectory -Path $parent.FullName -ErrorId $ErrorId)
        return $full
    } catch {
        Throw-CcodOfficialDraftError $ErrorId 'Official-draft asset is missing or unsafe.' $null
    }
}

function Test-CcodOfficialDraftCanonicalUtc {
    param($Value)
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value)) { return $false }
    $parsed = [datetime]::MinValue
    return [datetime]::TryParseExact(
        $Value,
        'o',
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind,
        [ref]$parsed
    ) -and $parsed.Kind -eq [DateTimeKind]::Utc -and
        $parsed.ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture) -ceq $Value
}

function Test-CcodOfficialDraftExactProperties {
    param($Value, [Parameter(Mandatory)][string[]]$Expected)
    if ($null -eq $Value -or ($Value -isnot [pscustomobject] -and $Value -isnot [Collections.IDictionary])) { return $false }
    $actual = @(
        if ($Value -is [Collections.IDictionary]) {
            $Value.Keys | ForEach-Object { [string]$_ }
        } else {
            $Value.PSObject.Properties.Name
        }
    )
    return $actual.Count -eq $Expected.Count -and ($actual -join "`0") -ceq ($Expected -join "`0")
}

function Test-CcodOfficialDraftHash {
    param($Value)
    return $Value -is [string] -and $Value -cmatch '^[0-9a-f]{64}\z'
}

function Test-CcodOfficialDraftInt32 {
    param($Value)
    if ($null -eq $Value -or $Value -is [bool]) { return $false }
    if ($Value.GetType() -notin @([sbyte],[byte],[int16],[uint16],[int32],[uint32],[int64],[uint64])) { return $false }
    try {
        $number = [int64]$Value
        return $number -ge [int32]::MinValue -and $number -le [int32]::MaxValue
    } catch { return $false }
}

function Test-CcodOfficialDraftCommit {
    param($Value)
    return $Value -is [string] -and $Value -cmatch '^[0-9a-f]{40}\z'
}

function Get-CcodOfficialDraftExpectedAssetNames {
    $module = Get-CcodOfficialDraftAssetModule
    return @(&$module { param($Version) Get-CcodExpectedReleaseAssetNames -Version $Version } $script:CcodOfficialDraftExpectedVersion)
}

function Get-CcodOfficialDraftAssetHash {
    param([Parameter(Mandatory)]$Candidate, [Parameter(Mandatory)][string]$Name)
    foreach ($asset in @($Candidate.assetHashes)) {
        if ($asset.name -ceq $Name) { return [string]$asset.sha256 }
    }
    return $null
}

function ConvertTo-CcodOfficialDraftCandidate {
    param([Parameter(Mandatory)]$Value)
    try {
        if ($null -eq $Value -or $Value.Valid -isnot [bool] -or -not [bool]$Value.Valid -or
            $Value.Version -isnot [string] -or $Value.Version -cne $script:CcodOfficialDraftExpectedVersion -or
            -not (Test-CcodOfficialDraftCommit $Value.GitCommit)) { throw 'metadata' }
        $expected = @(Get-CcodOfficialDraftExpectedAssetNames)
        $assets = @($Value.Assets)
        if ($assets.Count -ne $expected.Count) { throw 'asset count' }
        $records = [Collections.Generic.List[object]]::new()
        for ($index = 0; $index -lt $expected.Count; $index++) {
            $asset = $assets[$index]
            if ($null -eq $asset -or
                -not (Test-CcodOfficialDraftExactProperties -Value $asset -Expected @('name','sha256')) -or
                $asset.name -isnot [string] -or $asset.name -cne $expected[$index] -or
                -not (Test-CcodOfficialDraftHash $asset.sha256)) { throw 'asset record' }
            $records.Add([pscustomobject][ordered]@{ name = [string]$asset.name; sha256 = [string]$asset.sha256 })
        }
        return [pscustomobject][ordered]@{
            version = [string]$Value.Version
            gitCommit = [string]$Value.GitCommit
            assetHashes = @($records)
            manifestHashes = [pscustomobject][ordered]@{
                portable = [string]$records[4].sha256
                setup = [string]$records[10].sha256
            }
        }
    } catch {
        Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_ASSET_CONTRACT_INVALID' 'The official draft does not satisfy the exact eleven-asset manifest contract.' $null
    }
}

function ConvertTo-CcodOfficialDraftPersistedCandidate {
    param([Parameter(Mandatory)]$Value)
    try {
        if (-not (Test-CcodOfficialDraftExactProperties -Value $Value -Expected @('version','gitCommit','assetHashes','manifestHashes')) -or
            $Value.version -isnot [string] -or $Value.version -cne $script:CcodOfficialDraftExpectedVersion -or
            -not (Test-CcodOfficialDraftCommit $Value.gitCommit)) { throw 'metadata' }
        $expected = @(Get-CcodOfficialDraftExpectedAssetNames)
        $assets = @($Value.assetHashes)
        if ($assets.Count -ne $expected.Count) { throw 'asset count' }
        $records = [Collections.Generic.List[object]]::new()
        for ($index = 0; $index -lt $expected.Count; $index++) {
            $asset = $assets[$index]
            if (-not (Test-CcodOfficialDraftExactProperties -Value $asset -Expected @('name','sha256')) -or
                $asset.name -isnot [string] -or $asset.name -cne $expected[$index] -or
                -not (Test-CcodOfficialDraftHash $asset.sha256)) { throw 'asset record' }
            $records.Add([pscustomobject][ordered]@{ name = [string]$asset.name; sha256 = [string]$asset.sha256 })
        }
        if (-not (Test-CcodOfficialDraftExactProperties -Value $Value.manifestHashes -Expected @('portable','setup')) -or
            -not (Test-CcodOfficialDraftHash $Value.manifestHashes.portable) -or
            -not (Test-CcodOfficialDraftHash $Value.manifestHashes.setup) -or
            [string]$Value.manifestHashes.portable -cne [string]$records[4].sha256 -or
            [string]$Value.manifestHashes.setup -cne [string]$records[10].sha256) { throw 'manifest hashes' }
        return [pscustomobject][ordered]@{
            version = [string]$Value.version
            gitCommit = [string]$Value.gitCommit
            assetHashes = @($records)
            manifestHashes = [pscustomobject][ordered]@{
                portable = [string]$records[4].sha256
                setup = [string]$records[10].sha256
            }
        }
    } catch {
        Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_RECEIPT_INVALID' 'The persisted official-draft candidate identity is malformed.' $null
    }
}

function ConvertTo-CcodOfficialDraftIdentity {
    param($Value)
    try {
        if ($null -eq $Value) { throw 'draft' }
        if (-not (Test-CcodOfficialDraftExactProperties -Value $Value -Expected @('tag','id')) -or
            $Value.tag -isnot [string] -or $Value.tag -cne 'v2.5.22') { throw 'draft' }
        if ($Value.id -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$Value.id) -or
            [string]$Value.id -notmatch '^[1-9][0-9]*\z') { throw 'id' }
        return [pscustomobject][ordered]@{
            tag = [string]$Value.tag
            id = [string]$Value.id
        }
    } catch {
        Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_DRAFT_IDENTITY_INVALID' 'The official draft tag or identifier is malformed.' $null
    }
}

function Test-CcodOfficialDraftCandidateEqual {
    param([Parameter(Mandatory)]$Left, [Parameter(Mandatory)]$Right)
    if ($Left.version -cne $Right.version -or $Left.gitCommit -cne $Right.gitCommit) { return $false }
    $leftAssets = @($Left.assetHashes); $rightAssets = @($Right.assetHashes)
    if ($leftAssets.Count -ne $rightAssets.Count) { return $false }
    for ($index = 0; $index -lt $leftAssets.Count; $index++) {
        if ($leftAssets[$index].name -cne $rightAssets[$index].name -or $leftAssets[$index].sha256 -cne $rightAssets[$index].sha256) { return $false }
    }
    if ($Left.manifestHashes.portable -cne $Right.manifestHashes.portable -or
        $Left.manifestHashes.setup -cne $Right.manifestHashes.setup) { return $false }
    return $true
}

function Test-CcodOfficialDraftDraftEqual {
    param([AllowNull()]$Left,[AllowNull()]$Right)
    if ($null -eq $Left -or $null -eq $Right) { return $false }
    $leftTag = $Left.PSObject.Properties['tag']; $rightTag = $Right.PSObject.Properties['tag']
    $leftId = $Left.PSObject.Properties['id']; $rightId = $Right.PSObject.Properties['id']
    if (@($leftTag).Count -ne 1 -or @($rightTag).Count -ne 1 -or @($leftId).Count -ne 1 -or @($rightId).Count -ne 1) { return $false }
    return [string]$leftTag.Value -ceq [string]$rightTag.Value -and [string]$leftId.Value -ceq [string]$rightId.Value
}

function Close-CcodOfficialDraftOperationLease {
    param($Lease)
    if ($null -eq $Lease -or $Lease.Closed) { return }
    $failed = $false
    if ($null -ne $Lease.Stream) { try { $Lease.Stream.Dispose() } catch { $failed = $true } }
    for ($index = $Lease.Parents.Count - 1; $index -ge 0; $index--) {
        try { $Lease.Parents[$index].Handle.Dispose() } catch { $failed = $true }
    }
    $Lease.Closed = $true
    if ($failed) { Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_OPERATION_LOCK_FAILED' 'Acceptance operation authority could not be released.' $null }
}

function Open-CcodOfficialDraftOperationLease {
    param([Parameter(Mandatory)][string]$EvidenceRoot)
    $root = Assert-CcodOfficialDraftSafeDirectory -Path $EvidenceRoot -ErrorId 'CCOD_ACCEPTANCE_EVIDENCE_ROOT_INVALID'
    $assetModule = Get-CcodOfficialDraftAssetModule
    $lease = [pscustomobject]@{ Stream = $null; Parents = [Collections.Generic.List[object]]::new(); Closed = $false }
    try {
        $directories = [Collections.Generic.List[string]]::new()
        for ($directory = [IO.DirectoryInfo]::new($root); $null -ne $directory; $directory = $directory.Parent) { $directories.Insert(0,$directory.FullName) }
        foreach ($path in $directories) {
            $handle = [CcodReleaseFileAuthorityV1]::OpenDirectory($path,$true)
            $entry = [pscustomobject]@{ Path = $path; Handle = $handle }
            $lease.Parents.Add($entry)
            $identity = [CcodReleaseFileAuthorityV1]::Identity($handle)
            if ([CcodReleaseFileAuthorityV1]::IsReparse($identity) -or -not [CcodReleaseFileAuthorityV1]::IsDirectory($identity) -or
                -not $identity.FinalPath.TrimEnd('\').Equals($path.TrimEnd('\'),[StringComparison]::OrdinalIgnoreCase)) { throw 'operation ancestry' }
        }
        $lockPath = Join-Path $root '.ccod-official-draft-operation.lock'
        try { $lease.Stream = [CcodReleaseFileAuthorityV1]::OpenExclusiveOperationFile($lockPath) }
        catch {
            $exception = $_.Exception
            while ($null -ne $exception -and $exception -isnot [ComponentModel.Win32Exception]) { $exception = $exception.InnerException }
            if ($null -ne $exception -and $exception.NativeErrorCode -in @(32,33)) {
                Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_OPERATION_BUSY' 'Another acceptance operation owns this evidence root.' $null
            }
            throw
        }
        $identity = [CcodReleaseFileAuthorityV1]::Identity($lease.Stream.SafeFileHandle)
        if ([CcodReleaseFileAuthorityV1]::IsDirectory($identity) -or [CcodReleaseFileAuthorityV1]::IsReparse($identity) -or
            $identity.Links -ne 1 -or $lease.Stream.Length -ne 0 -or
            -not $identity.FinalPath.Equals($lockPath,[StringComparison]::OrdinalIgnoreCase) -or
            -not (& $assetModule {param($Value) Test-CcodReleaseAuthorityStreams -Identity $Value} $identity)) { throw 'operation lock identity' }
        # The empty lock leaf is retained. Deleting it on release would race the next opener.
        return $lease
    } catch {
        $failure = $_
        Close-CcodOfficialDraftOperationLease $lease
        if ($failure.FullyQualifiedErrorId -like 'CCOD_ACCEPTANCE_*') { throw $failure }
        Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_OPERATION_LOCK_FAILED' 'Acceptance operation authority could not be acquired safely.' $null
    }
}

function Get-CcodOfficialDraftStateDirectory {
    param([Parameter(Mandatory)][string]$EvidenceRoot)
    $root = Assert-CcodOfficialDraftSafeDirectory -Path $EvidenceRoot -ErrorId 'CCOD_ACCEPTANCE_EVIDENCE_ROOT_INVALID'
    $state = [IO.Path]::GetFullPath((Join-Path $root 'official-draft-acceptance'))
    if ([IO.File]::Exists($state)) {
        Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_EVIDENCE_ROOT_INVALID' 'The official-draft state directory is not a directory.' $null
    }
    if (-not [IO.Directory]::Exists($state)) {
        try { [IO.Directory]::CreateDirectory($state) | Out-Null } catch { Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_EVIDENCE_ROOT_INVALID' 'The official-draft state directory could not be created safely.' $null }
    }
    return (Assert-CcodOfficialDraftSafeDirectory -Path $state -ErrorId 'CCOD_ACCEPTANCE_EVIDENCE_ROOT_INVALID')
}

function Get-CcodOfficialDraftManualDirectory {
    param([Parameter(Mandatory)][string]$StateDirectory)
    $path = Join-Path $StateDirectory $script:CcodOfficialDraftManualDirectoryName
    if ([IO.File]::Exists($path)) {
        Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_EVIDENCE_ROOT_INVALID' 'The manual-evidence state path is a file.' $null
    }
    if (-not [IO.Directory]::Exists($path)) {
        try { [IO.Directory]::CreateDirectory($path) | Out-Null }
        catch { Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_EVIDENCE_ROOT_INVALID' 'The manual-evidence state directory could not be created safely.' $null }
    }
    return (Assert-CcodOfficialDraftSafeDirectory -Path $path -ErrorId 'CCOD_ACCEPTANCE_EVIDENCE_ROOT_INVALID')
}

function Get-CcodOfficialDraftManualEvidencePath {
    param([Parameter(Mandatory)][string]$StateDirectory,[Parameter(Mandatory)][string]$Operation)
    if (-not $script:CcodOfficialDraftManualFiles.ContainsKey($Operation)) {
        Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_MANUAL_OPERATION_INVALID' 'The manual evidence operation is unsupported.' $null
    }
    $directory = Get-CcodOfficialDraftManualDirectory -StateDirectory $StateDirectory
    $path = Join-Path $directory $script:CcodOfficialDraftManualFiles[$Operation]
    if ([IO.Directory]::Exists($path)) {
        Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_PHASE_REUSED' 'The manual evidence operation already has a receipt.' $null
    }
    if ([IO.File]::Exists($path)) {
        Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_PHASE_REUSED' 'The manual evidence operation already has a receipt.' $null
    }
    return $path
}

function Get-CcodOfficialDraftCompleteAcceptancePath {
    param([Parameter(Mandatory)][string]$EvidenceRoot)
    $root = Assert-CcodOfficialDraftSafeDirectory -Path $EvidenceRoot -ErrorId 'CCOD_ACCEPTANCE_EVIDENCE_ROOT_INVALID'
    $directory = Join-Path $root 'acceptance'
    if ([IO.File]::Exists($directory)) {
        Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_EVIDENCE_ROOT_INVALID' 'The acceptance evidence path is a file.' $null
    }
    if (-not [IO.Directory]::Exists($directory)) {
        try { [IO.Directory]::CreateDirectory($directory) | Out-Null }
        catch { Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_EVIDENCE_ROOT_INVALID' 'The acceptance evidence directory could not be created safely.' $null }
    }
    $directory = Assert-CcodOfficialDraftSafeDirectory -Path $directory -ErrorId 'CCOD_ACCEPTANCE_EVIDENCE_ROOT_INVALID'
    $path = Join-Path $directory 'CodexRemote-fix-2.5.22-official-draft.complete.json'
    if ([IO.File]::Exists($path) -or [IO.Directory]::Exists($path)) {
        Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_PHASE_REUSED' 'The complete acceptance receipt already exists.' $null
    }
    return $path
}

function Read-CcodOfficialDraftJson {
    param([Parameter(Mandatory)][string]$Path)
    $module = Get-CcodOfficialDraftAssetModule
    try {
        return & $module { param($JsonPath) Read-CcodReleaseContractJson -Path $JsonPath -ErrorId 'CCOD_ACCEPTANCE_RECEIPT_INVALID' -MaximumBytes 1048576 } $Path
    } catch {
        Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_RECEIPT_INVALID' 'An official-draft receipt is malformed or unreadable.' $null
    }
}

function Assert-CcodOfficialDraftDefenderReceipt {
    param(
        [Parameter(Mandatory)]$Receipt,
        [Parameter(Mandatory)]$Candidate,
        [Parameter(Mandatory)][ValidateSet('Setup','PortableZip')][string]$AssetType
    )
    try {
        if (-not (Test-CcodOfficialDraftExactProperties -Value $Receipt -Expected $script:CcodOfficialDraftDefenderReceiptFields) -or
            -not (Test-CcodOfficialDraftInt32 $Receipt.schemaVersion) -or $Receipt.schemaVersion -ne 2 -or
            $Receipt.assetType -isnot [string] -or $Receipt.assetType -cne $AssetType) { throw 'receipt frame' }
        $expected = @(Get-CcodOfficialDraftExpectedAssetNames)
        $assetIndex = if ($AssetType -ceq 'Setup') { 5 } else { 0 }
        $checksumIndex = if ($AssetType -ceq 'Setup') { 6 } else { 1 }
        $manifestIndex = if ($AssetType -ceq 'Setup') { 10 } else { 4 }
        if ($Receipt.assetName -isnot [string] -or $Receipt.checksumName -isnot [string] -or $Receipt.manifestName -isnot [string] -or
            $Receipt.assetSha256 -isnot [string] -or $Receipt.checksumSha256 -isnot [string] -or $Receipt.manifestSha256 -isnot [string] -or
            $Receipt.version -isnot [string] -or $Receipt.gitCommit -isnot [string] -or $Receipt.origin -isnot [string]) { throw 'receipt scalar types' }
        if ($Receipt.assetName -cne $expected[$assetIndex] -or $Receipt.checksumName -cne $expected[$checksumIndex] -or
            $Receipt.manifestName -cne $expected[$manifestIndex] -or
            $Receipt.assetSha256 -cne (Get-CcodOfficialDraftAssetHash $Candidate $expected[$assetIndex]) -or
            $Receipt.checksumSha256 -cne (Get-CcodOfficialDraftAssetHash $Candidate $expected[$checksumIndex]) -or
            $Receipt.manifestSha256 -cne (Get-CcodOfficialDraftAssetHash $Candidate $expected[$manifestIndex]) -or
            $Receipt.version -cne $Candidate.version -or $Receipt.gitCommit -cne $Candidate.gitCommit -or
            $Receipt.origin -cne 'InternetDownload' -or $null -ne $Receipt.workflowArtifactIdentity -or
            -not (Test-CcodOfficialDraftInt32 $Receipt.zoneId) -or $Receipt.zoneId -ne 3 -or
            $Receipt.defenderServiceEnabled -isnot [bool] -or -not $Receipt.defenderServiceEnabled -or
            $Receipt.antivirusEnabled -isnot [bool] -or -not $Receipt.antivirusEnabled -or
            $Receipt.realTimeProtectionEnabled -isnot [bool] -or -not $Receipt.realTimeProtectionEnabled -or
            $Receipt.defenderPlatformVersion -isnot [string] -or [string]::IsNullOrWhiteSpace($Receipt.defenderPlatformVersion) -or $Receipt.defenderPlatformVersion.Length -gt 128 -or
            $Receipt.defenderEngineVersion -isnot [string] -or [string]::IsNullOrWhiteSpace($Receipt.defenderEngineVersion) -or $Receipt.defenderEngineVersion.Length -gt 128 -or
            $Receipt.signatureVersion -isnot [string] -or [string]::IsNullOrWhiteSpace($Receipt.signatureVersion) -or $Receipt.signatureVersion.Length -gt 128 -or
            -not (Test-CcodOfficialDraftCanonicalUtc $Receipt.signatureUpdatedAtUtc) -or
            -not (Test-CcodOfficialDraftCanonicalUtc $Receipt.scanStartedAtUtc) -or
            -not (Test-CcodOfficialDraftCanonicalUtc $Receipt.scanCompletedAtUtc) -or
            -not (Test-CcodOfficialDraftInt32 $Receipt.detectionCount) -or $Receipt.detectionCount -ne 0 -or
            $Receipt.outcome -isnot [string] -or $Receipt.outcome -cne 'Completed' -or $null -ne $Receipt.errorCode) { throw 'receipt binding' }
        $started = [datetime]::ParseExact($Receipt.scanStartedAtUtc,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
        $completed = [datetime]::ParseExact($Receipt.scanCompletedAtUtc,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
        $signature = [datetime]::ParseExact($Receipt.signatureUpdatedAtUtc,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
        if ($completed -lt $started -or $completed -gt $started.AddHours(2) -or $signature -lt $started.AddHours(-72) -or $signature -gt $started.AddMinutes(5)) { throw 'receipt time' }
        return [pscustomobject][ordered]@{
            schemaVersion = 2
            assetType = [string]$Receipt.assetType
            assetName = [string]$Receipt.assetName
            assetSha256 = [string]$Receipt.assetSha256
            checksumName = [string]$Receipt.checksumName
            checksumSha256 = [string]$Receipt.checksumSha256
            manifestName = [string]$Receipt.manifestName
            manifestSha256 = [string]$Receipt.manifestSha256
            version = [string]$Receipt.version
            gitCommit = [string]$Receipt.gitCommit
            origin = 'InternetDownload'
            workflowArtifactIdentity = $null
            zoneId = 3
            defenderServiceEnabled = $true
            antivirusEnabled = $true
            realTimeProtectionEnabled = $true
            defenderPlatformVersion = [string]$Receipt.defenderPlatformVersion
            defenderEngineVersion = [string]$Receipt.defenderEngineVersion
            signatureVersion = [string]$Receipt.signatureVersion
            signatureUpdatedAtUtc = [string]$Receipt.signatureUpdatedAtUtc
            scanStartedAtUtc = [string]$Receipt.scanStartedAtUtc
            scanCompletedAtUtc = [string]$Receipt.scanCompletedAtUtc
            detectionCount = 0
            outcome = 'Completed'
            errorCode = $null
        }
    } catch {
        Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_DEFENDER_RECEIPT_INVALID' 'The official downloaded-asset Defender receipt is missing, mismatched, or incomplete.' $null
    }
}

function ConvertTo-CcodOfficialDraftDefenderReceipt {
    param([Parameter(Mandatory)]$Receipt, [Parameter(Mandatory)]$Candidate, [Parameter(Mandatory)][string]$AssetType)
    $normalized = Assert-CcodOfficialDraftDefenderReceipt -Receipt $Receipt -Candidate $Candidate -AssetType $AssetType
    return $normalized
}

function Test-CcodOfficialDraftPositiveInteger {
    param($Value)
    if (-not (Test-CcodOfficialDraftIntegerValue $Value)) { return $false }
    try { return [UInt64]$Value -gt 0 } catch { return $false }
}

function ConvertTo-CcodOfficialDraftTrayHostIdentity {
    param([Parameter(Mandatory)]$Value)
    try {
        if (-not (Test-CcodOfficialDraftExactProperties -Value $Value -Expected @('pid','creationTimeUtc')) -or
            -not (Test-CcodOfficialDraftIntegerValue $Value.pid) -or [UInt64]$Value.pid -le 0 -or [UInt64]$Value.pid -gt [UInt64][int]::MaxValue -or
            $Value.creationTimeUtc -isnot [string] -or -not (Test-CcodOfficialDraftCanonicalUtc $Value.creationTimeUtc)) { throw 'tray host identity' }
        return [pscustomobject][ordered]@{ pid = [int]$Value.pid; creationTimeUtc = [string]$Value.creationTimeUtc }
    } catch {
        Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_RECEIPT_INVALID' 'TrayHost identity is missing or malformed.' $null
    }
}

function ConvertTo-CcodOfficialDraftSafeProcessIdentity {
    param([Parameter(Mandatory)]$Value,[Parameter(Mandatory)][string]$Label)
    if ($null -eq $Value -or -not (Test-CcodOfficialDraftExactProperties -Value $Value -Expected @('pid','creationTimeUtc')) -or
        -not (Test-CcodOfficialDraftPositiveInteger $Value.pid) -or [UInt64]$Value.pid -gt [UInt64][int]::MaxValue -or
        $Value.creationTimeUtc -isnot [string] -or -not (Test-CcodOfficialDraftCanonicalUtc $Value.creationTimeUtc)) { throw "$Label identity" }
    return [pscustomobject][ordered]@{ pid = [int]$Value.pid; creationTimeUtc = [string]$Value.creationTimeUtc }
}

function ConvertTo-CcodOfficialDraftLegacyObservation {
    param([Parameter(Mandatory)]$Facts,[Parameter(Mandatory)][string]$ExpectedVersion)
    try {
        $required = @('installRootPresent','installReady','appRootPresent','runtimeRootPresent','activePointerPresent','activeRuntimeId','activeGeneration','runtimeManifestSha256','supervisor','trayHost','codex','trayHostIdentity','trayAuthenticated','taskState','statusPhase','statusRuntimeId','statusCodex','transitionStage','lifecycleReceipt','aboutVersion','deviceKeyPresent','deviceKeySha256','shortcuts','debugPorts','debugEndpoints','protectionReady','bootId')
        foreach ($name in $required) {
            if (-not (Test-CcodOfficialDraftHasFact -Facts $Facts -Name $name)) { throw 'legacy observation shape' }
        }
        foreach ($name in @('installRootPresent','installReady','appRootPresent','runtimeRootPresent','activePointerPresent','trayAuthenticated','deviceKeyPresent','protectionReady')) {
            $value = Get-CcodOfficialDraftFactValue -Facts $Facts -Name $name
            if ($value -isnot [bool] -or -not [bool]$value) { throw 'legacy observation readiness' }
        }
        $activeRuntimeId = Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'activeRuntimeId'
        $activeGeneration = Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'activeGeneration'
        $manifestHash = Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'runtimeManifestSha256'
        if ($activeRuntimeId -isnot [string] -or $activeRuntimeId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,95}\z' -or
            -not (Test-CcodOfficialDraftPositiveInteger $activeGeneration) -or
            -not (Test-CcodOfficialDraftHash $manifestHash)) { throw 'legacy observation runtime' }
        $aboutVersion = Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'aboutVersion'
        $statusPhase = Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'statusPhase'
        $statusRuntimeId = Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'statusRuntimeId'
        $taskState = Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'taskState'
        $transitionStage = Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'transitionStage'
        $bootId = Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'bootId'
        if ($aboutVersion -isnot [string] -or $aboutVersion -cne $ExpectedVersion -or
            $statusPhase -isnot [string] -or $statusPhase -cne 'Active' -or
            $statusRuntimeId -isnot [string] -or $statusRuntimeId -cne $activeRuntimeId -or
            $taskState -isnot [string] -or $taskState -notin @('Ready','Running') -or
            $transitionStage -isnot [string] -or $transitionStage -cne 'Idle' -or
            $bootId -isnot [string] -or $bootId -notmatch '^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\z') { throw 'legacy observation status' }
        $supervisor = [Collections.Generic.List[object]]::new()
        foreach ($record in @((Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'supervisor'))) { [void]$supervisor.Add((ConvertTo-CcodOfficialDraftSafeProcessIdentity -Value $record -Label 'supervisor')) }
        $trayHost = [Collections.Generic.List[object]]::new()
        foreach ($record in @((Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'trayHost'))) { [void]$trayHost.Add((ConvertTo-CcodOfficialDraftSafeProcessIdentity -Value $record -Label 'tray host')) }
        $codex = [Collections.Generic.List[object]]::new()
        foreach ($record in @((Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'codex'))) { [void]$codex.Add((ConvertTo-CcodOfficialDraftSafeProcessIdentity -Value $record -Label 'codex')) }
        if ($supervisor.Count -ne 1 -or $trayHost.Count -ne 1 -or $codex.Count -ne 1) { throw 'legacy observation process count' }
        $trayIdentity = ConvertTo-CcodOfficialDraftTrayHostIdentity -Value (Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'trayHostIdentity')
        if ($trayIdentity.pid -ne $trayHost[0].pid -or $trayIdentity.creationTimeUtc -cne $trayHost[0].creationTimeUtc) { throw 'legacy observation tray identity' }
        $statusCodex = ConvertTo-CcodOfficialDraftSafeProcessIdentity -Value (Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'statusCodex') -Label 'status codex'
        if ($statusCodex.pid -ne $codex[0].pid -or $statusCodex.creationTimeUtc -cne $codex[0].creationTimeUtc) { throw 'legacy observation codex identity' }
        $terminal = ConvertTo-CcodOfficialDraftTerminalReceipt -Receipt (Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'lifecycleReceipt')
        if ($terminal.runtimeId -cne $activeRuntimeId -or [UInt64]$terminal.runtimeGeneration -ne [UInt64]$activeGeneration) { throw 'legacy observation receipt' }
        $shortcuts = Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'shortcuts'
        if (-not (Test-CcodOfficialDraftExactProperties -Value $shortcuts -Expected @('startMenu','desktop')) -or
            $shortcuts.startMenu -isnot [bool] -or -not [bool]$shortcuts.startMenu -or
            $shortcuts.desktop -isnot [bool] -or -not [bool]$shortcuts.desktop) { throw 'legacy observation shortcuts' }
        $debugPorts = @((Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'debugPorts'))
        if ($debugPorts.Count -ne 2 -or @($debugPorts | Sort-Object -Unique).Count -ne 2) { throw 'legacy observation debug ports' }
        foreach ($port in $debugPorts) {
            if (-not (Test-CcodOfficialDraftPositiveInteger $port) -or [UInt64]$port -gt 65535) { throw 'legacy observation debug port' }
        }
        $debugEndpoints = @((Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'debugEndpoints'))
        [void](Assert-CcodOfficialDraftDebugEndpointOwnership -Endpoints $debugEndpoints -ExpectedPorts ([int[]]$debugPorts) -ExpectedPid $codex[0].pid -ExpectedCreationTimeUtc $codex[0].creationTimeUtc)
        $keyHash = Get-CcodOfficialDraftObservedKeyHash -Facts $Facts
        if (-not (Test-CcodOfficialDraftHash $keyHash)) { throw 'legacy observation key' }
        return [pscustomobject][ordered]@{
            version = $ExpectedVersion
            bootId = [string]$bootId
            installRootPresent = $true
            installReady = $true
            appRootPresent = $true
            runtimeRootPresent = $true
            activePointerPresent = $true
            activeRuntimeId = [string]$activeRuntimeId
            activeGeneration = [UInt64]$activeGeneration
            runtimeManifestSha256 = [string]$manifestHash
            supervisor = @($supervisor)
            trayHost = @($trayHost)
            codex = @($codex)
            trayHostIdentity = $trayIdentity
            trayAuthenticated = $true
            taskState = [string]$taskState
            statusPhase = 'Active'
            statusRuntimeId = [string]$statusRuntimeId
            statusCodex = $statusCodex
            transitionStage = 'Idle'
            lifecycleReceipt = $terminal
            aboutVersion = $ExpectedVersion
            deviceKeyPresent = $true
            deviceKeySha256 = [string]$keyHash
            shortcuts = [pscustomobject][ordered]@{ startMenu = $true; desktop = $true }
            debugPorts = [int[]]$debugPorts
            debugEndpoints = @($debugEndpoints)
            protectionReady = $true
        }
    } catch {
        if ($_.FullyQualifiedErrorId -like 'CCOD_ACCEPTANCE_*') { throw }
        Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_OBSERVATION_UNAVAILABLE' 'Installed lifecycle readiness could not be proven for the legacy upgrade boundary.' $null
    }
}

function Assert-CcodOfficialDraftPersistedPhaseFacts {
    param([Parameter(Mandatory)][string]$Phase,[Parameter(Mandatory)]$Facts)
    try {
        switch ($Phase) {
            'LegacyUpgrade' {
                if (-not (Test-CcodOfficialDraftExactProperties -Value $Facts -Expected @('previousSetup','before','after','deviceKeySha256Before','deviceKeySha256After','keyHashPreserved','operationOutcome')) -or
                    -not (Test-CcodOfficialDraftExactProperties -Value $Facts.previousSetup -Expected @('version','gitCommit','assetSha256','manifestSha256')) -or
                    $Facts.previousSetup.version -cne '2.5.21' -or -not (Test-CcodOfficialDraftCommit $Facts.previousSetup.gitCommit) -or
                    -not (Test-CcodOfficialDraftHash $Facts.previousSetup.assetSha256) -or -not (Test-CcodOfficialDraftHash $Facts.previousSetup.manifestSha256) -or
                    -not (Test-CcodOfficialDraftHash $Facts.deviceKeySha256Before) -or -not (Test-CcodOfficialDraftHash $Facts.deviceKeySha256After) -or
                    $Facts.deviceKeySha256Before -cne $Facts.deviceKeySha256After -or $Facts.keyHashPreserved -isnot [bool] -or
                    -not [bool]$Facts.keyHashPreserved -or $Facts.operationOutcome -isnot [string] -or $Facts.operationOutcome -cne 'Completed') { throw 'legacy facts' }
                $before = ConvertTo-CcodOfficialDraftLegacyObservation -Facts $Facts.before -ExpectedVersion '2.5.21'
                $after = ConvertTo-CcodOfficialDraftLegacyObservation -Facts $Facts.after -ExpectedVersion $script:CcodOfficialDraftExpectedVersion
                if ($before.deviceKeySha256 -cne [string]$Facts.deviceKeySha256Before -or $after.deviceKeySha256 -cne [string]$Facts.deviceKeySha256After) { throw 'legacy observation key binding' }
                return [pscustomobject][ordered]@{
                    previousSetup = $Facts.previousSetup
                    before = $before
                    after = $after
                    deviceKeySha256Before = [string]$Facts.deviceKeySha256Before
                    deviceKeySha256After = [string]$Facts.deviceKeySha256After
                    keyHashPreserved = $true
                    operationOutcome = 'Completed'
                }
            }
            'Uninstall' {
                if (-not (Test-CcodOfficialDraftExactProperties -Value $Facts -Expected @('stateRemoved','installRootPresent','appRootPresent','runtimeRootPresent','activePointerPresent','taskState','supervisorCount','trayHostCount','codexCount','shortcuts','debugEndpointsGone','deviceKeySha256Before','deviceKeySha256After','keyHashPreserved','operationOutcome')) -or
                    $Facts.stateRemoved -isnot [bool] -or -not $Facts.stateRemoved -or
                    $Facts.installRootPresent -isnot [bool] -or $Facts.installRootPresent -or
                    $Facts.appRootPresent -isnot [bool] -or $Facts.appRootPresent -or $Facts.runtimeRootPresent -isnot [bool] -or $Facts.runtimeRootPresent -or
                    $Facts.activePointerPresent -isnot [bool] -or $Facts.activePointerPresent -or $Facts.taskState -isnot [string] -or $Facts.taskState -cne 'Absent' -or
                    -not (Test-CcodOfficialDraftInt32 $Facts.supervisorCount) -or $Facts.supervisorCount -ne 0 -or -not (Test-CcodOfficialDraftInt32 $Facts.trayHostCount) -or $Facts.trayHostCount -ne 0 -or
                    -not (Test-CcodOfficialDraftInt32 $Facts.codexCount) -or $Facts.codexCount -ne 0 -or
                    $Facts.debugEndpointsGone -isnot [bool] -or -not $Facts.debugEndpointsGone -or
                    -not (Test-CcodOfficialDraftExactProperties -Value $Facts.shortcuts -Expected @('startMenu','desktop')) -or
                    $Facts.shortcuts.startMenu -isnot [bool] -or $Facts.shortcuts.startMenu -or $Facts.shortcuts.desktop -isnot [bool] -or $Facts.shortcuts.desktop -or
                    -not (Test-CcodOfficialDraftHash $Facts.deviceKeySha256Before) -or -not (Test-CcodOfficialDraftHash $Facts.deviceKeySha256After) -or
                    $Facts.deviceKeySha256Before -cne $Facts.deviceKeySha256After -or $Facts.keyHashPreserved -isnot [bool] -or -not $Facts.keyHashPreserved -or
                    $Facts.operationOutcome -isnot [string] -or $Facts.operationOutcome -cne 'Completed') { throw 'uninstall facts' }
            }
            'FreshInstall' {
                if (-not (Test-CcodOfficialDraftExactProperties -Value $Facts -Expected @('installRootPresent','installReady','activePointerPresent','activeRuntimeId','activeGeneration','runtimeManifestSha256','supervisorCount','trayHostCount','codexCount','trayHostIdentity','trayAuthenticated','taskState','terminalReceipt','protectionReady','deviceKeySha256','operationOutcome')) -or
                    $Facts.installRootPresent -isnot [bool] -or -not $Facts.installRootPresent -or
                    $Facts.installReady -isnot [bool] -or -not $Facts.installReady -or $Facts.activePointerPresent -isnot [bool] -or -not $Facts.activePointerPresent -or
                    $Facts.activeRuntimeId -isnot [string] -or $Facts.activeRuntimeId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,95}\z' -or
                    -not (Test-CcodOfficialDraftPositiveInteger $Facts.activeGeneration) -or -not (Test-CcodOfficialDraftHash $Facts.runtimeManifestSha256) -or
                    -not (Test-CcodOfficialDraftInt32 $Facts.supervisorCount) -or $Facts.supervisorCount -ne 1 -or -not (Test-CcodOfficialDraftInt32 $Facts.trayHostCount) -or $Facts.trayHostCount -ne 1 -or
                    -not (Test-CcodOfficialDraftInt32 $Facts.codexCount) -or $Facts.codexCount -ne 1 -or
                    $Facts.trayAuthenticated -isnot [bool] -or -not $Facts.trayAuthenticated -or $Facts.taskState -notin @('Ready','Running') -or
                    $Facts.protectionReady -isnot [bool] -or -not $Facts.protectionReady -or -not (Test-CcodOfficialDraftHash $Facts.deviceKeySha256)) { throw 'fresh facts' }
                $trayIdentity = ConvertTo-CcodOfficialDraftTrayHostIdentity -Value $Facts.trayHostIdentity
                $terminal = ConvertTo-CcodOfficialDraftTerminalReceipt -Receipt $Facts.terminalReceipt
                if ($terminal.runtimeId -cne $Facts.activeRuntimeId -or [UInt64]$terminal.runtimeGeneration -ne [UInt64]$Facts.activeGeneration -or
                    $Facts.operationOutcome -isnot [string] -or $Facts.operationOutcome -cne 'Completed') { throw 'fresh receipt binding' }
            }
            'PreReboot' {
                if (-not (Test-CcodOfficialDraftExactProperties -Value $Facts -Expected @('rebootRequested','bootIdBefore','freshInstallReceiptSha256','activeRuntimeId','activeGeneration','runtimeManifestSha256','deviceKeySha256','operationOutcome','observation')) -or
                    $Facts.rebootRequested -isnot [bool] -or -not $Facts.rebootRequested -or
                    $Facts.bootIdBefore -isnot [string] -or $Facts.bootIdBefore -notmatch '^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\z' -or
                    -not (Test-CcodOfficialDraftHash $Facts.freshInstallReceiptSha256) -or $Facts.activeRuntimeId -isnot [string] -or
                    $Facts.activeRuntimeId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,95}\z' -or -not (Test-CcodOfficialDraftPositiveInteger $Facts.activeGeneration) -or
                    -not (Test-CcodOfficialDraftHash $Facts.runtimeManifestSha256) -or
                    -not (Test-CcodOfficialDraftHash $Facts.deviceKeySha256) -or $Facts.operationOutcome -isnot [string] -or $Facts.operationOutcome -cne 'Completed') { throw 'pre facts' }
                $observation = ConvertTo-CcodOfficialDraftLegacyObservation -Facts $Facts.observation -ExpectedVersion $script:CcodOfficialDraftExpectedVersion
                if ($observation.bootId -cne $Facts.bootIdBefore -or $observation.activeRuntimeId -cne $Facts.activeRuntimeId -or
                    [UInt64]$observation.activeGeneration -ne [UInt64]$Facts.activeGeneration -or
                    $observation.runtimeManifestSha256 -cne $Facts.runtimeManifestSha256 -or
                    $observation.deviceKeySha256 -cne $Facts.deviceKeySha256) { throw 'pre observation continuity' }
                $Facts.observation = $observation
            }
            'PostReboot' {
                if (-not (Test-CcodOfficialDraftExactProperties -Value $Facts -Expected @('observation','installRootPresent','activePointerPresent','bootIdBefore','bootIdAfter','bootChanged','receiptContinuity','activeRuntimeId','activeGeneration','runtimeManifestSha256','transitionStage','protectionRecovered','protectionReady','taskState','supervisorCount','trayHostCount','codexCount','trayHostIdentity','trayAuthenticated','terminalReceipt','deviceKeySha256','keyHashPreserved','operationOutcome')) -or
                    $Facts.installRootPresent -isnot [bool] -or -not $Facts.installRootPresent -or $Facts.activePointerPresent -isnot [bool] -or -not $Facts.activePointerPresent -or
                    $Facts.bootIdBefore -isnot [string] -or $Facts.bootIdBefore -notmatch '^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\z' -or
                    $Facts.bootIdAfter -isnot [string] -or $Facts.bootIdAfter -notmatch '^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\z' -or $Facts.bootIdAfter -ceq $Facts.bootIdBefore -or
                    $Facts.bootChanged -isnot [bool] -or -not $Facts.bootChanged -or $Facts.receiptContinuity -isnot [bool] -or -not $Facts.receiptContinuity -or
                    $Facts.activeRuntimeId -isnot [string] -or $Facts.activeRuntimeId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,95}\z' -or
                    -not (Test-CcodOfficialDraftPositiveInteger $Facts.activeGeneration) -or -not (Test-CcodOfficialDraftHash $Facts.runtimeManifestSha256) -or $Facts.transitionStage -isnot [string] -or $Facts.transitionStage -cne 'Idle' -or
                    $Facts.protectionRecovered -isnot [bool] -or -not $Facts.protectionRecovered -or $Facts.protectionReady -isnot [bool] -or -not $Facts.protectionReady -or
                    $Facts.taskState -notin @('Ready','Running') -or -not (Test-CcodOfficialDraftInt32 $Facts.supervisorCount) -or $Facts.supervisorCount -ne 1 -or
                    -not (Test-CcodOfficialDraftInt32 $Facts.trayHostCount) -or $Facts.trayHostCount -ne 1 -or -not (Test-CcodOfficialDraftInt32 $Facts.codexCount) -or $Facts.codexCount -ne 1 -or $Facts.trayAuthenticated -isnot [bool] -or -not $Facts.trayAuthenticated -or
                    -not (Test-CcodOfficialDraftHash $Facts.deviceKeySha256) -or $Facts.keyHashPreserved -isnot [bool] -or -not $Facts.keyHashPreserved -or
                    $Facts.operationOutcome -isnot [string] -or $Facts.operationOutcome -cne 'Completed') { throw 'post facts' }
                $trayIdentity = ConvertTo-CcodOfficialDraftTrayHostIdentity -Value $Facts.trayHostIdentity
                $null = ConvertTo-CcodOfficialDraftTerminalReceipt -Receipt $Facts.terminalReceipt
                $observation = ConvertTo-CcodOfficialDraftLegacyObservation -Facts $Facts.observation -ExpectedVersion $script:CcodOfficialDraftExpectedVersion
                $observationTrayIdentity = ConvertTo-CcodOfficialDraftTrayHostIdentity -Value $observation.trayHostIdentity
                if ($trayIdentity.pid -ne $observationTrayIdentity.pid -or $trayIdentity.creationTimeUtc -cne $observationTrayIdentity.creationTimeUtc) { throw 'post tray identity binding' }
                if ($observation.bootId -cne $Facts.bootIdAfter -or $observation.activeRuntimeId -cne $Facts.activeRuntimeId -or
                    [UInt64]$observation.activeGeneration -ne [UInt64]$Facts.activeGeneration -or
                    $observation.runtimeManifestSha256 -cne $Facts.runtimeManifestSha256 -or
                    $observation.deviceKeySha256 -cne $Facts.deviceKeySha256) { throw 'post observation continuity' }
                $Facts.observation = $observation
            }
            'ReadyForManualEvidence' {
                if (-not (Test-CcodOfficialDraftExactProperties -Value $Facts -Expected @('automatedPhases','status','manualEvidencePending','complete','manualChallenge')) -or
                    (@($Facts.automatedPhases).Count -ne 6) -or
                    ((@($Facts.automatedPhases) -join "`0") -cne (@('Preflight','LegacyUpgrade','Uninstall','FreshInstall','PreReboot','PostReboot') -join "`0")) -or
                    $Facts.status -isnot [string] -or $Facts.status -cne 'ReadyForManualEvidence' -or
                    $Facts.manualEvidencePending -isnot [bool] -or -not $Facts.manualEvidencePending -or $Facts.complete -isnot [bool] -or $Facts.complete -or
                    $Facts.manualChallenge -isnot [string] -or $Facts.manualChallenge -cnotmatch '^[0-9a-f]{32}\z') { throw 'ready facts' }
            }
            default { throw 'phase facts' }
        }
        return $Facts
    } catch {
        if ($_.FullyQualifiedErrorId -like 'CCOD_ACCEPTANCE_*') { throw }
        Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_RECEIPT_INVALID' 'An official-draft phase receipt contains invalid bounded facts.' $null
    }
}

function Assert-CcodOfficialDraftReceiptShape {
    param([Parameter(Mandatory)]$Receipt, [Parameter(Mandatory)][string]$ExpectedPhase)
    try {
        if (-not (Test-CcodOfficialDraftExactProperties -Value $Receipt -Expected $script:CcodOfficialDraftReceiptFields) -or
            -not (Test-CcodOfficialDraftInt32 $Receipt.schemaVersion) -or $Receipt.schemaVersion -ne 1 -or
            $Receipt.phase -isnot [string] -or $Receipt.phase -cne $ExpectedPhase) { throw 'frame' }
        $candidate = ConvertTo-CcodOfficialDraftPersistedCandidate -Value $Receipt.candidate
        if (-not (Test-CcodOfficialDraftExactProperties -Value $Receipt.draft -Expected @('tag','id'))) { throw 'draft' }
        $draft = ConvertTo-CcodOfficialDraftIdentity -Value $Receipt.draft
        if ($null -eq $Receipt.facts -or $Receipt.facts -isnot [pscustomobject]) { throw 'facts' }
        if ($ExpectedPhase -ceq 'Preflight') {
            if (-not (Test-CcodOfficialDraftExactProperties -Value $Receipt.facts -Expected @('defenderReceipts'))) { throw 'preflight facts' }
            $defenders = @($Receipt.facts.defenderReceipts)
            if ($defenders.Count -ne 2) { throw 'defender count' }
            $first = Assert-CcodOfficialDraftDefenderReceipt -Receipt $defenders[0] -Candidate $candidate -AssetType Setup
            $second = Assert-CcodOfficialDraftDefenderReceipt -Receipt $defenders[1] -Candidate $candidate -AssetType PortableZip
            return [pscustomobject][ordered]@{
                schemaVersion = 1
                phase = $ExpectedPhase
                candidate = $candidate
                draft = $draft
                facts = [pscustomobject][ordered]@{ defenderReceipts = @($first,$second) }
            }
        }
        if ($ExpectedPhase -ceq 'Complete') {
            if (-not (Test-CcodOfficialDraftExactProperties -Value $Receipt.facts -Expected @('manualEvidence','status','complete')) -or
                $Receipt.facts.status -isnot [string] -or $Receipt.facts.status -cne 'Complete' -or
                $Receipt.facts.complete -isnot [bool] -or -not [bool]$Receipt.facts.complete) { throw 'complete facts' }
            $manual = Assert-CcodOfficialDraftManualEvidenceSet -Records $Receipt.facts.manualEvidence -Candidate $candidate
            return [pscustomobject][ordered]@{
                schemaVersion = 1
                phase = $ExpectedPhase
                candidate = $candidate
                draft = $draft
                facts = [pscustomobject][ordered]@{ manualEvidence = @($manual); status = 'Complete'; complete = $true }
            }
        }
        $normalizedFacts = Assert-CcodOfficialDraftPersistedPhaseFacts -Phase $ExpectedPhase -Facts $Receipt.facts
        return [pscustomobject][ordered]@{ schemaVersion = 1; phase = $ExpectedPhase; candidate = $candidate; draft = $draft; facts = $normalizedFacts }
    } catch {
        Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_RECEIPT_INVALID' 'An official-draft acceptance receipt is malformed or tampered.' $null
    }
}

function ConvertTo-CcodOfficialDraftTrayProof {
    param([Parameter(Mandatory)]$Proof,[Parameter(Mandatory)][string]$Operation)
    try {
        $allowed = @{
            About = @('ShowAbout')
            Language = @('SetLanguageSystem','SetLanguageChinese','SetLanguageEnglish')
            OpenLogs = @('OpenLogs')
            Repair = @('CheckAndRepair')
        }
        if ($null -eq $Proof -or -not (Test-CcodOfficialDraftExactProperties -Value $Proof -Expected @('timestampUtc','command','revision','code','status')) -or
            $Proof.timestampUtc -isnot [string] -or $Proof.command -isnot [string] -or
            -not $allowed.ContainsKey($Operation) -or $allowed[$Operation] -cnotcontains [string]$Proof.command -or
            -not (Test-CcodOfficialDraftPositiveInteger $Proof.revision) -or
            $Proof.code -isnot [string] -or $Proof.code -cne 'CCOD_TRAY_ACTION_COMPLETED' -or
            $Proof.status -isnot [string] -or $Proof.status -cne 'Completed') { throw 'tray proof' }
        if (-not (Test-CcodOfficialDraftCanonicalUtc $Proof.timestampUtc)) { throw 'tray timestamp' }
        return [pscustomobject][ordered]@{
            timestampUtc = [string]$Proof.timestampUtc
            command = [string]$Proof.command
            revision = [UInt64]$Proof.revision
            code = 'CCOD_TRAY_ACTION_COMPLETED'
            status = 'Completed'
        }
    } catch {
        Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_MANUAL_EVIDENCE_INVALID' 'Tray operation proof is malformed or not bound to the requested operation.' $null
    }
}

function ConvertTo-CcodOfficialDraftRemoteProof {
    param([Parameter(Mandatory)]$Proof)
    try {
        $expected = @('schemaVersion','timestampUtc','kind','operation','deviceRole','challenge','candidateVersion','runtimeId','runtimeGeneration','runtimeManifestSha256','attestation','connection','control','outcome','code')
        if ($null -eq $Proof -or -not (Test-CcodOfficialDraftExactProperties -Value $Proof -Expected $expected) -or
            -not (Test-CcodOfficialDraftIntegerValue $Proof.schemaVersion) -or [int64]$Proof.schemaVersion -ne 1 -or
            $Proof.timestampUtc -isnot [string] -or
            $Proof.kind -isnot [string] -or $Proof.kind -cne 'remote-control-manual-proof' -or
            $Proof.operation -isnot [string] -or $Proof.operation -cne 'SecondDeviceControl' -or
            $Proof.deviceRole -isnot [string] -or $Proof.deviceRole -cne 'SecondDevice' -or
            $Proof.challenge -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$Proof.challenge) -or
            $Proof.candidateVersion -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$Proof.candidateVersion) -or
            $Proof.runtimeId -isnot [string] -or $Proof.runtimeId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,95}\z' -or
            -not (Test-CcodOfficialDraftPositiveInteger $Proof.runtimeGeneration) -or
            $Proof.runtimeManifestSha256 -isnot [string] -or -not (Test-CcodOfficialDraftHash $Proof.runtimeManifestSha256) -or
            $Proof.attestation -isnot [string] -or $Proof.attestation -cne 'HumanReviewedStructuredAttestation' -or
            $Proof.connection -isnot [string] -or $Proof.connection -cne 'Connected' -or
            $Proof.control -isnot [string] -or $Proof.control -cne 'Completed' -or
            $Proof.outcome -isnot [string] -or $Proof.outcome -cne 'Completed' -or
            $Proof.code -isnot [string] -or $Proof.code -cne 'CCOD_REMOTE_ACTION_COMPLETED') { throw 'remote proof' }
        if (-not (Test-CcodOfficialDraftCanonicalUtc $Proof.timestampUtc)) { throw 'remote timestamp' }
        return [pscustomobject][ordered]@{
            schemaVersion = 1
            timestampUtc = [string]$Proof.timestampUtc
            kind = 'remote-control-manual-proof'
            operation = 'SecondDeviceControl'
            deviceRole = 'SecondDevice'
            challenge = [string]$Proof.challenge
            candidateVersion = [string]$Proof.candidateVersion
            runtimeId = [string]$Proof.runtimeId
            runtimeGeneration = [UInt64]$Proof.runtimeGeneration
            runtimeManifestSha256 = [string]$Proof.runtimeManifestSha256
            attestation = 'HumanReviewedStructuredAttestation'
            connection = 'Connected'
            control = 'Completed'
            outcome = 'Completed'
            code = 'CCOD_REMOTE_ACTION_COMPLETED'
        }
    } catch {
        Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_REMOTE_UNPROVEN' 'Second-device proof is malformed or does not prove a completed connection and control.' $null
    }
}

function Assert-CcodOfficialDraftManualRecordShape {
    param([Parameter(Mandatory)]$Record)
    try {
        if (-not (Test-CcodOfficialDraftExactProperties -Value $Record -Expected $script:CcodOfficialDraftManualRecordFields) -or
            -not (Test-CcodOfficialDraftInt32 $Record.schemaVersion) -or $Record.schemaVersion -ne 1 -or
            $Record.kind -isnot [string] -or $Record.kind -cne 'manual-evidence' -or
            $Record.phase -isnot [string] -or $Record.phase -cnotin @('TrayEvidence','RemoteEvidence') -or
            $Record.operation -isnot [string] -or -not $script:CcodOfficialDraftManualFiles.ContainsKey($Record.operation) -or
            $Record.terminalState -isnot [string] -or $Record.terminalState -cne [string]$script:CcodOfficialDraftManualTerminalStates[$Record.operation] -or
            $Record.result -isnot [string] -or $Record.result -cne [string]$script:CcodOfficialDraftManualResultCodes[$Record.operation] -or
            $Record.reviewState -isnot [string] -or $Record.reviewState -cne 'Reviewed' -or
            $Record.version -isnot [string] -or $Record.version -cne $script:CcodOfficialDraftExpectedVersion -or
            -not (Test-CcodOfficialDraftCommit $Record.gitCommit) -or
            -not (Test-CcodOfficialDraftHash $Record.candidateManifestSha256) -or
            -not (Test-CcodOfficialDraftHash $Record.screenshotSha256) -or
            -not (Test-CcodOfficialDraftHash $Record.redactedLogSha256) -or
            $Record.screenshotSha256 -ceq $Record.redactedLogSha256) { throw 'manual record' }
        if (($Record.phase -ceq 'TrayEvidence' -and $Record.operation -ceq 'SecondDeviceControl') -or
            ($Record.phase -ceq 'RemoteEvidence' -and $Record.operation -cne 'SecondDeviceControl')) { throw 'manual phase' }
        $proof = $null
        if ($Record.operation -ceq 'SecondDeviceControl') { $proof = ConvertTo-CcodOfficialDraftRemoteProof -Proof $Record.proof } else { $proof = ConvertTo-CcodOfficialDraftTrayProof -Proof $Record.proof -Operation ([string]$Record.operation) }
        return [pscustomobject][ordered]@{
            schemaVersion = 1
            kind = 'manual-evidence'
            phase = [string]$Record.phase
            operation = [string]$Record.operation
            terminalState = [string]$Record.terminalState
            result = [string]$Record.result
            proof = $proof
            reviewState = 'Reviewed'
            version = [string]$Record.version
            gitCommit = [string]$Record.gitCommit
            candidateManifestSha256 = [string]$Record.candidateManifestSha256
            screenshotSha256 = [string]$Record.screenshotSha256
            redactedLogSha256 = [string]$Record.redactedLogSha256
        }
    } catch {
        Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_MANUAL_EVIDENCE_INVALID' 'Manual evidence is malformed, unreviewed, or not operation-bound.' $null
    }
}

function Assert-CcodOfficialDraftManualEvidenceSet {
    param([Parameter(Mandatory)]$Records, [Parameter(Mandatory)]$Candidate)
    try {
        $values = if ($Records -is [Collections.IDictionary]) { @($Records.Values) } else { @($Records) }
        $expectedOperations = @('About','Language','OpenLogs','Repair','SecondDeviceControl')
        if ($values.Count -ne $expectedOperations.Count) { throw 'manual count' }
        $normalized = [Collections.Generic.List[object]]::new()
        $seenOperations = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $seenHashes = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($operation in $expectedOperations) {
            $matches = @($values | Where-Object { $_.operation -ceq $operation })
            if ($matches.Count -ne 1) { throw 'manual operation' }
            $record = Assert-CcodOfficialDraftManualRecordShape -Record $matches[0]
            if (-not $seenOperations.Add($record.operation) -or
                $record.version -cne $Candidate.version -or $record.gitCommit -cne $Candidate.gitCommit -or
                $record.candidateManifestSha256 -cne $Candidate.manifestHashes.portable -or
                ($record.operation -ceq 'SecondDeviceControl' -and ($record.proof.candidateVersion -isnot [string] -or $record.proof.candidateVersion -cne $Candidate.version)) -or
                -not $seenHashes.Add($record.screenshotSha256) -or -not $seenHashes.Add($record.redactedLogSha256)) { throw 'manual binding' }
            $normalized.Add($record)
        }
        return @($normalized)
    } catch {
        if ($_.FullyQualifiedErrorId -like 'CCOD_ACCEPTANCE_*') { throw }
        Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_MANUAL_EVIDENCE_INCOMPLETE' 'All four tray records and the distinct second-device record are required.' $null
    }
}

function Read-CcodOfficialDraftState {
    param([Parameter(Mandatory)][string]$StateDirectory,[string]$PreviousAssetDirectory)
    [void](Assert-CcodOfficialDraftSafeDirectory -Path $StateDirectory -ErrorId 'CCOD_ACCEPTANCE_RECEIPT_INVALID')
    [void](Repair-CcodOfficialDraftOrphanTemporaryFiles -StateDirectory $StateDirectory)
    $records = @{}
    try { $children = @(Get-ChildItem -LiteralPath $StateDirectory -Force -ErrorAction Stop) } catch { Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_RECEIPT_INVALID' 'Official-draft acceptance state could not be enumerated safely.' $null }
    $allowed = @($script:CcodOfficialDraftPhaseFiles.Values) + @($script:CcodOfficialDraftCompletionFile,$script:CcodOfficialDraftManualDirectoryName)
    foreach ($child in $children) {
        if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            $allowed -cnotcontains [string]$child.Name -or
            ([string]$child.Name -ceq $script:CcodOfficialDraftManualDirectoryName -and -not $child.PSIsContainer) -or
            ([string]$child.Name -cne $script:CcodOfficialDraftManualDirectoryName -and $child.PSIsContainer)) {
            Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_RECEIPT_INVALID' 'Official-draft acceptance state contains an unexpected entry.' $null
        }
    }
    foreach ($phase in $script:CcodOfficialDraftPhases) {
        $path = Join-Path $StateDirectory $script:CcodOfficialDraftPhaseFiles[$phase]
        if (-not (Get-CcodOfficialDraftOptionalPathState -Path $path -ExpectDirectory $false -GetItem { param($CandidatePath) Get-Item -LiteralPath $CandidatePath -Force -ErrorAction Stop } -ErrorId 'CCOD_ACCEPTANCE_RECEIPT_INVALID')) { continue }
        $json = Read-CcodOfficialDraftJson -Path $path
        $records[$phase] = Assert-CcodOfficialDraftReceiptShape -Receipt $json.Value -ExpectedPhase $phase
    }
    $completePath = Join-Path $StateDirectory $script:CcodOfficialDraftCompletionFile
    if (Get-CcodOfficialDraftOptionalPathState -Path $completePath -ExpectDirectory $false -GetItem { param($CandidatePath) Get-Item -LiteralPath $CandidatePath -Force -ErrorAction Stop } -ErrorId 'CCOD_ACCEPTANCE_RECEIPT_INVALID') {
        $json = Read-CcodOfficialDraftJson -Path $completePath
        $records['Complete'] = Assert-CcodOfficialDraftReceiptShape -Receipt $json.Value -ExpectedPhase 'Complete'
    }
    $manual = @{}
    $manualDirectory = Join-Path $StateDirectory $script:CcodOfficialDraftManualDirectoryName
    if (Get-CcodOfficialDraftOptionalPathState -Path $manualDirectory -ExpectDirectory $true -GetItem { param($CandidatePath) Get-Item -LiteralPath $CandidatePath -Force -ErrorAction Stop } -ErrorId 'CCOD_ACCEPTANCE_RECEIPT_INVALID') {
        [void](Assert-CcodOfficialDraftSafeDirectory -Path $manualDirectory -ErrorId 'CCOD_ACCEPTANCE_RECEIPT_INVALID')
        try { $manualChildren = @(Get-ChildItem -LiteralPath $manualDirectory -Force -ErrorAction Stop) }
        catch { Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_RECEIPT_INVALID' 'Manual evidence state could not be enumerated safely.' $null }
        foreach ($child in $manualChildren) {
            if ($child.PSIsContainer -or ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                @($script:CcodOfficialDraftManualFiles.Values) -cnotcontains [string]$child.Name) {
                Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_RECEIPT_INVALID' 'Manual evidence state contains an unexpected entry.' $null
            }
            $fileOperation = @($script:CcodOfficialDraftManualFiles.GetEnumerator() | Where-Object { [string]$_.Value -ceq [string]$child.Name } | ForEach-Object { [string]$_.Key })
            if ($fileOperation.Count -ne 1) { Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_MANUAL_EVIDENCE_INVALID' 'Manual evidence filename is not recognized.' $child.FullName }
            $record = Assert-CcodOfficialDraftManualRecordShape -Record (Read-CcodOfficialDraftJson -Path $child.FullName).Value
            if ([string]$record.operation -cne [string]$fileOperation[0]) { Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_MANUAL_EVIDENCE_INVALID' 'Manual evidence filename is detached from its operation.' $child.FullName }
            if ($manual.ContainsKey([string]$record.operation)) {
                Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_MANUAL_EVIDENCE_INVALID' 'Manual evidence contains a duplicate operation.' $null
            }
            $manual[[string]$record.operation] = $record
        }
    }
    $records['ManualEvidence'] = $manual
    if ($records.ContainsKey('LegacyUpgrade') -and -not [string]::IsNullOrWhiteSpace($PreviousAssetDirectory)) {
        [void](Assert-CcodOfficialDraftPreviousSetupBinding -PreviousSetup $records['LegacyUpgrade'].facts.previousSetup -PreviousAssetDirectory $PreviousAssetDirectory)
    }
    if (@($script:CcodOfficialDraftPhases | Where-Object { -not $records.ContainsKey($_) }).Count -eq 0) {
        [void](Assert-CcodOfficialDraftAutomatedReceiptChain -Records $records -StateDirectory $StateDirectory)
    }
    return $records
}

function Repair-CcodOfficialDraftOrphanTemporaryFiles {
    param([Parameter(Mandatory)][string]$StateDirectory)
    try {
        $temporaryEntries = @(Get-ChildItem -LiteralPath $StateDirectory -Force -ErrorAction Stop | Where-Object { [string]$_.Name -cmatch '^\.(acceptance|manual)-[0-9a-f]{32}\.tmp\z' })
        foreach ($entry in $temporaryEntries) {
            if ($entry -isnot [IO.FileInfo] -or ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'orphan temporary identity' }
            $stream = [IO.File]::Open($entry.FullName,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
            try { $stream.Flush() } finally { $stream.Dispose() }
            Remove-Item -LiteralPath $entry.FullName -Force -ErrorAction Stop
            if (Test-Path -LiteralPath $entry.FullName) { throw 'orphan temporary residue' }
        }
        return $true
    } catch {
        if ($_.FullyQualifiedErrorId -like 'CCOD_ACCEPTANCE_*') { throw }
        Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_RECEIPT_INVALID' 'An orphan acceptance temporary could not be proven safe to remove.' $StateDirectory
    }
}

function Get-CcodOfficialDraftPreviousSetupContract {
    param([Parameter(Mandatory)][string]$Directory,[Parameter(Mandatory)][string]$Version)
    $assetModule=Get-CcodOfficialDraftAssetModule
    $directoryAuthority=$null
    $files=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    $errorId='CCOD_ACCEPTANCE_PREVIOUS_ASSET_INVALID'
    try {
        if($Version-cne'2.5.21'){throw 'unsupported previous version'}
        $names=@('CodexRemote-fix-2.5.21-windows-x64.zip','CodexRemote-fix-2.5.21-windows-x64.zip.sha256.txt','CodexRemote-fix-2.5.21-trayhost-provenance.json','CodexRemote-fix-2.5.21-payload-manifest.json','CodexRemote-fix-2.5.21-release-manifest.json','CodexRemote-fix-2.5.21-setup.exe','CodexRemote-fix-2.5.21-setup.exe.sha256.txt','CodexRemote-fix-2.5.21-setup-release-manifest.json')
        $directoryAuthority=&$assetModule {param($Path,$ErrorId)Open-CcodReleaseDirectoryAuthority -Path $Path -ErrorId $ErrorId} $Directory $errorId
        if(@($directoryAuthority.Children).Count-ne$names.Count-or@($directoryAuthority.Children|Where-Object {$names-cnotcontains$_}).Count-ne0){throw 'previous asset membership'}
        foreach($name in $names){
            $file=&$assetModule {param($Leaf,$Directory,$ErrorId)Open-CcodReleaseFileAuthority -Directory $Directory -Leaf $Leaf -ErrorId $ErrorId -AllowZone} $name $directoryAuthority $errorId
            $files.Add($name,$file)
        }
        $setup=&$assetModule {param($File,$ErrorId)(Read-CcodReleaseContractPinnedJson -Authority $File -ErrorId $ErrorId).Value} $files[$names[7]] $errorId
        if((@($setup.PSObject.Properties.Name)-join',')-cne'schemaVersion,product,version,gitCommit,buildTimestampUtc,assets'-or
            -not(Test-CcodOfficialDraftIntegerValue $setup.schemaVersion)-or[long]$setup.schemaVersion-ne1-or
            $setup.product-isnot[string]-or$setup.product-cne'CodexRemote-fix'-or
            $setup.version-isnot[string]-or$setup.version-cne$Version-or
            -not(Test-CcodOfficialDraftCommit $setup.gitCommit)-or-not(Test-CcodOfficialDraftCanonicalUtc $setup.buildTimestampUtc)){throw 'legacy setup manifest schema'}
        $map=&$assetModule {param($Manifest,$Names,$ErrorId,$Target)Get-CcodReleaseContractManifestMap -Manifest $Manifest -ExpectedNames $Names -ErrorId $ErrorId -Target $Target} $setup @($names[5],$names[6],$names[2]) $errorId $files[$names[7]].Path
        foreach($name in @($names[5],$names[6],$names[2])){if($files[$name].Sha256-cne$map[$name]){throw 'legacy setup asset hash'}}
        $checksum=&$assetModule {param($File)$bytes=Get-CcodReleaseAuthorityStreamBytes -Stream $File.Stream -MaximumBytes 16384;[Text.UTF8Encoding]::new($false,$true).GetString($bytes)} $files[$names[6]]
        if($checksum.TrimEnd([char]13,[char]10)-cne($map[$names[5]]+' *'+$names[5])){throw 'legacy setup checksum'}
        $portable=&$assetModule {
            param($File,$Directory,$Version,$ErrorId)
            $loaded=Read-CcodReleaseContractPinnedJson -Authority $File -ErrorId $ErrorId
            Test-CcodReleasePortableManifestDeep -Manifest $loaded.Value -ManifestRaw $loaded.Raw -ManifestPath $File.Path -Directory $Directory -Version $Version -ErrorId $ErrorId
        } $files[$names[4]] $directoryAuthority.Path $Version $errorId
        if($portable.Valid-isnot[bool]-or-not$portable.Valid-or$portable.GitCommit-cne$setup.gitCommit-or$portable.BuildTimestampUtc-cne$setup.buildTimestampUtc){throw 'legacy distribution binding'}
        foreach($file in $files.Values){&$assetModule {param($File,$ErrorId)Assert-CcodReleaseAuthorityCurrent -Authority $File -ErrorId $ErrorId -CheckBytes|Out-Null} $file $errorId}
        &$assetModule {param($Directory,$ErrorId)Assert-CcodReleaseAuthorityCurrent -Authority $Directory -ErrorId $ErrorId|Out-Null} $directoryAuthority $errorId
        return [pscustomobject][ordered]@{Valid=$true;Version=$Version;GitCommit=[string]$setup.gitCommit;InstallerName=$names[5];InstallerSha256=[string]$files[$names[5]].Sha256;ManifestSha256=[string]$files[$names[7]].Sha256}
    } catch {
        Throw-CcodOfficialDraftError $errorId 'The previous v2.5.21 assets do not satisfy their original eight-file contract.' $Directory
    } finally {
        foreach($file in $files.Values){&$assetModule {param($File)Close-CcodReleaseAuthority $File} $file}
        if($null-ne$directoryAuthority){&$assetModule {param($Directory)Close-CcodReleaseAuthority $Directory} $directoryAuthority}
    }
}

function Assert-CcodOfficialDraftPreviousSetupBinding {
    param([Parameter(Mandatory)]$PreviousSetup,[Parameter(Mandatory)][string]$PreviousAssetDirectory)
    try {
        if (-not (Test-CcodOfficialDraftExactProperties -Value $PreviousSetup -Expected @('version','gitCommit','assetSha256','manifestSha256')) -or
            $PreviousSetup.version -isnot [string] -or $PreviousSetup.version -cne '2.5.21' -or
            -not (Test-CcodOfficialDraftCommit $PreviousSetup.gitCommit) -or
            -not (Test-CcodOfficialDraftHash $PreviousSetup.assetSha256) -or
            -not (Test-CcodOfficialDraftHash $PreviousSetup.manifestSha256)) { throw 'previous setup shape' }
        $contract=Get-CcodOfficialDraftPreviousSetupContract -Directory $PreviousAssetDirectory -Version '2.5.21'
        if($contract.GitCommit-cne$PreviousSetup.gitCommit-or$contract.InstallerSha256-cne$PreviousSetup.assetSha256-or$contract.ManifestSha256-cne$PreviousSetup.manifestSha256){throw 'previous setup binding'}
        return $true
    } catch {
        if ($_.FullyQualifiedErrorId -like 'CCOD_ACCEPTANCE_RECEIPT_INVALID*') { throw }
        Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_RECEIPT_INVALID' 'Persisted v2.5.21 setup evidence is detached from the validated previous asset files.' $PreviousAssetDirectory
    }
}

function Assert-CcodOfficialDraftRemoteProofRuntimeContinuity {
    param([Parameter(Mandatory)]$ManualEvidence,[Parameter(Mandatory)]$FreshFacts,[Parameter(Mandatory)]$PostFacts)
    try {
        $remote = @($ManualEvidence | Where-Object { $_.operation -ceq 'SecondDeviceControl' })
        if ($remote.Count -ne 1) { throw 'remote proof count' }
        $proof = $remote[0].proof
        $freshRuntimeId = Get-CcodOfficialDraftFactValue -Facts $FreshFacts -Name 'activeRuntimeId'
        $postRuntimeId = Get-CcodOfficialDraftFactValue -Facts $PostFacts -Name 'activeRuntimeId'
        $freshGeneration = Get-CcodOfficialDraftFactValue -Facts $FreshFacts -Name 'activeGeneration'
        $postGeneration = Get-CcodOfficialDraftFactValue -Facts $PostFacts -Name 'activeGeneration'
        $freshManifestHash = Get-CcodOfficialDraftFactValue -Facts $FreshFacts -Name 'runtimeManifestSha256'
        $postManifestHash = Get-CcodOfficialDraftFactValue -Facts $PostFacts -Name 'runtimeManifestSha256'
        if ($proof.runtimeId -isnot [string] -or $proof.runtimeId -cne [string]$freshRuntimeId -or $proof.runtimeId -cne [string]$postRuntimeId -or
            -not (Test-CcodOfficialDraftPositiveInteger $proof.runtimeGeneration) -or -not (Test-CcodOfficialDraftPositiveInteger $freshGeneration) -or
            -not (Test-CcodOfficialDraftPositiveInteger $postGeneration) -or [UInt64]$proof.runtimeGeneration -ne [UInt64]$freshGeneration -or [UInt64]$proof.runtimeGeneration -ne [UInt64]$postGeneration -or
            -not (Test-CcodOfficialDraftHash $proof.runtimeManifestSha256) -or $proof.runtimeManifestSha256 -cne [string]$freshManifestHash -or $proof.runtimeManifestSha256 -cne [string]$postManifestHash) { throw 'remote runtime continuity' }
        return $true
    } catch {
        if ($_.FullyQualifiedErrorId -like 'CCOD_ACCEPTANCE_*') { throw }
        Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_RECEIPT_INVALID' 'Second-device proof is not bound to the current installed runtime.' $null
    }
}

function Assert-CcodOfficialDraftAutomatedReceiptChain {
    param([Parameter(Mandatory)]$Records,[Parameter(Mandatory)][string]$StateDirectory)
    try {
        foreach ($phase in $script:CcodOfficialDraftPhases) {
            if (-not $Records.ContainsKey($phase)) { throw 'automated phase missing' }
        }
        $candidate = $Records['Preflight'].candidate
        $draftIdentity = $Records['Preflight'].draft
        if ($draftIdentity.tag -isnot [string] -or $draftIdentity.tag -cne 'v2.5.22' -or
            $draftIdentity.id -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$draftIdentity.id)) { throw 'draft identity chain' }
        foreach ($phase in $script:CcodOfficialDraftPhases) {
            $receipt = $Records[$phase]
            if (-not (Test-CcodOfficialDraftCandidateEqual -Left $candidate -Right $receipt.candidate) -or
                $receipt.draft.tag -isnot [string] -or $receipt.draft.tag -cne 'v2.5.22' -or
                $receipt.draft.id -isnot [string] -or $receipt.draft.id -cne [string]$draftIdentity.id) { throw 'automated candidate chain' }
        }
        if ($Records.ContainsKey('Complete') -and
            (-not (Test-CcodOfficialDraftCandidateEqual -Left $candidate -Right $Records['Complete'].candidate) -or
             $Records['Complete'].draft.tag -isnot [string] -or $Records['Complete'].draft.tag -cne [string]$draftIdentity.tag -or
             $Records['Complete'].draft.id -isnot [string] -or $Records['Complete'].draft.id -cne [string]$draftIdentity.id)) { throw 'complete candidate/draft chain' }
        $freshFacts = $Records['FreshInstall'].facts
        $preFacts = $Records['PreReboot'].facts
        $postFacts = $Records['PostReboot'].facts
        $legacyFacts = $Records['LegacyUpgrade'].facts
        $uninstallFacts = $Records['Uninstall'].facts
        $freshLeaf = [string]$script:CcodOfficialDraftPhaseFiles['FreshInstall']
        if ([string]::IsNullOrWhiteSpace($StateDirectory) -or [string]::IsNullOrWhiteSpace($freshLeaf)) { throw 'fresh receipt path' }
        $freshHash = Get-CcodOfficialDraftFileSha256 -Path (Join-Path $StateDirectory $freshLeaf)
        if ((Get-CcodOfficialDraftFactValue -Facts $preFacts -Name 'freshInstallReceiptSha256') -cne $freshHash) { throw 'fresh receipt chain' }
        $expectedKeyHash = Get-CcodOfficialDraftFactValue -Facts $freshFacts -Name 'deviceKeySha256'
        $legacyAfterKeyHash = Get-CcodOfficialDraftFactValue -Facts $legacyFacts -Name 'deviceKeySha256After'
        $uninstallBeforeKeyHash = Get-CcodOfficialDraftFactValue -Facts $uninstallFacts -Name 'deviceKeySha256Before'
        $uninstallAfterKeyHash = Get-CcodOfficialDraftFactValue -Facts $uninstallFacts -Name 'deviceKeySha256After'
        if (-not (Test-CcodOfficialDraftHash $expectedKeyHash) -or
            -not (Test-CcodOfficialDraftHash $legacyAfterKeyHash) -or
            -not (Test-CcodOfficialDraftHash $uninstallBeforeKeyHash) -or
            -not (Test-CcodOfficialDraftHash $uninstallAfterKeyHash) -or
            $legacyAfterKeyHash -cne $uninstallBeforeKeyHash -or
            $uninstallBeforeKeyHash -cne $uninstallAfterKeyHash -or
            $uninstallAfterKeyHash -cne $expectedKeyHash) { throw 'device-key chain' }
        $preRuntimeId = Get-CcodOfficialDraftFactValue -Facts $preFacts -Name 'activeRuntimeId'
        $preGeneration = Get-CcodOfficialDraftFactValue -Facts $preFacts -Name 'activeGeneration'
        $preManifestHash = Get-CcodOfficialDraftFactValue -Facts $preFacts -Name 'runtimeManifestSha256'
        $preKeyHash = Get-CcodOfficialDraftFactValue -Facts $preFacts -Name 'deviceKeySha256'
        $freshRuntimeId = Get-CcodOfficialDraftFactValue -Facts $freshFacts -Name 'activeRuntimeId'
        $freshGeneration = Get-CcodOfficialDraftFactValue -Facts $freshFacts -Name 'activeGeneration'
        $freshManifestHash = Get-CcodOfficialDraftFactValue -Facts $freshFacts -Name 'runtimeManifestSha256'
        if ($preRuntimeId -isnot [string] -or $freshRuntimeId -isnot [string] -or $preRuntimeId -cne $freshRuntimeId -or
            -not (Test-CcodOfficialDraftPositiveInteger $preGeneration) -or -not (Test-CcodOfficialDraftPositiveInteger $freshGeneration) -or [UInt64]$preGeneration -ne [UInt64]$freshGeneration -or
            -not (Test-CcodOfficialDraftHash $preManifestHash) -or -not (Test-CcodOfficialDraftHash $freshManifestHash) -or $preManifestHash -cne $freshManifestHash -or
            -not (Test-CcodOfficialDraftHash $preKeyHash) -or $preKeyHash -cne $expectedKeyHash) { throw 'pre-reboot identity chain' }
        $bootBefore = Get-CcodOfficialDraftFactValue -Facts $preFacts -Name 'bootIdBefore'
        if (-not (Test-CcodOfficialDraftHash $expectedKeyHash) -or $bootBefore -isnot [string]) { throw 'reboot continuity inputs' }
        [void](Assert-CcodOfficialDraftPersistedPostRebootContinuity -Facts $postFacts -FreshFacts $freshFacts -PreFacts $preFacts -ExpectedKeyHash $expectedKeyHash)
        $readyFacts = $Records['ReadyForManualEvidence'].facts
        if (-not (Test-CcodOfficialDraftExactProperties -Value $readyFacts -Expected @('automatedPhases','status','manualEvidencePending','complete','manualChallenge')) -or
            (@($readyFacts.automatedPhases) -join '|') -cne 'Preflight|LegacyUpgrade|Uninstall|FreshInstall|PreReboot|PostReboot' -or
            $readyFacts.status -isnot [string] -or $readyFacts.status -cne 'ReadyForManualEvidence' -or
            $readyFacts.manualEvidencePending -isnot [bool] -or -not $readyFacts.manualEvidencePending -or
            $readyFacts.complete -isnot [bool] -or $readyFacts.complete -or
            $readyFacts.manualChallenge -isnot [string] -or $readyFacts.manualChallenge -cnotmatch '^[0-9a-f]{32}\z') { throw 'ready chain' }
        if ($Records.ContainsKey('Complete')) {
            $completeManual = @($Records['Complete'].facts.manualEvidence)
            $fileManual = @()
            foreach ($operation in $script:CcodOfficialDraftManualOperations) {
                if (-not $Records['ManualEvidence'].ContainsKey($operation)) { throw 'manual state missing' }
                $fileManual += $Records['ManualEvidence'][$operation]
            }
            if ($completeManual.Count -ne $script:CcodOfficialDraftManualOperations.Count -or $fileManual.Count -ne $completeManual.Count) { throw 'manual state count' }
            $manualFields = @('schemaVersion','kind','phase','operation','terminalState','result','proof','reviewState','version','gitCommit','candidateManifestSha256','screenshotSha256','redactedLogSha256')
            for ($manualIndex = 0; $manualIndex -lt $completeManual.Count; $manualIndex++) {
                foreach ($right in @($fileManual[$manualIndex])) {
                    foreach ($field in $manualFields) {
                        $leftProperty = @($completeManual[$manualIndex].PSObject.Properties | Where-Object { $_.Name -ceq $field })
                        $rightProperty = @($right.PSObject.Properties | Where-Object { $_.Name -ceq $field })
                        if ($leftProperty.Count -ne 1 -or $rightProperty.Count -ne 1) { throw 'manual state binding' }
                        $leftValue = [string]$leftProperty[0].Value
                        $rightValue = [string]$rightProperty[0].Value
                        if ($field -ceq 'proof') {
                            $leftValue = $leftProperty[0].Value | ConvertTo-Json -Depth 12 -Compress
                            $rightValue = $rightProperty[0].Value | ConvertTo-Json -Depth 12 -Compress
                        }
                        if ($leftValue -cne $rightValue) { throw 'manual state binding' }
                    }
                }
            }
            [void](Assert-CcodOfficialDraftRemoteProofRuntimeContinuity -ManualEvidence $completeManual -FreshFacts $freshFacts -PostFacts $postFacts)
            $remoteManual = @($completeManual | Where-Object { $_.operation -ceq 'SecondDeviceControl' })
            $readyChallenge = Get-CcodOfficialDraftFactValue -Facts $readyFacts -Name 'manualChallenge'
            if ($remoteManual.Count -ne 1 -or $remoteManual[0].proof.challenge -isnot [string] -or $remoteManual[0].proof.challenge -cne [string]$readyChallenge -or
                $remoteManual[0].proof.candidateVersion -isnot [string] -or $remoteManual[0].proof.candidateVersion -cne [string]$candidate.version) { throw 'remote proof chain' }
        }
        return $true
    } catch {
        if ($_.FullyQualifiedErrorId -like 'CCOD_ACCEPTANCE_*') { throw }
        Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_RECEIPT_INVALID' 'The automated official-draft receipt chain is missing, tampered, or inconsistent.' $null
    }
}

function Assert-CcodOfficialDraftPersistedPostRebootContinuity {
    param([Parameter(Mandatory)]$Facts,[Parameter(Mandatory)]$FreshFacts,[Parameter(Mandatory)]$PreFacts,[Parameter(Mandatory)][string]$ExpectedKeyHash)
    try {
        $bootBefore = Get-CcodOfficialDraftFactValue -Facts $PreFacts -Name 'bootIdBefore'
        $postBefore = Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'bootIdBefore'
        $postAfter = Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'bootIdAfter'
        if ($bootBefore -isnot [string] -or $postBefore -isnot [string] -or $postAfter -isnot [string] -or
            $bootBefore -cne $postBefore -or $postAfter -ceq $postBefore -or
            (Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'bootChanged') -isnot [bool] -or -not (Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'bootChanged') -or
            (Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'receiptContinuity') -isnot [bool] -or -not (Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'receiptContinuity')) { throw 'boot continuity' }
        $runtimeId = Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'activeRuntimeId'
        $generation = Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'activeGeneration'
        $freshRuntimeId = Get-CcodOfficialDraftFactValue -Facts $FreshFacts -Name 'activeRuntimeId'
        $freshGeneration = Get-CcodOfficialDraftFactValue -Facts $FreshFacts -Name 'activeGeneration'
        $postManifestHash = Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'runtimeManifestSha256'
        $freshManifestHash = Get-CcodOfficialDraftFactValue -Facts $FreshFacts -Name 'runtimeManifestSha256'
        if ($runtimeId -isnot [string] -or $runtimeId -cne $freshRuntimeId -or
            -not (Test-CcodOfficialDraftPositiveInteger $generation) -or [UInt64]$generation -ne [UInt64]$freshGeneration -or
            -not (Test-CcodOfficialDraftHash $postManifestHash) -or $postManifestHash -cne $freshManifestHash -or
            -not (Test-CcodOfficialDraftInt32 (Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'codexCount')) -or [int](Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'codexCount') -ne 1 -or
            -not (Test-CcodOfficialDraftInt32 (Get-CcodOfficialDraftFactValue -Facts $FreshFacts -Name 'codexCount')) -or [int](Get-CcodOfficialDraftFactValue -Facts $FreshFacts -Name 'codexCount') -ne 1 -or
            (Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'transitionStage') -cne 'Idle' -or
            (Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'protectionRecovered') -isnot [bool] -or -not (Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'protectionRecovered') -or
            (Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'protectionReady') -isnot [bool] -or -not (Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'protectionReady') -or
            (Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'trayAuthenticated') -isnot [bool] -or -not (Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'trayAuthenticated')) { throw 'runtime continuity' }
        $terminal = ConvertTo-CcodOfficialDraftTerminalReceipt -Receipt (Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'terminalReceipt')
        $freshTerminal = ConvertTo-CcodOfficialDraftTerminalReceipt -Receipt (Get-CcodOfficialDraftFactValue -Facts $FreshFacts -Name 'terminalReceipt')
        if ($terminal.runtimeId -cne $runtimeId -or [UInt64]$terminal.runtimeGeneration -ne [UInt64]$generation -or
            $terminal.runtimeId -cne $freshTerminal.runtimeId -or [UInt64]$terminal.runtimeGeneration -ne [UInt64]$freshTerminal.runtimeGeneration -or
            (Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'deviceKeySha256') -cne $ExpectedKeyHash -or
            (Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'keyHashPreserved') -isnot [bool] -or -not (Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'keyHashPreserved')) { throw 'terminal continuity' }
        return $true
    } catch {
        if ($_.FullyQualifiedErrorId -like 'CCOD_ACCEPTANCE_*') { throw }
        Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_RECEIPT_INVALID' 'Persisted post-reboot identity is not bound to FreshInstall and PreReboot.' $null
    }
}

function Write-CcodOfficialDraftReceipt {
    param(
        [Parameter(Mandatory)][string]$StateDirectory,
        [Parameter(Mandatory)][string]$Phase,
        [Parameter(Mandatory)]$Candidate,
        [Parameter(Mandatory)]$Draft,
        [Parameter(Mandatory)]$Facts,
        [scriptblock]$ReadbackVerifier,
        [ref]$PublishedHash
    )
    $leaf = if ($Phase -ceq 'Complete') { $script:CcodOfficialDraftCompletionFile } else { $script:CcodOfficialDraftPhaseFiles[$Phase] }
    if ([string]::IsNullOrWhiteSpace([string]$leaf)) {
        Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_PHASE_INVALID' 'The official-draft acceptance phase has no state file.' $Phase
    }
    $path = Join-Path $StateDirectory $leaf
    $existing = $null
    try { $existing = Get-Item -LiteralPath $path -Force -ErrorAction Stop } catch { if (-not (Test-CcodOfficialDraftMissingError -ErrorRecord $_)) { Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_PHASE_REUSED' 'The acceptance receipt path could not be inspected safely.' $path } }
    if ($null -ne $existing) {
        if ($Phase -ne 'Complete') {
            Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_PHASE_REUSED' 'An official-draft acceptance phase receipt already exists.' $null
        }
        try {
            $existingReceipt = Assert-CcodOfficialDraftReceiptShape -Receipt (Read-CcodOfficialDraftJson -Path $path).Value -ExpectedPhase 'Complete'
            if (-not (Test-CcodOfficialDraftCandidateEqual -Left $Candidate -Right $existingReceipt.candidate) -or
                -not (Test-CcodOfficialDraftDraftEqual -Left $Draft -Right $existingReceipt.draft)) { throw 'complete identity' }
            if ($null -ne $PublishedHash) { $PublishedHash.Value = $null }
            return $existingReceipt
        } catch {
            Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_PHASE_REUSED' 'An existing Complete receipt is not safely resumable.' $path
        }
    }
    $receipt = [pscustomobject][ordered]@{
        schemaVersion = 1
        phase = $Phase
        candidate = $Candidate
        draft = $Draft
        facts = $Facts
    }
    $temporary = Join-Path $StateDirectory ('.acceptance-' + [guid]::NewGuid().ToString('N') + '.tmp')
    $published = $false
    $expectedHash = $null
    try {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($receipt | ConvertTo-Json -Depth 16))
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $expectedHash = ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
        $stream = [IO.File]::Open($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
        try { $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        [IO.File]::Move($temporary,$path)
        $published = $true
        if ($null -ne $PublishedHash) { $PublishedHash.Value = $expectedHash }
        if ($null -ne $ReadbackVerifier -and -not [bool](& $ReadbackVerifier $path)) { throw 'receipt readback' }
        $normalizedReceipt = Assert-CcodOfficialDraftReceiptShape -Receipt (Read-CcodOfficialDraftJson -Path $path).Value -ExpectedPhase $Phase
        if ((Get-CcodOfficialDraftFileSha256 -Path $path) -cne $expectedHash) { throw 'receipt semantic mismatch' }
        return $normalizedReceipt
    } catch {
        $failure = $_
        if ($null -ne $temporary) {
            try { $tempItem = Get-Item -LiteralPath $temporary -Force -ErrorAction Stop; if ($null -ne $tempItem) { Remove-Item -LiteralPath $temporary -Force -ErrorAction Stop } } catch { if (-not (Test-CcodOfficialDraftMissingError -ErrorRecord $_)) { Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_RECEIPT_CLEANUP_FAILED' 'Temporary acceptance receipt cleanup could not be proven.' $temporary } }
        }
        if ($published) {
            try {
                $item = $null
                try { $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop } catch { if (-not (Test-CcodOfficialDraftMissingError -ErrorRecord $_)) { throw } }
                if ($null -ne $item) {
                    if ($item -isnot [IO.FileInfo] -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                        ($null -ne $expectedHash -and (Get-CcodOfficialDraftFileSha256 -Path $path) -cne $expectedHash)) { throw 'receipt cleanup target' }
                    Remove-Item -LiteralPath $path -Force -ErrorAction Stop
                }
                $residual = $null
                try { $residual = Get-Item -LiteralPath $path -Force -ErrorAction Stop } catch { if (-not (Test-CcodOfficialDraftMissingError -ErrorRecord $_)) { throw } }
                if ($null -ne $residual) { throw 'receipt cleanup residue' }
            } catch {
                Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_RECEIPT_CLEANUP_FAILED' 'Receipt destination cleanup could not be proven after a failed readback.' $path
            }
        }
        if ($failure.FullyQualifiedErrorId -like 'CCOD_ACCEPTANCE_*') { throw $failure }
        Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_RECEIPT_WRITE_FAILED' 'Official-draft acceptance receipt could not be durably written.' $null
    }
}

function Test-CcodOfficialDraftIntegerValue {
    param($Value)
    if ($null -eq $Value -or $Value -is [bool]) { return $false }
    return $Value.GetType() -in @([sbyte],[byte],[int16],[uint16],[int32],[uint32],[int64],[uint64])
}

function Test-CcodOfficialDraftMissingError {
    param([Parameter(Mandatory)]$ErrorRecord)
    return $ErrorRecord.CategoryInfo.Category -eq 'ObjectNotFound' -or
        $ErrorRecord.Exception -is [IO.FileNotFoundException] -or $ErrorRecord.Exception -is [IO.DirectoryNotFoundException]
}

function Assert-CcodOfficialDraftMissingPathAncestorsSafe {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][scriptblock]$GetItem,[Parameter(Mandatory)][string]$ErrorId)
    try {
        $current = [IO.Path]::GetFullPath($Path)
        $pathRoot = [IO.Path]::GetPathRoot($current)
        while ($null -ne $current) {
            $parent = [IO.Directory]::GetParent($current)
            if ($null -eq $parent) { break }
            $current = $parent.FullName
            try {
                $items = @(& $GetItem $current)
                if ($items.Count -ne 1 -or $null -eq $items[0] -or -not [bool]$items[0].PSIsContainer) { throw 'ancestor shape' }
                if (($items[0].Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'ancestor reparse' }
            } catch {
                if (-not (Test-CcodOfficialDraftMissingError -ErrorRecord $_)) { throw }
            }
            if ($current.TrimEnd('\') -ceq $pathRoot.TrimEnd('\')) { break }
        }
    } catch {
        if ($_.FullyQualifiedErrorId -like 'CCOD_ACCEPTANCE_*') { throw }
        Throw-CcodOfficialDraftError $ErrorId 'Installed lifecycle path ancestry could not be inspected safely.' $Path
    }
}

function Get-CcodOfficialDraftOptionalPathState {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][bool]$ExpectDirectory,
        [Parameter(Mandatory)][scriptblock]$GetItem,
        [Parameter(Mandatory)][string]$ErrorId
    )
    try {
        $items = @(& $GetItem $Path)
        if ($items.Count -ne 1 -or $null -eq $items[0]) { throw 'path observation' }
        $item = $items[0]
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            [bool]$item.PSIsContainer -ne $ExpectDirectory) { throw 'wrong type or reparse' }
        return $true
    } catch {
        $missing = $_.CategoryInfo.Category -eq 'ObjectNotFound' -or
            $_.Exception -is [IO.FileNotFoundException] -or $_.Exception -is [IO.DirectoryNotFoundException]
        if ($missing) {
            Assert-CcodOfficialDraftMissingPathAncestorsSafe -Path $Path -GetItem $GetItem -ErrorId $ErrorId
            return $false
        }
        Throw-CcodOfficialDraftError $ErrorId 'Installed lifecycle path could not be inspected safely.' $Path
    }
}

function Assert-CcodOfficialDraftRegularEvidenceFile {
    param([Parameter(Mandatory)][string]$Path)
    try {
        if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathRooted($Path)) { throw 'absolute' }
        $full = [IO.Path]::GetFullPath($Path)
        $root = [IO.Path]::GetPathRoot($full)
        if ([string]::IsNullOrWhiteSpace($root) -or $full.TrimEnd('\') -cne $Path.TrimEnd('\')) { throw 'canonical' }
        $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
        if ($item -isnot [IO.FileInfo] -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            [int64]$item.Length -lt 1 -or [int64]$item.Length -gt 2MB) { throw 'evidence file' }
        $parent = [IO.Directory]::GetParent($full)
        if ($null -eq $parent) { throw 'parent' }
        [void](Assert-CcodOfficialDraftSafeDirectory -Path $parent.FullName -ErrorId 'CCOD_ACCEPTANCE_MANUAL_EVIDENCE_INVALID')
        return $full
    } catch {
        Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_MANUAL_EVIDENCE_INVALID' 'Manual evidence must be a bounded regular file.' $Path
    }
}

function Close-CcodOfficialDraftEvidenceReadLease {
    param($Lease)
    if ($null -eq $Lease -or $Lease.Closed) { return }
    $failed = $false
    for ($index = $Lease.Entries.Count - 1; $index -ge 0; $index--) {
        $entry = $Lease.Entries[$index]
        try {
            if ($null -ne $entry.Stream) { $entry.Stream.Dispose() } else { $entry.Handle.Dispose() }
        } catch { $failed = $true }
    }
    $Lease.Closed = $true
    if ($failed) { Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_MANUAL_EVIDENCE_INVALID' 'Manual evidence read authority could not be released.' $null }
}

function Assert-CcodOfficialDraftEvidenceReadLease {
    param([Parameter(Mandatory)]$Lease)
    try {
        if ($Lease.Closed) { throw 'closed read authority' }
        foreach ($entry in $Lease.Entries) {
            $current = [CcodReleaseFileAuthorityV1]::Identity($entry.Handle)
            if ([CcodReleaseFileAuthorityV1]::IsReparse($current) -or
                [CcodReleaseFileAuthorityV1]::IsDirectory($current) -ne $entry.Directory -or
                $current.Volume -ne $entry.Identity.Volume -or $current.FileId -ne $entry.Identity.FileId -or
                -not $current.FinalPath.TrimEnd('\').Equals($entry.Path.TrimEnd('\'),[StringComparison]::OrdinalIgnoreCase)) { throw 'read identity drift' }
            if (-not $entry.Directory) {
                if ($current.Links -ne 1 -or $current.Attributes -ne $entry.Identity.Attributes -or $entry.Stream.Length -ne $entry.Length) { throw 'read file drift' }
                $validStreams = & $Lease.AssetModule { param($Identity) Test-CcodReleaseAuthorityStreams -Identity $Identity -AllowZone } $current
                $currentHash = & $Lease.AssetModule { param($Stream) Get-CcodReleaseAuthorityStreamSha256 -Stream $Stream } $entry.Stream
                if (-not $validStreams -or $currentHash -cne $entry.Sha256) { throw 'read bytes drift' }
            }
        }
    } catch {
        Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_MANUAL_EVIDENCE_INVALID' 'Held manual evidence changed or became unavailable.' $null
    }
}

function Open-CcodOfficialDraftEvidenceReadLease {
    param([Parameter(Mandatory)][string[]]$Paths)
    $lease = [pscustomobject]@{ Entries = [Collections.Generic.List[object]]::new(); AssetModule = (Get-CcodOfficialDraftAssetModule); Closed = $false }
    try {
        if ($Paths.Count -eq 0) { throw 'evidence paths missing' }
        $directories = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $files = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($path in $Paths) {
            $full = Assert-CcodOfficialDraftRegularEvidenceFile -Path $path
            if (-not $files.Add($full)) { continue }
            $parents = [Collections.Generic.List[string]]::new()
            for ($parent = [IO.Directory]::GetParent($full); $null -ne $parent; $parent = $parent.Parent) { $parents.Insert(0,$parent.FullName) }
            if ($parents.Count -eq 0 -or -not $parents[0].TrimEnd('\').Equals([IO.Path]::GetPathRoot($full).TrimEnd('\'),[StringComparison]::OrdinalIgnoreCase)) { throw 'evidence ancestry' }
            foreach ($directory in $parents) {
                if (-not $directories.Add($directory)) { continue }
                $handle = [CcodReleaseFileAuthorityV1]::OpenDirectory($directory,$true)
                $entry = [pscustomobject]@{ Directory = $true; Path = $directory; Handle = $handle; Stream = $null; Identity = $null; Length = 0; Sha256 = $null }
                $lease.Entries.Add($entry)
                $entry.Identity = [CcodReleaseFileAuthorityV1]::Identity($handle)
                if ([CcodReleaseFileAuthorityV1]::IsReparse($entry.Identity) -or -not [CcodReleaseFileAuthorityV1]::IsDirectory($entry.Identity) -or
                    -not $entry.Identity.FinalPath.TrimEnd('\').Equals($directory.TrimEnd('\'),[StringComparison]::OrdinalIgnoreCase)) { throw 'unsafe evidence ancestor' }
            }
            $stream = [CcodReleaseFileAuthorityV1]::OpenReadFile($full,$false)
            $entry = [pscustomobject]@{ Directory = $false; Path = $full; Handle = $stream.SafeFileHandle; Stream = $stream; Identity = $null; Length = 0; Sha256 = $null }
            $lease.Entries.Add($entry)
            $entry.Identity = [CcodReleaseFileAuthorityV1]::Identity($entry.Handle)
            if ([CcodReleaseFileAuthorityV1]::IsReparse($entry.Identity) -or [CcodReleaseFileAuthorityV1]::IsDirectory($entry.Identity) -or
                $entry.Identity.Links -ne 1 -or $stream.Length -lt 1 -or $stream.Length -gt 2MB -or
                -not $entry.Identity.FinalPath.Equals($full,[StringComparison]::OrdinalIgnoreCase)) { throw 'unsafe evidence file' }
            $entry.Length = $stream.Length
            $entry.Sha256 = & $lease.AssetModule { param($Stream) Get-CcodReleaseAuthorityStreamSha256 -Stream $Stream } $stream
        }
        Assert-CcodOfficialDraftEvidenceReadLease -Lease $lease
        return $lease
    } catch {
        Close-CcodOfficialDraftEvidenceReadLease -Lease $lease
        Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_MANUAL_EVIDENCE_INVALID' 'Immutable manual evidence read authority could not be acquired.' $null
    }
}

function Read-CcodOfficialDraftJsonStringToken {
    param([Parameter(Mandatory)][string]$Raw,[Parameter(Mandatory)][ref]$Index)
    if ($Index.Value -ge $Raw.Length -or $Raw[$Index.Value] -cne [char]34) { throw 'json string' }
    $start = $Index.Value
    $Index.Value++
    $escaped = $false
    while ($Index.Value -lt $Raw.Length) {
        $character = $Raw[$Index.Value]
        $Index.Value++
        if ($escaped) { $escaped = $false; continue }
        if ($character -eq [char]92) { $escaped = $true; continue }
        if ($character -eq [char]34) {
            $encoded = ([string][char]34) + $Raw.Substring($start + 1, $Index.Value - $start - 2) + ([string][char]34)
            return [string]($encoded | ConvertFrom-Json -ErrorAction Stop)
        }
    }
    throw 'json string'
}

function Skip-CcodOfficialDraftJsonWhitespace {
    param([Parameter(Mandatory)][string]$Raw,[Parameter(Mandatory)][ref]$Index)
    while ($Index.Value -lt $Raw.Length -and [char]::IsWhiteSpace($Raw[$Index.Value])) { $Index.Value++ }
}

function Skip-CcodOfficialDraftJsonValue {
    param([Parameter(Mandatory)][string]$Raw,[Parameter(Mandatory)][ref]$Index)
    Skip-CcodOfficialDraftJsonWhitespace -Raw $Raw -Index $Index
    if ($Index.Value -ge $Raw.Length) { throw 'json value' }
    switch ([string]$Raw[$Index.Value]) {
        '{' { Skip-CcodOfficialDraftJsonObject -Raw $Raw -Index $Index; return }
        '[' { Skip-CcodOfficialDraftJsonArray -Raw $Raw -Index $Index; return }
        '"' { [void](Read-CcodOfficialDraftJsonStringToken -Raw $Raw -Index $Index); return }
        default {
            $start = $Index.Value
            while ($Index.Value -lt $Raw.Length -and $Raw[$Index.Value] -notin @([char]44,[char]93,[char]125) -and -not [char]::IsWhiteSpace($Raw[$Index.Value])) { $Index.Value++ }
            if ($Index.Value -eq $start) { throw 'json scalar' }
        }
    }
}

function Skip-CcodOfficialDraftJsonArray {
    param([Parameter(Mandatory)][string]$Raw,[Parameter(Mandatory)][ref]$Index)
    if ($Raw[$Index.Value] -cne [char]91) { throw 'json array' }
    $Index.Value++
    Skip-CcodOfficialDraftJsonWhitespace -Raw $Raw -Index $Index
    if ($Index.Value -lt $Raw.Length -and $Raw[$Index.Value] -ceq [char]93) { $Index.Value++; return }
    while ($true) {
        Skip-CcodOfficialDraftJsonValue -Raw $Raw -Index $Index
        Skip-CcodOfficialDraftJsonWhitespace -Raw $Raw -Index $Index
        if ($Index.Value -ge $Raw.Length) { throw 'json array' }
        if ($Raw[$Index.Value] -ceq [char]93) { $Index.Value++; return }
        if ($Raw[$Index.Value] -cne [char]44) { throw 'json array separator' }
        $Index.Value++
    }
}

function Skip-CcodOfficialDraftJsonObject {
    param([Parameter(Mandatory)][string]$Raw,[Parameter(Mandatory)][ref]$Index)
    if ($Raw[$Index.Value] -cne [char]123) { throw 'json object' }
    $Index.Value++
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    Skip-CcodOfficialDraftJsonWhitespace -Raw $Raw -Index $Index
    if ($Index.Value -lt $Raw.Length -and $Raw[$Index.Value] -ceq [char]125) { $Index.Value++; return }
    while ($true) {
        Skip-CcodOfficialDraftJsonWhitespace -Raw $Raw -Index $Index
        $name = Read-CcodOfficialDraftJsonStringToken -Raw $Raw -Index $Index
        if (-not $names.Add($name)) { throw 'duplicate json property' }
        Skip-CcodOfficialDraftJsonWhitespace -Raw $Raw -Index $Index
        if ($Index.Value -ge $Raw.Length -or $Raw[$Index.Value] -cne [char]58) { throw 'json object separator' }
        $Index.Value++
        Skip-CcodOfficialDraftJsonValue -Raw $Raw -Index $Index
        Skip-CcodOfficialDraftJsonWhitespace -Raw $Raw -Index $Index
        if ($Index.Value -ge $Raw.Length) { throw 'json object' }
        if ($Raw[$Index.Value] -ceq [char]125) { $Index.Value++; return }
        if ($Raw[$Index.Value] -cne [char]44) { throw 'json object separator' }
        $Index.Value++
    }
}

function Assert-CcodOfficialDraftJsonNoDuplicateProperties {
    param([Parameter(Mandatory)][string]$Raw)
    try {
        $index = 0
        Skip-CcodOfficialDraftJsonValue -Raw $Raw -Index ([ref]$index)
        Skip-CcodOfficialDraftJsonWhitespace -Raw $Raw -Index ([ref]$index)
        if ($index -ne $Raw.Length) { throw 'json trailing data' }
    } catch {
        Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_MANUAL_EVIDENCE_INVALID' 'A JSONL evidence record is malformed or contains duplicate properties.' $null
    }
}

function Get-CcodOfficialDraftJsonLines {
    param(
        [Parameter(Mandatory)][string]$Path,
        [AllowNull()][Nullable[DateTimeOffset]]$NotBefore
    )
    $full = Assert-CcodOfficialDraftRegularEvidenceFile -Path $Path
    try {
        $text = [IO.File]::ReadAllText($full, [Text.UTF8Encoding]::new($false, $true))
        $records = [Collections.Generic.List[object]]::new()
        $lines = @($text -split "`r?`n")
        for ($lineIndex = 0; $lineIndex -lt $lines.Count; $lineIndex++) {
            $line = $lines[$lineIndex]
            if ([string]::IsNullOrWhiteSpace($line)) {
                if ($lineIndex -eq ($lines.Count - 1) -and $line -ceq '' -and ($text.EndsWith("`n") -or $text.EndsWith("`r"))) { continue }
                throw 'json blank line'
            }
            Assert-CcodOfficialDraftJsonNoDuplicateProperties -Raw $line
            $value = $line | ConvertFrom-Json -ErrorAction Stop
            if ($value -isnot [pscustomobject]) { throw 'json line object' }
            $timestampProperties = @($value.PSObject.Properties | Where-Object { $_.Name -ceq 'timestampUtc' })
            if ($timestampProperties.Count -ne 1 -or $timestampProperties[0].Value -isnot [string] -or -not (Test-CcodOfficialDraftCanonicalUtc $timestampProperties[0].Value)) { throw 'timestamp field' }
            if ($null -ne $NotBefore) {
                $timestamp = [DateTimeOffset]::ParseExact([string]$timestampProperties[0].Value, 'o', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal)
                if ($timestamp -lt [DateTimeOffset]$NotBefore) { continue }
            }
            $records.Add($value)
        }
        return @($records)
    } catch {
        Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_MANUAL_EVIDENCE_INVALID' 'Manual evidence log is not valid UTF-8 JSONL.' $full
    }
}

function Get-CcodOfficialDraftTrayActionProof {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Operation,
        [AllowNull()][Nullable[DateTimeOffset]]$NotBefore
    )
    $allowedCommands = @{
        About = @('ShowAbout')
        Language = @('SetLanguageSystem','SetLanguageChinese','SetLanguageEnglish')
        OpenLogs = @('OpenLogs')
        Repair = @('CheckAndRepair')
    }
    $matches = [Collections.Generic.List[object]]::new()
    foreach ($record in @(Get-CcodOfficialDraftJsonLines -Path $Path -NotBefore $NotBefore)) {
        if ([string]$record.stage -cne 'TrayAction') { continue }
        $fields = @($record.PSObject.Properties.Name)
        if (($fields -join ',') -cne 'schemaVersion,timestampUtc,component,stage,code,outcome,command,revision,status' -or
            -not (Test-CcodOfficialDraftIntegerValue $record.schemaVersion) -or [int64]$record.schemaVersion -ne 1 -or
            $record.timestampUtc -isnot [string] -or $record.component -isnot [string] -or $record.stage -isnot [string] -or $record.stage -cne 'TrayAction' -or $record.component -cne 'Supervisor' -or
            $record.code -isnot [string] -or $record.code -cne 'CCOD_TRAY_ACTION_COMPLETED' -or
            $record.outcome -isnot [string] -or $record.outcome -cne 'Completed' -or
            $record.command -isnot [string] -or -not $allowedCommands.ContainsKey($Operation) -or $allowedCommands[$Operation] -cnotcontains [string]$record.command -or
            -not (Test-CcodOfficialDraftIntegerValue $record.revision) -or [uint64]$record.revision -eq 0 -or
            $record.status -isnot [string] -or $record.status -cne 'Completed') { Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_MANUAL_EVIDENCE_INVALID' 'Tray action proof is malformed or has invalid field types.' $Path }
        $matches.Add($record)
    }
    if ($matches.Count -ne 1) {
        Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_MANUAL_OPERATION_UNPROVEN' 'The requested tray operation has no unique verified terminal result.' $Operation
    }
    return $matches[0]
}

function Get-CcodOfficialDraftRemoteProof {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedChallenge,
        [Parameter(Mandatory)][Nullable[DateTimeOffset]]$NotBefore,
        [Parameter(Mandatory)][string]$ExpectedVersion,
        [Parameter(Mandatory)][string]$ExpectedRuntimeId,
        [Parameter(Mandatory)][UInt64]$ExpectedGeneration,
        [Parameter(Mandatory)][string]$ExpectedManifestSha256
    )
    $records = @(Get-CcodOfficialDraftJsonLines -Path $Path -NotBefore $NotBefore)
    if ($records.Count -ne 1) { Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_REMOTE_UNPROVEN' 'Second-device proof must contain exactly one structured record.' $Path }
    $record = $records[0]
    $expected = @('schemaVersion','timestampUtc','kind','operation','deviceRole','challenge','candidateVersion','runtimeId','runtimeGeneration','runtimeManifestSha256','attestation','connection','control','outcome','code')
    if (($record.PSObject.Properties.Name -join ',') -cne ($expected -join ',') -or
        -not (Test-CcodOfficialDraftIntegerValue $record.schemaVersion) -or [int64]$record.schemaVersion -ne 1 -or
        $record.timestampUtc -isnot [string] -or
        $record.kind -isnot [string] -or $record.kind -cne 'remote-control-manual-proof' -or
        $record.operation -isnot [string] -or $record.operation -cne 'SecondDeviceControl' -or
        $record.deviceRole -isnot [string] -or $record.deviceRole -cne 'SecondDevice' -or
        $record.challenge -isnot [string] -or $record.challenge -cne $ExpectedChallenge -or
        $record.candidateVersion -isnot [string] -or $record.candidateVersion -cne $ExpectedVersion -or
        $record.runtimeId -isnot [string] -or $record.runtimeId -cne $ExpectedRuntimeId -or
        -not (Test-CcodOfficialDraftPositiveInteger $record.runtimeGeneration) -or [UInt64]$record.runtimeGeneration -ne $ExpectedGeneration -or
        $record.runtimeManifestSha256 -isnot [string] -or $record.runtimeManifestSha256 -cne $ExpectedManifestSha256 -or
        $record.attestation -isnot [string] -or $record.attestation -cne 'HumanReviewedStructuredAttestation' -or
        $record.connection -isnot [string] -or $record.connection -cne 'Connected' -or
        $record.control -isnot [string] -or $record.control -cne 'Completed' -or
        $record.outcome -isnot [string] -or $record.outcome -cne 'Completed' -or
        $record.code -isnot [string] -or $record.code -cne 'CCOD_REMOTE_ACTION_COMPLETED') {
        Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_REMOTE_UNPROVEN' 'Second-device proof is malformed or does not prove a completed connection and control.' $Path
    }
    return $record
}

function Get-CcodOfficialDraftTrayHostReadyProof {
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$RuntimeId,
        [Parameter(Mandatory)]$TrayHosts
    )
    $logPath = Join-Path ([IO.Path]::GetFullPath($InstallRoot)) 'logs\supervisor.log'
    if ($TrayHosts.Count -ne 1) { return $null }
    $host = $TrayHosts[0]
    if (-not (Test-CcodOfficialDraftExactProperties -Value $host -Expected @('pid','creationTimeUtc')) -or
        -not (Test-CcodOfficialDraftInt32 $host.pid) -or [int]$host.pid -le 0 -or
        $host.creationTimeUtc -isnot [string] -or -not (Test-CcodOfficialDraftCanonicalUtc $host.creationTimeUtc)) {
        Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_MANUAL_EVIDENCE_INVALID' 'TrayHost identity is malformed or not canonical.' $logPath
    }
    $matches = [Collections.Generic.List[object]]::new()
    foreach ($record in @(Get-CcodOfficialDraftJsonLines -Path $logPath)) {
        if ([string]$record.stage -cne 'TrayHostReady') { continue }
        $fields = @($record.PSObject.Properties.Name)
        if (($fields -join ',') -cne 'schemaVersion,timestampUtc,component,stage,code,outcome,runtimeId,hostPid,hostCreationTimeUtc,protocolMajor,capabilities' -or
            -not (Test-CcodOfficialDraftIntegerValue $record.schemaVersion) -or [int64]$record.schemaVersion -ne 1 -or
            $record.timestampUtc -isnot [string] -or $record.component -isnot [string] -or $record.stage -isnot [string] -or $record.stage -cne 'TrayHostReady' -or $record.component -cne 'Supervisor' -or
            $record.code -isnot [string] -or $record.code -cne 'CCOD_TRAYHOST_READY' -or
            $record.outcome -isnot [string] -or $record.outcome -cne 'Completed' -or
            $record.runtimeId -isnot [string] -or [string]::IsNullOrWhiteSpace($record.runtimeId) -or
            -not (Test-CcodOfficialDraftInt32 $record.hostPid) -or [int]$record.hostPid -le 0 -or
            $record.hostCreationTimeUtc -isnot [string] -or -not (Test-CcodOfficialDraftCanonicalUtc $record.hostCreationTimeUtc) -or
            -not (Test-CcodOfficialDraftIntegerValue $record.protocolMajor) -or [int64]$record.protocolMajor -ne 2 -or
            -not (Test-CcodOfficialDraftPositiveInteger $record.capabilities) -or [uint64]$record.capabilities -eq 0) { Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_MANUAL_EVIDENCE_INVALID' 'TrayHost ready proof is malformed or has invalid field types.' $logPath }
        if ($record.runtimeId -cne $RuntimeId) { continue }
        $matches.Add($record)
    }
    $identityMatches = [Collections.Generic.List[object]]::new()
    foreach ($record in $matches) {
        if ([int]$record.hostPid -eq [int]$host.pid -and $record.hostCreationTimeUtc -ceq $host.creationTimeUtc) { $identityMatches.Add($record) }
    }
    if ($identityMatches.Count -ne 1) { return $null }
    return $identityMatches[0]
}

function Assert-CcodOfficialDraftDebugEndpointOwnership {
    param([AllowNull()]$Endpoints,[Parameter(Mandatory)][int[]]$ExpectedPorts,[Parameter(Mandatory)][int]$ExpectedPid,[Parameter(Mandatory)][string]$ExpectedCreationTimeUtc)
    try {
        if ($ExpectedPid -le 0 -or $null -eq $Endpoints) { throw 'debug endpoint owner' }
        $expected = @($ExpectedPorts | Sort-Object -Unique)
        if ($expected.Count -eq 0 -or @($Endpoints).Count -ne $expected.Count) { throw 'debug endpoint count' }
        $seen = [Collections.Generic.HashSet[int]]::new()
        foreach ($endpoint in @($Endpoints)) {
            if (-not (Test-CcodOfficialDraftExactProperties -Value $endpoint -Expected @('localAddress','localPort','owningProcess','owningProcessCreationTimeUtc')) -or
                $endpoint.localAddress -isnot [string] -or $endpoint.localAddress -cne '127.0.0.1' -or
                -not (Test-CcodOfficialDraftPositiveInteger $endpoint.localPort) -or [int]$endpoint.localPort -gt 65535 -or
                -not (Test-CcodOfficialDraftPositiveInteger $endpoint.owningProcess) -or [int]$endpoint.owningProcess -ne $ExpectedPid -or
                $endpoint.owningProcessCreationTimeUtc -isnot [string] -or [string]::IsNullOrWhiteSpace($endpoint.owningProcessCreationTimeUtc) -or $endpoint.owningProcessCreationTimeUtc -cne $ExpectedCreationTimeUtc -or
                -not $seen.Add([int]$endpoint.localPort)) { throw 'debug endpoint owner' }
        }
        if (@($seen | Where-Object { $expected -contains $_ }).Count -ne $expected.Count) { throw 'debug endpoint ports' }
        return $true
    } catch {
        if ($_.FullyQualifiedErrorId -like 'CCOD_ACCEPTANCE_*') { throw }
        Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_OBSERVATION_UNAVAILABLE' 'Debug endpoints are not bound to the verified process identity.' $null
    }
}

function Get-CcodOfficialDraftDefaultAdapters {
    $debugOwnershipFunction = ${function:Assert-CcodOfficialDraftDebugEndpointOwnership}
    $manualTerminalStates = $script:CcodOfficialDraftManualTerminalStates
    $manualResultCodes = $script:CcodOfficialDraftManualResultCodes
    $defaults = @{}
    $assetModule = Get-CcodOfficialDraftAssetModule
    $defenderModule = Get-CcodOfficialDraftDefenderModule
    $moduleInfo = $ExecutionContext.SessionState.Module
    $openEvidenceReadLease = { param($Paths) & $moduleInfo { param($EvidencePaths) Open-CcodOfficialDraftEvidenceReadLease -Paths $EvidencePaths } $Paths }.GetNewClosure()
    $checkEvidenceReadLease = { param($Lease) & $moduleInfo { param($EvidenceLease) Assert-CcodOfficialDraftEvidenceReadLease -Lease $EvidenceLease } $Lease }.GetNewClosure()
    $closeEvidenceReadLease = { param($Lease) & $moduleInfo { param($EvidenceLease) Close-CcodOfficialDraftEvidenceReadLease -Lease $EvidenceLease } $Lease }.GetNewClosure()
    $normalizeObservedIdentities = {
        param($Records,$Kind)
        & $moduleInfo {
            param($Values,$Label)
            if ($Values -isnot [array]) { throw "$Label observation array" }
            foreach ($value in $Values) {
                if (Test-CcodOfficialDraftExactProperties -Value $value -Expected @('Pid','CreationTimeUtc')) {
                    $canonical = [pscustomobject][ordered]@{ pid = $value.Pid; creationTimeUtc = $value.CreationTimeUtc }
                } elseif (Test-CcodOfficialDraftExactProperties -Value $value -Expected @('pid','creationTimeUtc')) {
                    $canonical = $value
                } else { throw "$Label observation identity" }
                ConvertTo-CcodOfficialDraftSafeProcessIdentity -Value $canonical -Label $Label
            }
        } $Records $Kind
    }.GetNewClosure()
    $trayActionProof = {
        param($Path,$Operation,$NotBefore)
        & $moduleInfo { param($ProofPath,$ProofOperation,$ProofNotBefore) Get-CcodOfficialDraftTrayActionProof -Path $ProofPath -Operation $ProofOperation -NotBefore $ProofNotBefore } $Path $Operation $NotBefore
    }.GetNewClosure()
    $remoteProof = {
        param($Path,$ExpectedChallenge,$NotBefore,$ExpectedVersion,$ExpectedRuntimeId,$ExpectedGeneration,$ExpectedManifestSha256)
        & $moduleInfo { param($ProofPath,$Challenge,$ProofNotBefore,$Version,$RuntimeId,$Generation,$ManifestHash) Get-CcodOfficialDraftRemoteProof -Path $ProofPath -ExpectedChallenge $Challenge -NotBefore $ProofNotBefore -ExpectedVersion $Version -ExpectedRuntimeId $RuntimeId -ExpectedGeneration $Generation -ExpectedManifestSha256 $ManifestHash } $Path $ExpectedChallenge $NotBefore $ExpectedVersion $ExpectedRuntimeId $ExpectedGeneration $ExpectedManifestSha256
    }.GetNewClosure()
    $trayReadyProofCommand = {
        param($Root,$RuntimeId,$Hosts)
        & $moduleInfo { param($InstallRoot,$ExpectedRuntimeId,$TrayHosts) Get-CcodOfficialDraftTrayHostReadyProof -InstallRoot $InstallRoot -RuntimeId $ExpectedRuntimeId -TrayHosts $TrayHosts } $Root $RuntimeId $Hosts
    }.GetNewClosure()
    $integrationModule = Get-CcodOfficialDraftIntegrationModule
    $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    $throwAcceptanceError = {
        param($Id, $Message, $Target)
        throw [Management.Automation.ErrorRecord]::new(
            [InvalidOperationException]::new($Message),
            $Id,
            [Management.Automation.ErrorCategory]::InvalidOperation,
            $Target
        )
    }.GetNewClosure()
    if ([string]::IsNullOrWhiteSpace($localAppData)) {
        & $throwAcceptanceError 'CCOD_ACCEPTANCE_OBSERVATION_UNAVAILABLE' 'Local application data is unavailable for installed-lifecycle observation.' $null
    }
    $configuredInstallRoot = [string]$script:CcodOfficialDraftInstallRoot
    if ([string]::IsNullOrWhiteSpace($configuredInstallRoot)) {
        $configuredInstallRoot = Join-Path $localAppData 'CodexControlOtherDevices'
    }
    $pathProbe = { param($Path) Get-Item -LiteralPath $Path -Force -ErrorAction Stop }.GetNewClosure()
    $pathState = {
        param($Path,$ExpectDirectory,$Probe,$ErrorId)
        & $moduleInfo {
            param($ObservedPath,$ExpectedDirectory,$GetItem,$AcceptanceErrorId)
            Get-CcodOfficialDraftOptionalPathState -Path $ObservedPath -ExpectDirectory $ExpectedDirectory -GetItem $GetItem -ErrorId $AcceptanceErrorId
        } $Path $ExpectDirectory $Probe $ErrorId
    }.GetNewClosure()
    $integerValue = {
        param($Value)
        & $moduleInfo { param($ObservedValue) Test-CcodOfficialDraftIntegerValue -Value $ObservedValue } $Value
    }.GetNewClosure()
    $fileHash = {
        param($Path)
        & $moduleInfo { param($ObservedPath) Get-CcodOfficialDraftFileSha256 -Path $ObservedPath } $Path
    }.GetNewClosure()
    $hashValue = {
        param($Value)
        & $moduleInfo { param($ObservedValue) Test-CcodOfficialDraftHash $ObservedValue } $Value
    }.GetNewClosure()
    try {
        if (-not [IO.Path]::IsPathRooted($configuredInstallRoot)) { throw 'install root absolute' }
        $installRoot = [IO.Path]::GetFullPath($configuredInstallRoot)
        if ($installRoot -cne $configuredInstallRoot.TrimEnd('\')) { throw 'install root canonical' }
        $installRootPresent = & $pathState $installRoot $true $pathProbe 'CCOD_ACCEPTANCE_OBSERVATION_UNAVAILABLE'
        if ($installRootPresent) {
            [void](Assert-CcodOfficialDraftSafeDirectory -Path $installRoot -ErrorId 'CCOD_ACCEPTANCE_OBSERVATION_UNAVAILABLE')
        }
    } catch {
        if ($_.FullyQualifiedErrorId -like 'CCOD_ACCEPTANCE_*') { throw }
        & $throwAcceptanceError 'CCOD_ACCEPTANCE_OBSERVATION_UNAVAILABLE' 'The installed lifecycle root is unavailable or unsafe.' $null
    }
    $debugPorts = [Collections.Generic.List[int]]::new()
    $defaults.ValidateAssetSet = {
        param($Path, $Version)
        & $assetModule { param($AssetDirectory,$ExpectedVersion) Test-CcodExactReleaseAssetSet -AssetDirectory $AssetDirectory -Version $ExpectedVersion } $Path $Version
    }.GetNewClosure()
    $defaults.ValidatePreviousSetup = {
        param($Path, $Version)
        try {
            & $moduleInfo {param($Directory,$ExpectedVersion)Get-CcodOfficialDraftPreviousSetupContract -Directory $Directory -Version $ExpectedVersion} $Path $Version
        } catch {
            & $throwAcceptanceError 'CCOD_ACCEPTANCE_PREVIOUS_ASSET_INVALID' 'The previous public v2.5.21 Setup is not manifest-bound.' $null
        }
    }.GetNewClosure()
    $defaults.GetDraftIdentity = {
        param($Path, $Candidate, $ExpectedDraftId)
        if ([string]::IsNullOrWhiteSpace([string]$ExpectedDraftId)) {
            & $throwAcceptanceError 'CCOD_ACCEPTANCE_DRAFT_IDENTITY_INVALID' 'The official draft database identifier is required.' $null
        }
        [pscustomobject][ordered]@{ tag = 'v2.5.22'; id = [string]$ExpectedDraftId }
    }.GetNewClosure()
    $defaults.InvokeDefenderCheck = {
        param($Path, $AssetType, $Origin, $Version, $GitCommit, $EvidencePath)
        $names = @(& $assetModule { param($ExpectedVersion) Get-CcodExpectedReleaseAssetNames -Version $ExpectedVersion } $Version)
        $assetIndex = if ($AssetType -ceq 'Setup') { 5 } else { 0 }
        $checksumIndex = if ($AssetType -ceq 'Setup') { 6 } else { 1 }
        $manifestIndex = if ($AssetType -ceq 'Setup') { 10 } else { 4 }
        $candidatePath = Join-Path $Path $names[$assetIndex]
        $checksumPath = Join-Path $Path $names[$checksumIndex]
        $manifestPath = Join-Path $Path $names[$manifestIndex]
        & $defenderModule {
            param($CandidatePath,$ChecksumPath,$ManifestPath,$ScanOrigin,$ExpectedVersion,$ExpectedGitCommit,$ReceiptPath)
            Invoke-CcodReleaseDefenderCheck -CandidatePath $CandidatePath -ChecksumPath $ChecksumPath -ManifestPath $ManifestPath -Origin $ScanOrigin -ExpectedVersion $ExpectedVersion -ExpectedGitCommit $ExpectedGitCommit -EvidencePath $ReceiptPath
        } $candidatePath $checksumPath $manifestPath $Origin $Version $GitCommit $EvidencePath
    }.GetNewClosure()
    $defaults.GetUtcNow = { [datetime]::UtcNow }.GetNewClosure()
    $defaults.CaptureFacts = {
        param($Context, $Point)
        try {
            $expectedVersion = if ($Context.PSObject.Properties['expectedVersion'] -and $Context.expectedVersion -is [string]) { [string]$Context.expectedVersion } else { $null }
            $observationVersion = $expectedVersion
            if ($Context.phase -ceq 'LegacyUpgrade' -and $Point -ceq 'Before' -and $Context.PSObject.Properties['previousSetup'] -and $null -ne $Context.previousSetup -and $Context.previousSetup.version -is [string]) { $observationVersion = [string]$Context.previousSetup.version }
            $values = @(& $integrationModule { param($Root,$Version) Get-CcodInstalledLifecycleFacts -InstallRoot $Root -ExpectedVersion $Version } $installRoot $observationVersion)
            if ($values.Count -ne 1 -or $null -eq $values[0]) { throw 'facts' }
            $raw = $values[0]
            foreach ($name in @('installRootPresent','appPresent','runtimeRootPresent','activePointerPresent','activeRuntimeId','activeGeneration','runtimeManifestSha256','supervisor','trayHost','codex','taskState','statusPhase','statusRuntimeId','statusCodex','transitionStage','lifecycleReceipt','aboutVersion','deviceKeyPresent','deviceKeySha256','shortcuts','debugPorts','debugEndpoints')) {
                if ($null -eq $raw.PSObject.Properties[$name]) { throw 'facts shape' }
            }
            $get = {
                param($Name)
                $property = $raw.PSObject.Properties[$Name]
                if ($null -eq $property) { return $null }
                return ,$property.Value
            }.GetNewClosure()
            $supervisor = @(& $normalizeObservedIdentities $raw.PSObject.Properties['supervisor'].Value 'supervisor')
            $trayHost = @(& $normalizeObservedIdentities $raw.PSObject.Properties['trayHost'].Value 'tray host')
            $activeRuntimeId = & $get 'activeRuntimeId'
            $activeGeneration = & $get 'activeGeneration'
            $receipt = & $get 'lifecycleReceipt'
            $taskState = & $get 'taskState'
            $appPresent = & $get 'appPresent'
            $aboutVersion = & $get 'aboutVersion'
            $statusPhase = & $get 'statusPhase'
            $statusRuntimeId = & $get 'statusRuntimeId'
            $statusCodex = & $get 'statusCodex'
            $transitionStage = & $get 'transitionStage'
            if ($transitionStage -isnot [string] -or [string]::IsNullOrWhiteSpace($transitionStage)) { throw 'transition stage' }
            $codex = @(& $normalizeObservedIdentities $raw.PSObject.Properties['codex'].Value 'codex')
            if ($null -ne $raw.PSObject.Properties['codexCount']) {
                $rawCodexCount = & $get 'codexCount'
                if (-not (& $integerValue $rawCodexCount) -or [int64]$rawCodexCount -ne [int64]$codex.Count) { throw 'codex count' }
            }
            $deviceKeyPresent = & $get 'deviceKeyPresent'
            $deviceKeySha256 = & $get 'deviceKeySha256'
            $shortcutsValue = & $get 'shortcuts'
            $shortcuts = if ($null -eq $shortcutsValue) {
                [pscustomobject][ordered]@{ startMenu = $false; desktop = $false }
            } else { $shortcutsValue }
            $installRootPresent = [bool](& $pathState $installRoot $true $pathProbe 'CCOD_ACCEPTANCE_OBSERVATION_UNAVAILABLE')
            $runtimeRootPresent = & $get 'runtimeRootPresent'
            $activePointerPresent = & $get 'activePointerPresent'
            if ($runtimeRootPresent -isnot [bool] -or $activePointerPresent -isnot [bool]) { throw 'selector facts' }
            $terminalValid = $null -ne $receipt -and
                $receipt.kind -is [string] -and $receipt.kind -ceq 'RestartAndRepair' -and
                $receipt.origin -is [string] -and $receipt.origin -ceq 'Installer' -and
                $receipt.runtimeId -is [string] -and $receipt.runtimeGeneration -is [ValueType] -and
                $receipt.phase -is [string] -and $receipt.phase -ceq 'Completed'
            if ($null -ne $activeGeneration -and -not [bool](& $integerValue $activeGeneration)) { throw 'active generation type' }
            $generationValid = $false
            $generation = [UInt64]0
            try {
                if ($null -ne $activeGeneration -and [bool](& $integerValue $activeGeneration)) {
                    $generation = [UInt64]$activeGeneration
                    $generationValid = $generation -gt 0
                }
            } catch { $generationValid = $false }
            $runtimeValid = $activeRuntimeId -is [string] -and $activeRuntimeId -cmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,95}\z'
            $manifestHash = & $get 'runtimeManifestSha256'
            $expectedVersionProperties = @($Context.PSObject.Properties | Where-Object { $_.Name -ceq 'expectedVersion' })
            $expectedVersion = if ($expectedVersionProperties.Count -eq 1 -and $expectedVersionProperties[0].Value -is [string]) { [string]$expectedVersionProperties[0].Value } else { $null }
            $requiresCandidateReady = $Context.phase -in @('FreshInstall','PreReboot','PostReboot','ReadyForManualEvidence','TrayEvidence','RemoteEvidence') -or
                ($Context.phase -ceq 'LegacyUpgrade' -and ($Point -ceq 'Before' -or ($Point -ceq 'After' -and $aboutVersion -ceq $expectedVersion)))
            $readinessVersion = if ($Context.phase -ceq 'LegacyUpgrade' -and $Point -ceq 'Before') { $observationVersion } else { $expectedVersion }
            $observedDebugValue = & $get 'debugEndpoints'
            $expectedDebugValue = & $get 'debugPorts'
            $debugEndpoints = @()
            if ($null -ne $observedDebugValue) { $debugEndpoints = @($observedDebugValue) }
            $expectedPorts = @()
            if ($null -ne $expectedDebugValue) { $expectedPorts = @($expectedDebugValue) }
            $debugOwnershipValid = $true
            $trayReadyProof = $null
            $collectorAuthenticated = $false
            if ($requiresCandidateReady) {
                $collectorAuthenticated = & $get 'trayAuthenticated'
                if ($collectorAuthenticated -isnot [bool]) { throw 'tray authentication observation' }
                $ownerPid = $null
                if ($null -ne $statusCodex -and $statusCodex.PSObject.Properties['pid']) { $ownerPid = $statusCodex.pid }
                elseif ($codex.Count -eq 1) { $ownerPid = $codex[0].pid }
                if ($null -eq $ownerPid -or $ownerPid -isnot [ValueType] -or $ownerPid -is [bool] -or $expectedPorts.Count -ne 2 -or @($expectedPorts | Sort-Object -Unique).Count -ne 2) { throw 'debug endpoint readiness' }
                [void](& $debugOwnershipFunction -Endpoints $debugEndpoints -ExpectedPorts $expectedPorts -ExpectedPid ([int]$ownerPid) -ExpectedCreationTimeUtc ([string]$codex[0].creationTimeUtc))
            }
            if ($requiresCandidateReady -and $trayHost.Count -eq 1 -and $activeRuntimeId -is [string]) {
                if($Context.phase-ceq'LegacyUpgrade'-and$Point-ceq'Before'-and$readinessVersion-ceq'2.5.21'){
                    if($activeRuntimeId-cnotmatch'^2\.5\.21-[0-9a-f]{16}\z'){throw 'legacy runtime profile'}
                    $legacyProof=@(&$integrationModule {param($Root,$RuntimeId,$Parent,$HostIdentity)Get-CcodInstalledLifecycleLegacyTrayReadyProof -InstallRoot $Root -RuntimeId $RuntimeId -Supervisor $Parent -TrayHost $HostIdentity} $installRoot $activeRuntimeId $supervisor $trayHost)
                    if($legacyProof.Count-ne1-or$legacyProof[0]-isnot[bool]){throw 'legacy readiness proof'}
                    if($legacyProof[0]){$trayReadyProof=$true}
                } else {
                    $trayReadyProof = & $trayReadyProofCommand $installRoot ([string]$activeRuntimeId) $trayHost
                }
            }
            $statusCodexPid = if ($null -ne $statusCodex) { $statusCodex.pid } else { $null }
            $codexPid = if ($codex.Count -eq 1) { $codex[0].pid } else { $null }
            $codexStatusMatches = $false
            if ($statusCodexPid -ne $null -and $codexPid -ne $null -and
                [bool](& $integerValue $statusCodexPid) -and [bool](& $integerValue $codexPid) -and
                [uint64]$statusCodexPid -gt 0 -and [uint64]$codexPid -gt 0 -and
                [uint64]$statusCodexPid -eq [uint64]$codexPid -and [string]$statusCodex.creationTimeUtc -ceq [string]$codex[0].creationTimeUtc) {
                $codexStatusMatches = $true
            }
            $ready = $appPresent -is [bool] -and [bool]$appPresent -and
                $runtimeRootPresent -and $activePointerPresent -and
                $runtimeValid -and $generationValid -and $manifestHash -is [string] -and $manifestHash -cmatch '^[0-9a-f]{64}\z' -and
                $taskState -is [string] -and $taskState -in @('Ready','Running') -and
                $supervisor.Count -eq 1 -and $trayHost.Count -eq 1 -and $trayReadyProof -ne $null -and $collectorAuthenticated -and $debugOwnershipValid -and $terminalValid -and
                $aboutVersion -is [string] -and $aboutVersion -ceq $readinessVersion -and
                $statusPhase -is [string] -and $statusPhase -ceq 'Active' -and $transitionStage -ceq 'Idle' -and
                $statusRuntimeId -is [string] -and $statusRuntimeId -ceq [string]$activeRuntimeId -and $codexStatusMatches -and
                [string]$receipt.runtimeId -ceq [string]$activeRuntimeId -and [UInt64]$receipt.runtimeGeneration -eq $generation
            if ($Context.phase -ceq 'Uninstall' -and $Point -ceq 'Before') {
                $debugPorts.Clear()
                if ($expectedDebugValue -isnot [array]) { throw 'debug port observation' }
                foreach ($port in $expectedPorts) {
                    if (($port -isnot [int] -and $port -isnot [long]) -or $port -lt 1 -or $port -gt 65535) { throw 'debug port observation' }
                    [void]$debugPorts.Add([int]$port)
                }
                if ($debugPorts.Count -ne 2 -or @($debugPorts | Sort-Object -Unique).Count -ne 2) { throw 'debug port observation' }
            }
            if ($Context.phase -ceq 'Uninstall' -and $Point -ceq 'After' -and $debugPorts.Count -gt 0) {
                $closed = @(& $integrationModule { param($Ports) Test-CcodInstalledLifecycleDebugPortsClosed -Ports $Ports } ([int[]]$debugPorts))
                if ($closed.Count -ne 1 -or $closed[0] -isnot [bool]) { throw 'debug endpoint observation' }
                if (-not $closed[0]) {
                    & $throwAcceptanceError 'CCOD_ACCEPTANCE_UNINSTALL_OBSERVATION_INVALID' 'A previously declared debug port still has a listener after uninstall.' $null
                }
            }
            $bootValues = @(Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop)
            if ($bootValues.Count -ne 1 -or $null -eq $bootValues[0].LastBootUpTime) { throw 'boot identity' }
            $lastBoot = $bootValues[0].LastBootUpTime
            if ($lastBoot -isnot [datetime]) { $lastBoot = [datetime]::Parse([string]$lastBoot, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) }
            $bootId = 'boot-' + $lastBoot.ToUniversalTime().ToString('yyyyMMddTHHmmssfffffffZ', [Globalization.CultureInfo]::InvariantCulture)
            $trayHostIdentity = $null
            if ($trayHost.Count -eq 1) { $trayHostIdentity = [pscustomobject][ordered]@{ pid = $trayHost[0].pid; creationTimeUtc = [string]$trayHost[0].creationTimeUtc } }
            return [pscustomobject][ordered]@{
                installRootPresent = [bool]$installRootPresent
                installReady = [bool]$ready
                appRootPresent = if ($appPresent -is [bool]) { [bool]$appPresent } else { $false }
                runtimeRootPresent = $runtimeRootPresent
                activePointerPresent = $activePointerPresent
                activeRuntimeId = if ($runtimeValid) { [string]$activeRuntimeId } else { $null }
                activeGeneration = if ($generationValid) { $generation } else { $null }
                runtimeManifestSha256 = if ($manifestHash -is [string] -and $manifestHash -cmatch '^[0-9a-f]{64}\z') { [string]$manifestHash } else { $null }
                supervisor = @($supervisor)
                trayHost = @($trayHost)
                codex = @($codex)
                codexCount = [int]$codex.Count
                trayHostIdentity = $trayHostIdentity
                trayAuthenticated = [bool]$ready
                taskState = if ($taskState -is [string]) { [string]$taskState } else { 'Unknown' }
                statusPhase = if ($statusPhase -is [string]) { [string]$statusPhase } else { 'Unavailable' }
                statusRuntimeId = if ($statusRuntimeId -is [string]) { [string]$statusRuntimeId } else { $null }
                statusCodex = $statusCodex
                transitionStage = $transitionStage
                lifecycleReceipt = $receipt
                aboutVersion = if ($aboutVersion -is [string]) { [string]$aboutVersion } else { $null }
                shortcuts = $shortcuts
                debugPorts = [int[]]$expectedPorts
                protectionReady = [bool]$ready
                protectionRecovered = [bool]($ready -and $Context.phase -ceq 'PostReboot' -and $Point -ceq 'After')
                deviceKeyPresent = if ($deviceKeyPresent -is [bool]) { [bool]$deviceKeyPresent } else { $false }
                deviceKeySha256 = if ($deviceKeySha256 -is [string]) { [string]$deviceKeySha256 } else { $null }
                bootId = $bootId
                debugEndpoints = @($debugEndpoints)
            }
        } catch {
            if ($_.FullyQualifiedErrorId -like 'CCOD_ACCEPTANCE_*') { throw }
            & $throwAcceptanceError 'CCOD_ACCEPTANCE_OBSERVATION_UNAVAILABLE' 'Installed lifecycle observations are unavailable or cannot be proven safely.' $null
        }
    }.GetNewClosure()
    $assertManualReadiness = {
        param([string]$ExpectedVersion,[string]$ExpectedRuntimeId,$ExpectedGeneration,[string]$ExpectedManifestSha256,[string]$ExpectedBootId,[string]$ExpectedDeviceKeySha256)
        $readinessContext = [pscustomobject][ordered]@{ phase = 'PostReboot'; expectedVersion = $ExpectedVersion }
        $values = @(& $defaults.CaptureFacts $readinessContext 'After')
        if ($values.Count -ne 1 -or $null -eq $values[0]) { throw 'manual readiness observation' }
        $facts = $values[0]
        $terminal = $facts.lifecycleReceipt
        if ($facts.appRootPresent -isnot [bool] -or -not [bool]$facts.appRootPresent -or
            $facts.runtimeRootPresent -isnot [bool] -or -not [bool]$facts.runtimeRootPresent -or
            $facts.activePointerPresent -isnot [bool] -or -not [bool]$facts.activePointerPresent -or
            $facts.activeRuntimeId -isnot [string] -or $facts.activeRuntimeId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,95}\z' -or
            $facts.activeGeneration -isnot [UInt64] -or [UInt64]$facts.activeGeneration -lt 1 -or
            @($facts.supervisor).Count -ne 1 -or @($facts.trayHost).Count -ne 1 -or
            $facts.trayAuthenticated -isnot [bool] -or -not [bool]$facts.trayAuthenticated -or
            $facts.protectionReady -isnot [bool] -or -not [bool]$facts.protectionReady -or
            $facts.protectionRecovered -isnot [bool] -or -not [bool]$facts.protectionRecovered -or
            $facts.taskState -isnot [string] -or $facts.taskState -notin @('Ready','Running') -or
            $facts.runtimeManifestSha256 -isnot [string] -or -not (& $hashValue $facts.runtimeManifestSha256) -or
            $facts.bootId -isnot [string] -or $facts.bootId -notmatch '^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\z' -or
            $facts.deviceKeyPresent -isnot [bool] -or -not [bool]$facts.deviceKeyPresent -or
            $facts.deviceKeySha256 -isnot [string] -or $facts.deviceKeySha256 -notmatch '^[0-9a-f]{64}\z' -or
            $null -eq $terminal -or $terminal.kind -isnot [string] -or $terminal.kind -cne 'RestartAndRepair' -or
            $terminal.origin -isnot [string] -or $terminal.origin -cne 'Installer' -or
            $terminal.runtimeId -isnot [string] -or $terminal.runtimeId -cne [string]$facts.activeRuntimeId -or
            $terminal.runtimeGeneration -isnot [UInt64] -or [UInt64]$terminal.runtimeGeneration -ne [UInt64]$facts.activeGeneration -or
            $terminal.phase -isnot [string] -or $terminal.phase -cne 'Completed') { throw 'manual readiness' }
        if (-not [string]::IsNullOrEmpty([string]$ExpectedRuntimeId) -and ($ExpectedRuntimeId -isnot [string] -or $facts.activeRuntimeId -cne $ExpectedRuntimeId)) { throw 'manual persisted runtime' }
        if ($null -ne $ExpectedGeneration -and ($ExpectedGeneration -isnot [UInt64] -or [UInt64]$facts.activeGeneration -ne [UInt64]$ExpectedGeneration)) { throw 'manual persisted generation' }
        if (-not [string]::IsNullOrEmpty([string]$ExpectedManifestSha256) -and ($ExpectedManifestSha256 -isnot [string] -or -not (& $hashValue $ExpectedManifestSha256) -or $facts.runtimeManifestSha256 -cne $ExpectedManifestSha256)) { throw 'manual persisted manifest' }
        if (-not [string]::IsNullOrEmpty([string]$ExpectedDeviceKeySha256) -and ($ExpectedDeviceKeySha256 -isnot [string] -or -not (& $hashValue $ExpectedDeviceKeySha256) -or $facts.deviceKeySha256 -cne $ExpectedDeviceKeySha256)) { throw 'manual persisted device key' }
        if (-not [string]::IsNullOrEmpty([string]$ExpectedBootId) -and ($ExpectedBootId -isnot [string] -or $facts.bootId -cne $ExpectedBootId)) { throw 'manual persisted boot' }
        return $facts
    }.GetNewClosure()
    $defaults.RunPhase = {
        param($Context)
        try {
            if ($Context.allowMachineMutation -isnot [bool] -or -not [bool]$Context.allowMachineMutation) {
                & $throwAcceptanceError 'CCOD_ACCEPTANCE_MACHINE_MUTATION_NOT_ALLOWED' 'This installed-lifecycle operation requires explicit machine-mutation authorization.' $null
            }
            if ($Context.allowCodexRestart -isnot [bool] -or -not [bool]$Context.allowCodexRestart) {
                & $throwAcceptanceError 'CCOD_ACCEPTANCE_CODEX_RESTART_NOT_ALLOWED' 'This installed-lifecycle operation requires explicit Codex-restart authorization.' $null
            }
            $scenario = switch ([string]$Context.phase) {
                'LegacyUpgrade' { 'Upgrade'; break }
                'Uninstall' { 'DirectUninstall'; break }
                'FreshInstall' { 'FreshInstall'; break }
                default { & $throwAcceptanceError 'CCOD_ACCEPTANCE_MACHINE_OPERATION_UNAVAILABLE' 'The requested official-draft phase has no installed-lifecycle scenario mapping.' $null }
            }
            $previousPath = if ([string]$Context.phase -ceq 'LegacyUpgrade') { [string]$Context.previousSetupPath } else { $null }
            $values = @(& $integrationModule {
                param($InstallerPath,$PreviousInstallerPath,$PreviousExpectedVersion,$PreviousInstallerSha256,$PreviousManifestSha256,$ExpectedVersion,$EvidenceRoot,$Mutation,$Restart,$ScenarioName,$ExpectedCandidate)
                Invoke-CcodInstalledLifecycleIntegration -InstallerPath $InstallerPath -PreviousInstallerPath $PreviousInstallerPath -PreviousExpectedVersion $PreviousExpectedVersion -PreviousInstallerSha256 $PreviousInstallerSha256 -PreviousManifestSha256 $PreviousManifestSha256 -ExpectedVersion $ExpectedVersion -EvidenceRoot $EvidenceRoot -AllowMachineMutation:$Mutation -AllowCodexRestart:$Restart -Scenario $ScenarioName -ExpectedCandidate $ExpectedCandidate
            } $Context.setupPath $previousPath $Context.previousSetupVersion $Context.previousSetupSha256 $Context.previousManifestSha256 $Context.expectedVersion $Context.evidenceRoot $Context.allowMachineMutation $Context.allowCodexRestart $scenario $Context.candidate)
            if ($values.Count -ne 1 -or $null -eq $values[0] -or
                $values[0].outcome -isnot [string] -or $values[0].outcome -cne 'Completed' -or
                $null -eq $values[0].verification -or $values[0].verification.verified -isnot [bool] -or
                -not [bool]$values[0].verification.verified) { throw 'integration result' }
            $setupName = [IO.Path]::GetFileName([string]$Context.setupPath)
            $expectedInstallerHash = @($Context.candidate.assetHashes | Where-Object { $_.name -ceq $setupName })
            $installerHash = if ($null -ne $values[0].PSObject.Properties['installerSha256']) { $values[0].installerSha256 } else { $null }
            $runtimeHash = if ($null -ne $values[0].verification.facts.PSObject.Properties['runtimeManifestSha256']) { $values[0].verification.facts.runtimeManifestSha256 } else { $null }
            if ($expectedInstallerHash.Count -ne 1 -or $installerHash -isnot [string] -or -not (& $hashValue $installerHash) -or
                $installerHash -cne [string]$expectedInstallerHash[0].sha256 -or
                ($null -ne $runtimeHash -and ($runtimeHash -isnot [string] -or -not (& $hashValue $runtimeHash))) -or
                ([string]$Context.phase -ceq 'FreshInstall' -and -not (& $hashValue $runtimeHash))) { throw 'integration binding' }
            return [pscustomobject][ordered]@{ completed = $true; outcome = 'Completed'; installerSha256 = [string]$installerHash; runtimeManifestSha256 = if ($null -eq $runtimeHash) { $null } else { [string]$runtimeHash } }
        } catch {
            if ($_.FullyQualifiedErrorId -like 'CCOD_ACCEPTANCE_*') { throw }
            & $throwAcceptanceError 'CCOD_ACCEPTANCE_MACHINE_OPERATION_FAILED' 'The installed-lifecycle operation did not return proven completion.' $null
        }
    }.GetNewClosure()
    $defaults.RunManualOperation = {
        param($Context,$Operation)
        $evidenceReadLease = $null
        try {
            if ($null -eq $Context -or $Operation -isnot [string] -or
                [string]::IsNullOrWhiteSpace([string]$Context.screenshotPath) -or
                [string]::IsNullOrWhiteSpace([string]$Context.redactedLogPath)) { throw 'manual context' }
            $operation = [string]$Operation
            $startedAt = [DateTimeOffset]::UtcNow
            $expectedRuntimeId = if ($null -ne $Context.PSObject.Properties['expectedRuntimeId']) { $Context.expectedRuntimeId } else { $null }
            $expectedGeneration = if ($null -ne $Context.PSObject.Properties['expectedGeneration']) { $Context.expectedGeneration } else { $null }
            $expectedManifestHash = if ($null -ne $Context.PSObject.Properties['expectedRuntimeManifestSha256']) { $Context.expectedRuntimeManifestSha256 } else { $null }
            $expectedDeviceKeyHash = if ($null -ne $Context.PSObject.Properties['expectedDeviceKeySha256']) { $Context.expectedDeviceKeySha256 } else { $null }
            $expectedBootId = if ($null -ne $Context.PSObject.Properties['expectedBootId']) { $Context.expectedBootId } else { $null }
            $expectedAck = 'CCOD_MANUAL_' + $operation.ToUpperInvariant() + '_COMPLETED'
            $instructions = @{
                About = 'Open the CodexRemote-fix tray menu, select About, confirm the dialog, and keep the redacted supervisor action record.'
                Language = 'Open the CodexRemote-fix tray menu, select any enabled language, confirm the presentation changes, and keep the redacted supervisor action record.'
                OpenLogs = 'Open the CodexRemote-fix tray menu, select Open logs, confirm the log directory opens, and keep the redacted supervisor action record.'
                Repair = 'Open the CodexRemote-fix tray menu, select Check and repair remote connection, wait for the terminal result, and keep the redacted supervisor action record.'
                SecondDeviceControl = 'Use the second device to connect to and control this Windows Codex session, then provide one strict redacted JSON proof record.'
            }
            if (-not $instructions.ContainsKey($operation)) { throw 'unsupported manual operation' }
            Write-Host ''
            Write-Host ('Manual official-draft evidence: {0}' -f $operation) -ForegroundColor Cyan
            Write-Host $instructions[$operation] -ForegroundColor Yellow
            if ($operation -ceq 'SecondDeviceControl') { Write-Host ('Include this one-time challenge in the proof: {0}' -f $Context.manualChallenge) -ForegroundColor Yellow }
            $readyBefore = & $assertManualReadiness ([string]$Context.expectedVersion) $expectedRuntimeId $expectedGeneration $expectedManifestHash $expectedBootId $expectedDeviceKeyHash
            $prompt = ('After independently completing the operation, type {0}' -f $expectedAck)
            $ack = if ($null -ne $Context.PSObject.Properties['manualAcknowledgement']) { [string]$Context.manualAcknowledgement } elseif ($null -ne $script:CcodOfficialDraftManualAcknowledgement) { & $script:CcodOfficialDraftManualAcknowledgement $prompt } else { Read-Host $prompt }
            if ([string]$ack -cne $expectedAck) { throw 'manual acknowledgement' }
            $readyAfter = & $assertManualReadiness ([string]$Context.expectedVersion) $expectedRuntimeId $expectedGeneration $expectedManifestHash $expectedBootId $expectedDeviceKeyHash
            if ([string]$readyAfter.activeRuntimeId -cne [string]$readyBefore.activeRuntimeId -or
                [UInt64]$readyAfter.activeGeneration -ne [UInt64]$readyBefore.activeGeneration -or
                [string]$readyAfter.bootId -cne [string]$readyBefore.bootId) { throw 'manual readiness changed' }
            $evidenceReadLease = & $openEvidenceReadLease @([string]$Context.redactedLogPath,[string]$Context.screenshotPath)
 if ($operation -ceq 'SecondDeviceControl') {
     $redactedHashBefore = & $fileHash $Context.redactedLogPath
     $proof = & $remoteProof -Path $Context.redactedLogPath -ExpectedChallenge ([string]$Context.manualChallenge) -NotBefore ([DateTimeOffset]$startedAt) -ExpectedVersion ([string]$Context.expectedVersion) -ExpectedRuntimeId ([string]$readyAfter.activeRuntimeId) -ExpectedGeneration ([UInt64]$readyAfter.activeGeneration) -ExpectedManifestSha256 ([string]$readyAfter.runtimeManifestSha256)
     $remoteDebugPorts = @($readyAfter.debugEndpoints | ForEach-Object { if ($_.localPort -is [ValueType] -and $_.localPort -isnot [bool]) { [int]$_.localPort } })
     $readyAfterCodex = @($readyAfter.codex)
     if ($remoteDebugPorts.Count -ne 2 -or @($remoteDebugPorts | Sort-Object -Unique).Count -ne 2 -or $readyAfterCodex.Count -ne 1) { throw 'remote debug ports' }
     $values = @(& $integrationModule {
         param($Root,$Version,$DebugPorts)
         Get-CcodInstalledLifecycleFacts -InstallRoot $Root -ExpectedVersion $Version -ExpectedDebugPorts ([int[]]$DebugPorts)
     } $installRoot ([string]$Context.expectedVersion) ([int[]]$remoteDebugPorts))
     if ($values.Count -ne 1 -or $null -eq $values[0]) { throw 'remote status' }
     $facts = $values[0]
     $statusCodex = $facts.statusCodex
     $codex = @($facts.codex)
     $codexMatchesReady = $codex.Count -eq 1 -and $readyAfterCodex.Count -eq 1 -and [int]$codex[0].pid -eq [int]$readyAfterCodex[0].pid -and [string]$codex[0].creationTimeUtc -ceq [string]$readyAfterCodex[0].creationTimeUtc
     $remotePortKey = (@($facts.debugPorts | ForEach-Object { [int]$_ } | Sort-Object) -join ',')
     $expectedRemotePortKey = (@($remoteDebugPorts | Sort-Object) -join ',')
     $remoteEndpointValid = $true
     if ($facts.debugEndpoints.Count -ne 2 -or $remotePortKey -cne $expectedRemotePortKey -or -not $codexMatchesReady) { $remoteEndpointValid = $false }
     else {
         foreach ($port in $remoteDebugPorts) {
             $endpointMatches = @($facts.debugEndpoints | Where-Object {
                 $_.localAddress -is [string] -and $_.localAddress -ceq '127.0.0.1' -and
                 $_.localPort -is [ValueType] -and $_.localPort -isnot [bool] -and [int]($_.localPort) -eq [int]$port -and
                 $_.owningProcess -is [ValueType] -and $_.owningProcess -isnot [bool] -and [uint64]($_.owningProcess) -eq [uint64]$readyAfterCodex[0].pid -and
                 $_.owningProcessCreationTimeUtc -is [string] -and $_.owningProcessCreationTimeUtc -ceq [string]$readyAfterCodex[0].creationTimeUtc
             })
             if ($endpointMatches.Count -ne 1) { $remoteEndpointValid = $false }
         }
     }
     if ($facts.aboutVersion -isnot [string] -or $facts.aboutVersion -cne [string]$Context.expectedVersion -or
         $facts.runtimeManifestSha256 -isnot [string] -or $facts.runtimeManifestSha256 -cne [string]$readyAfter.runtimeManifestSha256 -or
         $facts.activeRuntimeId -isnot [string] -or $facts.activeRuntimeId -cne [string]$readyAfter.activeRuntimeId -or
         $facts.activeGeneration -isnot [UInt64] -or [UInt64]$facts.activeGeneration -ne [UInt64]$readyAfter.activeGeneration -or
         $facts.deviceKeyPresent -isnot [bool] -or -not [bool]$facts.deviceKeyPresent -or
         $facts.deviceKeySha256 -isnot [string] -or $facts.deviceKeySha256 -cne [string]$readyAfter.deviceKeySha256 -or
         -not $remoteEndpointValid -or
         $facts.appPresent -isnot [bool] -or -not [bool]$facts.appPresent -or
         $facts.statusPhase -isnot [string] -or $facts.statusPhase -cne 'Active' -or
         $facts.statusRuntimeId -isnot [string] -or $facts.statusRuntimeId -cne [string]$facts.activeRuntimeId -or
         $facts.taskState -isnot [string] -or $facts.taskState -notin @('Ready','Running') -or
         @($facts.trayHost).Count -ne 1 -or $codex.Count -ne 1 -or $null -eq $statusCodex -or
         [int]$statusCodex.pid -ne [int]$codex[0].pid -or [string]$statusCodex.creationTimeUtc -cne [string]$codex[0].creationTimeUtc) { throw 'remote status' }
     $redactedHashAfter = & $fileHash $Context.redactedLogPath
     if ($redactedHashBefore -cne $redactedHashAfter) { throw 'remote evidence changed' }
     & $checkEvidenceReadLease $evidenceReadLease
     return [pscustomobject][ordered]@{ verified = $true; operation = $operation; terminalState = [string]$manualTerminalStates[$operation]; code = [string]$manualResultCodes[$operation]; proof = $proof; screenshotSha256 = [string](& $fileHash $Context.screenshotPath); redactedLogSha256 = [string]$redactedHashAfter }
 }
            $liveLog = Join-Path $installRoot 'logs\supervisor.log'
            $live = & $trayActionProof -Path $liveLog -Operation $operation -NotBefore ([DateTimeOffset]$startedAt)
            $redactedHashBefore = & $fileHash $Context.redactedLogPath
            $redacted = & $trayActionProof -Path $Context.redactedLogPath -Operation $operation -NotBefore ([DateTimeOffset]$startedAt)
            $redactedHashAfter = & $fileHash $Context.redactedLogPath
            if ([string]$redacted.timestampUtc -cne [string]$live.timestampUtc -or
                [string]$redacted.command -cne [string]$live.command -or [uint64]$redacted.revision -ne [uint64]$live.revision -or
                [string]$redacted.code -cne [string]$live.code -or [string]$redacted.status -cne [string]$live.status -or
                $redactedHashBefore -cne $redactedHashAfter) { throw 'tray proof mismatch' }
            $trayProof = [pscustomobject][ordered]@{ timestampUtc = [string]$redacted.timestampUtc; command = [string]$redacted.command; revision = [UInt64]$redacted.revision; code = 'CCOD_TRAY_ACTION_COMPLETED'; status = 'Completed' }
            & $checkEvidenceReadLease $evidenceReadLease
            return [pscustomobject][ordered]@{ verified = $true; operation = $operation; terminalState = [string]$manualTerminalStates[$operation]; code = [string]$manualResultCodes[$operation]; proof = $trayProof; screenshotSha256 = [string](& $fileHash $Context.screenshotPath); redactedLogSha256 = [string]$redactedHashAfter }
        } catch {
            if ($_.FullyQualifiedErrorId -like 'CCOD_ACCEPTANCE_*') { throw }
            & $throwAcceptanceError 'CCOD_ACCEPTANCE_MANUAL_OPERATION_UNPROVEN' 'The requested tray or second-device operation did not produce a unique verified result.' $null
        } finally { & $closeEvidenceReadLease $evidenceReadLease }
    }.GetNewClosure()
    $defaults.GetBootIdentity = {
        try {
            $values = @(Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop)
            if ($values.Count -ne 1 -or $null -eq $values[0].LastBootUpTime) { throw 'boot' }
            $lastBoot = $values[0].LastBootUpTime
            if ($lastBoot -isnot [datetime]) { $lastBoot = [datetime]::Parse([string]$lastBoot, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) }
            return 'boot-' + $lastBoot.ToUniversalTime().ToString('yyyyMMddTHHmmssfffffffZ', [Globalization.CultureInfo]::InvariantCulture)
        } catch {
            & $throwAcceptanceError 'CCOD_ACCEPTANCE_BOOT_ID_UNAVAILABLE' 'The Windows boot identity could not be observed safely.' $null
        }
    }.GetNewClosure()
    $defaults.Reboot = {
        param($Context)
        if ($null -eq $Context -or $Context.allowWindowsReboot -isnot [bool] -or -not [bool]$Context.allowWindowsReboot) {
            & $throwAcceptanceError 'CCOD_ACCEPTANCE_WINDOWS_REBOOT_NOT_ALLOWED' 'Windows reboot requires explicit authorization.' $null
        }
        try {
            Restart-Computer -Force -ErrorAction Stop
            return $true
        } catch {
            & $throwAcceptanceError 'CCOD_ACCEPTANCE_REBOOT_FAILED' 'The authorized Windows reboot could not be initiated.' $null
        }
    }.GetNewClosure()
    return $defaults
}

function Resolve-CcodOfficialDraftAdapters {
    param([hashtable]$Adapters)
    $resolved = Get-CcodOfficialDraftDefaultAdapters
    if ($null -eq $Adapters) { return $resolved }
    foreach ($name in $Adapters.Keys) {
        if (-not $resolved.ContainsKey([string]$name) -or $Adapters[$name] -isnot [scriptblock]) {
            Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_ADAPTER_INVALID' 'Private acceptance adapters must replace known scriptblock operations only.' $null
        }
        $resolved[[string]$name] = $Adapters[$name]
    }
    return $resolved
}

function Assert-CcodOfficialDraftPhaseState {
    param([Parameter(Mandatory)][string]$Phase, [Parameter(Mandatory)]$Records, [Parameter(Mandatory)]$Candidate, [Parameter(Mandatory)]$Draft,[switch]$AllowExistingComplete)
    $manualValues = @()
    if ($Records.ContainsKey('ManualEvidence') -and $null -ne $Records['ManualEvidence']) {
        $manualValues = @($Records['ManualEvidence'].Values)
        if ($null -eq $manualValues) { $manualValues = @() }
    }
    if ($Phase -notin @('TrayEvidence','RemoteEvidence','Complete') -and $manualValues.Count -gt 0) {
        Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_MANUAL_EVIDENCE_EARLY' 'Manual evidence cannot exist before ReadyForManualEvidence.' $null
    }
    if ($Phase -in @('TrayEvidence','RemoteEvidence','Complete')) {
        foreach ($automatedPhase in $script:CcodOfficialDraftPhases) {
            if (-not $Records.ContainsKey($automatedPhase)) {
                Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_PHASE_ORDER_INVALID' 'Manual evidence requires all automated acceptance phases first.' $null
            }
            if (-not (Test-CcodOfficialDraftCandidateEqual -Left $Candidate -Right $Records[$automatedPhase].candidate)) {
                Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_CANDIDATE_CHANGED' 'The official-draft candidate changed before manual evidence.' $null
            }
            if (-not (Test-CcodOfficialDraftDraftEqual -Left $Draft -Right $Records[$automatedPhase].draft)) {
                Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_DRAFT_IDENTITY_CHANGED' 'The official-draft identity changed before manual evidence.' $null
            }
        }
        if ($Records.ContainsKey('Complete') -and -not ($Phase -ceq 'Complete' -and $AllowExistingComplete)) {
            Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_PHASE_REUSED' 'Complete acceptance evidence cannot be reused.' $null
        }
        return
    }
    $index = [array]::IndexOf([string[]]$script:CcodOfficialDraftPhases,$Phase)
    if ($index -lt 0) { Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_PHASE_INVALID' 'The official-draft acceptance phase is unsupported.' $null }
    if ($Records.ContainsKey('Complete')) {
        Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_PHASE_REUSED' 'Automated acceptance cannot continue after Complete evidence.' $null
    }
    for ($prior = 0; $prior -lt $index; $prior++) {
        $name = $script:CcodOfficialDraftPhases[$prior]
        if (-not $Records.ContainsKey($name)) { Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_PHASE_ORDER_INVALID' 'Official-draft acceptance phases must be completed in order.' $null }
        if (-not (Test-CcodOfficialDraftCandidateEqual -Left $Candidate -Right $Records[$name].candidate)) {
            Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_CANDIDATE_CHANGED' 'The official-draft candidate changed during acceptance.' $null
        }
        if (-not (Test-CcodOfficialDraftDraftEqual -Left $Draft -Right $Records[$name].draft)) {
            Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_DRAFT_IDENTITY_CHANGED' 'The official-draft identity changed during acceptance.' $null
        }
    }
    for ($later = $index; $later -lt $script:CcodOfficialDraftPhases.Count; $later++) {
        if ($Records.ContainsKey($script:CcodOfficialDraftPhases[$later])) {
            Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_PHASE_REUSED' 'An official-draft acceptance phase cannot be reused or skipped.' $null
        }
    }
}

function Assert-CcodOfficialDraftPhaseAuthorization {
    param(
        [Parameter(Mandatory)][string]$Phase,
        [switch]$AllowMachineMutation,
        [switch]$AllowCodexRestart,
        [switch]$AllowWindowsReboot
    )
    if ($Phase -in @('LegacyUpgrade','Uninstall','FreshInstall','PreReboot','PostReboot')) {
        if (-not $AllowMachineMutation) {
            Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_MACHINE_MUTATION_NOT_ALLOWED' 'This official-draft phase requires explicit machine-mutation authorization.' $null
        }
        if (-not $AllowCodexRestart) {
            Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_CODEX_RESTART_NOT_ALLOWED' 'This official-draft phase requires explicit Codex-restart authorization.' $null
        }
    }
    if ($Phase -in @('PreReboot','PostReboot') -and -not $AllowWindowsReboot) {
        Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_WINDOWS_REBOOT_NOT_ALLOWED' 'This official-draft phase requires explicit Windows-reboot authorization.' $null
    }
}

function ConvertTo-CcodOfficialDraftPreviousSetup {
    param([Parameter(Mandatory)]$Value)
    try {
        if ($null -eq $Value -or $Value.Valid -isnot [bool] -or -not [bool]$Value.Valid -or
            $Value.Version -isnot [string] -or $Value.Version -cne '2.5.21' -or
            $Value.InstallerName -isnot [string] -or $Value.InstallerName -cne 'CodexRemote-fix-2.5.21-setup.exe' -or
            -not (Test-CcodOfficialDraftCommit $Value.GitCommit) -or
            -not (Test-CcodOfficialDraftHash $Value.InstallerSha256) -or
            -not (Test-CcodOfficialDraftHash $Value.ManifestSha256)) { throw 'previous setup' }
        return [pscustomobject][ordered]@{
            version = '2.5.21'
            gitCommit = [string]$Value.GitCommit
            assetSha256 = [string]$Value.InstallerSha256
            manifestSha256 = [string]$Value.ManifestSha256
        }
    } catch {
        Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_PREVIOUS_ASSET_INVALID' 'The previous public v2.5.21 Setup is not manifest-bound.' $null
    }
}

function Get-CcodOfficialDraftFactValue {
    param([Parameter(Mandatory)]$Facts, [Parameter(Mandatory)][string]$Name)
    if ($Facts -is [Collections.IDictionary]) {
        if (-not $Facts.Contains($Name)) { return $null }
        return $Facts[$Name]
    }
    $property = $Facts.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-CcodOfficialDraftObservedKeyHash {
    param([Parameter(Mandatory)]$Facts)
    try {
        $present = Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'deviceKeyPresent'
        $hash = Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'deviceKeySha256'
        if ($present -isnot [bool] -or -not [bool]$present -or -not (Test-CcodOfficialDraftHash $hash)) { throw 'key' }
        return [string]$hash
    } catch {
        Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_KEY_OBSERVATION_INVALID' 'The DPAPI device-key observation is missing or malformed.' $null
    }
}

function Invoke-CcodOfficialDraftPhaseOperation {
    param([Parameter(Mandatory)]$Adapters, [Parameter(Mandatory)]$Context)
    try {
        $values = @(& $Adapters.RunPhase $Context)
        if ($values.Count -ne 1 -or $null -eq $values[0]) { throw 'operation result' }
        $result = $values[0]
        if (-not (Test-CcodOfficialDraftExactProperties -Value $result -Expected @('completed','outcome','installerSha256','runtimeManifestSha256')) -or
            $result.installerSha256 -isnot [string] -or -not (Test-CcodOfficialDraftHash $result.installerSha256) -or
            ($null -ne $result.runtimeManifestSha256 -and ($result.runtimeManifestSha256 -isnot [string] -or -not (Test-CcodOfficialDraftHash $result.runtimeManifestSha256)))) { throw 'operation binding' }
        $setupName = [IO.Path]::GetFileName([string]$Context.setupPath)
        $expectedInstallerHash = Get-CcodOfficialDraftAssetHash -Candidate $Context.candidate -Name $setupName
        if (-not (Test-CcodOfficialDraftHash $expectedInstallerHash) -or $result.installerSha256 -cne $expectedInstallerHash) { throw 'operation candidate binding' }
        $completed = $false
        $outcomeCompleted = $false
        $hasCompletion = $false
        $property = $result.PSObject.Properties['completed']
        if ($null -ne $property) {
            if ($property.Value -isnot [bool]) { throw 'completed type' }
            $completed = [bool]$property.Value
            $hasCompletion = $true
        }
        $property = $result.PSObject.Properties['outcome']
        if ($null -ne $property) {
            if ($property.Value -isnot [string]) { throw 'outcome type' }
            if ([string]$property.Value -cne 'Completed') { throw 'outcome' }
            $outcomeCompleted = $true
            $hasCompletion = $true
        }
        if (-not $hasCompletion -or -not $completed -or -not $outcomeCompleted) { throw 'operation result' }
        return $result
    } catch {
        if ($_.FullyQualifiedErrorId -like 'CCOD_ACCEPTANCE_*') { throw }
        Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_MACHINE_OPERATION_FAILED' 'The official-draft machine operation did not return proven completion.' $null
    }
}

function New-CcodOfficialDraftContext {
    param(
        [Parameter(Mandatory)][string]$Phase,
        [Parameter(Mandatory)][string]$AssetDirectory,
        [Parameter(Mandatory)][string]$PreviousAssetDirectory,
        [Parameter(Mandatory)][string]$EvidenceRoot,
        [Parameter(Mandatory)]$Candidate,
        [Parameter(Mandatory)]$Draft,
        [Parameter(Mandatory)]$PreviousSetup,
        [switch]$AllowMachineMutation,
        [switch]$AllowCodexRestart,
        [switch]$AllowWindowsReboot
    )
    $names = @(Get-CcodOfficialDraftExpectedAssetNames)
    return [pscustomobject][ordered]@{
        phase = $Phase
        assetDirectory = [IO.Path]::GetFullPath($AssetDirectory)
        previousAssetDirectory = [IO.Path]::GetFullPath($PreviousAssetDirectory)
        evidenceRoot = [IO.Path]::GetFullPath($EvidenceRoot)
        installRoot = [IO.Path]::GetFullPath((Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'CodexControlOtherDevices'))
        expectedVersion = [string]$Candidate.version
        setupPath = [IO.Path]::GetFullPath((Join-Path $AssetDirectory $names[5]))
        portablePath = [IO.Path]::GetFullPath((Join-Path $AssetDirectory $names[0]))
        previousSetupPath = [IO.Path]::GetFullPath((Join-Path $PreviousAssetDirectory 'CodexRemote-fix-2.5.21-setup.exe'))
        previousSetupVersion = [string]$PreviousSetup.version
        previousSetupSha256 = [string]$PreviousSetup.assetSha256
        previousManifestSha256 = [string]$PreviousSetup.manifestSha256
        candidate = $Candidate
        draft = $Draft
        previousSetup = $PreviousSetup
        allowMachineMutation = [bool]$AllowMachineMutation
        allowCodexRestart = [bool]$AllowCodexRestart
        allowWindowsReboot = [bool]$AllowWindowsReboot
    }
}

function ConvertTo-CcodOfficialDraftLegacyFacts {
    param([Parameter(Mandatory)]$PreviousSetup,[Parameter(Mandatory)]$BeforeObservation,[Parameter(Mandatory)]$AfterObservation,[Parameter(Mandatory)][string]$BeforeHash,[Parameter(Mandatory)][string]$AfterHash)
    return [pscustomobject][ordered]@{
        previousSetup = $PreviousSetup
        before = $BeforeObservation
        after = $AfterObservation
        deviceKeySha256Before = $BeforeHash
        deviceKeySha256After = $AfterHash
        keyHashPreserved = $true
        operationOutcome = 'Completed'
    }
}

function Test-CcodOfficialDraftHasFact {
    param([Parameter(Mandatory)]$Facts, [Parameter(Mandatory)][string]$Name)
    if ($Facts -is [Collections.IDictionary]) { return $Facts.Contains($Name) }
    return $null -ne $Facts.PSObject.Properties[$Name]
}

function Assert-CcodOfficialDraftUninstallFacts {
    param([Parameter(Mandatory)]$Facts, [Parameter(Mandatory)][string]$ExpectedKeyHash)
    try {
        foreach ($name in @('installRootPresent','appRootPresent','runtimeRootPresent','activePointerPresent','taskState','supervisor','trayHost','codex','shortcuts','debugEndpoints')) {
            if (-not (Test-CcodOfficialDraftHasFact -Facts $Facts -Name $name)) { throw 'missing fact' }
        }
        foreach ($name in @('appRootPresent','runtimeRootPresent','activePointerPresent')) {
            $value = Get-CcodOfficialDraftFactValue -Facts $Facts -Name $name
            if ($value -isnot [bool] -or [bool]$value) { throw 'owned state remains' }
        }
        $rootValue = Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'installRootPresent'
        if ($rootValue -isnot [bool] -or [bool]$rootValue) { throw 'install root remains' }
        if ((Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'taskState') -isnot [string] -or
            (Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'taskState') -cne 'Absent') { throw 'task' }
        if (@(Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'supervisor').Count -ne 0 -or
            @(Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'trayHost').Count -ne 0 -or
            @(Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'codex').Count -ne 0 -or
            @(Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'debugEndpoints').Count -ne 0) { throw 'process or endpoint remains' }
        $shortcuts = Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'shortcuts'
        if (-not (Test-CcodOfficialDraftExactProperties -Value $shortcuts -Expected @('startMenu','desktop')) -or
            $shortcuts.startMenu -isnot [bool] -or [bool]$shortcuts.startMenu -or
            $shortcuts.desktop -isnot [bool] -or [bool]$shortcuts.desktop) { throw 'shortcuts' }
        $afterHash = Get-CcodOfficialDraftObservedKeyHash -Facts $Facts
        if ($afterHash -cne $ExpectedKeyHash) { throw 'key' }
        return $afterHash
    } catch {
        if ($_.FullyQualifiedErrorId -like 'CCOD_ACCEPTANCE_*') { throw }
        Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_UNINSTALL_OBSERVATION_INVALID' 'Uninstall did not prove complete owned-state removal.' $null
    }
}

function ConvertTo-CcodOfficialDraftUninstallFacts {
    param([Parameter(Mandatory)]$Facts,[Parameter(Mandatory)][string]$BeforeHash,[Parameter(Mandatory)][string]$AfterHash)
    return [pscustomobject][ordered]@{
        stateRemoved = $true
        installRootPresent = $false
        appRootPresent = $false
        runtimeRootPresent = $false
        activePointerPresent = $false
        taskState = 'Absent'
        supervisorCount = 0
        trayHostCount = 0
        codexCount = 0
        shortcuts = [pscustomobject][ordered]@{ startMenu = $false; desktop = $false }
        debugEndpointsGone = $true
        deviceKeySha256Before = $BeforeHash
        deviceKeySha256After = $AfterHash
        keyHashPreserved = $true
        operationOutcome = 'Completed'
    }
}

function ConvertTo-CcodOfficialDraftTerminalReceipt {
    param([Parameter(Mandatory)]$Receipt)
    try {
        if (-not (Test-CcodOfficialDraftExactProperties -Value $Receipt -Expected @('kind','origin','runtimeId','runtimeGeneration','phase')) -or
            $Receipt.kind -isnot [string] -or $Receipt.kind -cne 'RestartAndRepair' -or
            $Receipt.origin -isnot [string] -or $Receipt.origin -cne 'Installer' -or
            $Receipt.runtimeId -isnot [string] -or $Receipt.runtimeId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,95}\z' -or
            -not (Test-CcodOfficialDraftPositiveInteger $Receipt.runtimeGeneration) -or
            $Receipt.phase -isnot [string] -or $Receipt.phase -cne 'Completed') { throw 'terminal receipt' }
        return [pscustomobject][ordered]@{
            kind = 'RestartAndRepair'
            origin = 'Installer'
            runtimeId = [string]$Receipt.runtimeId
            runtimeGeneration = [UInt64]$Receipt.runtimeGeneration
            phase = 'Completed'
        }
    } catch {
        if ($_.FullyQualifiedErrorId -like 'CCOD_ACCEPTANCE_*') { throw }
        Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_FRESH_INSTALL_OBSERVATION_INVALID' 'Fresh install did not expose a valid terminal lifecycle receipt.' $null
    }
}

function Assert-CcodOfficialDraftFreshFacts {
    param([Parameter(Mandatory)]$Facts,[Parameter(Mandatory)][string]$ExpectedKeyHash,[string]$ExpectedRuntimeManifestSha256)
    try {
        foreach ($name in @('installRootPresent','appRootPresent','runtimeRootPresent','activePointerPresent','activeRuntimeId','activeGeneration','runtimeManifestSha256','supervisor','trayHost','codex','codexCount','statusCodex','trayAuthenticated','taskState','lifecycleReceipt','protectionReady')) {
            if (-not (Test-CcodOfficialDraftHasFact -Facts $Facts -Name $name)) { throw 'missing fact' }
        }
        foreach ($name in @('installRootPresent','appRootPresent','runtimeRootPresent','activePointerPresent','trayAuthenticated','protectionReady')) {
            $value = Get-CcodOfficialDraftFactValue -Facts $Facts -Name $name
            if ($value -isnot [bool] -or -not [bool]$value) { throw 'readiness flag' }
        }
        $runtimeId = Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'activeRuntimeId'
        $generation = Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'activeGeneration'
        $manifestHash = Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'runtimeManifestSha256'
        if ($runtimeId -isnot [string] -or $runtimeId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,95}\z' -or
            -not (Test-CcodOfficialDraftPositiveInteger $generation) -or
            -not (Test-CcodOfficialDraftHash $manifestHash) -or
            ($null -ne $ExpectedRuntimeManifestSha256 -and ($manifestHash -cne $ExpectedRuntimeManifestSha256))) { throw 'active generation' }
        if ((Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'taskState') -isnot [string] -or
            (Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'taskState') -notin @('Ready','Running')) { throw 'task' }
        $codex = @(Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'codex')
        $statusCodex = Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'statusCodex'
        if (@(Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'supervisor').Count -ne 1 -or
            @(Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'trayHost').Count -ne 1 -or
            -not (Test-CcodOfficialDraftInt32 (Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'codexCount')) -or
            [int](Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'codexCount') -ne 1 -or $codex.Count -ne 1 -or $null -eq $statusCodex) { throw 'process count' }
        $codexIdentity = ConvertTo-CcodOfficialDraftSafeProcessIdentity -Value $codex[0] -Label 'fresh codex'
        $statusCodexIdentity = ConvertTo-CcodOfficialDraftSafeProcessIdentity -Value $statusCodex -Label 'fresh status codex'
        if ($codexIdentity.pid -ne $statusCodexIdentity.pid -or $codexIdentity.creationTimeUtc -cne $statusCodexIdentity.creationTimeUtc) { throw 'codex identity binding' }
        $trayIdentity = ConvertTo-CcodOfficialDraftTrayHostIdentity -Value (Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'trayHostIdentity')
        $observedTrayIdentity = ConvertTo-CcodOfficialDraftTrayHostIdentity -Value (Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'trayHost')[0]
        if ($trayIdentity.pid -ne $observedTrayIdentity.pid -or $trayIdentity.creationTimeUtc -cne $observedTrayIdentity.creationTimeUtc) { throw 'tray identity binding' }
        $terminal = ConvertTo-CcodOfficialDraftTerminalReceipt -Receipt (Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'lifecycleReceipt')
        if ($terminal.runtimeId -cne $runtimeId -or [UInt64]$terminal.runtimeGeneration -ne [UInt64]$generation) { throw 'receipt binding' }
        $keyHash = Get-CcodOfficialDraftObservedKeyHash -Facts $Facts
        if ($keyHash -cne $ExpectedKeyHash) { throw 'key' }
        return [pscustomobject][ordered]@{
            installRootPresent = $true
            installReady = $true
            activePointerPresent = $true
            activeRuntimeId = [string]$runtimeId
            activeGeneration = [UInt64]$generation
            runtimeManifestSha256 = [string]$manifestHash
            supervisorCount = 1
            trayHostCount = 1
            codexCount = 1
            trayHostIdentity = $trayIdentity
            trayAuthenticated = $true
            taskState = [string](Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'taskState')
            terminalReceipt = $terminal
            protectionReady = $true
            deviceKeySha256 = $keyHash
            operationOutcome = 'Completed'
        }
    } catch {
        if ($_.FullyQualifiedErrorId -like 'CCOD_ACCEPTANCE_*') { throw }
        Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_FRESH_INSTALL_OBSERVATION_INVALID' 'Fresh install did not prove an active generation and authenticated protection.' $null
    }
}

function Get-CcodOfficialDraftFileSha256 {
    param([Parameter(Mandatory)][string]$Path,[string]$ErrorId='CCOD_ACCEPTANCE_RECEIPT_INVALID',[string]$Message='The acceptance receipt could not be hashed safely.')
    try {
        $full = Assert-CcodOfficialDraftRegularFile -Path $Path -ErrorId $ErrorId
        $sha = [Security.Cryptography.SHA256]::Create()
        $stream = [IO.File]::OpenRead($full)
        try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant() }
        finally { $stream.Dispose(); $sha.Dispose() }
    } catch {
        if ($_.FullyQualifiedErrorId -like 'CCOD_ACCEPTANCE_*') { throw }
        Throw-CcodOfficialDraftError $ErrorId $Message $null
    }
}

function Write-CcodOfficialDraftJsonCreateOnly {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)]$Record,[Parameter(Mandatory)][string]$ErrorId,[scriptblock]$Readback,[ref]$PublishedHash,[scriptblock]$BeforeTemporaryOpen)
    $temporary = $null
    $full = $null
    $published = $false
    $expectedHash = $null
    try {
        $full = [IO.Path]::GetFullPath($Path)
        $parent = [IO.Directory]::GetParent($full)
        if ($null -eq $parent) { throw 'parent' }
        [void](Assert-CcodOfficialDraftSafeDirectory -Path $parent.FullName -ErrorId $ErrorId)
        $existing = $null
        try { $existing = Get-Item -LiteralPath $full -Force -ErrorAction Stop } catch { if (-not (Test-CcodOfficialDraftMissingError -ErrorRecord $_)) { throw } }
        if ($null -ne $existing) { throw 'exists' }
        $temporary = Join-Path $parent.FullName ('.manual-' + [guid]::NewGuid().ToString('N') + '.tmp')
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($Record | ConvertTo-Json -Depth 16))
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $expectedHash = ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
        if ($null -ne $BeforeTemporaryOpen) { & $BeforeTemporaryOpen $temporary }
        $stream = [IO.File]::Open($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
        try { $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        [IO.File]::Move($temporary,$full)
        $published = $true
        if ($null -ne $PublishedHash) { $PublishedHash.Value = $expectedHash }
        $targetItem = Get-Item -LiteralPath $full -Force -ErrorAction Stop
        if ($targetItem -isnot [IO.FileInfo] -or ($targetItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'readback target' }
        if ($null -ne $Readback -and -not [bool](& $Readback $full)) { throw 'readback verifier' }
        $readbackObject = [IO.File]::ReadAllText($full,[Text.UTF8Encoding]::new($false,$true)) | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $readbackObject -or (Get-CcodOfficialDraftFileSha256 -Path $full) -cne $expectedHash) { throw 'readback semantic mismatch' }
        if ($null -ne $PublishedHash) { $PublishedHash.Value = $expectedHash }
        return $full
    } catch {
        $failure = $_
        if ($null -ne $temporary) {
            try {
                $tempItems = @()
                try { $tempItems = @(Get-Item -LiteralPath $temporary -Force -ErrorAction Stop) } catch { if (-not (Test-CcodOfficialDraftMissingError -ErrorRecord $_)) { throw } }
                if ($tempItems.Count -gt 0) {
                    if ($tempItems.Count -ne 1 -or $tempItems[0] -isnot [IO.FileInfo] -or
                        ($tempItems[0].Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                        $expectedHash -isnot [string] -or $expectedHash -notmatch '^[0-9a-f]{64}\z' -or
                        (Get-CcodOfficialDraftFileSha256 -Path $temporary) -cne $expectedHash) { throw 'temporary cleanup target' }
                    Remove-Item -LiteralPath $temporary -Force -ErrorAction Stop
                }
                $residual = $null
                try { $residual = @(Get-Item -LiteralPath $temporary -Force -ErrorAction Stop) } catch { if (-not (Test-CcodOfficialDraftMissingError -ErrorRecord $_)) { throw } }
                if ($null -ne $residual -and @($residual).Count -gt 0) { throw 'temporary cleanup residue' }
            } catch { Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_MANUAL_EVIDENCE_CLEANUP_FAILED' 'Temporary manual receipt cleanup could not be proven.' $temporary }
        }
        if ($published) {
            try {
                $item = $null
                try { $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop } catch { if (-not (Test-CcodOfficialDraftMissingError -ErrorRecord $_)) { throw } }
                if ($null -ne $item) {
                    if ($item -isnot [IO.FileInfo] -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                        ($null -ne $expectedHash -and (Get-CcodOfficialDraftFileSha256 -Path $full) -cne $expectedHash)) { throw 'readback cleanup target' }
                    Remove-Item -LiteralPath $full -Force -ErrorAction Stop
                }
                $residual = $null
                try { $residual = Get-Item -LiteralPath $full -Force -ErrorAction Stop } catch { if (-not (Test-CcodOfficialDraftMissingError -ErrorRecord $_)) { throw } }
                if ($null -ne $residual) { throw 'readback cleanup residue' }
            } catch {
                Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_MANUAL_EVIDENCE_CLEANUP_FAILED' 'Receipt destination cleanup could not be proven after a failed readback.' $full
            }
        }
        if ($failure.FullyQualifiedErrorId -like 'CCOD_ACCEPTANCE_*') { throw $failure }
        Throw-CcodOfficialDraftError $ErrorId 'Manual acceptance evidence could not be written durably.' $full
    }
}

function Remove-CcodOfficialDraftCompleteArtifacts {
    param([Parameter(Mandatory)][string[]]$Paths,[Parameter(Mandatory)][hashtable]$ExpectedHashes,[scriptblock]$RemovePath)
    $failures = [Collections.Generic.List[string]]::new()
    foreach ($path in $Paths) {
        $full = [IO.Path]::GetFullPath($path)
        try {
            $hasExpected = $ExpectedHashes.ContainsKey($full)
            $expected = $null
            if ($hasExpected) { $expected = [string]$ExpectedHashes[$full] }
            $items = @(Get-Item -LiteralPath $full -Force -ErrorAction Stop)
            if ($items.Count -ne 1 -or $items[0] -isnot [IO.FileInfo] -or
                ($items[0].Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                -not $hasExpected -or $expected -notmatch '^[0-9a-f]{64}\z' -or (Get-CcodOfficialDraftFileSha256 -Path $full) -cne $expected) { throw 'cleanup target' }
            if ($null -eq $RemovePath) { Remove-Item -LiteralPath $full -Force -ErrorAction Stop }
            else { & $RemovePath $full }
            try {
                @(Get-Item -LiteralPath $full -Force -ErrorAction Stop) | Out-Null
                [void]$failures.Add($full)
            } catch {
                $missing = $_.CategoryInfo.Category -eq 'ObjectNotFound' -or
                    $_.Exception -is [IO.FileNotFoundException] -or $_.Exception -is [IO.DirectoryNotFoundException]
                if (-not $missing) { [void]$failures.Add($full) }
            }
        } catch {
            $missing = $_.CategoryInfo.Category -eq 'ObjectNotFound' -or
                $_.Exception -is [IO.FileNotFoundException] -or $_.Exception -is [IO.DirectoryNotFoundException]
            if ($missing) {
                try {
                    [void](Assert-CcodOfficialDraftMissingPathAncestorsSafe -Path $full -GetItem { param($CandidatePath) Get-Item -LiteralPath $CandidatePath -Force -ErrorAction Stop } -ErrorId 'CCOD_ACCEPTANCE_COMPLETE_CLEANUP_FAILED')
                } catch { [void]$failures.Add($full) }
            } else { [void]$failures.Add($full) }
        }
    }
    if ($failures.Count -gt 0) {
        Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_COMPLETE_CLEANUP_FAILED' 'Complete acceptance cleanup could not prove terminal artifacts were removed.' ($failures -join ';')
    }
    return $true
}

function Assert-CcodOfficialDraftEvidenceHashesStable {
    param(
        [Parameter(Mandatory)][string]$ScreenshotPath,
        [Parameter(Mandatory)][string]$RedactedLogPath,
        [Parameter(Mandatory)][string]$ExpectedScreenshotSha256,
        [Parameter(Mandatory)][string]$ExpectedRedactedLogSha256
    )
    try {
        if (-not (Test-CcodOfficialDraftHash $ExpectedScreenshotSha256) -or
            -not (Test-CcodOfficialDraftHash $ExpectedRedactedLogSha256)) { throw 'expected evidence hashes' }
        [void](Assert-CcodOfficialDraftRegularEvidenceFile -Path $ScreenshotPath)
        [void](Assert-CcodOfficialDraftRegularEvidenceFile -Path $RedactedLogPath)
        $screenshotHash = Get-CcodOfficialDraftFileSha256 -Path $ScreenshotPath -ErrorId 'CCOD_ACCEPTANCE_MANUAL_EVIDENCE_INVALID' -Message 'Manual screenshot could not be hashed safely.'
        $redactedLogHash = Get-CcodOfficialDraftFileSha256 -Path $RedactedLogPath -ErrorId 'CCOD_ACCEPTANCE_MANUAL_EVIDENCE_INVALID' -Message 'Manual redacted log could not be hashed safely.'
        if ($screenshotHash -cne $ExpectedScreenshotSha256 -or $redactedLogHash -cne $ExpectedRedactedLogSha256) { throw 'evidence changed' }
        return [pscustomobject][ordered]@{ screenshotSha256 = $screenshotHash; redactedLogSha256 = $redactedLogHash }
    } catch {
        if ($_.FullyQualifiedErrorId -like 'CCOD_ACCEPTANCE_*') { throw }
        Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_MANUAL_EVIDENCE_INVALID' 'Manual evidence changed after operation proof.' $null
    }
}

function Get-CcodOfficialDraftManualArtifactPaths {
    param([Parameter(Mandatory)][string]$ArtifactDirectory,[Parameter(Mandatory)][string]$Operation,[switch]$Create)
    try {
        $root = [IO.Path]::GetFullPath($ArtifactDirectory)
        $parent = [IO.Directory]::GetParent($root)
        if ($null -eq $parent) { throw 'artifact parent' }
        [void](Assert-CcodOfficialDraftSafeDirectory -Path $parent.FullName -ErrorId 'CCOD_ACCEPTANCE_MANUAL_EVIDENCE_INVALID')
        $rootItem = $null
        try { $rootItem = Get-Item -LiteralPath $root -Force -ErrorAction Stop } catch { if (-not (Test-CcodOfficialDraftMissingError -ErrorRecord $_)) { throw } }
        if ($null -ne $rootItem -and -not $rootItem.PSIsContainer) { throw 'artifact root file' }
        if ($null -eq $rootItem) {
            if (-not $Create) { throw 'artifact root missing' }
            [IO.Directory]::CreateDirectory($root) | Out-Null
        }
        [void](Assert-CcodOfficialDraftSafeDirectory -Path $root -ErrorId 'CCOD_ACCEPTANCE_MANUAL_EVIDENCE_INVALID')
        $operationDirectory = Join-Path $root $Operation
        $operationItem = $null
        try { $operationItem = Get-Item -LiteralPath $operationDirectory -Force -ErrorAction Stop } catch { if (-not (Test-CcodOfficialDraftMissingError -ErrorRecord $_)) { throw } }
        if ($null -ne $operationItem -and -not $operationItem.PSIsContainer) { throw 'artifact operation file' }
        if ($null -eq $operationItem) {
            if (-not $Create) { throw 'artifact operation missing' }
            [IO.Directory]::CreateDirectory($operationDirectory) | Out-Null
        }
        [void](Assert-CcodOfficialDraftSafeDirectory -Path $operationDirectory -ErrorId 'CCOD_ACCEPTANCE_MANUAL_EVIDENCE_INVALID')
        return [pscustomobject][ordered]@{
            Directory = $operationDirectory
            Screenshot = Join-Path $operationDirectory 'screenshot.bin'
            RedactedLog = Join-Path $operationDirectory 'redacted.log'
        }
    } catch {
        if ($_.FullyQualifiedErrorId -like 'CCOD_ACCEPTANCE_*') { throw }
        Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_MANUAL_EVIDENCE_INVALID' 'Manual artifact directory is missing, reused, or unsafe.' $ArtifactDirectory
    }
}

function Write-CcodOfficialDraftManualArtifacts {
    param(
        [Parameter(Mandatory)][string]$ArtifactDirectory,
        [Parameter(Mandatory)][string]$Operation,
        [Parameter(Mandatory)][string]$ScreenshotPath,
        [Parameter(Mandatory)][string]$RedactedLogPath,
        [Parameter(Mandatory)][string]$ExpectedScreenshotSha256,
        [Parameter(Mandatory)][string]$ExpectedRedactedLogSha256
    )
    $paths = $null
    $created = [Collections.Generic.List[string]]::new()
    $temporary = [Collections.Generic.List[string]]::new()
    $temporaryHashes = @{}
    $createdHashes = @{}
    try {
        $paths = Get-CcodOfficialDraftManualArtifactPaths -ArtifactDirectory $ArtifactDirectory -Operation $Operation -Create
        foreach ($target in @($paths.Screenshot,$paths.RedactedLog)) {
            $targetItem = $null
            try { $targetItem = Get-Item -LiteralPath $target -Force -ErrorAction Stop } catch { if (-not (Test-CcodOfficialDraftMissingError -ErrorRecord $_)) { throw } }
            if ($null -ne $targetItem) { throw 'artifact reused' }
        }
        foreach ($pair in @(
            [pscustomobject]@{ Source = $ScreenshotPath; Target = $paths.Screenshot; ExpectedHash = $ExpectedScreenshotSha256 }
            [pscustomobject]@{ Source = $RedactedLogPath; Target = $paths.RedactedLog; ExpectedHash = $ExpectedRedactedLogSha256 }
        )) {
            $temporaryPath = Join-Path $paths.Directory ('.manual-artifact-' + [guid]::NewGuid().ToString('N') + '.tmp')
            $temporary.Add($temporaryPath)
            [IO.File]::Copy((Assert-CcodOfficialDraftRegularEvidenceFile -Path $pair.Source), $temporaryPath, $false)
            [void](Assert-CcodOfficialDraftRegularEvidenceFile -Path $temporaryPath)
            $temporaryHash = Get-CcodOfficialDraftFileSha256 -Path $temporaryPath -ErrorId 'CCOD_ACCEPTANCE_MANUAL_EVIDENCE_INVALID' -Message 'Temporary manual artifact could not be hashed safely.'
            $temporaryHashes[[IO.Path]::GetFullPath($temporaryPath)] = $temporaryHash
            if ($temporaryHash -cne $pair.ExpectedHash) { throw 'artifact hash mismatch' }
            [IO.File]::Move($temporaryPath, $pair.Target)
            [void]$temporary.Remove($temporaryPath)
            $created.Add($pair.Target)
            $createdHashes[[IO.Path]::GetFullPath($pair.Target)] = $temporaryHash
        }
        [void](Assert-CcodOfficialDraftRegularEvidenceFile -Path $paths.Screenshot)
        [void](Assert-CcodOfficialDraftRegularEvidenceFile -Path $paths.RedactedLog)
        $screenshotHash = Get-CcodOfficialDraftFileSha256 -Path $paths.Screenshot -ErrorId 'CCOD_ACCEPTANCE_MANUAL_EVIDENCE_INVALID' -Message 'Published manual screenshot could not be hashed safely.'
        $redactedLogHash = Get-CcodOfficialDraftFileSha256 -Path $paths.RedactedLog -ErrorId 'CCOD_ACCEPTANCE_MANUAL_EVIDENCE_INVALID' -Message 'Published manual redacted log could not be hashed safely.'
        if ($screenshotHash -cne $ExpectedScreenshotSha256 -or $redactedLogHash -cne $ExpectedRedactedLogSha256) { throw 'artifact hash mismatch' }
        return $paths
    } catch {
        if ($temporary.Count -gt 0) {
            try { [void](Remove-CcodOfficialDraftCompleteArtifacts -Paths @($temporary) -ExpectedHashes $temporaryHashes) }
            catch { Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_MANUAL_EVIDENCE_CLEANUP_FAILED' 'Temporary manual artifact cleanup could not prove removal.' ($temporary -join ';') }
        }
        if ($created.Count -gt 0) {
            try { [void](Remove-CcodOfficialDraftCompleteArtifacts -Paths @($created) -ExpectedHashes $createdHashes) }
            catch { Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_MANUAL_EVIDENCE_CLEANUP_FAILED' 'Manual artifact cleanup could not prove removal after a failed evidence write.' ($created -join ';') }
        }
        if ($_.FullyQualifiedErrorId -like 'CCOD_ACCEPTANCE_*') { throw }
        Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_MANUAL_EVIDENCE_INVALID' 'Manual evidence artifacts could not be copied and verified.' $ArtifactDirectory
    }
}

function Write-CcodOfficialDraftManualEvidence {
    param(
        [Parameter(Mandatory)][string]$StateDirectory,
        [Parameter(Mandatory)][string]$Phase,
        [Parameter(Mandatory)][string]$Operation,
        [Parameter(Mandatory)]$Candidate,
        [Parameter(Mandatory)]$Existing,
        [Parameter(Mandatory)]$ProgrammaticResult,
        [Parameter(Mandatory)][string]$ScreenshotPath,
        [Parameter(Mandatory)][string]$RedactedLogPath,
        [Parameter(Mandatory)][string]$ArtifactDirectory,
        [Parameter(Mandatory)][string]$ReviewState,
        [string]$ExpectedChallenge,
        [string]$ExpectedRuntimeId,
        $ExpectedGeneration,
        [string]$ExpectedManifestSha256
    )
    $artifactPaths = $null
    $receiptPath = $null
    $cleanupHashes = @{}
    try {
        if ($Phase -notin @('TrayEvidence','RemoteEvidence') -or
            -not $script:CcodOfficialDraftManualFiles.ContainsKey($Operation) -or
            ($Phase -ceq 'TrayEvidence' -and $Operation -ceq 'SecondDeviceControl') -or
            ($Phase -ceq 'RemoteEvidence' -and $Operation -cne 'SecondDeviceControl') -or
            $ReviewState -cne 'Reviewed' -or
            -not (Test-CcodOfficialDraftExactProperties -Value $ProgrammaticResult -Expected @('verified','operation','terminalState','code','proof','screenshotSha256','redactedLogSha256')) -or
            $ProgrammaticResult.verified -isnot [bool] -or -not [bool]$ProgrammaticResult.verified -or
            $ProgrammaticResult.operation -isnot [string] -or $ProgrammaticResult.operation -cne $Operation -or
            $ProgrammaticResult.terminalState -isnot [string] -or $ProgrammaticResult.terminalState -cne [string]$script:CcodOfficialDraftManualTerminalStates[$Operation] -or
            $ProgrammaticResult.code -isnot [string] -or $ProgrammaticResult.code -cne [string]$script:CcodOfficialDraftManualResultCodes[$Operation] -or
            $ProgrammaticResult.screenshotSha256 -isnot [string] -or $ProgrammaticResult.redactedLogSha256 -isnot [string]) { throw 'manual input' }
            $proof = $null
            if ($Operation -ceq 'SecondDeviceControl') {
            $proof = ConvertTo-CcodOfficialDraftRemoteProof -Proof $ProgrammaticResult.proof
            if (-not [string]::IsNullOrEmpty([string]$ExpectedChallenge) -and $proof.challenge -cne $ExpectedChallenge -or
            -not [string]::IsNullOrEmpty([string]$ExpectedRuntimeId) -and $proof.runtimeId -cne $ExpectedRuntimeId -or
            $null -ne $ExpectedGeneration -and ([UInt64]$proof.runtimeGeneration -ne [UInt64]$ExpectedGeneration) -or
            -not [string]::IsNullOrEmpty([string]$ExpectedManifestSha256) -and $proof.runtimeManifestSha256 -cne $ExpectedManifestSha256 -or
            $proof.candidateVersion -cne [string]$Candidate.version) { throw 'remote proof binding' }
            } else {
            $proof = ConvertTo-CcodOfficialDraftTrayProof -Proof $ProgrammaticResult.proof -Operation $Operation
            }
            $stableHashes = Assert-CcodOfficialDraftEvidenceHashesStable -ScreenshotPath $ScreenshotPath -RedactedLogPath $RedactedLogPath -ExpectedScreenshotSha256 $ProgrammaticResult.screenshotSha256 -ExpectedRedactedLogSha256 $ProgrammaticResult.redactedLogSha256
        $screenshotHash = [string]$stableHashes.screenshotSha256
        $logHash = [string]$stableHashes.redactedLogSha256
        if ($screenshotHash -ceq $logHash) { throw 'same file' }
        foreach ($record in @($Existing.Values)) {
            if ($null -eq $record) { continue }
            if ([string]$record.operation -ceq $Operation -or
                [string]$record.screenshotSha256 -ceq $screenshotHash -or
                [string]$record.screenshotSha256 -ceq $logHash -or
                [string]$record.redactedLogSha256 -ceq $screenshotHash -or
                [string]$record.redactedLogSha256 -ceq $logHash) { throw 'manual reuse' }
        }
        $artifactPaths = Write-CcodOfficialDraftManualArtifacts -ArtifactDirectory $ArtifactDirectory -Operation $Operation -ScreenshotPath $ScreenshotPath -RedactedLogPath $RedactedLogPath -ExpectedScreenshotSha256 $screenshotHash -ExpectedRedactedLogSha256 $logHash
        $cleanupHashes[[IO.Path]::GetFullPath($artifactPaths.Screenshot)] = $screenshotHash
        $cleanupHashes[[IO.Path]::GetFullPath($artifactPaths.RedactedLog)] = $logHash
        $record = [pscustomobject][ordered]@{
            schemaVersion = 1
            kind = 'manual-evidence'
            phase = $Phase
            operation = $Operation
            terminalState = [string]$ProgrammaticResult.terminalState
            result = [string]$ProgrammaticResult.code
            proof = $proof
            reviewState = 'Reviewed'
            version = [string]$Candidate.version
            gitCommit = [string]$Candidate.gitCommit
            candidateManifestSha256 = [string]$Candidate.manifestHashes.portable
            screenshotSha256 = $screenshotHash
            redactedLogSha256 = $logHash
        }
        $path = Get-CcodOfficialDraftManualEvidencePath -StateDirectory $StateDirectory -Operation $Operation
        $publishedReceiptHash = $null
        $receiptPath = Write-CcodOfficialDraftJsonCreateOnly -Path $path -Record $record -ErrorId 'CCOD_ACCEPTANCE_MANUAL_EVIDENCE_WRITE_FAILED' -PublishedHash ([ref]$publishedReceiptHash)
        $cleanupHashes[[IO.Path]::GetFullPath($receiptPath)] = $publishedReceiptHash
        return (Assert-CcodOfficialDraftManualRecordShape -Record (Read-CcodOfficialDraftJson -Path $receiptPath).Value)
    } catch {
        $failure = $_
        $cleanupPaths = [Collections.Generic.List[string]]::new()
        if ($null -ne $receiptPath) { $cleanupPaths.Add($receiptPath) }
        if ($null -ne $artifactPaths) { $cleanupPaths.Add($artifactPaths.Screenshot); $cleanupPaths.Add($artifactPaths.RedactedLog) }
        if ($cleanupPaths.Count -gt 0) {
            try { [void](Remove-CcodOfficialDraftCompleteArtifacts -Paths @($cleanupPaths) -ExpectedHashes $cleanupHashes) }
            catch { Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_MANUAL_EVIDENCE_CLEANUP_FAILED' 'Manual receipt and artifact cleanup could not prove removal after a failed record write.' ($cleanupPaths -join ';') }
        }
        if ($failure.FullyQualifiedErrorId -like 'CCOD_ACCEPTANCE_*') { throw $failure }
        Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_MANUAL_EVIDENCE_INVALID' 'Manual evidence is missing, reused, unreviewed, or unsafe.' $null
    }
}

function Assert-CcodOfficialDraftManualEvidenceArtifacts {
    param([Parameter(Mandatory)][string]$EvidenceRoot,[Parameter(Mandatory)]$Records)
    try {
        $artifactRoot = Join-Path $EvidenceRoot $script:CcodOfficialDraftManualArtifactRootName
        foreach ($record in @($Records)) {
            $paths = Get-CcodOfficialDraftManualArtifactPaths -ArtifactDirectory $artifactRoot -Operation ([string]$record.operation)
            [void](Assert-CcodOfficialDraftRegularEvidenceFile -Path $paths.Screenshot)
            [void](Assert-CcodOfficialDraftRegularEvidenceFile -Path $paths.RedactedLog)
            $screenshotHash = Get-CcodOfficialDraftFileSha256 -Path $paths.Screenshot -ErrorId 'CCOD_ACCEPTANCE_MANUAL_EVIDENCE_INVALID' -Message 'Persisted manual screenshot could not be hashed safely.'
            $redactedLogHash = Get-CcodOfficialDraftFileSha256 -Path $paths.RedactedLog -ErrorId 'CCOD_ACCEPTANCE_MANUAL_EVIDENCE_INVALID' -Message 'Persisted manual redacted log could not be hashed safely.'
            if ($screenshotHash.ToLowerInvariant() -cne ([string]$record.screenshotSha256).ToLowerInvariant() -or $redactedLogHash.ToLowerInvariant() -cne ([string]$record.redactedLogSha256).ToLowerInvariant()) { throw 'manual artifact hash' }
        }
        return $true
    } catch {
        if ($_.FullyQualifiedErrorId -like 'CCOD_ACCEPTANCE_*') { throw }
        Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_MANUAL_EVIDENCE_INVALID' 'Persisted manual evidence artifacts do not match their recorded hashes.' $EvidenceRoot
    }
}

function Write-CcodOfficialDraftCompleteAcceptance {
    param([Parameter(Mandatory)][string]$EvidenceRoot,[string]$PreviousAssetDirectory,[Parameter(Mandatory)]$Candidate,[Parameter(Mandatory)]$Draft,[Parameter(Mandatory)]$ManualEvidence,[Parameter(Mandatory)]$AutomatedReceiptHashes,[Parameter(Mandatory)][datetime]$CompletedAtUtc,[string]$Path,[ref]$PublishedHash)
    try {
        if ($CompletedAtUtc.Kind -ne [DateTimeKind]::Utc) { throw 'complete clock kind' }
        $stateDirectory = Get-CcodOfficialDraftStateDirectory -EvidenceRoot $EvidenceRoot
        $reloadedRecords = Read-CcodOfficialDraftState -StateDirectory $stateDirectory -PreviousAssetDirectory $PreviousAssetDirectory
        if (-not $reloadedRecords.ContainsKey('Preflight') -or
            -not (Test-CcodOfficialDraftCandidateEqual -Left $Candidate -Right $reloadedRecords['Preflight'].candidate) -or
            -not (Test-CcodOfficialDraftDraftEqual -Left $Draft -Right $reloadedRecords['Preflight'].draft)) {
            throw 'complete chain identity'
        }
        $draftIdentity = ConvertTo-CcodOfficialDraftIdentity -Value $Draft
        $manual = Assert-CcodOfficialDraftManualEvidenceSet -Records $reloadedRecords.ManualEvidence -Candidate $Candidate
        [void](Assert-CcodOfficialDraftManualEvidenceArtifacts -EvidenceRoot $EvidenceRoot -Records $manual)
        $automated = @($AutomatedReceiptHashes)
        if ($automated.Count -ne ($script:CcodOfficialDraftPhases.Count + 1)) { throw 'automated receipt hash count' }
        $normalizedAutomated = [Collections.Generic.List[object]]::new()
        $expectedPhases = @($script:CcodOfficialDraftPhases) + @('Complete')
        for ($index = 0; $index -lt $expectedPhases.Count; $index++) {
            $entry = $automated[$index]
            if ($null -eq $entry -or -not (Test-CcodOfficialDraftExactProperties -Value $entry -Expected @('phase','sha256')) -or
                $entry.phase -isnot [string] -or $entry.phase -cne $expectedPhases[$index] -or
                -not (Test-CcodOfficialDraftHash $entry.sha256)) { throw 'automated receipt hash shape' }
            $leaf = if ($expectedPhases[$index] -ceq 'Complete') { $script:CcodOfficialDraftCompletionFile } else { $script:CcodOfficialDraftPhaseFiles[$expectedPhases[$index]] }
            $statePath = Join-Path $stateDirectory $leaf
            if ((Get-CcodOfficialDraftFileSha256 -Path $statePath) -cne [string]$entry.sha256) { throw 'automated receipt hash binding' }
            $normalizedAutomated.Add([pscustomobject][ordered]@{ phase = $expectedPhases[$index]; sha256 = [string]$entry.sha256 })
        }
        $path = if ([string]::IsNullOrWhiteSpace($Path)) { Get-CcodOfficialDraftCompleteAcceptancePath -EvidenceRoot $EvidenceRoot } else { [IO.Path]::GetFullPath($Path) }
        $existing = $null
        try { $existing = Get-Item -LiteralPath $path -Force -ErrorAction Stop } catch { if (-not (Test-CcodOfficialDraftMissingError -ErrorRecord $_)) { throw } }
        if ($null -ne $existing) {
            Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_PHASE_REUSED' 'The complete acceptance receipt already exists.' $null
        }
        $record = [pscustomobject][ordered]@{
            schemaVersion = 1
            kind = 'official-draft-acceptance'
            version = [string]$Candidate.version
            gitCommit = [string]$Candidate.gitCommit
            draft = $draftIdentity
            candidateManifestSha256 = [string]$Candidate.manifestHashes.portable
            phase = 'Complete'
            completedAtUtc = $CompletedAtUtc.ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture)
            automatedReceiptSha256 = @($normalizedAutomated)
            manualEvidence = @($manual)
        }
        [void](Write-CcodOfficialDraftJsonCreateOnly -Path $path -Record $record -ErrorId 'CCOD_ACCEPTANCE_COMPLETE_WRITE_FAILED' -PublishedHash $PublishedHash)
        return (Read-CcodOfficialDraftJson -Path $path).Value
    } catch {
        if ($_.FullyQualifiedErrorId -like 'CCOD_ACCEPTANCE_*') { throw }
        Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_COMPLETE_WRITE_FAILED' 'The complete official-draft acceptance receipt could not be written.' $null
    }
}

function Get-CcodOfficialDraftBootIdentity {
    param([Parameter(Mandatory)]$Adapters)
    try {
        $values = @(& $Adapters.GetBootIdentity)
        if ($values.Count -ne 1 -or $values[0] -isnot [string] -or
            [string]$values[0] -notmatch '^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\z') { throw 'boot identity' }
        return [string]$values[0]
    } catch {
        if ($_.FullyQualifiedErrorId -like 'CCOD_ACCEPTANCE_*') { throw }
        Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_BOOT_ID_INVALID' 'The boot identity observation is missing or malformed.' $null
    }
}

function ConvertTo-CcodOfficialDraftPreRebootFacts {
    param(
        [Parameter(Mandatory)][string]$BootId,
        [Parameter(Mandatory)][string]$FreshReceiptHash,
        [Parameter(Mandatory)][string]$RuntimeId,
        [Parameter(Mandatory)][UInt64]$Generation,
        [Parameter(Mandatory)][string]$ManifestHash,
        [Parameter(Mandatory)][string]$KeyHash,
        [Parameter(Mandatory)]$Observation
    )
    return [pscustomobject][ordered]@{
        rebootRequested = $true
        bootIdBefore = $BootId
        freshInstallReceiptSha256 = $FreshReceiptHash
        activeRuntimeId = $RuntimeId
        activeGeneration = $Generation
        runtimeManifestSha256 = $ManifestHash
        deviceKeySha256 = $KeyHash
        operationOutcome = 'Completed'
        observation = $Observation
    }
}

function Assert-CcodOfficialDraftPostRebootFacts {
    param(
        [Parameter(Mandatory)]$Facts,
        [Parameter(Mandatory)]$FreshFacts,
        [Parameter(Mandatory)][string]$ExpectedKeyHash,
        [Parameter(Mandatory)][string]$BootBefore,
        [Parameter(Mandatory)][string]$ExpectedVersion
    )
    try {
        foreach ($name in @('installRootPresent','activePointerPresent','bootId','transitionStage','protectionRecovered','protectionReady','taskState','supervisor','trayHost','codex','codexCount','statusCodex','trayAuthenticated','lifecycleReceipt','runtimeManifestSha256')) {
            if (-not (Test-CcodOfficialDraftHasFact -Facts $Facts -Name $name)) { throw 'missing fact' }
        }
        foreach ($name in @('installRootPresent','activePointerPresent')) {
            $presence = Get-CcodOfficialDraftFactValue -Facts $Facts -Name $name
            if ($presence -isnot [bool] -or -not [bool]$presence) { throw 'installed state presence' }
        }
        $bootAfter = Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'bootId'
        if ($bootAfter -isnot [string] -or $bootAfter -notmatch '^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\z' -or $bootAfter -ceq $BootBefore) { throw 'boot' }
        if ((Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'transitionStage') -isnot [string] -or
            (Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'transitionStage') -cne 'Idle') { throw 'transition' }
        foreach ($name in @('protectionRecovered','protectionReady','trayAuthenticated')) {
            $value = Get-CcodOfficialDraftFactValue -Facts $Facts -Name $name
            if ($value -isnot [bool] -or -not [bool]$value) { throw 'protection' }
        }
        if ((Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'taskState') -notin @('Ready','Running') -or
            @(Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'supervisor').Count -ne 1 -or
            @(Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'trayHost').Count -ne 1 -or
            -not (Test-CcodOfficialDraftInt32 (Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'codexCount')) -or
            [int](Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'codexCount') -ne 1 -or
            @(Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'codex').Count -ne 1 -or
            $null -eq (Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'statusCodex')) { throw 'runtime' }
        $trayIdentity = ConvertTo-CcodOfficialDraftTrayHostIdentity -Value (Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'trayHostIdentity')
        $observedTrayIdentity = ConvertTo-CcodOfficialDraftTrayHostIdentity -Value (Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'trayHost')[0]
        if ($trayIdentity.pid -ne $observedTrayIdentity.pid -or $trayIdentity.creationTimeUtc -cne $observedTrayIdentity.creationTimeUtc) { throw 'tray identity binding' }
        $terminal = ConvertTo-CcodOfficialDraftTerminalReceipt -Receipt (Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'lifecycleReceipt')
        $expectedTerminal = Get-CcodOfficialDraftFactValue -Facts $FreshFacts -Name 'terminalReceipt'
        $observedRuntimeId = Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'activeRuntimeId'
        $observedGeneration = Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'activeGeneration'
        $expectedRuntimeId = Get-CcodOfficialDraftFactValue -Facts $FreshFacts -Name 'activeRuntimeId'
        $expectedGeneration = Get-CcodOfficialDraftFactValue -Facts $FreshFacts -Name 'activeGeneration'
        $observedManifestHash = Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'runtimeManifestSha256'
        $expectedManifestHash = Get-CcodOfficialDraftFactValue -Facts $FreshFacts -Name 'runtimeManifestSha256'
        if ($observedRuntimeId -isnot [string] -or $observedRuntimeId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,95}\z' -or
            -not (Test-CcodOfficialDraftPositiveInteger $observedGeneration) -or
            -not (Test-CcodOfficialDraftHash $observedManifestHash) -or $observedManifestHash -cne $expectedManifestHash -or
            $terminal.runtimeId -cne $observedRuntimeId -or [UInt64]$terminal.runtimeGeneration -ne [UInt64]$observedGeneration -or
            $observedRuntimeId -cne $expectedRuntimeId -or [UInt64]$observedGeneration -ne [UInt64]$expectedGeneration -or
            $terminal.runtimeId -cne $expectedTerminal.runtimeId -or [UInt64]$terminal.runtimeGeneration -ne [UInt64]$expectedTerminal.runtimeGeneration) { throw 'receipt continuity' }
        $keyHash = Get-CcodOfficialDraftObservedKeyHash -Facts $Facts
        if ($keyHash -cne $ExpectedKeyHash) { throw 'key' }
        $observation = ConvertTo-CcodOfficialDraftLegacyObservation -Facts $Facts -ExpectedVersion $ExpectedVersion
        if ($observation.bootId -cne [string]$bootAfter -or $observation.activeRuntimeId -cne [string]$observedRuntimeId -or
            [UInt64]$observation.activeGeneration -ne [UInt64]$observedGeneration -or
            $observation.runtimeManifestSha256 -cne [string]$observedManifestHash -or
            $observation.deviceKeySha256 -cne [string]$keyHash) { throw 'observation continuity' }
        return [pscustomobject][ordered]@{
            observation = $observation
            installRootPresent = $true
            activePointerPresent = $true
            bootIdBefore = $BootBefore
            bootIdAfter = [string]$bootAfter
            bootChanged = $true
            receiptContinuity = $true
            activeRuntimeId = [string]$observedRuntimeId
            activeGeneration = [UInt64]$observedGeneration
            runtimeManifestSha256 = [string]$observedManifestHash
            transitionStage = 'Idle'
            protectionRecovered = $true
            protectionReady = $true
            taskState = [string](Get-CcodOfficialDraftFactValue -Facts $Facts -Name 'taskState')
            supervisorCount = 1
            trayHostCount = 1
            codexCount = 1
            trayHostIdentity = $trayIdentity
            trayAuthenticated = $true
            terminalReceipt = $terminal
            deviceKeySha256 = $keyHash
            keyHashPreserved = $true
            operationOutcome = 'Completed'
        }
    } catch {
        if ($_.FullyQualifiedErrorId -like 'CCOD_ACCEPTANCE_*') { throw }
        Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_POST_REBOOT_OBSERVATION_INVALID' 'Post-reboot observations did not prove a new boot and recovered protected runtime.' $null
    }
}

function Invoke-CcodOfficialDraftAcceptanceCore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Preflight','LegacyUpgrade','Uninstall','FreshInstall','PreReboot','PostReboot','ReadyForManualEvidence','TrayEvidence','RemoteEvidence','Complete')][string]$Phase,
        [Parameter(Mandatory)][string]$AssetDirectory,
        [Parameter(Mandatory)][string]$PreviousAssetDirectory,
        [Parameter(Mandatory)][string]$EvidenceRoot,
        [string]$DraftId,
        [switch]$AllowMachineMutation,
        [switch]$AllowCodexRestart,
        [switch]$AllowWindowsReboot,
        [string]$TrayOperation,
        [string]$RemoteOperation,
        [string]$ScreenshotPath,
        [string]$RedactedLogPath,
        [string]$ReviewState,
        [hashtable]$Adapters
    )
    $phaseMatches = @(@($script:CcodOfficialDraftPhases) + @('TrayEvidence','RemoteEvidence','Complete') | Where-Object { [string]$_ -ieq [string]$Phase })
    if ($phaseMatches.Count -ne 1) { Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_PHASE_INVALID' 'The official-draft acceptance phase is unsupported.' $Phase }
    $Phase = [string]$phaseMatches[0]
    $operationLease = Open-CcodOfficialDraftOperationLease -EvidenceRoot $EvidenceRoot
    try {
    $stateDirectory = Get-CcodOfficialDraftStateDirectory -EvidenceRoot $EvidenceRoot
    [void](Assert-CcodOfficialDraftSafeDirectory -Path $PreviousAssetDirectory -ErrorId 'CCOD_ACCEPTANCE_PREVIOUS_ASSET_INVALID')
    $adapters = Resolve-CcodOfficialDraftAdapters -Adapters $Adapters
    $candidateValue = $null
    try {
        $candidateValue = & $adapters.ValidateAssetSet $AssetDirectory $script:CcodOfficialDraftExpectedVersion
    } catch {
        if ($_.FullyQualifiedErrorId -like 'CCOD_ACCEPTANCE_*') { throw }
        Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_ASSET_CONTRACT_INVALID' 'The official draft does not satisfy the exact eleven-asset manifest contract.' $null
    }
    $candidate = ConvertTo-CcodOfficialDraftCandidate -Value $candidateValue
    $draftValue = $null
    try { $draftValue = & $adapters.GetDraftIdentity $AssetDirectory $candidate $DraftId } catch { Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_DRAFT_IDENTITY_INVALID' 'The official draft identity could not be read.' $null }
    $draft = ConvertTo-CcodOfficialDraftIdentity -Value $draftValue
    $records = Read-CcodOfficialDraftState -StateDirectory $stateDirectory -PreviousAssetDirectory $PreviousAssetDirectory
    $allowExistingComplete = $false
    if ($Phase -ceq 'Complete' -and $records.ContainsKey('Complete')) {
        $existingAcceptance = $null
        $acceptancePathForResume = Get-CcodOfficialDraftCompleteAcceptancePath -EvidenceRoot $EvidenceRoot
        try { $existingAcceptance = Get-Item -LiteralPath $acceptancePathForResume -Force -ErrorAction Stop } catch { if (-not (Test-CcodOfficialDraftMissingError -ErrorRecord $_)) { Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_PHASE_REUSED' 'The complete acceptance artifact could not be inspected safely.' $acceptancePathForResume } }
        $allowExistingComplete = $null -eq $existingAcceptance
    }
    Assert-CcodOfficialDraftPhaseState -Phase $Phase -Records $records -Candidate $candidate -Draft $draft -AllowExistingComplete:$allowExistingComplete
    Assert-CcodOfficialDraftPhaseAuthorization -Phase $Phase -AllowMachineMutation:$AllowMachineMutation -AllowCodexRestart:$AllowCodexRestart -AllowWindowsReboot:$AllowWindowsReboot
    if ($Phase -ceq 'Preflight') {
        $scanReceipts = [Collections.Generic.List[object]]::new()
        $expectedScans = @(
            [pscustomobject]@{ Type = 'Setup'; Index = 5 },
            [pscustomobject]@{ Type = 'PortableZip'; Index = 0 }
        )
        foreach ($scan in $expectedScans) {
            $pending = Join-Path $stateDirectory ('.defender-' + $scan.Type + '-' + [guid]::NewGuid().ToString('N') + '.json')
            $pendingExpected = @{ ([IO.Path]::GetFullPath($pending)) = $null }
            try {
                $rawReceipt = & $adapters.InvokeDefenderCheck $AssetDirectory $scan.Type 'InternetDownload' $candidate.version $candidate.gitCommit $pending
                $pendingHash = $null
                try { $pendingItem = Get-Item -LiteralPath $pending -Force -ErrorAction Stop; if ($null -ne $pendingItem) { $pendingHash = Get-CcodOfficialDraftFileSha256 -Path $pending } } catch { if (-not (Test-CcodOfficialDraftMissingError -ErrorRecord $_)) { throw } }
                $pendingExpected = @{ ([IO.Path]::GetFullPath($pending)) = $pendingHash }
                if ($null -eq $rawReceipt) { throw 'empty' }
                $scanReceipts.Add((ConvertTo-CcodOfficialDraftDefenderReceipt -Receipt $rawReceipt -Candidate $candidate -AssetType $scan.Type))
            } catch {
                if ($_.FullyQualifiedErrorId -like 'CCOD_ACCEPTANCE_*') { throw }
                Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_DEFENDER_RECEIPT_INVALID' 'The official downloaded-asset Defender scan did not produce a valid receipt.' $null
            } finally {
                try { [void](Remove-CcodOfficialDraftCompleteArtifacts -Paths @($pending) -ExpectedHashes $pendingExpected) }
                catch { Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_DEFENDER_RECEIPT_CLEANUP_FAILED' 'Temporary Defender receipt cleanup could not be proven.' $pending }
            }
        }
        $facts = [pscustomobject][ordered]@{ defenderReceipts = @($scanReceipts) }
        $written = Write-CcodOfficialDraftReceipt -StateDirectory $stateDirectory -Phase $Phase -Candidate $candidate -Draft $draft -Facts $facts
        return [pscustomobject][ordered]@{ phase = 'Preflight'; outcome = 'Completed'; complete = $false; candidate = $written.candidate; facts = $written.facts }
    }
    if ($Phase -ceq 'LegacyUpgrade') {
        try {
            $previousValues = @(& $adapters.ValidatePreviousSetup $PreviousAssetDirectory '2.5.21')
            if ($previousValues.Count -ne 1 -or $null -eq $previousValues[0]) { throw 'previous' }
            $previous = ConvertTo-CcodOfficialDraftPreviousSetup -Value $previousValues[0]
        } catch {
            if ($_.FullyQualifiedErrorId -like 'CCOD_ACCEPTANCE_*') { throw }
            Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_PREVIOUS_ASSET_INVALID' 'The previous public v2.5.21 Setup is not manifest-bound.' $null
        }
        $context = New-CcodOfficialDraftContext -Phase $Phase -AssetDirectory $AssetDirectory -PreviousAssetDirectory $PreviousAssetDirectory -EvidenceRoot $EvidenceRoot -Candidate $candidate -Draft $draft -PreviousSetup $previous -AllowMachineMutation:$AllowMachineMutation -AllowCodexRestart:$AllowCodexRestart -AllowWindowsReboot:$AllowWindowsReboot
        try {
            $beforeValues = @(& $adapters.CaptureFacts $context 'Before')
            if ($beforeValues.Count -ne 1 -or $null -eq $beforeValues[0]) { throw 'before facts' }
            $beforeObservation = ConvertTo-CcodOfficialDraftLegacyObservation -Facts $beforeValues[0] -ExpectedVersion $previous.version
            $beforeHash = [string]$beforeObservation.deviceKeySha256
        } catch {
            if ($_.FullyQualifiedErrorId -like 'CCOD_ACCEPTANCE_*') { throw }
            Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_OBSERVATION_UNAVAILABLE' 'The pre-upgrade lifecycle observation is unavailable.' $null
        }
        [void](Invoke-CcodOfficialDraftPhaseOperation -Adapters $adapters -Context $context)
        try {
            $afterValues = @(& $adapters.CaptureFacts $context 'After')
            if ($afterValues.Count -ne 1 -or $null -eq $afterValues[0]) { throw 'after facts' }
            $afterObservation = ConvertTo-CcodOfficialDraftLegacyObservation -Facts $afterValues[0] -ExpectedVersion $candidate.version
            $afterHash = [string]$afterObservation.deviceKeySha256
        } catch {
            if ($_.FullyQualifiedErrorId -like 'CCOD_ACCEPTANCE_*') { throw }
            Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_OBSERVATION_UNAVAILABLE' 'The post-upgrade lifecycle observation is unavailable.' $null
        }
        if ($beforeHash -cne $afterHash) {
            Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_KEY_HASH_CHANGED' 'The DPAPI device-key hash changed during legacy upgrade.' $null
        }
        $facts = ConvertTo-CcodOfficialDraftLegacyFacts -PreviousSetup $previous -BeforeObservation $beforeObservation -AfterObservation $afterObservation -BeforeHash $beforeHash -AfterHash $afterHash
        $written = Write-CcodOfficialDraftReceipt -StateDirectory $stateDirectory -Phase $Phase -Candidate $candidate -Draft $draft -Facts $facts
        return [pscustomobject][ordered]@{ phase = 'LegacyUpgrade'; outcome = 'Completed'; complete = $false; candidate = $written.candidate; facts = $written.facts }
    }
    if ($Phase -ceq 'Uninstall') {
        $legacyFacts = $records.LegacyUpgrade.facts
        $expectedKeyHash = Get-CcodOfficialDraftFactValue -Facts $legacyFacts -Name 'deviceKeySha256After'
        if (-not (Test-CcodOfficialDraftHash $expectedKeyHash)) {
            Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_RECEIPT_INVALID' 'LegacyUpgrade does not contain a usable device-key hash.' $null
        }
        $context = New-CcodOfficialDraftContext -Phase $Phase -AssetDirectory $AssetDirectory -PreviousAssetDirectory $PreviousAssetDirectory -EvidenceRoot $EvidenceRoot -Candidate $candidate -Draft $draft -PreviousSetup $legacyFacts.previousSetup -AllowMachineMutation:$AllowMachineMutation -AllowCodexRestart:$AllowCodexRestart -AllowWindowsReboot:$AllowWindowsReboot
        try {
            $beforeValues = @(& $adapters.CaptureFacts $context 'Before')
            if ($beforeValues.Count -ne 1 -or $null -eq $beforeValues[0]) { throw 'before facts' }
            $beforeHash = Get-CcodOfficialDraftObservedKeyHash -Facts $beforeValues[0]
        } catch {
            if ($_.FullyQualifiedErrorId -like 'CCOD_ACCEPTANCE_*') { throw }
            Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_OBSERVATION_UNAVAILABLE' 'The pre-uninstall lifecycle observation is unavailable.' $null
        }
        if ($beforeHash -cne [string]$expectedKeyHash) {
            Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_KEY_HASH_CHANGED' 'The DPAPI device-key hash changed before uninstall.' $null
        }
        [void](Invoke-CcodOfficialDraftPhaseOperation -Adapters $adapters -Context $context)
        try {
            $afterValues = @(& $adapters.CaptureFacts $context 'After')
            if ($afterValues.Count -ne 1 -or $null -eq $afterValues[0]) { throw 'after facts' }
            $afterHash = Assert-CcodOfficialDraftUninstallFacts -Facts $afterValues[0] -ExpectedKeyHash $expectedKeyHash
        } catch {
            if ($_.FullyQualifiedErrorId -like 'CCOD_ACCEPTANCE_*') { throw }
            Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_UNINSTALL_OBSERVATION_INVALID' 'Uninstall did not prove complete owned-state removal.' $null
        }
        $facts = ConvertTo-CcodOfficialDraftUninstallFacts -Facts $afterValues[0] -BeforeHash $beforeHash -AfterHash $afterHash
        $written = Write-CcodOfficialDraftReceipt -StateDirectory $stateDirectory -Phase $Phase -Candidate $candidate -Draft $draft -Facts $facts
        return [pscustomobject][ordered]@{ phase = 'Uninstall'; outcome = 'Completed'; complete = $false; candidate = $written.candidate; facts = $written.facts }
    }
    if ($Phase -ceq 'FreshInstall') {
        $uninstallFacts = $records.Uninstall.facts
        $expectedKeyHash = Get-CcodOfficialDraftFactValue -Facts $uninstallFacts -Name 'deviceKeySha256After'
        if (-not (Test-CcodOfficialDraftHash $expectedKeyHash)) {
            Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_RECEIPT_INVALID' 'Uninstall does not contain a usable device-key hash.' $null
        }
        $previousSetup = $records.LegacyUpgrade.facts.previousSetup
        $context = New-CcodOfficialDraftContext -Phase $Phase -AssetDirectory $AssetDirectory -PreviousAssetDirectory $PreviousAssetDirectory -EvidenceRoot $EvidenceRoot -Candidate $candidate -Draft $draft -PreviousSetup $previousSetup -AllowMachineMutation:$AllowMachineMutation -AllowCodexRestart:$AllowCodexRestart -AllowWindowsReboot:$AllowWindowsReboot
        $operationResult = Invoke-CcodOfficialDraftPhaseOperation -Adapters $adapters -Context $context
        try {
            $afterValues = @(& $adapters.CaptureFacts $context 'After')
            if ($afterValues.Count -ne 1 -or $null -eq $afterValues[0]) { throw 'after facts' }
            $facts = Assert-CcodOfficialDraftFreshFacts -Facts $afterValues[0] -ExpectedKeyHash $expectedKeyHash -ExpectedRuntimeManifestSha256 $operationResult.runtimeManifestSha256
        } catch {
            if ($_.FullyQualifiedErrorId -like 'CCOD_ACCEPTANCE_*') { throw }
            Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_FRESH_INSTALL_OBSERVATION_INVALID' 'Fresh install did not prove an active generation and authenticated protection.' $null
        }
        $written = Write-CcodOfficialDraftReceipt -StateDirectory $stateDirectory -Phase $Phase -Candidate $candidate -Draft $draft -Facts $facts
        return [pscustomobject][ordered]@{ phase = 'FreshInstall'; outcome = 'Completed'; complete = $false; candidate = $written.candidate; facts = $written.facts }
    }
    if ($Phase -ceq 'PreReboot') {
        $freshFacts = $records.FreshInstall.facts
        $expectedKeyHash = Get-CcodOfficialDraftFactValue -Facts $freshFacts -Name 'deviceKeySha256'
        $runtimeId = Get-CcodOfficialDraftFactValue -Facts $freshFacts -Name 'activeRuntimeId'
        $generation = Get-CcodOfficialDraftFactValue -Facts $freshFacts -Name 'activeGeneration'
        if (-not (Test-CcodOfficialDraftHash $expectedKeyHash) -or
            $runtimeId -isnot [string] -or $runtimeId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,95}\z' -or
            -not (Test-CcodOfficialDraftPositiveInteger $generation)) {
            Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_RECEIPT_INVALID' 'FreshInstall does not contain a usable continuity identity.' $null
        }
        $freshPath = Join-Path $stateDirectory $script:CcodOfficialDraftPhaseFiles.FreshInstall
        $freshHash = Get-CcodOfficialDraftFileSha256 -Path $freshPath
        $bootBefore = Get-CcodOfficialDraftBootIdentity -Adapters $adapters
        $context = New-CcodOfficialDraftContext -Phase $Phase -AssetDirectory $AssetDirectory -PreviousAssetDirectory $PreviousAssetDirectory -EvidenceRoot $EvidenceRoot -Candidate $candidate -Draft $draft -PreviousSetup $records.LegacyUpgrade.facts.previousSetup -AllowMachineMutation:$AllowMachineMutation -AllowCodexRestart:$AllowCodexRestart -AllowWindowsReboot:$AllowWindowsReboot
        try {
            $beforeValues = @(& $adapters.CaptureFacts $context 'Before')
            if ($beforeValues.Count -ne 1 -or $null -eq $beforeValues[0]) { throw 'before facts' }
            $beforeObservation = ConvertTo-CcodOfficialDraftLegacyObservation -Facts $beforeValues[0] -ExpectedVersion $candidate.version
            if ($beforeObservation.deviceKeySha256 -cne [string]$expectedKeyHash -or
                $beforeObservation.activeRuntimeId -cne [string]$runtimeId -or
                [UInt64]$beforeObservation.activeGeneration -ne [UInt64]$generation -or
                $beforeObservation.runtimeManifestSha256 -cne [string]$freshFacts.runtimeManifestSha256 -or
                $beforeObservation.bootId -isnot [string] -or $beforeObservation.bootId -cne $bootBefore) { throw 'pre-reboot continuity' }
        } catch {
            if ($_.FullyQualifiedErrorId -like 'CCOD_ACCEPTANCE_*') { throw }
            Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_OBSERVATION_UNAVAILABLE' 'The pre-reboot lifecycle observation is unavailable.' $null
        }
        $facts = ConvertTo-CcodOfficialDraftPreRebootFacts -BootId $bootBefore -FreshReceiptHash $freshHash -RuntimeId $runtimeId -Generation ([UInt64]$generation) -ManifestHash ([string]$freshFacts.runtimeManifestSha256) -KeyHash $expectedKeyHash -Observation $beforeObservation
        $preRebootHash = $null
        $written = Write-CcodOfficialDraftReceipt -StateDirectory $stateDirectory -Phase $Phase -Candidate $candidate -Draft $draft -Facts $facts -PublishedHash ([ref]$preRebootHash)
        $preRebootPath = Join-Path $stateDirectory $script:CcodOfficialDraftPhaseFiles.PreReboot
        $preRebootExpected = @{ ([IO.Path]::GetFullPath($preRebootPath)) = $preRebootHash }
        try {
            $rebootValues = @(& $adapters.Reboot $context)
            if ($rebootValues.Count -ne 1 -or $rebootValues[0] -isnot [bool] -or -not [bool]$rebootValues[0]) { throw 'reboot' }
        } catch {
            try {
                [void](Remove-CcodOfficialDraftCompleteArtifacts -Paths @($preRebootPath) -ExpectedHashes $preRebootExpected)
            } catch {
                Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_REBOOT_FAILED' 'The failed reboot receipt could not be removed safely.' $null
            }
            if ($_.FullyQualifiedErrorId -like 'CCOD_ACCEPTANCE_*') { throw }
            Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_REBOOT_FAILED' 'The authorized Windows reboot did not return proven completion.' $null
        }
        return [pscustomobject][ordered]@{ phase = 'PreReboot'; outcome = 'Completed'; complete = $false; candidate = $written.candidate; facts = $written.facts }
    }
    if ($Phase -ceq 'PostReboot') {
        $freshFacts = $records.FreshInstall.facts
        $preFacts = $records.PreReboot.facts
        $expectedKeyHash = Get-CcodOfficialDraftFactValue -Facts $freshFacts -Name 'deviceKeySha256'
        $bootBefore = Get-CcodOfficialDraftFactValue -Facts $preFacts -Name 'bootIdBefore'
        $freshReceiptHash = Get-CcodOfficialDraftFactValue -Facts $preFacts -Name 'freshInstallReceiptSha256'
        if (-not (Test-CcodOfficialDraftHash $expectedKeyHash) -or
            $bootBefore -isnot [string] -or $bootBefore -notmatch '^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\z' -or
            -not (Test-CcodOfficialDraftHash $freshReceiptHash)) {
            Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_RECEIPT_INVALID' 'PreReboot does not contain a usable continuity identity.' $null
        }
        $freshPath = Join-Path $stateDirectory $script:CcodOfficialDraftPhaseFiles.FreshInstall
        if ((Get-CcodOfficialDraftFileSha256 -Path $freshPath) -cne [string]$freshReceiptHash) {
            Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_RECEIPT_INVALID' 'The FreshInstall receipt changed after the reboot boundary.' $null
        }
        $bootAfter = Get-CcodOfficialDraftBootIdentity -Adapters $adapters
        $context = New-CcodOfficialDraftContext -Phase $Phase -AssetDirectory $AssetDirectory -PreviousAssetDirectory $PreviousAssetDirectory -EvidenceRoot $EvidenceRoot -Candidate $candidate -Draft $draft -PreviousSetup $records.LegacyUpgrade.facts.previousSetup -AllowMachineMutation:$AllowMachineMutation -AllowCodexRestart:$AllowCodexRestart -AllowWindowsReboot:$AllowWindowsReboot
        try {
            $afterValues = @(& $adapters.CaptureFacts $context 'After')
            if ($afterValues.Count -ne 1 -or $null -eq $afterValues[0]) { throw 'after facts' }
            $facts = Assert-CcodOfficialDraftPostRebootFacts -Facts $afterValues[0] -FreshFacts $freshFacts -ExpectedKeyHash $expectedKeyHash -BootBefore $bootBefore -ExpectedVersion $candidate.version
        } catch {
            if ($_.FullyQualifiedErrorId -like 'CCOD_ACCEPTANCE_*') { throw }
            Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_POST_REBOOT_OBSERVATION_INVALID' 'Post-reboot observations did not prove a new boot and recovered protected runtime.' $null
        }
        if ($bootAfter -cne [string]$facts.bootIdAfter) {
            Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_BOOT_ID_INVALID' 'The post-reboot boot identity changed during observation.' $null
        }
        $written = Write-CcodOfficialDraftReceipt -StateDirectory $stateDirectory -Phase $Phase -Candidate $candidate -Draft $draft -Facts $facts
        return [pscustomobject][ordered]@{ phase = 'PostReboot'; outcome = 'Completed'; complete = $false; candidate = $written.candidate; facts = $written.facts }
    }
    if ($Phase -ceq 'ReadyForManualEvidence') {
        $manualChallenge = [guid]::NewGuid().ToString('N')
        $facts = [pscustomobject][ordered]@{
            automatedPhases = @('Preflight','LegacyUpgrade','Uninstall','FreshInstall','PreReboot','PostReboot')
            status = 'ReadyForManualEvidence'
            manualEvidencePending = $true
            complete = $false
            manualChallenge = $manualChallenge
        }
        $written = Write-CcodOfficialDraftReceipt -StateDirectory $stateDirectory -Phase $Phase -Candidate $candidate -Draft $draft -Facts $facts
        return [pscustomobject][ordered]@{ phase = 'ReadyForManualEvidence'; outcome = 'ReadyForManualEvidence'; complete = $false; candidate = $written.candidate; facts = $written.facts }
    }
    if ($Phase -in @('TrayEvidence','RemoteEvidence')) {
        if (($Phase -ceq 'TrayEvidence' -and [string]::IsNullOrWhiteSpace($TrayOperation)) -or
            ($Phase -ceq 'RemoteEvidence' -and [string]::IsNullOrWhiteSpace($RemoteOperation)) -or
            ($Phase -ceq 'TrayEvidence' -and -not [string]::IsNullOrWhiteSpace($RemoteOperation)) -or
            ($Phase -ceq 'RemoteEvidence' -and -not [string]::IsNullOrWhiteSpace($TrayOperation)) -or
            [string]::IsNullOrWhiteSpace($ScreenshotPath) -or [string]::IsNullOrWhiteSpace($RedactedLogPath) -or
            [string]::IsNullOrWhiteSpace($ReviewState)) {
            Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_MANUAL_EVIDENCE_INVALID' 'Manual evidence requires exactly one bounded operation, two evidence files, and Reviewed state.' $null
        }
        $rawOperation = if ($Phase -ceq 'TrayEvidence') { $TrayOperation } else { $RemoteOperation }
        $operationMatches = @($script:CcodOfficialDraftManualOperations | Where-Object { [string]$_ -ieq [string]$rawOperation })
        if ($operationMatches.Count -ne 1) {
            Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_MANUAL_OPERATION_INVALID' 'The manual evidence operation is unsupported.' $null
        }
        $operation = [string]$operationMatches[0]
        $canonicalReviewState = if ([string]$ReviewState -ieq 'Reviewed') { 'Reviewed' } else { [string]$ReviewState }
        $context = New-CcodOfficialDraftContext -Phase $Phase -AssetDirectory $AssetDirectory -PreviousAssetDirectory $PreviousAssetDirectory -EvidenceRoot $EvidenceRoot -Candidate $candidate -Draft $draft -PreviousSetup $records.LegacyUpgrade.facts.previousSetup -AllowMachineMutation:$AllowMachineMutation -AllowCodexRestart:$AllowCodexRestart -AllowWindowsReboot:$AllowWindowsReboot
        $context | Add-Member -NotePropertyName operation -NotePropertyValue $operation
        $context | Add-Member -NotePropertyName screenshotPath -NotePropertyValue ([IO.Path]::GetFullPath($ScreenshotPath))
        $context | Add-Member -NotePropertyName redactedLogPath -NotePropertyValue ([IO.Path]::GetFullPath($RedactedLogPath))
        $readyChallenge = Get-CcodOfficialDraftFactValue -Facts $records.ReadyForManualEvidence.facts -Name 'manualChallenge'
        if ($readyChallenge -isnot [string] -or $readyChallenge -cnotmatch '^[0-9a-f]{32}\z') {
            Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_RECEIPT_INVALID' 'ReadyForManualEvidence does not contain a usable manual challenge.' $null
        }
        $context | Add-Member -NotePropertyName manualChallenge -NotePropertyValue ([string]$readyChallenge)
        $context | Add-Member -NotePropertyName expectedRuntimeId -NotePropertyValue ([string](Get-CcodOfficialDraftFactValue -Facts $records.FreshInstall.facts -Name 'activeRuntimeId'))
        $context | Add-Member -NotePropertyName expectedGeneration -NotePropertyValue ([UInt64](Get-CcodOfficialDraftFactValue -Facts $records.FreshInstall.facts -Name 'activeGeneration'))
        $context | Add-Member -NotePropertyName expectedRuntimeManifestSha256 -NotePropertyValue ([string](Get-CcodOfficialDraftFactValue -Facts $records.FreshInstall.facts -Name 'runtimeManifestSha256'))
        $context | Add-Member -NotePropertyName expectedDeviceKeySha256 -NotePropertyValue ([string](Get-CcodOfficialDraftFactValue -Facts $records.FreshInstall.facts -Name 'deviceKeySha256'))
        $context | Add-Member -NotePropertyName expectedBootId -NotePropertyValue ([string](Get-CcodOfficialDraftFactValue -Facts $records.PostReboot.facts -Name 'bootIdAfter'))
        try {
            $programmaticValues = @(& $adapters.RunManualOperation $context $operation)
            if ($programmaticValues.Count -ne 1 -or $null -eq $programmaticValues[0] -or
                -not (Test-CcodOfficialDraftExactProperties -Value $programmaticValues[0] -Expected @('verified','operation','terminalState','code','proof','screenshotSha256','redactedLogSha256')) -or
                $programmaticValues[0].verified -isnot [bool] -or -not [bool]$programmaticValues[0].verified -or
                $programmaticValues[0].screenshotSha256 -isnot [string] -or -not (Test-CcodOfficialDraftHash $programmaticValues[0].screenshotSha256) -or
                $programmaticValues[0].redactedLogSha256 -isnot [string] -or -not (Test-CcodOfficialDraftHash $programmaticValues[0].redactedLogSha256)) { throw 'manual operation result' }
            $programmaticResult = $programmaticValues[0]
        } catch {
            if ($_.FullyQualifiedErrorId -like 'CCOD_ACCEPTANCE_*') { throw }
            Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_MANUAL_OPERATION_UNPROVEN' 'The requested manual operation did not produce programmatic proof.' $operation
        }
        try {
            $manualObservationValues = @(& $adapters.CaptureFacts $context 'AfterManualOperation')
            if ($manualObservationValues.Count -ne 1 -or $null -eq $manualObservationValues[0]) { throw 'manual observation' }
            $manualObservation = ConvertTo-CcodOfficialDraftLegacyObservation -Facts $manualObservationValues[0] -ExpectedVersion ([string]$context.expectedVersion)
            if ($manualObservation.activeRuntimeId -cne [string]$context.expectedRuntimeId -or
                [UInt64]$manualObservation.activeGeneration -ne [UInt64]$context.expectedGeneration -or
                $manualObservation.runtimeManifestSha256 -cne [string]$context.expectedRuntimeManifestSha256 -or
                $manualObservation.deviceKeySha256 -cne [string]$context.expectedDeviceKeySha256 -or
                $manualObservation.bootId -cne [string]$context.expectedBootId) { throw 'manual observation continuity' }
        } catch {
            $failure = $_
            if ($failure.FullyQualifiedErrorId -like 'CCOD_ACCEPTANCE_*') { throw $failure }
            Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_MANUAL_OPERATION_UNPROVEN' 'The current runtime identity changed or could not be re-observed after the manual operation.' $operation
        }
        $existing = if ($records.ContainsKey('ManualEvidence')) { $records.ManualEvidence } else { @{} }
        $manualRecord = Write-CcodOfficialDraftManualEvidence -StateDirectory $stateDirectory -Phase $Phase -Operation $operation -Candidate $candidate -Existing $existing -ProgrammaticResult $programmaticResult -ScreenshotPath $ScreenshotPath -RedactedLogPath $RedactedLogPath -ArtifactDirectory (Join-Path ([IO.Path]::GetFullPath($EvidenceRoot)) 'official-draft-artifacts') -ReviewState $canonicalReviewState -ExpectedChallenge ([string]$context.manualChallenge) -ExpectedRuntimeId ([string]$context.expectedRuntimeId) -ExpectedGeneration $context.expectedGeneration -ExpectedManifestSha256 ([string]$context.expectedRuntimeManifestSha256)
        return [pscustomobject][ordered]@{ phase = $Phase; outcome = 'Completed'; complete = $false; candidate = $candidate; facts = $manualRecord }
    }
    if ($Phase -ceq 'Complete') {
        if (-not [string]::IsNullOrWhiteSpace($TrayOperation) -or -not [string]::IsNullOrWhiteSpace($RemoteOperation) -or
            -not [string]::IsNullOrWhiteSpace($ScreenshotPath) -or -not [string]::IsNullOrWhiteSpace($RedactedLogPath) -or
            -not [string]::IsNullOrWhiteSpace($ReviewState)) {
            Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_MANUAL_EVIDENCE_INVALID' 'Complete does not accept an individual manual evidence payload.' $null
        }
        $manual = Assert-CcodOfficialDraftManualEvidenceSet -Records $records.ManualEvidence -Candidate $candidate
        $nowValues = @(& $adapters.GetUtcNow)
        if ($nowValues.Count -ne 1 -or $nowValues[0] -isnot [datetime] -or $nowValues[0].Kind -ne [DateTimeKind]::Utc) {
            Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_COMPLETE_WRITE_FAILED' 'Complete acceptance requires a valid UTC clock.' $null
        }
        $facts = [pscustomobject][ordered]@{ manualEvidence = @($manual); status = 'Complete'; complete = $true }
        $acceptancePath = Get-CcodOfficialDraftCompleteAcceptancePath -EvidenceRoot $EvidenceRoot
        $statePath = Join-Path $stateDirectory $script:CcodOfficialDraftCompletionFile
        $completeCleanupExpected = @{}
        $completeReceiptHash = $null
        $completeAcceptanceHash = $null
        try {
            $written = Write-CcodOfficialDraftReceipt -StateDirectory $stateDirectory -Phase $Phase -Candidate $candidate -Draft $draft -Facts $facts -PublishedHash ([ref]$completeReceiptHash)
            if (Test-CcodOfficialDraftHash $completeReceiptHash) { $completeCleanupExpected[[IO.Path]::GetFullPath($statePath)] = $completeReceiptHash }
            $automatedHashes = [Collections.Generic.List[object]]::new()
            foreach ($automatedPhase in $script:CcodOfficialDraftPhases) {
                $automatedHashes.Add([pscustomobject][ordered]@{
                    phase = [string]$automatedPhase
                    sha256 = Get-CcodOfficialDraftFileSha256 -Path (Join-Path $stateDirectory $script:CcodOfficialDraftPhaseFiles[$automatedPhase])
                })
            }
            $automatedHashes.Add([pscustomobject][ordered]@{ phase = 'Complete'; sha256 = Get-CcodOfficialDraftFileSha256 -Path $statePath })
            $writtenAcceptance = Write-CcodOfficialDraftCompleteAcceptance -EvidenceRoot $EvidenceRoot -PreviousAssetDirectory $PreviousAssetDirectory -Candidate $candidate -Draft $draft -ManualEvidence $manual -AutomatedReceiptHashes @($automatedHashes) -CompletedAtUtc $nowValues[0] -Path $acceptancePath -PublishedHash ([ref]$completeAcceptanceHash)
            if (Test-CcodOfficialDraftHash $completeAcceptanceHash) { $completeCleanupExpected[[IO.Path]::GetFullPath($acceptancePath)] = $completeAcceptanceHash }
        } catch {
            $failure = $_
            if ($completeReceiptHash -is [string] -and $completeReceiptHash -cmatch '^[0-9a-f]{64}\z') {
                $completeCleanupExpected[[IO.Path]::GetFullPath($statePath)] = $completeReceiptHash
            }
            if ($completeAcceptanceHash -is [string] -and $completeAcceptanceHash -cmatch '^[0-9a-f]{64}\z') {
                $completeCleanupExpected[[IO.Path]::GetFullPath($acceptancePath)] = $completeAcceptanceHash
            }
            try {
                $ownedPaths = @($acceptancePath,$statePath | Where-Object { $completeCleanupExpected.ContainsKey([IO.Path]::GetFullPath($_)) })
                if ($ownedPaths.Count -gt 0) { [void](Remove-CcodOfficialDraftCompleteArtifacts -Paths $ownedPaths -ExpectedHashes $completeCleanupExpected) }
            } catch {
                Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_COMPLETE_CLEANUP_FAILED' 'Complete acceptance cleanup failed and terminal evidence may remain.' $null
            }
            throw $failure
        }
        return [pscustomobject][ordered]@{ phase = 'Complete'; outcome = 'Complete'; complete = $true; candidate = $written.candidate; facts = $written.facts }
    }
    Throw-CcodOfficialDraftError 'CCOD_ACCEPTANCE_NOT_IMPLEMENTED' 'The official-draft acceptance state machine phase is not implemented.' $Phase
    } finally { Close-CcodOfficialDraftOperationLease $operationLease }
}

function Invoke-CcodOfficialDraftAcceptance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Preflight','LegacyUpgrade','Uninstall','FreshInstall','PreReboot','PostReboot','ReadyForManualEvidence','TrayEvidence','RemoteEvidence','Complete')][string]$Phase,
        [Parameter(Mandatory)][string]$AssetDirectory,
        [Parameter(Mandatory)][string]$PreviousAssetDirectory,
        [Parameter(Mandatory)][string]$EvidenceRoot,
        [string]$DraftId,
        [switch]$AllowMachineMutation,
        [switch]$AllowCodexRestart,
        [switch]$AllowWindowsReboot,
        [ValidateSet('About','Language','OpenLogs','Repair')][string]$TrayOperation,
        [ValidateSet('SecondDeviceControl')][string]$RemoteOperation,
        [string]$ScreenshotPath,
        [string]$RedactedLogPath,
        [ValidateSet('Reviewed')][string]$ReviewState
    )
    Invoke-CcodOfficialDraftAcceptanceCore `
        -Phase $Phase `
        -AssetDirectory $AssetDirectory `
        -PreviousAssetDirectory $PreviousAssetDirectory `
        -EvidenceRoot $EvidenceRoot `
        -DraftId $DraftId `
        -AllowMachineMutation:$AllowMachineMutation `
        -AllowCodexRestart:$AllowCodexRestart `
        -AllowWindowsReboot:$AllowWindowsReboot `
        -TrayOperation $TrayOperation `
        -RemoteOperation $RemoteOperation `
        -ScreenshotPath $ScreenshotPath `
        -RedactedLogPath $RedactedLogPath `
        -ReviewState $ReviewState
}

Export-ModuleMember -Function Invoke-CcodOfficialDraftAcceptance
