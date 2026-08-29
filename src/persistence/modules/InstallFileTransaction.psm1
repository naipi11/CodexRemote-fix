Set-StrictMode -Version Latest

$script:CcodInstallFileTransactionAfterSourceOpen = $null

function Throw-CcodInstallFileError {
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

function Initialize-CcodInstallFileNative {
    if ($null -ne ('CcodInstallFileNative' -as [type])) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

public static class CcodInstallFileNative
{
    private const uint FILE_LIST_DIRECTORY = 0x00000001;
    private const uint FILE_READ_ATTRIBUTES = 0x00000080;
    private const uint DELETE = 0x00010000;
    private const uint SYNCHRONIZE = 0x00100000;
    private const uint GENERIC_READ = 0x80000000;
    private const uint GENERIC_WRITE = 0x40000000;
    private const uint FILE_SHARE_READ = 0x00000001;
    private const uint FILE_SHARE_WRITE = 0x00000002;
    private const uint FILE_SHARE_DELETE = 0x00000004;
    private const uint FILE_OPEN = 0x00000001;
    private const uint FILE_CREATE = 0x00000002;
    private const uint FILE_OPEN_IF = 0x00000003;
    private const uint FILE_DIRECTORY_FILE = 0x00000001;
    private const uint FILE_WRITE_THROUGH = 0x00000002;
    private const uint FILE_SYNCHRONOUS_IO_NONALERT = 0x00000020;
    private const uint FILE_NON_DIRECTORY_FILE = 0x00000040;
    private const uint FILE_OPEN_FOR_BACKUP_INTENT = 0x00004000;
    private const uint FILE_OPEN_REPARSE_POINT = 0x00200000;
    private const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
    private const uint FILE_FLAG_OPEN_REPARSE_POINT = 0x00200000;
    private const uint FILE_FLAG_WRITE_THROUGH = 0x80000000;
    private const uint OPEN_EXISTING = 3;
    private const uint OBJ_CASE_INSENSITIVE = 0x00000040;
    private const uint FILE_ATTRIBUTE_DIRECTORY = 0x00000010;
    private const uint FILE_ATTRIBUTE_REPARSE_POINT = 0x00000400;
    private const int FileRenameInformation = 10;
    private const int FileDispositionInfo = 4;
    private const int FileStreamInfo = 7;
    private const int FileDirectoryInformation = 1;
    private const int STATUS_NO_MORE_FILES = unchecked((int)0x80000006);

    [StructLayout(LayoutKind.Sequential)]
    private struct UNICODE_STRING
    {
        public ushort Length;
        public ushort MaximumLength;
        public IntPtr Buffer;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct OBJECT_ATTRIBUTES
    {
        public int Length;
        public IntPtr RootDirectory;
        public IntPtr ObjectName;
        public uint Attributes;
        public IntPtr SecurityDescriptor;
        public IntPtr SecurityQualityOfService;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IO_STATUS_BLOCK
    {
        public IntPtr Status;
        public UIntPtr Information;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct FILETIME_NATIVE
    {
        public uint Low;
        public uint High;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct BY_HANDLE_FILE_INFORMATION
    {
        public uint FileAttributes;
        public FILETIME_NATIVE CreationTime;
        public FILETIME_NATIVE LastAccessTime;
        public FILETIME_NATIVE LastWriteTime;
        public uint VolumeSerialNumber;
        public uint FileSizeHigh;
        public uint FileSizeLow;
        public uint NumberOfLinks;
        public uint FileIndexHigh;
        public uint FileIndexLow;
    }

    public sealed class OpenResult
    {
        public SafeFileHandle Handle { get; private set; }
        public bool Created { get; private set; }
        public OpenResult(SafeFileHandle handle, bool created) { Handle = handle; Created = created; }
    }

    public sealed class HandleInfo
    {
        public uint Attributes { get; private set; }
        public uint NumberOfLinks { get; private set; }
        public uint VolumeSerialNumber { get; private set; }
        public ulong FileIndex { get; private set; }
        public long Length { get; private set; }
        public bool IsDirectory { get { return (Attributes & FILE_ATTRIBUTE_DIRECTORY) != 0; } }
        public bool IsReparsePoint { get { return (Attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0; } }

        internal HandleInfo(BY_HANDLE_FILE_INFORMATION value)
        {
            Attributes = value.FileAttributes;
            NumberOfLinks = value.NumberOfLinks;
            VolumeSerialNumber = value.VolumeSerialNumber;
            FileIndex = ((ulong)value.FileIndexHigh << 32) | value.FileIndexLow;
            Length = ((long)value.FileSizeHigh << 32) | value.FileSizeLow;
        }
    }

    public sealed class DirectoryEntry
    {
        public string Name { get; private set; }
        public uint Attributes { get; private set; }
        public DirectoryEntry(string name, uint attributes) { Name = name; Attributes = attributes; }
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFileW(string path, uint access, uint share, IntPtr security,
        uint creation, uint flags, IntPtr template);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out BY_HANDLE_FILE_INFORMATION information);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetFinalPathNameByHandleW(SafeFileHandle handle, StringBuilder path, uint length, uint flags);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileInformationByHandleEx(SafeFileHandle handle, int informationClass, IntPtr information, uint size);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetFileInformationByHandle(SafeFileHandle handle, int informationClass, IntPtr information, uint size);

    [DllImport("ntdll.dll")]
    private static extern int NtCreateFile(out IntPtr fileHandle, uint desiredAccess,
        ref OBJECT_ATTRIBUTES objectAttributes, out IO_STATUS_BLOCK ioStatusBlock, IntPtr allocationSize,
        uint fileAttributes, uint shareAccess, uint createDisposition, uint createOptions,
        IntPtr eaBuffer, uint eaLength);

    [DllImport("ntdll.dll")]
    private static extern int NtQueryDirectoryFile(SafeFileHandle fileHandle, IntPtr eventHandle, IntPtr apcRoutine,
        IntPtr apcContext, out IO_STATUS_BLOCK ioStatusBlock, IntPtr fileInformation, uint length,
        int fileInformationClass, [MarshalAs(UnmanagedType.Bool)] bool returnSingleEntry,
        IntPtr fileName, [MarshalAs(UnmanagedType.Bool)] bool restartScan);

    [DllImport("ntdll.dll")]
    private static extern int NtSetInformationFile(SafeFileHandle fileHandle, out IO_STATUS_BLOCK ioStatusBlock,
        IntPtr fileInformation, uint length, int fileInformationClass);

    [DllImport("ntdll.dll")]
    private static extern uint RtlNtStatusToDosError(int status);

    private static void ThrowStatus(int status)
    {
        throw new Win32Exception(unchecked((int)RtlNtStatusToDosError(status)));
    }

    private static OpenResult OpenRelative(SafeFileHandle parent, string name, uint access, uint share,
        uint disposition, uint options)
    {
        if (parent == null || parent.IsInvalid || parent.IsClosed) throw new ArgumentException("Parent pin is invalid", "parent");
        IntPtr nameBuffer = IntPtr.Zero;
        IntPtr unicodePointer = IntPtr.Zero;
        try
        {
            nameBuffer = Marshal.StringToHGlobalUni(name);
            UNICODE_STRING unicode = new UNICODE_STRING();
            unicode.Length = checked((ushort)(name.Length * 2));
            unicode.MaximumLength = checked((ushort)((name.Length + 1) * 2));
            unicode.Buffer = nameBuffer;
            unicodePointer = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(UNICODE_STRING)));
            Marshal.StructureToPtr(unicode, unicodePointer, false);
            OBJECT_ATTRIBUTES attributes = new OBJECT_ATTRIBUTES();
            attributes.Length = Marshal.SizeOf(typeof(OBJECT_ATTRIBUTES));
            attributes.RootDirectory = parent.DangerousGetHandle();
            attributes.ObjectName = unicodePointer;
            attributes.Attributes = OBJ_CASE_INSENSITIVE;
            IO_STATUS_BLOCK statusBlock;
            IntPtr rawHandle;
            int status = NtCreateFile(out rawHandle, access, ref attributes, out statusBlock, IntPtr.Zero,
                0, share, disposition, options | FILE_SYNCHRONOUS_IO_NONALERT | FILE_OPEN_REPARSE_POINT,
                IntPtr.Zero, 0);
            if (status < 0 || rawHandle == IntPtr.Zero || rawHandle == new IntPtr(-1)) ThrowStatus(status);
            return new OpenResult(new SafeFileHandle(rawHandle, true), statusBlock.Information.ToUInt64() == 2UL);
        }
        finally
        {
            if (unicodePointer != IntPtr.Zero) Marshal.FreeHGlobal(unicodePointer);
            if (nameBuffer != IntPtr.Zero) Marshal.FreeHGlobal(nameBuffer);
        }
    }

    public static SafeFileHandle OpenRootDirectory(string path)
    {
        SafeFileHandle handle = CreateFileW(path, FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES | SYNCHRONIZE,
            FILE_SHARE_READ | FILE_SHARE_WRITE, IntPtr.Zero, OPEN_EXISTING,
            FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, IntPtr.Zero);
        if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
        return handle;
    }

    public static OpenResult OpenDirectoryRelative(SafeFileHandle parent, string name, bool createIfMissing)
    {
        return OpenRelative(parent, name, FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES | DELETE | SYNCHRONIZE,
            FILE_SHARE_READ | FILE_SHARE_WRITE, createIfMissing ? FILE_OPEN_IF : FILE_OPEN,
            FILE_DIRECTORY_FILE | FILE_OPEN_FOR_BACKUP_INTENT);
    }

    public static OpenResult CreateTemporaryFileRelative(SafeFileHandle parent, string name)
    {
        return OpenRelative(parent, name, GENERIC_READ | GENERIC_WRITE | DELETE | SYNCHRONIZE,
            FILE_SHARE_READ, FILE_CREATE, FILE_NON_DIRECTORY_FILE | FILE_WRITE_THROUGH);
    }

    public static OpenResult OpenAppendFileRelative(SafeFileHandle parent, string name)
    {
        return OpenRelative(parent, name, GENERIC_READ | GENERIC_WRITE | DELETE | SYNCHRONIZE,
            FILE_SHARE_READ, FILE_OPEN_IF, FILE_NON_DIRECTORY_FILE | FILE_WRITE_THROUGH);
    }

    public static SafeFileHandle OpenIdentityRelative(SafeFileHandle parent, string name)
    {
        return OpenRelative(parent, name, FILE_READ_ATTRIBUTES | SYNCHRONIZE,
            FILE_SHARE_READ | FILE_SHARE_WRITE, FILE_OPEN, FILE_OPEN_FOR_BACKUP_INTENT).Handle;
    }

    public static SafeFileHandle OpenSourceFile(string path)
    {
        SafeFileHandle handle = CreateFileW(path, GENERIC_READ | FILE_READ_ATTRIBUTES | SYNCHRONIZE,
            FILE_SHARE_READ, IntPtr.Zero, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, IntPtr.Zero);
        if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
        return handle;
    }

    public static HandleInfo GetInfo(SafeFileHandle handle)
    {
        BY_HANDLE_FILE_INFORMATION information;
        if (!GetFileInformationByHandle(handle, out information)) throw new Win32Exception(Marshal.GetLastWin32Error());
        return new HandleInfo(information);
    }

    public static string GetFinalPath(SafeFileHandle handle)
    {
        StringBuilder path = new StringBuilder(512);
        uint length = GetFinalPathNameByHandleW(handle, path, (uint)path.Capacity, 0);
        if (length == 0) throw new Win32Exception(Marshal.GetLastWin32Error());
        if (length >= path.Capacity)
        {
            path.Capacity = checked((int)length + 1);
            length = GetFinalPathNameByHandleW(handle, path, (uint)path.Capacity, 0);
            if (length == 0 || length >= path.Capacity) throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        string value = path.ToString();
        if (value.StartsWith(@"\\?\UNC\", StringComparison.OrdinalIgnoreCase)) return @"\\" + value.Substring(8);
        if (value.StartsWith(@"\\?\", StringComparison.OrdinalIgnoreCase)) return value.Substring(4);
        return value;
    }

    public static bool HasOnlyDefaultDataStream(SafeFileHandle handle)
    {
        const int bufferSize = 65536;
        IntPtr buffer = Marshal.AllocHGlobal(bufferSize);
        try
        {
            if (!GetFileInformationByHandleEx(handle, FileStreamInfo, buffer, bufferSize))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            int offset = 0;
            int count = 0;
            while (true)
            {
                uint next = unchecked((uint)Marshal.ReadInt32(buffer, offset));
                uint nameLength = unchecked((uint)Marshal.ReadInt32(buffer, offset + 4));
                if (nameLength > bufferSize - offset - 24) throw new InvalidDataException("Invalid stream information");
                string name = Marshal.PtrToStringUni(IntPtr.Add(buffer, offset + 24), checked((int)nameLength / 2));
                count++;
                if (!String.Equals(name, "::$DATA", StringComparison.OrdinalIgnoreCase)) return false;
                if (next == 0) break;
                if (next > bufferSize - offset) throw new InvalidDataException("Invalid stream information offset");
                offset = checked(offset + (int)next);
            }
            return count == 1;
        }
        finally { Marshal.FreeHGlobal(buffer); }
    }

    public static string[] EnumerateDirectory(SafeFileHandle directory)
    {
        const int bufferSize = 65536;
        IntPtr buffer = Marshal.AllocHGlobal(bufferSize);
        List<string> names = new List<string>();
        bool restart = true;
        try
        {
            while (true)
            {
                IO_STATUS_BLOCK statusBlock;
                int status = NtQueryDirectoryFile(directory, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero,
                    out statusBlock, buffer, bufferSize, FileDirectoryInformation, false, IntPtr.Zero, restart);
                restart = false;
                if (status == STATUS_NO_MORE_FILES) break;
                if (status < 0) ThrowStatus(status);
                int offset = 0;
                while (true)
                {
                    uint next = unchecked((uint)Marshal.ReadInt32(buffer, offset));
                    uint nameLength = unchecked((uint)Marshal.ReadInt32(buffer, offset + 60));
                    if (nameLength > bufferSize - offset - 64) throw new InvalidDataException("Invalid directory information");
                    string name = Marshal.PtrToStringUni(IntPtr.Add(buffer, offset + 64), checked((int)nameLength / 2));
                    if (name != "." && name != "..") names.Add(name);
                    if (next == 0) break;
                    if (next > bufferSize - offset) throw new InvalidDataException("Invalid directory information offset");
                    offset = checked(offset + (int)next);
                }
            }
            return names.ToArray();
        }
        finally { Marshal.FreeHGlobal(buffer); }
    }

    public static int RenameRelative(SafeFileHandle source, SafeFileHandle parent, string destination, bool replaceIfExists)
    {
        byte[] name = Encoding.Unicode.GetBytes(destination);
        int rootDirectoryOffset = IntPtr.Size;
        int fileNameLengthOffset = rootDirectoryOffset + IntPtr.Size;
        int fileNameOffset = fileNameLengthOffset + sizeof(uint);
        int bufferSize = checked(fileNameOffset + name.Length + sizeof(char));
        IntPtr buffer = Marshal.AllocHGlobal(bufferSize);
        try
        {
            for (int index = 0; index < bufferSize; index++) Marshal.WriteByte(buffer, index, 0);
            Marshal.WriteByte(buffer, 0, replaceIfExists ? (byte)1 : (byte)0);
            Marshal.WriteIntPtr(buffer, rootDirectoryOffset, parent.DangerousGetHandle());
            Marshal.WriteInt32(buffer, fileNameLengthOffset, name.Length);
            Marshal.Copy(name, 0, IntPtr.Add(buffer, fileNameOffset), name.Length);
            IO_STATUS_BLOCK statusBlock;
            int status = NtSetInformationFile(source, out statusBlock, buffer, (uint)bufferSize, FileRenameInformation);
            return status >= 0 ? 0 : unchecked((int)RtlNtStatusToDosError(status));
        }
        finally { Marshal.FreeHGlobal(buffer); }
    }

    public static int MarkDelete(SafeFileHandle handle)
    {
        IntPtr buffer = Marshal.AllocHGlobal(1);
        try
        {
            Marshal.WriteByte(buffer, 1);
            return SetFileInformationByHandle(handle, FileDispositionInfo, buffer, 1)
                ? 0 : Marshal.GetLastWin32Error();
        }
        finally { Marshal.FreeHGlobal(buffer); }
    }
}
'@
}

function Assert-CcodInstallLeafName {
    param([Parameter(Mandatory)][string]$Leaf)
    if ([string]::IsNullOrWhiteSpace($Leaf) -or $Leaf.Length -gt 160 -or
        $Leaf -in @('.','..') -or $Leaf -notmatch '^[A-Za-z0-9._-]+$' -or
        $Leaf.EndsWith('.') -or $Leaf.EndsWith(' ') -or
        $Leaf -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') {
        Throw-CcodInstallFileError 'CCOD_INSTALL_LEAF_INVALID' 'Install transaction leaf must be one safe relative segment' $Leaf
    }
}

function Get-CcodInstallHandleInfo {
    param([Parameter(Mandatory)]$Pin)
    $handle = if ($null -ne $Pin.Stream) { $Pin.Stream.SafeFileHandle } else { $Pin.Handle }
    return [CcodInstallFileNative]::GetInfo($handle)
}

function Get-CcodInstallPinHandle {
    param([Parameter(Mandatory)]$Pin)
    if ($null -ne $Pin.Stream) { return $Pin.Stream.SafeFileHandle }
    return $Pin.Handle
}

function Get-CcodInstallIdentity {
    param([Parameter(Mandatory)]$Information)
    return [pscustomobject]@{
        VolumeSerialNumber = [uint32]$Information.VolumeSerialNumber
        FileIndex = [uint64]$Information.FileIndex
        Key = ('{0:x8}:{1:x16}' -f [uint32]$Information.VolumeSerialNumber,[uint64]$Information.FileIndex)
    }
}

function Get-CcodInstallObjectKey {
    param([Parameter(Mandatory)]$ParentDirectory, [Parameter(Mandatory)][string]$Leaf)
    return $ParentDirectory.Identity.Key + '|' + $Leaf.ToLowerInvariant()
}

function Test-CcodInstallSameIdentity {
    param($Expected, $Information)
    return $null -ne $Expected -and
        [uint32]$Expected.VolumeSerialNumber -eq [uint32]$Information.VolumeSerialNumber -and
        [uint64]$Expected.FileIndex -eq [uint64]$Information.FileIndex
}

function Assert-CcodInstallTransaction {
    param([Parameter(Mandatory)]$Transaction)
    if ($null -eq $Transaction -or $Transaction.Kind -cne 'CcodInstallFileTransaction') {
        Throw-CcodInstallFileError 'CCOD_INSTALL_TRANSACTION_INVALID' 'Install file transaction context is invalid' $null
    }
    if ($Transaction.Closed) {
        Throw-CcodInstallFileError 'CCOD_INSTALL_TRANSACTION_CLOSED' 'Install file transaction is already closed' $null
    }
}

function Assert-CcodInstallPin {
    param(
        [Parameter(Mandatory)]$Transaction,
        [Parameter(Mandatory)]$Pin,
        [ValidateSet('Directory','File')][string]$Kind
    )
    Assert-CcodInstallTransaction $Transaction
    if ($null -eq $Pin -or $Pin.TransactionId -cne $Transaction.Id -or $Pin.Closed -or
        (-not [string]::IsNullOrWhiteSpace($Kind) -and $Pin.Kind -cne $Kind)) {
        Throw-CcodInstallFileError 'CCOD_INSTALL_PIN_INVALID' 'Install file pin is invalid for this transaction' $null
    }
    $handle = Get-CcodInstallPinHandle $Pin
    if ($null -eq $handle -or $handle.IsInvalid -or $handle.IsClosed) {
        Throw-CcodInstallFileError 'CCOD_INSTALL_PIN_INVALID' 'Install file pin handle is closed or invalid' $null
    }
}

function Assert-CcodInstallPinCurrent {
    param(
        [Parameter(Mandatory)]$Transaction,
        [Parameter(Mandatory)]$Pin,
        [ValidateSet('Directory','File')][string]$Kind
    )
    Assert-CcodInstallPin -Transaction $Transaction -Pin $Pin -Kind $Kind
    try {
        $information = Get-CcodInstallHandleInfo $Pin
        $actualPath = [IO.Path]::GetFullPath([CcodInstallFileNative]::GetFinalPath((Get-CcodInstallPinHandle $Pin))).TrimEnd('\')
    } catch {
        Throw-CcodInstallFileError 'CCOD_INSTALL_PIN_CHANGED' 'Install file pin can no longer prove its identity' $Pin.Leaf
    }
    $expectedPath = [IO.Path]::GetFullPath([string]$Pin.ExpectedPath).TrimEnd('\')
    if (-not (Test-CcodInstallSameIdentity $Pin.Identity $information) -or
        -not $actualPath.Equals($expectedPath, [StringComparison]::OrdinalIgnoreCase) -or
        $information.IsReparsePoint -or
        ($Kind -ceq 'Directory' -and -not $information.IsDirectory) -or
        ($Kind -ceq 'File' -and $information.IsDirectory)) {
        Throw-CcodInstallFileError 'CCOD_INSTALL_PIN_CHANGED' 'Install file pin identity or final path changed' $Pin.Leaf
    }
    return $information
}

function Assert-CcodInstallPlainFile {
    param([Parameter(Mandatory)]$Information, [Parameter(Mandatory)]$Handle, [Parameter(Mandatory)][string]$Target)
    if ($Information.IsDirectory) {
        Throw-CcodInstallFileError 'CCOD_INSTALL_FILE_TYPE_INVALID' 'Install transaction expected a regular file' $Target
    }
    if ($Information.IsReparsePoint) {
        Throw-CcodInstallFileError 'CCOD_INSTALL_REPARSE_LEAF' 'Install transaction rejects reparse leaves' $Target
    }
    if ([uint32]$Information.NumberOfLinks -ne 1) {
        Throw-CcodInstallFileError 'CCOD_INSTALL_MULTILINK_LEAF' 'Install transaction rejects multi-link leaves' $Target
    }
    try { $defaultStreamOnly = [CcodInstallFileNative]::HasOnlyDefaultDataStream($Handle) }
    catch { Throw-CcodInstallFileError 'CCOD_INSTALL_ADS_LEAF' 'Install transaction could not prove the leaf stream inventory' $Target }
    if (-not $defaultStreamOnly) {
        Throw-CcodInstallFileError 'CCOD_INSTALL_ADS_LEAF' 'Install transaction rejects alternate data streams' $Target
    }
}

function Close-CcodInstallPin {
    param([Parameter(Mandatory)]$Pin)
    if ($Pin.Closed) { return }
    try {
        if ($null -ne $Pin.Stream) { $Pin.Stream.Dispose() }
        elseif ($null -ne $Pin.Handle) { $Pin.Handle.Dispose() }
    } finally { $Pin.Closed = $true }
}

function Open-CcodInstallFileTransaction {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$InstallRoot)

    Initialize-CcodInstallFileNative
    if (-not [IO.Path]::IsPathRooted($InstallRoot)) {
        Throw-CcodInstallFileError 'CCOD_INSTALL_ROOT_INVALID' 'Install root must be absolute' $InstallRoot
    }
    $rootPath = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
    if (-not [IO.Directory]::Exists($rootPath)) {
        Throw-CcodInstallFileError 'CCOD_INSTALL_ROOT_MISSING' 'Pinned install root must already exist' $rootPath
    }
    $handle = $null
    try {
        $handle = [CcodInstallFileNative]::OpenRootDirectory($rootPath)
        $information = [CcodInstallFileNative]::GetInfo($handle)
        $finalPath = [IO.Path]::GetFullPath([CcodInstallFileNative]::GetFinalPath($handle)).TrimEnd('\')
        if (-not $information.IsDirectory -or $information.IsReparsePoint -or
            -not $finalPath.Equals($rootPath, [StringComparison]::OrdinalIgnoreCase)) {
            Throw-CcodInstallFileError 'CCOD_INSTALL_ROOT_INVALID' 'Install root is not one plain directory identity' $rootPath
        }
        $id = [guid]::NewGuid().ToString('D')
        $rootPin = [pscustomobject]@{
            Kind = 'Directory'; TransactionId = $id; Handle = $handle; Stream = $null
            ParentDirectory = $null; Leaf = ''; ExpectedPath = $rootPath
            Identity = Get-CcodInstallIdentity $information; Created = $false; Owned = $false; Closed = $false
        }
        $handle = $null
        $pins = [Collections.Generic.List[object]]::new()
        $pins.Add($rootPin)
        return [pscustomobject]@{
            Kind = 'CcodInstallFileTransaction'; Id = $id; InstallRoot = $rootPath; RootDirectory = $rootPin
            Pins = $pins
            Objects = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
            OwnedObjects = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
            LastSourceOpenAttempt = $null; Closed = $false; Disposition = $null
        }
    } catch {
        if ($null -ne $handle) { $handle.Dispose() }
        throw
    }
}

function Open-CcodInstallPinnedDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Transaction,
        [Parameter(Mandatory)]$ParentDirectory,
        [Parameter(Mandatory)][string]$Leaf,
        [switch]$CreateIfMissing
    )
    Assert-CcodInstallLeafName $Leaf
    [void](Assert-CcodInstallPinCurrent -Transaction $Transaction -Pin $ParentDirectory -Kind Directory)
    $key = Get-CcodInstallObjectKey $ParentDirectory $Leaf
    if ($Transaction.Objects.ContainsKey($key)) {
        $existing = $Transaction.Objects[$key]
        [void](Assert-CcodInstallPinCurrent -Transaction $Transaction -Pin $existing -Kind Directory)
        return $existing
    }
    $result = $null
    try {
        $result = [CcodInstallFileNative]::OpenDirectoryRelative($ParentDirectory.Handle, $Leaf, [bool]$CreateIfMissing)
        $information = [CcodInstallFileNative]::GetInfo($result.Handle)
        if (-not $information.IsDirectory) {
            Throw-CcodInstallFileError 'CCOD_INSTALL_FILE_TYPE_INVALID' 'Pinned install child is not a directory' $Leaf
        }
        if ($information.IsReparsePoint) {
            Throw-CcodInstallFileError 'CCOD_INSTALL_REPARSE_LEAF' 'Pinned install child is a reparse point' $Leaf
        }
        $expectedPath = Join-Path $ParentDirectory.ExpectedPath $Leaf
        $finalPath = [IO.Path]::GetFullPath([CcodInstallFileNative]::GetFinalPath($result.Handle)).TrimEnd('\')
        if (-not $finalPath.Equals([IO.Path]::GetFullPath($expectedPath).TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
            Throw-CcodInstallFileError 'CCOD_INSTALL_PIN_CHANGED' 'Pinned install child final path is unexpected' $Leaf
        }
        $pin = [pscustomobject]@{
            Kind = 'Directory'; TransactionId = $Transaction.Id; Handle = $result.Handle; Stream = $null
            ParentDirectory = $ParentDirectory; Leaf = $Leaf; ExpectedPath = $expectedPath
            Identity = Get-CcodInstallIdentity $information; Created = [bool]$result.Created; Owned = [bool]$result.Created; Closed = $false
        }
        $result = $null
        $Transaction.Pins.Add($pin)
        $Transaction.Objects.Add($key, $pin)
        if ($pin.Owned) { $Transaction.OwnedObjects.Add($key, $pin) }
        return $pin
    } catch {
        if ($null -ne $result) { $result.Handle.Dispose() }
        throw
    }
}

function New-CcodInstallPinnedTemporaryLeaf {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Transaction,
        [Parameter(Mandatory)]$ParentDirectory,
        [Parameter(Mandatory)][string]$Leaf
    )
    Assert-CcodInstallLeafName $Leaf
    [void](Assert-CcodInstallPinCurrent -Transaction $Transaction -Pin $ParentDirectory -Kind Directory)
    $key = Get-CcodInstallObjectKey $ParentDirectory $Leaf
    if ($Transaction.Objects.ContainsKey($key) -or $Transaction.OwnedObjects.ContainsKey($key)) {
        Throw-CcodInstallFileError 'CCOD_INSTALL_TEMPORARY_EXISTS' 'Temporary install leaf is already tracked' $Leaf
    }
    $result = $null
    $stream = $null
    try {
        $result = [CcodInstallFileNative]::CreateTemporaryFileRelative($ParentDirectory.Handle, $Leaf)
        if (-not $result.Created) { Throw-CcodInstallFileError 'CCOD_INSTALL_TEMPORARY_EXISTS' 'Temporary install leaf already exists' $Leaf }
        $stream = [IO.FileStream]::new($result.Handle, [IO.FileAccess]::ReadWrite, 65536, $false)
        $result = $null
        $information = [CcodInstallFileNative]::GetInfo($stream.SafeFileHandle)
        Assert-CcodInstallPlainFile -Information $information -Handle $stream.SafeFileHandle -Target $Leaf
        $pin = [pscustomobject]@{
            Kind = 'File'; TransactionId = $Transaction.Id; Handle = $null; Stream = $stream
            ParentDirectory = $ParentDirectory; Leaf = $Leaf; ExpectedPath = (Join-Path $ParentDirectory.ExpectedPath $Leaf)
            Identity = Get-CcodInstallIdentity $information; Created = $true; Owned = $true; Closed = $false
            Sealed = $false; Length = [int64]0; Sha256 = $null
        }
        $stream = $null
        $Transaction.Pins.Add($pin)
        $Transaction.Objects.Add($key, $pin)
        $Transaction.OwnedObjects.Add($key, $pin)
        return $pin
    } catch {
        if ($null -ne $stream) { $stream.Dispose() }
        if ($null -ne $result) { $result.Handle.Dispose() }
        throw
    }
}

function Get-CcodInstallStreamSha256 {
    param([Parameter(Mandatory)][IO.FileStream]$Stream)
    $position = $Stream.Position
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $Stream.Position = 0
        return [BitConverter]::ToString($sha.ComputeHash($Stream)).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
        $Stream.Position = $position
    }
}

function Copy-CcodInstallSealedFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Transaction,
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)]$DestinationLeaf,
        [Parameter(Mandatory)][ValidateRange(0,[int64]::MaxValue)][int64]$ExpectedLength,
        [Parameter(Mandatory)][string]$ExpectedSha256
    )
    if (-not [IO.Path]::IsPathRooted($SourcePath) -or $ExpectedSha256 -cnotmatch '^[0-9a-f]{64}$') {
        Throw-CcodInstallFileError 'CCOD_INSTALL_SOURCE_INVALID' 'Sealed source contract is invalid' $SourcePath
    }
    $fullSource = [IO.Path]::GetFullPath($SourcePath)
    $sourceTail = if ($fullSource.StartsWith('\\')) { $fullSource } else { $fullSource.Substring([IO.Path]::GetPathRoot($fullSource).Length) }
    if ($sourceTail.Contains(':')) {
        Throw-CcodInstallFileError 'CCOD_INSTALL_ADS_LEAF' 'Sealed source may not name an alternate data stream' $SourcePath
    }
    $destinationInformation = Assert-CcodInstallPinCurrent -Transaction $Transaction -Pin $DestinationLeaf -Kind File
    Assert-CcodInstallPlainFile -Information $destinationInformation -Handle $DestinationLeaf.Stream.SafeFileHandle -Target $DestinationLeaf.Leaf
    if (-not $DestinationLeaf.Owned -or $DestinationLeaf.ParentDirectory.TransactionId -cne $Transaction.Id) {
        Throw-CcodInstallFileError 'CCOD_INSTALL_PIN_INVALID' 'Sealed copy destination is not a transaction-owned leaf' $DestinationLeaf.Leaf
    }

    $sourceHandle = $null
    $sourceStream = $null
    try {
        $sourceHandle = [CcodInstallFileNative]::OpenSourceFile($fullSource)
        $sourceInformation = [CcodInstallFileNative]::GetInfo($sourceHandle)
        Assert-CcodInstallPlainFile -Information $sourceInformation -Handle $sourceHandle -Target $fullSource
        $finalSource = [IO.Path]::GetFullPath([CcodInstallFileNative]::GetFinalPath($sourceHandle))
        if (-not $finalSource.Equals($fullSource, [StringComparison]::OrdinalIgnoreCase)) {
            Throw-CcodInstallFileError 'CCOD_INSTALL_SOURCE_INVALID' 'Sealed source final path is unexpected' $fullSource
        }
        if ($null -ne $script:CcodInstallFileTransactionAfterSourceOpen) {
            $Transaction.LastSourceOpenAttempt = & $script:CcodInstallFileTransactionAfterSourceOpen $fullSource
        }
        $sourceStream = [IO.FileStream]::new($sourceHandle, [IO.FileAccess]::Read, 65536, $false)
        $sourceHandle = $null
        if ([int64]$sourceStream.Length -ne $ExpectedLength) {
            Throw-CcodInstallFileError 'CCOD_INSTALL_SOURCE_MISMATCH' 'Sealed source length does not match the contract' $fullSource
        }
        $sourceSha = Get-CcodInstallStreamSha256 $sourceStream
        if ($sourceSha -cne $ExpectedSha256) {
            Throw-CcodInstallFileError 'CCOD_INSTALL_SOURCE_MISMATCH' 'Sealed source digest does not match the contract' $fullSource
        }
        $sourceStream.Position = 0
        $DestinationLeaf.Stream.Position = 0
        $DestinationLeaf.Stream.SetLength(0)
        $sourceStream.CopyTo($DestinationLeaf.Stream, 65536)
        $DestinationLeaf.Stream.Flush($true)
        $destinationLength = [int64]$DestinationLeaf.Stream.Length
        $destinationSha = Get-CcodInstallStreamSha256 $DestinationLeaf.Stream
        if ($destinationLength -ne $ExpectedLength -or $destinationSha -cne $ExpectedSha256) {
            Throw-CcodInstallFileError 'CCOD_INSTALL_DESTINATION_MISMATCH' 'Pinned destination bytes failed sealed readback' $DestinationLeaf.Leaf
        }
        $afterInformation = Assert-CcodInstallPinCurrent -Transaction $Transaction -Pin $DestinationLeaf -Kind File
        if (-not (Test-CcodInstallSameIdentity $DestinationLeaf.Identity $afterInformation)) {
            Throw-CcodInstallFileError 'CCOD_INSTALL_PIN_CHANGED' 'Pinned destination identity changed during copy' $DestinationLeaf.Leaf
        }
        $DestinationLeaf.Sealed = $true
        $DestinationLeaf.Length = $destinationLength
        $DestinationLeaf.Sha256 = $destinationSha
        return [pscustomobject]@{ Length = $destinationLength; Sha256 = $destinationSha }
    } finally {
        if ($null -ne $sourceStream) { $sourceStream.Dispose() }
        elseif ($null -ne $sourceHandle) { $sourceHandle.Dispose() }
    }
}

function Get-CcodInstallExistingPin {
    param([Parameter(Mandatory)]$Transaction, [Parameter(Mandatory)]$ParentDirectory, [Parameter(Mandatory)][string]$Leaf)
    $key = Get-CcodInstallObjectKey $ParentDirectory $Leaf
    if ($Transaction.Objects.ContainsKey($key)) { return $Transaction.Objects[$key] }
    return $null
}

function Commit-CcodInstallPinnedPromotion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Transaction,
        [Parameter(Mandatory)]$ParentDirectory,
        [Parameter(Mandatory)]$TemporaryLeaf,
        [Parameter(Mandatory)][string]$DestinationLeaf
    )
    Assert-CcodInstallLeafName $DestinationLeaf
    [void](Assert-CcodInstallPinCurrent -Transaction $Transaction -Pin $ParentDirectory -Kind Directory)
    $temporaryInformation = Assert-CcodInstallPinCurrent -Transaction $Transaction -Pin $TemporaryLeaf -Kind File
    Assert-CcodInstallPlainFile -Information $temporaryInformation -Handle $TemporaryLeaf.Stream.SafeFileHandle -Target $TemporaryLeaf.Leaf
    if ($TemporaryLeaf.ParentDirectory.Identity.Key -cne $ParentDirectory.Identity.Key -or -not $TemporaryLeaf.Owned -or -not $TemporaryLeaf.Sealed) {
        Throw-CcodInstallFileError 'CCOD_INSTALL_PROMOTION_INVALID' 'Promotion requires a sealed owned leaf under the pinned parent' $TemporaryLeaf.Leaf
    }
    if ($TemporaryLeaf.Leaf.Equals($DestinationLeaf, [StringComparison]::OrdinalIgnoreCase)) { return $TemporaryLeaf }

    $destinationKey = Get-CcodInstallObjectKey $ParentDirectory $DestinationLeaf
    $existingPin = Get-CcodInstallExistingPin $Transaction $ParentDirectory $DestinationLeaf
    $identityHandle = $null
    $destinationExists = $false
    try {
        if ($null -ne $existingPin) {
            $existingInformation = Assert-CcodInstallPinCurrent -Transaction $Transaction -Pin $existingPin -Kind File
            Assert-CcodInstallPlainFile -Information $existingInformation -Handle (Get-CcodInstallPinHandle $existingPin) -Target $DestinationLeaf
            $destinationExists = $true
        } else {
            try { $identityHandle = [CcodInstallFileNative]::OpenIdentityRelative($ParentDirectory.Handle, $DestinationLeaf) }
            catch [ComponentModel.Win32Exception] {
                if ($_.Exception.NativeErrorCode -notin @(2,3)) { throw }
            }
            if ($null -ne $identityHandle) {
                $existingInformation = [CcodInstallFileNative]::GetInfo($identityHandle)
                if ($existingInformation.IsReparsePoint) {
                    Throw-CcodInstallFileError 'CCOD_INSTALL_REPARSE_LEAF' 'Promotion destination is a reparse leaf' $DestinationLeaf
                }
                Assert-CcodInstallPlainFile -Information $existingInformation -Handle $identityHandle -Target $DestinationLeaf
                $destinationExists = $true
            }
        }
    } finally {
        if ($null -ne $identityHandle) { $identityHandle.Dispose() }
    }

    [void](Assert-CcodInstallPinCurrent -Transaction $Transaction -Pin $ParentDirectory -Kind Directory)
    if ($null -ne $existingPin) {
        Close-CcodInstallPin $existingPin
        [void]$Transaction.Objects.Remove($destinationKey)
        if ($Transaction.OwnedObjects.ContainsKey($destinationKey) -and $Transaction.OwnedObjects[$destinationKey] -eq $existingPin) {
            [void]$Transaction.OwnedObjects.Remove($destinationKey)
        }
    }
    $errorCode = [CcodInstallFileNative]::RenameRelative($TemporaryLeaf.Stream.SafeFileHandle, $ParentDirectory.Handle, $DestinationLeaf, $destinationExists)
    if ($errorCode -ne 0) {
        Throw-CcodInstallFileError 'CCOD_INSTALL_PROMOTION_FAILED' "Pinned promotion failed with Windows error $errorCode" $DestinationLeaf
    }

    $temporaryKey = Get-CcodInstallObjectKey $ParentDirectory $TemporaryLeaf.Leaf
    [void]$Transaction.Objects.Remove($temporaryKey)
    [void]$Transaction.OwnedObjects.Remove($temporaryKey)
    $TemporaryLeaf.Leaf = $DestinationLeaf
    $TemporaryLeaf.ExpectedPath = Join-Path $ParentDirectory.ExpectedPath $DestinationLeaf
    $Transaction.Objects[$destinationKey] = $TemporaryLeaf
    $Transaction.OwnedObjects[$destinationKey] = $TemporaryLeaf
    [void](Assert-CcodInstallPinCurrent -Transaction $Transaction -Pin $TemporaryLeaf -Kind File)
    return $TemporaryLeaf
}

function Write-CcodInstallPinnedBytes {
    param([Parameter(Mandatory)]$Pin, [Parameter(Mandatory)][byte[]]$Bytes)
    $Pin.Stream.Position = 0
    $Pin.Stream.SetLength(0)
    $Pin.Stream.Write($Bytes, 0, $Bytes.Length)
    $Pin.Stream.Flush($true)
    $Pin.Length = [int64]$Bytes.LongLength
    $Pin.Sha256 = Get-CcodInstallStreamSha256 $Pin.Stream
    $Pin.Sealed = $true
}

function Write-CcodInstallPinnedJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Transaction,
        [Parameter(Mandatory)]$ParentDirectory,
        [Parameter(Mandatory)][string]$Leaf,
        [Parameter(Mandatory)]$Value,
        [switch]$Compress
    )
    Assert-CcodInstallLeafName $Leaf
    [void](Assert-CcodInstallPinCurrent -Transaction $Transaction -Pin $ParentDirectory -Kind Directory)
    $json = ($Value | ConvertTo-Json -Depth 32 -Compress:$Compress) + "`n"
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
    $prefix = ('.' + $Leaf + '.')
    if ($prefix.Length -gt 100) { $prefix = '.json.' }
    $temporaryName = $prefix + [guid]::NewGuid().ToString('N') + '.tmp'
    $temporary = New-CcodInstallPinnedTemporaryLeaf -Transaction $Transaction -ParentDirectory $ParentDirectory -Leaf $temporaryName
    Write-CcodInstallPinnedBytes -Pin $temporary -Bytes $bytes
    return Commit-CcodInstallPinnedPromotion -Transaction $Transaction -ParentDirectory $ParentDirectory -TemporaryLeaf $temporary -DestinationLeaf $Leaf
}

function Test-CcodInstallSanitizedValue {
    param($Value, [int]$Depth = 0)
    if ($Depth -gt 8) { return $false }
    if ($null -eq $Value) { return $true }
    if ($Value -is [string]) { return $Value.Length -le 4096 }
    if ($Value -is [bool] -or $Value -is [byte] -or $Value -is [sbyte] -or
        $Value -is [int16] -or $Value -is [uint16] -or $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64] -or $Value -is [single] -or $Value -is [double] -or $Value -is [decimal]) { return $true }
    if ($Value -is [Collections.IDictionary]) {
        foreach ($key in @($Value.Keys)) {
            if ($key -isnot [string] -or $key -cnotmatch '^[A-Za-z0-9_.-]{1,96}$' -or
                -not (Test-CcodInstallSanitizedValue -Value $Value[$key] -Depth ($Depth + 1))) { return $false }
        }
        return $true
    }
    if ($Value -is [pscustomobject]) {
        foreach ($property in @($Value.PSObject.Properties)) {
            if ($property.Name -cnotmatch '^[A-Za-z0-9_.-]{1,96}$' -or
                -not (Test-CcodInstallSanitizedValue -Value $property.Value -Depth ($Depth + 1))) { return $false }
        }
        return $true
    }
    if ($Value -is [Collections.IList]) {
        foreach ($entry in @($Value)) {
            if (-not (Test-CcodInstallSanitizedValue -Value $entry -Depth ($Depth + 1))) { return $false }
        }
        return $true
    }
    return $false
}

