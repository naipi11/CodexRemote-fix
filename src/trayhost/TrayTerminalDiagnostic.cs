using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using Microsoft.Win32.SafeHandles;

internal sealed class TrayTerminalDiagnostic
{
    internal TrayCommand Command { get; private set; }
    internal ulong Revision { get; private set; }
    internal TrayActionResultStatus Status { get; private set; }
    internal string Code { get; private set; }

    internal TrayTerminalDiagnostic(TrayCommand command, ulong revision, TrayActionResultStatus status, string errorCode)
    {
        if (!TrayCommandPolicy.IsWireCommand(command) || revision == 0UL || status == TrayActionResultStatus.Accepted || !Enum.IsDefined(typeof(TrayActionResultStatus), status)) { throw new ArgumentException("terminal diagnostic is invalid"); }
        string code = status == TrayActionResultStatus.Completed ? "CCOD_TRAY_ACTION_COMPLETED" : errorCode;
        if (!TrayCommandPolicy.IsCanonicalErrorCode(code)) { code = "CCOD_TRAY_ACTION_FAILED"; }
        Command = command; Revision = revision; Status = status; Code = code;
    }
}

internal sealed class TrayTerminalDiagnosticStore : IDisposable
{
    private sealed class ReceiptPaths
    {
        internal string LocalRoot;
        internal string Product;
        internal string Logs;
        internal string Leaf;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeFileTime
    {
        internal uint Low;
        internal uint High;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ByHandleFileInformation
    {
        internal uint FileAttributes;
        internal NativeFileTime CreationTime;
        internal NativeFileTime LastAccessTime;
        internal NativeFileTime LastWriteTime;
        internal uint VolumeSerialNumber;
        internal uint FileSizeHigh;
        internal uint FileSizeLow;
        internal uint NumberOfLinks;
        internal uint FileIndexHigh;
        internal uint FileIndexLow;
    }

    internal const long MaximumBytes = 64L * 1024L;
    private const uint GenericRead = 0x80000000U;
    private const uint GenericWrite = 0x40000000U;
    private const uint ReadControl = 0x00020000U;
    private const uint FileListDirectory = 0x00000001U;
    private const uint FileReadAttributes = 0x00000080U;
    private const uint FileShareRead = 0x00000001U;
    private const uint FileShareWrite = 0x00000002U;
    private const uint OpenExisting = 3U;
    private const uint OpenAlways = 4U;
    private const uint FileAttributeDirectory = 0x00000010U;
    private const uint FileAttributeDevice = 0x00000040U;
    private const uint FileAttributeReparsePoint = 0x00000400U;
    private const uint FileFlagWriteThrough = 0x80000000U;
    private const uint FileFlagBackupSemantics = 0x02000000U;
    private const uint FileFlagOpenReparsePoint = 0x00200000U;
    private const uint FileTypeDisk = 1U;
    private const uint SecurityInformationOwner = 0x00000001U;
    private const uint SecurityInformationDacl = 0x00000004U;
    private const uint SeFileObject = 1U;
    private const int FullControlAccessMask = 0x001F01FF;
    private readonly object _gate = new object();
    private bool _disposed;

    internal TrayTerminalDiagnosticStore()
    {
    }

#if TRAYHOST_SELF_TEST
    private readonly string _testLocalRoot;
    private readonly Action _testDirectoryChainOpened;
    private readonly Action _testLeafValidated;

    private TrayTerminalDiagnosticStore(string testLocalRoot, Action directoryChainOpened, Action leafValidated)
    {
        _testLocalRoot = testLocalRoot;
        _testDirectoryChainOpened = directoryChainOpened;
        _testLeafValidated = leafValidated;
    }

    internal static TrayTerminalDiagnosticStore CreateForTesting(string localRoot, Action directoryChainOpened, Action leafValidated)
    {
        return new TrayTerminalDiagnosticStore(localRoot, directoryChainOpened, leafValidated);
    }
#endif

    internal static bool TryGetDefaultPath(out string path)
    {
        path = null;
        try
        {
            ReceiptPaths paths;
            if (!TryBuildPaths(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), out paths)) { return false; }
            path = paths.Leaf;
            return true;
        }
        catch { path = null; return false; }
    }

