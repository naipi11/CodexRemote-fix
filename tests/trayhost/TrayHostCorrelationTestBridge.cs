using System;
using System.Collections.Generic;

public sealed class TrayHostCorrelationTestBridge : IDisposable
{
    private sealed class Platform : INativeTrayPlatform
    {
        internal uint Selection;
        public IntPtr CreateOwner() { return new IntPtr(10); }
        public IntPtr AssociateOwnerInputContext(IntPtr owner, IntPtr context) { return new IntPtr(20); }
        public IntPtr GetOwnerInputContext(IntPtr owner) { return IntPtr.Zero; }
        public bool ReleaseInputContext(IntPtr owner, IntPtr context) { return true; }
        public IntPtr LoadIcon() { return new IntPtr(40); }
        public bool DestroyIcon(IntPtr icon) { return true; }
        public bool AddIcon(ref TrayIconData icon) { return true; }
        public bool SetIconVersion(ref TrayIconData icon) { return true; }
        public bool DeleteIcon(ref TrayIconData icon) { return true; }
        public IntPtr CreatePopupMenu() { return new IntPtr(30); }
        public IntPtr CreateSubMenu() { return new IntPtr(31); }
        public bool AppendMenu(IntPtr menu, uint flags, UIntPtr command, string text) { return true; }
        public bool AppendSubMenu(IntPtr menu, IntPtr child, string text) { return true; }
        public bool ShowOwner(IntPtr owner) { return true; }
        public bool HideOwner(IntPtr owner) { return true; }
        public bool SetForegroundWindow(IntPtr owner) { return true; }
        public IntPtr GetForegroundWindow() { return new IntPtr(10); }
        public uint TrackPopupMenuEx(IntPtr menu, uint flags, int x, int y, IntPtr owner, IntPtr parameters) { return Selection; }
        public bool PostMessage(IntPtr owner, uint message, UIntPtr wParam, IntPtr lParam) { return true; }
        public bool SetNotificationFocus(ref TrayIconData icon) { return true; }
        public bool ShowMessageBox(IntPtr owner, string text, string caption) { return true; }
        public bool ConfirmExit(IntPtr owner, string text, string caption) { return true; }
        public bool DestroyMenu(IntPtr menu) { return true; }
        public bool EndMenu() { return true; }
        public bool DestroyOwner(IntPtr owner) { return true; }
    }

    private readonly Platform _platform;
    private readonly HostTransport _transport;
    private readonly TrayWindow _window;
    private TrayHostAction _selected;
    private TrayActionResult _terminal;

    public TrayHostCorrelationTestBridge(ulong revision, TrayCommand command)
    {
        _platform = new Platform { Selection = (uint)command };
        _transport = new HostTransport();
        _window = new TrayWindow(_platform, _transport.SetMenuOpen);
        _window.CommandSelected += delegate(TrayCommand selected, ulong displayedRevision)
        {
            TrayHostAction action = new TrayHostAction(Guid.NewGuid(), selected, displayedRevision);
            if (!_transport.TryRegisterAction(action)) { throw new InvalidOperationException("test action registration failed"); }
            _selected = action;
        };
        _window.Create(Snapshot(revision));
    }

    public void SelectFromNativeMenu()
    {
        _window.HandleContextMenu(new TrayPoint(5, 5));
        if (_selected == null) { throw new InvalidOperationException("native menu produced no action"); }
    }

    public Guid ActionId { get { return _selected == null ? Guid.Empty : _selected.ActionId; } }
    public string Command { get { return _selected == null ? String.Empty : _selected.Command.ToString(); } }
    public ulong Revision { get { return _selected == null ? 0UL : _selected.Revision; } }

    public bool Acknowledge(Guid actionId, ulong revision, string status, string errorCode)
    {
        TrayActionResultStatus parsed = (TrayActionResultStatus)Enum.Parse(typeof(TrayActionResultStatus), status, false);
        TrayActionResult result = new TrayActionResult(actionId, revision, parsed, errorCode, null);
        bool accepted = _transport.TryAcknowledgeAction(result);
        if (!accepted) { return false; }
        if (parsed == TrayActionResultStatus.Rejected || parsed == TrayActionResultStatus.Failed)
        {
            TrayActionResult queued;
            if (!_transport.TryTakeFailedAction(out queued)) { return false; }
            _terminal = queued;
        }
        else { _terminal = result; }
        return true;
    }

    public string TerminalStatus { get { return _terminal == null ? String.Empty : _terminal.Status.ToString(); } }
    public string TerminalCode { get { return _terminal == null ? String.Empty : (_terminal.ErrorCode ?? String.Empty); } }
    public ulong TerminalRevision { get { return _terminal == null ? 0UL : _terminal.Revision; } }

    private static PresentationSnapshot Snapshot(ulong revision)
    {
        string[] strings = new string[16];
        for (int index = 0; index < strings.Length; index++) { strings[index] = "correlation-" + index.ToString(); }
        return new PresentationSnapshot(revision, TrayColor.Green, ConnectionState.Connected, ProtectionState.Running, LanguageMode.English,
            PresentationFlags.OpenLogsEnabled | PresentationFlags.LanguageEnabled | PresentationFlags.AboutEnabled, strings);
    }

    public void Dispose()
    {
        _window.Dispose();
        _transport.Dispose();
    }
}
