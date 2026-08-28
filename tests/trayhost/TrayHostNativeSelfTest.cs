using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Threading;

internal sealed class FakeTrayPlatform : INativeTrayPlatform
{
    internal readonly List<string> Calls = new List<string>();
    internal bool ForegroundResult = true;
    internal bool ForegroundProof = true;
    internal bool ShowOwnerResult = true;
    internal IntPtr OwnerInputContext = IntPtr.Zero;
    internal uint TrackResult;
    internal bool SawNonzeroIcon;
    internal Action DuringTrack;
    internal int TrackCalls;
    internal readonly List<string> MessageBoxes = new List<string>();
    internal readonly List<string> AppendedText = new List<string>();
    internal readonly List<uint> Commands = new List<uint>();
    internal bool ConfirmExitResult = true;

    public IntPtr CreateOwner() { Calls.Add("CreateOwner"); return new IntPtr(10); }
    public IntPtr AssociateOwnerInputContext(IntPtr owner, IntPtr context) { Calls.Add(context == IntPtr.Zero ? "Associate:null" : "Associate:restore"); return new IntPtr(20); }
    public IntPtr GetOwnerInputContext(IntPtr owner) { Calls.Add("GetContext"); return OwnerInputContext; }
    public bool ReleaseInputContext(IntPtr owner, IntPtr context) { Calls.Add("ReleaseContext"); return true; }
    public IntPtr LoadIcon() { Calls.Add("LoadIcon"); return new IntPtr(40); }
    public bool DestroyIcon(IntPtr icon) { Calls.Add("DestroyIcon"); return true; }
    public bool AddIcon(ref TrayIconData icon) { SawNonzeroIcon = icon.hIcon != IntPtr.Zero; Calls.Add("NIM_ADD"); return true; }
    public bool SetIconVersion(ref TrayIconData icon) { Calls.Add("NIM_SETVERSION"); return true; }
    public bool DeleteIcon(ref TrayIconData icon) { Calls.Add("NIM_DELETE"); return true; }
    public IntPtr CreatePopupMenu() { Calls.Add("CreateMenu"); return new IntPtr(30); }
    public IntPtr CreateSubMenu() { return new IntPtr(31); }
    public bool AppendMenu(IntPtr menu, uint flags, UIntPtr command, string text) { Calls.Add("Append:" + text); if(menu==new IntPtr(30) && !String.IsNullOrEmpty(text)){AppendedText.Add(text);if(command != UIntPtr.Zero){Commands.Add((uint)command.ToUInt64());}} return true; }
    public bool AppendSubMenu(IntPtr menu, IntPtr child, string text) { Calls.Add("SubMenu:" + text); if(!String.IsNullOrEmpty(text)){AppendedText.Add(text);} return true; }
    public bool ShowOwner(IntPtr owner) { Calls.Add("ShowOwner"); return ShowOwnerResult; }
    public bool HideOwner(IntPtr owner) { Calls.Add("HideOwner"); return true; }
    public bool SetForegroundWindow(IntPtr owner) { Calls.Add("SetForeground"); return ForegroundResult; }
    public IntPtr GetForegroundWindow() { Calls.Add("GetForeground"); return ForegroundProof ? new IntPtr(10) : new IntPtr(11); }
    public uint TrackPopupMenuEx(IntPtr menu, uint flags, int x, int y, IntPtr owner, IntPtr parameters) { Calls.Add("Track"); TrackCalls++; if (DuringTrack != null) { DuringTrack(); } return TrackResult; }
    public bool PostMessage(IntPtr owner, uint message, UIntPtr wParam, IntPtr lParam) { Calls.Add("WM_NULL"); return true; }
    public bool SetNotificationFocus(ref TrayIconData icon) { Calls.Add("NIM_SETFOCUS"); return true; }
    public bool ShowMessageBox(IntPtr owner, string text, string caption) { MessageBoxes.Add(caption + "|" + text); Calls.Add("MessageBox"); return true; }
    public bool ConfirmExit(IntPtr owner, string text, string caption) { MessageBoxes.Add(caption + "|" + text); Calls.Add("ConfirmExit"); return ConfirmExitResult; }
    public bool DestroyMenu(IntPtr menu) { Calls.Add("DestroyMenu"); return true; }
    public bool EndMenu() { Calls.Add("EndMenu"); return true; }
    public bool DestroyOwner(IntPtr owner) { Calls.Add("DestroyOwner"); return true; }
}

internal static class TrayHostNativeSelfTest
{
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CreateHardLinkW(string fileName, string existingFileName, IntPtr securityAttributes);

    private static void AssertTrue(bool value, string message) { if (!value) { throw new InvalidOperationException(message); } }
    private static void AssertEqual(string expected, string actual, string message) { if (!String.Equals(expected, actual, StringComparison.Ordinal)) { throw new InvalidOperationException(message + " expected=[" + expected + "] actual=[" + actual + "]"); } }

    private static string ProductPath(string root)
    {
        return Path.Combine(root, "CodexControlOtherDevices");
    }

    private static string LogsPath(string root)
    {
        return Path.Combine(ProductPath(root), "logs");
    }

