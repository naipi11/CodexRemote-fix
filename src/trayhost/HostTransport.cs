using System;
using System.Collections.Generic;

internal sealed class HostTransport : IDisposable
{
    private sealed class PendingAction
    {
        internal TrayHostAction Action;
        internal bool Accepted;
    }

    private sealed class UiWorkItem
    {
        internal TrayActionResult Result;
        internal bool Ready;
        internal bool ProbeObserved;
    }

    private readonly object _gate = new object();
    private readonly Action _presentationReady;
    private readonly Action _receiptReady;
    private readonly Queue<UiWorkItem> _completedAbout = new Queue<UiWorkItem>();
    private readonly Queue<UiWorkItem> _failedActions = new Queue<UiWorkItem>();
    private readonly Dictionary<Guid, PendingAction> _pendingActions = new Dictionary<Guid, PendingAction>();
    private readonly Queue<Guid> _recentActionOrder = new Queue<Guid>();
    private readonly HashSet<Guid> _recentActions = new HashSet<Guid>();
    private PresentationSnapshot _pendingPresentation;
    private int _uiWorkCount;
    private bool _menuOpen;
    private bool _disposed;

    internal HostTransport() : this(null, null)
    {
    }

    internal HostTransport(Action presentationReady) : this(presentationReady, presentationReady)
    {
    }

    internal HostTransport(Action presentationReady, Action receiptReady)
    {
        _presentationReady = presentationReady;
        _receiptReady = receiptReady;
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

    internal bool TryAcknowledgeAction(TrayActionResult result, out TrayTerminalReceipt receipt)
    {
        receipt = null;
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
            receipt = new TrayTerminalReceipt(this, pending.Action.Command, result);
            _pendingActions.Remove(result.ActionId);
            return true;
        }
    }

    internal bool TryPublishDurableReceipt(TrayTerminalReceipt receipt)
    {
        if (receipt == null) { return false; }
        UiWorkItem work = null;
        Action receiptReady = _receiptReady;
        lock (_gate)
        {
            if (_disposed || !receipt.TryClaimPublication(this)) { return false; }
            TrayActionResult result = receipt.Result;
            if (result.Status == TrayActionResultStatus.Completed && receipt.Command == TrayCommand.ShowAbout)
            {
                if (_uiWorkCount >= 8) { return false; }
                work = new UiWorkItem { Result = result, Ready = receiptReady == null };
                _completedAbout.Enqueue(work);
                _uiWorkCount++;
            }
            else if (result.Status == TrayActionResultStatus.Rejected || result.Status == TrayActionResultStatus.Failed)
            {
                if (_uiWorkCount >= 8) { return false; }
                work = new UiWorkItem { Result = result, Ready = receiptReady == null };
                _failedActions.Enqueue(work);
                _uiWorkCount++;
            }
        }
        if (work == null || receiptReady == null) { return true; }
        try { receiptReady(); }
        catch
        {
            DropUiWork(work);
            return false;
        }
        bool repost;
        lock (_gate)
        {
            if (_disposed) { return false; }
            work.Ready = true;
            repost = work.ProbeObserved;
            work.ProbeObserved = false;
        }
        if (repost) { try { receiptReady(); } catch { } }
        return true;
    }

    private void DropUiWork(UiWorkItem target)
    {
        if (target == null) { return; }
        lock (_gate)
        {
            Queue<UiWorkItem> queue = target.Result.Status == TrayActionResultStatus.Completed ? _completedAbout : _failedActions;
            int count = queue.Count;
            bool removed = false;
            for (int index = 0; index < count; index++)
            {
                UiWorkItem current = queue.Dequeue();
                if (!removed && Object.ReferenceEquals(current, target)) { removed = true; }
                else { queue.Enqueue(current); }
            }
            if (removed && _uiWorkCount > 0) { _uiWorkCount--; }
        }
    }

    internal bool TryTakeCompletedAbout(out TrayActionResult result)
    {
        lock (_gate)
        {
            if (_completedAbout.Count == 0) { result = null; return false; }
            UiWorkItem work = _completedAbout.Peek();
            if (!work.Ready) { work.ProbeObserved = true; result = null; return false; }
            result = _completedAbout.Dequeue().Result;
            if (_uiWorkCount > 0) { _uiWorkCount--; }
            return true;
        }
    }

    internal bool TryTakeFailedAction(out TrayActionResult result)
    {
        lock (_gate)
        {
            if (_failedActions.Count == 0) { result = null; return false; }
            UiWorkItem work = _failedActions.Peek();
            if (!work.Ready) { work.ProbeObserved = true; result = null; return false; }
            result = _failedActions.Dequeue().Result;
            if (_uiWorkCount > 0) { _uiWorkCount--; }
            return true;
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
            _uiWorkCount = 0;
            _pendingActions.Clear();
            _recentActions.Clear();
            _recentActionOrder.Clear();
            _pendingPresentation = null;
        }
    }
}
