using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Reflection;
using System.Threading;

internal static class TrayHostTransportSelfTest
{
    private enum ReceiptStoreBlockStage
    {
        None = 0,
        BeforeOpen = 1,
        DuringWrite = 2,
        DuringFlush = 3
    }

    private sealed class ControllableReceiptStore : IDisposable
    {
        private readonly object _gate = new object();
        private readonly ReceiptStoreBlockStage _blockStage;
        private readonly Queue<int> _outcomes = new Queue<int>();
        private readonly HashSet<int> _writerThreads = new HashSet<int>();
        private readonly ManualResetEvent _entered = new ManualResetEvent(false);
        private readonly ManualResetEvent _release = new ManualResetEvent(false);
        private int _active;
        private int _callCount;
        private int _completedCount;
        private int _maximumConcurrent;

        internal ControllableReceiptStore(ReceiptStoreBlockStage blockStage, params int[] outcomes)
        {
            _blockStage = blockStage;
            if (outcomes != null) { for (int index = 0; index < outcomes.Length; index++) { _outcomes.Enqueue(outcomes[index]); } }
        }

        internal bool TryAppendDurably(TrayTerminalDiagnostic record)
        {
            if (record == null) { return false; }
            int call = Interlocked.Increment(ref _callCount);
            int active = Interlocked.Increment(ref _active);
            lock (_gate)
            {
                _writerThreads.Add(Thread.CurrentThread.ManagedThreadId);
                if (active > _maximumConcurrent) { _maximumConcurrent = active; }
            }
            try
            {
                BlockAt(call, ReceiptStoreBlockStage.BeforeOpen);
                BlockAt(call, ReceiptStoreBlockStage.DuringWrite);
                BlockAt(call, ReceiptStoreBlockStage.DuringFlush);
                int outcome = 1;
                lock (_gate) { if (_outcomes.Count != 0) { outcome = _outcomes.Dequeue(); } }
                if (outcome < 0) { throw new InvalidOperationException("intentional receipt-store failure"); }
                return outcome > 0;
            }
            finally
            {
                Interlocked.Decrement(ref _active);
                Interlocked.Increment(ref _completedCount);
            }
        }

        internal bool WaitUntilBlocked(int milliseconds) { return _entered.WaitOne(milliseconds); }
        internal void Release() { _release.Set(); }
        internal int CallCount { get { return Interlocked.CompareExchange(ref _callCount, 0, 0); } }
        internal int CompletedCount { get { return Interlocked.CompareExchange(ref _completedCount, 0, 0); } }
        internal int MaximumConcurrent { get { lock (_gate) { return _maximumConcurrent; } } }
        internal int WriterThreadCount { get { lock (_gate) { return _writerThreads.Count; } } }

        private void BlockAt(int call, ReceiptStoreBlockStage stage)
        {
            if (call != 1 || _blockStage != stage) { return; }
            _entered.Set();
            _release.WaitOne();
        }

        public void Dispose()
        {
            _release.Set();
            _entered.Dispose();
            _release.Dispose();
        }
    }

    private static void AssertTrue(bool value, string message)
    {
        if (!value) { throw new InvalidOperationException(message); }
    }

    private static void AssertThrows(Action action, string message)
    {
        bool threw = false;
        try { action(); } catch (ArgumentException) { threw = true; }
        AssertTrue(threw, message);
    }

    private static void AssertReturnsQuickly(Stopwatch elapsed, string message)
    {
        AssertTrue(elapsed.Elapsed < TimeSpan.FromMilliseconds(250), message + " elapsedMs=" + elapsed.ElapsedMilliseconds.ToString());
    }

    private static void WaitUntil(Func<bool> condition, int milliseconds, string message)
    {
        Stopwatch elapsed = Stopwatch.StartNew();
        bool satisfied = condition();
        while (!satisfied && elapsed.ElapsedMilliseconds < milliseconds) { Thread.Sleep(5); satisfied = condition(); }
        AssertTrue(satisfied, message);
    }

    private static PresentationSnapshot Snapshot(ulong revision)
    {
        string[] strings = new string[16];
        for (int i = 0; i < strings.Length; i++) { strings[i] = "string-" + i; }
        return new PresentationSnapshot(revision, TrayColor.Green, ConnectionState.Connected, ProtectionState.Running, LanguageMode.Chinese, PresentationFlags.OpenLogsEnabled, strings);
    }

    private static bool TryAcknowledge(HostTransport host, TrayActionResult result)
    {
        TrayTerminalReceipt ignored;
        return host.TryAcknowledgeAction(result, out ignored);
    }

    private static TrayTerminalReceipt AcknowledgeTerminalQuickly(HostTransport host, TrayActionResult result, string message)
    {
        TrayTerminalReceipt receipt;
        Stopwatch elapsed = Stopwatch.StartNew();
        bool accepted = host.TryAcknowledgeAction(result, out receipt);
        elapsed.Stop();
        AssertTrue(accepted && receipt != null, message + " is correlated into a typed receipt");
        AssertReturnsQuickly(elapsed, message + " never waits for receipt storage");
        return receipt;
    }

