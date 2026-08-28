using System;
using System.Collections.Generic;
using System.Threading;

internal sealed class TrayTerminalReceipt
{
    private readonly object _authority;
    private int _publicationClaimed;

    internal TrayTerminalReceipt(object authority, TrayCommand command, TrayActionResult result)
    {
        if (authority == null) { throw new ArgumentNullException("authority"); }
        if (!TrayCommandPolicy.IsWireCommand(command) || result == null || result.Status == TrayActionResultStatus.Accepted) { throw new ArgumentException("terminal receipt is invalid"); }
        _authority = authority;
        Command = command;
        Result = result;
        Diagnostic = new TrayTerminalDiagnostic(command, result.Revision, result.Status, result.ErrorCode);
    }

    internal TrayCommand Command { get; private set; }
    internal TrayActionResult Result { get; private set; }
    internal TrayTerminalDiagnostic Diagnostic { get; private set; }

    internal bool TryClaimPublication(object authority)
    {
        return Object.ReferenceEquals(_authority, authority) && Interlocked.CompareExchange(ref _publicationClaimed, 1, 0) == 0;
    }
}

internal sealed class TrayTerminalReceiptSink : IDisposable
{
    internal const int MaximumOutstanding = 8;
    private const int DisposeJoinMilliseconds = 100;
    private readonly object _gate = new object();
    private readonly Queue<TrayTerminalReceipt> _pending = new Queue<TrayTerminalReceipt>();
    private readonly AutoResetEvent _available = new AutoResetEvent(false);
    private readonly Func<TrayTerminalDiagnostic, bool> _writeDurably;
    private readonly Func<TrayTerminalReceipt, bool> _publishDurable;
    private readonly Action _disposeStore;
    private readonly Thread _writer;
    private int _outstanding;
    private int _cleanupStarted;
    private bool _writerStarted;
    private bool _closed;

    internal TrayTerminalReceiptSink(Func<TrayTerminalDiagnostic, bool> writeDurably, Func<TrayTerminalReceipt, bool> publishDurable)
        : this(writeDurably, publishDurable, null)
    {
    }

    internal TrayTerminalReceiptSink(Func<TrayTerminalDiagnostic, bool> writeDurably, Func<TrayTerminalReceipt, bool> publishDurable, Action disposeStore)
    {
        _writeDurably = writeDurably;
        _publishDurable = publishDurable;
        _disposeStore = disposeStore;
        if (_writeDurably == null || _publishDurable == null) { _closed = true; return; }
        try
        {
            _writer = new Thread(new ThreadStart(WriterMain)) { IsBackground = true, Name = "CodexRemote.TrayHost.ReceiptWriter" };
            _writer.Start();
            _writerStarted = true;
        }
        catch { _closed = true; }
    }

    internal bool TrySubmit(TrayTerminalReceipt receipt)
    {
        if (receipt == null || !Monitor.TryEnter(_gate)) { return false; }
        try
        {
            if (_closed || _outstanding >= MaximumOutstanding) { return false; }
            try { _available.Set(); }
            catch { return false; }
            try
            {
                _pending.Enqueue(receipt);
                _outstanding++;
                return true;
            }
            catch { return false; }
        }
        finally { Monitor.Exit(_gate); }
    }

    public void Dispose()
    {
        Thread writer;
        lock (_gate)
        {
            if (_closed)
            {
                writer = _writer;
            }
            else
            {
                _closed = true;
                _pending.Clear();
                _outstanding = 0;
                writer = _writer;
                try { _available.Set(); } catch { }
            }
        }
        if (writer == null || !_writerStarted) { CleanupAfterWriter(); return; }
        if (Object.ReferenceEquals(writer, Thread.CurrentThread)) { return; }
        bool stopped = false;
        try { stopped = writer.Join(DisposeJoinMilliseconds); } catch { }
        if (stopped) { CleanupAfterWriter(); }
    }

    private void WriterMain()
    {
        try
        {
            while (true)
            {
                TrayTerminalReceipt receipt = null;
                lock (_gate)
                {
                    if (_closed) { return; }
                    if (_pending.Count != 0) { receipt = _pending.Dequeue(); }
                }
                if (receipt == null)
                {
                    try { _available.WaitOne(); }
                    catch { return; }
                    continue;
                }

                bool durable = false;
                try { durable = _writeDurably(receipt.Diagnostic); }
                catch { durable = false; }
                if (durable && !IsClosed())
                {
                    try { _publishDurable(receipt); }
                    catch { }
                }
                lock (_gate)
                {
                    if (_outstanding > 0) { _outstanding--; }
                    if (_closed) { return; }
                }
            }
        }
        finally
        {
            lock (_gate)
            {
                _closed = true;
                _pending.Clear();
                _outstanding = 0;
            }
            CleanupAfterWriter();
        }
    }

    private bool IsClosed()
    {
        lock (_gate) { return _closed; }
    }

    private void CleanupAfterWriter()
    {
        if (Interlocked.CompareExchange(ref _cleanupStarted, 1, 0) != 0) { return; }
        Action disposeStore = _disposeStore;
        if (disposeStore != null) { try { disposeStore(); } catch { } }
        try { _available.Dispose(); } catch { }
    }
}
