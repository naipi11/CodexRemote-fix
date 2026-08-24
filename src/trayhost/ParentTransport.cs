using System;
using System.Collections.Generic;

internal sealed class ParentTransport : IDisposable
{
    private readonly object _gate = new object();
    private readonly Queue<TrayHostControl> _controls = new Queue<TrayHostControl>();
    private readonly Queue<TrayHostAction> _actions = new Queue<TrayHostAction>();
    private readonly Queue<TrayActionResult> _actionResults = new Queue<TrayActionResult>();
    private readonly HashSet<Guid> _pendingActionResults = new HashSet<Guid>();
    private PresentationSnapshot _latestPresentation;
    private TrayHostHealth _health = TrayHostHealth.Starting;
    private string _faultCode = String.Empty;
    private int _stderrBytesRetained;
    private bool _disposed;

    internal int StderrBytesRetained { get { lock (_gate) { return _stderrBytesRetained; } } }
    internal string FaultCode { get { lock (_gate) { return _faultCode; } } }

    internal bool TrySetLatestPresentation(PresentationSnapshot snapshot)
    {
        if (snapshot == null) { return false; }
        lock (_gate)
        {
            if (_disposed || _health == TrayHostHealth.Faulted || _health == TrayHostHealth.Stopped) { return false; }
            if (_latestPresentation == null || snapshot.Revision >= _latestPresentation.Revision) { _latestPresentation = snapshot; }
            return true;
        }
    }

    internal bool TryDequeueLatestPresentation(out PresentationSnapshot snapshot)
    {
        lock (_gate)
        {
            snapshot = _latestPresentation;
            _latestPresentation = null;
            return snapshot != null;
        }
    }

    internal bool TryEnqueueControl(TrayHostControl control)
    {
        if (control == null) { return false; }
        lock (_gate)
        {
            if (_disposed || _health == TrayHostHealth.Stopped) { return false; }
            if (_controls.Count >= 16) { return false; }
            _controls.Enqueue(control);
            return true;
        }
    }

    internal bool TryEnqueueAction(TrayHostAction action)
    {
        if (action == null) { return false; }
        lock (_gate)
        {
            if (_disposed || _health == TrayHostHealth.Faulted || _health == TrayHostHealth.Stopped || _actions.Count >= 8) { return false; }
            _actions.Enqueue(action);
            return true;
        }
    }

    internal bool TryEnqueueActionResult(TrayActionResult result)
    {
        if (result == null) { return false; }
        lock (_gate)
        {
            if (_disposed || _health == TrayHostHealth.Faulted || _health == TrayHostHealth.Stopped || _actionResults.Count >= 8 || _pendingActionResults.Contains(result.ActionId)) { return false; }
            _pendingActionResults.Add(result.ActionId);
            _actionResults.Enqueue(result);
            return true;
        }
    }

    internal bool TryDequeueOutbound(out TrayHostOutbound outbound)
    {
        lock (_gate)
        {
            if (_controls.Count > 0) { outbound = TrayHostOutbound.FromControl(_controls.Dequeue()); return true; }
            if (_actionResults.Count > 0) { TrayActionResult result = _actionResults.Dequeue(); _pendingActionResults.Remove(result.ActionId); outbound = TrayHostOutbound.FromActionResult(result); return true; }
            if (_latestPresentation != null) { outbound = TrayHostOutbound.FromPresentation(_latestPresentation); _latestPresentation = null; return true; }
            if (_actions.Count > 0) { outbound = TrayHostOutbound.FromAction(_actions.Dequeue()); return true; }
            outbound = null;
            return false;
        }
    }

    internal void RecordStderr(byte[] bytes)
    {
        if (bytes == null) { return; }
        lock (_gate) { _stderrBytesRetained = Math.Min(4096, _stderrBytesRetained + bytes.Length); }
    }

    internal void MarkPipeBroken(string errorCode)
    {
        lock (_gate)
        {
            if (_disposed) { return; }
            _health = TrayHostHealth.Faulted;
            _faultCode = errorCode ?? "CCOD_PIPE_BROKEN";
        }
    }

    internal TrayHostHealth GetHealth() { lock (_gate) { return _health; } }
    internal void MarkReady() { lock (_gate) { if (!_disposed && _health == TrayHostHealth.Starting) { _health = TrayHostHealth.Ready; } } }
    internal void MarkStopping() { lock (_gate) { if (!_disposed && _health != TrayHostHealth.Faulted) { _health = TrayHostHealth.Stopping; } } }

    public void Dispose()
    {
        lock (_gate)
        {
            if (_disposed) { return; }
            _disposed = true;
            _health = TrayHostHealth.Stopped;
            _controls.Clear();
            _actions.Clear();
            _actionResults.Clear();
            _pendingActionResults.Clear();
            _latestPresentation = null;
        }
    }
}