    private static TrayTerminalReceipt RegisterAndAcknowledgeFailure(HostTransport host, Guid actionId, ulong revision, string message)
    {
        AssertTrue(host.TryRegisterAction(new TrayHostAction(actionId, TrayCommand.OpenLogs, revision)), message + " registers");
        return AcknowledgeTerminalQuickly(host, new TrayActionResult(actionId, revision, TrayActionResultStatus.Failed, "CCOD_TRAY_ACTION_FAILED", null), message);
    }

    private static void TestParentLatestAndReservedControl()
    {
        ParentTransport transport = new ParentTransport();
        AssertTrue(transport.TrySetLatestPresentation(Snapshot(1)), "first presentation accepted");
        AssertTrue(transport.TrySetLatestPresentation(Snapshot(2)), "latest presentation replaces pending state");
        PresentationSnapshot latest;
        AssertTrue(transport.TryDequeueLatestPresentation(out latest) && latest.Revision == 2UL, "only newest presentation is dequeued");
        AssertTrue(transport.TryEnqueueAction(new TrayHostAction(Guid.NewGuid(), TrayCommand.OpenLogs, 2UL)), "first action accepted");
        for (int i = 0; i < 7; i++) { AssertTrue(transport.TryEnqueueAction(new TrayHostAction(Guid.NewGuid(), TrayCommand.OpenLogs, 2UL)), "action queue remains bounded through eight entries"); }
        AssertTrue(!transport.TryEnqueueAction(new TrayHostAction(Guid.NewGuid(), TrayCommand.OpenLogs, 2UL)), "ninth action is rejected");
        AssertTrue(transport.TryEnqueueControl(new TrayHostControl(TrayHostControlKind.Shutdown, ShutdownReason.SupervisorExit, 2UL)), "shutdown control is reserved");
        TrayHostOutbound outbound;
        AssertTrue(transport.TryDequeueOutbound(out outbound) && outbound.Kind == TrayHostOutboundKind.Control, "control drains before actions");
        transport.Dispose();
    }

    private static void TestBrokenPipeAndStderrCap()
    {
        ParentTransport transport = new ParentTransport();
        byte[] noise = new byte[8192];
        transport.RecordStderr(noise);
        AssertTrue(transport.StderrBytesRetained == 4096, "stderr diagnostic retention is capped at 4 KiB");
        transport.MarkPipeBroken("CCOD_PIPE_BROKEN");
        AssertTrue(transport.GetHealth() == TrayHostHealth.Faulted, "broken pipe enters faulted health");
        transport.Dispose();
    }

    private static void TestHostPendingAndReplayBound()
    {
        int releasedPresentationSignals = 0;
        HostTransport transport = new HostTransport(delegate { releasedPresentationSignals++; });
        transport.SetMenuOpen(true);
        AssertTrue(transport.TryAcceptPresentation(Snapshot(1)), "host accepts first presentation");
        AssertTrue(transport.TryAcceptPresentation(Snapshot(2)), "host coalesces a newer presentation while menu is open");
        PresentationSnapshot ignored;
        AssertTrue(!transport.TryTakePresentation(out ignored), "menu-open presentation is not applied early");
        transport.SetMenuOpen(false);
        AssertTrue(releasedPresentationSignals == 1, "menu close re-signals pending presentation work consumed by the nested menu loop");
        PresentationSnapshot newest;
        AssertTrue(transport.TryTakePresentation(out newest) && newest.Revision == 2UL, "menu close applies newest snapshot only");
        Guid actionId = Guid.NewGuid();
        AssertTrue(transport.TryRegisterAction(new TrayHostAction(actionId, TrayCommand.OpenLogs, 2UL)), "first action accepted");
        AssertTrue(!transport.TryRegisterAction(new TrayHostAction(actionId, TrayCommand.OpenLogs, 2UL)), "replayed action id is rejected");
        AssertTrue(TryAcknowledge(transport, new TrayActionResult(actionId, 2UL, TrayActionResultStatus.Completed, null, null)), "terminal non-lifecycle result clears the pending action");
        for (int i = 0; i < 63; i++)
        {
            Guid next = Guid.NewGuid();
            AssertTrue(transport.TryRegisterAction(new TrayHostAction(next, TrayCommand.OpenLogs, 2UL)), "replay cache accepts distinct ids");
            AssertTrue(TryAcknowledge(transport, new TrayActionResult(next, 2UL, TrayActionResultStatus.Completed, null, null)), "terminal non-lifecycle result drains independently");
        }
        AssertTrue(!transport.TryRegisterAction(new TrayHostAction(actionId, TrayCommand.OpenLogs, 2UL)), "the 64-entry replay cache rejects a replayed id");
        transport.Dispose();
    }