function Append-CcodInstallPinnedLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Transaction,
        [Parameter(Mandatory)]$ParentDirectory,
        [Parameter(Mandatory)][string]$Leaf,
        [Parameter(Mandatory)]$Record
    )
    Assert-CcodInstallLeafName $Leaf
    if (($Record -isnot [Collections.IDictionary] -and $Record -isnot [pscustomobject]) -or
        -not (Test-CcodInstallSanitizedValue $Record)) {
        Throw-CcodInstallFileError 'CCOD_INSTALL_LOG_RECORD_INVALID' 'Install log record is not a bounded sanitized object' $null
    }
    [void](Assert-CcodInstallPinCurrent -Transaction $Transaction -Pin $ParentDirectory -Kind Directory)
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($Record | ConvertTo-Json -Depth 8 -Compress) + "`n")
    if ($bytes.LongLength -gt 65536) {
        Throw-CcodInstallFileError 'CCOD_INSTALL_LOG_RECORD_INVALID' 'Install log record exceeds the bounded size' $null
    }
    $key = Get-CcodInstallObjectKey $ParentDirectory $Leaf
    $pin = Get-CcodInstallExistingPin $Transaction $ParentDirectory $Leaf
    if ($null -ne $pin) {
        $information = Assert-CcodInstallPinCurrent -Transaction $Transaction -Pin $pin -Kind File
        Assert-CcodInstallPlainFile -Information $information -Handle $pin.Stream.SafeFileHandle -Target $Leaf
    } else {
        $result = $null
        $stream = $null
        try {
            $result = [CcodInstallFileNative]::OpenAppendFileRelative($ParentDirectory.Handle, $Leaf)
            $stream = [IO.FileStream]::new($result.Handle, [IO.FileAccess]::ReadWrite, 65536, $false)
            $created = [bool]$result.Created
            $result = $null
            $information = [CcodInstallFileNative]::GetInfo($stream.SafeFileHandle)
            Assert-CcodInstallPlainFile -Information $information -Handle $stream.SafeFileHandle -Target $Leaf
            $pin = [pscustomobject]@{
                Kind = 'File'; TransactionId = $Transaction.Id; Handle = $null; Stream = $stream
                ParentDirectory = $ParentDirectory; Leaf = $Leaf; ExpectedPath = (Join-Path $ParentDirectory.ExpectedPath $Leaf)
                Identity = Get-CcodInstallIdentity $information; Created = $created; Owned = $created; Closed = $false
                Sealed = $false; Length = [int64]$information.Length; Sha256 = $null
            }
            $stream = $null
            $Transaction.Pins.Add($pin)
            $Transaction.Objects.Add($key, $pin)
            if ($pin.Owned) { $Transaction.OwnedObjects.Add($key, $pin) }
        } catch {
            if ($null -ne $stream) { $stream.Dispose() }
            if ($null -ne $result) { $result.Handle.Dispose() }
            throw
        }
    }
    [void](Assert-CcodInstallPinCurrent -Transaction $Transaction -Pin $ParentDirectory -Kind Directory)
    [void](Assert-CcodInstallPinCurrent -Transaction $Transaction -Pin $pin -Kind File)
    $pin.Stream.Position = $pin.Stream.Length
    $pin.Stream.Write($bytes, 0, $bytes.Length)
    $pin.Stream.Flush($true)
    $pin.Length = [int64]$pin.Stream.Length
    return $pin
}