    private static string ReceiptDirectoryPath(string root)
    {
        return Path.Combine(LogsPath(root), "tray-receipts");
    }

    private static string ReceiptPath(string root)
    {
        return Path.Combine(ReceiptDirectoryPath(root), "trayhost-actions.log");
    }

    private static string LegacyReceiptPath(string root)
    {
        return Path.Combine(LogsPath(root), "trayhost-actions.log");
    }

    private static void CreateCompatibilityParents(string root)
    {
        Directory.CreateDirectory(LogsPath(root));
    }

    private static void AssertPrivateReceiptDirectory(string path)
    {
        DirectorySecurity security = Directory.GetAccessControl(path);
        SecurityIdentifier owner = security.GetOwner(typeof(SecurityIdentifier)) as SecurityIdentifier;
        SecurityIdentifier current;
        using (WindowsIdentity identity = WindowsIdentity.GetCurrent()) { current = identity.User; }
        AssertTrue(security.AreAccessRulesProtected && owner != null && current != null && String.Equals(owner.Value, current.Value, StringComparison.Ordinal), "receipt child has a protected current-user owner/DACL");
        HashSet<string> expected = new HashSet<string>(StringComparer.Ordinal) {
            current.Value,
            new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null).Value,
            new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null).Value
        };
        HashSet<string> seen = new HashSet<string>(StringComparer.Ordinal);
        AuthorizationRuleCollection rules = security.GetAccessRules(true, false, typeof(SecurityIdentifier));
        AssertTrue(rules.Count == 3, "receipt child DACL contains exactly three explicit rules");
        foreach (FileSystemAccessRule rule in rules)
        {
            SecurityIdentifier sid = rule.IdentityReference as SecurityIdentifier;
            AssertTrue(sid != null && expected.Contains(sid.Value) && seen.Add(sid.Value), "receipt child DACL contains only current-user, SYSTEM, and Administrators rules");
            AssertTrue(rule.AccessControlType == AccessControlType.Allow && rule.FileSystemRights == FileSystemRights.FullControl, "receipt child principals receive exact full control");
            AssertTrue(rule.InheritanceFlags == (InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit) && rule.PropagationFlags == PropagationFlags.None, "receipt child private rules inherit to its fixed leaf");
        }
        AssertTrue(seen.Count == expected.Count, "receipt child DACL proves every required principal");
    }

    private static TrayTerminalDiagnosticStore TestStore(string root, Action directoryChainOpened, Action leafValidated)
    {
        return TrayTerminalDiagnosticStore.CreateForTesting(root, directoryChainOpened, leafValidated);
    }

    private static void CreateJunction(string link, string target)
    {
        ProcessStartInfo info = new ProcessStartInfo {
            FileName = Environment.GetEnvironmentVariable("ComSpec"),
            Arguments = "/d /c mklink /J \"" + link + "\" \"" + target + "\"",
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true
        };
        using (Process process = Process.Start(info))
        {
            process.WaitForExit();
            AssertTrue(process.ExitCode == 0, "test junction is created: " + process.StandardError.ReadToEnd());
        }
    }

    private static void DeleteJunction(string path)
    {
        try { if (Directory.Exists(path)) { Directory.Delete(path); } } catch { }
    }

    private static byte[] ReceiptBytes(TrayCommand command, ulong revision, TrayActionResultStatus status, string code)
    {
        string line = "command=" + command.ToString() + " revision=" + revision.ToString(System.Globalization.CultureInfo.InvariantCulture) + " status=" + status.ToString() + " code=" + code + Environment.NewLine;
        return new UTF8Encoding(false).GetBytes(line);
    }

    private static PresentationSnapshot Snapshot(ulong revision)
    {
        return SnapshotV2(revision);
    }

    private static PresentationSnapshot SnapshotV2(ulong revision)
    {
        string[] strings = new string[] {
            "CodexRemote-fix 2.5.21", "Connection: Connected", "Protection: Running", "Check and repair remote connection",
            "Language / 语言", "Follow system (English)", "中文", "English", "Open logs", "About", "Exit",
            "About", "CodexRemote-fix | Version 2.5.21", "Exit CodexRemote-fix?", "Remote control will stop.", "Action failed"
        };
        return new PresentationSnapshot(revision, TrayColor.Green, ConnectionState.Connected, ProtectionState.Running, LanguageMode.English,
            PresentationFlags.LanguageEnabled | PresentationFlags.OpenLogsEnabled | PresentationFlags.AboutEnabled | PresentationFlags.ExitEnabled, strings);
    }

    private static TrayWindow NewWindow(FakeTrayPlatform platform)
    {
        TrayWindow window = new TrayWindow(platform);
        window.Create(Snapshot(1));
        return window;
    }

    private static void TestNativeOrderAndCancel()
    {
        FakeTrayPlatform platform = new FakeTrayPlatform();
        TrayWindow window = NewWindow(platform);
        platform.TrackResult = 0;
        AssertTrue(window.HandleContextMenu(new TrayPoint(10, 20)) == 0, "cancel returns zero");
        AssertTrue(platform.SawNonzeroIcon, "NIM_ADD receives a valid HICON");
        AssertTrue(platform.Calls.Contains("ShowOwner") && platform.Calls.Contains("Track") && platform.Calls.Contains("NIM_SETFOCUS") && platform.Calls.Contains("DestroyMenu"), "native menu preserves owner foreground focus and cleanup lifecycle");
        window.Dispose();
    }

    private static void TestForegroundFailureFallsBackToNativeMenu()
    {
        FakeTrayPlatform platform = new FakeTrayPlatform();
        platform.ForegroundResult = false;
        TrayWindow window = NewWindow(platform);
        window.HandleContextMenu(new TrayPoint(0, 0));
        AssertTrue(platform.TrackCalls == 1, "foreground failure still tracks a native menu fallback");
        window.Dispose();
    }

    private static void TestOwnerShowFailureNeverTracks()
    {
        FakeTrayPlatform platform = new FakeTrayPlatform();
        platform.ShowOwnerResult = false;
        TrayWindow window = NewWindow(platform);
        window.HandleContextMenu(new TrayPoint(0, 0));
        AssertTrue(platform.TrackCalls == 0, "owner show failure never tracks a menu");
        window.Dispose();
    }

    private static void TestReentryAndPendingSnapshot()
    {
        FakeTrayPlatform platform = new FakeTrayPlatform();
        TrayWindow window = NewWindow(platform);
        platform.DuringTrack = delegate { AssertTrue(!window.HandleContextMenu(new TrayPoint(0, 0)).HasValue, "reentry returns no command"); window.Apply(Snapshot(2)); };
        platform.TrackResult = 0;
        window.HandleContextMenu(new TrayPoint(0, 0));
        AssertTrue(platform.TrackCalls == 1 && window.CurrentRevision == 2UL, "reentry is ignored and pending snapshot applies after close");
        window.Dispose();
    }

    private static void TestStalePresentationIsNotReportedAsDisplayed()
    {
        FakeTrayPlatform platform = new FakeTrayPlatform(); TrayWindow window = NewWindow(platform);
        AssertTrue(window.Apply(Snapshot(2)), "newer presentation is displayed");
        AssertTrue(!window.Apply(Snapshot(1)), "older presentation is rejected instead of being reported as displayed");
        AssertTrue(window.CurrentRevision == 2UL, "stale presentation cannot roll back the displayed revision");
        window.Dispose();
    }

    private static void TestMenuRevisionGateHoldsNewPresentationUntilTheDisplayedActionIsSelected()
    {
        FakeTrayPlatform platform = new FakeTrayPlatform();
        HostTransport transport = new HostTransport();
        TrayWindow window = new TrayWindow(platform, transport.SetMenuOpen);
        window.Create(Snapshot(1));
        ulong selectedRevision = 0UL;
        window.CommandSelected += delegate(TrayCommand command, ulong revision) { selectedRevision = revision; };
        platform.DuringTrack = delegate
        {
            AssertTrue(window.MenuOpen, "native menu reports open before nested message work can apply a presentation");
            AssertTrue(transport.TryAcceptPresentation(Snapshot(2)), "new presentation reaches the real host transport while the menu is open");
            PresentationSnapshot early;
            AssertTrue(!transport.TryTakePresentation(out early), "menu gate prevents acknowledging a presentation that is not displayed yet");
        };
        platform.TrackResult = (uint)TrayCommand.OpenLogs;
        window.HandleContextMenu(new TrayPoint(0, 0));
        AssertTrue(selectedRevision == 1UL, "selected action is bound to the revision actually displayed by the native menu");
        PresentationSnapshot afterClose;
        AssertTrue(transport.TryTakePresentation(out afterClose) && afterClose.Revision == 2UL, "new presentation becomes eligible only after the displayed menu closes");
        window.Dispose(); transport.Dispose();
    }

    private static void TestSelectedCommandAndTaskbarRestore()
    {
        FakeTrayPlatform platform = new FakeTrayPlatform();
        TrayWindow window = NewWindow(platform);
        TrayCommand selected = TrayCommand.None;
        window.CommandSelected += delegate(TrayCommand command, ulong revision) { selected = command; AssertTrue(revision == 1UL, "action revision is current"); };
        platform.TrackResult = (uint)TrayCommand.OpenLogs;
        window.HandleContextMenu(new TrayPoint(0, 0));
        AssertTrue(selected == TrayCommand.OpenLogs, "selected command is emitted once");
        platform.Calls.Clear();
        window.ReAddAfterTaskbarCreated();
        AssertEqual("NIM_ADD|NIM_SETVERSION", String.Join("|", platform.Calls.ToArray()), "Explorer restore re-adds and versions the icon");
        window.Dispose();
    }

    private static void TestAboutCommandDefersProofToSupervisor()
    {
        FakeTrayPlatform platform = new FakeTrayPlatform();
        TrayWindow window = NewWindow(platform);
        TrayCommand selected = TrayCommand.None;
        window.CommandSelected += delegate(TrayCommand command, ulong revision) { selected = command; };
        platform.TrackResult = (uint)TrayCommand.ShowAbout;
        window.HandleContextMenu(new TrayPoint(0, 0));
        AssertTrue(selected == TrayCommand.ShowAbout, "about command is delegated for Supervisor manifest proof");
        AssertTrue(platform.MessageBoxes.Count == 0, "about does not display an unverified local version");
        window.Dispose();
    }

    private static void TestSimplifiedMenuAndExitConfirmation()
    {
        FakeTrayPlatform platform = new FakeTrayPlatform();
        TrayWindow window = new TrayWindow(platform); window.Create(SnapshotV2(1));
        platform.TrackResult = 0; window.HandleContextMenu(new TrayPoint(0, 0));
        AssertEqual("CodexRemote-fix 2.5.21|Connection: Connected|Protection: Running|Check and repair remote connection|Language / 语言|Open logs|About|Exit", String.Join("|", platform.AppendedText.ToArray()), "menu contains only the approved information architecture");
        AssertTrue(!platform.AppendedText.Contains("Allow compatible update trials"), "candidate toggle is removed");
        AssertTrue(!platform.Commands.Contains(1009U), "tray uninstall command is removed");
        TrayCommand selected = TrayCommand.None; window.CommandSelected += delegate(TrayCommand command, ulong revision) { selected = command; };
        platform.ConfirmExitResult = false; platform.TrackResult = (uint)TrayCommand.Exit; window.HandleContextMenu(new TrayPoint(0, 0));
        AssertTrue(selected == TrayCommand.None, "Exit is not emitted when native confirmation is declined");
        platform.ConfirmExitResult = true; window.HandleContextMenu(new TrayPoint(0, 0));
        AssertTrue(selected == TrayCommand.Exit, "Exit is emitted only after native confirmation");
        window.Dispose();
    }

    private static void TestVerifiedAboutUsesTheAcknowledgedSnapshotVersion()
    {
        FakeTrayPlatform platform = new FakeTrayPlatform(); TrayWindow window = new TrayWindow(platform); window.Create(SnapshotV2(1));
        window.ShowAbout();
        AssertTrue(platform.MessageBoxes.Count == 1, "verified About shows exactly one native message box");
        AssertEqual("About|CodexRemote-fix | Version 2.5.21", platform.MessageBoxes[0], "verified About displays the version from the acknowledged snapshot");
        window.Dispose();
    }

    private static void TestActionFailureUsesTheAcknowledgedSnapshotStrings()
    {
        FakeTrayPlatform platform = new FakeTrayPlatform(); TrayWindow window = new TrayWindow(platform); window.Create(SnapshotV2(1));
        window.ShowActionFailed();
        AssertTrue(platform.MessageBoxes.Count == 1, "a failed correlated action shows exactly one native message box");
        AssertEqual("CodexRemote-fix 2.5.21|Action failed", platform.MessageBoxes[0], "action failure uses the localized strings from the acknowledged snapshot");
        window.Dispose();
    }

    private static void TestTerminalDiagnosticLogIsSanitizedAndReportsPersistence()
    {
        string root = Path.Combine(Path.GetTempPath(), "ccod-tray-terminal-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        CreateCompatibilityParents(root);
        string path = ReceiptPath(root);
        try
        {
            TrayTerminalDiagnostic record = new TrayTerminalDiagnostic(TrayCommand.OpenLogs, 23UL, TrayActionResultStatus.Rejected, "CCOD_TRAY_ACTION_STALE");
            using (TrayTerminalDiagnosticStore store = TestStore(root, null, null))
            {
                AssertTrue(store.TryAppendDurably(record), "terminal diagnostic append reports durable success");
            }
            byte[] expected = ReceiptBytes(TrayCommand.OpenLogs, 23UL, TrayActionResultStatus.Rejected, "CCOD_TRAY_ACTION_STALE");
            AssertTrue(Convert.ToBase64String(expected) == Convert.ToBase64String(File.ReadAllBytes(path)), "terminal diagnostic file is exact UTF-8 without a BOM and contains only approved fields");
            string defaultPath;
            AssertTrue(TrayTerminalDiagnosticStore.TryGetDefaultPath(out defaultPath), "fixed production receipt path resolves");
            string expectedDefaultPath = Path.GetFullPath(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CodexControlOtherDevices", "logs", "tray-receipts", "trayhost-actions.log"));
            AssertTrue(String.Equals(expectedDefaultPath, defaultPath, StringComparison.OrdinalIgnoreCase), "production receipt path is fixed to the current user's exact LocalApplicationData leaf");
        }
        finally { try { Directory.Delete(root, true); } catch { } }
    }

    private static void TestTerminalDiagnosticStoreSupportsInheritedCompatibilityParentsAndCreatesPrivateChild()
    {
        string root = Path.Combine(Path.GetTempPath(), "ccod-tray-terminal-compat-" + Guid.NewGuid().ToString("N"));
        string product = ProductPath(root); string logs = LogsPath(root); string receiptDirectory = ReceiptDirectoryPath(root);
        string path = ReceiptPath(root); string legacyPath = LegacyReceiptPath(root);
        byte[] legacySentinel = new byte[] { 0x42, 0x31, 0x37, 0x29 };
        Directory.CreateDirectory(root); CreateCompatibilityParents(root); File.WriteAllBytes(legacyPath, legacySentinel);
        try
        {
            AssertTrue(!Directory.GetAccessControl(product).AreAccessRulesProtected && !Directory.GetAccessControl(logs).AreAccessRulesProtected, "supported existing product/logs parents retain inherited ACLs");
            TrayTerminalDiagnostic record = new TrayTerminalDiagnostic(TrayCommand.OpenLogs, 24UL, TrayActionResultStatus.Rejected, "CCOD_TRAY_ACTION_STALE");
            using (TrayTerminalDiagnosticStore store = TestStore(root, null, null))
            {
                AssertTrue(store.TryAppendDurably(record), "inherited supported parents accept a durable receipt in the dedicated private child");
            }
            AssertPrivateReceiptDirectory(receiptDirectory);
            byte[] expected = ReceiptBytes(TrayCommand.OpenLogs, 24UL, TrayActionResultStatus.Rejected, "CCOD_TRAY_ACTION_STALE");
            AssertTrue(Convert.ToBase64String(expected) == Convert.ToBase64String(File.ReadAllBytes(path)), "compatible parent flow writes only the fixed dedicated receipt leaf");
            AssertTrue(Convert.ToBase64String(legacySentinel) == Convert.ToBase64String(File.ReadAllBytes(legacyPath)), "legacy direct logs receipt leaf remains byte-identical and is never reused");
        }
        finally { try { Directory.Delete(root, true); } catch { } }
    }

    private static void TestTerminalDiagnosticStoreRejectsUnsafeObjectsAndProtectsOutsideSentinel()
    {
        string root = Path.Combine(Path.GetTempPath(), "ccod-tray-terminal-unsafe-" + Guid.NewGuid().ToString("N"));
        string outside = Path.Combine(Path.GetTempPath(), "ccod-tray-terminal-outside-" + Guid.NewGuid().ToString("N"));
        string outsideSentinel = Path.Combine(outside, "trayhost-actions.log");
        string path = ReceiptPath(root);
        string receiptDirectory = ReceiptDirectoryPath(root);
        string logs = LogsPath(root);
        byte[] sentinel = new byte[] { 0x10, 0x22, 0x34, 0x46, 0x58, 0x6a };
        Directory.CreateDirectory(root); CreateCompatibilityParents(root); Directory.CreateDirectory(outside); File.WriteAllBytes(outsideSentinel, sentinel);
        try
        {
            TrayTerminalDiagnostic record = new TrayTerminalDiagnostic(TrayCommand.OpenLogs, 1UL, TrayActionResultStatus.Rejected, "CCOD_TRAY_ACTION_STALE");
            using (TrayTerminalDiagnosticStore bootstrap = TestStore(root, null, null)) { AssertTrue(bootstrap.TryAppendDurably(record), "safe receipt directories are bootstrapped"); }
            File.Delete(path); Directory.Delete(receiptDirectory);

            Directory.Delete(logs);
            CreateJunction(logs, outside);
            using (TrayTerminalDiagnosticStore reparseParent = TestStore(root, null, null))
            {
                AssertTrue(!reparseParent.TryAppendDurably(record), "a reparse compatibility logs parent is rejected before writing");
            }
            AssertTrue(Convert.ToBase64String(sentinel) == Convert.ToBase64String(File.ReadAllBytes(outsideSentinel)), "reparse compatibility parent cannot alter the outside sentinel");
            DeleteJunction(logs); CreateCompatibilityParents(root);

            CreateJunction(receiptDirectory, outside);
            using (TrayTerminalDiagnosticStore reparseDirectory = TestStore(root, null, null))
            {
                AssertTrue(!reparseDirectory.TryAppendDurably(record), "a reparse private receipt directory is rejected before writing");
            }
            AssertTrue(Convert.ToBase64String(sentinel) == Convert.ToBase64String(File.ReadAllBytes(outsideSentinel)), "reparse receipt directory cannot alter the outside sentinel");
            DeleteJunction(receiptDirectory);

            using (TrayTerminalDiagnosticStore restore = TestStore(root, null, null)) { AssertTrue(restore.TryAppendDurably(record), "safe private receipt directory is restored for leaf tests"); }
            File.Delete(path);
            CreateJunction(path, outside);
            using (TrayTerminalDiagnosticStore reparseLeaf = TestStore(root, null, null))
            {
                AssertTrue(!reparseLeaf.TryAppendDurably(record), "a reparse receipt leaf is rejected before writing");
            }
            AssertTrue(Convert.ToBase64String(sentinel) == Convert.ToBase64String(File.ReadAllBytes(outsideSentinel)), "reparse leaf cannot alter the outside sentinel");
            DeleteJunction(path);

            AssertTrue(CreateHardLinkW(path, outsideSentinel, IntPtr.Zero), "test hard link is created");
            using (TrayTerminalDiagnosticStore hardLinkLeaf = TestStore(root, null, null))
            {
                AssertTrue(!hardLinkLeaf.TryAppendDurably(record), "a multi-link receipt leaf is rejected before writing");
            }
            AssertTrue(Convert.ToBase64String(sentinel) == Convert.ToBase64String(File.ReadAllBytes(outsideSentinel)), "hard-link leaf cannot alter the outside sentinel");
            File.Delete(path);

            DirectorySecurity unsafeSecurity = Directory.GetAccessControl(receiptDirectory);
            unsafeSecurity.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(WellKnownSidType.WorldSid, null), FileSystemRights.FullControl, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
            Directory.SetAccessControl(receiptDirectory, unsafeSecurity);
            using (TrayTerminalDiagnosticStore unsafeAcl = TestStore(root, null, null))
            {
                AssertTrue(!unsafeAcl.TryAppendDurably(record), "an unexpected private receipt-child DACL is rejected before writing");
            }
            AssertTrue(!File.Exists(path), "unsafe receipt-child ACL cannot create or write the receipt leaf");
            AssertTrue(Convert.ToBase64String(sentinel) == Convert.ToBase64String(File.ReadAllBytes(outsideSentinel)), "unsafe receipt-child ACL cannot alter the outside sentinel");
        }
        finally
        {
            DeleteJunction(path); DeleteJunction(receiptDirectory); DeleteJunction(logs);
            try { Directory.Delete(root, true); } catch { }
            try { Directory.Delete(outside, true); } catch { }
        }
    }

    private static void TestTerminalDiagnosticStorePinsDirectoryChainAgainstReplacement()
    {
        string root = Path.Combine(Path.GetTempPath(), "ccod-tray-terminal-pin-" + Guid.NewGuid().ToString("N"));
        string outside = Path.Combine(Path.GetTempPath(), "ccod-tray-terminal-pin-outside-" + Guid.NewGuid().ToString("N"));
        string path = ReceiptPath(root); string logs = LogsPath(root); string displaced = logs + ".displaced";
        string outsideSentinel = Path.Combine(outside, "trayhost-actions.log");
        byte[] sentinel = new byte[] { 0x71, 0x72, 0x73, 0x74, 0x75 };
        bool barrierEntered = false; bool replacementSucceeded = false;
        Directory.CreateDirectory(root); CreateCompatibilityParents(root); Directory.CreateDirectory(outside); File.WriteAllBytes(outsideSentinel, sentinel);
        try
        {
            TrayTerminalDiagnostic record = new TrayTerminalDiagnostic(TrayCommand.OpenLogs, 2UL, TrayActionResultStatus.Failed, "CCOD_TRAY_ACTION_FAILED");
            using (TrayTerminalDiagnosticStore bootstrap = TestStore(root, null, null)) { AssertTrue(bootstrap.TryAppendDurably(record), "safe receipt chain is bootstrapped"); }
            File.Delete(path);
            Action barrier = delegate
            {
                barrierEntered = true;
                try { Directory.Move(logs, displaced); replacementSucceeded = true; CreateJunction(logs, outside); } catch (IOException) { }
                catch (UnauthorizedAccessException) { }
                throw new InvalidOperationException("intentional barrier stop");
            };
            using (TrayTerminalDiagnosticStore store = TestStore(root, barrier, null))
            {
                AssertTrue(!store.TryAppendDurably(record), "a replacement attempt at the directory-to-leaf barrier fails closed");
            }
            AssertTrue(barrierEntered, "replacement barrier runs after the directory chain is opened");
            AssertTrue(!replacementSucceeded, "the opened logs handle denies rename replacement");
            AssertTrue(Convert.ToBase64String(sentinel) == Convert.ToBase64String(File.ReadAllBytes(outsideSentinel)), "replacement attempt leaves the outside sentinel byte-identical");
        }
        finally
        {
            DeleteJunction(logs);
            try { if (Directory.Exists(displaced) && !Directory.Exists(logs)) { Directory.Move(displaced, logs); } } catch { }
            try { Directory.Delete(root, true); } catch { }
            try { Directory.Delete(outside, true); } catch { }
        }
    }

    private static void TestTerminalDiagnosticStoreRejectsConcurrentWriter()
    {
        string root = Path.Combine(Path.GetTempPath(), "ccod-tray-terminal-share-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root); CreateCompatibilityParents(root);
        ManualResetEvent leafValidated = new ManualResetEvent(false); ManualResetEvent release = new ManualResetEvent(false);
        bool firstResult = false;
        try
        {
            TrayTerminalDiagnostic first = new TrayTerminalDiagnostic(TrayCommand.OpenLogs, 3UL, TrayActionResultStatus.Failed, "CCOD_TRAY_ACTION_FAILED");
            TrayTerminalDiagnostic second = new TrayTerminalDiagnostic(TrayCommand.OpenLogs, 4UL, TrayActionResultStatus.Failed, "CCOD_TRAY_ACTION_FAILED");
            using (TrayTerminalDiagnosticStore firstStore = TestStore(root, null, delegate { leafValidated.Set(); release.WaitOne(); }))
            using (TrayTerminalDiagnosticStore secondStore = TestStore(root, null, null))
            {
                Thread writer = new Thread(new ThreadStart(delegate { firstResult = firstStore.TryAppendDurably(first); }));
                writer.Start();
                AssertTrue(leafValidated.WaitOne(5000), "first writer reaches the validated leaf barrier");
                Stopwatch rejection = Stopwatch.StartNew();
                AssertTrue(!secondStore.TryAppendDurably(second), "a concurrent writer is rejected by leaf sharing");
                rejection.Stop(); AssertTrue(rejection.ElapsedMilliseconds < 250L, "a sharing conflict fails without waiting or retrying");
                release.Set(); AssertTrue(writer.Join(5000), "first writer completes after the sharing probe");
                AssertTrue(firstResult, "the validated first writer remains durable");
            }
        }
        finally { release.Set(); leafValidated.Dispose(); release.Dispose(); try { Directory.Delete(root, true); } catch { } }
    }

    private static void TestTerminalDiagnosticStoreRejectsDirectoryLeafWithoutWriting()
    {
        string root = Path.Combine(Path.GetTempPath(), "ccod-tray-terminal-directory-leaf-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root); CreateCompatibilityParents(root); string path = ReceiptPath(root);
        try
        {
            TrayTerminalDiagnostic record = new TrayTerminalDiagnostic(TrayCommand.OpenLogs, 5UL, TrayActionResultStatus.Failed, "CCOD_TRAY_ACTION_FAILED");
            using (TrayTerminalDiagnosticStore bootstrap = TestStore(root, null, null)) { AssertTrue(bootstrap.TryAppendDurably(record), "safe receipt chain is bootstrapped for directory-leaf test"); }
            File.Delete(path); Directory.CreateDirectory(path);
            using (TrayTerminalDiagnosticStore directoryLeaf = TestStore(root, null, null))
            {
                AssertTrue(!directoryLeaf.TryAppendDurably(record), "a directory at the fixed receipt leaf is rejected before writing");
            }
            AssertTrue(Directory.Exists(path) && Directory.GetFileSystemEntries(path).Length == 0, "directory leaf remains unchanged after rejection");
        }
        finally { try { if (Directory.Exists(path)) { Directory.Delete(path, true); } } catch { } try { Directory.Delete(root, true); } catch { } }
    }

    private static void TestTerminalDiagnosticStoreIsBoundedThroughValidatedHandle()
    {
        string root = Path.Combine(Path.GetTempPath(), "ccod-tray-terminal-bound-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root); CreateCompatibilityParents(root); string path = ReceiptPath(root);
        try
        {
            TrayTerminalDiagnostic first = new TrayTerminalDiagnostic(TrayCommand.OpenLogs, 41UL, TrayActionResultStatus.Failed, "CCOD_TRAY_ACTION_FAILED");
            TrayTerminalDiagnostic second = new TrayTerminalDiagnostic(TrayCommand.OpenLogs, 42UL, TrayActionResultStatus.Rejected, "CCOD_TRAY_ACTION_STALE");
            byte[] firstBytes = ReceiptBytes(TrayCommand.OpenLogs, 41UL, TrayActionResultStatus.Failed, "CCOD_TRAY_ACTION_FAILED");
            byte[] secondBytes = ReceiptBytes(TrayCommand.OpenLogs, 42UL, TrayActionResultStatus.Rejected, "CCOD_TRAY_ACTION_STALE");
            using (TrayTerminalDiagnosticStore store = TestStore(root, null, null))
            {
                AssertTrue(store.TryAppendDurably(first), "safe receipt chain is created before boundary setup");
                byte[] boundaryPrefix = new byte[checked((int)(TrayTerminalDiagnosticStore.MaximumBytes - firstBytes.Length))];
                for (int i = 0; i < boundaryPrefix.Length; i++) { boundaryPrefix[i] = (byte)'x'; }
                File.WriteAllBytes(path, boundaryPrefix);
                AssertTrue(store.TryAppendDurably(first), "a whole receipt fitting the exact 64-KiB boundary is appended");
                AssertTrue(new FileInfo(path).Length == TrayTerminalDiagnosticStore.MaximumBytes, "exact-boundary append retains exactly 64 KiB");
                AssertTrue(File.ReadAllText(path).EndsWith(Encoding.UTF8.GetString(firstBytes), StringComparison.Ordinal), "exact-boundary append retains the whole latest record");

                AssertTrue(store.TryAppendDurably(second), "a boundary-crossing receipt rolls over through the validated handle");
                AssertTrue(Convert.ToBase64String(secondBytes) == Convert.ToBase64String(File.ReadAllBytes(path)), "rollover retains exactly one complete latest record");

                File.WriteAllBytes(path, new byte[checked((int)TrayTerminalDiagnosticStore.MaximumBytes + 17)]);
                AssertTrue(store.TryAppendDurably(first), "an oversized existing receipt rolls over through the validated handle");
                AssertTrue(Convert.ToBase64String(firstBytes) == Convert.ToBase64String(File.ReadAllBytes(path)), "oversized rollover retains exactly one complete latest record");
            }
        }
        finally { try { Directory.Delete(root, true); } catch { } }
    }

    private static void TestNoHimcFailureIsSafe()
    {
        FakeTrayPlatform platform = new FakeTrayPlatform();
        platform.OwnerInputContext = new IntPtr(99);
        TrayWindow window = new TrayWindow(platform);
        bool threw = false;
        try { window.Create(Snapshot(1)); } catch (InvalidOperationException) { threw = true; }
        AssertTrue(threw && platform.Calls.Contains("ReleaseContext"), "unexpected owner HIMC is released and creation fails");
    }

    private static void TestShellRightClickNotificationMapping()
    {
        AssertTrue(TrayHostApplication.IsContextMenuEvent(0x007bU, IntPtr.Zero), "WM_CONTEXTMENU opens the native menu");
        AssertTrue(TrayHostApplication.IsContextMenuEvent(0x0205U, IntPtr.Zero), "WM_RBUTTONUP opens the native menu");
        AssertTrue(TrayHostApplication.IsContextMenuEvent(TrayNativeConstants.WmApp + 1U, new IntPtr(0x0205)), "version-4 callback WM_RBUTTONUP opens the native menu");
        AssertTrue(TrayHostApplication.IsContextMenuEvent(TrayNativeConstants.WmApp + 1U, new IntPtr(0x007b), IntPtr.Zero), "legacy callback WM_CONTEXTMENU in wParam opens the native menu");
        AssertTrue(TrayHostApplication.IsContextMenuEvent(TrayNativeConstants.WmApp + 1U, new IntPtr(0x0205), IntPtr.Zero), "legacy callback WM_RBUTTONUP in wParam opens the native menu");
        AssertTrue(!TrayHostApplication.IsContextMenuEvent(TrayNativeConstants.WmApp + 1U, new IntPtr(0x0201)), "left click remains inert");
    }

    private static void TestRealNativePInvokeSurface()
    {
        Win32TrayPlatform platform = new Win32TrayPlatform();
        IntPtr owner = platform.CreateOwner();
        IntPtr menu = IntPtr.Zero;
        try
        {
            AssertTrue(owner != IntPtr.Zero, "real native owner is created");
            AssertTrue(platform.ShowOwner(owner), "real ShowWindow entry point resolves");
            menu = platform.CreatePopupMenu();
            AssertTrue(menu != IntPtr.Zero, "real CreatePopupMenu entry point resolves");
            AssertTrue(platform.AppendMenu(menu, TrayNativeConstants.MfString, new UIntPtr(1U), "probe"), "real AppendMenu entry point resolves");
            platform.SetForegroundWindow(owner);
            platform.GetForegroundWindow();
        }
        finally
        {
            if (menu != IntPtr.Zero) { platform.DestroyMenu(menu); }
            platform.HideOwner(owner);
            platform.DestroyOwner(owner);
        }
    }

    private static void TestPostedWorkMessageDispatchesToItsOwnerWindow()
    {
        Win32TrayPlatform platform = new Win32TrayPlatform();
        IntPtr owner = IntPtr.Zero;
        uint observed = 0U;
        platform.SetMessageHandler(delegate(uint message, IntPtr wParam, IntPtr lParam) { observed = message; });
        try
        {
            owner = platform.CreateOwner();
            uint workMessage = TrayNativeConstants.WmApp + 2U;
            AssertTrue(Win32TrayPlatform.PostToWindow(owner, workMessage), "real PostMessage queues work for the owner window");
            Win32TrayPlatform.Message message;
            AssertTrue(Win32TrayPlatform.GetMessageLoop(out message) > 0, "real GetMessage receives the posted owner work");
            Win32TrayPlatform.TranslateAndDispatch(message);
            AssertTrue(observed == workMessage, "dispatch preserves the target HWND so posted presentation work reaches the owner WndProc");
        }
        finally
        {
            if (owner != IntPtr.Zero) { platform.DestroyOwner(owner); }
        }
    }

    public static int Main(string[] args)
    {
        try
        {
            TestNativeOrderAndCancel();
            TestForegroundFailureFallsBackToNativeMenu();
            TestOwnerShowFailureNeverTracks();
            TestReentryAndPendingSnapshot();
            TestStalePresentationIsNotReportedAsDisplayed();
            TestMenuRevisionGateHoldsNewPresentationUntilTheDisplayedActionIsSelected();
            TestSelectedCommandAndTaskbarRestore();
            TestAboutCommandDefersProofToSupervisor();
            TestVerifiedAboutUsesTheAcknowledgedSnapshotVersion();
            TestActionFailureUsesTheAcknowledgedSnapshotStrings();
            TestTerminalDiagnosticStoreSupportsInheritedCompatibilityParentsAndCreatesPrivateChild();
            TestTerminalDiagnosticLogIsSanitizedAndReportsPersistence();
            TestTerminalDiagnosticStoreRejectsUnsafeObjectsAndProtectsOutsideSentinel();
            TestTerminalDiagnosticStorePinsDirectoryChainAgainstReplacement();
            TestTerminalDiagnosticStoreRejectsConcurrentWriter();
            TestTerminalDiagnosticStoreRejectsDirectoryLeafWithoutWriting();
            TestTerminalDiagnosticStoreIsBoundedThroughValidatedHandle();
            TestSimplifiedMenuAndExitConfirmation();
            TestNoHimcFailureIsSafe();
            TestShellRightClickNotificationMapping();
            TestRealNativePInvokeSurface();
            TestPostedWorkMessageDispatchesToItsOwnerWindow();
            Console.WriteLine("TrayHost native self-tests passed: 22");
            return 0;
        }
        catch (Exception error)
        {
            Console.Error.WriteLine("TrayHost native self-test failed: " + error.GetType().FullName);
            Console.Error.WriteLine(error.Message);
            return 1;
        }
    }
}