    private static void TestDirectPresentationAcksDoNotAccumulateAnUnusedControlQueue()
    {
        HostTransport transport = new HostTransport();
        for (ulong revision = 1UL; revision <= 40UL; revision++)
        {
            AssertTrue(transport.TryAcceptPresentation(Snapshot(revision)), "production presentation is accepted without a side-channel ACK queue");
            PresentationSnapshot applied;
            AssertTrue(transport.TryTakePresentation(out applied) && applied.Revision == revision, "production presentation remains available for the direct wire ACK path");
        }
        transport.Dispose();
    }

    private static void TestActionResultCorrelationAndControlPriority()
    {
        Guid actionId = Guid.NewGuid(); Guid transactionId = Guid.Parse("11111111-2222-3333-4444-555555555555");
        HostTransport host = new HostTransport();
        AssertTrue(host.TryRegisterAction(new TrayHostAction(actionId, TrayCommand.CheckAndRepair, 12UL)), "host registers one v2 lifecycle action");
        AssertTrue(!TryAcknowledge(host, new TrayActionResult(actionId, 12UL, TrayActionResultStatus.Accepted, null, null)), "lifecycle accepted result requires its durable transaction id");
        TrayActionResult accepted = new TrayActionResult(actionId, 12UL, TrayActionResultStatus.Accepted, null, transactionId);
        TrayTerminalReceipt terminal;
        AssertTrue(host.TryAcknowledgeAction(accepted, out terminal) && terminal == null, "host accepts the correlated nonterminal accepted result without a receipt");
        AssertTrue(!TryAcknowledge(host, accepted), "host rejects a duplicate accepted result");
        AssertTrue(!TryAcknowledge(host, new TrayActionResult(Guid.NewGuid(), 12UL, TrayActionResultStatus.Completed, null, transactionId)), "host rejects a result for an unknown action id");
        AssertTrue(!TryAcknowledge(host, new TrayActionResult(actionId, 99UL, TrayActionResultStatus.Completed, null, transactionId)), "host rejects a result with the wrong revision");
        AssertTrue(host.TryAcknowledgeAction(new TrayActionResult(actionId, 12UL, TrayActionResultStatus.Completed, null, transactionId), out terminal) && terminal != null, "host returns the correlated terminal receipt after accepted");
        AssertTrue(!TryAcknowledge(host, new TrayActionResult(actionId, 12UL, TrayActionResultStatus.Completed, null, transactionId)), "host rejects a double terminal result");
        Guid prematureId = Guid.NewGuid();
        AssertTrue(host.TryRegisterAction(new TrayHostAction(prematureId, TrayCommand.CheckAndRepair, 13UL)), "second lifecycle action registers");
        AssertTrue(!TryAcknowledge(host, new TrayActionResult(prematureId, 13UL, TrayActionResultStatus.Completed, null, null)), "lifecycle completion before accepted is rejected");
        AssertThrows(delegate { new TrayActionResult(Guid.NewGuid(), 1UL, TrayActionResultStatus.Rejected, "not-canonical", null); }, "invalid action result error code is rejected");
        AssertThrows(delegate { new TrayActionResult(Guid.NewGuid(), 1UL, TrayActionResultStatus.Completed, null, Guid.Empty); }, "empty action result transaction id is rejected");
        host.Dispose();

        ParentTransport parent = new ParentTransport();
        AssertTrue(parent.TryEnqueueAction(new TrayHostAction(Guid.NewGuid(), TrayCommand.OpenLogs, 12UL)), "parent queues a normal action behind reserved controls");
        AssertTrue(parent.TryEnqueueActionResult(accepted), "parent queues one correlated action result");
        AssertTrue(!parent.TryEnqueueActionResult(accepted), "parent permits only one pending result per action id");
        for (int index = 0; index < 7; index++) { AssertTrue(parent.TryEnqueueActionResult(new TrayActionResult(Guid.NewGuid(), 12UL, TrayActionResultStatus.Completed, null, null)), "action result queue remains bounded through eight entries"); }
        AssertTrue(!parent.TryEnqueueActionResult(new TrayActionResult(Guid.NewGuid(), 12UL, TrayActionResultStatus.Completed, null, null)), "ninth pending action result is rejected without consuming control capacity");
        AssertTrue(parent.TryEnqueueControl(new TrayHostControl(TrayHostControlKind.Shutdown, ShutdownReason.SupervisorExit, 12UL)), "shutdown remains available after the action-result queue fills");
        TrayHostOutbound outbound;
        AssertTrue(parent.TryDequeueOutbound(out outbound) && outbound.Kind == TrayHostOutboundKind.Control && outbound.Control.Kind == TrayHostControlKind.Shutdown, "reserved shutdown control drains before action results");
        AssertTrue(parent.TryDequeueOutbound(out outbound) && outbound.Kind == TrayHostOutboundKind.ActionResult, "action result drains after reserved controls and before ordinary traffic");
        AssertTrue(parent.TryEnqueueActionResult(new TrayActionResult(actionId, 12UL, TrayActionResultStatus.Completed, null, transactionId)), "terminal result queues after the accepted result drains");
        parent.Dispose();
    }

