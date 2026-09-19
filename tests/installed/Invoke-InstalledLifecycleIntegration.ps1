[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Run')][string]$InstallerPath,
    [Parameter(ParameterSetName = 'Run')][string]$PreviousInstallerPath,
    [Parameter(ParameterSetName = 'Run')][ValidatePattern('^\d+\.\d+\.\d+\z')][string]$PreviousExpectedVersion,
    [Parameter(ParameterSetName = 'Run')][ValidatePattern('^[0-9a-f]{64}\z')][string]$PreviousInstallerSha256,
    [Parameter(ParameterSetName = 'Run')][ValidatePattern('^[0-9a-f]{64}\z')][string]$PreviousManifestSha256,
    [Parameter(Mandatory, ParameterSetName = 'Run')][ValidatePattern('^\d+\.\d+\.\d+\z')][string]$ExpectedVersion,
    [Parameter(Mandatory, ParameterSetName = 'Run')][string]$EvidenceRoot,
    [Parameter(ParameterSetName = 'Run')][Parameter(ParameterSetName = 'VerifiedUninstall')][switch]$AllowMachineMutation,
    [Parameter(ParameterSetName = 'Run')][Parameter(ParameterSetName = 'VerifiedUninstall')][switch]$AllowCodexRestart,
    [Parameter(Mandatory, ParameterSetName = 'Run')][ValidateSet('FreshInstall','FreshLater','FreshRestart','Upgrade','SlowLaunch','ManualLaunchResume','LanguageStress','RepairStates','SafeExit','SettingsUninstall','DirectUninstall')][string]$Scenario,
    [Parameter(Mandatory, ParameterSetName = 'Library')][switch]$Library,
    [Parameter(Mandatory, ParameterSetName = 'VerifiedUninstall')][switch]$VerifiedUninstallChild
)

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

$script:CcodInstalledLifecycleRestartScenarios = @(
    'FreshInstall','FreshRestart','Upgrade','SlowLaunch','ManualLaunchResume','LanguageStress','RepairStates','SafeExit','SettingsUninstall','DirectUninstall'
)
$script:CcodInstalledLifecycleTaskName = 'Codex Control Other Devices Supervisor'
$script:CcodInstalledLifecycleRepositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
# Pin the complete eager import closure, including StateStore's nested identity
# dependency, before any initializer runs. Imports remain in their original scope.
$importClosure = @('PersistenceIO.psm1','StateStore.psm1','TrustedLogonIdentity.psm1','LifecycleTransaction.psm1')
$importLeases = [Collections.Generic.List[IDisposable]]::new()
try {
    foreach ($leaf in $importClosure) {
        $path = Join-Path (Join-Path $script:CcodInstalledLifecycleRepositoryRoot 'src\persistence\modules') $leaf
        $importLeases.Add((Open-CcodTrustedImportLease -Path $path -ErrorId 'CCOD_INTEGRATION_MODULE_MISSING'))
    }
    foreach ($lease in $importLeases) { $lease.Revalidate() }
    $script:CcodInstalledLifecyclePersistenceIoModule = Import-Module (Join-Path $script:CcodInstalledLifecycleRepositoryRoot 'src\persistence\modules\PersistenceIO.psm1') -Force -PassThru
    $script:CcodInstalledLifecycleStateStoreModule = Import-Module (Join-Path $script:CcodInstalledLifecycleRepositoryRoot 'src\persistence\modules\StateStore.psm1') -Force -PassThru
    $script:CcodInstalledLifecycleTransactionModule = Import-Module (Join-Path $script:CcodInstalledLifecycleRepositoryRoot 'src\persistence\modules\LifecycleTransaction.psm1') -Force -PassThru
    foreach ($lease in $importLeases) { $lease.Revalidate() }
} finally {
    for ($index = $importLeases.Count - 1; $index -ge 0; $index--) { $importLeases[$index].Dispose() }
}

function Throw-CcodInstalledLifecycleError {
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

function Get-CcodInstalledLifecycleErrorId {
    param([Parameter(Mandatory)]$ErrorRecord)
    $id = [string]$ErrorRecord.FullyQualifiedErrorId
    if ([string]::IsNullOrWhiteSpace($id)) { return $null }
    return ($id -split ',')[0]
}

function Assert-CcodInstalledLifecycleCanonicalAbsolutePath {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Kind)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathRooted($Path)) {
        Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_OBSERVATION_UNAVAILABLE' "$Kind must be an absolute canonical path" $Path
    }
    try { $full = [IO.Path]::GetFullPath($Path) } catch {
        Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_OBSERVATION_UNAVAILABLE' "$Kind path could not be canonicalized safely" $Path
    }
    if (-not [string]::Equals($full, $Path, [StringComparison]::OrdinalIgnoreCase)) {
        Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_OBSERVATION_UNAVAILABLE' "$Kind must use a canonical path" $Path
    }
    return $full
}

function Get-CcodInstalledLifecycleHash {
    param([Parameter(Mandatory)][string]$Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $stream = [IO.File]::OpenRead($Path)
        try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
        finally { $stream.Dispose() }
    } finally { $sha.Dispose() }
}

function Test-CcodInstalledLifecycleCanonicalUtc {
    param([AllowNull()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    $parsed = [datetime]::MinValue
    if (-not [datetime]::TryParse($Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) { return $false }
    return $parsed.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture) -ceq $Value
}

function Test-CcodInstalledLifecycleValidUtcClock {
    param($Value)
    return $Value -is [datetime] -and $Value.Kind -eq [DateTimeKind]::Utc -and
        $Value -ne [datetime]::MinValue -and $Value -ne [datetime]::MaxValue
}

function ConvertTo-CcodInstalledLifecycleCreationTimeUtc {
    param($Value)
    $created = $null
    if ($Value -is [datetime]) {
        if ($Value.Kind -ne [DateTimeKind]::Local -and $Value.Kind -ne [DateTimeKind]::Utc) {
            Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_FACTS_INVALID' 'An enumerated ChatGPT process has invalid creation-time evidence' $null
        }
        $created = $Value
    } elseif ($Value -is [string]) {
        if ($Value -cnotmatch '^\d{14}\.\d{6}[+-]\d{3}\z') {
            Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_FACTS_INVALID' 'An enumerated ChatGPT process has invalid creation-time evidence' $null
        }
        try {
            $created = [Management.ManagementDateTimeConverter]::ToDateTime($Value)
        } catch {
            Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_FACTS_INVALID' 'An enumerated ChatGPT process has invalid creation-time evidence' $null
        }
    } else {
        Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_FACTS_INVALID' 'An enumerated ChatGPT process has invalid creation-time evidence' $null
    }
    $canonical = $created.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    if (-not (Test-CcodInstalledLifecycleCanonicalUtc -Value $canonical)) {
        Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_FACTS_INVALID' 'An enumerated ChatGPT process creation time is not canonical' $null
    }
    return $canonical
}

function Get-CcodInstalledLifecycleNativeProcessCreationTimeUtc {
    param([Parameter(Mandatory)][int]$ProcessId)
    $process=$null
    try {
        $process=Get-Process -Id $ProcessId -ErrorAction Stop
        if($null-eq$process-or$process.Id-ne$ProcessId-or$process.HasExited){throw 'process not current'}
        $created=$process.StartTime.ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture)
        if(-not(Test-CcodInstalledLifecycleCanonicalUtc $created)){throw 'native timestamp'}
        return $created
    } finally {if($null-ne$process){$process.Dispose()}}
}

function Get-CcodInstalledLifecycleCorrelatedCreationTimeUtc {
    param([Parameter(Mandatory)]$Process)
    try {
        if(-not(Test-CcodInstalledLifecyclePositiveInteger $Process.ProcessId)-or[decimal]$Process.ProcessId-gt[int]::MaxValue){throw 'process id'}
        $cim=ConvertTo-CcodInstalledLifecycleCreationTimeUtc -Value $Process.CreationDate
        $native=Get-CcodInstalledLifecycleNativeProcessCreationTimeUtc -ProcessId ([int]$Process.ProcessId)
        if($native-isnot[string]-or-not(Test-CcodInstalledLifecycleCanonicalUtc $native)){throw 'native timestamp'}
        $style=[Globalization.DateTimeStyles]::RoundtripKind;$culture=[Globalization.CultureInfo]::InvariantCulture
        $cimTicks=[datetime]::ParseExact($cim,'o',$culture,$style).Ticks
        $nativeTicks=[datetime]::ParseExact($native,'o',$culture,$style).Ticks
        if(($cimTicks%10)-eq0){if($nativeTicks-lt$cimTicks-or($nativeTicks-$cimTicks)-gt9){throw 'CIM identity mismatch'}}
        elseif($nativeTicks-ne$cimTicks){throw 'precise identity mismatch'}
        return $native
    } catch {
        Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_OBSERVATION_UNAVAILABLE' 'The native process creation identity does not match the enumerated CIM process.' $null
    }
}

function Test-CcodInstalledLifecycleMissingError {
    param([Parameter(Mandatory)]$ErrorRecord)
    return $ErrorRecord.CategoryInfo.Category -eq 'ObjectNotFound' -or
        $ErrorRecord.Exception -is [IO.FileNotFoundException] -or $ErrorRecord.Exception -is [IO.DirectoryNotFoundException]
}

function Assert-CcodInstalledLifecycleNoReparseAncestors {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][scriptblock]$GetItem)
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    $parent = [IO.Directory]::GetParent($full)
    $current = if ($null -eq $parent) { $null } else { $parent.FullName }
    while (-not [string]::IsNullOrWhiteSpace($current)) {
        try {
            $items = @(& $GetItem $current)
            if ($items.Count -eq 1 -and $null -ne $items[0] -and (-not $items[0].PSIsContainer -or (($items[0].Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0))) { throw 'unsafe ancestry' }
        } catch {
            if (-not (Test-CcodInstalledLifecycleMissingError -ErrorRecord $_)) { throw }
        }
        if ($current.TrimEnd('\') -ceq $root.TrimEnd('\')) { break }
        $nextParent = [IO.Directory]::GetParent($current)
        if ($null -eq $nextParent) { break }
        $next = if ($nextParent.FullName.Length -gt $root.Length) { $nextParent.FullName.TrimEnd('\') } else { $nextParent.FullName }
        if ($next -ceq $current) { break }
        $current = $next
    }
}

function Assert-CcodInstalledLifecycleRegularFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Kind)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathRooted($Path)) {
        Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_CANDIDATE_INVALID' "$Kind must be an absolute path" $Path
    }
    $full = [IO.Path]::GetFullPath($Path)
    if (-not [string]::Equals($full, $Path, [StringComparison]::OrdinalIgnoreCase)) {
        Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_CANDIDATE_INVALID' "$Kind must use a canonical path" $Path
    }
    try { $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop } catch {
        Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_CANDIDATE_INVALID' "$Kind is missing or cannot be inspected" $full
    }
    if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_CANDIDATE_INVALID' "$Kind must be a regular non-reparse file" $full
    }
    Assert-CcodInstalledLifecycleNoReparseAncestors -Path $full -GetItem { param($CandidatePath) Get-Item -LiteralPath $CandidatePath -Force -ErrorAction Stop }
    return $full
}

function Assert-CcodInstalledLifecycleReadableProcessText {
    param([AllowNull()]$Value, [Parameter(Mandatory)][string]$Kind)
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_OBSERVATION_UNAVAILABLE' "$Kind could not be read safely." $null
    }
    return [string]$Value
}

function Assert-CcodInstalledLifecycleSafeDirectory {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Kind)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathRooted($Path)) {
        Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_EVIDENCE_ROOT_INVALID' "$Kind must be an absolute path" $Path
    }
    $full = [IO.Path]::GetFullPath($Path)
    if (-not [string]::Equals($full, $Path, [StringComparison]::OrdinalIgnoreCase)) {
        Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_EVIDENCE_ROOT_INVALID' "$Kind must use a canonical path" $Path
    }
    $probe = { param($CandidatePath) Get-Item -LiteralPath $CandidatePath -Force -ErrorAction Stop }
    $item = $null
    try { $item = & $probe $full } catch {
        if (-not (Test-CcodInstalledLifecycleMissingError -ErrorRecord $_)) {
            Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_EVIDENCE_ROOT_INVALID' "$Kind could not be inspected safely" $full
        }
        try {
            Assert-CcodInstalledLifecycleNoReparseAncestors -Path $full -GetItem $probe
            [IO.Directory]::CreateDirectory($full) | Out-Null
            $item = & $probe $full
        } catch {
            Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_EVIDENCE_ROOT_INVALID' "$Kind could not be created or inspected safely" $full
        }
    }
    Assert-CcodInstalledLifecycleNoReparseAncestors -Path $full -GetItem $probe
    if ($null -eq $item -or -not $item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_EVIDENCE_ROOT_INVALID' "$Kind must be a non-reparse directory" $full
    }
    return $full
}

