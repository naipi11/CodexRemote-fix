using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;

public static class TrayHostProductionTraceFixture
{
    public static TrayHostParentClient Start(string executablePath)
    {
        if (String.IsNullOrEmpty(executablePath) || !Path.IsPathRooted(executablePath) || !File.Exists(executablePath)) { throw new ArgumentException("trace executable is required", "executablePath"); }
        string witnessPath = GetWitnessPath(executablePath);
        if (File.Exists(witnessPath)) { File.Delete(witnessPath); }
        using (Process current = Process.GetCurrentProcess())
        {
            return TrayHostParentClient.Start(new TrayHostStartOptions {
                ExePath = executablePath,
                RuntimeId = "trace-runtime",
                ParentPid = current.Id,
                ParentCreationFileTimeUtc = current.StartTime.ToFileTimeUtc(),
                InitialPresentation = CreateSnapshot()
            });
        }
    }

    public static string GetWitnessPath(string executablePath)
    {
        return Path.GetFullPath(executablePath) + ".witness.log";
    }

    private static PresentationSnapshot CreateSnapshot()
    {
        string[] strings = new string[16];
        for (int index = 0; index < strings.Length; index++) { strings[index] = "trace-" + index.ToString(); }
        return new PresentationSnapshot(1UL, TrayColor.Green, ConnectionState.Connected, ProtectionState.Running, LanguageMode.English, PresentationFlags.OpenLogsEnabled, strings);
    }
}

internal static class TrayHostProductionTraceMain
{
    public static int Main(string[] args)
    {
        string witnessPath = TrayHostProductionTraceFixture.GetWitnessPath(Process.GetCurrentProcess().MainModule.FileName);
        TraceWitness witness = new TraceWitness(witnessPath);
        try
        {
            TrayHostChildIdentity identity;
            if (!TrayHostChildSession.TryCreateIdentity(args, out identity)) { return 2; }
#if TRAYHOST_TRACE_STALE
            bool stale = true;
#else
            bool stale = false;
#endif
#if TRAYHOST_TRACE_HANG_AFTER_ACK
            bool hangAfterShutdownAck = true;
#else
            bool hangAfterShutdownAck = false;
#endif
            using (ScriptedTraceRuntime runtime = new ScriptedTraceRuntime(witness, stale, hangAfterShutdownAck))
            {
                return TrayHostChildSession.Run(
                    Console.OpenStandardInput(),
                    Console.OpenStandardOutput(),
                    identity,
                    runtime,
                    delegate(HostTransport transport)
                    {
                        return new TrayTerminalReceiptSink(
                            witness.TryWriteDurably,
                            delegate(TrayTerminalReceipt receipt)
                            {
                                bool published = transport.TryPublishDurableReceipt(receipt);
                                witness.Append("publication accepted=" + published.ToString().ToLowerInvariant());
                                runtime.ReleaseReceiptDispatch();
                                return published;
                            });
                    });
            }
        }
        catch (Exception error)
        {
            witness.Append("fatal type=" + error.GetType().Name);
            return 1;
        }
    }
}

internal sealed class ScriptedTraceRuntime : ITrayHostRuntime
{
    private readonly TraceWitness _witness;
    private readonly bool _stale;
    private readonly bool _hangAfterShutdownAck;
    private readonly ScriptedTracePlatform _platform;
    private TrayWindow _window;
    private TrayHostApplication _application;
    private Action<TrayCommand, ulong> _commandSelected;
    private bool _exitRequested;
    private bool _started;
    private bool _disposed;
    private bool _blockedExitRecorded;

    internal ScriptedTraceRuntime(TraceWitness witness, bool stale, bool hangAfterShutdownAck)
    {
        if (witness == null) { throw new ArgumentNullException("witness"); }
        _witness = witness;
        _stale = stale;
        _hangAfterShutdownAck = hangAfterShutdownAck;
        _platform = new ScriptedTracePlatform(witness);
    }

    public ulong CurrentRevision { get { return _window == null ? 0UL : _window.CurrentRevision; } }

    public void Initialize(Action<bool> menuOpenChanged, Action<TrayCommand, ulong> commandSelected, Action work, Action<uint> receiptWork)
    {
        if (_window != null || commandSelected == null || work == null || receiptWork == null) { throw new InvalidOperationException("trace runtime initialization is invalid"); }
        _commandSelected = commandSelected;
        _window = new TrayWindow(_platform, menuOpenChanged);
        _window.CommandSelected += commandSelected;
        _application = new TrayHostApplication(_platform, _window, commandSelected, work, receiptWork);
    }

    public void Create(PresentationSnapshot initial) { _window.Create(initial); }
    public bool Apply(PresentationSnapshot snapshot) { return _window.Apply(snapshot); }
    public void PostWork() { _application.PostWork(); }
    public bool PostReceiptWork(uint token) { return _application.PostReceiptWork(token); }
    public void ShowAbout() { _window.ShowAbout(); }
    public void ShowActionFailed() { _window.ShowActionFailed(); }
    public void RequestShutdown() { _window.RequestShutdown(); }

    internal void ReleaseReceiptDispatch() { _platform.ReleaseReceiptDispatch(); }

    public void RequestExit()
    {
        if (_hangAfterShutdownAck)
        {
            if (!_blockedExitRecorded) { _blockedExitRecorded = true; _witness.Append("shutdown-ack-written-exit-blocked"); }
            _platform.Signal();
            return;
        }
        _exitRequested = true;
        _platform.Signal();
    }