    private static void TestBlockedReceiptStagesNeverBlockCorrelationOrUi()
    {
        ReceiptStoreBlockStage[] stages = new ReceiptStoreBlockStage[] { ReceiptStoreBlockStage.BeforeOpen, ReceiptStoreBlockStage.DuringWrite, ReceiptStoreBlockStage.DuringFlush };
        for (int stageIndex = 0; stageIndex < stages.Length; stageIndex++)
        {
            ControllableReceiptStore store = new ControllableReceiptStore(stages[stageIndex], 1, 1);
            int uiSignals = 0;
            HostTransport host = new HostTransport(delegate { Interlocked.Increment(ref uiSignals); });
            TrayTerminalReceiptSink sink = new TrayTerminalReceiptSink(store.TryAppendDurably, host.TryPublishDurableReceipt);
            try
            {
                Guid firstId = Guid.NewGuid(); Guid followingId = Guid.NewGuid();
                TrayTerminalReceipt first = RegisterAndAcknowledgeFailure(host, firstId, 24UL, stages[stageIndex].ToString() + " current terminal result");
                Stopwatch firstSubmit = Stopwatch.StartNew(); bool firstAdmitted = sink.TrySubmit(first); firstSubmit.Stop();
                AssertTrue(firstAdmitted, "current receipt is admitted before the fake store blocks " + stages[stageIndex].ToString());
                AssertReturnsQuickly(firstSubmit, "current receipt admission is zero-wait");
                AssertTrue(store.WaitUntilBlocked(2000), "fake store reaches " + stages[stageIndex].ToString());

                AssertTrue(host.TryRegisterAction(new TrayHostAction(followingId, TrayCommand.ShowAbout, 24UL)), stages[stageIndex].ToString() + " following About action registers");
                TrayTerminalReceipt following = AcknowledgeTerminalQuickly(host, new TrayActionResult(followingId, 24UL, TrayActionResultStatus.Completed, null, null), stages[stageIndex].ToString() + " following About terminal result");
                Stopwatch followingSubmit = Stopwatch.StartNew(); bool followingAdmitted = sink.TrySubmit(following); followingSubmit.Stop();
                AssertTrue(followingAdmitted, "following receipt is admitted while the store is blocked " + stages[stageIndex].ToString());
                AssertReturnsQuickly(followingSubmit, "following receipt admission never waits for the current store operation");
                TrayTerminalReceipt duplicate;
                AssertTrue(!host.TryAcknowledgeAction(new TrayActionResult(firstId, 24UL, TrayActionResultStatus.Failed, "CCOD_TRAY_ACTION_FAILED", null), out duplicate), "current terminal action is removed before sink submission");
                AssertTrue(!host.TryAcknowledgeAction(new TrayActionResult(followingId, 24UL, TrayActionResultStatus.Completed, null, null), out duplicate), "following terminal action is removed before sink submission");
                TrayActionResult prematureFailure; TrayActionResult prematureAbout;
                AssertTrue(!host.TryTakeFailedAction(out prematureFailure) && !host.TryTakeCompletedAbout(out prematureAbout) && Interlocked.CompareExchange(ref uiSignals, 0, 0) == 0, "blocked store exposes no generic or About UI work before durable success");

                store.Release();
                WaitUntil(delegate { return Interlocked.CompareExchange(ref uiSignals, 0, 0) == 2; }, 2000, "both durable successes post exactly one work signal");
                TrayActionResult firstUi; TrayActionResult followingUi; TrayActionResult none;
                firstUi = null; followingUi = null;
                WaitUntil(delegate { return host.TryTakeFailedAction(out firstUi); }, 2000, "first durable receipt becomes visible after its callback succeeds");
                WaitUntil(delegate { return host.TryTakeCompletedAbout(out followingUi); }, 2000, "following durable About becomes visible after its callback succeeds");
                AssertTrue(firstUi.ActionId == firstId, "first durable receipt publishes its exact generic-feedback item");
                AssertTrue(followingUi.ActionId == followingId, "following durable receipt publishes its exact About item");
                AssertTrue(!host.TryTakeFailedAction(out none), "durable callbacks publish no duplicate feedback");
                AssertTrue(store.WriterThreadCount == 1 && store.MaximumConcurrent == 1, "all blocked stages are serviced by exactly one non-overlapping writer");
            }
            finally
            {
                store.Release();
                sink.Dispose();
                host.Dispose();
                store.Dispose();
            }
        }
    }