function Get-CcodInstallOwnedDeletionPlan {
    param(
        [Parameter(Mandatory)]$Transaction,
        [Parameter(Mandatory)]$DirectoryPin,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$Plan
    )
    [void](Assert-CcodInstallPinCurrent -Transaction $Transaction -Pin $DirectoryPin -Kind Directory)
    foreach ($name in [CcodInstallFileNative]::EnumerateDirectory($DirectoryPin.Handle)) {
        Assert-CcodInstallLeafName $name
        $key = Get-CcodInstallObjectKey $DirectoryPin $name
        $pin = if ($Transaction.Objects.ContainsKey($key)) { $Transaction.Objects[$key] } else { $null }
        if ($null -eq $pin) {
            $probe = $null
            try {
                $probe = [CcodInstallFileNative]::OpenIdentityRelative($DirectoryPin.Handle, $name)
                $probeInformation = [CcodInstallFileNative]::GetInfo($probe)
                if ($probeInformation.IsReparsePoint) {
                    Throw-CcodInstallFileError 'CCOD_INSTALL_REPARSE_LEAF' 'Owned-tree cleanup encountered a reparse leaf' $name
                }
                if (-not $probeInformation.IsDirectory) {
                    Assert-CcodInstallPlainFile -Information $probeInformation -Handle $probe -Target $name
                }
                Throw-CcodInstallFileError 'CCOD_INSTALL_UNKNOWN_LEAF' 'Owned-tree cleanup encountered an unowned leaf' $name
            } finally {
                if ($null -ne $probe) { $probe.Dispose() }
            }
        }
        if (-not $Transaction.OwnedObjects.ContainsKey($key) -or $Transaction.OwnedObjects[$key] -ne $pin) {
            Throw-CcodInstallFileError 'CCOD_INSTALL_UNKNOWN_LEAF' 'Owned-tree cleanup encountered an unowned tracked leaf' $name
        }
        if ($pin.Kind -ceq 'Directory') {
            [void](Assert-CcodInstallPinCurrent -Transaction $Transaction -Pin $pin -Kind Directory)
            Get-CcodInstallOwnedDeletionPlan -Transaction $Transaction -DirectoryPin $pin -Plan $Plan
        } else {
            $information = Assert-CcodInstallPinCurrent -Transaction $Transaction -Pin $pin -Kind File
            Assert-CcodInstallPlainFile -Information $information -Handle $pin.Stream.SafeFileHandle -Target $name
        }
        $Plan.Add($pin)
    }
}