    internal bool TryAppendDurably(TrayTerminalDiagnostic record)
    {
        if (record == null) { return false; }
        byte[] bytes;
        try
        {
            string line = "command=" + record.Command.ToString() + " revision=" + record.Revision.ToString(System.Globalization.CultureInfo.InvariantCulture) + " status=" + record.Status.ToString() + " code=" + record.Code + Environment.NewLine;
            bytes = new UTF8Encoding(false).GetBytes(line);
            if (bytes.LongLength > MaximumBytes) { return false; }
        }
        catch { return false; }

        lock (_gate)
        {
            if (_disposed) { return false; }
            try
            {
                ReceiptPaths paths;
                if (!TryGetPaths(out paths)) { return false; }
                return TryAppendThroughValidatedHandles(paths, bytes);
            }
            catch { return false; }
        }
    }

    public void Dispose()
    {
        lock (_gate) { _disposed = true; }
    }

    private bool TryGetPaths(out ReceiptPaths paths)
    {
#if TRAYHOST_SELF_TEST
        if (_testLocalRoot != null) { return TryBuildPaths(_testLocalRoot, out paths); }
#endif
        return TryBuildPaths(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), out paths);
    }

    private bool TryAppendThroughValidatedHandles(ReceiptPaths paths, byte[] bytes)
    {
        using (SafeFileHandle local = OpenDirectory(paths.LocalRoot))
        {
            if (!IsExpectedDirectory(local, paths.LocalRoot, false)) { return false; }
            if (!TryCreateChildDirectory(paths.Product)) { return false; }
            using (SafeFileHandle product = OpenDirectory(paths.Product))
            {
                if (!IsExpectedDirectory(product, paths.Product, true)) { return false; }
                if (!TryCreateChildDirectory(paths.Logs)) { return false; }
                using (SafeFileHandle logs = OpenDirectory(paths.Logs))
                {
                    if (!IsExpectedDirectory(logs, paths.Logs, true)) { return false; }
#if TRAYHOST_SELF_TEST
                    if (_testDirectoryChainOpened != null) { _testDirectoryChainOpened(); }
#endif
                    using (SafeFileHandle leaf = CreateFileW(paths.Leaf, GenericRead | GenericWrite | ReadControl, FileShareRead, IntPtr.Zero, OpenAlways, FileFlagOpenReparsePoint | FileFlagWriteThrough, IntPtr.Zero))
                    {
                        if (!IsExpectedLeaf(leaf, paths.Leaf)) { return false; }
#if TRAYHOST_SELF_TEST
                        if (_testLeafValidated != null) { _testLeafValidated(); }
#endif
                        using (FileStream stream = new FileStream(leaf, FileAccess.ReadWrite, 4096, false))
                        {
                            long length = stream.Length;
                            if (length > MaximumBytes || length > MaximumBytes - bytes.LongLength)
                            {
                                stream.SetLength(0L);
                                stream.Position = 0L;
                            }
                            else { stream.Position = length; }
                            stream.Write(bytes, 0, bytes.Length);
                            stream.Flush(true);
                            return true;
                        }
                    }
                }
            }
        }
    }

    private static bool TryBuildPaths(string localRoot, out ReceiptPaths paths)
    {
        paths = null;
        if (String.IsNullOrEmpty(localRoot) || !Path.IsPathRooted(localRoot) || localRoot.StartsWith("\\\\?\\", StringComparison.Ordinal) || localRoot.StartsWith("\\\\.\\", StringComparison.Ordinal)) { return false; }
        string canonicalRoot = NormalizePath(localRoot);
        if (String.IsNullOrEmpty(canonicalRoot)) { return false; }
        string product = NormalizePath(Path.Combine(canonicalRoot, "CodexControlOtherDevices"));
        string logs = NormalizePath(Path.Combine(product, "logs"));
        string leaf = NormalizePath(Path.Combine(logs, "trayhost-actions.log"));
        if (String.IsNullOrEmpty(product) || String.IsNullOrEmpty(logs) || String.IsNullOrEmpty(leaf)) { return false; }
        if (!String.Equals(Path.GetDirectoryName(product), canonicalRoot, StringComparison.OrdinalIgnoreCase) || !String.Equals(Path.GetDirectoryName(logs), product, StringComparison.OrdinalIgnoreCase) || !String.Equals(Path.GetDirectoryName(leaf), logs, StringComparison.OrdinalIgnoreCase)) { return false; }
        if (!String.Equals(Path.GetFileName(product), "CodexControlOtherDevices", StringComparison.Ordinal) || !String.Equals(Path.GetFileName(logs), "logs", StringComparison.Ordinal) || !String.Equals(Path.GetFileName(leaf), "trayhost-actions.log", StringComparison.Ordinal) || Path.GetFileName(leaf).IndexOf(':') >= 0) { return false; }
        paths = new ReceiptPaths { LocalRoot = canonicalRoot, Product = product, Logs = logs, Leaf = leaf };
        return true;
    }

