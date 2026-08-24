using System;
using System.Collections.Generic;

internal static class TrayHostTransportSelfTest
{
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
        HostTransport transport = new HostTransport();
        transport.SetMenuOpen(true);
        AssertTrue(transport.TryAcceptPresentation(Snapshot(1)), "host accepts first presentation");
        AssertTrue(transport.TryAcceptPresentation(Snapshot(2)), "host coalesces a newer presentation while menu is open");
        PresentationSnapshot ignored;
        AssertTrue(!transport.TryTakePresentation(out ignored), "menu-open presentation is not applied early");
        transport.SetMenuOpen(false);
        PresentationSnapshot newest;
        AssertTrue(transport.TryTakePresentation(out newest) && newest.Revision == 2UL, "menu close applies newest snapshot only");
        TrayHostControl control;
        AssertTrue(transport.TryDequeueControl(out control) && control.Kind == TrayHostControlKind.PresentationAck && control.Revision == 2UL, "one ack is emitted for the applied revision");
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
        HostTransport host = new HostTransport(); Guid actionId = Guid.NewGuid();
        AssertTrue(host.TryRegisterAction(new TrayHostAction(actionId, TrayCommand.ShowAbout, 14UL)), "About action registers");
        AssertTrue(host.TryAcknowledgeAction(new TrayActionResult(actionId, 14UL, TrayActionResultStatus.Completed, null, null)), "verified About completion is accepted");
        TrayActionResult result;
        AssertTrue(host.TryTakeCompletedAbout(out result) && result.ActionId == actionId && result.Status == TrayActionResultStatus.Completed, "verified About completion queues one UI work item");
        AssertTrue(!host.TryTakeCompletedAbout(out result), "About UI work item is consumed exactly once");
        host.Dispose();
    }

    public static int Main(string[] args)
    {
        try
        {
            TestParentLatestAndReservedControl();
            TestBrokenPipeAndStderrCap();
            TestHostPendingAndReplayBound();
            TestActionResultCorrelationAndControlPriority();
            TestAcknowledgedAboutQueuesOneUiWorkItem();
            Console.WriteLine("TrayHost transport self-tests passed: 5");
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
