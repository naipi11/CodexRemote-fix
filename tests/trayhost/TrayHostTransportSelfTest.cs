using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Threading;

internal static class TrayHostTransportSelfTest
{
    private static bool PersistTerminal(TrayTerminalDiagnostic record) { return true; }

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

    private static PresentationSnapshot Snapshot(ulong revision)
    {
        string[] strings = new string[16];
        for (int i = 0; i < strings.Length; i++) { strings[i] = "string-" + i; }
        return new PresentationSnapshot(revision, TrayColor.Green, ConnectionState.Connected, ProtectionState.Running, LanguageMode.Chinese, PresentationFlags.OpenLogsEnabled, strings);
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
        AssertTrue(transport.TryAcknowledgeAction(new TrayActionResult(actionId, 2UL, TrayActionResultStatus.Completed, null, null)), "terminal non-lifecycle result clears the pending action");
        for (int i = 0; i < 63; i++)
        {
            Guid next = Guid.NewGuid();
            AssertTrue(transport.TryRegisterAction(new TrayHostAction(next, TrayCommand.OpenLogs, 2UL)), "replay cache accepts distinct ids");
            AssertTrue(transport.TryAcknowledgeAction(new TrayActionResult(next, 2UL, TrayActionResultStatus.Completed, null, null)), "terminal non-lifecycle result drains independently");
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
        AssertTrue(!host.TryAcknowledgeAction(new TrayActionResult(actionId, 12UL, TrayActionResultStatus.Accepted, null, null)), "lifecycle accepted result requires its durable transaction id");
        TrayActionResult accepted = new TrayActionResult(actionId, 12UL, TrayActionResultStatus.Accepted, null, transactionId);
        AssertTrue(host.TryAcknowledgeAction(accepted), "host accepts the correlated accepted result");
        AssertTrue(!host.TryAcknowledgeAction(accepted), "host rejects a duplicate accepted result");
        AssertTrue(!host.TryAcknowledgeAction(new TrayActionResult(Guid.NewGuid(), 12UL, TrayActionResultStatus.Completed, null, transactionId)), "host rejects a result for an unknown action id");
        AssertTrue(!host.TryAcknowledgeAction(new TrayActionResult(actionId, 99UL, TrayActionResultStatus.Completed, null, transactionId)), "host rejects a result with the wrong revision");
        AssertTrue(host.TryAcknowledgeAction(new TrayActionResult(actionId, 12UL, TrayActionResultStatus.Completed, null, transactionId)), "host accepts the correlated terminal result after accepted");
        AssertTrue(!host.TryAcknowledgeAction(new TrayActionResult(actionId, 12UL, TrayActionResultStatus.Completed, null, transactionId)), "host rejects a double terminal result");
        Guid prematureId = Guid.NewGuid();
        AssertTrue(host.TryRegisterAction(new TrayHostAction(prematureId, TrayCommand.CheckAndRepair, 13UL)), "second lifecycle action registers");
        AssertTrue(!host.TryAcknowledgeAction(new TrayActionResult(prematureId, 13UL, TrayActionResultStatus.Completed, null, null)), "lifecycle completion before accepted is rejected");
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

    private static void TestAcknowledgedAboutQueuesOneUiWorkItem()
    {
        HostTransport host = new HostTransport(null, PersistTerminal); Guid actionId = Guid.NewGuid();
        AssertTrue(host.TryRegisterAction(new TrayHostAction(actionId, TrayCommand.ShowAbout, 14UL)), "About action registers");
        AssertTrue(host.TryAcknowledgeAction(new TrayActionResult(actionId, 14UL, TrayActionResultStatus.Completed, null, null)), "verified About completion is accepted");
        TrayActionResult result;
        AssertTrue(host.TryTakeCompletedAbout(out result) && result.ActionId == actionId && result.Status == TrayActionResultStatus.Completed, "verified About completion queues one UI work item");
        AssertTrue(!host.TryTakeCompletedAbout(out result), "About UI work item is consumed exactly once");
        host.Dispose();
    }

    private static void TestRejectedAndFailedActionsQueueUserFeedback()
    {
        HostTransport host = new HostTransport(null, PersistTerminal);
        Guid rejectedId = Guid.NewGuid(); Guid failedId = Guid.NewGuid();
        AssertTrue(host.TryRegisterAction(new TrayHostAction(rejectedId, TrayCommand.OpenLogs, 20UL)), "rejected action registers");
        AssertTrue(host.TryRegisterAction(new TrayHostAction(failedId, TrayCommand.SetLanguageEnglish, 20UL)), "failed action registers");
        AssertTrue(host.TryAcknowledgeAction(new TrayActionResult(rejectedId, 20UL, TrayActionResultStatus.Rejected, "CCOD_TRAY_ACTION_UNAVAILABLE", null)), "correlated rejected result is accepted");
        AssertTrue(host.TryAcknowledgeAction(new TrayActionResult(failedId, 20UL, TrayActionResultStatus.Failed, "CCOD_TRAY_ACTION_FAILED", null)), "correlated failed result is accepted");
        TrayActionResult first; TrayActionResult second; TrayActionResult none;
        AssertTrue(host.TryTakeFailedAction(out first) && first.ActionId == rejectedId && first.Revision == 20UL && first.Status == TrayActionResultStatus.Rejected && String.Equals(first.ErrorCode, "CCOD_TRAY_ACTION_UNAVAILABLE", StringComparison.Ordinal), "rejected result preserves its exact correlated terminal record before generic feedback");
        AssertTrue(host.TryTakeFailedAction(out second) && second.ActionId == failedId && second.Revision == 20UL && second.Status == TrayActionResultStatus.Failed && String.Equals(second.ErrorCode, "CCOD_TRAY_ACTION_FAILED", StringComparison.Ordinal), "failed result preserves its exact correlated terminal record before generic feedback");
        AssertTrue(!host.TryTakeFailedAction(out none), "each terminal failure queues feedback exactly once");
        host.Dispose();
    }

    private static void TestUndisplayedActionFailureFeedbackIsBounded()
    {
        HostTransport host = new HostTransport(null, PersistTerminal);
        for (int index = 0; index < 9; index++)
        {
            Guid actionId = Guid.NewGuid();
            AssertTrue(host.TryRegisterAction(new TrayHostAction(actionId, TrayCommand.OpenLogs, 21UL)), "terminal failure releases pending action capacity");
            bool accepted = host.TryAcknowledgeAction(new TrayActionResult(actionId, 21UL, TrayActionResultStatus.Failed, "CCOD_TRAY_ACTION_FAILED", null));
            AssertTrue(accepted, "bounded undisplayed feedback never strands an authenticated terminal action");
        }
        host.Dispose();
    }

    private static void TestTerminalDiagnosticFailureNeverStrandsPendingActions()
    {
        HostTransport missingWriter = new HostTransport();
        Guid missingWriterId = Guid.NewGuid();
        AssertTrue(missingWriter.TryRegisterAction(new TrayHostAction(missingWriterId, TrayCommand.OpenLogs, 22UL)), "action registers without a diagnostic writer");
        AssertTrue(missingWriter.TryAcknowledgeAction(new TrayActionResult(missingWriterId, 22UL, TrayActionResultStatus.Failed, "CCOD_TRAY_ACTION_FAILED", null)), "missing diagnostic writer still releases the authenticated terminal action");
        TrayActionResult missingWriterFeedback;
        AssertTrue(!missingWriter.TryTakeFailedAction(out missingWriterFeedback), "missing diagnostic writer cannot authorize generic feedback");
        missingWriter.Dispose();

        bool persist = false;
        List<TrayTerminalDiagnostic> records = new List<TrayTerminalDiagnostic>();
        HostTransport host = new HostTransport(null, delegate(TrayTerminalDiagnostic record) { records.Add(record); return persist; });
        for (int index = 0; index < 10; index++)
        {
            Guid actionId = Guid.NewGuid();
            AssertTrue(host.TryRegisterAction(new TrayHostAction(actionId, TrayCommand.OpenLogs, 22UL)), "diagnostic failure never consumes pending-action capacity");
            AssertTrue(host.TryAcknowledgeAction(new TrayActionResult(actionId, 22UL, TrayActionResultStatus.Failed, "CCOD_TRAY_ACTION_FAILED", null)), "authenticated terminal result releases its pending action even when local persistence fails");
            TrayActionResult suppressed;
            AssertTrue(!host.TryTakeFailedAction(out suppressed), "generic feedback is suppressed when its local terminal diagnostic did not persist");
        }
        persist = true;
        Guid recoveredId = Guid.NewGuid();
        AssertTrue(host.TryRegisterAction(new TrayHostAction(recoveredId, TrayCommand.OpenLogs, 22UL)), "new action registers after repeated diagnostic failures");
        AssertTrue(host.TryAcknowledgeAction(new TrayActionResult(recoveredId, 22UL, TrayActionResultStatus.Failed, "CCOD_TRAY_ACTION_FAILED", null)), "recovered diagnostic persistence accepts a new terminal result");
        TrayActionResult recoveredFeedback;
        AssertTrue(host.TryTakeFailedAction(out recoveredFeedback) && recoveredFeedback.ActionId == recoveredId, "generic feedback resumes only after local terminal persistence recovers");
        Guid completedId = Guid.NewGuid();
        AssertTrue(host.TryRegisterAction(new TrayHostAction(completedId, TrayCommand.OpenLogs, 22UL)), "post-recovery command can still register");
        AssertTrue(host.TryAcknowledgeAction(new TrayActionResult(completedId, 22UL, TrayActionResultStatus.Completed, null, null)), "post-recovery command can complete");
        TrayTerminalDiagnostic last = records[records.Count - 1];
        AssertTrue(last.Command == TrayCommand.OpenLogs && last.Revision == 22UL && last.Status == TrayActionResultStatus.Completed && String.Equals(last.Code, "CCOD_TRAY_ACTION_COMPLETED", StringComparison.Ordinal), "terminal diagnostic exposes only the exact canonical correlation fields");
        host.Dispose();
    }

    private static void TestBlockingTerminalWriterRunsOutsideCorrelationLock()
    {
        ManualResetEvent writerEntered = new ManualResetEvent(false);
        ManualResetEvent releaseWriter = new ManualResetEvent(false);
        bool first = true;
        HostTransport host = new HostTransport(null, delegate(TrayTerminalDiagnostic record)
        {
            if (first) { first = false; writerEntered.Set(); releaseWriter.WaitOne(TimeSpan.FromSeconds(3)); }
            return true;
        });
        Guid blockedId = Guid.NewGuid();
        AssertTrue(host.TryRegisterAction(new TrayHostAction(blockedId, TrayCommand.OpenLogs, 24UL)), "blocking-writer action registers");
        bool acknowledged = false;
        Thread acknowledgement = new Thread((ThreadStart)delegate { acknowledged = host.TryAcknowledgeAction(new TrayActionResult(blockedId, 24UL, TrayActionResultStatus.Failed, "CCOD_TRAY_ACTION_FAILED", null)); });
        acknowledgement.IsBackground = true;
        acknowledgement.Start();
        try
        {
            AssertTrue(writerEntered.WaitOne(TimeSpan.FromSeconds(2)), "terminal writer enters deterministically");
            Guid concurrentId = Guid.NewGuid();
            Stopwatch registration = Stopwatch.StartNew();
            bool registered = host.TryRegisterAction(new TrayHostAction(concurrentId, TrayCommand.OpenLogs, 24UL));
            registration.Stop();
            AssertTrue(registered && registration.Elapsed < TimeSpan.FromMilliseconds(250), "blocking terminal I/O cannot hold the correlation lock or pending capacity");
            releaseWriter.Set();
            AssertTrue(acknowledgement.Join(TimeSpan.FromSeconds(2)) && acknowledged, "terminal acknowledgement completes after the writer is released");
            AssertTrue(host.TryAcknowledgeAction(new TrayActionResult(concurrentId, 24UL, TrayActionResultStatus.Completed, null, null)), "concurrent action remains independently completable");
        }
        finally
        {
            releaseWriter.Set();
            if (acknowledgement.IsAlive) { acknowledgement.Join(TimeSpan.FromSeconds(2)); }
            writerEntered.Dispose(); releaseWriter.Dispose(); host.Dispose();
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
            TestAcknowledgedAboutQueuesOneUiWorkItem();
            TestRejectedAndFailedActionsQueueUserFeedback();
            TestUndisplayedActionFailureFeedbackIsBounded();
            TestTerminalDiagnosticFailureNeverStrandsPendingActions();
            TestBlockingTerminalWriterRunsOutsideCorrelationLock();
            Console.WriteLine("TrayHost transport self-tests passed: 10");
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