    private static void TestNinthReceiptAndBusyAdmissionDropWithoutPendingOrUi()
    {
        ControllableReceiptStore store = new ControllableReceiptStore(ReceiptStoreBlockStage.BeforeOpen, 1);
        HostTransport host = new HostTransport();
        TrayTerminalReceiptSink sink = new TrayTerminalReceiptSink(store.TryAppendDurably, host.TryPublishDurableReceipt);
        try
        {
            TrayTerminalReceipt first = RegisterAndAcknowledgeFailure(host, Guid.NewGuid(), 25UL, "first hung-store action");
            AssertTrue(sink.TrySubmit(first), "current receipt occupies the first outstanding slot");
            AssertTrue(store.WaitUntilBlocked(2000), "single writer enters the hung fake store");
            for (int index = 1; index < 8; index++)
            {
                TrayTerminalReceipt queued = RegisterAndAcknowledgeFailure(host, Guid.NewGuid(), 25UL, "queued outstanding action " + index.ToString());
                AssertTrue(sink.TrySubmit(queued), "outstanding receipt slots include current plus seven queued items");
            }

            Guid ninthId = Guid.NewGuid();
            TrayTerminalReceipt ninth = RegisterAndAcknowledgeFailure(host, ninthId, 25UL, "ninth full-sink action");
            Stopwatch ninthSubmit = Stopwatch.StartNew(); bool ninthAdmitted = sink.TrySubmit(ninth); ninthSubmit.Stop();
            AssertTrue(!ninthAdmitted, "ninth outstanding receipt is dropped");
            AssertReturnsQuickly(ninthSubmit, "ninth outstanding admission is rejected immediately");
            TrayTerminalReceipt duplicate;
            AssertTrue(!host.TryAcknowledgeAction(new TrayActionResult(ninthId, 25UL, TrayActionResultStatus.Failed, "CCOD_TRAY_ACTION_FAILED", null), out duplicate), "full-sink terminal action remains consumed");
            for (int index = 0; index < 8; index++)
            {
                Guid droppedId = Guid.NewGuid();
                TrayTerminalReceipt dropped = RegisterAndAcknowledgeFailure(host, droppedId, 25UL, "additional full-sink action " + index.ToString());
                AssertTrue(!sink.TrySubmit(dropped), "repeated full-sink paths drop only receipt feedback");
            }
            for (int index = 0; index < 8; index++)
            {
                Guid capacityId = Guid.NewGuid();
                AssertTrue(host.TryRegisterAction(new TrayHostAction(capacityId, TrayCommand.OpenLogs, 25UL)), "receipt saturation never consumes pending action capacity");
                AssertTrue(TryAcknowledge(host, new TrayActionResult(capacityId, 25UL, TrayActionResultStatus.Completed, null, null)), "capacity proof action remains terminally consumable");
            }
            AssertTrue(store.CallCount == 1 && store.WriterThreadCount == 1 && store.MaximumConcurrent == 1, "hung writer is never replaced");
            TrayActionResult none;
            AssertTrue(!host.TryTakeFailedAction(out none), "full and hung paths show no UI");

            FieldInfo gateField = typeof(TrayTerminalReceiptSink).GetField("_gate", BindingFlags.Instance | BindingFlags.NonPublic);
            AssertTrue(gateField != null, "busy-admission fixture locates the sink admission gate");
            object admissionGate = gateField.GetValue(sink);
            ManualResetEvent gateHeld = new ManualResetEvent(false); ManualResetEvent releaseGate = new ManualResetEvent(false);
            Thread holder = new Thread((ThreadStart)delegate { lock (admissionGate) { gateHeld.Set(); releaseGate.WaitOne(); } });
            holder.IsBackground = true; holder.Start();
            try
            {
                AssertTrue(gateHeld.WaitOne(2000), "busy-admission fixture holds the sink gate");
                Guid busyId = Guid.NewGuid();
                TrayTerminalReceipt busy = RegisterAndAcknowledgeFailure(host, busyId, 25UL, "busy-sink action");
                bool busyReturned = false; bool busyAdmitted = true;
                Thread submitter = new Thread((ThreadStart)delegate { busyAdmitted = sink.TrySubmit(busy); busyReturned = true; });
                submitter.IsBackground = true; submitter.Start();
                AssertTrue(submitter.Join(250) && busyReturned && !busyAdmitted, "busy admission returns immediately without waiting for the gate");
                AssertTrue(!host.TryAcknowledgeAction(new TrayActionResult(busyId, 25UL, TrayActionResultStatus.Failed, "CCOD_TRAY_ACTION_FAILED", null), out duplicate), "busy-sink terminal action remains consumed");
                AssertTrue(!host.TryTakeFailedAction(out none), "busy admission shows no UI");
            }
            finally
            {
                releaseGate.Set(); holder.Join(2000); gateHeld.Dispose(); releaseGate.Dispose();
            }
        }
        finally
        {
            store.Release();
            sink.Dispose();
            host.Dispose();
            store.Dispose();
        }
    }

