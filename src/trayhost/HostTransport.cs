using System;
using System.Collections.Generic;

internal sealed class HostTransport : IDisposable
{
    private sealed class PendingAction
    {
        internal TrayHostAction Action;
        internal bool Accepted;
    }

    private readonly object _gate = new object();
    private readonly Queue<TrayHostControl> _controls = new Queue<TrayHostControl>();
    private readonly Dictionary<Guid, PendingAction> _pendingActions = new Dictionary<Guid, PendingAction>();
    private readonly Queue<Guid> _recentActionOrder = new Queue<Guid>();
    private readonly HashSet<Guid> _recentActions = new HashSet<Guid>();
    private PresentationSnapshot _pendingPresentation;
    private bool _menuOpen;
    private bool _disposed;

    internal void SetMenuOpen(bool value)
    {
        lock (_gate) { if (!_disposed) { _menuOpen = value; } }
    }

    internal bool TryAcceptPresentation(PresentationSnapshot snapshot)
    {
        if (snapshot == null) { return false; }
        lock (_gate)
        {
            if (_disposed) { return false; }
            if (_pendingPresentation == null || snapshot.Revision >= _pendingPresentation.Revision) { _pendingPresentation = snapshot; }
            return true;
        }
    }

    internal bool TryTakePresentation(out PresentationSnapshot snapshot)
    {
        lock (_gate)
        {
            if (_menuOpen || _pendingPresentation == null) { snapshot = null; return false; }
            snapshot = _pendingPresentation;
            _pendingPresentation = null;
            if (_controls.Count >= 16) { throw new InvalidOperationException("host control queue is exhausted"); }
            _controls.Enqueue(new TrayHostControl(TrayHostControlKind.PresentationAck, ShutdownReason.SupervisorExit, snapshot.Revision));
            return true;
        }
    }

    internal bool TryRegisterAction(TrayHostAction action)
    {
        if (action == null) { return false; }
        lock (_gate)
        {
            if (_disposed || _recentActions.Contains(action.ActionId) || _pendingActions.Count >= 8) { return false; }
            _recentActions.Add(action.ActionId);
            _recentActionOrder.Enqueue(action.ActionId);
            while (_recentActionOrder.Count > 64) { _recentActions.Remove(_recentActionOrder.Dequeue()); }
            _pendingActions.Add(action.ActionId, new PendingAction { Action = action, Accepted = false });
            return true;
        }
    }

    internal bool TryAcknowledgeAction(TrayActionResult result)
    {
        if (result == null) { return false; }
        lock (_gate)
        {
            if (_disposed) { return false; }
            PendingAction pending;
            if (!_pendingActions.TryGetValue(result.ActionId, out pending) || pending.Action.Revision != result.Revision) { return false; }
            if (result.Status == TrayActionResultStatus.Accepted)
            {
                if (pending.Accepted || (TrayCommandPolicy.RequiresTransactionWhenAccepted(pending.Action.Command) && !result.TransactionId.HasValue)) { return false; }
                pending.Accepted = true;
                return true;
            }
            if (result.Status != TrayActionResultStatus.Completed && result.Status != TrayActionResultStatus.Rejected && result.Status != TrayActionResultStatus.Failed) { return false; }
            if (result.Status == TrayActionResultStatus.Completed && TrayCommandPolicy.RequiresAcceptedBeforeCompleted(pending.Action.Command) && !pending.Accepted) { return false; }
            _pendingActions.Remove(result.ActionId);
            return true;
        }
    }

    internal bool TryDequeueControl(out TrayHostControl control)
    {
        lock (_gate)
        {
            if (_controls.Count == 0) { control = null; return false; }
            control = _controls.Dequeue();
            return true;
        }
    }

    public void Dispose()
    {
        lock (_gate)
        {
            if (_disposed) { return; }
            _disposed = true;
            _controls.Clear();
            _pendingActions.Clear();
            _recentActions.Clear();
            _recentActionOrder.Clear();
            _pendingPresentation = null;
        }
    }
}