    private static string NormalizePath(string path)
    {
        try
        {
            string full = Path.GetFullPath(path);
            string root = Path.GetPathRoot(full);
            while (!String.IsNullOrEmpty(root) && full.Length > root.Length && (full.EndsWith("\\", StringComparison.Ordinal) || full.EndsWith("/", StringComparison.Ordinal))) { full = full.Substring(0, full.Length - 1); }
            return full;
        }
        catch { return null; }
    }

    private static bool TryCreateChildDirectory(string path)
    {
        try
        {
            if (Directory.Exists(path)) { return true; }
            Directory.CreateDirectory(path, CreatePrivateDirectorySecurity());
            return true;
        }
        catch { return false; }
    }

    private static DirectorySecurity CreatePrivateDirectorySecurity()
    {
        SecurityIdentifier user = GetCurrentUserSid();
        if (user == null) { throw new InvalidOperationException("current user SID is unavailable"); }
        DirectorySecurity security = new DirectorySecurity();
        security.SetOwner(user);
        security.SetAccessRuleProtection(true, false);
        InheritanceFlags inheritance = InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit;
        SecurityIdentifier[] identities = new SecurityIdentifier[] {
            user,
            new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null),
            new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null)
        };
        for (int i = 0; i < identities.Length; i++)
        {
            security.AddAccessRule(new FileSystemAccessRule(identities[i], FileSystemRights.FullControl, inheritance, PropagationFlags.None, AccessControlType.Allow));
        }
        return security;
    }

    private static SecurityIdentifier GetCurrentUserSid()
    {
        try
        {
            using (WindowsIdentity identity = WindowsIdentity.GetCurrent())
            {
                return identity == null || identity.User == null ? null : new SecurityIdentifier(identity.User.Value);
            }
        }
        catch { return null; }
    }

    private static SafeFileHandle OpenDirectory(string path)
    {
        return CreateFileW(path, FileListDirectory | FileReadAttributes | ReadControl, FileShareRead | FileShareWrite, IntPtr.Zero, OpenExisting, FileFlagBackupSemantics | FileFlagOpenReparsePoint, IntPtr.Zero);
    }

    private static bool IsExpectedDirectory(SafeFileHandle handle, string expectedPath, bool requirePrivateSecurity)
    {
        ByHandleFileInformation information;
        if (handle == null || handle.IsInvalid || GetFileType(handle) != FileTypeDisk || !GetFileInformationByHandle(handle, out information)) { return false; }
        if ((information.FileAttributes & FileAttributeDirectory) == 0U || (information.FileAttributes & (FileAttributeReparsePoint | FileAttributeDevice)) != 0U) { return false; }
        if (!IsExpectedFinalPath(handle, expectedPath)) { return false; }
        return !requirePrivateSecurity || HasPrivateDirectorySecurity(handle);
    }

    private static bool HasPrivateDirectorySecurity(SafeFileHandle handle)
    {
        IntPtr owner; IntPtr group; IntPtr dacl; IntPtr sacl; IntPtr descriptor;
        uint result = GetSecurityInfo(handle, SeFileObject, SecurityInformationOwner | SecurityInformationDacl, out owner, out group, out dacl, out sacl, out descriptor);
        if (result != 0U || descriptor == IntPtr.Zero) { return false; }
        try
        {
            uint length = GetSecurityDescriptorLength(descriptor);
            if (length == 0U || length > 65536U) { return false; }
            byte[] bytes = new byte[checked((int)length)];
            Marshal.Copy(descriptor, bytes, 0, bytes.Length);
            RawSecurityDescriptor security = new RawSecurityDescriptor(bytes, 0);
            SecurityIdentifier user = GetCurrentUserSid();
            if (user == null || security.Owner == null || !String.Equals(security.Owner.Value, user.Value, StringComparison.Ordinal)) { return false; }
            if ((security.ControlFlags & ControlFlags.DiscretionaryAclPresent) == 0 || (security.ControlFlags & ControlFlags.DiscretionaryAclProtected) == 0 || security.DiscretionaryAcl == null || security.DiscretionaryAcl.Count != 3) { return false; }
            HashSet<string> expected = new HashSet<string>(StringComparer.Ordinal) {
                user.Value,
                new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null).Value,
                new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null).Value
            };
            HashSet<string> seen = new HashSet<string>(StringComparer.Ordinal);
            AceFlags inheritance = AceFlags.ContainerInherit | AceFlags.ObjectInherit;
            for (int i = 0; i < security.DiscretionaryAcl.Count; i++)
            {
                CommonAce ace = security.DiscretionaryAcl[i] as CommonAce;
                if (ace == null || ace.IsCallback || ace.AceQualifier != AceQualifier.AccessAllowed || ace.SecurityIdentifier == null || ace.AccessMask != FullControlAccessMask) { return false; }
                if ((ace.AceFlags & inheritance) != inheritance || (ace.AceFlags & ~(inheritance)) != AceFlags.None) { return false; }
                if (!expected.Contains(ace.SecurityIdentifier.Value) || !seen.Add(ace.SecurityIdentifier.Value)) { return false; }
            }
            return seen.Count == expected.Count;
        }
        catch { return false; }
        finally { LocalFree(descriptor); }
    }

    private static bool IsExpectedLeaf(SafeFileHandle handle, string expectedPath)
    {
        ByHandleFileInformation information;
        if (handle == null || handle.IsInvalid || GetFileType(handle) != FileTypeDisk || !GetFileInformationByHandle(handle, out information)) { return false; }
        if ((information.FileAttributes & (FileAttributeDirectory | FileAttributeReparsePoint | FileAttributeDevice)) != 0U || information.NumberOfLinks != 1U) { return false; }
        return IsExpectedFinalPath(handle, expectedPath);
    }

    private static bool IsExpectedFinalPath(SafeFileHandle handle, string expectedPath)
    {
        string actual;
        if (!TryGetFinalPath(handle, out actual)) { return false; }
        return String.Equals(actual, NormalizePath(expectedPath), StringComparison.OrdinalIgnoreCase);
    }

    private static bool TryGetFinalPath(SafeFileHandle handle, out string path)
    {
        path = null;
        StringBuilder buffer = new StringBuilder(512);
        uint length = GetFinalPathNameByHandleW(handle, buffer, (uint)buffer.Capacity, 0U);
        if (length == 0U) { return false; }
        if (length >= (uint)buffer.Capacity)
        {
            if (length > 32767U) { return false; }
            buffer = new StringBuilder(checked((int)length + 1));
            length = GetFinalPathNameByHandleW(handle, buffer, (uint)buffer.Capacity, 0U);
            if (length == 0U || length >= (uint)buffer.Capacity) { return false; }
        }
        string value = buffer.ToString();
        if (value.StartsWith("\\\\?\\UNC\\", StringComparison.OrdinalIgnoreCase)) { value = "\\\\" + value.Substring(8); }
        else if (value.StartsWith("\\\\?\\", StringComparison.Ordinal)) { value = value.Substring(4); }
        path = NormalizePath(value);
        return !String.IsNullOrEmpty(path);
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFileW(string fileName, uint desiredAccess, uint shareMode, IntPtr securityAttributes, uint creationDisposition, uint flagsAndAttributes, IntPtr templateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileInformationByHandle(SafeFileHandle file, out ByHandleFileInformation information);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint GetFileType(SafeFileHandle file);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetFinalPathNameByHandleW(SafeFileHandle file, StringBuilder path, uint pathLength, uint flags);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern uint GetSecurityInfo(SafeFileHandle handle, uint objectType, uint securityInformation, out IntPtr owner, out IntPtr group, out IntPtr dacl, out IntPtr sacl, out IntPtr securityDescriptor);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern uint GetSecurityDescriptorLength(IntPtr securityDescriptor);

    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr memory);
}