    private static void TestStoreAndCallbackFailuresRecoverOnTheSameWriter()
    {
        ControllableReceiptStore store = new ControllableReceiptStore(ReceiptStoreBlockStage.DuringFlush, 0, 1, 1);
        bool failCallback = true; int successfulSignals = 0;
        HostTransport host = new HostTransport(delegate
        {
            if (failCallback) { failCallback = false; throw new InvalidOperationException("intentional UI callback failure"); }
            Interlocked.Increment(ref successfulSignals);
        });
        TrayTerminalReceiptSink sink = new TrayTerminalReceiptSink(store.TryAppendDurably, host.TryPublishDurableReceipt);
        try
        {
            Guid storeFailureId = Guid.NewGuid(); Guid callbackFailureId = Guid.NewGuid(); Guid recoveredId = Guid.NewGuid();
            AssertTrue(sink.TrySubmit(RegisterAndAcknowledgeFailure(host, storeFailureId, 26UL, "store-failure action")), "first receipt is admitted before the store failure");
            AssertTrue(store.WaitUntilBlocked(2000), "first receipt blocks during the simulated flush");
            AssertTrue(sink.TrySubmit(RegisterAndAcknowledgeFailure(host, callbackFailureId, 26UL, "callback-failure action")), "second receipt queues behind the first store failure");
            AssertTrue(sink.TrySubmit(RegisterAndAcknowledgeFailure(host, recoveredId, 26UL, "recovered action")), "third receipt queues for recovery");
            TrayActionResult none;
            AssertTrue(!host.TryTakeFailedAction(out none), "blocked and not-yet-durable receipts expose no UI");
            store.Release();
            WaitUntil(delegate { return store.CompletedCount == 3 && Interlocked.CompareExchange(ref successfulSignals, 0, 0) == 1; }, 3000, "same writer continues through store and callback failures to a later success");
            TrayActionResult recovered; TrayActionResult extra;
            recovered = null;
            WaitUntil(delegate { return host.TryTakeFailedAction(out recovered); }, 2000, "later durable callback makes its recovered feedback visible");
            AssertTrue(recovered.ActionId == recoveredId, "only the later durable callback publishes generic feedback");
            AssertTrue(!host.TryTakeFailedAction(out extra), "store and callback failures publish no latent UI");
            AssertTrue(store.WriterThreadCount == 1 && store.MaximumConcurrent == 1, "recovery keeps the original single writer instead of starting a replacement");
        }
        finally
        {
            store.Release(); sink.Dispose(); host.Dispose(); store.Dispose();
        }
    }

    private static void TestDurableReceiptTrustAndSharedUiBound()
    {
        int signals = 0;
        HostTransport host = new HostTransport(delegate { Interlocked.Increment(ref signals); });
        HostTransport foreign = new HostTransport();
        try
        {
            Guid aboutId = Guid.NewGuid();
            AssertTrue(host.TryRegisterAction(new TrayHostAction(aboutId, TrayCommand.ShowAbout, 27UL)), "About action registers for durable authorization");
            TrayTerminalReceipt about = AcknowledgeTerminalQuickly(host, new TrayActionResult(aboutId, 27UL, TrayActionResultStatus.Completed, null, null), "About terminal result");
            TrayActionResult beforeDurable;
            AssertTrue(!host.TryTakeCompletedAbout(out beforeDurable), "typed receipt alone cannot expose About UI before durable publication");
            AssertTrue(!foreign.TryPublishDurableReceipt(about), "a different transport rejects a receipt it did not correlate");
            AssertTrue(host.TryPublishDurableReceipt(about), "originating transport accepts one explicit durable-success callback");
            AssertTrue(!host.TryPublishDurableReceipt(about), "the same durable receipt cannot publish twice");

            for (int index = 0; index < 7; index++)
            {
                TrayTerminalReceipt failure = RegisterAndAcknowledgeFailure(host, Guid.NewGuid(), 27UL, "bounded UI failure " + index.ToString());
                AssertTrue(host.TryPublishDurableReceipt(failure), "shared UI queue admits through eight total items");
            }
            TrayTerminalReceipt overflow = RegisterAndAcknowledgeFailure(host, Guid.NewGuid(), 27UL, "bounded UI overflow");
            AssertTrue(!host.TryPublishDurableReceipt(overflow), "ninth shared About/failure UI item is dropped");

            Guid noUiId = Guid.NewGuid();
            AssertTrue(host.TryRegisterAction(new TrayHostAction(noUiId, TrayCommand.OpenLogs, 27UL)), "non-UI completion registers while UI work is full");
            TrayTerminalReceipt noUi = AcknowledgeTerminalQuickly(host, new TrayActionResult(noUiId, 27UL, TrayActionResultStatus.Completed, null, null), "non-UI completion");
            AssertTrue(host.TryPublishDurableReceipt(noUi), "durable non-UI completion is consumed without UI capacity");

            TrayActionResult aboutUi;
            AssertTrue(host.TryTakeCompletedAbout(out aboutUi) && aboutUi.ActionId == aboutId, "durable About maps to one About UI item");
            int failures = 0; TrayActionResult failed;
            while (host.TryTakeFailedAction(out failed)) { failures++; }
            AssertTrue(failures == 7, "About and generic failure share one eight-item UI bound");
            AssertTrue(Interlocked.CompareExchange(ref signals, 0, 0) == 8, "only admitted UI items post application work");
        }
        finally { foreign.Dispose(); host.Dispose(); }
    }

