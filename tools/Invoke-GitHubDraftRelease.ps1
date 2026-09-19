Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:CcodDraftReleaseAssetContractModule = $null
$script:CcodGitHubDraftModuleRoot = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) { [IO.Path]::GetFullPath($PSScriptRoot) } else { $null }

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

function Throw-CcodGitHubDraftError {
    param([Parameter(Mandatory)][string]$Id,[Parameter(Mandatory)][string]$Message,$Target)
    throw [Management.Automation.ErrorRecord]::new(
        [InvalidOperationException]::new($Message),
        $Id,
        [Management.Automation.ErrorCategory]::InvalidData,
        $Target)
}

function Test-CcodGitHubDraftSchemaVersion($Value) {
    return ($Value -is [int] -or $Value -is [long]) -and [long]$Value -eq 1
}

function Test-CcodGitHubDraftCanonicalAbsolutePath($Path) {
    if ([string]::IsNullOrWhiteSpace([string]$Path)) { return $false }
    try {
        if (-not [IO.Path]::IsPathRooted([string]$Path)) { return $false }
        $full = [IO.Path]::GetFullPath([string]$Path)
        return [string]::Equals($full, [string]$Path, [StringComparison]::OrdinalIgnoreCase)
    } catch {
        return $false
    }
}

function Test-CcodGitHubDraftCanonicalUtc($Value) {
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value)) { return $false }
    $parsed = [datetime]::MinValue
    return [datetime]::TryParseExact(
        $Value,
        'o',
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind,
        [ref]$parsed
    ) -and $parsed.Kind -eq [DateTimeKind]::Utc -and
        $parsed.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture) -ceq $Value
}

function Test-CcodGitHubDraftMissingError($ErrorRecord) {
    return $ErrorRecord.CategoryInfo.Category -eq 'ObjectNotFound' -or
        $ErrorRecord.Exception -is [IO.FileNotFoundException] -or $ErrorRecord.Exception -is [IO.DirectoryNotFoundException]
}

function Assert-CcodGitHubDraftTrustedModulePath {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][bool]$Directory)
    try {
        if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathRooted($Path)) { throw 'module path' }
        $full = [IO.Path]::GetFullPath($Path)
        if (-not [string]::Equals($full, $Path, [StringComparison]::OrdinalIgnoreCase)) { throw 'module canonical path' }
        $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
        if (($Directory -and $item -isnot [IO.DirectoryInfo]) -or (-not $Directory -and $item -isnot [IO.FileInfo])) { throw 'module kind' }
        $root = [IO.Path]::GetPathRoot($full)
        $current = $full
        while ($true) {
            $ancestor = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if (($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'module reparse' }
            if ($current.TrimEnd('\') -ceq $root.TrimEnd('\')) { break }
            $parent = [IO.Directory]::GetParent($current)
            if ($null -eq $parent) { break }
            $current = $parent.FullName.TrimEnd('\')
        }
        return $full
    } catch {
        Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_CONTRACT_MISSING' 'Trusted validation module path has missing or reparse ancestry.' $Path
    }
}

function Test-CcodGitHubDraftExactProperties($Value,[string[]]$Expected) {
    if ($null -eq $Value -or ($Value -isnot [pscustomobject] -and $Value -isnot [Collections.IDictionary])) { return $false }
    if ($Value -is [Collections.IDictionary]) { $actual = @($Value.Keys | ForEach-Object { [string]$_ }) } else { $actual = @($Value.PSObject.Properties.Name) }
    return $actual.Count -eq $Expected.Count -and ($actual -join "`0") -ceq ($Expected -join "`0")
}

function Test-CcodGitHubDraftPositiveInteger($Value) {
    if ($null -eq $Value -or $Value -is [bool] -or $Value.GetType() -notin @([int32],[int64])) { return $false }
    try { return [uint64]$Value -gt 0 } catch { return $false }
}

function Import-CcodDraftReleaseAssetContract {
    $toolRoot = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) { [IO.Path]::GetFullPath($PSScriptRoot) } else { [string]$script:CcodGitHubDraftModuleRoot }
    $path = Join-Path $toolRoot 'ReleaseAssetContract.psm1'
    $lease = Open-CcodTrustedImportLease -Path $path -ErrorId 'CCOD_GITHUB_DRAFT_CONTRACT_MISSING'
    try {
        $toolRoot = Assert-CcodGitHubDraftTrustedModulePath -Path $toolRoot -Directory $true
        $path = Assert-CcodGitHubDraftTrustedModulePath -Path $path -Directory $false
        $lease.Revalidate()
        $script:CcodDraftReleaseAssetContractModule = Import-Module $path -Force -DisableNameChecking -PassThru -ErrorAction Stop
        $lease.Revalidate()
    } finally { $lease.Dispose() }
}

function Read-CcodGitHubDraftContractJson {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$ErrorId)
    if ($null -eq $script:CcodDraftReleaseAssetContractModule) { Import-CcodDraftReleaseAssetContract }
    $directory = $null
    $file = $null
    try {
        $full = [IO.Path]::GetFullPath($Path)
        $directory = & $script:CcodDraftReleaseAssetContractModule { param($Parent,$Id) Open-CcodReleaseDirectoryAuthority -Path $Parent -ErrorId $Id } ([IO.Path]::GetDirectoryName($full)) $ErrorId
        $file = & $script:CcodDraftReleaseAssetContractModule { param($Parent,$Leaf,$Id) Open-CcodReleaseFileAuthority -Directory $Parent -Leaf $Leaf -ErrorId $Id -MaximumBytes 4194304 } $directory ([IO.Path]::GetFileName($full)) $ErrorId
        $pinned = & $script:CcodDraftReleaseAssetContractModule { param($Authority,$Id) Read-CcodReleaseContractPinnedJson -Authority $Authority -ErrorId $Id -MaximumBytes 4194304 } $file $ErrorId
        return [pscustomobject]@{ Raw = $pinned.Raw; Value = $pinned.Value; Bytes = $pinned.Bytes; Sha256 = $file.Sha256; Path = $file.Path }
    } catch {
        if ($_.FullyQualifiedErrorId -like 'CCOD_*') { throw }
        Throw-CcodGitHubDraftError $ErrorId 'Draft evidence JSON is malformed or outside its contract.' $Path
    } finally {
        if ($null -ne $file) { & $script:CcodDraftReleaseAssetContractModule { param($Value) Close-CcodReleaseAuthority $Value } $file }
        if ($null -ne $directory) { & $script:CcodDraftReleaseAssetContractModule { param($Value) Close-CcodReleaseAuthority $Value } $directory }
    }
}

function Read-CcodGitHubDraftNotesPinned {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$ErrorId)
    if ($null -eq $script:CcodDraftReleaseAssetContractModule) { Import-CcodDraftReleaseAssetContract }
    $directory = $null
    $file = $null
    try {
        $full = [IO.Path]::GetFullPath($Path)
        $directory = & $script:CcodDraftReleaseAssetContractModule { param($Parent,$Id) Open-CcodReleaseDirectoryAuthority -Path $Parent -ErrorId $Id } ([IO.Path]::GetDirectoryName($full)) $ErrorId
        $file = & $script:CcodDraftReleaseAssetContractModule { param($Parent,$Leaf,$Id) Open-CcodReleaseFileAuthority -Directory $Parent -Leaf $Leaf -ErrorId $Id -MaximumBytes 1048576 } $directory ([IO.Path]::GetFileName($full)) $ErrorId
        $bytes = & $script:CcodDraftReleaseAssetContractModule {
            param($Authority,$Id)
            Assert-CcodReleaseAuthorityCurrent -Authority $Authority -ErrorId $Id -CheckBytes | Out-Null
            Get-CcodReleaseAuthorityStreamBytes -Stream $Authority.Stream -MaximumBytes 1048576
        } $file $ErrorId
        & $script:CcodDraftReleaseAssetContractModule { param($Authority,$Id) Assert-CcodReleaseAuthorityCurrent -Authority $Authority -ErrorId $Id -CheckBytes | Out-Null } $file $ErrorId
        return [Text.UTF8Encoding]::new($false, $true).GetString([byte[]]$bytes)
    } catch {
        if ($_.FullyQualifiedErrorId -like 'CCOD_*') { throw }
        Throw-CcodGitHubDraftError $ErrorId 'Release notes are missing, invalid, or changed during the pinned read.' $Path
    } finally {
        if ($null -ne $file) { & $script:CcodDraftReleaseAssetContractModule { param($Value) Close-CcodReleaseAuthority $Value } $file }
        if ($null -ne $directory) { & $script:CcodDraftReleaseAssetContractModule { param($Value) Close-CcodReleaseAuthority $Value } $directory }
    }
}

function Read-CcodGitHubDraftPreflight {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Version,[Parameter(Mandatory)][string]$GitCommit,[ref]$PinnedSha256)
    if (-not [IO.File]::Exists($Path)) {
        Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_PREFLIGHT_MISSING' 'Stage requires transferred clean-runner preflight evidence.' $Path
    }
    $Path = Assert-CcodGitHubDraftPlainPath -Path $Path -Directory $false
    $parsed = Read-CcodGitHubDraftContractJson -Path $Path -ErrorId 'CCOD_GITHUB_DRAFT_PREFLIGHT_INVALID'
    $record = $parsed.Value
    $fields = @($record.PSObject.Properties.Name)
    if (($fields -join ',') -cne 'schemaVersion,valid,version,gitCommit,repositoryRoot' -or
        -not (Test-CcodGitHubDraftSchemaVersion $record.schemaVersion) -or
        $record.valid -isnot [bool] -or -not [bool]$record.valid -or
        $record.version -isnot [string] -or $record.version -cne $Version -or
        $record.gitCommit -isnot [string] -or $record.gitCommit -cne $GitCommit -or
        $record.gitCommit -cnotmatch '^[0-9a-f]{40}\z' -or
        $record.repositoryRoot -isnot [string] -or [string]::IsNullOrWhiteSpace($record.repositoryRoot) -or
        -not (Test-CcodGitHubDraftCanonicalAbsolutePath $record.repositoryRoot)) {
        Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_PREFLIGHT_INVALID' 'Transferred clean-runner preflight is not bound to this candidate.' $Path
    }
    if ($null -ne $PinnedSha256) {
        if ($parsed.Sha256 -isnot [string] -or $parsed.Sha256 -cnotmatch '^[0-9a-f]{64}\z') {
            Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_PREFLIGHT_INVALID' 'Transferred preflight pinned byte hash is unavailable.' $Path
        }
        $PinnedSha256.Value = $parsed.Sha256
    }
    return $record
}

function Assert-CcodGitHubDraftRemoteView {
    param([Parameter(Mandatory)][string]$Tag,[Parameter(Mandatory)][string]$Version,$View,[switch]$AfterPromotion)
    $notStagedId = if ($AfterPromotion) { 'CCOD_GITHUB_DRAFT_PROMOTE_READBACK_FAILED' } else { 'CCOD_GITHUB_DRAFT_NOT_STAGED' }
    if ($null -eq $View -or $View -isnot [pscustomobject]) {
        Throw-CcodGitHubDraftError $notStagedId 'GitHub returned no structured release state.' $Tag
    }
    $fields = @($View.PSObject.Properties.Name)
    if (($fields -join ',') -cne 'Tag,Id,Draft,AssetNames' -or $View.Tag -isnot [string] -or $View.Tag -cne $Tag -or $View.Id -isnot [string] -or $View.Id -notmatch '^[1-9][0-9]*\z' -or $View.Draft -isnot [bool]) {
        Throw-CcodGitHubDraftError $notStagedId 'GitHub release state has an invalid schema.' $Tag
    }
    if ((-not $AfterPromotion -and -not [bool]$View.Draft) -or ($AfterPromotion -and [bool]$View.Draft)) {
        Throw-CcodGitHubDraftError $notStagedId 'The GitHub release has an invalid draft visibility state.' $Tag
    }
    $expected = @(Get-CcodExpectedReleaseAssetNames -Version $Version)
    $actual = @($View.AssetNames)
    if ($actual.Count -ne $expected.Count) {
        Throw-CcodGitHubDraftError $notStagedId 'GitHub draft does not contain the complete release asset set.' $Tag
    }
    if (@($actual | Where-Object { $_ -isnot [string] }).Count -ne 0 -or (($actual -join "`n") -cne ($expected -join "`n"))) {
        Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_ASSET_SET_INVALID' 'GitHub draft assets are not the exact ordered release set.' $Tag
    }
    return [string[]]$actual
}

function Assert-CcodGitHubDraftPrivateView {
    param([Parameter(Mandatory)][string]$Tag,[Parameter(Mandatory)][string]$Version,$View)
    if ($null -eq $View -or $View -isnot [pscustomobject]) {
        Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_CREATE_FAILED' 'GitHub returned no structured private draft state.' $Tag
    }
    $fields = @($View.PSObject.Properties.Name)
    if (($fields -join ',') -cne 'Tag,Id,Draft,AssetNames' -or $View.Tag -isnot [string] -or $View.Tag -cne $Tag -or $View.Id -isnot [string] -or $View.Id -notmatch '^[1-9][0-9]*\z' -or $View.Draft -isnot [bool] -or -not [bool]$View.Draft -or $null -eq $View.AssetNames) {
        Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_CREATE_FAILED' 'GitHub returned an invalid or non-private draft state.' $Tag
    }
    $expected = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($name in @(Get-CcodExpectedReleaseAssetNames -Version $Version)) { [void]$expected.Add($name) }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($name in @($View.AssetNames)) {
        if ($name -isnot [string] -or -not $expected.Contains([string]$name) -or -not $seen.Add([string]$name)) {
            Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_ASSET_SET_INVALID' 'Private draft contains an unexpected or duplicate asset.' $Tag
        }
    }
    [string[]]$seen
}

