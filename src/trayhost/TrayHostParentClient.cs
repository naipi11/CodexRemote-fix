using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Security.Cryptography;
using System.Text.RegularExpressions;
using System.Threading;

public sealed class TrayHostStartOptions
{
    public string ExePath { get; set; }
    public string RuntimeId { get; set; }
    public int ParentPid { get; set; }
    public long ParentCreationFileTimeUtc { get; set; }
    public PresentationSnapshot InitialPresentation { get; set; }
}

public sealed class TrayHostStartReceipt
{
    public int HostPid { get; internal set; }
    public long HostCreationFileTimeUtc { get; internal set; }
    public string RuntimeId { get; internal set; }
    public ushort ProtocolMajor { get; internal set; }
    public ulong Capabilities { get; internal set; }
}

public sealed class TrayHostParentClient : IDisposable
{
    internal static Func<ProcessStartInfo, Process> TestProcessFactory = null;
    internal static Action TestBeforeReaderStopSignal = null;
    internal static Action TestBeforeWaitHandleDispose = null;

    private readonly object _eventGate = new object();
    private readonly object _writeGate = new object();
    private readonly AutoResetEvent _work = new AutoResetEvent(false);
    private readonly ManualResetEvent _stopped = new ManualResetEvent(false);
    private readonly Queue<TrayHostEvent> _events = new Queue<TrayHostEvent>();
    private ParentTransport _transport;
    private Process _process;
    private JobObject _job;
    private Stream _childInput;
    private Stream _childOutput;
    private Stream _childError;
    private SessionKeys _keys;
    private ulong _writeSequence;
    private ulong _readSequence;
    private volatile bool _shutdownRequested;
    private int _disposeGate;
    private int _disposed;
    private Thread _writerThread;
    private Thread _readerThread;
    private Thread _stderrThread;

    public TrayHostStartReceipt Receipt { get; private set; }

    private TrayHostParentClient() { }

    public static TrayHostParentClient Start(TrayHostStartOptions options)
    {
        TrayHostParentClient client = new TrayHostParentClient();
        try { client.StartInternal(options); return client; }
        catch { client.Dispose(); throw; }
    }

    private void StartInternal(TrayHostStartOptions options)
    {
        ValidateOptions(options);
        _transport = new ParentTransport();
        ProcessStartInfo startInfo = new ProcessStartInfo {
            FileName = options.ExePath,
            Arguments = "--child --parent-pid " + options.ParentPid.ToString() + " --parent-created " + options.ParentCreationFileTimeUtc.ToString() + " --runtime-id " + options.RuntimeId,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            WorkingDirectory = Path.GetDirectoryName(options.ExePath)
        };
        _process = TestProcessFactory == null ? Process.Start(startInfo) : TestProcessFactory(startInfo);
        if (_process == null) { throw new InvalidOperationException("CCOD_TRAYHOST_PROCESS_START_FAILED"); }
        _process.EnableRaisingEvents = true;
        _childInput = _process.StandardInput.BaseStream;
        _childOutput = _process.StandardOutput.BaseStream;
        _childError = _process.StandardError.BaseStream;
        _job = JobObject.CreateKillOnClose();
        _job.Assign(_process);

        byte[] seed = new byte[32]; byte[] challenge = new byte[32];
        using (RandomNumberGenerator rng = RandomNumberGenerator.Create()) { rng.GetBytes(seed); rng.GetBytes(challenge); }
        ProtocolCodec.WriteBootstrap(_childInput, ProtocolFrame.Bootstrap(ProtocolDirection.ParentToHost, TrayHostMessageType.ParentHello, TrayHostWire.WriteParentHello(seed, challenge, options.ParentPid, options.ParentCreationFileTimeUtc, options.RuntimeId)));
        TrayHostHello host = TrayHostWire.ReadHostHello(ProtocolCodec.ReadBootstrap(_childOutput, ProtocolDirection.HostToParent).Payload);
        if (host.ProcessId != _process.Id || host.CreationFileTimeUtc != _process.StartTime.ToFileTimeUtc() || host.RuntimeId != options.RuntimeId || host.HostEpoch == 0UL) { throw new InvalidOperationException("CCOD_TRAYHOST_IDENTITY_INVALID"); }
        _keys = ProtocolCodec.DeriveDirectionalKeys(seed, challenge, host.HostNonce, host.HostEpoch);
        _writeSequence = 1UL; _readSequence = 1UL;
        WriteAuthenticated(TrayHostMessageType.Presentation, TrayHostWire.WritePresentation(options.InitialPresentation));
        ProtocolFrame ack = ReadAuthenticated();
        if (ack.MessageType != TrayHostMessageType.PresentationAck || TrayHostWire.ReadRevision(ack.Payload) != options.InitialPresentation.Revision) { throw new InvalidOperationException("CCOD_TRAYHOST_INITIAL_ACK_INVALID"); }
        ProtocolFrame ready = ReadAuthenticated();
        if (ready.MessageType != TrayHostMessageType.UiReady || TrayHostWire.ReadRevision(ready.Payload) != options.InitialPresentation.Revision) { throw new InvalidOperationException("CCOD_TRAYHOST_NOT_READY"); }
        _transport.MarkReady();
        Receipt = new TrayHostStartReceipt { HostPid = _process.Id, HostCreationFileTimeUtc = _process.StartTime.ToFileTimeUtc(), RuntimeId = options.RuntimeId, ProtocolMajor = ProtocolCodec.ProtocolMajor, Capabilities = 2UL };
        StartThreads();
    }