    private static void TestFailingCallbackNeverExposesProvisionalUiWork()
    {
        ManualResetEvent callbackEntered = new ManualResetEvent(false);
        ManualResetEvent releaseCallback = new ManualResetEvent(false);
        HostTransport host = new HostTransport(delegate
        {
            callbackEntered.Set();
            releaseCallback.WaitOne();
            throw new InvalidOperationException("intentional UI callback failure");
        });
        try
        {
            TrayTerminalReceipt receipt = RegisterAndAcknowledgeFailure(host, Guid.NewGuid(), 29UL, "provisional callback-failure action");
            bool published = true;
            Thread publisher = new Thread((ThreadStart)delegate { published = host.TryPublishDurableReceipt(receipt); });
            publisher.IsBackground = true; publisher.Start();
            AssertTrue(callbackEntered.WaitOne(2000), "durable UI callback enters before failing");
            TrayActionResult provisional = null; bool takeReturned = false; bool tookProvisional = true;
            Thread taker = new Thread((ThreadStart)delegate { tookProvisional = host.TryTakeFailedAction(out provisional); takeReturned = true; });
            taker.IsBackground = true; taker.Start();
            AssertTrue(taker.Join(250) && takeReturned && !tookProvisional && provisional == null, "provisional UI work returns immediately but remains unavailable while callback outcome is unknown");
            releaseCallback.Set();
            AssertTrue(publisher.Join(2000) && !published, "throwing durable callback reports publication failure");
            TrayActionResult none;
            AssertTrue(!host.TryTakeFailedAction(out none), "callback failure leaves no latent generic UI work");
        }
        finally
        {
            releaseCallback.Set(); host.Dispose(); callbackEntered.Dispose(); releaseCallback.Dispose();
        }
    }

    private static void TestSuccessfulCallbackRepostsAfterAnEarlyUiProbe()
    {
        ManualResetEvent callbackEntered = new ManualResetEvent(false);
        ManualResetEvent releaseCallback = new ManualResetEvent(false);
        int callbackCount = 0;
        HostTransport host = new HostTransport(delegate
        {
            int call = Interlocked.Increment(ref callbackCount);
            if (call == 1) { callbackEntered.Set(); releaseCallback.WaitOne(); }
        });
        try
        {
            Guid actionId = Guid.NewGuid();
            TrayTerminalReceipt receipt = RegisterAndAcknowledgeFailure(host, actionId, 30UL, "early-probe durable action");
            bool published = false;
            Thread publisher = new Thread((ThreadStart)delegate { published = host.TryPublishDurableReceipt(receipt); });
            publisher.IsBackground = true; publisher.Start();
            AssertTrue(callbackEntered.WaitOne(2000), "first successful UI post is held before returning");
            TrayActionResult early;
            AssertTrue(!host.TryTakeFailedAction(out early), "work-message probe cannot consume provisional feedback");
            releaseCallback.Set();
            AssertTrue(publisher.Join(2000) && published, "durable publication succeeds after its first UI post returns");
            AssertTrue(Interlocked.CompareExchange(ref callbackCount, 0, 0) == 2, "an early work-message probe causes one replacement UI post");
            TrayActionResult ready; TrayActionResult none;
            AssertTrue(host.TryTakeFailedAction(out ready) && ready.ActionId == actionId, "replacement post observes the now-ready durable feedback");
            AssertTrue(!host.TryTakeFailedAction(out none), "replacement posting never duplicates the UI item");
        }
        finally
        {
            releaseCallback.Set(); host.Dispose(); callbackEntered.Dispose(); releaseCallback.Dispose();
        }
    }