function Get-CcodInstalledLifecycleOptionalDirectoryState {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][scriptblock]$GetItem)
    $full = Assert-CcodInstalledLifecycleCanonicalAbsolutePath -Path $Path -Kind 'Installed product directory'
    $present = $false
    try {
        $items = @(& $GetItem $full)
        if ($items.Count -eq 1 -and $null -ne $items[0] -and $items[0].PSIsContainer -and
            ($items[0].Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) { $present = $true }
        else { throw 'directory observation' }
    } catch {
        if (-not (Test-CcodInstalledLifecycleMissingError -ErrorRecord $_)) {
            Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_OBSERVATION_UNAVAILABLE' 'An installed product directory could not be inspected safely.' $full
        }
    }
    try { Assert-CcodInstalledLifecycleNoReparseAncestors -Path $full -GetItem $GetItem }
    catch { Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_OBSERVATION_UNAVAILABLE' 'An installed product directory ancestry could not be inspected safely.' $full }
    return $present
}

function Get-CcodInstalledLifecycleOptionalRegularFileState {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][scriptblock]$GetItem)
    $full = Assert-CcodInstalledLifecycleCanonicalAbsolutePath -Path $Path -Kind 'Installed product file'
    $item = $null
    try {
        $items = @(& $GetItem $full)
        if ($items.Count -eq 1 -and $null -ne $items[0] -and -not $items[0].PSIsContainer -and
            ($items[0].Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) { $item = $items[0] }
        else { throw 'file observation' }
    } catch {
        if (-not (Test-CcodInstalledLifecycleMissingError -ErrorRecord $_)) {
            Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_OBSERVATION_UNAVAILABLE' 'An installed product file could not be inspected safely.' $full
        }
    }
    try { Assert-CcodInstalledLifecycleNoReparseAncestors -Path $full -GetItem $GetItem }
    catch { Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_OBSERVATION_UNAVAILABLE' 'An installed product file ancestry could not be inspected safely.' $full }
    return $item
}

function Write-CcodInstalledLifecycleEvidenceFile {
    param([Parameter(Mandatory)][string]$EvidenceDirectory,[Parameter(Mandatory)]$Receipt,[scriptblock]$ReadbackVerifier)
    $directory = Assert-CcodInstalledLifecycleSafeDirectory -Path $EvidenceDirectory -Kind 'Evidence directory'
    $target = [IO.Path]::GetFullPath((Join-Path $directory 'receipt.json'))
    $temporary = "$target.$([guid]::NewGuid().ToString('N')).tmp"
    $published = $false
    try {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($Receipt | ConvertTo-Json -Depth 16))
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $expected = ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() } finally { $sha.Dispose() }
        [IO.File]::WriteAllBytes($temporary, $bytes)
        [IO.File]::Move($temporary, $target)
        $published = $true
        $targetItem = Get-Item -LiteralPath $target -Force -ErrorAction Stop
        if ($targetItem.PSIsContainer -or (($targetItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { throw 'evidence target' }
        if ($null -ne $ReadbackVerifier -and -not [bool](& $ReadbackVerifier $target)) { throw 'evidence readback' }
        $parsed = [IO.File]::ReadAllText($targetItem.FullName, [Text.UTF8Encoding]::new($false, $true)) | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $parsed -or (Get-CcodInstalledLifecycleHash -Path $targetItem.FullName) -cne $expected) { throw 'evidence hash readback' }
        return $target
    } catch {
        $failure = $_
        if ($published) {
            try {
                $item = $null
                try { $item = Get-Item -LiteralPath $target -Force -ErrorAction Stop } catch { if (-not (Test-CcodInstalledLifecycleMissingError -ErrorRecord $_)) { throw } }
                if ($null -ne $item) {
                    if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or (Get-CcodInstalledLifecycleHash -Path $target) -cne $expected) { throw 'evidence cleanup target' }
                    Remove-Item -LiteralPath $target -Force -ErrorAction Stop
                }
                $residual = $null
                try { $residual = Get-Item -LiteralPath $target -Force -ErrorAction Stop } catch { if (-not (Test-CcodInstalledLifecycleMissingError -ErrorRecord $_)) { throw } }
                if ($null -ne $residual) { throw 'evidence cleanup residue' }
            } catch {
                Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_EVIDENCE_CLEANUP_FAILED' 'Failed evidence cleanup left an unverifiable destination.' $target
            }
        }
        Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_EVIDENCE_WRITE_FAILED' 'Installed lifecycle evidence could not be written and read back safely.' $target
    } finally {
        try { $tempItem = Get-Item -LiteralPath $temporary -Force -ErrorAction Stop; if ($null -ne $tempItem) { Remove-Item -LiteralPath $temporary -Force -ErrorAction Stop } } catch { if (-not (Test-CcodInstalledLifecycleMissingError -ErrorRecord $_)) { Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_EVIDENCE_CLEANUP_FAILED' 'Temporary evidence cleanup could not be verified.' $temporary } }
    }
}

function Get-CcodInstalledLifecycleDefaultAdapters {
    $safeDirectory = ${function:Assert-CcodInstalledLifecycleSafeDirectory}
    $hashFunction = ${function:Get-CcodInstalledLifecycleHash}
    $factsFunction = ${function:Get-CcodInstalledLifecycleFacts}
    $writeEvidenceFunction = ${function:Write-CcodInstalledLifecycleEvidenceFile}
    $scenarioFunction = ${function:Invoke-CcodInstalledLifecycleOperatorScenario}
    $verifyScenarioFunction = ${function:Test-CcodInstalledLifecycleScenario}
    $rollbackFunction = ${function:Invoke-CcodInstalledLifecycleRollback}
    $missingFunction = ${function:Test-CcodInstalledLifecycleMissingError}
    $defaults = @{}
    $defaults.GetGitStatus = {
        param($RepositoryRoot)
        $status = & git -C $RepositoryRoot status --porcelain --untracked-files=all --ignored=matching 2>$null
        if ($LASTEXITCODE -ne 0) { throw [InvalidOperationException]::new('git status could not determine checkout cleanliness') }
        return @($status | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    }.GetNewClosure()
    $defaults.GetFileSha256 = { param($Path) & $hashFunction -Path $Path }.GetNewClosure()
    $defaults.ReadText = { param($Path) [IO.File]::ReadAllText($Path) }.GetNewClosure()
    $defaults.NewEvidenceDirectory = {
        param($Root, $TransactionId)
        $safeRoot = & $safeDirectory -Path $Root -Kind 'Evidence root'
        $directory = [IO.Path]::GetFullPath((Join-Path $safeRoot ('installed-lifecycle-' + $TransactionId)))
        $probe = { param($CandidatePath) Get-Item -LiteralPath $CandidatePath -Force -ErrorAction Stop }
        try {
            $existing = & $probe $directory
            if ($null -ne $existing) { Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_EVIDENCE_EXISTS' 'The generated evidence directory already exists' $directory }
        } catch {
            if (-not (& $missingFunction -ErrorRecord $_)) { throw }
        }
        [IO.Directory]::CreateDirectory($directory) | Out-Null
        return & $safeDirectory -Path $directory -Kind 'Evidence directory'
    }.GetNewClosure()
    $defaults.WriteEvidence = {
        param($EvidenceDirectory, $Receipt, $ReadbackVerifier)
        & $writeEvidenceFunction -EvidenceDirectory $EvidenceDirectory -Receipt $Receipt -ReadbackVerifier $ReadbackVerifier
    }.GetNewClosure()
    $defaults.CaptureFacts = { param($InstallRoot,$ExpectedVersion) & $factsFunction -InstallRoot $InstallRoot -ExpectedVersion $ExpectedVersion }.GetNewClosure()
    $defaults.CreateRollbackSnapshot = {
        param($Context, $Facts)
        return [pscustomobject][ordered]@{ kind = 'observation'; transactionId = $Context.transactionId; beforeFacts = $Facts }
    }.GetNewClosure()
    $defaults.RunScenario = { param($Context) & $scenarioFunction -Context $Context }.GetNewClosure()
        $defaults.VerifyScenario = { param($Context, $BeforeFacts, $RunResult) & $verifyScenarioFunction -Context $Context -BeforeFacts $BeforeFacts -RunResult $RunResult }.GetNewClosure()
        $defaults.Rollback = { param($Context, $Snapshot) & $rollbackFunction -Context $Context -Snapshot $Snapshot }.GetNewClosure()
    $defaults.CleanupRollback = { param($Context, $Snapshot) return $true }.GetNewClosure()
    $defaults.GetUtcNow = { [datetime]::UtcNow }.GetNewClosure()
    return $defaults
}

function Resolve-CcodInstalledLifecycleAdapters {
    param([hashtable]$Adapters)
    $resolved = Get-CcodInstalledLifecycleDefaultAdapters
    if ($null -eq $Adapters) { return $resolved }
    foreach ($name in $Adapters.Keys) {
        if (-not $resolved.ContainsKey([string]$name) -or $Adapters[$name] -isnot [scriptblock]) {
            Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_ADAPTER_INVALID' 'Installed lifecycle test adapters must replace known scriptblock adapters only' $name
        }
        $resolved[[string]$name] = $Adapters[$name]
    }
    return $resolved
}

function Get-CcodInstalledLifecycleExecutionAssetModule {
    $path = Join-Path $script:CcodInstalledLifecycleRepositoryRoot 'tools\ReleaseAssetContract.psm1'
    $lease = Open-CcodTrustedImportLease -Path $path -ErrorId 'CCOD_INTEGRATION_MODULE_MISSING'
    try {
        $lease.Revalidate()
        $module = Import-Module $path -PassThru -DisableNameChecking -ErrorAction Stop
        $lease.Revalidate()
        return $module
    } finally { $lease.Dispose() }
}

function Close-CcodInstalledLifecycleExecutionLease {
    param($Lease)
    if ($null -eq $Lease -or $Lease.Closed) { return }
    for ($index = $Lease.Files.Count - 1; $index -ge 0; $index--) { $Lease.Files[$index].Stream.Dispose() }
    for ($index = $Lease.Parents.Count - 1; $index -ge 0; $index--) { $Lease.Parents[$index].Handle.Dispose() }
    $Lease.Closed = $true
}

function Assert-CcodInstalledLifecycleExecutionLease {
    param([Parameter(Mandatory)]$Lease)
    try {
        if ($Lease.Closed) { throw 'closed execution authority' }
        foreach ($entry in @($Lease.Parents) + @($Lease.Files)) {
            $handle = if ($entry.Directory) { $entry.Handle } else { $entry.Stream.SafeFileHandle }
            $current = [CcodReleaseFileAuthorityV1]::Identity($handle)
            if ([CcodReleaseFileAuthorityV1]::IsReparse($current) -or [CcodReleaseFileAuthorityV1]::IsDirectory($current) -ne $entry.Directory -or
                $current.Volume -ne $entry.Identity.Volume -or $current.FileId -ne $entry.Identity.FileId -or
                -not $current.FinalPath.TrimEnd('\').Equals($entry.Path.TrimEnd('\'),[StringComparison]::OrdinalIgnoreCase)) { throw 'execution identity changed' }
            if (-not $entry.Directory) {
                if ($current.Links -ne 1 -or $current.Attributes -ne $entry.Identity.Attributes -or $entry.Stream.Length -ne $entry.Length -or
                    -not (& $Lease.Module {param($Value) Test-CcodReleaseAuthorityStreams -Identity $Value -AllowZone} $current) -or
                    (& $Lease.Module {param($Stream) Get-CcodReleaseAuthorityStreamSha256 -Stream $Stream} $entry.Stream) -cne $entry.Sha256) { throw 'execution bytes changed' }
            }
        }
    } catch { Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_CANDIDATE_INVALID' 'Held execution files changed or became unavailable.' $null }
}

function Open-CcodInstalledLifecycleExecutionLease {
    param([Parameter(Mandatory)][string[]]$Paths)
    $lease = [pscustomobject]@{ Module = (Get-CcodInstalledLifecycleExecutionAssetModule); Files = [Collections.Generic.List[object]]::new(); Parents = [Collections.Generic.List[object]]::new(); Closed = $false }
    try {
        if ($Paths.Count -eq 0) { throw 'execution paths empty' }
        $seenParents = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $seenFiles = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($path in $Paths) {
            $full = Assert-CcodInstalledLifecycleCanonicalAbsolutePath -Path $path -Kind 'Execution file'
            if (-not $seenFiles.Add($full)) { throw 'duplicate execution file' }
            $parents = [Collections.Generic.List[string]]::new()
            for ($parent = [IO.Directory]::GetParent($full); $null -ne $parent; $parent = $parent.Parent) { $parents.Insert(0,$parent.FullName) }
            foreach ($directory in $parents) {
                if (-not $seenParents.Add($directory)) { continue }
                $handle = [CcodReleaseFileAuthorityV1]::OpenDirectory($directory,$true)
                $entry = [pscustomobject]@{ Directory = $true; Path = $directory; Handle = $handle; Identity = $null }
                $lease.Parents.Add($entry)
                $entry.Identity = [CcodReleaseFileAuthorityV1]::Identity($handle)
                if ([CcodReleaseFileAuthorityV1]::IsReparse($entry.Identity) -or -not [CcodReleaseFileAuthorityV1]::IsDirectory($entry.Identity) -or
                    -not $entry.Identity.FinalPath.TrimEnd('\').Equals($directory.TrimEnd('\'),[StringComparison]::OrdinalIgnoreCase)) { throw 'execution ancestor' }
            }
            $stream = [CcodReleaseFileAuthorityV1]::OpenReadFile($full,$false)
            $entry = [pscustomobject]@{ Directory = $false; Path = $full; Stream = $stream; Identity = $null; Length = $stream.Length; Sha256 = $null }
            $lease.Files.Add($entry)
            $entry.Identity = [CcodReleaseFileAuthorityV1]::Identity($stream.SafeFileHandle)
            if ($entry.Length -lt 1 -or $entry.Length -gt 536870912) { throw 'execution bounds' }
            $entry.Sha256 = & $lease.Module {param($Stream) Get-CcodReleaseAuthorityStreamSha256 -Stream $Stream} $stream
        }
        Assert-CcodInstalledLifecycleExecutionLease $lease
        return $lease
    } catch {
        Close-CcodInstalledLifecycleExecutionLease $lease
        Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_CANDIDATE_INVALID' 'Execution file authority could not be acquired safely.' $null
    }
}

function Get-CcodInstalledLifecycleCandidate {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$ExpectedVersion,
        [Parameter(Mandatory)][hashtable]$Adapters,
        [Parameter(Mandatory)][string]$Kind,
        [switch]$AllowAnyVersion,
        [ref]$ExecutionLease
    )
    $installer = Assert-CcodInstalledLifecycleRegularFile -Path $Path -Kind $Kind
    $leaf = [IO.Path]::GetFileName($installer)
    $versionMatch = [regex]::Match($leaf, '^CodexRemote-fix-(\d+\.\d+\.\d+)-setup\.exe\z')
    if (-not $versionMatch.Success -or (-not $AllowAnyVersion -and ([string]::IsNullOrWhiteSpace($ExpectedVersion) -or $versionMatch.Groups[1].Value -cne $ExpectedVersion))) {
        Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_CANDIDATE_INVALID' "$Kind filename does not bind the expected version" $installer
    }
    $executionPaths = @($installer,"$installer.sha256.txt")
    if ($Kind -ceq 'Installer') {
        if ([version]$versionMatch.Groups[1].Value -ge [version]'2.5.22') {
            $executionModule = Get-CcodInstalledLifecycleExecutionAssetModule
            $executionNames = @(& $executionModule {param($Version) Get-CcodExpectedReleaseAssetNames -Version $Version} $versionMatch.Groups[1].Value)
            $executionPaths = @($executionNames | ForEach-Object { Join-Path (Split-Path $installer -Parent) $_ })
        } else { $executionPaths += Join-Path (Split-Path $installer -Parent) ("CodexRemote-fix-{0}-setup-payload-manifest.json" -f $versionMatch.Groups[1].Value) }
    }
    $heldExecution = Open-CcodInstalledLifecycleExecutionLease -Paths $executionPaths
    $transferred = $false
    try {
    $checksum = Assert-CcodInstalledLifecycleRegularFile -Path "$installer.sha256.txt" -Kind "$Kind checksum"
    $text = & $Adapters.ReadText $checksum
    if ($text -isnot [string]) {
        Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_CHECKSUM_INVALID' "$Kind checksum could not be read as text" $checksum
    }
    $normalized = $text.TrimEnd("`r", "`n")
    $match = [regex]::Match($normalized, '^([0-9a-f]{64}) \*([^\r\n]+)$')
    if (-not $match.Success -or $match.Groups[2].Value -cne [IO.Path]::GetFileName($installer)) {
        Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_CHECKSUM_INVALID' "$Kind checksum is malformed or names a different asset" $checksum
    }
    $actualHash = [string](& $Adapters.GetFileSha256 $installer)
    if ($actualHash -cnotmatch '^[0-9a-f]{64}\z' -or $actualHash -cne $match.Groups[1].Value) {
        Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_CHECKSUM_INVALID' "$Kind checksum does not match the exact installer bytes" $installer
    }
    $payloadManifestPath = $null
    $payloadManifestHash = $null
    $payloadFiles = @()
    $candidateCommit = $null
    $candidateAssets = @()
    if ($Kind -ceq 'Installer') {
        $payloadManifestPath = Assert-CcodInstalledLifecycleRegularFile -Path (Join-Path (Split-Path $installer -Parent) ("CodexRemote-fix-{0}-setup-payload-manifest.json" -f $versionMatch.Groups[1].Value)) -Kind "$Kind payload manifest"
        if ([version]$versionMatch.Groups[1].Value -ge [version]'2.5.22') {
            $lease=$null;$authority=$null;$contractModule=$null
            try {
                $contractPath=Join-Path $script:CcodInstalledLifecycleRepositoryRoot 'tools\ReleaseAssetContract.psm1'
                $lease=Open-CcodTrustedImportLease -Path $contractPath -ErrorId 'CCOD_INTEGRATION_MODULE_MISSING'
                $lease.Revalidate();$contractModule=Import-Module $contractPath -PassThru -ErrorAction Stop;$lease.Revalidate()
                $directory=Split-Path $installer -Parent
                $authority=&$contractModule {param($Directory,$Version)Open-CcodExactReleaseAssetAuthority -AssetDirectory $Directory -Version $Version -ErrorId 'CCOD_INTEGRATION_CANDIDATE_INVALID'} $directory $versionMatch.Groups[1].Value
                $contract=&$contractModule {param($Directory,$Version)Test-CcodExactReleaseAssetSet -AssetDirectory $Directory -Version $Version} $directory $versionMatch.Groups[1].Value
                if($contract.Valid-isnot[bool]-or-not$contract.Valid-or$authority.Files[5].Sha256-cne$actualHash){throw 'sealed installer binding'}
                $package=&$contractModule {param($File)(Read-CcodReleaseContractPinnedJson -Authority $File -ErrorId 'CCOD_INTEGRATION_CANDIDATE_INVALID').Value} $authority.Files[8]
                $payloadFiles=@($package.files)
                if($payloadFiles.Count-eq0-or-not(Test-CcodInstalledLifecycleFileRecordSet -Actual $payloadFiles -Expected $payloadFiles)){throw 'sealed payload records'}
                $payloadManifestHash=[string]$authority.Files[8].Sha256
                $candidateCommit=$contract.GitCommit
                $candidateAssets=@($authority.Files | ForEach-Object { [pscustomobject][ordered]@{ name=$_.Leaf; sha256=$_.Sha256 } })
                &$contractModule {param($Authority)Assert-CcodExactReleaseAssetAuthorityCurrent -Authority $Authority -ErrorId 'CCOD_INTEGRATION_CANDIDATE_INVALID'|Out-Null} $authority
                $lease.Revalidate()
            } catch {
                Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_CANDIDATE_INVALID' 'The sealed installer payload is not bound to the complete release asset contract.' $payloadManifestPath
            } finally {
                if($null-ne$authority){&$contractModule {param($Authority)Close-CcodExactReleaseAssetAuthority $Authority} $authority}
                if($null-ne$lease){$lease.Dispose()}
            }
        } else {
        $payloadText = & $Adapters.ReadText $payloadManifestPath
        try {
            $payloadUnique = & $script:CcodInstalledLifecyclePersistenceIoModule { param($Json) Test-CcodJsonHasNoDuplicateProperties -Json $Json } $payloadText
            $payloadManifest = $payloadText | ConvertFrom-Json -ErrorAction Stop
        } catch { Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_CANDIDATE_INVALID' 'Installer payload manifest is malformed.' $payloadManifestPath }
        if ($payloadText -isnot [string] -or -not $payloadUnique -or -not (Test-CcodInstalledLifecycleExactProperties -Value $payloadManifest -Expected @('schemaVersion','projectVersion','files')) -or
            $payloadManifest.schemaVersion -isnot [int] -or $payloadManifest.schemaVersion -ne 1 -or $payloadManifest.projectVersion -isnot [string] -or $payloadManifest.projectVersion -cne $versionMatch.Groups[1].Value) {
            Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_CANDIDATE_INVALID' 'Installer payload manifest is not bound to the candidate version.' $payloadManifestPath
        }
        $payloadFiles = @($payloadManifest.files)
        if ($payloadFiles.Count -eq 0 -or -not (Test-CcodInstalledLifecycleFileRecordSet -Actual $payloadFiles -Expected $payloadFiles)) {
            Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_CANDIDATE_INVALID' 'Installer payload manifest file records are not canonical.' $payloadManifestPath
        }
        $payloadManifestHash = [string](& $Adapters.GetFileSha256 $payloadManifestPath)
        if ($payloadManifestHash -cnotmatch '^[0-9a-f]{64}\z') { Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_CANDIDATE_INVALID' 'Installer payload manifest hash is invalid.' $payloadManifestPath }
        }
    }
    Assert-CcodInstalledLifecycleExecutionLease $heldExecution
    if ($null -ne $ExecutionLease) { $ExecutionLease.Value = $heldExecution; $transferred = $true }
    return [pscustomobject][ordered]@{ Path = $installer; Version = $versionMatch.Groups[1].Value; Sha256 = $actualHash; ChecksumPath = $checksum; PayloadManifestPath = $payloadManifestPath; PayloadManifestSha256 = $payloadManifestHash; PayloadFiles = @($payloadFiles); GitCommit = $candidateCommit; AssetHashes = @($candidateAssets) }
    } finally { if (-not $transferred) { Close-CcodInstalledLifecycleExecutionLease $heldExecution } }
}

function Assert-CcodInstalledLifecycleExpectedCandidate {
    param([Parameter(Mandatory)]$Candidate,$Expected)
    try {
        if (-not (Test-CcodInstalledLifecycleExactProperties $Expected @('version','gitCommit','assetHashes','manifestHashes')) -or
            $Expected.version -isnot [string] -or $Expected.version -cne $Candidate.Version -or
            $Expected.gitCommit -isnot [string] -or $Expected.gitCommit -cnotmatch '^[0-9a-f]{40}\z' -or
            $Expected.gitCommit -cne $Candidate.GitCommit -or $Expected.assetHashes -isnot [array] -or
            $Expected.assetHashes.Count -ne 11 -or $Candidate.AssetHashes.Count -ne 11) { throw 'candidate metadata' }
        for ($index=0; $index -lt 11; $index++) {
            $asset=$Expected.assetHashes[$index];$actual=$Candidate.AssetHashes[$index]
            if (-not (Test-CcodInstalledLifecycleExactProperties $asset @('name','sha256')) -or
                $asset.name -isnot [string] -or $asset.name -cne $actual.name -or
                $asset.sha256 -isnot [string] -or $asset.sha256 -cnotmatch '^[0-9a-f]{64}\z' -or $asset.sha256 -cne $actual.sha256) { throw 'candidate asset' }
        }
        if (-not (Test-CcodInstalledLifecycleExactProperties $Expected.manifestHashes @('portable','setup')) -or
            $Expected.manifestHashes.portable -isnot [string] -or $Expected.manifestHashes.portable -cne $Candidate.AssetHashes[4].sha256 -or
            $Expected.manifestHashes.setup -isnot [string] -or $Expected.manifestHashes.setup -cne $Candidate.AssetHashes[10].sha256 -or
            $Candidate.Sha256 -cne $Expected.assetHashes[5].sha256) { throw 'candidate manifest' }
    } catch { Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_CANDIDATE_MISMATCH' 'The held installer does not match the original acceptance candidate.' $null }
}

function Get-CcodInstalledLifecycleLegacyTrayReadyProof {
    param([Parameter(Mandatory)][string]$InstallRoot,[Parameter(Mandatory)][string]$RuntimeId,[Parameter(Mandatory)]$Supervisor,[Parameter(Mandatory)]$TrayHost)
    $lease=$null;$event=$null
    try {
        if($RuntimeId-cnotmatch '^2\.5\.21-[0-9a-f]{16}\z'-or@($Supervisor).Count-ne1-or@($TrayHost).Count-ne1){throw 'legacy identity profile'}
        $root=Assert-CcodInstalledLifecycleCanonicalAbsolutePath -Path $InstallRoot -Kind 'Legacy install root'
        $runtimeRoot=Join-Path (Join-Path $root 'runtime') $RuntimeId
        $scriptPath=[IO.Path]::GetFullPath((Join-Path $runtimeRoot 'src\persistence\Supervisor.ps1'))
        $hostPath=[IO.Path]::GetFullPath((Join-Path $runtimeRoot 'bin\CodexRemote.TrayHost.exe'))
        $powershellPath=[IO.Path]::GetFullPath((Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'))
        $current=[Diagnostics.Process]::GetCurrentProcess();try{$sessionId=$current.SessionId}finally{$current.Dispose()}
        $windowsIdentity=[Security.Principal.WindowsIdentity]::GetCurrent();try{$sid=$windowsIdentity.User.Value}finally{$windowsIdentity.Dispose()}
        $parentIdentity=@(ConvertTo-CcodInstalledLifecycleIdentities -Records $Supervisor -Kind 'Legacy supervisor')[0]
        $hostIdentity=@(ConvertTo-CcodInstalledLifecycleIdentities -Records $TrayHost -Kind 'Legacy tray')[0]
        $readSnapshot={
            $parents=@(Get-CimInstance -ClassName Win32_Process -Filter ('ProcessId = '+$parentIdentity.pid) -ErrorAction Stop)
            $hosts=@(Get-CimInstance -ClassName Win32_Process -Filter ('ProcessId = '+$hostIdentity.pid) -ErrorAction Stop)
            if($parents.Count-ne1-or$hosts.Count-ne1){throw 'legacy process count'}
            $parent=$parents[0];$child=$hosts[0]
            foreach($entry in @(@($parent,$parentIdentity,'powershell.exe',$powershellPath),@($child,$hostIdentity,'CodexRemote.TrayHost.exe',$hostPath))){
                $process=$entry[0];$expected=$entry[1]
                if($process.Name-isnot[string]-or$process.Name-cne$entry[2]-or
                    -not(Test-CcodInstalledLifecyclePositiveInteger $process.ProcessId)-or[long]$process.ProcessId-ne$expected.pid-or
                    (Get-CcodInstalledLifecycleCorrelatedCreationTimeUtc -Process $process)-cne$expected.creationTimeUtc-or
                    -not(Test-CcodInstalledLifecyclePositiveInteger $process.SessionId -AllowZero)-or[long]$process.SessionId-ne$sessionId-or
                    $process.ExecutablePath-isnot[string]-or$process.ExecutablePath-ine$entry[3]-or
                    $process.CommandLine-isnot[string]-or[string]::IsNullOrWhiteSpace($process.CommandLine)){throw 'legacy process identity'}
            }
            if(-not(Test-CcodInstalledLifecyclePositiveInteger $child.ParentProcessId)-or[long]$child.ParentProcessId-ne$parentIdentity.pid){throw 'legacy parent pid'}
            Initialize-CcodInstalledLifecycleCommandLineParser
            $parentArgs=@([CcodInstalledLifecycleCommandLine]::Parse($parent.CommandLine))
            $childArgs=@([CcodInstalledLifecycleCommandLine]::Parse($child.CommandLine))
            if($parentArgs.Count-ne9-or$parentArgs[0]-ine$powershellPath-or
                ($parentArgs[1..5]-join',')-cne'-NoProfile,-ExecutionPolicy,Bypass,-STA,-File'-or
                $parentArgs[6]-ine$scriptPath-or$parentArgs[7]-cne'-ReadyToken'-or$parentArgs[8]-cnotmatch'^[0-9a-f]{64}\z'){throw 'legacy supervisor argv'}
            $parentCreated=[datetime]::ParseExact($parentIdentity.creationTimeUtc,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
            $expectedChild=@($hostPath,'--child','--parent-pid',$parentIdentity.pid.ToString([Globalization.CultureInfo]::InvariantCulture),'--parent-created',$parentCreated.ToFileTimeUtc().ToString([Globalization.CultureInfo]::InvariantCulture),'--runtime-id',$RuntimeId)
            if($childArgs.Count-ne$expectedChild.Count-or$childArgs[0]-ine$hostPath-or($childArgs[1..7]-join[char]0)-cne($expectedChild[1..7]-join[char]0)){throw 'legacy host argv'}
            $status=Read-CcodInstalledLifecycleStatusFact -StateRoot (Join-Path $root 'state')
            $active=Read-CcodInstalledLifecycleActiveFact -InstallRoot $root
            if($null-eq$active-or$active.activeRuntime-cne$RuntimeId-or$null-eq$status-or$null-eq$status.session-or$status.session.supervisorPid-ne$parentIdentity.pid-or
                $status.session.supervisorCreationTimeUtc-cne$parentIdentity.creationTimeUtc-or$status.session.runtimeId-cne$RuntimeId-or
                $status.session.sessionId-cne$sessionId.ToString([Globalization.CultureInfo]::InvariantCulture)-or$status.session.sessionState-cne'Active'){throw 'legacy status identity'}
            return [string]$parentArgs[8]
        }
        $token=&$readSnapshot
        $manifestPath=Assert-CcodInstalledLifecycleRegularFile -Path (Join-Path $runtimeRoot 'manifest.json') -Kind 'Legacy runtime manifest'
        $manifestHash=Get-CcodInstalledLifecycleHash $manifestPath
        $manifest=Read-CcodInstalledLifecycleStrictJson -Path $manifestPath -ExpectedSchema 1 -Kind 'Legacy runtime manifest'
        [void](Assert-CcodInstalledLifecycleRuntimeManifest -Manifest $manifest -ExpectedVersion '2.5.21' -ExpectedRuntimeId $RuntimeId -RuntimeRoot $runtimeRoot)
        foreach($required in @('bin/CodexRemote.TrayHost.exe','src/persistence/Supervisor.ps1')){if(@($manifest.files|Where-Object {$_.path-ceq$required}).Count-ne1){throw 'legacy required runtime file'}}
        $kernelPath=Join-Path $script:CcodInstalledLifecycleRepositoryRoot 'src\persistence\modules\KernelObjects.psm1'
        $lease=Open-CcodTrustedImportLease -Path $kernelPath -ErrorId 'CCOD_INTEGRATION_MODULE_MISSING'
        $lease.Revalidate();$kernel=Import-Module $kernelPath -PassThru -ErrorAction Stop;$lease.Revalidate()
        $event=&$kernel {param($Sid,$Session,$Token)Open-CcodEvent -Kind Ready -UserSid $Sid -SessionId $Session -ReadyToken $Token} $sid $sessionId $token
        if($event.Handle-isnot[Threading.EventWaitHandle]-or$event.CreatedNew-isnot[bool]-or$event.CreatedNew){throw 'legacy existing event'}
        $ready=$event.Handle.WaitOne(0)
        if((&$readSnapshot)-cne$token-or(Get-CcodInstalledLifecycleHash $manifestPath)-cne$manifestHash){throw 'legacy observation drift'}
        $lease.Revalidate()
        return [bool]$ready
    } catch {
        Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_OBSERVATION_UNAVAILABLE' 'Legacy readiness is not bound to the current runtime, parent, host and protected startup event.' $RuntimeId
    } finally {
        if($null-ne$event-and$null-ne$event.Handle){$event.Handle.Dispose()}
        if($null-ne$lease){$lease.Dispose()}
    }
}

function Get-CcodInstalledLifecycleTrayHostReadyProof {
    param([Parameter(Mandatory)][string]$InstallRoot,[Parameter(Mandatory)][string]$RuntimeId,[Parameter(Mandatory)]$TrayHost)
    if (@($TrayHost).Count -ne 1) { return $false }
    if ($RuntimeId -cmatch '^2\.5\.21-[0-9a-f]{16}\z') {
        $status=Read-CcodInstalledLifecycleStatusFact -StateRoot (Join-Path $InstallRoot 'state')
        if($null-eq$status-or$null-eq$status.session){return $false}
        $parent=@([pscustomobject]@{Pid=$status.session.supervisorPid;CreationTimeUtc=$status.session.supervisorCreationTimeUtc})
        return Get-CcodInstalledLifecycleLegacyTrayReadyProof -InstallRoot $InstallRoot -RuntimeId $RuntimeId -Supervisor $parent -TrayHost $TrayHost
    }
    $logPath = Join-Path $InstallRoot 'logs\supervisor.log'
    $logItem = Get-CcodInstalledLifecycleOptionalRegularFileState -Path $logPath -GetItem { param($CandidatePath) Get-Item -LiteralPath $CandidatePath -Force -ErrorAction Stop }
    if ($null -eq $logItem) { return $false }
    try {
        $text = [IO.File]::ReadAllText($logItem.FullName,[Text.UTF8Encoding]::new($false,$true))
        $matches = [Collections.Generic.List[object]]::new()
        foreach ($line in @($text -split "`r?`n")) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $unique = & $script:CcodInstalledLifecyclePersistenceIoModule { param($Json) Test-CcodJsonHasNoDuplicateProperties -Json $Json } $line
            if (-not $unique) { throw 'ready log duplicate properties' }
            $record = $line | ConvertFrom-Json -ErrorAction Stop
            if ($record.stage -isnot [string]) { throw 'supervisor log stage' }
            if ($record.stage -cne 'TrayHostReady') {
                $fields = @('schemaVersion','timestampUtc','component','stage','code','outcome')
                if ($record.stage -ceq 'TrayAction') {
                    $fields += @('command','revision','status')
                    if ($record.command -isnot [string] -or [string]::IsNullOrWhiteSpace($record.command) -or
                        -not (Test-CcodInstalledLifecyclePositiveInteger $record.revision) -or
                        $record.status -isnot [string] -or @('Completed','Rejected','Failed') -cnotcontains $record.status -or
                        $record.outcome -cne $record.status -or
                        ($record.status -ceq 'Completed' -and $record.code -cne 'CCOD_TRAY_ACTION_COMPLETED')) { throw 'tray action log shape' }
                } elseif (@('LeaseAcquire','RendererHandoff','SafeExitRecovery','LanguageChange','ErrorDialog','TrayCallback') -ccontains $record.stage) {
                    $expectedEvent = switch -CaseSensitive ($record.stage) {
                        'LeaseAcquire' { @('CCOD_SUPERVISOR_LEASE_ABANDONED','Warning') }
                        'RendererHandoff' { @('CCOD_RENDERER_HANDOFF_FAILED','Failed') }
                        'SafeExitRecovery' { @('CCOD_SUPERVISOR_SAFE_EXIT_RECOVERY_PERSIST_FAILED','Failed') }
                        'LanguageChange' { @('CCOD_LANGUAGE_CHANGE_ROLLED_BACK','Failed') }
                        'ErrorDialog' { @('CCOD_TRAY_ACTION_RESULT_FAILED','Failed') }
                        'TrayCallback' { @('CCOD_TRAY_CALLBACK_FAILED','Failed') }
                    }
                    if ($record.code -cne $expectedEvent[0] -or $record.outcome -cne $expectedEvent[1]) { throw 'supervisor event log shape' }
                } else { throw 'unsupported supervisor log stage' }
                if (-not (Test-CcodInstalledLifecycleExactProperties -Value $record -Expected $fields) -or
                    $record.schemaVersion -isnot [int] -or $record.schemaVersion -ne 1 -or
                    $record.timestampUtc -isnot [string] -or -not (Test-CcodInstalledLifecycleCanonicalUtc $record.timestampUtc) -or
                    $record.component -isnot [string] -or $record.component -cne 'Supervisor' -or
                    $record.code -isnot [string] -or -not [regex]::IsMatch($record.code,'^CCOD_[A-Z0-9_]{1,91}\z') -or
                    $record.outcome -isnot [string]) { throw 'supervisor log frame' }
                continue
            }
            if (-not (Test-CcodInstalledLifecycleExactProperties -Value $record -Expected @('schemaVersion','timestampUtc','component','stage','code','outcome','runtimeId','hostPid','hostCreationTimeUtc','protocolMajor','capabilities')) -or
                $record.schemaVersion -isnot [int] -or $record.schemaVersion -ne 1 -or
                $record.timestampUtc -isnot [string] -or -not (Test-CcodInstalledLifecycleCanonicalUtc $record.timestampUtc) -or
                $record.component -isnot [string] -or $record.component -cne 'Supervisor' -or
                $record.stage -isnot [string] -or $record.stage -cne 'TrayHostReady' -or
                $record.code -isnot [string] -or $record.code -cne 'CCOD_TRAYHOST_READY' -or
                $record.outcome -isnot [string] -or $record.outcome -cne 'Completed' -or
                $record.runtimeId -isnot [string] -or [string]::IsNullOrWhiteSpace($record.runtimeId) -or
                $record.hostPid -isnot [int] -or $record.hostPid -le 0 -or
                $record.hostCreationTimeUtc -isnot [string] -or -not (Test-CcodInstalledLifecycleCanonicalUtc $record.hostCreationTimeUtc) -or
                (($record.protocolMajor -isnot [int]) -and ($record.protocolMajor -isnot [uint16])) -or $record.protocolMajor -ne 2 -or
                (($record.capabilities -isnot [int]) -and ($record.capabilities -isnot [long]) -and ($record.capabilities -isnot [uint64])) -or [uint64]$record.capabilities -eq 0) { throw 'ready log shape' }
            if ($record.runtimeId -ceq $RuntimeId -and $record.hostPid -eq [int]$TrayHost[0].Pid -and $record.hostCreationTimeUtc -ceq [string]$TrayHost[0].CreationTimeUtc) { $matches.Add($record) }
        }
        return $matches.Count -gt 0
    } catch {
        if ($_.FullyQualifiedErrorId -like 'CCOD_INTEGRATION_*') { throw }
        Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_OBSERVATION_UNAVAILABLE' 'TrayHost readiness evidence could not be read safely.' $logPath
    }
}

function ConvertTo-CcodInstalledLifecycleIdentities {
    param($Records, [Parameter(Mandatory)][string]$Kind)
    $result = [Collections.Generic.List[object]]::new()
    foreach ($record in @($Records)) {
        if ($null -eq $record -or $record.Pid -isnot [int] -or [int]$record.Pid -le 0 -or
            $record.CreationTimeUtc -isnot [string] -or -not (Test-CcodInstalledLifecycleCanonicalUtc $record.CreationTimeUtc)) {
            Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_FACTS_INVALID' "$Kind process identity is malformed" $record
        }
        $result.Add([pscustomobject][ordered]@{ pid = [int]$record.Pid; creationTimeUtc = [string]$record.CreationTimeUtc })
    }
    return @($result | Sort-Object pid, creationTimeUtc)
}

function Test-CcodInstalledLifecycleExactProperties {
    param($Value, [Parameter(Mandatory)][string[]]$Expected)
    if ($null -eq $Value -or ($Value -isnot [pscustomobject] -and $Value -isnot [Collections.IDictionary])) { return $false }
    if ($Value -is [Collections.IDictionary]) { $actual = @($Value.Keys | ForEach-Object { [string]$_ }) }
    else { $actual = @($Value.PSObject.Properties.Name) }
    return $actual.Count -eq $Expected.Count -and ($actual -join "`0") -ceq ($Expected -join "`0")
}

function Get-CcodInstalledLifecycleProductState {
    param([Parameter(Mandatory)][string]$RuntimeId)
    $lease=$null
    try {
        $path=Join-Path $script:CcodInstalledLifecycleRepositoryRoot 'src\persistence\modules\ProductRegistration.psm1'
        $lease=Open-CcodTrustedImportLease -Path $path -ErrorId 'CCOD_INTEGRATION_MODULE_MISSING'
        $lease.Revalidate();$module=Import-Module $path -PassThru -DisableNameChecking -ErrorAction Stop;$lease.Revalidate()
        $values=@(&$module {param($Id)Read-CcodCurrentProductState -ExpectedRuntimeId $Id} $RuntimeId)
        $lease.Revalidate()
        if($values.Count-ne1){throw 'product state count'}
        return $values[0]
    } finally {if($null-ne$lease){$lease.Dispose()}}
}

function Test-CcodInstalledLifecycleCandidateFileSet {
    param($Actual,$Expected,[string]$InstallRoot,[string]$RuntimeId,$Generation,[string]$ManifestSha256)
    try {
        if($RuntimeId-cnotmatch'^2\.5\.22-[0-9a-f]{16}-[0-9a-f]{32}\z'){return Test-CcodInstalledLifecycleFileRecordSet -Actual $Actual -Expected $Expected}
        if(-not(Test-CcodInstalledLifecycleFileRecordSet -Actual $Actual -Expected $Actual)-or
            -not(Test-CcodInstalledLifecycleFileRecordSet -Actual $Expected -Expected $Expected)-or
            -not(Test-CcodInstalledLifecyclePositiveInteger $Generation)-or$ManifestSha256-cnotmatch'^[0-9a-f]{64}\z'){return $false}
        $root=Assert-CcodInstalledLifecycleCanonicalAbsolutePath -Path $InstallRoot -Kind 'Product root'
        $state=Get-CcodInstalledLifecycleProductState -RuntimeId $RuntimeId
        if($state.valid-isnot[bool]-or-not$state.valid-or@($state.entries).Count-ne3-or$null-eq$state.readyEvidence){return $false}
        $proof=$state.readyEvidence
        $fields=@('phase','installRoot','runtimeId','runtimeGeneration','packageSha256','manifestSha256','startMenuSha256','desktopSha256','targetPath','arguments')
        if(-not(Test-CcodInstalledLifecycleExactProperties -Value $proof -Expected $fields)-or$proof.phase-cne'Ready'-or
            $proof.installRoot-isnot[string]-or$proof.installRoot-cne$root-or$proof.runtimeId-isnot[string]-or$proof.runtimeId-cne$RuntimeId-or
            -not(Test-CcodInstalledLifecyclePositiveInteger $proof.runtimeGeneration)-or[uint64]$proof.runtimeGeneration-ne[uint64]$Generation-or
            $proof.manifestSha256-isnot[string]-or$proof.manifestSha256-cne$ManifestSha256-or$proof.packageSha256-isnot[string]-or$proof.packageSha256-cnotmatch'^[0-9a-f]{64}\z'-or
            $proof.targetPath-isnot[string]-or$proof.targetPath-cne[IO.Path]::GetFullPath((Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::System)) 'schtasks.exe'))-or
            $proof.arguments-isnot[string]-or$proof.arguments-cne'/Run /TN "Codex Control Other Devices Supervisor"'){return $false}
        $generated=@('registration/Desktop.CodexRemote-fix.lnk','registration/StartMenu.CodexRemote-fix.lnk')
        foreach($pair in @(@($generated[0],'desktopSha256','Desktop'),@($generated[1],'startMenuSha256','StartMenu'))){
            $file=@($Actual|Where-Object {$_.path-ceq$pair[0]});$entry=@($state.entries|Where-Object {$_.kind-ceq$pair[2]})
            if($file.Count-ne1-or$entry.Count-ne1-or$proof.($pair[1])-isnot[string]-or$proof.($pair[1])-cnotmatch'^[0-9a-f]{64}\z'-or
                $file[0].length-le0-or$file[0].length-gt262144-or$file[0].sha256-cne$proof.($pair[1])-or$entry[0].sha256-cne$file[0].sha256){return $false}
        }
        if(@($state.entries|Where-Object {$_.kind-ceq'Registry'}).Count-ne1-or@($Expected|Where-Object {$generated-ccontains$_.path}).Count-ne0){return $false}
        $payload=@($Actual|Where-Object {$generated-cnotcontains$_.path})
        return Test-CcodInstalledLifecycleFileRecordSet -Actual $payload -Expected $Expected
    } catch {return $false}
}

function Test-CcodInstalledLifecycleFileRecordSet {
    param($Actual,$Expected)
    $actualRecords = @($Actual)
    $expectedRecords = @($Expected)
    if ($actualRecords.Count -ne $expectedRecords.Count) { return $false }
    for ($index = 0; $index -lt $expectedRecords.Count; $index++) {
        $actualRecord = $actualRecords[$index]
        $expectedRecord = $expectedRecords[$index]
        if (-not (Test-CcodInstalledLifecycleExactProperties -Value $actualRecord -Expected @('path','length','sha256')) -or
            -not (Test-CcodInstalledLifecycleExactProperties -Value $expectedRecord -Expected @('path','length','sha256')) -or
            $actualRecord.path -isnot [string] -or $expectedRecord.path -isnot [string] -or
            $actualRecord.path -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._/-]{0,255}\z' -or $expectedRecord.path -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._/-]{0,255}\z' -or
            $actualRecord.path.Contains('//') -or $expectedRecord.path.Contains('//') -or $actualRecord.path.Contains('..') -or $expectedRecord.path.Contains('..') -or
            $actualRecord.path.Contains(':') -or $expectedRecord.path.Contains(':') -or $actualRecord.path.Contains('\') -or $expectedRecord.path.Contains('\') -or
            $actualRecord.length -isnot [ValueType] -or $actualRecord.length -is [bool] -or $expectedRecord.length -isnot [ValueType] -or $expectedRecord.length -is [bool] -or
            [decimal]$actualRecord.length -ne [decimal][int64]$actualRecord.length -or [decimal]$expectedRecord.length -ne [decimal][int64]$expectedRecord.length -or
            [int64]$actualRecord.length -lt 0 -or [int64]$expectedRecord.length -lt 0 -or
            $actualRecord.sha256 -isnot [string] -or $expectedRecord.sha256 -isnot [string] -or
            $actualRecord.sha256 -cnotmatch '^[0-9a-f]{64}\z' -or $expectedRecord.sha256 -cnotmatch '^[0-9a-f]{64}\z' -or
            $actualRecord.path -cne $expectedRecord.path -or [int64]$actualRecord.length -ne [int64]$expectedRecord.length -or $actualRecord.sha256 -cne $expectedRecord.sha256) { return $false }
        if ($index -gt 0 -and [StringComparer]::Ordinal.Compare([string]$actualRecords[$index - 1].path,[string]$actualRecord.path) -ge 0) { return $false }
    }
    return $true
}

function Test-CcodInstalledLifecyclePositiveInteger {
    param($Value, [switch]$AllowZero)
    if ($Value -isnot [byte] -and $Value -isnot [uint16] -and $Value -isnot [uint32] -and $Value -isnot [uint64] -and
        $Value -isnot [int16] -and $Value -isnot [int32] -and $Value -isnot [int64]) { return $false }
    return $Value -ge $(if ($AllowZero) { 0 } else { 1 })
}

function ConvertTo-CcodInstalledLifecycleNullableIdentity {
    param($Identity, [Parameter(Mandatory)][string]$Kind)
    if ($null -eq $Identity) { return $null }
    $converted = @(ConvertTo-CcodInstalledLifecycleIdentities -Records @($Identity) -Kind $Kind)
    if ($converted.Count -ne 1) { Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_FACTS_INVALID' "$Kind identity is malformed" $Identity }
    return $converted[0]
}

function ConvertTo-CcodInstalledLifecycleReceiptFact {
    param($Receipt)
    if ($null -eq $Receipt) { return $null }
    $fields = @('kind','origin','runtimeId','runtimeGeneration','phase')
    if (-not (Test-CcodInstalledLifecycleExactProperties -Value $Receipt -Expected $fields) -or
        $Receipt.kind -isnot [string] -or @('RestartAndRepair','CheckAndRepair','SafeExit') -cnotcontains $Receipt.kind -or
        $Receipt.origin -isnot [string] -or @('Installer','Tray','ExplicitStart','Guardian') -cnotcontains $Receipt.origin -or
        $Receipt.runtimeId -isnot [string] -or $Receipt.runtimeId -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,95}\z' -or
        -not (Test-CcodInstalledLifecyclePositiveInteger -Value $Receipt.runtimeGeneration) -or
        $Receipt.phase -isnot [string] -or @('Completed','CloseFailed','OrdinaryLaunchFailed','OrdinaryObservationTimedOut','LaunchWindowExpired','RepairFailed','VerificationFailed','CancelledBeforeClose','SupersededByUpgrade') -cnotcontains $Receipt.phase) {
        Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_FACTS_INVALID' 'Lifecycle receipt fact is malformed' $Receipt
    }
    return [pscustomobject][ordered]@{
        kind = [string]$Receipt.kind
        origin = [string]$Receipt.origin
        runtimeId = [string]$Receipt.runtimeId
        runtimeGeneration = [UInt64]$Receipt.runtimeGeneration
        phase = [string]$Receipt.phase
    }
}

function ConvertTo-CcodInstalledLifecycleFacts {
    param($Facts)
    $expected = @('installRootPresent','appPresent','runtimeRootPresent','activePointerPresent','installReady','activeRuntimeId','activeGeneration','runtimeManifestSha256','runtimeManifestFiles','supervisor','trayHost','trayHostIdentity','trayAuthenticated','codex','taskState','statusPhase','statusRuntimeId','statusCodex','transitionStage','protectionReady','lifecycleReceipt','aboutVersion','deviceKeyPresent','deviceKeySha256','shortcuts','debugPorts','debugEndpoints')
    if ($null -eq $Facts -or ($Facts -isnot [pscustomobject] -and $Facts -isnot [Collections.IDictionary])) {
        Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_FACTS_INVALID' 'Machine facts are unavailable' $Facts
    }
    foreach ($name in $expected) {
        $property = if ($Facts -is [Collections.IDictionary]) { $Facts.Contains($name) } else { $null -ne $Facts.PSObject.Properties[$name] }
        if (-not $property) { Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_FACTS_INVALID' "Machine facts omit $name" $Facts }
    }
    if ($Facts.installRootPresent -isnot [bool] -or $Facts.appPresent -isnot [bool] -or $Facts.runtimeRootPresent -isnot [bool] -or $Facts.activePointerPresent -isnot [bool] -or
        $Facts.installReady -isnot [bool] -or $Facts.trayAuthenticated -isnot [bool] -or $Facts.protectionReady -isnot [bool] -or $Facts.deviceKeyPresent -isnot [bool] -or
        ($null -ne $Facts.activeRuntimeId -and ($Facts.activeRuntimeId -isnot [string] -or $Facts.activeRuntimeId -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,95}\z')) -or
        ($null -ne $Facts.activeRuntimeId -and ($Facts.activeGeneration -isnot [UInt64] -or [UInt64]$Facts.activeGeneration -lt 1)) -or
        ($null -eq $Facts.activeRuntimeId -and $null -ne $Facts.activeGeneration) -or
        ($null -ne $Facts.runtimeManifestSha256 -and ($Facts.runtimeManifestSha256 -isnot [string] -or $Facts.runtimeManifestSha256 -cnotmatch '^[0-9a-f]{64}\z')) -or
        -not (Test-CcodInstalledLifecycleFileRecordSet -Actual $Facts.runtimeManifestFiles -Expected $Facts.runtimeManifestFiles) -or
        ($null -ne $Facts.aboutVersion -and ($Facts.aboutVersion -isnot [string] -or $Facts.aboutVersion -cnotmatch '^\d+\.\d+\.\d+\z')) -or
        ($null -ne $Facts.statusRuntimeId -and ($Facts.statusRuntimeId -isnot [string] -or $Facts.statusRuntimeId -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,95}\z')) -or
        ($null -ne $Facts.deviceKeySha256 -and ($Facts.deviceKeySha256 -isnot [string] -or $Facts.deviceKeySha256 -cnotmatch '^[0-9a-f]{64}\z')) -or
        ($Facts.deviceKeyPresent -and $null -eq $Facts.deviceKeySha256) -or
        (-not $Facts.deviceKeyPresent -and $null -ne $Facts.deviceKeySha256) -or
        $Facts.taskState -isnot [string] -or $Facts.statusPhase -isnot [string] -or $Facts.transitionStage -isnot [string] -or $Facts.statusPhase.Length -gt 64 -or $Facts.transitionStage.Length -gt 64 -or
        $null -eq $Facts.shortcuts -or $Facts.shortcuts.startMenu -isnot [bool] -or $Facts.shortcuts.desktop -isnot [bool]) {
        Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_FACTS_INVALID' 'Machine facts have an invalid public shape' $Facts
    }
    $debugPorts = @()
    if ($null -ne $Facts.debugPorts) { $debugPorts = @($Facts.debugPorts) }
    foreach ($port in $debugPorts) { if ($port -isnot [int] -or $port -lt 1 -or $port -gt 65535) { Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_FACTS_INVALID' 'Debug port facts are malformed' $port } }
    if (@($debugPorts | Sort-Object -Unique).Count -ne $debugPorts.Count) { Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_FACTS_INVALID' 'Debug port facts contain duplicates' $debugPorts }
    $codexIdentities = @(ConvertTo-CcodInstalledLifecycleIdentities -Records $Facts.codex -Kind 'Codex')
    $trayIdentities = @(ConvertTo-CcodInstalledLifecycleIdentities -Records $Facts.trayHost -Kind 'TrayHost')
    $trayHostIdentity = ConvertTo-CcodInstalledLifecycleNullableIdentity -Identity $Facts.trayHostIdentity -Kind 'TrayHost'
    if ($trayIdentities.Count -eq 1) {
        if ($null -eq $trayHostIdentity -or $trayHostIdentity.pid -ne $trayIdentities[0].pid -or $trayHostIdentity.creationTimeUtc -cne $trayIdentities[0].creationTimeUtc) { Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_FACTS_INVALID' 'TrayHost identity is detached from the observed TrayHost process' $Facts.trayHostIdentity }
    } elseif ($null -ne $trayHostIdentity -or $Facts.trayAuthenticated) {
        Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_FACTS_INVALID' 'TrayHost authentication requires exactly one matching TrayHost identity' $Facts.trayHostIdentity
    }
    $debugNormalized = @()
    if ($null -ne $Facts.debugEndpoints) {
        foreach ($endpoint in @($Facts.debugEndpoints)) {
            if (-not (Test-CcodInstalledLifecycleExactProperties -Value $endpoint -Expected @('localAddress','localPort','owningProcess','owningProcessCreationTimeUtc')) -or
                $endpoint.localAddress -isnot [string] -or $endpoint.localAddress -cne '127.0.0.1' -or
                $endpoint.localPort -isnot [int] -or $endpoint.localPort -lt 1 -or $endpoint.localPort -gt 65535 -or
                $endpoint.owningProcess -isnot [int] -or $endpoint.owningProcess -lt 1 -or
                $endpoint.owningProcessCreationTimeUtc -isnot [string] -or [string]::IsNullOrWhiteSpace($endpoint.owningProcessCreationTimeUtc)) { Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_FACTS_INVALID' 'Debug endpoint identity is malformed' $endpoint }
            if ($codexIdentities.Count -ne 1 -or $endpoint.owningProcess -ne $codexIdentities[0].Pid -or $endpoint.owningProcessCreationTimeUtc -cne $codexIdentities[0].CreationTimeUtc) { Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_FACTS_INVALID' 'Debug endpoint is not owned by the verified Codex identity' $endpoint }
            $debugNormalized += [pscustomobject][ordered]@{ localAddress = [string]$endpoint.localAddress; localPort = [int]$endpoint.localPort; owningProcess = [int]$endpoint.owningProcess; owningProcessCreationTimeUtc = [string]$endpoint.owningProcessCreationTimeUtc }
        }
    }
    if ($debugNormalized.Count -gt 0) {
        if ($codexIdentities.Count -ne 1 -or @($debugNormalized.owningProcess | Sort-Object -Unique).Count -ne 1 -or [int]$debugNormalized[0].owningProcess -ne [int]$codexIdentities[0].Pid) { Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_FACTS_INVALID' 'Debug endpoints are not owned by the verified Codex process' $debugNormalized }
    }
    return [pscustomobject][ordered]@{
        installRootPresent = [bool]$Facts.installRootPresent
        appPresent = [bool]$Facts.appPresent
        runtimeRootPresent = [bool]$Facts.runtimeRootPresent
        activePointerPresent = [bool]$Facts.activePointerPresent
        installReady = [bool]$Facts.installReady
        activeRuntimeId = $Facts.activeRuntimeId
        activeGeneration = $Facts.activeGeneration
        runtimeManifestSha256 = $Facts.runtimeManifestSha256
        runtimeManifestFiles = @($Facts.runtimeManifestFiles)
        supervisor = @(ConvertTo-CcodInstalledLifecycleIdentities -Records $Facts.supervisor -Kind 'Supervisor')
        trayHost = @($trayIdentities)
        trayHostIdentity = $trayHostIdentity
        trayAuthenticated = [bool]$Facts.trayAuthenticated
        codex = @(ConvertTo-CcodInstalledLifecycleIdentities -Records $Facts.codex -Kind 'Codex')
        codexCount = [int]$codexIdentities.Count
        taskState = [string]$Facts.taskState
        statusPhase = [string]$Facts.statusPhase
        statusRuntimeId = $Facts.statusRuntimeId
        statusCodex = ConvertTo-CcodInstalledLifecycleNullableIdentity -Identity $Facts.statusCodex -Kind 'Status Codex'
        transitionStage = [string]$Facts.transitionStage
        protectionReady = [bool]$Facts.protectionReady
        lifecycleReceipt = ConvertTo-CcodInstalledLifecycleReceiptFact -Receipt $Facts.lifecycleReceipt
        aboutVersion = $Facts.aboutVersion
        deviceKeyPresent = [bool]$Facts.deviceKeyPresent
        deviceKeySha256 = $Facts.deviceKeySha256
        shortcuts = [pscustomobject][ordered]@{ startMenu = [bool]$Facts.shortcuts.startMenu; desktop = [bool]$Facts.shortcuts.desktop }
        debugPorts = [int[]]$debugPorts
        debugEndpoints = @($debugNormalized)
    }
}

function New-CcodInstalledLifecyclePhase {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Outcome)
    return [pscustomobject][ordered]@{ name = $Name; outcome = $Outcome }
}

function Read-CcodInstalledLifecycleStrictJson {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int]$ExpectedSchema,
        [Parameter(Mandatory)][string]$Kind
    )
    return & $script:CcodInstalledLifecyclePersistenceIoModule {
        param($DocumentPath, $Schema, $DocumentKind)
        Read-CcodStrictJson -Path $DocumentPath -ExpectedSchema $Schema -Kind $DocumentKind
    } $Path $ExpectedSchema $Kind
}

function Get-CcodInstalledLifecycleFileLinkCount {
    param([Parameter(Mandatory)][string]$Path)
    if ($null -eq ('CcodInstalledLifecycleFileIdentity' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class CcodInstalledLifecycleFileIdentity {
    [StructLayout(LayoutKind.Sequential)] private struct Info { public uint Attributes; public System.Runtime.InteropServices.ComTypes.FILETIME Creation; public System.Runtime.InteropServices.ComTypes.FILETIME Access; public System.Runtime.InteropServices.ComTypes.FILETIME Write; public uint Volume; public uint FileIndexHigh; public uint FileIndexLow; public uint Links; public uint SizeHigh; public uint SizeLow; }
    [DllImport("kernel32.dll", SetLastError=true)] private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out Info info);
    public static uint Links(string path) { using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read)) { Info info; if (!GetFileInformationByHandle(stream.SafeFileHandle, out info)) throw new Win32Exception(Marshal.GetLastWin32Error()); return info.Links; } }
}
'@
    }
    return [CcodInstalledLifecycleFileIdentity]::Links($Path)
}

function Assert-CcodInstalledLifecyclePlainSelectorFile {
    param([Parameter(Mandatory)][string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or (Get-CcodInstalledLifecycleFileLinkCount -Path $Path) -ne 1) { throw 'selector file identity' }
    $streams = @(Get-Item -LiteralPath $Path -Stream * -ErrorAction Stop)
    if ($streams.Count -ne 1 -or [string]$streams[0].Stream -cne ':$DATA') { throw 'selector file streams' }
}

function Read-CcodInstalledLifecycleActiveFact {
    param([Parameter(Mandatory)][string]$InstallRoot)
    $probe = { param($CandidatePath) Get-Item -LiteralPath $CandidatePath -Force -ErrorAction Stop }
    $selectorRoot = Join-Path (Join-Path $InstallRoot 'state') 'active-generation'
    $selectorPresent = Get-CcodInstalledLifecycleOptionalDirectoryState -Path $selectorRoot -GetItem $probe
    if ($selectorPresent) {
        try {
            $selectorItem = & $probe $selectorRoot
            if (-not $selectorItem.PSIsContainer -or (($selectorItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { throw 'selector root' }
            $entries = @(Get-ChildItem -LiteralPath $selectorRoot -Force -ErrorAction Stop)
            if ($entries.Count -eq 0) { throw 'selector empty' }
            $records = [Collections.Generic.List[object]]::new()
            foreach ($entry in $entries) {
                if ($entry.PSIsContainer -or $entry -isnot [IO.FileInfo] -or (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or $entry.Name -notmatch '^\d{20}\.json\z') { throw 'selector entry' }
                Assert-CcodInstalledLifecyclePlainSelectorFile -Path $entry.FullName
                $record = Read-CcodInstalledLifecycleStrictJson -Path $entry.FullName -ExpectedSchema 1 -Kind 'installed active-generation selector'
                if ($record.activeRuntime -isnot [string] -or -not [regex]::IsMatch([string]$record.activeRuntime, '^[A-Za-z0-9][A-Za-z0-9._-]{0,95}\z', [Text.RegularExpressions.RegexOptions]::CultureInvariant)) { throw 'selector active runtime' }
                if (-not (Test-CcodInstalledLifecycleExactProperties -Value $record -Expected @('schemaVersion','generation','activeRuntime','previousGeneration')) -or
                    $record.schemaVersion -isnot [int] -or $record.schemaVersion -ne 1 -or
                    $record.activeRuntime -isnot [string] -or $record.activeRuntime -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,95}\z' -or
                    -not (Test-CcodInstalledLifecyclePositiveInteger -Value $record.generation) -or
                    $record.previousGeneration -isnot [ValueType] -or $record.previousGeneration -is [bool] -or
                    $record.previousGeneration -isnot [byte] -and $record.previousGeneration -isnot [uint16] -and $record.previousGeneration -isnot [uint32] -and $record.previousGeneration -isnot [uint64] -and
                    $record.previousGeneration -isnot [int16] -and $record.previousGeneration -isnot [int32] -and $record.previousGeneration -isnot [int64]) { throw 'selector record' }
                [UInt64]$generation = $record.generation
                [UInt64]$previous = $record.previousGeneration
                if ($entry.Name -cne ('{0:D20}.json' -f $generation) -or $generation -eq 0 -or $previous -ne ($generation - 1)) { throw 'selector canonical record' }
                $records.Add([pscustomobject][ordered]@{ generation = $generation; activeRuntime = [string]$record.activeRuntime; previousGeneration = $previous })
            }
            $ordered = @($records | Sort-Object generation)
            for ($index = 0; $index -lt $ordered.Count; $index++) {
                if ([UInt64]$ordered[$index].generation -ne [UInt64]($index + 1) -or [UInt64]$ordered[$index].previousGeneration -ne [UInt64]$index) { throw 'selector chain' }
            }
            $latest = $ordered[-1]
            return [pscustomobject][ordered]@{ schemaVersion = 2; activeRuntime = [string]$latest.activeRuntime; previousRuntime = $null; generation = [UInt64]$latest.generation; updatedAtUtc = '1970-01-01T00:00:00.0000000Z' }
        } catch {
            Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_FACTS_INVALID' 'Append-only active-generation selector is malformed' $selectorRoot
        }
    }
    $path = Join-Path $InstallRoot 'active.json'
    $item = Get-CcodInstalledLifecycleOptionalRegularFileState -Path $path -GetItem $probe
    if ($null -eq $item) { return $null }
    Assert-CcodInstalledLifecyclePlainSelectorFile -Path $item.FullName
    $active = $null
    $legacy = $false
    try { $active = Read-CcodInstalledLifecycleStrictJson -Path $item.FullName -ExpectedSchema 2 -Kind 'installed active runtime' } catch {
        if ($_.FullyQualifiedErrorId -notlike '*CCOD_SCHEMA_UNSUPPORTED*') { throw }
        $active = Read-CcodInstalledLifecycleStrictJson -Path $item.FullName -ExpectedSchema 1 -Kind 'installed legacy active runtime'
        $legacy = $true
    }
    if ($legacy) {
        if (-not (Test-CcodInstalledLifecycleExactProperties -Value $active -Expected @('schemaVersion','activeRuntime','previousRuntime','updatedAtUtc')) -or
            $active.schemaVersion -isnot [int] -or $active.schemaVersion -ne 1 -or $active.activeRuntime -isnot [string] -or $active.activeRuntime -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,95}\z' -or
            ($null -ne $active.previousRuntime -and ($active.previousRuntime -isnot [string] -or $active.previousRuntime -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,95}\z')) -or
            -not (Test-CcodInstalledLifecycleCanonicalUtc -Value $active.updatedAtUtc)) {
            Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_FACTS_INVALID' 'Active runtime schema 1 is malformed' $path
        }
        return [pscustomobject][ordered]@{ schemaVersion = 2; activeRuntime = [string]$active.activeRuntime; previousRuntime = $active.previousRuntime; generation = [UInt64]1; updatedAtUtc = [string]$active.updatedAtUtc }
    }
    if (-not (Test-CcodInstalledLifecycleExactProperties -Value $active -Expected @('schemaVersion','activeRuntime','previousRuntime','generation','updatedAtUtc')) -or
        $active.schemaVersion -isnot [int] -or $active.schemaVersion -ne 2 -or
        $active.activeRuntime -isnot [string] -or $active.activeRuntime -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,95}\z' -or
        ($null -ne $active.previousRuntime -and ($active.previousRuntime -isnot [string] -or $active.previousRuntime -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,95}\z')) -or
        -not (Test-CcodInstalledLifecyclePositiveInteger -Value $active.generation) -or
        -not (Test-CcodInstalledLifecycleCanonicalUtc -Value $active.updatedAtUtc)) {
        Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_FACTS_INVALID' 'Active runtime schema 2 is malformed' $path
    }
    return $active
}

function Read-CcodInstalledLifecycleStatusFact {
    param([Parameter(Mandatory)][string]$StateRoot)
    $path = Join-Path $StateRoot 'status.json'
    $probe = { param($CandidatePath) Get-Item -LiteralPath $CandidatePath -Force -ErrorAction Stop }
    $item = Get-CcodInstalledLifecycleOptionalRegularFileState -Path $path -GetItem $probe
    if ($null -eq $item) { return $null }
    $status = Read-CcodInstalledLifecycleStrictJson -Path $item.FullName -ExpectedSchema 1 -Kind 'installed status'
    try {
        & $script:CcodInstalledLifecycleStateStoreModule { param($Value) Assert-CcodStatusShape -Status $Value } $status
    } catch {
        Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_FACTS_INVALID' 'Status schema 1 is malformed' $path
    }
    return $status
}

function Read-CcodInstalledLifecycleTransitionFact {
    param([Parameter(Mandatory)][string]$StateRoot)
    $path = Join-Path $StateRoot 'transition.json'
    $probe = { param($CandidatePath) Get-Item -LiteralPath $CandidatePath -Force -ErrorAction Stop }
    $item = Get-CcodInstalledLifecycleOptionalRegularFileState -Path $path -GetItem $probe
    if ($null -eq $item) { return $null }
    $transition = Read-CcodInstalledLifecycleStrictJson -Path $item.FullName -ExpectedSchema 1 -Kind 'installed transition'
    try {
        & $script:CcodInstalledLifecycleStateStoreModule { param($Value) Assert-CcodTransitionShape -Transition $Value } $transition
    } catch {
        Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_FACTS_INVALID' 'Transition schema 1 is malformed' $path
    }
    return $transition
}

function Get-CcodInstalledLifecycleReceiptFact {
    param(
        [Parameter(Mandatory)][string]$StateRoot,
        [AllowNull()][string]$ActiveRuntimeId,
        [UInt64]$ActiveGeneration
    )
    $directory = Join-Path (Join-Path $StateRoot 'lifecycle') 'receipts'
    $probe = { param($CandidatePath) Get-Item -LiteralPath $CandidatePath -Force -ErrorAction Stop }
    $directoryPresent = Get-CcodInstalledLifecycleOptionalDirectoryState -Path $directory -GetItem $probe
    if (-not $directoryPresent) { return $null }
    $directoryItem = & $probe $directory
    if (-not $directoryItem.PSIsContainer -or (($directoryItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_FACTS_INVALID' 'Lifecycle receipt root is malformed' $directory
    }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $candidates = [Collections.Generic.List[object]]::new()
    foreach ($item in @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop)) {
        if ($item.PSIsContainer -or $item -isnot [IO.FileInfo] -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or
            $item.Name -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.json\z') {
            Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_FACTS_INVALID' 'Lifecycle receipt entry is malformed' $item.FullName
        }
        try { Assert-CcodInstalledLifecyclePlainSelectorFile -Path $item.FullName }
        catch { Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_FACTS_INVALID' 'Lifecycle receipt entry does not have plain-file identity.' $item.FullName }
        $receipt = Read-CcodInstalledLifecycleStrictJson -Path $item.FullName -ExpectedSchema 1 -Kind 'installed lifecycle receipt'
        try {
            & $script:CcodInstalledLifecycleTransactionModule { param($Value) Assert-CcodLifecycleRequest -Request $Value } $receipt
        } catch {
            Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_FACTS_INVALID' 'Lifecycle receipt schema 1 is malformed' $item.FullName
        }
        if ($item.Name -cne ($receipt.transactionId + '.json') -or -not $seen.Add([string]$receipt.transactionId)) {
            Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_FACTS_INVALID' 'Lifecycle receipts have a mismatched or duplicate identity' $item.FullName
        }
        if ($receipt.phase -cnotin @('Completed','CloseFailed','OrdinaryLaunchFailed','OrdinaryObservationTimedOut','LaunchWindowExpired','RepairFailed','VerificationFailed','CancelledBeforeClose','SupersededByUpgrade')) {
            Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_FACTS_INVALID' 'Lifecycle receipt is not terminal' $item.FullName
        }
        if ($null -ne $ActiveRuntimeId -and $receipt.runtimeId -ceq $ActiveRuntimeId -and
            [UInt64]$receipt.runtimeGeneration -eq $ActiveGeneration -and
            $receipt.origin -ceq 'Installer' -and $receipt.kind -ceq 'RestartAndRepair') {
            $candidates.Add($receipt)
        }
    }
    if ($candidates.Count -eq 0) { return $null }
    $ordered = @($candidates | Sort-Object updatedAtUtc -Descending)
    if ($ordered.Count -gt 1 -and $ordered[0].updatedAtUtc -ceq $ordered[1].updatedAtUtc) {
        Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_FACTS_INVALID' 'Latest current-runtime installer lifecycle receipt is ambiguous' $directory
    }
    $latest = $ordered[0]
    return [pscustomobject][ordered]@{
        kind = [string]$latest.kind
        origin = [string]$latest.origin
        runtimeId = [string]$latest.runtimeId
        runtimeGeneration = [UInt64]$latest.runtimeGeneration
        phase = [string]$latest.phase
    }
}

function Initialize-CcodInstalledLifecycleCommandLineParser {
    if ($null -ne ('CcodInstalledLifecycleCommandLine' -as [type])) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class CcodInstalledLifecycleCommandLine
{
    [DllImport("shell32.dll", SetLastError = true)]
    private static extern IntPtr CommandLineToArgvW(
        [MarshalAs(UnmanagedType.LPWStr)] string commandLine,
        out int argumentCount);

    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr memory);

    public static string[] Parse(string commandLine)
    {
        int argumentCount;
        IntPtr arguments = CommandLineToArgvW(commandLine, out argumentCount);
        if (arguments == IntPtr.Zero || argumentCount < 1) return null;
        try
        {
            string[] result = new string[argumentCount];
            for (int index = 0; index < argumentCount; index++)
            {
                IntPtr value = Marshal.ReadIntPtr(arguments, index * IntPtr.Size);
                result[index] = Marshal.PtrToStringUni(value);
            }
            return result;
        }
        finally
        {
            LocalFree(arguments);
        }
    }
}
'@
}

function Test-CcodInstalledLifecycleOrdinaryChatGptRoot {
    param($Process)
    if ($null -eq $Process -or $Process.CommandLine -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$Process.CommandLine)) { return $false }
    try {
        Initialize-CcodInstalledLifecycleCommandLineParser
        $arguments = @([CcodInstalledLifecycleCommandLine]::Parse([string]$Process.CommandLine))
    } catch {
        return $false
    }
    if ($arguments.Count -eq 0 -or @($arguments | Where-Object { $null -eq $_ -or $_ -isnot [string] }).Count -ne 0) { return $false }
    foreach ($argument in $arguments) {
        if ($argument.StartsWith('--type=', [StringComparison]::OrdinalIgnoreCase)) { return $false }
    }
    return $true
}

function Get-CcodInstalledLifecycleChatGptClassification {
    param($Process)
    if ($null -eq $Process -or $Process.PSObject.Properties['Name'] -eq $null -or
        $Process.Name -isnot [string] -or $Process.Name -cne 'ChatGPT.exe' -or
        $Process.PSObject.Properties['CommandLine'] -eq $null -or $Process.CommandLine -isnot [string] -or
        [string]::IsNullOrWhiteSpace([string]$Process.CommandLine)) {
        Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_FACTS_INVALID' 'An enumerated ChatGPT process has unreadable command-line evidence' $null
    }
    try {
        Initialize-CcodInstalledLifecycleCommandLineParser
        $arguments=@([CcodInstalledLifecycleCommandLine]::Parse([string]$Process.CommandLine))
    } catch {
        Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_FACTS_INVALID' 'An enumerated ChatGPT process command line could not be parsed' $null
    }
    if($arguments.Count -lt 1 -or @($arguments|Where-Object{$_ -isnot [string] -or [string]::IsNullOrWhiteSpace($_)}).Count -ne 0 -or
       [IO.Path]::GetFileName([string]$arguments[0]) -ine 'ChatGPT.exe'){
        Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_FACTS_INVALID' 'An enumerated ChatGPT process command line is not a complete executable argv' $null
    }
    $typeArguments=@($arguments|Select-Object -Skip 1|Where-Object{$_.StartsWith('--type=',[StringComparison]::OrdinalIgnoreCase)})
    if($typeArguments.Count -gt 1 -or ($typeArguments.Count -eq 1 -and $typeArguments[0].Length -le 7)){
        Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_FACTS_INVALID' 'An enumerated ChatGPT process has an invalid Electron type argv' $null
    }
    return $(if($typeArguments.Count -eq 1){'Child'}else{'Root'})
}

function Get-CcodInstalledLifecycleChatGptIdentities {
    $records=[Collections.Generic.List[object]]::new()
    try{$processes=@(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'ChatGPT.exe'" -ErrorAction Stop)}catch{
        Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_FACTS_INVALID' 'ChatGPT process enumeration failed' $null
    }
    foreach($process in $processes){
        if($null -eq $process -or $process.PSObject.Properties['ProcessId'] -eq $null -or
           -not (Test-CcodInstalledLifecyclePositiveInteger -Value $process.ProcessId) -or [decimal]$process.ProcessId -gt [int]::MaxValue -or
           $process.PSObject.Properties['CreationDate'] -eq $null){
            Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_FACTS_INVALID' 'An enumerated ChatGPT process has invalid identity evidence' $null
        }
        $created = ConvertTo-CcodInstalledLifecycleCreationTimeUtc -Value $process.CreationDate
        $classification=Get-CcodInstalledLifecycleChatGptClassification -Process $process
        if($classification -ceq 'Root'){$created=Get-CcodInstalledLifecycleCorrelatedCreationTimeUtc -Process $process;$records.Add([pscustomobject][ordered]@{Pid=[int]$process.ProcessId;CreationTimeUtc=$created})}
    }
    return @($records)
}

function Assert-CcodInstalledLifecycleRuntimeManifest {
    param([Parameter(Mandatory)]$Manifest,[Parameter(Mandatory)][string]$ExpectedVersion,[Parameter(Mandatory)][string]$ExpectedRuntimeId,[string]$RuntimeRoot)
    try {
        if (-not (Test-CcodInstalledLifecycleExactProperties -Value $Manifest -Expected @('schemaVersion','projectVersion','runtimeId','files')) -or
            $Manifest.files -isnot [Array] -or -not (Test-CcodInstalledLifecyclePositiveInteger $Manifest.schemaVersion -AllowZero) -or $Manifest.schemaVersion -ne 1) { throw 'manifest frame' }
        $newRuntimeMatch = [regex]::Match($ExpectedRuntimeId, '^(?<version>[A-Za-z0-9][A-Za-z0-9._-]{0,45})-(?<digest>[0-9a-f]{16})-(?<nonce>[0-9a-f]{32})\z')
        $legacyRuntimeMatch = [regex]::Match($ExpectedRuntimeId, '^(?<version>[A-Za-z0-9][A-Za-z0-9._-]{0,45})-(?<digest>[0-9a-f]{16})\z')
        $expectedManifestVersion = if ($newRuntimeMatch.Success) { $newRuntimeMatch.Groups['version'].Value } else { $legacyRuntimeMatch.Groups['version'].Value }
        if ((-not $newRuntimeMatch.Success -and -not $legacyRuntimeMatch.Success) -or ($legacyRuntimeMatch.Success -and $legacyRuntimeMatch.Groups['version'].Value -cne '2.5.21') -or
            $expectedManifestVersion -cne $ExpectedVersion -or
            $Manifest.runtimeId -isnot [string] -or $Manifest.runtimeId -cne $ExpectedRuntimeId -or $Manifest.projectVersion -isnot [string] -or $Manifest.projectVersion -cne $ExpectedVersion) { throw 'manifest frame' }
        $previousPath = $null
        $seenPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($file in @($Manifest.files)) {
            if (-not (Test-CcodInstalledLifecycleExactProperties -Value $file -Expected @('path','length','sha256')) -or
                $file.path -isnot [string] -or [string]::IsNullOrWhiteSpace($file.path) -or
                [IO.Path]::IsPathRooted($file.path) -or $file.path.Contains('..') -or $file.path.Contains(':') -or
                -not (Test-CcodInstalledLifecyclePositiveInteger $file.length -AllowZero) -or
                $file.sha256 -isnot [string] -or $file.sha256 -cnotmatch '^[0-9a-f]{64}\z' -or
                -not $seenPaths.Add([string]$file.path)) { throw 'manifest file' }
            if ($null -ne $previousPath -and [StringComparer]::Ordinal.Compare([string]$previousPath,[string]$file.path) -ge 0) { throw 'manifest order' }
            $previousPath = [string]$file.path
        }
        if (-not [string]::IsNullOrWhiteSpace($RuntimeRoot)) {
            $runtimePath = [IO.Path]::GetFullPath($RuntimeRoot)
            $runtimeItem = Get-Item -LiteralPath $runtimePath -Force -ErrorAction Stop
            if ($runtimeItem.PSIsContainer -ne $true -or ($runtimeItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'runtime root' }
            $actualFiles = [Collections.Generic.List[object]]::new()
            $prefix = $runtimePath.TrimEnd('\') + '\'
            foreach ($item in @(Get-ChildItem -LiteralPath $runtimePath -Force -Recurse -ErrorAction Stop)) {
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'runtime reparse' }
                if (-not $item.PSIsContainer) {
                    $relative = $item.FullName.Substring($prefix.Length).Replace('\','/')
                    if (-not $relative.Equals('manifest.json',[StringComparison]::OrdinalIgnoreCase)) {
                        $actualFiles.Add([pscustomobject][ordered]@{ path = $relative; length = [int64]$item.Length; sha256 = Get-CcodInstalledLifecycleHash -Path $item.FullName })
                    }
                }
            }
            $actualFiles.Sort([Comparison[object]]{param($left,$right) [StringComparer]::Ordinal.Compare([string]$left.path,[string]$right.path)})
            $actual = @($actualFiles)
            $declared = @($Manifest.files)
            if ($actual.Count -ne $declared.Count) { throw 'runtime files count' }
            for ($index = 0; $index -lt $actual.Count; $index++) {
                if ($actual[$index].path -cne [string]$declared[$index].path -or [int64]$actual[$index].length -ne [int64]$declared[$index].length -or $actual[$index].sha256 -cne [string]$declared[$index].sha256) { throw 'runtime file binding' }
            }
            $canonical = if ($newRuntimeMatch.Success) {
                @($declared | ForEach-Object { "{0}`t{1}`t{2}" -f [string]$_.path,[int64]$_.length,[string]$_.sha256 }) -join "`n"
            } else {
                @($declared | ForEach-Object { '{0}`t{1}`t{2}' -f [string]$_.path,[int64]$_.length,[string]$_.sha256 }) -join "`n"
            }
            $sha = [Security.Cryptography.SHA256]::Create()
            try { $digest = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonical)))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
            if ($newRuntimeMatch.Success) {
                if ($newRuntimeMatch.Groups['digest'].Value -cne $digest.Substring(0,16)) { throw 'runtime id binding' }
            } elseif ($legacyRuntimeMatch.Groups['digest'].Value -cne $digest.Substring(0,16)) { throw 'legacy runtime id binding' }
        }
        return $Manifest
    } catch {
        Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_OBSERVATION_UNAVAILABLE' 'The active runtime manifest is missing, malformed, or detached from the installed candidate.' $ExpectedRuntimeId
    }
}

function Get-CcodInstalledLifecycleFacts {
    param([Parameter(Mandatory)][string]$InstallRoot,[string]$ExpectedVersion,[object]$ExpectedDebugPorts,[object[]]$ExpectedPayloadFiles)
    $root = Assert-CcodInstalledLifecycleCanonicalAbsolutePath -Path $InstallRoot -Kind 'Install root'
    $appRoot = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'CodexControlOtherDevices-installer'
    $pathProbe = { param($Path) Get-Item -LiteralPath $Path -Force -ErrorAction Stop }.GetNewClosure()
    $installRootPresent = Get-CcodInstalledLifecycleOptionalDirectoryState -Path $root -GetItem $pathProbe
    if ($installRootPresent) { [void](Assert-CcodInstalledLifecycleSafeDirectory -Path $root -Kind 'Install root') }
    $runtimeRootPath = Join-Path $root 'runtime'
    $selectorRootPath = Join-Path (Join-Path $root 'state') 'active-generation'
    $activePointerPath = Join-Path $root 'active.json'
    $runtimeRootPresent = Get-CcodInstalledLifecycleOptionalDirectoryState -Path $runtimeRootPath -GetItem $pathProbe
    $selectorPresent = Get-CcodInstalledLifecycleOptionalDirectoryState -Path $selectorRootPath -GetItem $pathProbe
    $activePointerItem = Get-CcodInstalledLifecycleOptionalRegularFileState -Path $activePointerPath -GetItem $pathProbe
    $activePointerPresent = $selectorPresent -or ($null -ne $activePointerItem)
    $appRootPresent = Get-CcodInstalledLifecycleOptionalDirectoryState -Path $appRoot -GetItem $pathProbe
    $activeRuntimeId = $null
    [UInt64]$activeGeneration = 0
    $runtimeManifestSha256 = $null
    $runtimeManifestFiles = @()
    $activeManifestObject = $null
    $manifestExpectedVersion = $ExpectedVersion
    $statusPhase = 'Unavailable'
    $statusRuntimeId = $null
    $statusCodex = $null
    $transitionStage = 'Unavailable'
    $active = Read-CcodInstalledLifecycleActiveFact -InstallRoot $root
    if ($null -ne $active) {
        $activeRuntimeId = [string]$active.activeRuntime
        $activeGeneration = [UInt64]$active.generation
        $manifest = Join-Path (Join-Path (Join-Path $root 'runtime') $activeRuntimeId) 'manifest.json'
        $manifestItem = Get-CcodInstalledLifecycleOptionalRegularFileState -Path $manifest -GetItem $pathProbe
        if ($null -eq $manifestItem) { Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_OBSERVATION_UNAVAILABLE' 'The active runtime manifest is missing.' $manifest }
        $runtimeManifestSha256 = Get-CcodInstalledLifecycleHash -Path $manifestItem.FullName
        try { $activeManifestObject = Read-CcodInstalledLifecycleStrictJson -Path $manifestItem.FullName -ExpectedSchema 1 -Kind 'installed runtime manifest' } catch { Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_OBSERVATION_UNAVAILABLE' 'The active runtime manifest could not be read safely.' $manifest }
        if ([string]::IsNullOrWhiteSpace($manifestExpectedVersion)) {
            if ($activeRuntimeId -notmatch '^(?<version>[A-Za-z0-9][A-Za-z0-9._-]{0,45})-(?<digest>[0-9a-f]{16})(?:-(?<nonce>[0-9a-f]{32}))?\z') { Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_OBSERVATION_UNAVAILABLE' 'The active runtime version binding could not be proven.' $activeRuntimeId }
            $manifestExpectedVersion = [string]$Matches.version
        }
    }
    $stateRoot = Join-Path $root 'state'
    $status = Read-CcodInstalledLifecycleStatusFact -StateRoot $stateRoot
    if ($null -ne $status -and $null -ne $status.session) {
        $statusPhase = [string]$status.session.sessionState
        $statusRuntimeId = [string]$status.session.runtimeId
        if ($null -ne $status.session.codex) {
            $statusCodex = [pscustomobject][ordered]@{
                pid = [int]$status.session.codex.pid
                creationTimeUtc = [string]$status.session.codex.creationTimeUtc
            }
        }
    }
    $transition = Read-CcodInstalledLifecycleTransitionFact -StateRoot $stateRoot
    if ($null -ne $transition) {
        $transitionStage = if ($null -eq $transition.activeTransaction) { 'Idle' } else { [string]$transition.activeTransaction.stage }
    }
    $lifecycleReceipt = Get-CcodInstalledLifecycleReceiptFact -StateRoot $stateRoot -ActiveRuntimeId $activeRuntimeId -ActiveGeneration $activeGeneration
    $taskState = 'Unknown'
    try {
        $matches = @(Get-ScheduledTask -ErrorAction Stop | Where-Object { $_.TaskName -ceq $script:CcodInstalledLifecycleTaskName })
        if ($matches.Count -eq 0) { $taskState = 'Absent' }
        elseif ($matches.Count -eq 1) { $taskState = [string]$matches[0].State }
    } catch {
        Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_OBSERVATION_UNAVAILABLE' 'The Supervisor scheduled task could not be inspected safely.' $null
    }
    $makeIdentities = {
        param([string[]]$Names, [scriptblock]$Predicate)
        $records = [Collections.Generic.List[object]]::new()
        foreach ($name in $Names) {
            try {
                foreach ($process in @(Get-CimInstance -ClassName Win32_Process -Filter ("Name = '{0}'" -f $name) -ErrorAction Stop)) {
                    if (-not (& $Predicate $process)) { continue }
                    $created = Get-CcodInstalledLifecycleCorrelatedCreationTimeUtc -Process $process
                    $records.Add([pscustomobject][ordered]@{ Pid = [int]$process.ProcessId; CreationTimeUtc = $created })
                }
            } catch {
                Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_OBSERVATION_UNAVAILABLE' 'Process identities could not be inspected safely.' $null
            }
        }
        return @($records)
    }
    $supervisor = & $makeIdentities @('powershell.exe','pwsh.exe') {
        param($Process)
        $commandLine = Assert-CcodInstalledLifecycleReadableProcessText -Value $Process.CommandLine -Kind 'Supervisor CommandLine'
        $commandLine.IndexOf('Supervisor.ps1', [StringComparison]::OrdinalIgnoreCase) -ge 0 -and
        $commandLine.IndexOf($root, [StringComparison]::OrdinalIgnoreCase) -ge 0
    }
    $trayRuntimeRoot = if ($null -ne $activeRuntimeId) { Join-Path (Join-Path $root 'runtime') $activeRuntimeId } else { $root }
    $trayHostPath = [IO.Path]::GetFullPath((Join-Path $trayRuntimeRoot 'bin\CodexRemote.TrayHost.exe'))
    $trayHost = & $makeIdentities @('CodexRemote.TrayHost.exe') {
        param($Process)
        $executablePath = Assert-CcodInstalledLifecycleReadableProcessText -Value $Process.ExecutablePath -Kind 'TrayHost ExecutablePath'
        $executablePath -ieq $trayHostPath
    }
    $trayHostIdentity = $null
    $trayAuthenticated = $false
    if (@($trayHost).Count -eq 1) {
        $trayHostIdentity = [pscustomobject][ordered]@{ pid = [int]$trayHost[0].Pid; creationTimeUtc = [string]$trayHost[0].CreationTimeUtc }
        if ($null -ne $activeRuntimeId) { $trayAuthenticated = [bool](Get-CcodInstalledLifecycleTrayHostReadyProof -InstallRoot $root -RuntimeId $activeRuntimeId -TrayHost $trayHost) }
    }
    $codex = @(Get-CcodInstalledLifecycleChatGptIdentities)
    $aboutVersion = $null
    $sealedRuntime = $null -ne $activeRuntimeId -and $activeRuntimeId -cmatch '^2\.5\.22-[0-9a-f]{16}-[0-9a-f]{32}\z'
    $packagePath = if ($sealedRuntime) { Join-Path $trayRuntimeRoot 'package.json' } else { Join-Path $appRoot 'package.json' }
    $packageItem = Get-CcodInstalledLifecycleOptionalRegularFileState -Path $packagePath -GetItem $pathProbe
    if ($sealedRuntime) { $appRootPresent = $null -ne $packageItem }
    if ($null -ne $packageItem) {
        try {
            $packageText = [IO.File]::ReadAllText($packageItem.FullName, [Text.UTF8Encoding]::new($false,$true))
            $packageUnique = & $script:CcodInstalledLifecyclePersistenceIoModule { param($Json) Test-CcodJsonHasNoDuplicateProperties -Json $Json } $packageText
            if (-not $packageUnique) { throw 'package duplicate properties' }
            $package = $packageText | ConvertFrom-Json -ErrorAction Stop
            if ($package.version -is [string] -and $package.version -cmatch '^\d+\.\d+\.\d+\z') { $aboutVersion = [string]$package.version }
        } catch {
            Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_OBSERVATION_UNAVAILABLE' 'The installed package metadata could not be read safely.' $packagePath
        }
    }
    if ($null -ne $activeRuntimeId) {
        if ([string]::IsNullOrWhiteSpace($manifestExpectedVersion) -or $null -eq $activeManifestObject) { Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_OBSERVATION_UNAVAILABLE' 'The active runtime version binding could not be proven.' $activeRuntimeId }
        if (-not [string]::IsNullOrWhiteSpace($ExpectedVersion) -and ($aboutVersion -isnot [string] -or $aboutVersion -cne $ExpectedVersion)) { Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_OBSERVATION_UNAVAILABLE' 'The installed package version is detached from the expected candidate.' $ExpectedVersion }
        [void](Assert-CcodInstalledLifecycleRuntimeManifest -Manifest $activeManifestObject -ExpectedVersion $manifestExpectedVersion -ExpectedRuntimeId $activeRuntimeId -RuntimeRoot (Join-Path (Join-Path $root 'runtime') $activeRuntimeId))
        $runtimeManifestFiles = @($activeManifestObject.files)
        if ($null -ne $ExpectedPayloadFiles -and -not (Test-CcodInstalledLifecycleCandidateFileSet -Actual $runtimeManifestFiles -Expected $ExpectedPayloadFiles -InstallRoot $root -RuntimeId $activeRuntimeId -Generation $activeGeneration -ManifestSha256 $runtimeManifestSha256)) { Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_OBSERVATION_UNAVAILABLE' 'The active runtime file set is detached from the candidate payload manifest.' $activeRuntimeId }
    }
    $codexHome = [Environment]::GetEnvironmentVariable('CODEX_HOME', 'Process')
    if ([string]::IsNullOrWhiteSpace($codexHome)) { $codexHome = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)) '.codex' }
    $deviceKey = if ([IO.Path]::IsPathRooted($codexHome)) { Join-Path $codexHome 'remote-control-device-keys.windows.json' } else { $null }
    $deviceKeyItem = if ($null -eq $deviceKey) { $null } else { Get-CcodInstalledLifecycleOptionalRegularFileState -Path $deviceKey -GetItem $pathProbe }
    $deviceKeyPresent = $null -ne $deviceKeyItem
    $deviceKeySha256 = if ($deviceKeyPresent) { Get-CcodInstalledLifecycleHash -Path $deviceKeyItem.FullName } else { $null }
    $includeDebug = -not [string]::IsNullOrWhiteSpace($ExpectedVersion) -or $null -ne $ExpectedDebugPorts
    $debugPorts = [Collections.Generic.List[int]]::new()
    if ($includeDebug -and $null -ne $status -and $null -ne $status.session -and $null -ne $status.session.codex) {
        foreach ($name in @('mainPort','rendererPort')) {
            $property = $status.session.codex.PSObject.Properties[$name]
            if ($null -eq $property) { Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_OBSERVATION_UNAVAILABLE' 'Debug port facts could not be read safely.' $name }
            $portValue = $property.Value
            if (($portValue -isnot [int] -and $portValue -isnot [long]) -or $portValue -lt 1 -or $portValue -gt 65535) { Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_OBSERVATION_UNAVAILABLE' 'Debug port facts could not be read safely.' $name }
            [void]$debugPorts.Add([int]$portValue)
        }
    }
    $requestedDebugPorts = $null
    if ($null -ne $ExpectedDebugPorts) {
        if ($ExpectedDebugPorts -isnot [array]) { Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_OBSERVATION_UNAVAILABLE' 'Expected debug ports must be an array of integers.' $ExpectedDebugPorts }
        $requestedDebugPorts = @($ExpectedDebugPorts)
        $requestedPortValues = [Collections.Generic.List[int]]::new()
        foreach ($port in $requestedDebugPorts) {
            if (($port -isnot [int] -and $port -isnot [long]) -or $port -is [bool] -or $port -lt 1 -or $port -gt 65535) { Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_OBSERVATION_UNAVAILABLE' 'Expected debug port is invalid.' $port }
            [void]$requestedPortValues.Add([int]$port)
        }
        $requestedDebugPorts = @($requestedPortValues)
        if ($requestedDebugPorts.Count -gt 0) {
            $requestedPortKey = (@($requestedDebugPorts | Sort-Object) -join ',')
            $declaredPortKey = (@($debugPorts | ForEach-Object { [int]$_ } | Sort-Object) -join ',')
            if ($requestedDebugPorts.Count -ne @($requestedDebugPorts | Sort-Object -Unique).Count -or
                $debugPorts.Count -ne $requestedDebugPorts.Count -or $declaredPortKey -cne $requestedPortKey) {
                Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_OBSERVATION_UNAVAILABLE' 'Expected debug ports are detached from the current runtime declaration.' $ExpectedDebugPorts
            }
        }
    }
    $debugEndpoints = [Collections.Generic.List[object]]::new()
    if ($debugPorts.Count -gt 0) {
        try {
            foreach ($listener in @(Get-NetTCPConnection -State Listen -ErrorAction Stop)) {
                if ($null -eq $listener -or $listener.PSObject.Properties['LocalPort'] -eq $null) { throw 'listener port' }
                $listenerPort = $listener.LocalPort
                if (($listenerPort -isnot [uint16] -and $listenerPort -isnot [int] -and $listenerPort -isnot [long]) -or
                    [decimal]$listenerPort -lt 1 -or [decimal]$listenerPort -gt 65535) { throw 'listener port' }
                if ($debugPorts -notcontains [int]$listenerPort) { continue }
                if ($listener.PSObject.Properties['LocalAddress'] -eq $null -or $listener.PSObject.Properties['OwningProcess'] -eq $null -or
                    $listener.LocalAddress -isnot [string] -or $listener.LocalAddress -cne '127.0.0.1') { throw 'listener address' }
                $listenerOwner = $listener.OwningProcess
                if (($listenerOwner -isnot [uint32] -and $listenerOwner -isnot [int] -and $listenerOwner -isnot [long]) -or
                    [decimal]$listenerOwner -lt 1 -or [decimal]$listenerOwner -gt [int]::MaxValue) { throw 'listener scalar' }
                $owner = @($codex | Where-Object { $_.Pid -eq [int]$listenerOwner })
                if ($owner.Count -ne 1) { Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_OBSERVATION_UNAVAILABLE' 'Debug endpoint owner is not a unique verified Codex process.' $listener.OwningProcess }
                $debugEndpoints.Add([pscustomobject][ordered]@{ localAddress = '127.0.0.1'; localPort = [int]$listenerPort; owningProcess = [int]$listenerOwner; owningProcessCreationTimeUtc = [string]$owner[0].CreationTimeUtc })
            }
        } catch { Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_OBSERVATION_UNAVAILABLE' 'Debug endpoints could not be inspected safely.' $null }
    }
    $startMenu = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::Programs)) 'CodexRemote-fix\CodexRemote-fix.lnk'
    $desktop = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::Desktop)) 'CodexRemote-fix.lnk'
    $startMenuItem = Get-CcodInstalledLifecycleOptionalRegularFileState -Path $startMenu -GetItem $pathProbe
    $desktopItem = Get-CcodInstalledLifecycleOptionalRegularFileState -Path $desktop -GetItem $pathProbe
    $publicDebugPorts = [int[]]@()
    $publicDebugEndpoints = @()
    if ($includeDebug) { $publicDebugPorts = [int[]]$debugPorts; $publicDebugEndpoints = @($debugEndpoints) }
    $installReady = [bool]($installRootPresent -and $appRootPresent -and $runtimeRootPresent -and $activePointerPresent -and
        $null -ne $activeRuntimeId -and $activeGeneration -gt 0 -and $null -ne $activeManifestObject -and
        ($null -eq $ExpectedVersion -or $aboutVersion -ceq $ExpectedVersion))
    $protectionReady = [bool]($installReady -and $taskState -in @('Ready','Running') -and $statusPhase -ceq 'Active' -and
        $statusRuntimeId -ceq $activeRuntimeId -and $transitionStage -ceq 'Idle' -and $trayAuthenticated -and
        @($supervisor).Count -eq 1 -and @($trayHost).Count -eq 1 -and @($codex).Count -eq 1 -and $null -ne $statusCodex -and
        $statusCodex.pid -eq $codex[0].Pid -and $statusCodex.creationTimeUtc -ceq $codex[0].CreationTimeUtc -and
        $null -ne $lifecycleReceipt -and $lifecycleReceipt.phase -ceq 'Completed' -and $lifecycleReceipt.runtimeId -ceq $activeRuntimeId -and
        [UInt64]$lifecycleReceipt.runtimeGeneration -eq [UInt64]$activeGeneration)
    return [pscustomobject][ordered]@{
        installRootPresent = [bool]$installRootPresent
        appPresent = [bool]$appRootPresent
        runtimeRootPresent = [bool]$runtimeRootPresent
        activePointerPresent = [bool]$activePointerPresent
        installReady = $installReady
        activeRuntimeId = $activeRuntimeId
        activeGeneration = if ($null -eq $activeRuntimeId) { $null } else { [UInt64]$activeGeneration }
        runtimeManifestSha256 = $runtimeManifestSha256
        runtimeManifestFiles = @($runtimeManifestFiles)
        supervisor = @($supervisor)
        trayHost = @($trayHost)
        trayHostIdentity = $trayHostIdentity
        trayAuthenticated = $trayAuthenticated
        codex = @($codex)
        taskState = $taskState
        statusPhase = $statusPhase
        statusRuntimeId = $statusRuntimeId
        statusCodex = $statusCodex
        transitionStage = $transitionStage
        protectionReady = $protectionReady
        lifecycleReceipt = $lifecycleReceipt
        aboutVersion = $aboutVersion
        deviceKeyPresent = [bool]$deviceKeyPresent
        deviceKeySha256 = $deviceKeySha256
        shortcuts = [pscustomobject][ordered]@{ startMenu = $null -ne $startMenuItem; desktop = $null -ne $desktopItem }
        debugPorts = [int[]]$publicDebugPorts
        debugEndpoints = @($publicDebugEndpoints)
    }
}

function Read-CcodInstalledLifecycleOperatorAck {
    param([Parameter(Mandatory)][string]$Scenario, [Parameter(Mandatory)][string]$Instructions)
    Write-Host ''
    Write-Host ("Installed lifecycle scenario: {0}" -f $Scenario) -ForegroundColor Cyan
    Write-Host $Instructions -ForegroundColor Yellow
    $expected = "CCOD_$($Scenario.ToUpperInvariant())_COMPLETED"
    $acknowledgement = Read-Host "After independently verifying the requested action, type $expected"
    if ($acknowledgement -cne $expected) {
        Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_OPERATOR_NOT_CONFIRMED' 'The requested live scenario was not explicitly confirmed' $Scenario
    }
}

function Get-CcodInstalledLifecycleUninstallCommand {
    param([Parameter(Mandatory)][string]$InstallRoot,[Parameter(Mandatory)][string]$ExpectedVersion,[Parameter(Mandatory)][object[]]$ExpectedPayloadFiles)
    try {
        if($ExpectedVersion-cne'2.5.22'){throw 'sealed uninstall version'}
        $root=Assert-CcodInstalledLifecycleCanonicalAbsolutePath -Path $InstallRoot -Kind 'Uninstall root'
        $facts=Get-CcodInstalledLifecycleFacts -InstallRoot $root -ExpectedVersion $ExpectedVersion -ExpectedPayloadFiles $ExpectedPayloadFiles
        if($facts.activeRuntimeId-isnot[string]-or$facts.activeRuntimeId-cnotmatch'^2\.5\.22-[0-9a-f]{16}-[0-9a-f]{32}\z'-or
            $facts.installReady-isnot[bool]-or-not$facts.installReady-or$facts.protectionReady-isnot[bool]-or-not$facts.protectionReady){throw 'sealed uninstall readiness'}
        $runtime=Join-Path (Join-Path $root 'runtime') $facts.activeRuntimeId
        $path=Assert-CcodInstalledLifecycleRegularFile -Path (Join-Path $runtime 'Uninstall-CodexControlOtherDevices.ps1') -Kind 'Sealed uninstaller'
        $records=@($facts.runtimeManifestFiles|Where-Object {$_.path-ceq'Uninstall-CodexControlOtherDevices.ps1'})
        if($records.Count-ne1-or(Get-CcodInstalledLifecycleHash $path)-cne$records[0].sha256-or[long](Get-Item -LiteralPath $path -ErrorAction Stop).Length-ne[long]$records[0].length){throw 'sealed uninstaller bytes'}
        $active=Read-CcodInstalledLifecycleActiveFact -InstallRoot $root
        if($null-eq$active-or$active.activeRuntime-cne$facts.activeRuntimeId-or[uint64]$active.generation-ne[uint64]$facts.activeGeneration){throw 'uninstall active identity changed'}
        $spec=[pscustomobject][ordered]@{schemaVersion=1;installRoot=$root;expectedVersion=$ExpectedVersion;runtimeId=$facts.activeRuntimeId;generation=$facts.activeGeneration;manifestSha256=$facts.runtimeManifestSha256;runtimeFiles=@($facts.runtimeManifestFiles);candidatePayloadFiles=@($ExpectedPayloadFiles)}
        # Copy the original identity as data, not a mutable view of captured facts.
        return [pscustomobject]@{Spec=($spec|ConvertTo-Json -Depth 8 -Compress|ConvertFrom-Json)}
    } catch {
        Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_OBSERVATION_UNAVAILABLE' 'The direct uninstaller is not bound to the active sealed candidate.' $InstallRoot
    }
}

function Invoke-CcodInstalledLifecycleVerifiedUninstall {
    param([Parameter(Mandatory)]$Spec)
    $lease=$null
    try {
        if (-not(Test-CcodInstalledLifecycleExactProperties $Spec @('schemaVersion','installRoot','expectedVersion','runtimeId','generation','manifestSha256','runtimeFiles','candidatePayloadFiles')) -or
            $Spec.schemaVersion -isnot [int] -or $Spec.schemaVersion -ne 1 -or $Spec.installRoot -isnot [string] -or
            $Spec.expectedVersion -isnot [string] -or $Spec.expectedVersion -cne '2.5.22' -or
            $Spec.runtimeId -isnot [string] -or $Spec.runtimeId -cnotmatch '^2\.5\.22-[0-9a-f]{16}-[0-9a-f]{32}\z' -or
            -not(Test-CcodInstalledLifecyclePositiveInteger $Spec.generation) -or
            $Spec.manifestSha256 -isnot [string] -or $Spec.manifestSha256 -cnotmatch '^[0-9a-f]{64}\z' -or
            $Spec.runtimeFiles -isnot [array] -or $Spec.runtimeFiles.Count -lt 1 -or
            $Spec.candidatePayloadFiles -isnot [array] -or $Spec.candidatePayloadFiles.Count -lt 1 -or
            -not(Test-CcodInstalledLifecycleFileRecordSet $Spec.runtimeFiles $Spec.runtimeFiles) -or
            -not(Test-CcodInstalledLifecycleFileRecordSet $Spec.candidatePayloadFiles $Spec.candidatePayloadFiles)) { throw 'uninstall specification' }
        $root=Assert-CcodInstalledLifecycleCanonicalAbsolutePath $Spec.installRoot 'Uninstall root'
        $runtime=Join-Path (Join-Path $root 'runtime') $Spec.runtimeId
        $manifest=Join-Path $runtime 'manifest.json'
        $paths=@($manifest)+@($Spec.runtimeFiles|ForEach-Object {Join-Path $runtime $_.path})
        $lease=Open-CcodInstalledLifecycleExecutionLease -Paths $paths
        if ($lease.Files[0].Sha256 -cne $Spec.manifestSha256) { throw 'original manifest replaced' }
        for ($index=0; $index -lt $Spec.runtimeFiles.Count; $index++) {
            $record=$Spec.runtimeFiles[$index];$held=$lease.Files[$index+1]
            if ($held.Length -ne $record.length -or $held.Sha256 -cne $record.sha256) { throw 'original runtime replaced' }
        }
        $facts=Get-CcodInstalledLifecycleFacts -InstallRoot $root -ExpectedVersion $Spec.expectedVersion -ExpectedPayloadFiles $Spec.candidatePayloadFiles
        if ($facts.activeRuntimeId -cne $Spec.runtimeId -or $facts.activeGeneration -ne $Spec.generation -or
            $facts.runtimeManifestSha256 -cne $Spec.manifestSha256 -or $facts.installReady -isnot [bool] -or -not $facts.installReady -or
            $facts.protectionReady -isnot [bool] -or -not $facts.protectionReady -or
            -not(Test-CcodInstalledLifecycleFileRecordSet $facts.runtimeManifestFiles $Spec.runtimeFiles)) { throw 'uninstall original state' }
        $wrapperRecords=@($Spec.runtimeFiles|Where-Object {$_.path -ceq 'Uninstall-CodexControlOtherDevices.ps1'})
        if ($wrapperRecords.Count -ne 1) { throw 'uninstall wrapper missing' }
        $active=Read-CcodInstalledLifecycleActiveFact -InstallRoot $root
        if ($null -eq $active -or $active.activeRuntime -cne $Spec.runtimeId -or $active.generation -ne $Spec.generation) { throw 'active selector changed' }
        Assert-CcodInstalledLifecycleExecutionLease $lease
        $values=@(& (Join-Path $runtime 'Uninstall-CodexControlOtherDevices.ps1') -Confirm:$false)
        if ($values.Count -ne 1 -or -not(Test-CcodInstalledLifecycleExactProperties $values[0] @('Outcome','TransactionId','FinalizerProcessId','KeptDeviceKeyStore')) -or
            $values[0].Outcome -isnot [string] -or $values[0].Outcome -cne 'InstalledFinalizationStarted' -or
            $values[0].TransactionId -isnot [string] -or $values[0].TransactionId -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z' -or
            $values[0].FinalizerProcessId -isnot [int] -or $values[0].FinalizerProcessId -lt 1 -or
            $values[0].KeptDeviceKeyStore -isnot [bool] -or -not $values[0].KeptDeviceKeyStore) { throw 'uninstall wrapper completion' }
        Assert-CcodInstalledLifecycleExecutionLease $lease
        return $values[0]
    } catch {
        Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_OBSERVATION_UNAVAILABLE' 'The direct uninstaller changed before or during verified consumption.' $null
    } finally {
        # This executes in the wrapper process, before its exit releases the
        # detached finalizer's existing exact-wrapper-exit barrier.
        Close-CcodInstalledLifecycleExecutionLease $lease
    }
}

function Start-CcodInstalledLifecycleVerifiedUninstall {
    param([Parameter(Mandatory)]$Spec)
    $sourceLease=$null;$process=$null
    try {
        $entry=Join-Path $script:CcodInstalledLifecycleRepositoryRoot 'tests\installed\Invoke-InstalledLifecycleIntegration.ps1'
        $sourcePaths=@($entry,(Join-Path $script:CcodInstalledLifecycleRepositoryRoot 'tools\ReleaseAssetContract.psm1'))
        foreach($leaf in @('PersistenceIO.psm1','StateStore.psm1','TrustedLogonIdentity.psm1','LifecycleTransaction.psm1','KernelObjects.psm1','ProductRegistration.psm1')) {
            $sourcePaths+=Join-Path $script:CcodInstalledLifecycleRepositoryRoot ('src\persistence\modules\'+$leaf)
        }
        $sourceLease=Open-CcodInstalledLifecycleExecutionLease -Paths $sourcePaths
        $inputJson=$Spec|ConvertTo-Json -Depth 8 -Compress
        if ($inputJson.Length -lt 1 -or $inputJson.Length -gt 1048576) { throw 'uninstall input bounds' }
        $start=[Diagnostics.ProcessStartInfo]::new()
        $start.FileName=Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::System)) 'WindowsPowerShell\v1.0\powershell.exe'
        $start.Arguments='-NoLogo -NoProfile -NonInteractive -File "'+$entry+'" -VerifiedUninstallChild -AllowMachineMutation -AllowCodexRestart'
        $start.UseShellExecute=$false;$start.CreateNoWindow=$true
        $start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
        # Windows PowerShell 5.1 has no StandardInputEncoding, so the child must own
        # its input decoding: the default stdin writer can emit a UTF-8 BOM that a
        # legacy console input page would then decode into a corrupt first token.
        $start.StandardOutputEncoding=[Text.UTF8Encoding]::new($false)
        $start.StandardErrorEncoding=[Text.UTF8Encoding]::new($false)
        [void]$start.EnvironmentVariables.Remove('PSExecutionPolicyPreference')
        Assert-CcodInstalledLifecycleExecutionLease $sourceLease
        $process=[Diagnostics.Process]::Start($start)
        $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        # Write explicit UTF-8 bytes with no byte-order mark: Windows PowerShell 5.1
        # cannot pin ProcessStartInfo.StandardInputEncoding, so the inherited console
        # page could otherwise prepend a BOM and corrupt the child's first JSON token.
        $inputBytes=[Text.UTF8Encoding]::new($false).GetBytes($inputJson)
        $process.StandardInput.BaseStream.Write($inputBytes,0,$inputBytes.Length)
        $process.StandardInput.BaseStream.Flush()
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(600000)) { throw 'verified uninstall child timeout' }
        $output=$stdout.GetAwaiter().GetResult();$errorOutput=$stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0 -or $output -cne ('CCOD_UNINSTALL_WRAPPER_COMPLETED'+[Environment]::NewLine) -or $errorOutput.Length -ne 0) {
            throw 'verified uninstall child result'
        }
        Assert-CcodInstalledLifecycleExecutionLease $sourceLease
        return [pscustomobject]@{ExitCode=0}
    } catch { Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_INSTALLER_FAILED' 'The verified uninstall child did not complete its wrapper handoff.' $null }
    finally {
        if ($null -ne $process) {
            try { if (-not $process.HasExited) { $process.Kill();$process.WaitForExit() } } finally { $process.Dispose() }
        }
        Close-CcodInstalledLifecycleExecutionLease $sourceLease
    }
}

function Invoke-CcodInstalledLifecycleOperatorScenario {
    param([Parameter(Mandatory)]$Context)
    $launchInstaller = {
        $process = Start-Process -FilePath $Context.installerPath -PassThru -Wait -ErrorAction Stop
        if ($process.ExitCode -ne 0) {
            Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_INSTALLER_FAILED' 'The operator-visible installer returned a nonzero exit code' $process.ExitCode
        }
    }.GetNewClosure()
    switch ($Context.scenario) {
        'FreshInstall' {
            & $launchInstaller
            Read-CcodInstalledLifecycleOperatorAck -Scenario $Context.scenario -Instructions 'Complete the fresh install, choose Later, and wait for the new controlled Codex session and tray to become ready.'
        }
        'FreshLater' {
            & $launchInstaller
            Read-CcodInstalledLifecycleOperatorAck -Scenario $Context.scenario -Instructions 'Complete the installer and choose Later. Confirm that the pre-existing Codex session was left untouched.'
        }
        'FreshRestart' {
            & $launchInstaller
            Read-CcodInstalledLifecycleOperatorAck -Scenario $Context.scenario -Instructions 'Complete the installer, choose Restart now, and wait for the new controlled Codex session and tray to become ready.'
        }
        'Upgrade' {
            & $launchInstaller
            Read-CcodInstalledLifecycleOperatorAck -Scenario $Context.scenario -Instructions 'Complete the upgrade and observe the requested restart/later behavior before acknowledging it.'
        }
        'SettingsUninstall' {
            Start-Process 'ms-settings:appsfeatures' -ErrorAction Stop | Out-Null
            Read-CcodInstalledLifecycleOperatorAck -Scenario $Context.scenario -Instructions 'Use Windows Settings to uninstall CodexRemote-fix. Wait for the uninstaller to complete successfully.'
        }
        'DirectUninstall' {
            if($Context.expectedVersion-ceq'2.5.22'){
                $command=Get-CcodInstalledLifecycleUninstallCommand -InstallRoot $Context.installRoot -ExpectedVersion $Context.expectedVersion -ExpectedPayloadFiles $Context.candidatePayloadFiles
                $process=Start-CcodInstalledLifecycleVerifiedUninstall -Spec $command.Spec
            } else {
                $uninstaller = Assert-CcodInstalledLifecycleRegularFile -Path (Join-Path $Context.installerApplicationRoot 'unins000.exe') -Kind 'Installed uninstaller'
                $process = Start-Process -FilePath $uninstaller -PassThru -Wait -ErrorAction Stop
            }
            if ($process.ExitCode -ne 0) { Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_INSTALLER_FAILED' 'The installed uninstaller returned a nonzero exit code' $process.ExitCode }
            Read-CcodInstalledLifecycleOperatorAck -Scenario $Context.scenario -Instructions 'Confirm that the direct uninstaller completed and did not remove the device-key store.'
        }
        default {
            Read-CcodInstalledLifecycleOperatorAck -Scenario $Context.scenario -Instructions 'Perform the named scenario through the visible CodexRemote-fix UI and wait for its observable state to settle.'
        }
    }
    $runtimeManifestSha256 = $null
    if ($Context.scenario -in @('FreshInstall','FreshLater','FreshRestart','Upgrade','SlowLaunch','ManualLaunchResume','LanguageStress','RepairStates')) {
        try {
            $postOperationFacts = Get-CcodInstalledLifecycleFacts -InstallRoot $Context.installRoot -ExpectedVersion $Context.expectedVersion -ExpectedPayloadFiles $Context.candidatePayloadFiles
            if ($postOperationFacts.runtimeManifestSha256 -isnot [string] -or $postOperationFacts.runtimeManifestSha256 -cnotmatch '^[0-9a-f]{64}\z') { throw 'runtime manifest attestation' }
            $runtimeManifestSha256 = [string]$postOperationFacts.runtimeManifestSha256
        } catch {
            if ($_.FullyQualifiedErrorId -like 'CCOD_INTEGRATION_*') { throw }
            Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_OBSERVATION_UNAVAILABLE' 'The operator completion did not produce a candidate-bound runtime manifest attestation.' $Context.scenario
        }
    }
    return [pscustomobject][ordered]@{
        code = 'CCOD_INTEGRATION_OPERATOR_COMPLETED'
        scenario = [string]$Context.scenario
        transactionId = [string]$Context.transactionId
        completed = $true
        operatorAttestation = 'OperatorConfirmed'
        installerSha256 = [string](Get-CcodInstalledLifecycleHash -Path $Context.installerPath)
        runtimeManifestSha256 = $runtimeManifestSha256
    }
}

function Test-CcodInstalledLifecycleSameIdentitySet {
    param($Expected, $Actual)
    $expectedKeys = @($Expected | ForEach-Object { '{0}|{1}' -f $_.pid, $_.creationTimeUtc } | Sort-Object)
    $actualKeys = @($Actual | ForEach-Object { '{0}|{1}' -f $_.pid, $_.creationTimeUtc } | Sort-Object)
    return (($expectedKeys -join ';') -ceq ($actualKeys -join ';'))
}

function Test-CcodInstalledLifecycleRunResult {
    param([Parameter(Mandatory)]$Context,[Parameter(Mandatory)]$RunResult)
    if (-not (Test-CcodInstalledLifecycleExactProperties -Value $RunResult -Expected @('code','scenario','transactionId','completed','operatorAttestation','installerSha256','runtimeManifestSha256'))) { return $false }
    $parsedTransactionId = [guid]::Empty
    if ($RunResult.code -isnot [string] -or $RunResult.code -cne 'CCOD_INTEGRATION_OPERATOR_COMPLETED' -or
        $RunResult.scenario -isnot [string] -or $RunResult.scenario -cne [string]$Context.scenario -or
        $RunResult.transactionId -isnot [string] -or -not [guid]::TryParse($RunResult.transactionId,[ref]$parsedTransactionId) -or
        $RunResult.completed -isnot [bool] -or -not $RunResult.completed -or
        $RunResult.operatorAttestation -isnot [string] -or $RunResult.operatorAttestation -cne 'OperatorConfirmed' -or
        $RunResult.installerSha256 -isnot [string] -or $RunResult.installerSha256 -cnotmatch '^[0-9a-f]{64}\z' -or
        $Context.installerSha256 -isnot [string] -or $RunResult.installerSha256 -cne [string]$Context.installerSha256) { return $false }
    $requiresRuntimeManifest = $Context.scenario -in @('FreshInstall','FreshLater','FreshRestart','Upgrade','SlowLaunch','ManualLaunchResume','LanguageStress','RepairStates')
    if ($requiresRuntimeManifest) { return $RunResult.runtimeManifestSha256 -is [string] -and $RunResult.runtimeManifestSha256 -cmatch '^[0-9a-f]{64}\z' }
    return $null -eq $RunResult.runtimeManifestSha256
}

function Test-CcodInstalledLifecycleDebugPortsClosed {
    param($Ports)
    try {
        if ($Ports -isnot [array]) { throw 'captured ports array' }
        $captured = [Collections.Generic.HashSet[int]]::new()
        foreach ($port in $Ports) {
            if (($port -isnot [int] -and $port -isnot [long]) -or $port -lt 1 -or $port -gt 65535 -or
                -not $captured.Add([int]$port)) { throw 'captured port' }
        }
        if ($captured.Count -eq 0) { return $true }
        foreach ($listener in @(Get-NetTCPConnection -State Listen -ErrorAction Stop)) {
            if ($null -eq $listener -or $null -eq $listener.PSObject.Properties['LocalPort']) { throw 'listener port unavailable' }
            $port = $listener.LocalPort
            if (($port -isnot [uint16] -and $port -isnot [int] -and $port -isnot [long]) -or
                $port -lt 1 -or $port -gt 65535) { throw 'listener port shape' }
            if ($captured.Contains([int]$port)) { return $false }
        }
        return $true
    } catch {
        Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_OBSERVATION_UNAVAILABLE' 'Previously declared debug ports could not be inspected safely.' $null
    }
}

function Test-CcodInstalledLifecycleScenario {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$BeforeFacts, [Parameter(Mandatory)]$RunResult)
    if (-not (Test-CcodInstalledLifecycleRunResult -Context $Context -RunResult $RunResult)) {
        return [pscustomobject][ordered]@{ verified = $false; code = 'CCOD_INTEGRATION_OBSERVATION_UNPROVEN'; facts = $null }
    }
    $expectedDebugPorts = @()
    if ($Context.PSObject.Properties['expectedDebugPorts'] -and $null -ne $Context.expectedDebugPorts) { $expectedDebugPorts = @($Context.expectedDebugPorts) }
    elseif ($BeforeFacts.PSObject.Properties['debugPorts'] -and $null -ne $BeforeFacts.debugPorts) { $expectedDebugPorts = @($BeforeFacts.debugPorts) }
    elseif ($BeforeFacts.PSObject.Properties['debugEndpoints']) { foreach ($endpoint in @($BeforeFacts.debugEndpoints)) { if ($endpoint.PSObject.Properties['localPort'] -and $endpoint.localPort -is [ValueType]) { $expectedDebugPorts += [int]$endpoint.localPort } } }
    $expectedPayloadFiles = $null
    if ($Context.PSObject.Properties['candidatePayloadFiles']) { $expectedPayloadFiles = @($Context.candidatePayloadFiles) }
    $requiresDebugEvidence = $Context.scenario -notin @('SafeExit','SettingsUninstall','DirectUninstall')
    $afterFacts = if ($requiresDebugEvidence -and $expectedDebugPorts.Count -gt 0) {
        ConvertTo-CcodInstalledLifecycleFacts -Facts (Get-CcodInstalledLifecycleFacts -InstallRoot $Context.installRoot -ExpectedVersion $Context.expectedVersion -ExpectedDebugPorts $expectedDebugPorts -ExpectedPayloadFiles $expectedPayloadFiles)
    } else {
        ConvertTo-CcodInstalledLifecycleFacts -Facts (Get-CcodInstalledLifecycleFacts -InstallRoot $Context.installRoot -ExpectedVersion $Context.expectedVersion -ExpectedPayloadFiles $expectedPayloadFiles)
    }
    $payloadEvidenceValid = $true
    if ($null -ne $expectedPayloadFiles) { $payloadEvidenceValid = Test-CcodInstalledLifecycleCandidateFileSet -Actual $afterFacts.runtimeManifestFiles -Expected $expectedPayloadFiles -InstallRoot $Context.installRoot -RuntimeId $afterFacts.activeRuntimeId -Generation $afterFacts.activeGeneration -ManifestSha256 $afterFacts.runtimeManifestSha256 }
    if ($Context.scenario -in @('FreshInstall','FreshRestart') -and $expectedDebugPorts.Count -eq 0) { $expectedDebugPorts = @($afterFacts.debugPorts) }
    $debugEvidenceValid = $true
    if ($Context.scenario -in @('FreshInstall','FreshLater','FreshRestart','Upgrade')) {
        $afterPorts = @($afterFacts.debugPorts)
        $afterEndpoints = @($afterFacts.debugEndpoints)
        $codexIdentities = @($afterFacts.codex)
        $expectedPortKey = (@($expectedDebugPorts | ForEach-Object { [int]$_ } | Sort-Object) -join ',')
        $afterPortKey = (@($afterPorts | ForEach-Object { [int]$_ } | Sort-Object) -join ',')
        $expectedPortCount = @($expectedDebugPorts | Sort-Object -Unique).Count
        if ($expectedDebugPorts.Count -ne 2 -or $expectedPortCount -ne 2 -or
            $afterPorts.Count -ne $expectedDebugPorts.Count -or $afterPortKey -cne $expectedPortKey -or
            $afterEndpoints.Count -ne $expectedDebugPorts.Count -or $codexIdentities.Count -ne 1) {
            $debugEvidenceValid = $false
        } else {
            $owner = $codexIdentities[0]
            foreach ($port in $expectedDebugPorts) {
                $matches = @($afterEndpoints | Where-Object {
                    $_.localAddress -is [string] -and $_.localAddress -ceq '127.0.0.1' -and
                    $_.localPort -is [ValueType] -and $_.localPort -isnot [bool] -and [int]($_.localPort) -eq [int]$port -and
                    $_.owningProcess -is [ValueType] -and $_.owningProcess -isnot [bool] -and [uint64]($_.owningProcess) -eq [uint64]$owner.pid -and
                    $_.owningProcessCreationTimeUtc -is [string] -and $_.owningProcessCreationTimeUtc -ceq [string]$owner.creationTimeUtc
                })
                if ($matches.Count -ne 1) { $debugEvidenceValid = $false }
            }
        }
    }
    $verified = $true
    $code = 'CCOD_INTEGRATION_VERIFIED'
    if ($Context.scenario -in @('SettingsUninstall','DirectUninstall')) {
        $portsClosed = Test-CcodInstalledLifecycleDebugPortsClosed -Ports $BeforeFacts.debugPorts
        $verified = $portsClosed -and -not $afterFacts.installRootPresent -and -not $afterFacts.appPresent -and -not $afterFacts.runtimeRootPresent -and -not $afterFacts.activePointerPresent -and
            $afterFacts.taskState -ceq 'Absent' -and $afterFacts.statusCodex -eq $null -and $afterFacts.statusRuntimeId -eq $null -and
            $afterFacts.statusPhase -in @('Unavailable','Stopped','Closed') -and $afterFacts.transitionStage -in @('Unavailable','Idle','Completed','Failed','Cancelled') -and
            $afterFacts.supervisor.Count -eq 0 -and $afterFacts.trayHost.Count -eq 0 -and $afterFacts.codex.Count -eq 0 -and
            $afterFacts.shortcuts.startMenu -eq $false -and $afterFacts.shortcuts.desktop -eq $false -and $afterFacts.debugEndpoints.Count -eq 0 -and $null -eq $afterFacts.lifecycleReceipt
        if ($BeforeFacts.deviceKeyPresent) { $verified = $verified -and $afterFacts.deviceKeyPresent -and $afterFacts.deviceKeySha256 -ceq $BeforeFacts.deviceKeySha256 }
        else { $verified = $verified -and -not $afterFacts.deviceKeyPresent -and $null -eq $afterFacts.deviceKeySha256 }
    } elseif ($Context.scenario -eq 'SafeExit') {
        $verified = $afterFacts.appPresent -and $afterFacts.supervisor.Count -eq 0 -and $afterFacts.trayHost.Count -eq 0
    } else {
        $verified = $afterFacts.installRootPresent -and $afterFacts.appPresent -and $afterFacts.aboutVersion -ceq $Context.expectedVersion -and $null -ne $afterFacts.activeRuntimeId -and $afterFacts.taskState -in @('Ready','Running') -and $debugEvidenceValid -and $payloadEvidenceValid -and
            $afterFacts.installReady -is [bool] -and $afterFacts.installReady -and $afterFacts.protectionReady -is [bool] -and $afterFacts.protectionReady -and
            $afterFacts.trayAuthenticated -is [bool] -and $afterFacts.trayAuthenticated -and $null -ne $afterFacts.trayHostIdentity -and
            $RunResult.runtimeManifestSha256 -ceq [string]$afterFacts.runtimeManifestSha256
        if ($Context.scenario -in @('FreshInstall','FreshLater','Upgrade')) {
            $verified = $verified -and $afterFacts.supervisor.Count -eq 1 -and $afterFacts.trayHost.Count -eq 1 -and $afterFacts.codex.Count -eq 1 -and
                $afterFacts.statusPhase -ceq 'Active' -and $afterFacts.statusRuntimeId -ceq $afterFacts.activeRuntimeId -and $null -ne $afterFacts.statusCodex -and
                $afterFacts.statusCodex.pid -eq $afterFacts.codex[0].Pid -and $afterFacts.statusCodex.creationTimeUtc -ceq $afterFacts.codex[0].CreationTimeUtc -and
                $afterFacts.transitionStage -ceq 'Idle' -and $null -ne $afterFacts.lifecycleReceipt -and
                $afterFacts.lifecycleReceipt.kind -ceq 'RestartAndRepair' -and $afterFacts.lifecycleReceipt.origin -ceq 'Installer' -and
                $afterFacts.lifecycleReceipt.runtimeId -ceq $afterFacts.activeRuntimeId -and
                [UInt64]$afterFacts.lifecycleReceipt.runtimeGeneration -eq [UInt64]$afterFacts.activeGeneration -and
                $afterFacts.lifecycleReceipt.phase -ceq 'Completed'
        }
        if ($BeforeFacts.deviceKeyPresent) { $verified = $verified -and $afterFacts.deviceKeyPresent -and $afterFacts.deviceKeySha256 -ceq $BeforeFacts.deviceKeySha256 }
        if ($Context.scenario -eq 'FreshLater' -and $BeforeFacts.codex.Count -eq 1) {
            $verified = $verified -and (Test-CcodInstalledLifecycleSameIdentitySet -Expected $BeforeFacts.codex -Actual $afterFacts.codex)
        }
        if ($Context.scenario -eq 'FreshLater' -and $BeforeFacts.codex.Count -ne 1) { $verified = $false }
        if ($Context.scenario -eq 'FreshInstall') {
            $verified = $verified -and $BeforeFacts.codex.Count -eq 0 -and
                -not $BeforeFacts.installRootPresent -and -not $BeforeFacts.appPresent -and -not $BeforeFacts.runtimeRootPresent -and
                -not $BeforeFacts.activePointerPresent -and $BeforeFacts.taskState -ceq 'Absent' -and
                $BeforeFacts.supervisor.Count -eq 0 -and $BeforeFacts.trayHost.Count -eq 0 -and
                $BeforeFacts.statusPhase -in @('Unavailable','Stopped','Closed') -and $null -eq $BeforeFacts.statusRuntimeId -and
                $null -eq $BeforeFacts.statusCodex -and $BeforeFacts.transitionStage -in @('Unavailable','Idle') -and
                $null -eq $BeforeFacts.lifecycleReceipt -and -not $BeforeFacts.shortcuts.startMenu -and -not $BeforeFacts.shortcuts.desktop -and
                $BeforeFacts.debugPorts.Count -eq 0 -and $BeforeFacts.debugEndpoints.Count -eq 0
        }
        if ($Context.scenario -eq 'FreshRestart') {
            $rootIdentityReplaced = $true
            if ($BeforeFacts.codex.Count -gt 0) {
                $rootIdentityReplaced = $afterFacts.codex.Count -eq 1 -and @($BeforeFacts.codex | Where-Object {
                    $_.pid -eq $afterFacts.codex[0].pid -and $_.creationTimeUtc -ceq $afterFacts.codex[0].creationTimeUtc
                }).Count -eq 0
            }
            $verified = $verified -and
                $afterFacts.codex.Count -eq 1 -and
                $rootIdentityReplaced -and
                $afterFacts.statusPhase -ceq 'Active' -and
                $afterFacts.statusRuntimeId -ceq $afterFacts.activeRuntimeId -and
                $null -ne $afterFacts.statusCodex -and
                $afterFacts.statusCodex.pid -eq $afterFacts.codex[0].pid -and
                $afterFacts.statusCodex.creationTimeUtc -ceq $afterFacts.codex[0].creationTimeUtc -and
                $afterFacts.transitionStage -ceq 'Idle' -and
                $null -ne $afterFacts.lifecycleReceipt -and
                $afterFacts.lifecycleReceipt.kind -ceq 'RestartAndRepair' -and
                $afterFacts.lifecycleReceipt.origin -ceq 'Installer' -and
                $afterFacts.lifecycleReceipt.runtimeId -ceq $afterFacts.activeRuntimeId -and
                [UInt64]$afterFacts.lifecycleReceipt.runtimeGeneration -eq [UInt64]$afterFacts.activeGeneration -and
                $afterFacts.lifecycleReceipt.phase -ceq 'Completed'
        }
    }
    if (-not $verified) { $code = 'CCOD_INTEGRATION_OBSERVATION_UNPROVEN' }
    return [pscustomobject][ordered]@{ verified = [bool]$verified; code = $code; facts = $afterFacts }
}

function Invoke-CcodInstalledLifecycleRollback {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Snapshot)
    if (-not [string]::IsNullOrWhiteSpace([string]$Context.previousInstallerPath)) {
        try {
            $expectedVersion = if ($Context.PSObject.Properties['previousExpectedVersion']) { [string]$Context.previousExpectedVersion } else { $null }
            $expectedInstallerHash = if ($Context.PSObject.Properties['previousInstallerSha256']) { [string]$Context.previousInstallerSha256 } else { $null }
            $expectedManifestHash = if ($Context.PSObject.Properties['previousManifestSha256']) { [string]$Context.previousManifestSha256 } else { $null }
            $installer = Assert-CcodInstalledLifecycleRegularFile -Path ([string]$Context.previousInstallerPath) -Kind 'Frozen previous installer'
            $installerName = [IO.Path]::GetFileName($installer)
            $versionMatch = [regex]::Match($installerName, '^CodexRemote-fix-(?<version>\d+\.\d+\.\d+)-setup\.exe\z')
            if (-not $versionMatch.Success -or $versionMatch.Groups['version'].Value -cne $expectedVersion -or
                $expectedInstallerHash -notmatch '^[0-9a-f]{64}\z' -or (Get-CcodInstalledLifecycleHash -Path $installer) -cne $expectedInstallerHash) { throw 'rollback installer identity' }
            $manifestName = 'CodexRemote-fix-{0}-setup-release-manifest.json' -f $expectedVersion
            $manifest = Assert-CcodInstalledLifecycleRegularFile -Path (Join-Path (Split-Path -Parent $installer) $manifestName) -Kind 'Frozen previous installer release manifest'
            if ($expectedManifestHash -notmatch '^[0-9a-f]{64}\z' -or (Get-CcodInstalledLifecycleHash -Path $manifest) -cne $expectedManifestHash) { throw 'rollback manifest identity' }
        } catch {
            if ($_.FullyQualifiedErrorId -like 'CCOD_INTEGRATION_ROLLBACK_FAILED*') { throw }
            Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_ROLLBACK_FAILED' 'The frozen prior installer identity could not be revalidated before rollback.' $Context.previousInstallerPath
        }
        $process = Start-Process -FilePath $installer -PassThru -Wait -ErrorAction Stop
        if ($process.ExitCode -ne 0) { Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_ROLLBACK_FAILED' 'The prior installer did not complete during rollback' $process.ExitCode }
        Read-CcodInstalledLifecycleOperatorAck -Scenario 'ROLLBACK' -Instructions 'Verify that the prior installer restored the pre-test application state.'
        return [pscustomobject][ordered]@{ restored = $true; code = 'CCOD_INTEGRATION_ROLLBACK_COMPLETED' }
    }
    Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_ROLLBACK_UNAVAILABLE' 'No prior installer was supplied for an observable rollback path' $Context.scenario
}

function Remove-CcodInstalledLifecycleFrozenRoot {
    param([Parameter(Mandatory)][string]$Path)
    try {
        $root = Assert-CcodInstalledLifecycleCanonicalAbsolutePath -Path $Path -Kind 'Frozen rollback root'
        $rootItem = Get-Item -LiteralPath $root -Force -ErrorAction Stop
        if ($rootItem -isnot [IO.DirectoryInfo] -or ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'frozen root identity' }
        Assert-CcodInstalledLifecycleNoReparseAncestors -Path $root -GetItem { param($CandidatePath) Get-Item -LiteralPath $CandidatePath -Force -ErrorAction Stop }
        $pendingDirectories = [Collections.Generic.Stack[string]]::new()
        $pendingDirectories.Push($root)
        while ($pendingDirectories.Count -gt 0) {
            $current = $pendingDirectories.Pop()
            foreach ($child in @(Get-ChildItem -LiteralPath $current -Force -ErrorAction Stop)) {
                if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'frozen descendant reparse' }
                if ($child -is [IO.DirectoryInfo]) { $pendingDirectories.Push($child.FullName) }
                elseif ($child -isnot [IO.FileInfo]) { throw 'frozen descendant identity' }
            }
        }
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop
        if (Test-Path -LiteralPath $root) { throw 'frozen root residue' }
        return $true
    } catch {
        if ($_.FullyQualifiedErrorId -like 'CCOD_INTEGRATION_ROLLBACK_CLEANUP_FAILED*') { throw }
        Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_ROLLBACK_CLEANUP_FAILED' 'The frozen rollback root or one of its descendants was unsafe to remove.' $Path
    }
}

function Invoke-CcodInstalledLifecycleIntegration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$InstallerPath,
        [string]$PreviousInstallerPath,
        [string]$PreviousExpectedVersion,
        [string]$PreviousInstallerSha256,
        [string]$PreviousManifestSha256,
        [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+\z')][string]$ExpectedVersion,
        [Parameter(Mandatory)][string]$EvidenceRoot,
        [switch]$AllowMachineMutation,
        [switch]$AllowCodexRestart,
        [Parameter(Mandatory)][ValidateSet('FreshInstall','FreshLater','FreshRestart','Upgrade','SlowLaunch','ManualLaunchResume','LanguageStress','RepairStates','SafeExit','SettingsUninstall','DirectUninstall')][string]$Scenario,
        $ExpectedCandidate,
        [hashtable]$Adapters
    )
    if (-not $AllowMachineMutation) {
        Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_MUTATION_NOT_ALLOWED' 'Live installed lifecycle scenarios require -AllowMachineMutation before any candidate, checkout, or machine operation.' $Scenario
    }
    if ($script:CcodInstalledLifecycleRestartScenarios -icontains $Scenario -and -not $AllowCodexRestart) {
        Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_CODEX_RESTART_NOT_ALLOWED' 'This scenario can stop or restart Codex and requires -AllowCodexRestart before any operation.' $Scenario
    }
    $adapters = Resolve-CcodInstalledLifecycleAdapters -Adapters $Adapters
    $startedAtValues = @(& $adapters.GetUtcNow)
    if ($startedAtValues.Count -ne 1 -or -not (Test-CcodInstalledLifecycleValidUtcClock -Value $startedAtValues[0])) { Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_CLOCK_INVALID' 'The integration clock did not return one valid UTC DateTime value' $startedAtValues }
    $startedAt = $startedAtValues[0]
    $transactionId = [guid]::NewGuid().ToString('D')
    $phases = [Collections.Generic.List[object]]::new()
    $evidenceDirectory = $null
    $snapshot = $null
    $failure = $null
    $failureCode = $null
    $rollback = [pscustomobject][ordered]@{ attempted = $false; completed = $false; code = $null }
    $candidate = $null
    $candidateExecutionLease = $null
    $previousExecutionLease = $null
    $previousCandidate = $null
    $frozenPreviousRoot = $null
    $frozenPreviousInstallerPath = $null
    $frozenPreviousManifestPath = $null
    $beforeFacts = $null
    $verification = $null
    try {
        $candidate = Get-CcodInstalledLifecycleCandidate -Path $InstallerPath -ExpectedVersion $ExpectedVersion -Adapters $adapters -Kind 'Installer' -ExecutionLease ([ref]$candidateExecutionLease)
        if ($PSBoundParameters.ContainsKey('ExpectedCandidate')) { Assert-CcodInstalledLifecycleExpectedCandidate -Candidate $candidate -Expected $ExpectedCandidate }
        if ($Scenario -ceq 'Upgrade') {
            if ([string]::IsNullOrWhiteSpace($PreviousInstallerPath)) { Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_PREVIOUS_INSTALLER_REQUIRED' 'Upgrade scenarios require a checksum-bound previous installer for rollback.' $Scenario }
            if ([string]::IsNullOrWhiteSpace($PreviousExpectedVersion) -or [string]::IsNullOrWhiteSpace($PreviousInstallerSha256) -or [string]::IsNullOrWhiteSpace($PreviousManifestSha256)) {
                Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_PREVIOUS_INSTALLER_REQUIRED' 'Upgrade scenarios require the exact validated previous version and manifest-bound installer hashes.' $Scenario
            }
            try {
                $previousCandidate = Get-CcodInstalledLifecycleCandidate -Path $PreviousInstallerPath -ExpectedVersion $PreviousExpectedVersion -Adapters $adapters -Kind 'Previous installer'
                if ([version]$previousCandidate.Version -ge [version]$ExpectedVersion -or $previousCandidate.Version -cne $PreviousExpectedVersion -or $previousCandidate.Sha256 -cne $PreviousInstallerSha256) { throw 'previous installer identity' }
                $previousManifestName = 'CodexRemote-fix-{0}-setup-release-manifest.json' -f $previousCandidate.Version
                $previousManifestPath = Assert-CcodInstalledLifecycleRegularFile -Path (Join-Path (Split-Path -Parent $previousCandidate.Path) $previousManifestName) -Kind 'Previous installer release manifest'
                $previousManifestActualHash = [string](& $adapters.GetFileSha256 $previousManifestPath)
                if ($previousManifestActualHash -cnotmatch '^[0-9a-f]{64}\z' -or $previousManifestActualHash -cne $PreviousManifestSha256) { throw 'previous manifest identity' }
                $temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
                [void](Assert-CcodInstalledLifecycleSafeDirectory -Path $temporaryRoot -Kind 'System temporary root')
                $frozenPreviousRoot = [IO.Path]::GetFullPath((Join-Path $temporaryRoot ('ccod-frozen-previous-' + [guid]::NewGuid().ToString('N'))))
                [void](Assert-CcodInstalledLifecycleSafeDirectory -Path $frozenPreviousRoot -Kind 'Frozen previous root')
                $frozenPreviousInstallerPath = Join-Path $frozenPreviousRoot ([IO.Path]::GetFileName($previousCandidate.Path))
                $frozenPreviousManifestPath = Join-Path $frozenPreviousRoot $previousManifestName
                [IO.File]::Copy($previousCandidate.Path, $frozenPreviousInstallerPath, $false)
                [IO.File]::Copy($previousManifestPath, $frozenPreviousManifestPath, $false)
                [void](Assert-CcodInstalledLifecycleRegularFile -Path $frozenPreviousInstallerPath -Kind 'Frozen previous installer')
                [void](Assert-CcodInstalledLifecycleRegularFile -Path $frozenPreviousManifestPath -Kind 'Frozen previous installer release manifest')
                $previousExecutionLease = Open-CcodInstalledLifecycleExecutionLease -Paths @($frozenPreviousInstallerPath,$frozenPreviousManifestPath)
                if ((Get-CcodInstalledLifecycleHash -Path $frozenPreviousInstallerPath) -cne $PreviousInstallerSha256 -or (Get-CcodInstalledLifecycleHash -Path $frozenPreviousManifestPath) -cne $PreviousManifestSha256) { throw 'frozen previous identity' }
            } catch {
                Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_PREVIOUS_INSTALLER_INVALID' 'Upgrade rollback installer and manifest are not the exact validated prior identity.' $PreviousInstallerPath
            }
        } elseif (-not [string]::IsNullOrWhiteSpace($PreviousInstallerPath)) {
            Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_PREVIOUS_INSTALLER_UNEXPECTED' 'A previous installer is allowed only for the Upgrade scenario.' $Scenario
        }
        $checkout = @(& $adapters.GetGitStatus (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent))
        if ($checkout.Count -ne 0) { Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_CHECKOUT_DIRTY' 'Live integration refuses a dirty checkout.' $null }
        $phases.Add((New-CcodInstalledLifecyclePhase -Name 'Preflight' -Outcome 'Completed'))
        $evidenceDirectory = & $adapters.NewEvidenceDirectory $EvidenceRoot $transactionId
        if ($evidenceDirectory -isnot [string] -or -not [IO.Path]::IsPathRooted($evidenceDirectory)) { Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_EVIDENCE_ROOT_INVALID' 'Evidence directory adapter returned an invalid path' $evidenceDirectory }
        $installRoot = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'CodexControlOtherDevices'
        $installerApplicationRoot = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'CodexControlOtherDevices-installer'
        $context = [pscustomobject][ordered]@{
            transactionId = $transactionId
            scenario = $Scenario
            installerPath = $candidate.Path
            previousInstallerPath = if ($null -eq $previousCandidate) { $null } else { $frozenPreviousInstallerPath }
            previousExpectedVersion = if ($null -eq $previousCandidate) { $null } else { $PreviousExpectedVersion }
            previousInstallerSha256 = if ($null -eq $previousCandidate) { $null } else { $PreviousInstallerSha256 }
            previousManifestSha256 = if ($null -eq $previousCandidate) { $null } else { $PreviousManifestSha256 }
            previousManifestPath = if ($null -eq $previousCandidate) { $null } else { $frozenPreviousManifestPath }
            expectedVersion = $ExpectedVersion
            installRoot = [IO.Path]::GetFullPath($installRoot)
            installerApplicationRoot = [IO.Path]::GetFullPath($installerApplicationRoot)
            installerSha256 = [string]$candidate.Sha256
            candidatePayloadManifestSha256 = [string]$candidate.PayloadManifestSha256
            candidatePayloadFiles = @($candidate.PayloadFiles)
        }
        $beforeObservationVersion = if ($Scenario -ceq 'Upgrade') { $PreviousExpectedVersion } else { $ExpectedVersion }
        $beforeFactsRaw = & $adapters.CaptureFacts $context.installRoot $beforeObservationVersion
        $context | Add-Member -NotePropertyName expectedDebugPorts -NotePropertyValue @($beforeFactsRaw.debugPorts)
        $beforeFacts = ConvertTo-CcodInstalledLifecycleFacts -Facts $beforeFactsRaw
        $snapshot = & $adapters.CreateRollbackSnapshot $context $beforeFacts
        if ($null -eq $snapshot) { Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_SNAPSHOT_FAILED' 'Rollback snapshot adapter returned no snapshot.' $null }
        $phases.Add((New-CcodInstalledLifecyclePhase -Name 'CaptureRollback' -Outcome 'Completed'))
        try {
            Assert-CcodInstalledLifecycleExecutionLease $candidateExecutionLease
            $runResult = & $adapters.RunScenario $context
            Assert-CcodInstalledLifecycleExecutionLease $candidateExecutionLease
        } catch {
            Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_SCENARIO_FAILED' 'The live scenario failed before verification.' (Get-CcodInstalledLifecycleErrorId $_)
        }
        if ($null -eq $runResult -or -not (Test-CcodInstalledLifecycleRunResult -Context $context -RunResult $runResult)) { Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_SCENARIO_FAILED' 'The live scenario did not return a complete candidate-bound attestation.' $runResult }
        $phases.Add((New-CcodInstalledLifecyclePhase -Name 'RunScenario' -Outcome 'Completed'))
        try {
            $verification = & $adapters.VerifyScenario $context $beforeFacts $runResult
        } catch {
            Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_VERIFICATION_FAILED' 'The live scenario could not be verified.' (Get-CcodInstalledLifecycleErrorId $_)
        }
        if ($null -eq $verification -or $verification.verified -isnot [bool] -or -not [bool]$verification.verified -or $verification.code -isnot [string]) {
            Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_VERIFICATION_FAILED' 'The live scenario did not produce a proven verification result.' $verification
        }
        $verificationFacts = ConvertTo-CcodInstalledLifecycleFacts -Facts $verification.facts
        $installedProofScenario = $Scenario -in @('FreshInstall','FreshLater','FreshRestart','Upgrade','SlowLaunch','ManualLaunchResume','LanguageStress','RepairStates')
        if ($installedProofScenario -and
            (-not $verificationFacts.installReady -or -not $verificationFacts.protectionReady -or -not $verificationFacts.trayAuthenticated -or $null -eq $verificationFacts.trayHostIdentity -or
             -not (Test-CcodInstalledLifecycleCandidateFileSet -Actual $verificationFacts.runtimeManifestFiles -Expected $context.candidatePayloadFiles -InstallRoot $context.installRoot -RuntimeId $verificationFacts.activeRuntimeId -Generation $verificationFacts.activeGeneration -ManifestSha256 $verificationFacts.runtimeManifestSha256) -or
             $runResult.runtimeManifestSha256 -cne [string]$verificationFacts.runtimeManifestSha256)) {
            Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_VERIFICATION_FAILED' 'The returned verification facts are not bound to the candidate and authenticated Ready proof.' $verificationFacts
        }
        $verification = [pscustomobject][ordered]@{
            verified = $true
            code = [string]$verification.code
            facts = $verificationFacts
        }
        $phases.Add((New-CcodInstalledLifecyclePhase -Name 'VerifyScenario' -Outcome 'Completed'))
    } catch {
        $failure = $_
        $failureCode = Get-CcodInstalledLifecycleErrorId $_
        if ([string]::IsNullOrWhiteSpace($failureCode) -or $failureCode -notmatch '^CCOD_INTEGRATION_') { $failureCode = 'CCOD_INTEGRATION_FAILED' }
        if ($null -ne $snapshot) {
            $rollback.attempted = $true
            try {
                if ($null -ne $previousExecutionLease) { Assert-CcodInstalledLifecycleExecutionLease $previousExecutionLease }
                $rollbackResult = & $adapters.Rollback $context $snapshot
                if ($null -ne $previousExecutionLease) { Assert-CcodInstalledLifecycleExecutionLease $previousExecutionLease }
                if ($null -eq $rollbackResult -or $rollbackResult.restored -isnot [bool] -or -not [bool]$rollbackResult.restored -or $rollbackResult.code -isnot [string]) {
                    Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_ROLLBACK_FAILED' 'Rollback did not return a proven completion result.' $rollbackResult
                }
                $rollback.completed = $true
                $rollback.code = [string]$rollbackResult.code
            } catch {
                $rollback.completed = $false
                $rollback.code = Get-CcodInstalledLifecycleErrorId $_
                $failureCode = 'CCOD_INTEGRATION_ROLLBACK_FAILED'
            }
        }
        $phases.Add((New-CcodInstalledLifecyclePhase -Name 'Failed' -Outcome $failureCode))
    } finally {
        Close-CcodInstalledLifecycleExecutionLease $candidateExecutionLease
        Close-CcodInstalledLifecycleExecutionLease $previousExecutionLease
        if ($null -ne $snapshot) {
            try {
                $cleaned = & $adapters.CleanupRollback $context $snapshot
                if ($cleaned -isnot [bool] -or -not $cleaned) {
                    if ($null -eq $failure) { $failureCode = 'CCOD_INTEGRATION_ROLLBACK_CLEANUP_FAILED' }
                    $rollback.completed = $false
                    $rollback.code = 'CCOD_INTEGRATION_ROLLBACK_CLEANUP_FAILED'
                }
            } catch {
                if ($null -eq $failure) { $failureCode = 'CCOD_INTEGRATION_ROLLBACK_CLEANUP_FAILED' }
                $rollback.completed = $false
                $rollback.code = 'CCOD_INTEGRATION_ROLLBACK_CLEANUP_FAILED'
            }
        }
        if ($null -ne $frozenPreviousRoot) {
            try {
                [void](Remove-CcodInstalledLifecycleFrozenRoot -Path $frozenPreviousRoot)
            } catch {
                if ($null -eq $failure) { $failureCode = 'CCOD_INTEGRATION_ROLLBACK_CLEANUP_FAILED' }
                $rollback.completed = $false
                $rollback.code = 'CCOD_INTEGRATION_ROLLBACK_CLEANUP_FAILED'
            }
        }
        if ($null -ne $evidenceDirectory) {
            $completedAtValues = @()
            try { $completedAtValues = @(& $adapters.GetUtcNow) } catch { $completedAtValues = @() }
            if ($completedAtValues.Count -ne 1 -or -not (Test-CcodInstalledLifecycleValidUtcClock -Value $completedAtValues[0])) {
                if ($null -eq $failure) { $failureCode = 'CCOD_INTEGRATION_CLOCK_INVALID' }
                $completedAt = $startedAt
            } else { $completedAt = $completedAtValues[0] }
            $receipt = [pscustomobject][ordered]@{
                schemaVersion = 1
                transactionId = $transactionId
                scenario = $Scenario
                expectedVersion = $ExpectedVersion
                installerSha256 = if ($null -eq $candidate) { $null } else { $candidate.Sha256 }
                previousInstallerSha256 = if ($null -eq $previousCandidate) { $null } else { $previousCandidate.Sha256 }
                startedAtUtc = $startedAt.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
                completedAtUtc = $completedAt.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
                durationMilliseconds = [long][math]::Max(0, ($completedAt.ToUniversalTime() - $startedAt.ToUniversalTime()).TotalMilliseconds)
                outcome = if ($null -eq $failure -and [string]::IsNullOrWhiteSpace($failureCode)) { 'Completed' } else { 'Failed' }
                errorCode = if ($null -eq $failure -and [string]::IsNullOrWhiteSpace($failureCode)) { $null } else { $failureCode }
                phases = @($phases)
                beforeFacts = $beforeFacts
                verification = $verification
                rollback = $rollback
            }
            try { & $adapters.WriteEvidence $evidenceDirectory $receipt | Out-Null }
            catch {
                if ($null -eq $failure) { $failureCode = 'CCOD_INTEGRATION_EVIDENCE_WRITE_FAILED' }
            }
        }
    }
    if ($null -ne $failure -or -not [string]::IsNullOrWhiteSpace($failureCode)) {
        Throw-CcodInstalledLifecycleError $failureCode 'The installed lifecycle scenario did not complete with proven evidence.' $Scenario
    }
    return $receipt
}

if ($VerifiedUninstallChild) {
    try {
        if (-not $AllowMachineMutation -or -not $AllowCodexRestart) {
            Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_MUTATION_NOT_ALLOWED' 'The uninstall child requires both explicit mutation and restart authorization.' $null
        }
        [Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
        # Read the wrapper input as explicit UTF-8 bytes instead of the ambient
        # console code page, and tolerate an optional byte-order mark.
        $reader=[IO.StreamReader]::new([Console]::OpenStandardInput(),[Text.UTF8Encoding]::new($false),$true)
        try{$json=$reader.ReadToEnd()}finally{$reader.Dispose()}
        if ($json.Length -gt 1048576) { throw 'uninstall input bounds' }
        if (-not (& $script:CcodInstalledLifecyclePersistenceIoModule {param($Json) Test-CcodJsonHasNoDuplicateProperties -Json $Json} $json)) { throw 'duplicate uninstall input' }
        $spec=$json|ConvertFrom-Json -ErrorAction Stop
        $expectedRoot=[IO.Path]::GetFullPath((Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'CodexControlOtherDevices'))
        if ($spec.installRoot -isnot [string] -or $spec.installRoot -cne $expectedRoot) { throw 'uninstall current-user root' }
        Invoke-CcodInstalledLifecycleVerifiedUninstall -Spec $spec|Out-Null
        [Console]::Out.WriteLine('CCOD_UNINSTALL_WRAPPER_COMPLETED')
        exit 0
    } catch { [Console]::Error.WriteLine('CCOD_INTEGRATION_UNINSTALL_CHILD_FAILED');exit 1 }
} elseif (-not $Library) {
    try {
        $receipt = Invoke-CcodInstalledLifecycleIntegration -InstallerPath $InstallerPath -PreviousInstallerPath $PreviousInstallerPath -PreviousExpectedVersion $PreviousExpectedVersion -PreviousInstallerSha256 $PreviousInstallerSha256 -PreviousManifestSha256 $PreviousManifestSha256 -ExpectedVersion $ExpectedVersion -EvidenceRoot $EvidenceRoot -AllowMachineMutation:$AllowMachineMutation -AllowCodexRestart:$AllowCodexRestart -Scenario $Scenario
        $receipt | ConvertTo-Json -Depth 16
    } catch {
        Write-Error $_
        exit 1
    }
}