    private void StartThreads()
    {
        _writerThread = new Thread(WriterLoop) { IsBackground = true, Name = "CodexRemote.TrayHost.ParentWriter" };
        _readerThread = new Thread(ReaderLoop) { IsBackground = true, Name = "CodexRemote.TrayHost.ParentReader" };
        _stderrThread = new Thread(StderrLoop) { IsBackground = true, Name = "CodexRemote.TrayHost.ParentStderr" };
        _writerThread.Start(); _readerThread.Start(); _stderrThread.Start();
    }

    public bool TryPublish(PresentationSnapshot snapshot)
    {
        if (IsClosing() || snapshot == null || _transport.GetHealth() != TrayHostHealth.Ready) { return false; }
        bool accepted = _transport.TrySetLatestPresentation(snapshot); if (accepted) { SignalWork(); } return accepted;
    }

    public bool TryDequeueEvent(out TrayHostEvent value)
    {
        lock (_eventGate) { if (_events.Count == 0) { value = null; return false; } value = _events.Dequeue(); return true; }
    }

    public bool TryAcknowledgeAction(TrayActionResult result)
    {
        if (IsClosing() || result == null || _transport == null || _transport.GetHealth() != TrayHostHealth.Ready) { return false; }
        bool accepted = _transport.TryEnqueueActionResult(result); if (accepted) { SignalWork(); } return accepted;
    }

    public bool BeginShutdown(ShutdownReason reason, ulong finalRevision)
    {
        if (IsClosing()) { return false; }
        return BeginShutdownCore(reason, finalRevision);
    }

    private bool BeginShutdownCore(ShutdownReason reason, ulong finalRevision)
    {
        if (_shutdownRequested || _transport == null || _transport.GetHealth() != TrayHostHealth.Ready) { return false; }
        _shutdownRequested = true; _transport.MarkStopping();
        bool accepted = _transport.TryEnqueueControl(new TrayHostControl(TrayHostControlKind.Shutdown, reason, finalRevision));
        if (accepted) { SignalWork(); } return accepted;
    }

    public bool WaitForStopped(TimeSpan timeout) { try { return _stopped.WaitOne(timeout); } catch (ObjectDisposedException) { return true; } }
    public bool WaitForActivity(TimeSpan timeout) { if (IsDisposing()) { return false; } try { return _work.WaitOne(timeout); } catch (ObjectDisposedException) { return false; } }
    public TrayHostHealth GetHealth() { return _transport == null ? TrayHostHealth.Stopped : _transport.GetHealth(); }

    private void WriterLoop()
    {
        try
        {
            while (!IsDisposing())
            {
                _work.WaitOne(250);
                TrayHostOutbound outbound;
                while (!IsDisposing() && _transport.TryDequeueOutbound(out outbound))
                {
                    if (outbound.Kind == TrayHostOutboundKind.Presentation) { WriteAuthenticated(TrayHostMessageType.Presentation, TrayHostWire.WritePresentation(outbound.Presentation)); }
                    else if (outbound.Kind == TrayHostOutboundKind.Action) { WriteAuthenticated(TrayHostMessageType.Action, TrayHostWire.WriteAction(outbound.Action)); }
                    else if (outbound.Kind == TrayHostOutboundKind.ActionResult) { WriteAuthenticated(TrayHostMessageType.ActionResult, TrayHostWire.WriteActionResult(outbound.ActionResult)); }
                    else { WriteControl(outbound.Control); }
                }
            }
        }
        catch (Exception error) { if (IsDisposing() || _shutdownRequested) { SignalStopped(); } else { HandleTransportFailure(error); } }
    }

    private void WriteControl(TrayHostControl control)
    {
        if (control.Kind == TrayHostControlKind.Shutdown) { WriteAuthenticated(TrayHostMessageType.Shutdown, TrayHostWire.WriteShutdown(control.Reason, control.Revision)); }
        else if (control.Kind == TrayHostControlKind.Ping) { WriteAuthenticated(TrayHostMessageType.Ping, new byte[0]); }
    }

    private void ReaderLoop()
    {
        try
        {
            while (!IsDisposing())
            {
                ProtocolFrame frame = ReadAuthenticated();
                if (frame.MessageType == TrayHostMessageType.PresentationAck) { EnqueueEvent(TrayHostEvent.Ack(TrayHostWire.ReadRevision(frame.Payload))); }
                else if (frame.MessageType == TrayHostMessageType.Action) { EnqueueEvent(TrayHostEvent.Action(TrayHostWire.ReadAction(frame.Payload))); }
                else if (frame.MessageType == TrayHostMessageType.ShutdownAck) { EnqueueEvent(TrayHostEvent.Exited()); _transport.Dispose(); SignalStopped(); return; }
                else if (frame.MessageType == TrayHostMessageType.Fault) { EnqueueEvent(TrayHostEvent.Fault("CCOD_TRAYHOST_REMOTE_FAULT")); }
                else if (frame.MessageType == TrayHostMessageType.Pong) { _work.Set(); }
            }
        }
        catch (Exception error)
        {
            if (IsDisposing()) { InvokeTestHook(TestBeforeReaderStopSignal); SignalStopped(); }
            else if (!_shutdownRequested) { HandleTransportFailure(error); }
            else { SignalStopped(); }
        }
    }