    private static void TestReplacementCallbackFailureDropsReadyUiWork()
    {
        ManualResetEvent callbackEntered = new ManualResetEvent(false);
        ManualResetEvent releaseCallback = new ManualResetEvent(false);
        int callbackCount = 0;
        HostTransport host = new HostTransport(delegate
        {
            int call = Interlocked.Increment(ref callbackCount);
            if (call == 1) { callbackEntered.Set(); releaseCallback.WaitOne(); return; }
            throw new InvalidOperationException("intentional replacement UI callback failure");
        });
        try
        {
            TrayTerminalReceipt receipt = RegisterAndAcknowledgeFailure(host, Guid.NewGuid(), 31UL, "replacement-callback failure action");
            bool published = true;
            Thread publisher = new Thread((ThreadStart)delegate { published = host.TryPublishDurableReceipt(receipt); });
            publisher.IsBackground = true; publisher.Start();
            AssertTrue(callbackEntered.WaitOne(2000), "first UI post is held before replacement-failure probe");
            TrayActionResult early;
            AssertTrue(!host.TryTakeFailedAction(out early), "replacement-failure probe cannot consume provisional feedback");
            releaseCallback.Set();
            AssertTrue(publisher.Join(2000) && !published, "replacement callback failure reports publication failure");
            TrayActionResult none;
            AssertTrue(!host.TryTakeFailedAction(out none), "replacement callback failure removes the ready-but-unnotified UI item");
            AssertTrue(Interlocked.CompareExchange(ref callbackCount, 0, 0) == 2, "replacement callback is attempted exactly once");
        }
        finally
        {
            releaseCallback.Set(); host.Dispose(); callbackEntered.Dispose(); releaseCallback.Dispose();
        }
    }

    private static void TestDisposalReturnsWhileStoreIsHungAndSuppressesLateCallbacks()
    {
        ControllableReceiptStore store = new ControllableReceiptStore(ReceiptStoreBlockStage.BeforeOpen, 1);
        int signals = 0;
        HostTransport host = new HostTransport(delegate { Interlocked.Increment(ref signals); });
        TrayTerminalReceiptSink sink = new TrayTerminalReceiptSink(store.TryAppendDurably, host.TryPublishDurableReceipt);
        try
        {
            TrayTerminalReceipt current = RegisterAndAcknowledgeFailure(host, Guid.NewGuid(), 28UL, "dispose-hung current action");
            AssertTrue(sink.TrySubmit(current), "dispose-hung receipt is admitted");
            AssertTrue(store.WaitUntilBlocked(2000), "writer is hung before sink disposal");
            Stopwatch disposal = Stopwatch.StartNew(); sink.Dispose(); disposal.Stop();
            AssertReturnsQuickly(disposal, "sink disposal uses a bounded join when the only writer is hung");

            Guid closedId = Guid.NewGuid();
            TrayTerminalReceipt closed = RegisterAndAcknowledgeFailure(host, closedId, 28UL, "closed-sink action");
            Stopwatch closedSubmit = Stopwatch.StartNew(); bool closedAdmitted = sink.TrySubmit(closed); closedSubmit.Stop();
            AssertTrue(!closedAdmitted, "disposed sink rejects new receipts");
            AssertReturnsQuickly(closedSubmit, "closed admission is immediate");
            TrayTerminalReceipt duplicate;
            AssertTrue(!host.TryAcknowledgeAction(new TrayActionResult(closedId, 28UL, TrayActionResultStatus.Failed, "CCOD_TRAY_ACTION_FAILED", null), out duplicate), "closed-sink action remains terminally consumed");

            store.Release();
            WaitUntil(delegate { return store.CompletedCount == 1; }, 2000, "hung store can return after disposal without reviving the sink");
            Stopwatch finalJoin = Stopwatch.StartNew(); sink.Dispose(); finalJoin.Stop();
            AssertReturnsQuickly(finalJoin, "disposed sink remains bounded while joining its original completed writer");
            TrayActionResult none;
            AssertTrue(Interlocked.CompareExchange(ref signals, 0, 0) == 0 && !host.TryTakeFailedAction(out none), "late durable return after disposal cannot publish UI");
            AssertTrue(store.CallCount == 1 && store.WriterThreadCount == 1, "disposal never starts a replacement writer");
        }
        finally
        {
            store.Release(); sink.Dispose(); host.Dispose(); store.Dispose();
        }
    }

    public static int Main(string[] args)
    {
        try
        {
            TestParentLatestAndReservedControl();
            TestBrokenPipeAndStderrCap();
            TestHostPendingAndReplayBound();
            TestDirectPresentationAcksDoNotAccumulateAnUnusedControlQueue();
            TestActionResultCorrelationAndControlPriority();
            TestBlockedReceiptStagesNeverBlockCorrelationOrUi();
            TestNinthReceiptAndBusyAdmissionDropWithoutPendingOrUi();
            TestStoreAndCallbackFailuresRecoverOnTheSameWriter();
            TestDurableReceiptTrustAndSharedUiBound();
            TestFailingCallbackNeverExposesProvisionalUiWork();
            TestSuccessfulCallbackRepostsAfterAnEarlyUiProbe();
            TestReplacementCallbackFailureDropsReadyUiWork();
            TestDisposalReturnsWhileStoreIsHungAndSuppressesLateCallbacks();
            Console.WriteLine("TrayHost transport self-tests passed: 13");
            return 0;
        }
        catch (Exception error)
        {
            Console.Error.WriteLine("TrayHost transport self-test failed: " + error.GetType().FullName);
            Console.Error.WriteLine(error.Message);
            return 1;
        }
    }
}