$script:CcodGitHubDraftStageLocks = @{}

function Get-CcodGitHubDraftStageLockName([string]$Tag) {
    "Local\CodexRemoteFix.Release.Stage.$Tag"
}

function Acquire-CcodGitHubDraftStageLock {
    param([Parameter(Mandatory)][string]$Tag)
    if ($script:CcodGitHubDraftStageLocks.ContainsKey($Tag)) { return $false }
    $mutex = $null
    try {
        $mutex = [Threading.Mutex]::new($false, (Get-CcodGitHubDraftStageLockName $Tag))
        try {
            $acquired = $mutex.WaitOne(0)
        } catch [Threading.AbandonedMutexException] {
            $acquired = $true
        }
        if (-not $acquired) {
            $mutex.Dispose()
            return $false
        }
        $script:CcodGitHubDraftStageLocks[$Tag] = $mutex
        return $true
    } catch {
        if ($null -ne $mutex) { $mutex.Dispose() }
        Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_LOCK_FAILED' 'Could not inspect or acquire the same-tag draft lock.' $Tag
    }
}

function Release-CcodGitHubDraftStageLock {
    param([Parameter(Mandatory)][string]$Tag)
    if (-not $script:CcodGitHubDraftStageLocks.ContainsKey($Tag)) { return }
    $mutex = $script:CcodGitHubDraftStageLocks[$Tag]
    $script:CcodGitHubDraftStageLocks.Remove($Tag)
    try {
        $mutex.ReleaseMutex()
    } finally {
        $mutex.Dispose()
    }
}

function Assert-CcodGitHubDraftActionsContext {
    param([Parameter(Mandatory)][string]$Tag)
    $repository = 'naipi11/CodexRemote-fix'
    if ($env:GITHUB_ACTIONS -cne 'true' -or $env:GITHUB_SERVER_URL -cne 'https://github.com' -or $env:GITHUB_REPOSITORY -cne $repository -or $env:GITHUB_RUN_ID -notmatch '^[1-9][0-9]*\z' -or [string]::IsNullOrWhiteSpace($env:GH_TOKEN)) {
        Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_GH_FORBIDDEN' 'GitHub draft adapters require the official CodexRemote-fix Actions context.' $Tag
    }
}

function Assert-CcodGitHubDraftAuthenticatedContext {
    param([Parameter(Mandatory)][string]$Tag)
    if (-not [string]::IsNullOrWhiteSpace($env:GH_TOKEN)) { return }
    try {
        & gh auth status '--hostname' 'github.com' 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'gh auth status failed' }
    } catch {
        Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_GH_FORBIDDEN' 'Draft readback requires an authenticated GitHub CLI context.' $Tag
    }
}

function Get-CcodGitHubDraftTagCommit {
    param([Parameter(Mandatory)][string]$Tag,[Parameter(Mandatory)][bool]$ActionsOnly)
    if ($ActionsOnly) { Assert-CcodGitHubDraftActionsContext $Tag } else { Assert-CcodGitHubDraftAuthenticatedContext $Tag }
    $endpoint = 'repos/naipi11/CodexRemote-fix/commits/' + $Tag
    $lines = @(& gh api $endpoint '--jq' '.sha')
    if ($LASTEXITCODE -ne 0) {
        Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_TAG_COMMIT_FAILED' 'Could not resolve the official remote tag commit.' $Tag
    }
    if ($lines.Count -ne 1 -or $lines[0] -isnot [string] -or $lines[0] -cnotmatch '^[0-9a-f]{40}\z') {
        Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_TAG_COMMIT_FAILED' 'GitHub returned an invalid remote tag commit.' $Tag
    }
    $lines[0]
}

function Assert-CcodGitHubDraftTagCommit {
    param([Parameter(Mandatory)][string]$Tag,[Parameter(Mandatory)][string]$ExpectedCommit,[Parameter(Mandatory)]$Adapters,[Parameter(Mandatory)][bool]$ActionsOnly)
    if ($ExpectedCommit -cnotmatch '^[0-9a-f]{40}\z') {
        Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_TAG_COMMIT_INVALID' 'Candidate commit is not canonical.' $ExpectedCommit
    }
    try {
        $rawCommit = & $Adapters.GetTagCommit $Tag $ActionsOnly
        if ($rawCommit -isnot [string] -or $rawCommit -cnotmatch '^[0-9a-f]{40}\z') { throw 'remote commit type or value' }
        $actualCommit = $rawCommit
    } catch {
        Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_TAG_COMMIT_FAILED' 'Could not read the remote tag commit.' $Tag
    }
    if ($actualCommit -cne $ExpectedCommit) {
        Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_TAG_COMMIT_MISMATCH' 'Remote tag does not resolve to the immutable candidate commit.' $Tag
    }
}