    private void StderrLoop()
    {
        try
        {
            byte[] buffer = new byte[1024]; int read;
            while (!IsDisposing() && (read = _childError.Read(buffer, 0, buffer.Length)) > 0) { byte[] copy = new byte[read]; Buffer.BlockCopy(buffer, 0, copy, 0, read); _transport.RecordStderr(copy); }
        }
        catch { }
    }

    private void WriteAuthenticated(TrayHostMessageType type, byte[] payload)
    {
        lock (_writeGate)
        {
            ProtocolCodec.WriteAuthenticated(_childInput, ProtocolFrame.Authenticated(ProtocolDirection.ParentToHost, type, _keys.HostEpoch, _writeSequence++, payload), _keys.ParentToHost);
        }
    }

    private ProtocolFrame ReadAuthenticated()
    {
        return ProtocolCodec.ReadAuthenticated(_childOutput, ProtocolDirection.HostToParent, _keys.HostEpoch, _readSequence++, _keys.HostToParent);
    }

    private bool IsDisposing() { return Volatile.Read(ref _disposed) != 0; }
    private bool IsClosing() { return Volatile.Read(ref _disposeGate) != 0; }
    private void SignalWork() { try { _work.Set(); } catch (ObjectDisposedException) { } }
    private void SignalStopped() { try { _stopped.Set(); } catch (ObjectDisposedException) { } }
    private static void InvokeTestHook(Action hook) { if (hook != null) { hook(); } }
    private void EnqueueEvent(TrayHostEvent value) { lock (_eventGate) { if (_events.Count < 32) { _events.Enqueue(value); } } SignalWork(); }
    private void HandleTransportFailure(Exception error)
    {
        if (IsDisposing()) { SignalStopped(); return; }
        _transport.MarkPipeBroken("CCOD_TRAYHOST_TRANSPORT_FAILED"); EnqueueEvent(TrayHostEvent.Fault("CCOD_TRAYHOST_TRANSPORT_FAILED")); SignalStopped();
    }

    private bool JoinBackgroundThreads(TimeSpan timeout)
    {
        DateTime deadline = DateTime.UtcNow.Add(timeout); bool complete = true;
        foreach (Thread thread in new Thread[] { _writerThread, _readerThread, _stderrThread })
        {
            if (thread == null || thread == Thread.CurrentThread || !thread.IsAlive) { continue; }
            int remaining = (int)Math.Max(0, (deadline - DateTime.UtcNow).TotalMilliseconds);
            if (remaining == 0 || !thread.Join(remaining)) { complete = false; }
        }
        return complete;
    }

    private static void ValidateOptions(TrayHostStartOptions options)
    {
        if (options == null || String.IsNullOrEmpty(options.ExePath) || !Path.IsPathRooted(options.ExePath) || !File.Exists(options.ExePath) || options.InitialPresentation == null || options.ParentPid <= 0 || options.ParentCreationFileTimeUtc <= 0 || String.IsNullOrEmpty(options.RuntimeId) || !Regex.IsMatch(options.RuntimeId, "^[A-Za-z0-9._-]{1,128}$", RegexOptions.CultureInvariant)) { throw new ArgumentException("CCOD_TRAYHOST_OPTIONS_INVALID"); }
    }

    public void Dispose()
    {
        if (Interlocked.CompareExchange(ref _disposeGate, 1, 0) != 0) { return; }
        if (!_shutdownRequested && _transport != null && _transport.GetHealth() == TrayHostHealth.Ready) { BeginShutdownCore(ShutdownReason.ParentFault, 1UL); }
        if (_shutdownRequested) { _stopped.WaitOne(TimeSpan.FromSeconds(2)); }
        Interlocked.Exchange(ref _disposed, 1);
        SignalWork();
        try { if (_job != null) { _job.Terminate(1U); } } catch { }
        try { if (_childInput != null) { _childInput.Close(); } } catch { }
        try { if (_childOutput != null) { _childOutput.Close(); } } catch { }
        try { if (_childError != null) { _childError.Close(); } } catch { }
        try { if (_process != null && !_process.HasExited) { _process.WaitForExit(2000); } } catch { }
        bool workersStopped = JoinBackgroundThreads(TimeSpan.FromSeconds(2));
        try { if (_job != null) { _job.Dispose(); } } catch { }
        try { if (_process != null) { _process.Dispose(); } } catch { }
        if (_transport != null) { _transport.Dispose(); }
        if (workersStopped)
        {
            InvokeTestHook(TestBeforeWaitHandleDispose);
            _work.Dispose(); _stopped.Dispose();
        }
    }
}