function Remove-CcodInstallOwnedTree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Transaction,
        [Parameter(Mandatory)]$ParentDirectory,
        [Parameter(Mandatory)][string]$Leaf
    )
    Assert-CcodInstallLeafName $Leaf
    [void](Assert-CcodInstallPinCurrent -Transaction $Transaction -Pin $ParentDirectory -Kind Directory)
    $key = Get-CcodInstallObjectKey $ParentDirectory $Leaf
    if (-not $Transaction.OwnedObjects.ContainsKey($key)) {
        Throw-CcodInstallFileError 'CCOD_INSTALL_UNKNOWN_LEAF' 'Owned-tree cleanup target is not transaction-owned' $Leaf
    }
    $target = $Transaction.OwnedObjects[$key]
    [void](Assert-CcodInstallPinCurrent -Transaction $Transaction -Pin $target -Kind Directory)
    $plan = [Collections.Generic.List[object]]::new()
    Get-CcodInstallOwnedDeletionPlan -Transaction $Transaction -DirectoryPin $target -Plan $plan
    $plan.Add($target)

    foreach ($pin in $plan) {
        $pinKey = if ($null -eq $pin.ParentDirectory) { $null } else { Get-CcodInstallObjectKey $pin.ParentDirectory $pin.Leaf }
        $errorCode = [CcodInstallFileNative]::MarkDelete((Get-CcodInstallPinHandle $pin))
        if ($errorCode -ne 0) {
            Throw-CcodInstallFileError 'CCOD_INSTALL_DELETE_FAILED' "Owned-tree handle delete failed with Windows error $errorCode" $pin.Leaf
        }
        Close-CcodInstallPin $pin
        if ($null -ne $pinKey) {
            [void]$Transaction.Objects.Remove($pinKey)
            [void]$Transaction.OwnedObjects.Remove($pinKey)
        }
    }
}

function Close-CcodInstallFileTransaction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Transaction,
        [Parameter(Mandatory)][ValidateSet('Ready','Failed')][string]$Disposition
    )
    if ($null -eq $Transaction -or $Transaction.Kind -cne 'CcodInstallFileTransaction') {
        Throw-CcodInstallFileError 'CCOD_INSTALL_TRANSACTION_INVALID' 'Install file transaction context is invalid' $null
    }
    if ($Transaction.Closed) { return $Transaction }
    for ($index = $Transaction.Pins.Count - 1; $index -ge 0; $index--) {
        Close-CcodInstallPin $Transaction.Pins[$index]
    }
    $Transaction.Disposition = $Disposition
    $Transaction.Closed = $true
    return $Transaction
}

Export-ModuleMember -Function @(
    'Open-CcodInstallFileTransaction',
    'Open-CcodInstallPinnedDirectory',
    'New-CcodInstallPinnedTemporaryLeaf',
    'Copy-CcodInstallSealedFile',
    'Commit-CcodInstallPinnedPromotion',
    'Write-CcodInstallPinnedJson',
    'Append-CcodInstallPinnedLog',
    'Remove-CcodInstallOwnedTree',
    'Close-CcodInstallFileTransaction'
)