    public int Run()
    {
        if (_started || _window == null) { throw new InvalidOperationException("trace runtime lifecycle is invalid"); }
        _started = true;
        if (_stale)
        {
            _witness.Append("fixture command=OpenLogs revision=8");
            _commandSelected(TrayCommand.OpenLogs, 8UL);
        }
        else
        {
            uint? selected = _window.HandleContextMenu(new TrayPoint(4, 5));
            if (!selected.HasValue || selected.Value != (uint)TrayCommand.OpenLogs) { throw new InvalidOperationException("native OpenLogs selection failed"); }
            _witness.Append("native command=OpenLogs revision=" + CurrentRevision.ToString());
        }
        while (!_exitRequested) { _platform.TryDispatch(TimeSpan.FromMilliseconds(250)); }
        return 0;
    }

    public void Dispose()
    {
        if (_disposed) { return; }
        _disposed = true;
        if (_application != null) { _application.Dispose(); }
        _platform.Dispose();
    }
}

internal sealed class ScriptedTracePlatform : INativeTrayPlatform, IDisposable
{
    private sealed class QueuedMessage
    {
        internal uint Message;
        internal IntPtr WParam;
        internal IntPtr LParam;
    }

    private readonly object _gate = new object();
    private readonly Queue<QueuedMessage> _messages = new Queue<QueuedMessage>();
    private readonly AutoResetEvent _available = new AutoResetEvent(false);
    private readonly TraceWitness _witness;
    private Action<uint, IntPtr, IntPtr> _handler;
    private bool _receiptDispatchReleased;
    private bool _disposed;

    internal ScriptedTracePlatform(TraceWitness witness) { _witness = witness; }

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

    public uint TrackPopupMenuEx(IntPtr menu, uint flags, int x, int y, IntPtr owner, IntPtr parameters)
    {
        _witness.Append("native-menu command=OpenLogs");
        return (uint)TrayCommand.OpenLogs;
    }

    public bool PostMessage(IntPtr owner, uint message, UIntPtr wParam, IntPtr lParam)
    {
        ulong raw = wParam.ToUInt64();
        IntPtr converted = IntPtr.Size == 4 ? new IntPtr(unchecked((int)raw)) : new IntPtr(unchecked((long)raw));
        lock (_gate)
        {
            if (_disposed) { return false; }
            _messages.Enqueue(new QueuedMessage { Message = message, WParam = converted, LParam = lParam });
        }
        _witness.Append("post message=" + message.ToString() + " token=" + raw.ToString());
        _available.Set();
        return true;
    }

    public bool SetNotificationFocus(ref TrayIconData icon) { return true; }

    public bool ShowMessageBox(IntPtr owner, string text, string caption)
    {
        _witness.Append("dialog caption=" + caption + " text=" + text);
        return true;
    }

    public bool ConfirmExit(IntPtr owner, string text, string caption) { return true; }
    public bool DestroyMenu(IntPtr menu) { return true; }
    public bool EndMenu() { return true; }
    public bool DestroyOwner(IntPtr owner) { return true; }

    internal bool TryDispatch(TimeSpan timeout)
    {
        QueuedMessage queued = null;
        lock (_gate)
        {
            if (_messages.Count != 0 && (_messages.Peek().Message != TrayNativeConstants.WmApp + 3U || _receiptDispatchReleased)) { queued = _messages.Dequeue(); }
        }
        if (queued == null)
        {
            try { if (!_available.WaitOne(timeout)) { return false; } }
            catch (ObjectDisposedException) { return false; }
            lock (_gate)
            {
                if (_messages.Count != 0 && (_messages.Peek().Message != TrayNativeConstants.WmApp + 3U || _receiptDispatchReleased)) { queued = _messages.Dequeue(); }
            }
        }
        if (queued == null) { return false; }
        Action<uint, IntPtr, IntPtr> handler = _handler;
        if (handler == null) { throw new InvalidOperationException("trace native handler is unavailable"); }
        handler(queued.Message, queued.WParam, queued.LParam);
        return true;
    }

    internal void Signal() { try { _available.Set(); } catch (ObjectDisposedException) { } }

    internal void ReleaseReceiptDispatch()
    {
        lock (_gate) { if (!_disposed) { _receiptDispatchReleased = true; } }
        Signal();
    }

    public void Dispose()
    {
        lock (_gate) { if (_disposed) { return; } _disposed = true; _messages.Clear(); }
        _available.Dispose();
    }
}

internal sealed class TraceWitness
{
    private readonly object _gate = new object();
    private readonly string _path;

    internal TraceWitness(string path)
    {
        if (String.IsNullOrEmpty(path) || !Path.IsPathRooted(path)) { throw new ArgumentException("trace witness path is invalid", "path"); }
        _path = path;
    }

    internal bool TryWriteDurably(TrayTerminalDiagnostic record)
    {
        if (record == null) { return false; }
        Append("receipt command=" + record.Command.ToString() + " revision=" + record.Revision.ToString() + " status=" + record.Status.ToString() + " code=" + record.Code);
        return true;
    }

    internal void Append(string value)
    {
        byte[] bytes = new UTF8Encoding(false).GetBytes(value + "\r\n");
        lock (_gate)
        {
            using (FileStream stream = new FileStream(_path, FileMode.Append, FileAccess.Write, FileShare.ReadWrite))
            {
                stream.Write(bytes, 0, bytes.Length);
                stream.Flush(true);
            }
        }
    }
}
