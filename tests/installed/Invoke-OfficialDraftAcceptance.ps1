[CmdletBinding()]
param(
    [string]$Phase,
    [string]$AssetDirectory,
    [string]$PreviousAssetDirectory,
    [string]$EvidenceRoot,
    [string]$DraftId,
    [switch]$AllowMachineMutation,
    [switch]$AllowCodexRestart,
    [switch]$AllowWindowsReboot,
    [string]$TrayOperation,
    [string]$RemoteOperation,
    [string]$ScreenshotPath,
    [string]$RedactedLogPath,
    [string]$ReviewState
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
$modulePath = Join-Path $PSScriptRoot 'OfficialDraftAcceptance.psm1'
function Throw-CcodOfficialDraftWrapperError {
    param([Parameter(Mandatory)][string]$ErrorId,[Parameter(Mandatory)][string]$Message)
    throw [Management.Automation.ErrorRecord]::new(
        [InvalidOperationException]::new($Message),
        $ErrorId,
        [Management.Automation.ErrorCategory]::InvalidArgument,
        $null
    )
}
try {
    $phaseNames = [string[]]@('Preflight','LegacyUpgrade','Uninstall','FreshInstall','PreReboot','PostReboot','ReadyForManualEvidence','TrayEvidence','RemoteEvidence','Complete')
    $phaseMatch = @($phaseNames | Where-Object { $_ -ieq [string]$Phase })
    if ($phaseMatch.Count -ne 1) { Throw-CcodOfficialDraftWrapperError 'CCOD_ACCEPTANCE_PHASE_INVALID' 'The official-draft acceptance phase is unsupported.' }
    $Phase = [string]$phaseMatch[0]
    if ([string]::IsNullOrWhiteSpace($AssetDirectory) -or [string]::IsNullOrWhiteSpace($PreviousAssetDirectory) -or [string]::IsNullOrWhiteSpace($EvidenceRoot)) {
        Throw-CcodOfficialDraftWrapperError 'CCOD_ACCEPTANCE_ARGUMENT_INVALID' 'Required acceptance paths are missing.'
    }
    $trayNames = [string[]]@('About','Language','OpenLogs','Repair')
    if (-not [string]::IsNullOrWhiteSpace($TrayOperation)) {
        $trayMatch = @($trayNames | Where-Object { $_ -ieq [string]$TrayOperation })
        if ($trayMatch.Count -ne 1) { Throw-CcodOfficialDraftWrapperError 'CCOD_ACCEPTANCE_TRAY_OPERATION_INVALID' 'The tray operation is unsupported.' }
        $TrayOperation = [string]$trayMatch[0]
    }
    if (-not [string]::IsNullOrWhiteSpace($RemoteOperation)) {
        if ($RemoteOperation -ine 'SecondDeviceControl') { Throw-CcodOfficialDraftWrapperError 'CCOD_ACCEPTANCE_REMOTE_OPERATION_INVALID' 'The remote operation is unsupported.' }
        $RemoteOperation = 'SecondDeviceControl'
    }
    if (-not [string]::IsNullOrWhiteSpace($ReviewState)) {
        if ($ReviewState -ine 'Reviewed') { Throw-CcodOfficialDraftWrapperError 'CCOD_ACCEPTANCE_REVIEW_STATE_INVALID' 'The manual evidence review state is unsupported.' }
        $ReviewState = 'Reviewed'
    }
    $moduleLease = Open-CcodTrustedImportLease -Path $modulePath -ErrorId 'CCOD_ACCEPTANCE_MODULE_MISSING'
    try {
        $moduleLease.Revalidate()
        Import-Module $modulePath -Force -ErrorAction Stop
        $moduleLease.Revalidate()
    } finally { $moduleLease.Dispose() }
    $invokeParameters = @{
        Phase = $Phase
        AssetDirectory = $AssetDirectory
        PreviousAssetDirectory = $PreviousAssetDirectory
        EvidenceRoot = $EvidenceRoot
        DraftId = $DraftId
        AllowMachineMutation = [bool]$AllowMachineMutation
        AllowCodexRestart = [bool]$AllowCodexRestart
        AllowWindowsReboot = [bool]$AllowWindowsReboot
    }
    if (-not [string]::IsNullOrWhiteSpace($TrayOperation)) { $invokeParameters.TrayOperation = $TrayOperation }
    if (-not [string]::IsNullOrWhiteSpace($RemoteOperation)) { $invokeParameters.RemoteOperation = $RemoteOperation }
    if (-not [string]::IsNullOrWhiteSpace($ScreenshotPath)) { $invokeParameters.ScreenshotPath = $ScreenshotPath }
    if (-not [string]::IsNullOrWhiteSpace($RedactedLogPath)) { $invokeParameters.RedactedLogPath = $RedactedLogPath }
    if (-not [string]::IsNullOrWhiteSpace($ReviewState)) { $invokeParameters.ReviewState = $ReviewState }
    Invoke-CcodOfficialDraftAcceptance @invokeParameters |
        ConvertTo-Json -Depth 16
} catch {
    $errorId = [string]$_.FullyQualifiedErrorId
    if ($errorId -notmatch '^CCOD_ACCEPTANCE_[A-Z0-9_]+\z') { $errorId = 'CCOD_ACCEPTANCE_WRAPPER_FAILED' }
    [Console]::Error.WriteLine($errorId)
    exit 1
}
