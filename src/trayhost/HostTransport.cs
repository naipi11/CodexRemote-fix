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
    private readonly Action _presentationReady;
    private readonly Queue<TrayActionResult> _completedAbout = new Queue<TrayActionResult>();
    private readonly Queue<TrayActionResult> _failedActions = new Queue<TrayActionResult>();
    private readonly Dictionary<Guid, PendingAction> _pendingActions = new Dictionary<Guid, PendingAction>();
    private readonly Queue<Guid> _recentActionOrder = new Queue<Guid>();
    private readonly HashSet<Guid> _recentActions = new HashSet<Guid>();
    private PresentationSnapshot _pendingPresentation;
    private bool _menuOpen;
    private bool _disposed;

    internal HostTransport() : this(null)
    {
    }

    internal HostTransport(Action presentationReady)
    {
        _presentationReady = presentationReady;
    }

    internal void SetMenuOpen(bool value)
    {
        bool notify = false;
        lock (_gate)
        {
            if (!_disposed)
            {
                bool wasOpen = _menuOpen;
                _menuOpen = value;
                notify = wasOpen && !value && _pendingPresentation != null;
            }
        }
        Action presentationReady = _presentationReady;
        if (notify && presentationReady != null) { presentationReady(); }
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
            if ((result.Status == TrayActionResultStatus.Rejected || result.Status == TrayActionResultStatus.Failed) && _failedActions.Count >= 8) { return false; }
            _pendingActions.Remove(result.ActionId);
            if (result.Status == TrayActionResultStatus.Completed && pending.Action.Command == TrayCommand.ShowAbout) { _completedAbout.Enqueue(result); }
            if (result.Status == TrayActionResultStatus.Rejected || result.Status == TrayActionResultStatus.Failed) { _failedActions.Enqueue(result); }
            return true;
        }
    }

    internal bool TryTakeCompletedAbout(out TrayActionResult result)
    {
        lock (_gate)
        {
            if (_completedAbout.Count == 0) { result = null; return false; }
            result = _completedAbout.Dequeue(); return true;
        }
    }

    internal bool TryTakeFailedAction(out TrayActionResult result)
    {
        lock (_gate)
        {
            if (_failedActions.Count == 0) { result = null; return false; }
            result = _failedActions.Dequeue(); return true;
        }
    }

    public void Dispose()
    {
        lock (_gate)
        {
            if (_disposed) { return; }
            _disposed = true;
            _completedAbout.Clear();
            _failedActions.Clear();
            _pendingActions.Clear();
            _recentActions.Clear();
            _recentActionOrder.Clear();
            _pendingPresentation = null;
        }
    }
}