function Get-CcodGitHubDraftReleaseDefaultAdapters {
    @{
        TryStageLock = {
            param($Tag)
            Acquire-CcodGitHubDraftStageLock $Tag
        }
        AcquireStageLock = {
            param($Tag)
            Acquire-CcodGitHubDraftStageLock $Tag
        }
        ReleaseStageLock = {
            param($Tag)
            Release-CcodGitHubDraftStageLock $Tag
        }
        CreateDraft = {
            param($Tag, $Title, $Notes)
            Assert-CcodGitHubDraftActionsContext $Tag
            & gh release create $Tag '--repo' 'naipi11/CodexRemote-fix' '--draft' '--verify-tag' '--title' $Title '--notes' $Notes | Out-Null
            if ($LASTEXITCODE -ne 0) { Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_CREATE_FAILED' 'Could not create a private draft.' $Tag }
            $json = & gh release view $Tag '--repo' 'naipi11/CodexRemote-fix' '--json' 'databaseId,tagName,isDraft'
            if ($LASTEXITCODE -ne 0) { Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_CREATE_FAILED' 'Could not read back the created draft identity.' $Tag }
            try {
                $value = ($json -join [Environment]::NewLine) | ConvertFrom-Json -ErrorAction Stop
                $fields = @($value.PSObject.Properties.Name)
                if ($value -isnot [pscustomobject] -or $fields.Count -ne 3 -or (($fields | Sort-Object -CaseSensitive) -join ',') -cne 'databaseId,isDraft,tagName' -or
                    ($value.databaseId -isnot [int] -and $value.databaseId -isnot [long]) -or [long]$value.databaseId -le 0 -or
                    $value.tagName -isnot [string] -or $value.tagName -cne $Tag -or $value.isDraft -isnot [bool] -or -not [bool]$value.isDraft) { throw 'schema' }
                $id = [string]$value.databaseId
                [pscustomobject][ordered]@{ Tag = $Tag; Id = $id; Draft = $true; AssetNames = @() }
            } catch {
                Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_CREATE_FAILED' 'GitHub returned malformed created draft identity.' $Tag
            }
        }
        UploadAsset = {
            param($Tag, $Name, $Path)
            Assert-CcodGitHubDraftActionsContext $Tag
            & gh release upload $Tag '--repo' 'naipi11/CodexRemote-fix' $Path | Out-Null
            if ($LASTEXITCODE -ne 0) { Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_UPLOAD_FAILED' 'Could not upload a draft asset.' $Name }
        }
        GetTagCommit = {
            param($Tag, [bool]$ActionsOnly)
            Get-CcodGitHubDraftTagCommit -Tag $Tag -ActionsOnly $ActionsOnly
        }
        DownloadAsset = {
            param($Tag, $Name, $Destination)
            Assert-CcodGitHubDraftAuthenticatedContext $Tag
            $dir = [IO.Path]::GetDirectoryName($Destination)
            & gh release download $Tag '--repo' 'naipi11/CodexRemote-fix' '--pattern' $Name '--dir' $dir | Out-Null
            if ($LASTEXITCODE -ne 0) { Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_READBACK_FAILED' 'Could not read back a staged draft asset.' $Name }
        }
        ViewRelease = {
            param($Tag)
            Assert-CcodGitHubDraftAuthenticatedContext $Tag
            $json = & gh release view $Tag '--repo' 'naipi11/CodexRemote-fix' '--json' 'tagName,isDraft,databaseId,assets'
            if ($LASTEXITCODE -ne 0) { Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_NOT_STAGED' 'Could not read the GitHub draft state.' $Tag }
            try {
                $value = ($json -join [Environment]::NewLine) | ConvertFrom-Json -ErrorAction Stop
                $fields = @($value.PSObject.Properties.Name)
                if ($value -isnot [pscustomobject] -or $fields.Count -ne 4 -or (($fields | Sort-Object -CaseSensitive) -join ',') -cne 'assets,databaseId,isDraft,tagName' -or $value.tagName -isnot [string] -or $value.tagName -cne $Tag -or $value.isDraft -isnot [bool] -or
                    ($value.databaseId -isnot [int] -and $value.databaseId -isnot [long]) -or [long]$value.databaseId -le 0 -or $null -eq $value.assets) { throw 'schema' }
                $id = [string]$value.databaseId
                $assetNames = [Collections.Generic.List[string]]::new()
                foreach ($asset in @($value.assets)) {
                    if ($null -eq $asset -or $null -eq $asset.PSObject.Properties['name'] -or $asset.name -isnot [string] -or [string]::IsNullOrWhiteSpace($asset.name)) { throw 'asset schema' }
                    $assetNames.Add([string]$asset.name)
                }
                [pscustomobject][ordered]@{ Tag = [string]$value.tagName; Id = $id; Draft = $value.isDraft; AssetNames = [string[]]$assetNames }
            } catch {
                Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_NOT_STAGED' 'GitHub returned malformed release state.' $Tag
            }
        }
        ProbeRelease = {
            param($Tag)
            Assert-CcodGitHubDraftActionsContext $Tag
            $endpoint = 'repos/naipi11/CodexRemote-fix/releases/tags/' + $Tag
            $raw = @(& gh api $endpoint '--jq' '{tagName:.tag_name,databaseId:.id,isDraft:.draft,assets:[.assets[].name]}' 2>&1)
            if ($LASTEXITCODE -ne 0) {
                $message = ($raw | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
                if ($message -match '(?i)\b404\b|not found') { return $null }
                Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_CREATE_FAILED' 'Could not prove that the release tag is absent before Stage.' $Tag
            }
            try {
                $value = ($raw -join [Environment]::NewLine) | ConvertFrom-Json -ErrorAction Stop
                if ($null -eq $value -or $value.tagName -isnot [string] -or $value.databaseId -isnot [int] -and $value.databaseId -isnot [long] -or
                    $value.isDraft -isnot [bool] -or $null -eq $value.assets) { throw 'schema' }
                [pscustomobject][ordered]@{
                    Tag = [string]$value.tagName
                    Id = [string]$value.databaseId
                    Draft = [bool]$value.isDraft
                    AssetNames = @($value.assets | ForEach-Object { [string]$_ })
                }
            } catch {
                Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_CREATE_FAILED' 'Pre-create release probe returned malformed state.' $Tag
            }
        }
        SetReleaseDraftState = {
            param($Tag, [bool]$Draft, $ExpectedReleaseId)
            $boundRecovery = $PSBoundParameters.ContainsKey('ExpectedReleaseId')
            if (-not $boundRecovery -or $ExpectedReleaseId -isnot [string] -or $ExpectedReleaseId -notmatch '^[1-9][0-9]*\z') {
                Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_PROMOTE_FAILED' 'Visibility changes require an exact bound release ID.' $Tag
            }
            Assert-CcodGitHubDraftAuthenticatedContext $Tag
            $endpoint = 'repos/naipi11/CodexRemote-fix/releases/' + $ExpectedReleaseId
            $draftField = if ($Draft) { 'draft=true' } else { 'draft=false' }
            & gh api $endpoint '--method' 'PATCH' '--field' $draftField '--silent' | Out-Null
            if ($LASTEXITCODE -ne 0) { Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_PROMOTE_FAILED' 'Could not change draft visibility.' $Tag }
        }
        InvokeBuild = {
            param($Version)
            Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_REBUILD' 'Draft promotion cannot rebuild a candidate.' $Version
        }
        InvokeGh = {
            param($Arguments)
            Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_GH_FORBIDDEN' 'Raw gh invocation is not part of the draft contract.' $Arguments
        }
    }
}

function Resolve-CcodGitHubDraftReleaseAdapters {
    param([hashtable]$Adapters)
    $resolved = Get-CcodGitHubDraftReleaseDefaultAdapters
    if ($null -eq $Adapters) { return $resolved }
    foreach ($name in @($Adapters.Keys)) {
        if (-not $resolved.ContainsKey([string]$name) -or $Adapters[$name] -isnot [scriptblock]) {
            Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_ADAPTER_INVALID' 'Private draft adapters must replace known scriptblock operations only.' $name
        }
        $resolved[[string]$name] = $Adapters[$name]
    }
    return $resolved
}

function Get-CcodGitHubDraftFileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    $full = Assert-CcodGitHubDraftPlainPath -Path $Path -Directory $false
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $stream = [IO.File]::OpenRead($full)
        try {
            return [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '').ToLowerInvariant()
        } finally {
            $stream.Dispose()
        }
    } finally {
        $sha.Dispose()
    }
}

function Remove-CcodGitHubDraftDirectoryIfPresent {
    param([Parameter(Mandatory)][string]$Path,[string]$ErrorId='CCOD_GITHUB_DRAFT_EVIDENCE_CLEANUP_FAILED')
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    try {
        $item = $null
        try { $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop } catch { if (-not (Test-CcodGitHubDraftMissingError $_)) { throw } }
        if ($null -eq $item) { return }
        if ($item -isnot [IO.DirectoryInfo] -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'directory cleanup target' }
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        $residual = $null
        try { $residual = Get-Item -LiteralPath $Path -Force -ErrorAction Stop } catch { if (-not (Test-CcodGitHubDraftMissingError $_)) { throw } }
        if ($null -ne $residual) { throw 'directory cleanup residue' }
    } catch {
        if ($_.FullyQualifiedErrorId -like 'CCOD_GITHUB_DRAFT_*') { throw }
        Throw-CcodGitHubDraftError $ErrorId 'Draft temporary directory cleanup could not be proven.' $Path
    }
}

function New-CcodGitHubDraftFrozenAssetSet {
    param([Parameter(Mandatory)][string]$AssetDirectory,[Parameter(Mandatory)][string]$Version,[Parameter(Mandatory)]$Contract)
    $frozenDirectory = Join-Path ([IO.Path]::GetTempPath()) ('ccod-draft-frozen-' + [guid]::NewGuid().ToString('N'))
    try {
        [IO.Directory]::CreateDirectory($frozenDirectory) | Out-Null
        $expected = @(Get-CcodExpectedReleaseAssetNames -Version $Version)
        $contractAssets = @($Contract.Assets)
        if ($contractAssets.Count -ne $expected.Count) { throw 'candidate contract asset count' }
        for ($index = 0; $index -lt $expected.Count; $index++) {
            $name = $expected[$index]
            if ($contractAssets[$index].name -isnot [string] -or [string]$contractAssets[$index].name -cne $name -or $contractAssets[$index].sha256 -isnot [string] -or [string]$contractAssets[$index].sha256 -cnotmatch '^[0-9a-f]{64}\z') { throw 'candidate contract asset identity' }
            $source = Join-Path $AssetDirectory $name
            $destination = Join-Path $frozenDirectory $name
            [IO.File]::Copy($source, $destination, $false)
            if ((Get-CcodGitHubDraftFileSha256 $destination) -cne [string]$contractAssets[$index].sha256) { throw 'candidate changed during freeze' }
        }
        return [pscustomobject][ordered]@{ Directory = $frozenDirectory; Names = [string[]]$expected; GitCommit = [string]$Contract.GitCommit }
    } catch {
        Remove-CcodGitHubDraftDirectoryIfPresent -Path $frozenDirectory
        Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_ASSET_FREEZE_FAILED' 'The release candidate changed or could not be frozen.' $AssetDirectory
    }
}

function Remove-CcodGitHubDraftFrozenAssetSet {
    param($Frozen)
    if ($null -ne $Frozen -and -not [string]::IsNullOrWhiteSpace([string]$Frozen.Directory)) {
        Remove-CcodGitHubDraftDirectoryIfPresent -Path ([string]$Frozen.Directory)
    }
}

function Invoke-CcodGitHubDraftDownloadAsset {
    param([Parameter(Mandatory)][hashtable]$Adapters,[Parameter(Mandatory)][string]$Tag,[Parameter(Mandatory)][string]$Name,[Parameter(Mandatory)][string]$Destination,[Parameter(Mandatory)][string]$ErrorId)
    try {
        & $Adapters.DownloadAsset $Tag $Name $Destination
        if (-not [IO.File]::Exists($Destination)) { throw 'download did not create destination' }
    } catch {
        Throw-CcodGitHubDraftError $ErrorId 'GitHub asset readback failed.' $Name
    }
}

function Get-CcodGitHubDraftPreflightName([string]$Version) {
    "CodexRemote-fix-$Version-clean-preflight.json"
}

function Get-CcodGitHubDraftAcceptanceName([string]$Version) {
    "CodexRemote-fix-$Version-official-draft.complete.json"
}

function Get-CcodGitHubDraftVerificationName([string]$Version) {
    "CodexRemote-fix-$Version-draft-verified.json"
}

function Get-CcodGitHubDraftDefenderEvidenceDirectory([string]$EvidenceDirectory) {
    $root = Assert-CcodGitHubDraftPlainPath -Path $EvidenceDirectory -Directory $true
    $dedicated = Join-Path $root 'defender'
    try { $item = Get-Item -LiteralPath $dedicated -Force -ErrorAction Stop } catch { Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_EVIDENCE_PATH_INVALID' 'The dedicated Defender evidence plane is missing or unavailable.' $dedicated }
    if ($item -isnot [IO.DirectoryInfo] -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_EVIDENCE_PATH_INVALID' 'The dedicated Defender evidence plane is not a plain directory.' $dedicated
    }
    return Assert-CcodGitHubDraftPlainPath -Path $dedicated -Directory $true
}

function Assert-CcodGitHubDraftPlainPath {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][bool]$Directory)
    if ($null -eq $script:CcodDraftReleaseAssetContractModule) { Import-CcodDraftReleaseAssetContract }
    try {
        return & $script:CcodDraftReleaseAssetContractModule { param($Value,$IsDirectory) Assert-CcodReleaseContractPlainPath -Path $Value -Directory $IsDirectory -ErrorId 'CCOD_GITHUB_DRAFT_EVIDENCE_PATH_INVALID' } $Path $Directory
    } catch {
        Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_EVIDENCE_PATH_INVALID' 'Draft evidence path is missing, noncanonical, or has unsafe reparse ancestry.' $Path
    }
}

function Get-CcodGitHubDraftEvidencePlanePath {
    param([Parameter(Mandatory)][string]$EvidenceDirectory,[Parameter(Mandatory)][ValidateSet('verification','acceptance')][string]$Plane,[switch]$Create)
    $root = Assert-CcodGitHubDraftPlainPath -Path $EvidenceDirectory -Directory $true
    $path = Join-Path $root $Plane
    $item = $null
    try { $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop } catch { if (-not (Test-CcodGitHubDraftMissingError $_)) { Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_EVIDENCE_PATH_INVALID' 'Draft evidence plane could not be inspected safely.' $path } }
    if ($null -ne $item -and ($item -isnot [IO.DirectoryInfo] -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_EVIDENCE_PATH_INVALID' 'Draft evidence plane is not a plain directory.' $path
    }
    if ($null -eq $item) {
        if (-not $Create) { return $path }
        try { [IO.Directory]::CreateDirectory($path) | Out-Null } catch { Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_EVIDENCE_PATH_INVALID' 'Draft evidence plane could not be created safely.' $path }
    }
    return Assert-CcodGitHubDraftPlainPath -Path $path -Directory $true
}

function Get-CcodGitHubDraftEvidenceFilePath {
    param([Parameter(Mandatory)][string]$EvidenceDirectory,[Parameter(Mandatory)][ValidateSet('verification','acceptance')][string]$Plane,[Parameter(Mandatory)][string]$Leaf,[switch]$CreatePlane)
    $planePath = Get-CcodGitHubDraftEvidencePlanePath -EvidenceDirectory $EvidenceDirectory -Plane $Plane -Create:$CreatePlane
    $path = Join-Path $planePath $Leaf
    $item = $null
    try { $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop } catch { if (-not (Test-CcodGitHubDraftMissingError $_)) { Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_EVIDENCE_PATH_INVALID' 'Draft evidence target could not be inspected safely.' $path } }
    if ($null -ne $item) {
        if ($item -isnot [IO.FileInfo] -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_EVIDENCE_PATH_INVALID' 'Draft evidence target is not a plain file.' $path }
        return Assert-CcodGitHubDraftPlainPath -Path $path -Directory $false
    }
    if ([IO.Path]::GetFullPath($path) -cne $path) {
        Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_EVIDENCE_PATH_INVALID' 'Draft evidence target is not canonical.' $path
    }
    return $path
}

function Get-CcodGitHubDraftRootEvidenceFilePath([string]$EvidenceDirectory,[string]$Leaf) {
    $root = Assert-CcodGitHubDraftPlainPath -Path $EvidenceDirectory -Directory $true
    $path = Join-Path $root $Leaf
    $item = $null
    try { $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop } catch { if (-not (Test-CcodGitHubDraftMissingError $_)) { Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_EVIDENCE_PATH_INVALID' 'Draft evidence target could not be inspected safely.' $path } }
    if ($null -ne $item) {
        if ($item -isnot [IO.FileInfo] -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_EVIDENCE_PATH_INVALID' 'Draft evidence target is not a plain file.' $path }
        return Assert-CcodGitHubDraftPlainPath -Path $path -Directory $false
    }
    return $path
}

function Get-CcodGitHubDraftVerificationPath([string]$EvidenceDirectory,[string]$Version,[switch]$CreatePlane) {
    Get-CcodGitHubDraftEvidenceFilePath -EvidenceDirectory $EvidenceDirectory -Plane verification -Leaf (Get-CcodGitHubDraftVerificationName $Version) -CreatePlane:$CreatePlane
}

function Get-CcodGitHubDraftAcceptancePath([string]$EvidenceDirectory,[string]$Version) {
    Get-CcodGitHubDraftEvidenceFilePath -EvidenceDirectory $EvidenceDirectory -Plane acceptance -Leaf (Get-CcodGitHubDraftAcceptanceName $Version)
}

function Get-CcodGitHubDraftManualArtifactPaths {
    param([Parameter(Mandatory)][string]$EvidenceDirectory,[Parameter(Mandatory)][string]$Operation)
    $artifactRoot = Assert-CcodGitHubDraftPlainPath -Path (Join-Path ([IO.Path]::GetFullPath($EvidenceDirectory)) 'official-draft-artifacts') -Directory $true
    $operationDirectory = Assert-CcodGitHubDraftPlainPath -Path (Join-Path $artifactRoot $Operation) -Directory $true
    return [pscustomobject][ordered]@{
        Screenshot = Assert-CcodGitHubDraftPlainPath -Path (Join-Path $operationDirectory 'screenshot.bin') -Directory $false
        RedactedLog = Assert-CcodGitHubDraftPlainPath -Path (Join-Path $operationDirectory 'redacted.log') -Directory $false
    }
}

function Test-CcodGitHubDraftManualProof {
    param([Parameter(Mandatory)]$Proof,[Parameter(Mandatory)][int]$Index,[Parameter(Mandatory)][string]$Version)
    try {
        if ($Index -lt 4) {
            $commandSets = @(
                ,@('ShowAbout')
                ,@('SetLanguageSystem','SetLanguageChinese','SetLanguageEnglish')
                ,@('OpenLogs')
                ,@('CheckAndRepair')
            )
            $commands = $commandSets[$Index]
            if (-not (Test-CcodGitHubDraftExactProperties -Value $Proof -Expected @('timestampUtc','command','revision','code','status')) -or
                $Proof.timestampUtc -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$Proof.timestampUtc) -or
                $Proof.command -isnot [string] -or $commands -cnotcontains [string]$Proof.command -or
                -not (Test-CcodGitHubDraftPositiveInteger $Proof.revision) -or
                $Proof.code -isnot [string] -or $Proof.code -cne 'CCOD_TRAY_ACTION_COMPLETED' -or
                $Proof.status -isnot [string] -or $Proof.status -cne 'Completed') { return $false }
            if (-not (Test-CcodGitHubDraftCanonicalUtc $Proof.timestampUtc)) { return $false }
            return $true
        }
        $expected = @('schemaVersion','timestampUtc','kind','operation','deviceRole','challenge','candidateVersion','runtimeId','runtimeGeneration','runtimeManifestSha256','attestation','connection','control','outcome','code')
        if (-not (Test-CcodGitHubDraftExactProperties -Value $Proof -Expected $expected) -or
            -not (Test-CcodGitHubDraftPositiveInteger $Proof.schemaVersion) -or [uint64]$Proof.schemaVersion -ne 1 -or
            $Proof.timestampUtc -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$Proof.timestampUtc) -or
            $Proof.kind -isnot [string] -or $Proof.kind -cne 'remote-control-manual-proof' -or
            $Proof.operation -isnot [string] -or $Proof.operation -cne 'SecondDeviceControl' -or
            $Proof.deviceRole -isnot [string] -or $Proof.deviceRole -cne 'SecondDevice' -or
            $Proof.challenge -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$Proof.challenge) -or
            $Proof.candidateVersion -isnot [string] -or $Proof.candidateVersion -cne $Version -or
            $Proof.runtimeId -isnot [string] -or $Proof.runtimeId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,95}\z' -or
            -not (Test-CcodGitHubDraftPositiveInteger $Proof.runtimeGeneration) -or
            $Proof.runtimeManifestSha256 -isnot [string] -or $Proof.runtimeManifestSha256 -cnotmatch '^[0-9a-f]{64}\z' -or
            $Proof.attestation -isnot [string] -or $Proof.attestation -cne 'HumanReviewedStructuredAttestation' -or
            $Proof.connection -isnot [string] -or $Proof.connection -cne 'Connected' -or
            $Proof.control -isnot [string] -or $Proof.control -cne 'Completed' -or
            $Proof.outcome -isnot [string] -or $Proof.outcome -cne 'Completed' -or
            $Proof.code -isnot [string] -or $Proof.code -cne 'CCOD_REMOTE_ACTION_COMPLETED') { return $false }
        if (-not (Test-CcodGitHubDraftCanonicalUtc $Proof.timestampUtc)) { return $false }
        return $true
    } catch { return $false }
}

function Assert-CcodGitHubDraftManualEvidenceArtifacts {
    param([Parameter(Mandatory)][string]$EvidenceDirectory,[Parameter(Mandatory)]$ManualEvidence)
    try {
        $expectedOperations = @('About','Language','OpenLogs','Repair','SecondDeviceControl')
        $entries = @($ManualEvidence)
        if ($entries.Count -ne $expectedOperations.Count) { throw 'manual artifact count' }
        for ($index = 0; $index -lt $expectedOperations.Count; $index++) {
            $entry = $entries[$index]
            if ($null -eq $entry -or $entry.operation -isnot [string] -or $entry.operation -cne $expectedOperations[$index]) { throw 'manual artifact operation' }
            $paths = Get-CcodGitHubDraftManualArtifactPaths -EvidenceDirectory $EvidenceDirectory -Operation ([string]$entry.operation)
            if ((Get-CcodGitHubDraftFileSha256 $paths.Screenshot) -cne [string]$entry.screenshotSha256 -or
                (Get-CcodGitHubDraftFileSha256 $paths.RedactedLog) -cne [string]$entry.redactedLogSha256) { throw 'manual artifact hash' }
        }
        return $true
    } catch {
        Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_ACCEPTANCE_INVALID' 'Manual acceptance hashes are not backed by the expected evidence artifacts.' $EvidenceDirectory
    }
}

function Write-CcodGitHubDraftJsonCreateOnly {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)]$Record,[Parameter(Mandatory)][string]$ErrorId,[scriptblock]$ReadbackVerifier)
    if ($null -eq $script:CcodDraftReleaseAssetContractModule) { Import-CcodDraftReleaseAssetContract }
    $Path = [IO.Path]::GetFullPath($Path)
    $directoryPath = [IO.Path]::GetDirectoryName($Path)
    $leaf = [IO.Path]::GetFileName($Path)
    $directory = $null
    $published = $null
    $encoding = [Text.UTF8Encoding]::new($false)
    $bytes = $encoding.GetBytes((($Record | ConvertTo-Json -Depth 12) + [Environment]::NewLine))
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $expectedHash = ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() } finally { $sha.Dispose() }
    try {
        $directory = & $script:CcodDraftReleaseAssetContractModule { param($Path,$Id) Open-CcodReleaseDirectoryAuthority -Path $Path -ErrorId $Id -AllowChildMutation } $directoryPath $ErrorId
        $published = & $script:CcodDraftReleaseAssetContractModule { param($Directory,$Leaf,$Bytes,$Id) Publish-CcodReleaseReceiptAuthority -Directory $Directory -Leaf $Leaf -Bytes $Bytes -ErrorId $Id } $directory $leaf $bytes $ErrorId
        if ($null -ne $ReadbackVerifier -and -not [bool](& $ReadbackVerifier $published.Path)) { throw 'draft evidence readback' }
        $pinned = & $script:CcodDraftReleaseAssetContractModule {
            param($Authority,$Id,$ExpectedHash,$ExpectedBytes)
            Assert-CcodReleaseAuthorityCurrent -Authority $Authority -ErrorId $Id -CheckBytes | Out-Null
            $read = Read-CcodReleaseContractPinnedJson -Authority $Authority -ErrorId $Id -MaximumBytes 65536
            if ([Convert]::ToBase64String([byte[]]$read.Bytes) -cne [Convert]::ToBase64String([byte[]]$ExpectedBytes) -or $Authority.Sha256 -cne $ExpectedHash) { throw 'draft evidence readback' }
            return $read
        } $published $ErrorId $expectedHash $bytes
        if ($null -eq $pinned.Value) { throw 'draft evidence readback' }
        return $published.Path
    } catch {
        $failure = $_
        if ($null -ne $published) {
            try {
                & $script:CcodDraftReleaseAssetContractModule {
                    param($Authority,$Directory,$Leaf,$Id)
                    $members = [string[]]([CcodReleaseFileAuthorityV1]::EnumerateDirectory($Directory.Handle))
                    if ([Array]::IndexOf($members, $Leaf) -ge 0) {
                        Assert-CcodReleaseAuthorityCurrent -Authority $Authority -ErrorId $Id | Out-Null
                        if ([CcodReleaseFileAuthorityV1]::Delete($Authority.Stream.SafeFileHandle) -ne 0) { throw 'draft evidence delete' }
                        # NTFS keeps the delete-pending name until our last file handle closes.
                        Close-CcodReleaseAuthority $Authority
                        $remaining = [string[]]([CcodReleaseFileAuthorityV1]::EnumerateDirectory($Directory.Handle))
                        if ([Array]::IndexOf($remaining, $Leaf) -ge 0) { throw 'draft evidence cleanup residue' }
                    }
                } $published $directory $leaf $ErrorId
            } catch {
                Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_EVIDENCE_CLEANUP_FAILED' 'Draft evidence cleanup could not prove the published target was removed.' $Path
            }
        }
        if ($failure.FullyQualifiedErrorId -like 'CCOD_GITHUB_*') { throw $failure }
        Throw-CcodGitHubDraftError $ErrorId 'Draft evidence is not create-only or could not be published and read back safely.' $Path
    } finally {
        if ($null -ne $published) { & $script:CcodDraftReleaseAssetContractModule { param($Value) Close-CcodReleaseAuthority $Value } $published }
        if ($null -ne $directory) { & $script:CcodDraftReleaseAssetContractModule { param($Value) Close-CcodReleaseAuthority $Value } $directory }
    }
}

function Read-CcodGitHubDraftVerification {
    param([Parameter(Mandatory)][string]$EvidenceDirectory,[Parameter(Mandatory)][string]$AssetDirectory,[Parameter(Mandatory)][string]$Tag,[Parameter(Mandatory)][string]$Version,[Parameter(Mandatory)][string]$GitCommit)
    $path = Get-CcodGitHubDraftVerificationPath $EvidenceDirectory $Version
    $receiptItem = $null
    try { $receiptItem = Get-Item -LiteralPath $path -Force -ErrorAction Stop } catch { if (Test-CcodGitHubDraftMissingError $_) { Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_VERIFY_EVIDENCE_MISSING' 'Promote requires a persisted successful Verify record.' $path } Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_VERIFY_EVIDENCE_INVALID' 'Persisted Verify evidence could not be inspected safely.' $path }
    if ($receiptItem -isnot [IO.FileInfo] -or ($receiptItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_VERIFY_EVIDENCE_INVALID' 'Persisted Verify evidence is not a plain file.' $path }
    $record = (Read-CcodGitHubDraftContractJson -Path $path -ErrorId 'CCOD_GITHUB_DRAFT_VERIFY_EVIDENCE_INVALID').Value
    $expected = @(Get-CcodExpectedReleaseAssetNames -Version $Version)
    $fields = @($record.PSObject.Properties.Name)
    $hashes = @($record.assetSha256)
    $names = @($record.assetNames)
    $localManifest = Join-Path $AssetDirectory (Get-CcodGitHubDraftManifestName $Version)
    if ($record -isnot [pscustomobject] -or ($fields -join ',') -cne 'schemaVersion,kind,tag,draftId,version,gitCommit,draft,verified,assetNames,assetSha256,candidateManifestSha256' -or
        -not (Test-CcodGitHubDraftSchemaVersion $record.schemaVersion) -or
        $record.kind -isnot [string] -or $record.kind -cne 'github-draft-verification' -or $record.tag -isnot [string] -or $record.tag -cne $Tag -or
        $record.draftId -isnot [string] -or $record.draftId -notmatch '^[1-9][0-9]*\z' -or
        $record.version -isnot [string] -or $record.version -cne $Version -or $record.gitCommit -isnot [string] -or $record.gitCommit -cne $GitCommit -or
        $record.draft -isnot [bool] -or -not [bool]$record.draft -or
        $record.verified -isnot [bool] -or -not [bool]$record.verified -or
        $names.Count -ne $expected.Count -or (@($names | Where-Object { $_ -isnot [string] }).Count -ne 0) -or (($names | ForEach-Object { [string]$_ }) -join "`n") -cne ($expected -join "`n") -or
        $hashes.Count -ne $expected.Count -or (@($hashes | Where-Object { $_ -isnot [string] -or $_ -cnotmatch '^[0-9a-f]{64}\z' }).Count -ne 0) -or
        $record.candidateManifestSha256 -isnot [string] -or $record.candidateManifestSha256 -cne (Get-CcodGitHubDraftFileSha256 $localManifest)) {
        Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_VERIFY_EVIDENCE_INVALID' 'Persisted Verify evidence is not bound to the exact candidate.' $path
    }
    for ($index = 0; $index -lt $expected.Count; $index++) {
        if ([string]$hashes[$index] -cne (Get-CcodGitHubDraftFileSha256 (Join-Path $AssetDirectory $expected[$index]))) {
            Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_VERIFY_EVIDENCE_INVALID' 'Persisted Verify asset hashes do not match the candidate.' $path
        }
    }
    return $record
}

function Get-CcodGitHubDraftManifestName([string]$Version) {
    "CodexRemote-fix-$Version-release-manifest.json"
}

function Read-CcodGitHubDraftAcceptance {
    param([Parameter(Mandatory)][string]$EvidenceDirectory,[Parameter(Mandatory)][string]$AssetDirectory,[Parameter(Mandatory)][string]$Tag,[Parameter(Mandatory)][string]$Version,[Parameter(Mandatory)][string]$GitCommit)
    $path = Get-CcodGitHubDraftAcceptancePath $EvidenceDirectory $Version
    $acceptanceItem = $null
    try { $acceptanceItem = Get-Item -LiteralPath $path -Force -ErrorAction Stop } catch { if (Test-CcodGitHubDraftMissingError $_) { Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_ACCEPTANCE_MISSING' 'Promotion requires Task 8/9 official-draft acceptance evidence.' $path } Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_ACCEPTANCE_INVALID' 'Official-draft acceptance evidence could not be inspected safely.' $path }
    if ($acceptanceItem -isnot [IO.FileInfo] -or ($acceptanceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_ACCEPTANCE_INVALID' 'Official-draft acceptance evidence is not a plain file.' $path }
    $record = (Read-CcodGitHubDraftContractJson -Path $path -ErrorId 'CCOD_GITHUB_DRAFT_ACCEPTANCE_INVALID').Value
    $fields = @($record.PSObject.Properties.Name)
    $baseFields = @('schemaVersion','kind','version','gitCommit','candidateManifestSha256','phase','completedAtUtc')
    if ($record -is [pscustomobject] -and ($fields -join ',') -ceq ($baseFields -join ',')) {
        Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_ACCEPTANCE_INCOMPLETE' 'Promotion requires all four tray records and the distinct second-device record.' $path
    }
    $manifestPath = Join-Path $AssetDirectory (Get-CcodGitHubDraftManifestName $Version)
    $canonicalCompletedAtUtc = $null
    try {
        $parsedCompletedAtUtc = [DateTimeOffset]::ParseExact([string]$record.completedAtUtc, "yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal)
        $canonicalCompletedAtUtc = $parsedCompletedAtUtc.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'", [Globalization.CultureInfo]::InvariantCulture)
    } catch { }
    if ($record -isnot [pscustomobject] -or ($fields -join ',') -cne 'schemaVersion,kind,version,gitCommit,draft,candidateManifestSha256,phase,completedAtUtc,automatedReceiptSha256,manualEvidence' -or
        -not (Test-CcodGitHubDraftSchemaVersion $record.schemaVersion) -or $record.kind -isnot [string] -or $record.kind -cne 'official-draft-acceptance' -or
        $record.version -isnot [string] -or $record.version -cne $Version -or $record.gitCommit -isnot [string] -or $record.gitCommit -cne $GitCommit -or $record.gitCommit -cnotmatch '^[0-9a-f]{40}\z' -or
        $record.draft -isnot [pscustomobject] -or (@($record.draft.PSObject.Properties.Name) -join ',') -cne 'tag,id' -or
        $record.draft.tag -isnot [string] -or $record.draft.tag -cne $Tag -or $record.draft.id -isnot [string] -or $record.draft.id -notmatch '^[1-9][0-9]*\z' -or
        $record.candidateManifestSha256 -isnot [string] -or $record.candidateManifestSha256 -cnotmatch '^[0-9a-f]{64}\z' -or $record.candidateManifestSha256 -cne (Get-CcodGitHubDraftFileSha256 $manifestPath) -or
        $record.phase -isnot [string] -or $record.phase -cne 'Complete' -or $record.completedAtUtc -isnot [string] -or [string]$record.completedAtUtc -cne $canonicalCompletedAtUtc) {
        Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_ACCEPTANCE_INVALID' 'Official-draft acceptance evidence is malformed or not bound to this candidate.' $path
    }
    $stateDirectory = Join-Path $EvidenceDirectory 'official-draft-acceptance'
    try {
        $toolRoot = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) { [IO.Path]::GetFullPath($PSScriptRoot) } else { [string]$script:CcodGitHubDraftModuleRoot }
        if ([string]::IsNullOrWhiteSpace($toolRoot)) { throw 'acceptance module root unavailable' }
        $acceptanceModulePath = Join-Path (Split-Path $toolRoot -Parent) 'tests\installed\OfficialDraftAcceptance.psm1'
        $acceptanceLease = Open-CcodTrustedImportLease -Path $acceptanceModulePath -ErrorId 'CCOD_GITHUB_DRAFT_ACCEPTANCE_INVALID'
        try {
            $acceptanceModulePath = Assert-CcodGitHubDraftTrustedModulePath -Path $acceptanceModulePath -Directory $false
            $acceptanceLease.Revalidate()
            $acceptanceModule = Import-Module $acceptanceModulePath -Force -PassThru -DisableNameChecking -ErrorAction Stop
            $acceptanceLease.Revalidate()
        } finally { $acceptanceLease.Dispose() }
        $state = & $acceptanceModule {
            param($Directory)
            $value = Read-CcodOfficialDraftState -StateDirectory $Directory
            [void](Assert-CcodOfficialDraftAutomatedReceiptChain -Records $value -StateDirectory $Directory)
            if (-not $value.ContainsKey('Complete')) { throw 'complete state missing' }
            return $value
        } $stateDirectory
        $completeCandidate = $state.Complete.candidate
        Import-CcodDraftReleaseAssetContract
        $currentContract = Test-CcodExactReleaseAssetSet -AssetDirectory $AssetDirectory -Version $Version
        if ($currentContract.Valid -isnot [bool] -or -not [bool]$currentContract.Valid -or $currentContract.GitCommit -isnot [string] -or $currentContract.GitCommit -cne $GitCommit) { throw 'current candidate contract' }
        $currentAssets = @($currentContract.Assets)
        $completeAssets = @($completeCandidate.assetHashes)
        if ($currentAssets.Count -ne 11 -or $completeAssets.Count -ne $currentAssets.Count) { throw 'complete candidate asset count' }
        for ($assetIndex = 0; $assetIndex -lt $currentAssets.Count; $assetIndex++) {
            if ($completeAssets[$assetIndex].name -isnot [string] -or $completeAssets[$assetIndex].name -cne [string]$currentAssets[$assetIndex].name -or
                $completeAssets[$assetIndex].sha256 -isnot [string] -or $completeAssets[$assetIndex].sha256 -cne [string]$currentAssets[$assetIndex].sha256) { throw 'complete candidate asset binding' }
        }
        if ([string]$completeCandidate.version -cne [string]$record.version -or
            [string]$completeCandidate.gitCommit -cne [string]$record.gitCommit -or
            [string]$completeCandidate.manifestHashes.portable -cne [string]$record.candidateManifestSha256 -or
            [string]$state.Complete.draft.tag -cne [string]$record.draft.tag -or
            [string]$state.Complete.draft.id -cne [string]$record.draft.id) { throw 'complete candidate binding' }
        $expectedStatePhases = @('Preflight','LegacyUpgrade','Uninstall','FreshInstall','PreReboot','PostReboot','ReadyForManualEvidence','Complete')
        $stateHashes = @($record.automatedReceiptSha256)
        if ($stateHashes.Count -ne $expectedStatePhases.Count) { throw 'automated receipt hash count' }
        for ($index = 0; $index -lt $expectedStatePhases.Count; $index++) {
            $entry = $stateHashes[$index]
            if ($entry -isnot [pscustomobject] -or (@($entry.PSObject.Properties.Name) -join ',') -cne 'phase,sha256' -or
                $entry.phase -isnot [string] -or $entry.phase -cne $expectedStatePhases[$index] -or
                $entry.sha256 -isnot [string] -or $entry.sha256 -cnotmatch '^[0-9a-f]{64}\z') { throw 'automated receipt hash shape' }
            $leaf = if ($entry.phase -ceq 'Complete') { '08-Complete.json' } else { '{0}-{1}.json' -f ('{0:d2}' -f ($index + 1)), $entry.phase }
            $statePath = Join-Path $stateDirectory $leaf
            if ((Get-CcodGitHubDraftFileSha256 $statePath) -cne [string]$entry.sha256) { throw 'automated receipt hash binding' }
        }
    } catch {
        Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_ACCEPTANCE_INVALID' 'Promotion requires the complete, candidate-bound automated official-draft receipt chain.' $stateDirectory
    }
    $expectedOperations = @('About','Language','OpenLogs','Repair','SecondDeviceControl')
    $expectedStates = @('AboutVisible','LanguageChanged','LogsOpened','RepairCompleted','SecondDeviceControlled')
    $expectedResults = @('CCOD_TRAYABOUT_COMPLETED','CCOD_TRAYLANGUAGE_COMPLETED','CCOD_TRAYOPENLOGS_COMPLETED','CCOD_TRAYREPAIR_COMPLETED','CCOD_SECONDDEVICE_COMPLETED')
    $manual = @($record.manualEvidence)
    if ($manual.Count -ne $expectedOperations.Count) {
        Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_ACCEPTANCE_INCOMPLETE' 'Promotion requires all four tray records and the distinct second-device record.' $path
    }
    $seenHashes = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    for ($index = 0; $index -lt $expectedOperations.Count; $index++) {
        $entry = $manual[$index]
        if ($entry -isnot [pscustomobject] -or (@($entry.PSObject.Properties.Name) -join ',') -cne 'schemaVersion,kind,phase,operation,terminalState,result,proof,reviewState,version,gitCommit,candidateManifestSha256,screenshotSha256,redactedLogSha256' -or
            -not (Test-CcodGitHubDraftSchemaVersion $entry.schemaVersion) -or $entry.schemaVersion -ne 1 -or $entry.kind -isnot [string] -or $entry.kind -cne 'manual-evidence' -or
            $entry.phase -isnot [string] -or $entry.operation -isnot [string] -or $entry.operation -cne $expectedOperations[$index] -or
            $entry.terminalState -isnot [string] -or $entry.terminalState -cne $expectedStates[$index] -or
            $entry.result -isnot [string] -or $entry.result -cne $expectedResults[$index] -or $entry.reviewState -isnot [string] -or $entry.reviewState -cne 'Reviewed' -or
            $entry.version -isnot [string] -or $entry.version -cne $Version -or $entry.gitCommit -isnot [string] -or $entry.gitCommit -cne $GitCommit -or
            $entry.candidateManifestSha256 -isnot [string] -or $entry.candidateManifestSha256 -cne $record.candidateManifestSha256 -or
            $entry.screenshotSha256 -isnot [string] -or $entry.screenshotSha256 -cnotmatch '^[0-9a-f]{64}\z' -or
            $entry.redactedLogSha256 -isnot [string] -or $entry.redactedLogSha256 -cnotmatch '^[0-9a-f]{64}\z' -or
            $entry.screenshotSha256 -ceq $entry.redactedLogSha256 -or
            -not (Test-CcodGitHubDraftManualProof -Proof $entry.proof -Index $index -Version $Version) -or
            -not $seenHashes.Add([string]$entry.screenshotSha256) -or -not $seenHashes.Add([string]$entry.redactedLogSha256)) {
            Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_ACCEPTANCE_INVALID' 'Manual acceptance evidence is malformed, duplicated, or not bound to this candidate.' $path
        }
        if (($index -lt 4 -and $entry.phase -cne 'TrayEvidence') -or ($index -eq 4 -and $entry.phase -cne 'RemoteEvidence')) {
            Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_ACCEPTANCE_INVALID' 'Manual acceptance evidence has the wrong phase for its operation.' $path
        }
    }
    $stateCompleteManual = @($state.Complete.facts.manualEvidence)
    $stateFileManual = @()
    foreach ($operation in $expectedOperations) {
        if (-not $state.ManualEvidence.ContainsKey($operation)) { Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_ACCEPTANCE_INVALID' 'Persisted manual acceptance state is incomplete.' $stateDirectory }
        $stateFileManual += $state.ManualEvidence[$operation]
    }
    if ($stateCompleteManual.Count -ne $manual.Count -or $stateFileManual.Count -ne $manual.Count) {
        Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_ACCEPTANCE_INVALID' 'Acceptance manual evidence is not bound to persisted manual state.' $path
    }
    $manualCompareFields = @('schemaVersion','kind','phase','operation','terminalState','result','proof','reviewState','version','gitCommit','candidateManifestSha256','screenshotSha256','redactedLogSha256')
    for ($index = 0; $index -lt $manual.Count; $index++) {
        foreach ($source in @($stateCompleteManual[$index],$stateFileManual[$index])) {
            foreach ($field in $manualCompareFields) {
                $leftProperty = @($manual[$index].PSObject.Properties | Where-Object { $_.Name -ceq $field })
                $rightProperty = @($source.PSObject.Properties | Where-Object { $_.Name -ceq $field })
                if ($leftProperty.Count -ne 1 -or $rightProperty.Count -ne 1) {
                    Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_ACCEPTANCE_INVALID' 'Acceptance manual evidence is not bound to persisted manual state.' $path
                }
                $leftValue = [string]$leftProperty[0].Value
                $rightValue = [string]$rightProperty[0].Value
                if ($field -ceq 'proof') {
                    $leftValue = $leftProperty[0].Value | ConvertTo-Json -Depth 12 -Compress
                    $rightValue = $rightProperty[0].Value | ConvertTo-Json -Depth 12 -Compress
                }
                if ($leftValue -cne $rightValue) {
                    Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_ACCEPTANCE_INVALID' 'Acceptance manual evidence is not bound to persisted manual state.' $path
                }
            }
        }
    }
    [void](Assert-CcodGitHubDraftManualEvidenceArtifacts -EvidenceDirectory $EvidenceDirectory -ManualEvidence $manual)
    return $record
}

function Invoke-CcodGitHubDraftBoundPrivateRecovery {
    param([Parameter(Mandatory)]$Adapters,[Parameter(Mandatory)][string]$Tag,[Parameter(Mandatory)]$DraftId)
    if ($DraftId -isnot [string] -or $DraftId -notmatch '^[1-9][0-9]*\z') { throw 'bound recovery ID' }
    # Hide only the previously authenticated release. Content/tag failures must not block containment.
    for ($observation = 0; $observation -lt 2; $observation++) {
        $view = & $Adapters.ViewRelease $Tag
        if ($view -isnot [pscustomobject] -or (@($view.PSObject.Properties.Name) -join ',') -cne 'Tag,Id,Draft,AssetNames' -or
            $view.Tag -isnot [string] -or $view.Tag -cne $Tag -or $view.Id -isnot [string] -or $view.Id -cne $DraftId -or
            $view.Draft -isnot [bool]) { throw 'bound recovery identity' }
        if ($observation -eq 0) {
            if (-not $view.Draft) { & $Adapters.SetReleaseDraftState $Tag $true $DraftId | Out-Null }
        } elseif (-not $view.Draft) { throw 'bound recovery private readback' }
    }
}

function Restore-CcodGitHubDraftPrivateState {
    param([Parameter(Mandatory)]$Adapters,[Parameter(Mandatory)][string]$Tag,[Parameter(Mandatory)][string]$Version,[Parameter(Mandatory)]$Verification,[Parameter(Mandatory)]$Acceptance,[Parameter(Mandatory)][string]$ExpectedGitCommit)
    try {
        if ($Verification.draftId -isnot [string] -or $Acceptance.draft.id -isnot [string] -or
            $Verification.draftId -cne $Acceptance.draft.id) { throw 'recovery receipt identity' }
        Invoke-CcodGitHubDraftBoundPrivateRecovery -Adapters $Adapters -Tag $Tag -DraftId $Verification.draftId
    } catch {
        Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_PROMOTE_ROLLBACK_FAILED' 'Promotion failed after changing visibility and private recovery was not proven.' $Tag
    }
}

function Assert-CcodGitHubDraftRecoveryView {
    param([Parameter(Mandatory)][string]$Tag,[Parameter(Mandatory)][string]$Version,[Parameter(Mandatory)][string]$DraftId,$View)
    if ($null -eq $View -or $View -isnot [pscustomobject]) { throw 'recovery view' }
    $fields = @($View.PSObject.Properties.Name)
    if (($fields -join ',') -cne 'Tag,Id,Draft,AssetNames' -or
        $View.Tag -isnot [string] -or $View.Tag -cne $Tag -or
        $View.Id -isnot [string] -or $View.Id -cne $DraftId -or
        $View.Draft -isnot [bool] -or $null -eq $View.AssetNames) { throw 'recovery view schema' }
    $expected = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($name in @(Get-CcodExpectedReleaseAssetNames -Version $Version)) { [void]$expected.Add($name) }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($name in @($View.AssetNames)) {
        if ($name -isnot [string] -or -not $expected.Contains([string]$name) -or -not $seen.Add([string]$name)) { throw 'recovery asset set' }
    }
    [string[]]$seen
}

function Restore-CcodGitHubDraftStagePrivateState {
    param([Parameter(Mandatory)][hashtable]$Adapters,[Parameter(Mandatory)][string]$Tag,[Parameter(Mandatory)][string]$Version,[Parameter(Mandatory)]$DraftId,[Parameter(Mandatory)][string]$ExpectedGitCommit)
    try {
        Invoke-CcodGitHubDraftBoundPrivateRecovery -Adapters $Adapters -Tag $Tag -DraftId $DraftId
    } catch {
        Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_UPLOAD_PRIVATE_RECOVERY_FAILED' 'Stage upload failed and the draft could not be proven private again.' $Tag
    }
}

function Restore-CcodGitHubDraftStageAttemptPrivateState {
    param([Parameter(Mandatory)][hashtable]$Adapters,[Parameter(Mandatory)][string]$Tag,[Parameter(Mandatory)][string]$Version,[Parameter(Mandatory)][string]$ExpectedGitCommit)
    try {
        $view = & $Adapters.ViewRelease $Tag
        if ($null -eq $view -or $view -isnot [pscustomobject] -or $view.Id -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$view.Id)) { throw 'create attempt view' }
        [void](Assert-CcodGitHubDraftRecoveryView -Tag $Tag -Version $Version -DraftId ([string]$view.Id) -View $view)
        Assert-CcodGitHubDraftTagCommit -Tag $Tag -ExpectedCommit $ExpectedGitCommit -Adapters $Adapters -ActionsOnly $false
        if (-not [bool]$view.Draft) { & $Adapters.SetReleaseDraftState $Tag $true ([string]$view.Id) }
        $privateView = & $Adapters.ViewRelease $Tag
        [void](Assert-CcodGitHubDraftRecoveryView -Tag $Tag -Version $Version -DraftId ([string]$view.Id) -View $privateView)
        if (-not [bool]$privateView.Draft) { throw 'create attempt private readback visibility' }
        Assert-CcodGitHubDraftTagCommit -Tag $Tag -ExpectedCommit $ExpectedGitCommit -Adapters $Adapters -ActionsOnly $false
    } catch {
        Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_UPLOAD_PRIVATE_RECOVERY_FAILED' 'Stage create failed and the created draft could not be proven private again.' $Tag
    }
}

function Invoke-CcodGitHubDraftReleaseCore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Stage','Verify','Promote')][string]$Mode,
        [Parameter(Mandatory)][ValidatePattern('^v\d+\.\d+\.\d+\z')][string]$Tag,
        [Parameter(Mandatory)][string]$AssetDirectory,
        [Parameter(Mandatory)][string]$EvidenceDirectory,
        [string]$NotesPath,
        [hashtable]$Adapters
    )
    $Mode = if ($Mode -ieq 'Stage') { 'Stage' } elseif ($Mode -ieq 'Verify') { 'Verify' } elseif ($Mode -ieq 'Promote') { 'Promote' } else { Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_MODE_INVALID' 'Release mode is invalid.' $Mode }
    $adapters = Resolve-CcodGitHubDraftReleaseAdapters $Adapters
    $version = $Tag.Substring(1)
    if (-not (Test-CcodGitHubDraftCanonicalAbsolutePath $AssetDirectory)) { Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_ASSET_PATH_INVALID' 'Asset directory must be an absolute canonical path.' $AssetDirectory }
    if (-not (Test-CcodGitHubDraftCanonicalAbsolutePath $EvidenceDirectory)) { Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_EVIDENCE_PATH_INVALID' 'Evidence directory must be an absolute canonical path.' $EvidenceDirectory }
    $assetDir = [string]$AssetDirectory
    $evidenceDir = [string]$EvidenceDirectory
    Import-CcodDraftReleaseAssetContract
    $evidenceDir = Assert-CcodGitHubDraftPlainPath -Path $evidenceDir -Directory $true
    if ($Mode -ceq 'Promote') {
        $promoteLockHeld = $false
        $publicMutationAttempted = $false
        $postReadRoot = $null
        $frozen = $null
        $verification = $null
        $acceptance = $null
        $assets = $null
        try {
            if ($null -eq $Adapters) {
                $promoteLockHeld = [bool](& $adapters.AcquireStageLock $Tag)
            } else {
                $promoteLockHeld = [bool](& $adapters.TryStageLock $Tag)
            }
            if (-not $promoteLockHeld) {
                Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_CONCURRENT' 'Same-tag release operation is already running.' $Tag
            }
            $assets = Test-CcodExactReleaseAssetSet -AssetDirectory $assetDir -Version $version
            Assert-CcodGitHubDraftTagCommit -Tag $Tag -ExpectedCommit ([string]$assets.GitCommit) -Adapters $adapters -ActionsOnly $false
            $preflight = Join-Path $evidenceDir (Get-CcodGitHubDraftPreflightName $version)
            $preflightHash = $null
            $preflightRecord = Read-CcodGitHubDraftPreflight -Path $preflight -Version $version -GitCommit ([string]$assets.GitCommit) -PinnedSha256 ([ref]$preflightHash)
            if ((Get-CcodGitHubDraftFileSha256 $preflight) -cne $preflightHash) {
                Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_PREFLIGHT_INVALID' 'Transferred preflight evidence changed after its pinned read.' $preflight
            }
            $frozen = New-CcodGitHubDraftFrozenAssetSet -AssetDirectory $assetDir -Version $version -Contract $assets
            try {
                $frozenDirectory = [string]$frozen.Directory
                $defenderEvidence = Get-CcodGitHubDraftDefenderEvidenceDirectory $evidenceDir
                try {
                    Test-CcodReleasePromotionEvidence -EvidenceDirectory $defenderEvidence -AssetDirectory $frozenDirectory -Version $version -ExpectedGitCommit $assets.GitCommit | Out-Null
                } catch {
                    $id = ([string]$_.FullyQualifiedErrorId -split '[,:]')[0]
                    if ($id -ceq 'CCOD_RELEASE_PROMOTION_EVIDENCE_INVALID' -or $id -ceq 'CCOD_RELEASE_ASSET_SET_INVALID') { throw }
                    Throw-CcodGitHubDraftError 'CCOD_RELEASE_PROMOTION_EVIDENCE_INVALID' 'Promotion requires Task 5 dual InternetDownload receipts.' $defenderEvidence
                }
                $acceptance = Read-CcodGitHubDraftAcceptance -EvidenceDirectory $evidenceDir -AssetDirectory $frozenDirectory -Tag $Tag -Version $version -GitCommit ([string]$assets.GitCommit)
                $verification = Read-CcodGitHubDraftVerification -EvidenceDirectory $evidenceDir -AssetDirectory $frozenDirectory -Tag $Tag -Version $version -GitCommit ([string]$assets.GitCommit)
                $acceptancePath = Get-CcodGitHubDraftAcceptancePath $evidenceDir $version
                $verificationPath = Get-CcodGitHubDraftVerificationPath $evidenceDir $version
                $acceptanceHash = Get-CcodGitHubDraftFileSha256 $acceptancePath
                $verificationHash = Get-CcodGitHubDraftFileSha256 $verificationPath
                try {
                    $view = & $adapters.ViewRelease $Tag
                } catch {
                    Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_NOT_STAGED' 'Could not read the already verified GitHub draft state.' $Tag
                }
                $expected = @(Assert-CcodGitHubDraftRemoteView -Tag $Tag -Version $version -View $view)
                if ([string]$view.Id -cne [string]$verification.draftId -or [string]$view.Id -cne [string]$acceptance.draft.id) {
                    Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_PROMOTE_READBACK_FAILED' 'The acceptance, Verify receipt, and current GitHub draft do not share one release identity.' $Tag
                }
                $readRoot = Join-Path ([IO.Path]::GetTempPath()) ('ccod-draft-promote-' + [guid]::NewGuid().ToString('N'))
                [IO.Directory]::CreateDirectory($readRoot) | Out-Null
                try {
                    for ($index = 0; $index -lt $expected.Count; $index++) {
                        $name = $expected[$index]
                        $destination = Join-Path $readRoot $name
                        Invoke-CcodGitHubDraftDownloadAsset -Adapters $adapters -Tag $Tag -Name $name -Destination $destination -ErrorId 'CCOD_GITHUB_DRAFT_READBACK_FAILED'
                        $actualHash = Get-CcodGitHubDraftFileSha256 $destination
                        if ($actualHash -cne [string]$verification.assetSha256[$index] -or $actualHash -cne (Get-CcodGitHubDraftFileSha256 (Join-Path $frozenDirectory $name))) {
                            Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_PROMOTE_READBACK_FAILED' 'Verified draft asset changed before promotion.' $name
                        }
                    }
                } finally {
                    Remove-CcodGitHubDraftDirectoryIfPresent -Path $readRoot
                }
                try {
                    $beforePublishView = & $adapters.ViewRelease $Tag
                } catch {
                    Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_PROMOTE_READBACK_FAILED' 'Could not re-read the private draft before promotion.' $Tag
                }
                [void](Assert-CcodGitHubDraftRemoteView -Tag $Tag -Version $version -View $beforePublishView)
                if ([string]$beforePublishView.Id -cne [string]$verification.draftId -or [string]$beforePublishView.Id -cne [string]$acceptance.draft.id) {
                    Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_PROMOTE_READBACK_FAILED' 'The GitHub draft identity changed before promotion.' $Tag
                }
                Assert-CcodGitHubDraftTagCommit -Tag $Tag -ExpectedCommit ([string]$assets.GitCommit) -Adapters $adapters -ActionsOnly $false
                if ((Get-CcodGitHubDraftFileSha256 $acceptancePath) -cne $acceptanceHash -or (Get-CcodGitHubDraftFileSha256 $verificationPath) -cne $verificationHash) { Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_ACCEPTANCE_INVALID' 'Acceptance or Verify evidence changed before promotion.' $evidenceDir }
                Test-CcodReleasePromotionEvidence -EvidenceDirectory $defenderEvidence -AssetDirectory $frozenDirectory -Version $version -ExpectedGitCommit $assets.GitCommit | Out-Null
                $finalAcceptance = Read-CcodGitHubDraftAcceptance -EvidenceDirectory $evidenceDir -AssetDirectory $frozenDirectory -Tag $Tag -Version $version -GitCommit ([string]$assets.GitCommit)
                $finalVerification = Read-CcodGitHubDraftVerification -EvidenceDirectory $evidenceDir -AssetDirectory $frozenDirectory -Tag $Tag -Version $version -GitCommit ([string]$assets.GitCommit)
                if ([string]$finalAcceptance.draft.id -cne [string]$acceptance.draft.id -or [string]$finalVerification.draftId -cne [string]$verification.draftId) { Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_ACCEPTANCE_INVALID' 'Acceptance evidence identity changed before promotion.' $evidenceDir }
                if ((Get-CcodGitHubDraftFileSha256 $acceptancePath) -cne $acceptanceHash -or (Get-CcodGitHubDraftFileSha256 $verificationPath) -cne $verificationHash) { Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_ACCEPTANCE_INVALID' 'Acceptance or Verify evidence changed after the final evidence read and before promotion.' $evidenceDir }
                $postReadRoot = $null
                try {
                    $postReadRoot = Join-Path ([IO.Path]::GetTempPath()) ('ccod-draft-post-promote-' + [guid]::NewGuid().ToString('N'))
                    [IO.Directory]::CreateDirectory($postReadRoot) | Out-Null
                } catch {
                    Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_PROMOTE_READBACK_FAILED' 'The post-promotion readback workspace could not be prepared before visibility changed.' $null
                }
                $setReleaseDraftState = $adapters.SetReleaseDraftState
                $heldEvidenceHashes = @{}
                $heldEvidenceHashes[[string]$preflight] = [string]$preflightHash
                $heldEvidenceHashes[[string]$acceptancePath] = [string]$acceptanceHash
                $heldEvidenceHashes[[string]$verificationPath] = [string]$verificationHash
                $acceptanceStateRoot = Join-Path $evidenceDir 'official-draft-acceptance'
                $acceptanceStatePhases = @('Preflight','LegacyUpgrade','Uninstall','FreshInstall','PreReboot','PostReboot','ReadyForManualEvidence','Complete')
                foreach ($stateHash in @($acceptance.automatedReceiptSha256)) {
                    $stateIndex = [array]::IndexOf($acceptanceStatePhases, [string]$stateHash.phase)
                    if ($stateIndex -lt 0) { Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_ACCEPTANCE_INVALID' 'Acceptance automated receipt phase is not recognized.' $acceptancePath }
                    $stateLeaf = if ([string]$stateHash.phase -ceq 'Complete') { '08-Complete.json' } else { '{0}-{1}.json' -f ('{0:d2}' -f ($stateIndex + 1)), [string]$stateHash.phase }
                    $heldEvidenceHashes[(Join-Path $acceptanceStateRoot $stateLeaf)] = [string]$stateHash.sha256
                }
                $manualArtifactRoot = Join-Path $evidenceDir 'official-draft-artifacts'
                $manualStateRoot = Join-Path $acceptanceStateRoot 'manual-evidence'
                $manualStateLeaves = @{
                    About = 'TrayEvidence-About.json'
                    Language = 'TrayEvidence-Language.json'
                    OpenLogs = 'TrayEvidence-OpenLogs.json'
                    Repair = 'TrayEvidence-Repair.json'
                    SecondDeviceControl = 'RemoteEvidence-SecondDeviceControl.json'
                }
                foreach ($manualEntry in @($acceptance.manualEvidence)) {
                    if ($manualEntry.operation -isnot [string] -or -not $manualStateLeaves.ContainsKey([string]$manualEntry.operation)) {
                        Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_ACCEPTANCE_INVALID' 'Acceptance manual operation is not recognized.' $acceptancePath
                    }
                    $manualStatePath = Join-Path $manualStateRoot $manualStateLeaves[[string]$manualEntry.operation]
                    $heldEvidenceHashes[$manualStatePath] = [string](Get-CcodGitHubDraftFileSha256 $manualStatePath)
                    $manualDirectory = Join-Path $manualArtifactRoot ([string]$manualEntry.operation)
                    $heldEvidenceHashes[(Join-Path $manualDirectory 'screenshot.bin')] = [string]$manualEntry.screenshotSha256
                    $heldEvidenceHashes[(Join-Path $manualDirectory 'redacted.log')] = [string]$manualEntry.redactedLogSha256
                }
                $publicMutationAttempted = $true
                try {
                    & $script:CcodDraftReleaseAssetContractModule {
                        param($EvidenceDirectory,$AssetDirectory,$Version,$GitCommit,$SetReleaseDraftState,$Tag,$HeldFileHashes,$DraftModule,$AcceptanceEvidenceDirectory,$BoundReleaseId)
                        $publish = {
                            param($AssetAuthority,$EvidenceAuthority,$ReceiptAuthorities)
                            # Validate semantics again while every acceptance byte and parent is held.
                            & $DraftModule {
                                param($EvidenceDirectory,$AssetDirectory,$Tag,$Version,$GitCommit)
                                Read-CcodGitHubDraftAcceptance -EvidenceDirectory $EvidenceDirectory -AssetDirectory $AssetDirectory -Tag $Tag -Version $Version -GitCommit $GitCommit | Out-Null
                            } $AcceptanceEvidenceDirectory $AssetDirectory $Tag $Version $GitCommit
                            & $SetReleaseDraftState $Tag $false $BoundReleaseId
                        }.GetNewClosure()
                        Test-CcodReleasePromotionEvidenceCore -EvidenceDirectory $EvidenceDirectory -AssetDirectory $AssetDirectory -Version $Version -ExpectedGitCommit $GitCommit -BeforeReturn $publish -HeldFileHashes $HeldFileHashes | Out-Null
                    } $defenderEvidence $frozenDirectory $version ([string]$assets.GitCommit) $setReleaseDraftState $Tag $heldEvidenceHashes $ExecutionContext.SessionState.Module $evidenceDir $verification.draftId
                } catch {
                    $promotionFailure = $_
                    Restore-CcodGitHubDraftPrivateState -Adapters $adapters -Tag $Tag -Version $version -Verification $verification -Acceptance $acceptance -ExpectedGitCommit ([string]$assets.GitCommit)
                    throw $promotionFailure
                }
                try {
                    $postView = & $adapters.ViewRelease $Tag
                    [void](Assert-CcodGitHubDraftRemoteView -Tag $Tag -Version $version -View $postView -AfterPromotion)
                    if ([string]$postView.Id -cne [string]$verification.draftId -or [string]$postView.Id -cne [string]$acceptance.draft.id) { throw 'post-promotion identity' }
                    Assert-CcodGitHubDraftTagCommit -Tag $Tag -ExpectedCommit ([string]$assets.GitCommit) -Adapters $adapters -ActionsOnly $false
                } catch {
                    $promotionFailure = $_
                    Restore-CcodGitHubDraftPrivateState -Adapters $adapters -Tag $Tag -Version $version -Verification $verification -Acceptance $acceptance -ExpectedGitCommit ([string]$assets.GitCommit)
                    throw $promotionFailure
                }
                try {
                    for ($index = 0; $index -lt $expected.Count; $index++) {
                        $name = $expected[$index]
                        $destination = Join-Path $postReadRoot $name
                        Invoke-CcodGitHubDraftDownloadAsset -Adapters $adapters -Tag $Tag -Name $name -Destination $destination -ErrorId 'CCOD_GITHUB_DRAFT_PROMOTE_READBACK_FAILED'
                        $actualHash = Get-CcodGitHubDraftFileSha256 $destination
                        if ($actualHash -cne [string]$verification.assetSha256[$index] -or $actualHash -cne (Get-CcodGitHubDraftFileSha256 (Join-Path $frozenDirectory $name))) {
                            Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_PROMOTE_READBACK_FAILED' 'Public release asset changed after promotion.' $name
                        }
                    }
                    $finalPostView = & $adapters.ViewRelease $Tag
                    [void](Assert-CcodGitHubDraftRemoteView -Tag $Tag -Version $version -View $finalPostView -AfterPromotion)
                    if ([string]$finalPostView.Id -cne [string]$verification.draftId -or [string]$finalPostView.Id -cne [string]$acceptance.draft.id) { throw 'post-promotion final identity' }
                    Assert-CcodGitHubDraftTagCommit -Tag $Tag -ExpectedCommit ([string]$assets.GitCommit) -Adapters $adapters -ActionsOnly $false
                } catch {
                    $promotionFailure = $_
                    try {
                        Restore-CcodGitHubDraftPrivateState -Adapters $adapters -Tag $Tag -Version $version -Verification $verification -Acceptance $acceptance -ExpectedGitCommit ([string]$assets.GitCommit)
                    } catch {
                        Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_PROMOTE_ROLLBACK_FAILED' 'Public promotion readback failed and the draft could not be proven private again.' $Tag
                    }
                    throw $promotionFailure
                } finally {
                    try { Remove-CcodGitHubDraftDirectoryIfPresent -Path $postReadRoot } catch { $promotionFailure = $_; Restore-CcodGitHubDraftPrivateState -Adapters $adapters -Tag $Tag -Version $version -Verification $verification -Acceptance $acceptance -ExpectedGitCommit ([string]$assets.GitCommit); throw $promotionFailure }
                }
                return [pscustomobject][ordered]@{ Mode = $Mode; Tag = $Tag; Draft = $false; Promoted = $true }
            } finally {
                try {
                    if ($null -ne $postReadRoot) { Remove-CcodGitHubDraftDirectoryIfPresent -Path $postReadRoot }
                } catch {
                    $cleanupFailure = $_
                    if ($publicMutationAttempted -and $null -ne $verification -and $null -ne $acceptance) {
                        try { Restore-CcodGitHubDraftPrivateState -Adapters $adapters -Tag $Tag -Version $version -Verification $verification -Acceptance $acceptance -ExpectedGitCommit ([string]$assets.GitCommit) } catch { Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_PROMOTE_ROLLBACK_FAILED' 'Promotion cleanup failed and the draft could not be proven private again.' $Tag }
                    }
                    throw $cleanupFailure
                }
                try { Remove-CcodGitHubDraftFrozenAssetSet $frozen } catch { $cleanupFailure = $_; if ($publicMutationAttempted -and $null -ne $verification -and $null -ne $acceptance) { Restore-CcodGitHubDraftPrivateState -Adapters $adapters -Tag $Tag -Version $version -Verification $verification -Acceptance $acceptance -ExpectedGitCommit ([string]$assets.GitCommit) }; throw $cleanupFailure }
            }
        } finally {
            if ($promoteLockHeld) {
                try { & $adapters.ReleaseStageLock $Tag } catch { $cleanupFailure = $_; if ($publicMutationAttempted -and $null -ne $verification -and $null -ne $acceptance) { Restore-CcodGitHubDraftPrivateState -Adapters $adapters -Tag $Tag -Version $version -Verification $verification -Acceptance $acceptance -ExpectedGitCommit ([string]$assets.GitCommit) }; throw $cleanupFailure }
            }
        }
    }
    $defaultLockHeld = $false
    try {
        if ($null -eq $Adapters) {
            $defaultLockHeld = [bool](& $adapters.AcquireStageLock $Tag)
        } else {
            $defaultLockHeld = [bool](& $adapters.TryStageLock $Tag)
        }
        if (-not $defaultLockHeld) {
            Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_CONCURRENT' 'Same-tag Stage is already running.' $Tag
        }
        $preflight = Join-Path $evidenceDir (Get-CcodGitHubDraftPreflightName $version)
    $assets = $null
    if ($Mode -ceq 'Stage') {
        $preflightItem = $null
        try { $preflightItem = Get-Item -LiteralPath $preflight -Force -ErrorAction Stop } catch { if (Test-CcodGitHubDraftMissingError $_) { Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_PREFLIGHT_MISSING' 'Stage requires transferred clean-runner preflight evidence.' $preflight } Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_PREFLIGHT_INVALID' 'Transferred clean-runner preflight evidence could not be inspected safely.' $preflight }
        if ($preflightItem.PSIsContainer -or ($preflightItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_PREFLIGHT_INVALID' 'Transferred clean-runner preflight evidence is not a plain file.' $preflight }
        $assets = Test-CcodExactReleaseAssetSet -AssetDirectory $assetDir -Version $version
        Assert-CcodGitHubDraftTagCommit -Tag $Tag -ExpectedCommit ([string]$assets.GitCommit) -Adapters $adapters -ActionsOnly $true
        Read-CcodGitHubDraftPreflight -Path $preflight -Version $version -GitCommit ([string]$assets.GitCommit) | Out-Null
    }
    if ($Mode -ceq 'Verify') {
        $assets = Test-CcodExactReleaseAssetSet -AssetDirectory $assetDir -Version $version
        Assert-CcodGitHubDraftTagCommit -Tag $Tag -ExpectedCommit ([string]$assets.GitCommit) -Adapters $adapters -ActionsOnly $false
        Read-CcodGitHubDraftPreflight -Path $preflight -Version $version -GitCommit ([string]$assets.GitCommit) | Out-Null
        $frozen = New-CcodGitHubDraftFrozenAssetSet -AssetDirectory $assetDir -Version $version -Contract $assets
        $frozenAuthority = $null
        try {
            $frozenDirectory = [string]$frozen.Directory
            $contractModule = $script:CcodDraftReleaseAssetContractModule
            $frozenAuthority = & $contractModule {
                param($Path,$Version)
                Open-CcodExactReleaseAssetAuthority -AssetDirectory $Path -Version $Version -ErrorId 'CCOD_GITHUB_DRAFT_ASSET_FREEZE_FAILED'
            } $frozenDirectory $version
            $contractAssets = @($assets.Assets)
            $verificationHashes = [Collections.Generic.List[string]]::new()
            if ($contractAssets.Count -ne $frozenAuthority.Files.Count) { Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_ASSET_FREEZE_FAILED' 'Frozen candidate membership changed before authority acquisition.' $Tag }
            for ($index = 0; $index -lt $contractAssets.Count; $index++) {
                $heldFile = $frozenAuthority.Files[$index]
                if ($contractAssets[$index].name -isnot [string] -or $contractAssets[$index].name -cne $heldFile.Leaf -or
                    $contractAssets[$index].sha256 -isnot [string] -or $contractAssets[$index].sha256 -cne $heldFile.Sha256) {
                    Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_ASSET_FREEZE_FAILED' 'Held frozen bytes do not match the original validated contract.' $Tag
                }
                $verificationHashes.Add([string]$heldFile.Sha256)
            }
            $manifestIndex = [Array]::IndexOf([string[]]$frozenAuthority.Names, (Get-CcodGitHubDraftManifestName $version))
            if ($manifestIndex -lt 0) { Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_ASSET_FREEZE_FAILED' 'The held candidate manifest is missing.' $Tag }
            $candidateManifestHash = [string]$verificationHashes[$manifestIndex]
            try {
                $view = & $adapters.ViewRelease $Tag
            } catch {
                Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_NOT_STAGED' 'Could not read the staged GitHub draft state.' $Tag
            }
            $expected = @(Assert-CcodGitHubDraftRemoteView -Tag $Tag -Version $version -View $view)
            $draftId = [string]$view.Id
            $readRoot = Join-Path ([IO.Path]::GetTempPath()) ('ccod-draft-verify-' + [guid]::NewGuid().ToString('N'))
            [IO.Directory]::CreateDirectory($readRoot) | Out-Null
            try {
                $index = 0
                foreach ($name in $expected) {
                    $destination = Join-Path $readRoot $name
                    Invoke-CcodGitHubDraftDownloadAsset -Adapters $adapters -Tag $Tag -Name $name -Destination $destination -ErrorId 'CCOD_GITHUB_DRAFT_READBACK_FAILED'
                    $expectedHash = [string]$verificationHashes[$index]
                    $actualHash = Get-CcodGitHubDraftFileSha256 $destination
                    if ($expectedHash -cne $actualHash) {
                        Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_READBACK_FAILED' 'Verified draft asset hash does not match the frozen candidate.' $name
                    }
                    $index++
                }
            } finally {
                Remove-CcodGitHubDraftDirectoryIfPresent -Path $readRoot
            }
            $assertFinalPrivateLineage = {
                try {
                    & $contractModule { param($Authority) Assert-CcodExactReleaseAssetAuthorityCurrent -Authority $Authority -ErrorId 'CCOD_GITHUB_DRAFT_VERIFY_EVIDENCE_INVALID' | Out-Null } $frozenAuthority
                    $finalView = & $adapters.ViewRelease $Tag
                    if ($null -eq $finalView -or $finalView -isnot [pscustomobject] -or (@($finalView.PSObject.Properties.Name) -join ',') -cne 'Tag,Id,Draft,AssetNames' -or
                        $finalView.Tag -isnot [string] -or $finalView.Tag -cne $Tag -or $finalView.Id -isnot [string] -or $finalView.Id -notmatch '^[1-9][0-9]*\z' -or $finalView.Id -cne $draftId -or
                        $finalView.Draft -isnot [bool] -or -not [bool]$finalView.Draft) { return $false }
                    $finalNames = @($finalView.AssetNames)
                    if ($finalNames.Count -ne $expected.Count -or @($finalNames | Where-Object { $_ -isnot [string] }).Count -ne 0 -or (($finalNames -join "`n") -cne ($expected -join "`n"))) { return $false }
                    $rawFinalCommit = & $adapters.GetTagCommit $Tag $false
                    if ($rawFinalCommit -isnot [string] -or $rawFinalCommit -cnotmatch '^[0-9a-f]{40}\z' -or $rawFinalCommit -cne [string]$assets.GitCommit) { return $false }
                    & $contractModule { param($Authority) Assert-CcodExactReleaseAssetAuthorityCurrent -Authority $Authority -ErrorId 'CCOD_GITHUB_DRAFT_VERIFY_EVIDENCE_INVALID' | Out-Null } $frozenAuthority
                    return $true
                } catch { return $false }
            }.GetNewClosure()
            if (-not [bool](& $assertFinalPrivateLineage)) {
                Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_VERIFY_EVIDENCE_INVALID' 'The private draft identity or tag commit changed before Verify evidence was published.' $Tag
            }
            $verificationRecord = [ordered]@{
                schemaVersion = 1
                kind = 'github-draft-verification'
                tag = $Tag
                draftId = $draftId
                version = $version
                gitCommit = [string]$assets.GitCommit
                draft = $true
                verified = $true
                assetNames = [string[]]$expected
                assetSha256 = [string[]]$verificationHashes
                candidateManifestSha256 = $candidateManifestHash
            }
            $verificationPath = Get-CcodGitHubDraftVerificationPath $evidenceDir $version -CreatePlane
            Write-CcodGitHubDraftJsonCreateOnly -Path $verificationPath -Record $verificationRecord -ErrorId 'CCOD_GITHUB_DRAFT_VERIFY_EVIDENCE_INVALID' -ReadbackVerifier $assertFinalPrivateLineage
            Read-CcodGitHubDraftVerification -EvidenceDirectory $evidenceDir -AssetDirectory $frozenDirectory -Tag $Tag -Version $version -GitCommit ([string]$assets.GitCommit) | Out-Null
            & $contractModule { param($Authority) Assert-CcodExactReleaseAssetAuthorityCurrent -Authority $Authority -ErrorId 'CCOD_GITHUB_DRAFT_VERIFY_EVIDENCE_INVALID' | Out-Null } $frozenAuthority
            return [pscustomobject][ordered]@{ Mode = $Mode; Tag = $Tag; Draft = $true; Verified = $true; VerificationPath = $verificationPath }
        } finally {
            if ($null -ne $frozenAuthority) { & $contractModule { param($Authority) Close-CcodExactReleaseAssetAuthority $Authority } $frozenAuthority }
            Remove-CcodGitHubDraftFrozenAssetSet $frozen
        }
    }
    $assets = Test-CcodExactReleaseAssetSet -AssetDirectory $assetDir -Version $version
    $frozen = New-CcodGitHubDraftFrozenAssetSet -AssetDirectory $assetDir -Version $version -Contract $assets
    $stageAuthority = $null
    $contractModule = $script:CcodDraftReleaseAssetContractModule
    try {
        $frozenDirectory = [string]$frozen.Directory
        $stageAuthority = & $contractModule {
            param($Path,$Version)
            Open-CcodExactReleaseAssetAuthority -AssetDirectory $Path -Version $Version -ErrorId 'CCOD_GITHUB_DRAFT_ASSET_FREEZE_FAILED'
        } $frozenDirectory $version
        $stageHashes = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
        $contractAssets = @($assets.Assets)
        if ($contractAssets.Count -ne $stageAuthority.Files.Count) { Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_ASSET_FREEZE_FAILED' 'Stage frozen membership changed before authority acquisition.' $Tag }
        for ($index = 0; $index -lt $contractAssets.Count; $index++) {
            $file = $stageAuthority.Files[$index]
            if ($contractAssets[$index].name -isnot [string] -or $contractAssets[$index].name -cne $file.Leaf -or
                $contractAssets[$index].sha256 -isnot [string] -or $contractAssets[$index].sha256 -cne $file.Sha256) {
                Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_ASSET_FREEZE_FAILED' 'Stage held bytes do not match the original validated contract.' $Tag
            }
            $stageHashes.Add([string]$file.Leaf,[string]$file.Sha256)
        }
        $notes = ''
        if (-not [string]::IsNullOrWhiteSpace($NotesPath)) {
            if (-not (Test-CcodGitHubDraftCanonicalAbsolutePath $NotesPath)) { Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_NOTES_INVALID' 'Release notes must be an absolute canonical path.' $NotesPath }
            $notesFile = Assert-CcodGitHubDraftPlainPath -Path $NotesPath -Directory $false
            $repositoryRoot = if ([string]::IsNullOrWhiteSpace([string]$script:CcodGitHubDraftModuleRoot)) { $null } else { [IO.Path]::GetFullPath((Split-Path -Parent $script:CcodGitHubDraftModuleRoot)) }
            if ($null -eq $repositoryRoot) { Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_NOTES_INVALID' 'Trusted release tool root is unavailable.' $notesFile }
            $approvedNotes = $notesFile.StartsWith($repositoryRoot.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
            $runnerTemp = $env:RUNNER_TEMP
            if (-not $approvedNotes -and -not [string]::IsNullOrWhiteSpace($runnerTemp)) {
                $runnerRoot = [IO.Path]::GetFullPath($runnerTemp)
                $approvedNotes = $notesFile.StartsWith($runnerRoot.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
            }
            if (-not $approvedNotes) { Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_NOTES_INVALID' 'Release notes must be inside the approved checkout or runner-temp root.' $notesFile }
            try {
                $notesItem = Get-Item -LiteralPath $notesFile -Force -ErrorAction Stop
                if (-not $notesItem.PSIsContainer -and $notesItem.Length -le 1048576) {
                    $notes = Read-CcodGitHubDraftNotesPinned -Path $notesFile -ErrorId 'CCOD_GITHUB_DRAFT_NOTES_INVALID'
                } else { throw 'notes bounds' }
            } catch {
                Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_NOTES_INVALID' 'Release notes are missing, invalid, or too large.' $notesFile
            }
        }
        $expected = [string[]]$frozen.Names
        $created = $false
        $createAttempted = $false
        try {
            $preCreateView = & $adapters.ProbeRelease $Tag
            if ($null -ne $preCreateView) {
                if ($preCreateView -isnot [pscustomobject] -or (@($preCreateView.PSObject.Properties.Name) -join ',') -cne 'Tag,Id,Draft,AssetNames' -or
                    $preCreateView.Tag -isnot [string] -or $preCreateView.Tag -cne $Tag -or
                    $preCreateView.Id -isnot [string] -or $preCreateView.Id -notmatch '^[1-9][0-9]*\z' -or
                    $preCreateView.Draft -isnot [bool] -or $null -eq $preCreateView.AssetNames) {
                    Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_CREATE_FAILED' 'Pre-create release probe returned invalid release identity.' $Tag
                }
                Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_CREATE_FAILED' 'A release already exists for the requested tag; Stage will not mutate it.' $Tag
            }
            $createAttempted = $true
            $createdResult = & $adapters.CreateDraft $Tag ("CodexRemote-fix $version") $notes
            if ($null -eq $createdResult -or $createdResult -isnot [pscustomobject] -or (@($createdResult.PSObject.Properties.Name) -join ',') -cne 'Tag,Id,Draft,AssetNames' -or $createdResult.Tag -isnot [string] -or $createdResult.Tag -cne $Tag -or $createdResult.Id -isnot [string] -or $createdResult.Id -notmatch '^[1-9][0-9]*\z' -or $createdResult.Draft -isnot [bool] -or -not [bool]$createdResult.Draft -or $null -eq $createdResult.AssetNames) {
                Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_CREATE_FAILED' 'Draft creation did not return a private draft state.' $Tag
            }
            $created = $true
            Assert-CcodGitHubDraftTagCommit -Tag $Tag -ExpectedCommit ([string]$assets.GitCommit) -Adapters $adapters -ActionsOnly $true
            $createdView = & $adapters.ViewRelease $Tag
            [void](Assert-CcodGitHubDraftPrivateView -Tag $Tag -Version $version -View $createdView)
            if ([string]$createdView.Id -cne [string]$createdResult.Id) {
                Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_CREATE_FAILED' 'The created draft identity changed before asset upload.' $Tag
            }
            foreach ($name in $expected) {
                Assert-CcodGitHubDraftTagCommit -Tag $Tag -ExpectedCommit ([string]$assets.GitCommit) -Adapters $adapters -ActionsOnly $true
                $beforeUploadView = & $adapters.ViewRelease $Tag
                [void](Assert-CcodGitHubDraftPrivateView -Tag $Tag -Version $version -View $beforeUploadView)
                if ([string]$beforeUploadView.Id -cne [string]$createdResult.Id) {
                    Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_CREATE_FAILED' 'The draft identity changed during asset upload.' $Tag
                }
                & $contractModule {param($Authority) Assert-CcodExactReleaseAssetAuthorityCurrent -Authority $Authority -ErrorId 'CCOD_GITHUB_DRAFT_ASSET_FREEZE_FAILED' | Out-Null} $stageAuthority
                & $adapters.UploadAsset $Tag $name (Join-Path $frozenDirectory $name)
                & $contractModule {param($Authority) Assert-CcodExactReleaseAssetAuthorityCurrent -Authority $Authority -ErrorId 'CCOD_GITHUB_DRAFT_ASSET_FREEZE_FAILED' | Out-Null} $stageAuthority
            }
            $stageView = & $adapters.ViewRelease $Tag
            [void](Assert-CcodGitHubDraftRemoteView -Tag $Tag -Version $version -View $stageView)
            if ([string]$stageView.Id -cne [string]$createdResult.Id) {
                Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_CREATE_FAILED' 'The draft identity changed after asset upload.' $Tag
            }
            Assert-CcodGitHubDraftTagCommit -Tag $Tag -ExpectedCommit ([string]$assets.GitCommit) -Adapters $adapters -ActionsOnly $true
        } catch {
            if ($created -or $createAttempted) {
                if ($created -and $null -ne $createdResult -and $createdResult.Id -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$createdResult.Id)) {
                    Restore-CcodGitHubDraftStagePrivateState -Adapters $adapters -Tag $Tag -Version $version -DraftId ([string]$createdResult.Id) -ExpectedGitCommit ([string]$assets.GitCommit)
                    Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_UPLOAD_FAILED' 'Draft upload failed; the draft was re-read and proven private.' $Tag
                }
                Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_CREATE_AMBIGUOUS' 'Draft creation failed after an absence probe; no existing release was mutated because creation ownership is unproven.' $Tag
            }
            throw
        }
        try {
            $readRoot = Join-Path ([IO.Path]::GetTempPath()) ('ccod-draft-stage-' + [guid]::NewGuid().ToString('N'))
            [IO.Directory]::CreateDirectory($readRoot) | Out-Null
            try {
                foreach ($name in $expected) {
                    $destination = Join-Path $readRoot $name
                    & $contractModule {param($Authority) Assert-CcodExactReleaseAssetAuthorityCurrent -Authority $Authority -ErrorId 'CCOD_GITHUB_DRAFT_READBACK_FAILED' | Out-Null} $stageAuthority
                    Invoke-CcodGitHubDraftDownloadAsset -Adapters $adapters -Tag $Tag -Name $name -Destination $destination -ErrorId 'CCOD_GITHUB_DRAFT_READBACK_FAILED'
                    $expectedHash = $stageHashes[$name]
                    $actualHash = Get-CcodGitHubDraftFileSha256 $destination
                    if ($expectedHash -cne $actualHash) {
                        Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_READBACK_FAILED' 'Staged draft asset hash does not match the frozen candidate.' $name
                    }
                    & $contractModule {param($Authority) Assert-CcodExactReleaseAssetAuthorityCurrent -Authority $Authority -ErrorId 'CCOD_GITHUB_DRAFT_READBACK_FAILED' | Out-Null} $stageAuthority
                }
                $finalStageView = & $adapters.ViewRelease $Tag
                [void](Assert-CcodGitHubDraftRemoteView -Tag $Tag -Version $version -View $finalStageView)
                if ([string]$finalStageView.Id -cne [string]$createdResult.Id) {
                    Throw-CcodGitHubDraftError 'CCOD_GITHUB_DRAFT_CREATE_FAILED' 'The draft identity changed after staged asset readback.' $Tag
                }
                Assert-CcodGitHubDraftTagCommit -Tag $Tag -ExpectedCommit ([string]$assets.GitCommit) -Adapters $adapters -ActionsOnly $true
            } finally {
                Remove-CcodGitHubDraftDirectoryIfPresent -Path $readRoot
            }
        } catch {
            if ($created) {
                Restore-CcodGitHubDraftStagePrivateState -Adapters $adapters -Tag $Tag -Version $version -DraftId ([string]$createdResult.Id) -ExpectedGitCommit ([string]$assets.GitCommit)
            }
            throw
        }
        & $contractModule {param($Authority) Assert-CcodExactReleaseAssetAuthorityCurrent -Authority $Authority -ErrorId 'CCOD_GITHUB_DRAFT_ASSET_FREEZE_FAILED' | Out-Null} $stageAuthority
        return [pscustomobject][ordered]@{ Mode = $Mode; Tag = $Tag; Draft = $true; Uploaded = $expected }
    } finally {
        try { if ($null -ne $stageAuthority) { & $contractModule {param($Authority) Close-CcodExactReleaseAssetAuthority $Authority} $stageAuthority } }
        finally { Remove-CcodGitHubDraftFrozenAssetSet $frozen }
    }
    } finally {
        if ($defaultLockHeld) {
            & $adapters.ReleaseStageLock $Tag
        }
    }
}

function Invoke-CcodGitHubDraftRelease {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Stage','Verify','Promote')][string]$Mode,
        [Parameter(Mandatory)][ValidatePattern('^v\d+\.\d+\.\d+\z')][string]$Tag,
        [Parameter(Mandatory)][string]$AssetDirectory,
        [Parameter(Mandatory)][string]$EvidenceDirectory,
        [string]$NotesPath
    )
    Invoke-CcodGitHubDraftReleaseCore -Mode $Mode -Tag $Tag -AssetDirectory $AssetDirectory -EvidenceDirectory $EvidenceDirectory -NotesPath $NotesPath
}

Export-ModuleMember -Function Invoke-CcodGitHubDraftRelease
