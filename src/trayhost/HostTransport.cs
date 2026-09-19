using System;
using System.Collections.Generic;

internal enum TrayTerminalReceiptUiKind : byte
{
    About = 1,
    Failure = 2
}

internal sealed class HostTransport : IDisposable
{
    private sealed class PendingAction
    {
        internal TrayHostAction Action;
        internal bool Accepted;
    }

    private sealed class UiWorkItem
    {
        internal uint Token;
        internal TrayTerminalReceiptUiKind Kind;
        internal TrayActionResult Result;
        internal bool Committed;
        internal bool DeliveryObserved;
    }

    private const int MaximumUiWork = 8;
    private const int MaximumTokenPostAttempts = 2;
    private readonly object _gate = new object();
    private readonly Action _presentationReady;
    private readonly Func<uint, bool> _receiptReady;
    private readonly Dictionary<uint, UiWorkItem> _receiptUi = new Dictionary<uint, UiWorkItem>();
    private readonly Dictionary<Guid, PendingAction> _pendingActions = new Dictionary<Guid, PendingAction>();
    private readonly Queue<Guid> _recentActionOrder = new Queue<Guid>();
    private readonly HashSet<Guid> _recentActions = new HashSet<Guid>();
    private PresentationSnapshot _pendingPresentation;
    private uint _nextReceiptToken = unchecked((uint)Guid.NewGuid().GetHashCode());
    private bool _menuOpen;
    private bool _disposed;

    internal HostTransport() : this(null, null)
    {
    }

    internal HostTransport(Action presentationReady) : this(presentationReady, null)
    {
    }

    internal HostTransport(Action presentationReady, Func<uint, bool> receiptReady)
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
        Func<uint, bool> receiptReady = _receiptReady;
        lock (_gate)
        {
            if (_disposed || !receipt.TryClaimPublication(this)) { return false; }
            TrayActionResult result = receipt.Result;
            TrayTerminalReceiptUiKind kind;
            if (result.Status == TrayActionResultStatus.Completed && receipt.Command == TrayCommand.ShowAbout) { kind = TrayTerminalReceiptUiKind.About; }
            else if (result.Status == TrayActionResultStatus.Rejected || result.Status == TrayActionResultStatus.Failed) { kind = TrayTerminalReceiptUiKind.Failure; }
            else { return true; }
            if (receiptReady == null || _receiptUi.Count >= MaximumUiWork) { return false; }
            uint token = NextReceiptTokenLocked();
            if (token == 0U) { return false; }
            work = new UiWorkItem { Token = token, Kind = kind, Result = result };
            _receiptUi.Add(token, work);
        }

        for (int attempt = 0; attempt < MaximumTokenPostAttempts; attempt++)
        {
            bool posted = false;
            try { posted = receiptReady(work.Token); }
            catch { posted = false; }
            if (!posted) { DropUiWork(work); return false; }
            lock (_gate)
            {
                UiWorkItem current;
                if (_disposed || !_receiptUi.TryGetValue(work.Token, out current) || !Object.ReferenceEquals(current, work)) { return false; }
                if (!work.DeliveryObserved)
                {
                    work.Committed = true;
                    return true;
                }
                work.DeliveryObserved = false;
            }
        }

        DropUiWork(work);
        return false;
    }

    internal bool TryTakeReceiptUi(uint token, out TrayTerminalReceiptUiKind kind, out TrayActionResult result)
    {
        kind = 0; result = null;
        if (token == 0U) { return false; }
        lock (_gate)
        {
            if (_disposed) { return false; }
            UiWorkItem work;
            if (!_receiptUi.TryGetValue(token, out work)) { return false; }
            if (!work.Committed) { work.DeliveryObserved = true; return false; }
            _receiptUi.Remove(token);
            kind = work.Kind; result = work.Result;
            return true;
        }
    }

    internal bool TryTakeCompletedAbout(out TrayActionResult result)
    {
        result = null;
        return false;
    }

    internal bool TryTakeFailedAction(out TrayActionResult result)
    {
        result = null;
        return false;
    }

    public void Dispose()
    {
        lock (_gate)
        {
            if (_disposed) { return; }
            _disposed = true;
            _receiptUi.Clear();
            _pendingActions.Clear();
            _recentActions.Clear();
            _recentActionOrder.Clear();
            _pendingPresentation = null;
        }
    }

    private uint NextReceiptTokenLocked()
    {
        for (int attempt = 0; attempt < MaximumUiWork + 2; attempt++)
        {
            _nextReceiptToken = unchecked(_nextReceiptToken + 1U);
            if (_nextReceiptToken != 0U && !_receiptUi.ContainsKey(_nextReceiptToken)) { return _nextReceiptToken; }
        }
        return 0U;
    }

    private void DropUiWork(UiWorkItem target)
    {
        if (target == null) { return; }
        lock (_gate)
        {
            UiWorkItem current;
            if (_receiptUi.TryGetValue(target.Token, out current) && Object.ReferenceEquals(current, target)) { _receiptUi.Remove(target.Token); }
        }
    }
}
