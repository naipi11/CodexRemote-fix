using System;
using System.Collections.Generic;
using System.Threading;

public sealed class TrayHostCorrelationTestBridge : IDisposable
{
    private sealed class Platform : INativeTrayPlatform
    {
        private sealed class Message
        {
            internal uint Id;
            internal IntPtr WParam;
            internal IntPtr LParam;
        }

        private readonly object _gate = new object();
        private readonly Queue<Message> _messages = new Queue<Message>();
        private readonly AutoResetEvent _available = new AutoResetEvent(false);
        private Action<uint, IntPtr, IntPtr> _handler;
        internal uint Selection;
        internal int MessageBoxCount;
        public void SetMessageHandler(Action<uint, IntPtr, IntPtr> handler) { _handler = handler; }
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
        public bool PostMessage(IntPtr owner, uint message, UIntPtr wParam, IntPtr lParam)
        {
            ulong raw = wParam.ToUInt64();
            IntPtr converted = IntPtr.Size == 4 ? new IntPtr(unchecked((int)raw)) : new IntPtr(unchecked((long)raw));
            lock (_gate) { _messages.Enqueue(new Message { Id = message, WParam = converted, LParam = lParam }); }
            _available.Set();
            return true;
        }
        public bool SetNotificationFocus(ref TrayIconData icon) { return true; }
        public bool ShowMessageBox(IntPtr owner, string text, string caption) { MessageBoxCount++; return true; }
        public bool ConfirmExit(IntPtr owner, string text, string caption) { return true; }
        public bool DestroyMenu(IntPtr menu) { return true; }
        public bool EndMenu() { return true; }
        public bool DestroyOwner(IntPtr owner) { return true; }

        internal bool DispatchNext(TimeSpan timeout)
        {
            Message message = null;
            lock (_gate) { if (_messages.Count != 0) { message = _messages.Dequeue(); } }
            if (message == null)
            {
                if (!_available.WaitOne(timeout)) { return false; }
                lock (_gate) { if (_messages.Count != 0) { message = _messages.Dequeue(); } }
            }
            if (message == null || _handler == null) { return false; }
            _handler(message.Id, message.WParam, message.LParam);
            return true;
        }

        internal void Dispose() { _available.Dispose(); }
    }

    private readonly Platform _platform;
    private readonly HostTransport _transport;
    private readonly TrayWindow _window;
    private readonly TrayHostApplication _application;
    private readonly TrayTerminalReceiptSink _receiptSink;
    private readonly ManualResetEvent _receiptAttempted = new ManualResetEvent(false);
    private readonly ManualResetEvent _publicationCompleted = new ManualResetEvent(false);
    private TrayHostAction _selected;
    private TrayActionResult _terminal;
    private bool _persistDiagnostics = true;

    public TrayHostCorrelationTestBridge(ulong revision, TrayCommand command) : this(revision, command, true)
    {
    }

    public TrayHostCorrelationTestBridge(ulong revision, TrayCommand command, bool persistDiagnostics)
    {
        _platform = new Platform { Selection = (uint)command };
        _persistDiagnostics = persistDiagnostics;
        TrayHostApplication application = null;
        _transport = new HostTransport(null, delegate(uint token) { return application != null && application.PostReceiptWork(token); });
        _window = new TrayWindow(_platform, _transport.SetMenuOpen);
        _window.CommandSelected += delegate(TrayCommand selected, ulong displayedRevision)
        {
            TrayHostAction action = new TrayHostAction(Guid.NewGuid(), selected, displayedRevision);
            if (!_transport.TryRegisterAction(action)) { throw new InvalidOperationException("test action registration failed"); }
            _selected = action;
        };
        Action<uint> receiptWork = delegate(uint token)
        {
            TrayTerminalReceiptUiKind kind;
            TrayActionResult result;
            if (!_transport.TryTakeReceiptUi(token, out kind, out result)) { return; }
            _terminal = result;
            if (kind == TrayTerminalReceiptUiKind.Failure) { _window.ShowActionFailed(); }
            else if (kind == TrayTerminalReceiptUiKind.About) { _window.ShowAbout(); }
        };
        application = new TrayHostApplication(_platform, _window, null, delegate { }, receiptWork);
        _application = application;
        _receiptSink = new TrayTerminalReceiptSink(
            delegate(TrayTerminalDiagnostic record) { bool persisted = _persistDiagnostics; _receiptAttempted.Set(); return persisted; },
            delegate(TrayTerminalReceipt receipt) { bool published = _transport.TryPublishDurableReceipt(receipt); _publicationCompleted.Set(); return published; });
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
        _receiptAttempted.Reset();
        _publicationCompleted.Reset();
        TrayTerminalReceipt receipt;
        bool accepted = _transport.TryAcknowledgeAction(result, out receipt);
        if (!accepted) { return false; }
        _terminal = result;
        if (receipt != null && _receiptSink.TrySubmit(receipt))
        {
            if (!_receiptAttempted.WaitOne(TimeSpan.FromSeconds(2))) { throw new InvalidOperationException("test receipt writer did not run"); }
            if (_persistDiagnostics)
            {
                if (!_publicationCompleted.WaitOne(TimeSpan.FromSeconds(2))) { throw new InvalidOperationException("test receipt publication did not complete"); }
                if (parsed == TrayActionResultStatus.Rejected || parsed == TrayActionResultStatus.Failed)
                {
                    DateTime deadline = DateTime.UtcNow.AddSeconds(2);
                    while (_platform.MessageBoxCount == 0 && DateTime.UtcNow < deadline) { _platform.DispatchNext(TimeSpan.FromMilliseconds(25)); }
                    if (_platform.MessageBoxCount != 1) { throw new InvalidOperationException("test receipt UI was not token-dispatched"); }
                }
            }
        }
        return true;
    }

    public void SetDiagnosticPersistence(bool value) { _persistDiagnostics = value; }
    public int FeedbackCount { get { return _platform.MessageBoxCount; } }

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
        _receiptSink.Dispose();
        _transport.Dispose();
        _application.Dispose();
        _receiptAttempted.Dispose();
        _publicationCompleted.Dispose();
        _platform.Dispose();
    }
}
