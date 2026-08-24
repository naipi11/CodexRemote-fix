using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Security.Cryptography;
using System.Threading;

internal static class TrayHostParentClientSelfTest
{
    private static string PeerArguments = "--peer";

    private static void AssertTrue(bool value, string message) { if (!value) { throw new InvalidOperationException(message); } }

    private static PresentationSnapshot Snapshot(ulong revision)
    {
        string[] strings = new string[16];
        for (int i = 0; i < strings.Length; i++) { strings[i] = "string-" + i; }
        return new PresentationSnapshot(revision, TrayColor.Green, ConnectionState.Connected, ProtectionState.Running, LanguageMode.Chinese, PresentationFlags.OpenLogsEnabled, strings);
    }

    private static Process StartPeer(ProcessStartInfo requested)
    {
        requested.Arguments = PeerArguments;
        requested.UseShellExecute = false;
        requested.CreateNoWindow = true;
        requested.RedirectStandardInput = true;
        requested.RedirectStandardOutput = true;
        requested.RedirectStandardError = true;
        return Process.Start(requested);
    }

    private static void RunPeer(bool emitFaultAndIgnoreShutdown, bool emitAction)
    {
        Stream input = Console.OpenStandardInput();
        Stream output = Console.OpenStandardOutput();
        ProtocolFrame parentHello = ProtocolCodec.ReadBootstrap(input, ProtocolDirection.ParentToHost);
        TrayHostHello hello = TrayHostWire.ReadParentHello(parentHello.Payload);
        byte[] hostNonce = new byte[32];
        using (RandomNumberGenerator rng = RandomNumberGenerator.Create()) { rng.GetBytes(hostNonce); }
        ulong epoch = 99UL;
        Process peerProcess = Process.GetCurrentProcess();
        ProtocolCodec.WriteBootstrap(output, ProtocolFrame.Bootstrap(ProtocolDirection.HostToParent, TrayHostMessageType.HostHello, TrayHostWire.WriteHostHello(peerProcess.Id, peerProcess.StartTime.ToFileTimeUtc(), hello.RuntimeId, hostNonce, epoch)));
        SessionKeys keys = ProtocolCodec.DeriveDirectionalKeys(hello.SessionSeed, hello.ParentChallenge, hostNonce, epoch);
        ProtocolFrame presentation = ProtocolCodec.ReadAuthenticated(input, ProtocolDirection.ParentToHost, epoch, 1UL, keys.ParentToHost);
        AssertTrue(presentation.MessageType == TrayHostMessageType.Presentation, "peer receives initial presentation");
        ProtocolCodec.WriteAuthenticated(output, ProtocolFrame.Authenticated(ProtocolDirection.HostToParent, TrayHostMessageType.PresentationAck, epoch, 1UL, TrayHostWire.WriteRevision(TrayHostWire.ReadPresentation(presentation.Payload).Revision)), keys.HostToParent);
        ProtocolCodec.WriteAuthenticated(output, ProtocolFrame.Authenticated(ProtocolDirection.HostToParent, TrayHostMessageType.UiReady, epoch, 2UL, TrayHostWire.WriteRevision(TrayHostWire.ReadPresentation(presentation.Payload).Revision)), keys.HostToParent);
        ulong inboundSequence = 2UL;
        ulong outboundSequence = 3UL;
        if (emitAction)
        {
            Guid actionId = Guid.Parse("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee");
            Guid transactionId = Guid.Parse("11111111-2222-3333-4444-555555555555");
            ProtocolCodec.WriteAuthenticated(output, ProtocolFrame.Authenticated(ProtocolDirection.HostToParent, TrayHostMessageType.Action, epoch, outboundSequence++, TrayHostWire.WriteAction(new TrayHostAction(actionId, TrayCommand.CheckAndRepair, 1UL))), keys.HostToParent);
            ProtocolFrame acceptedFrame = ProtocolCodec.ReadAuthenticated(input, ProtocolDirection.ParentToHost, epoch, inboundSequence++, keys.ParentToHost);
            AssertTrue(acceptedFrame.MessageType == TrayHostMessageType.ActionResult, "peer receives one parent action result");
            TrayActionResult accepted = TrayHostWire.ReadActionResult(acceptedFrame.Payload);
            AssertTrue(accepted.ActionId == actionId && accepted.Revision == 1UL && accepted.Status == TrayActionResultStatus.Accepted && accepted.TransactionId.HasValue && accepted.TransactionId.Value == transactionId, "peer receives the correlated accepted result");
            ProtocolFrame completedFrame = ProtocolCodec.ReadAuthenticated(input, ProtocolDirection.ParentToHost, epoch, inboundSequence++, keys.ParentToHost);
            AssertTrue(completedFrame.MessageType == TrayHostMessageType.ActionResult, "peer receives one parent terminal result");
            TrayActionResult completed = TrayHostWire.ReadActionResult(completedFrame.Payload);
            AssertTrue(completed.ActionId == actionId && completed.Status == TrayActionResultStatus.Completed && completed.TransactionId.HasValue && completed.TransactionId.Value == transactionId, "peer receives the correlated completed result");
            return;
        }
        if (emitFaultAndIgnoreShutdown)
        {
            ProtocolCodec.WriteAuthenticated(output, ProtocolFrame.Authenticated(ProtocolDirection.HostToParent, TrayHostMessageType.Fault, epoch, outboundSequence++, new byte[0]), keys.HostToParent);
        }
        while (true)
        {
            ProtocolFrame frame = ProtocolCodec.ReadAuthenticated(input, ProtocolDirection.ParentToHost, epoch, inboundSequence++, keys.ParentToHost);
            if (frame.MessageType == TrayHostMessageType.Shutdown)
            {
                if (emitFaultAndIgnoreShutdown) { Thread.Sleep(Timeout.Infinite); }
                ProtocolCodec.WriteAuthenticated(output, ProtocolFrame.Authenticated(ProtocolDirection.HostToParent, TrayHostMessageType.ShutdownAck, epoch, outboundSequence++, frame.Payload), keys.HostToParent);
                return;
            }
            if (frame.MessageType == TrayHostMessageType.Presentation)
            {
                ProtocolCodec.WriteAuthenticated(output, ProtocolFrame.Authenticated(ProtocolDirection.HostToParent, TrayHostMessageType.PresentationAck, epoch, outboundSequence++, TrayHostWire.WriteRevision(TrayHostWire.ReadPresentation(frame.Payload).Revision)), keys.HostToParent);
            }
            else if (frame.MessageType == TrayHostMessageType.Ping)
            {
                ProtocolCodec.WriteAuthenticated(output, ProtocolFrame.Authenticated(ProtocolDirection.HostToParent, TrayHostMessageType.Pong, epoch, outboundSequence++, frame.Payload), keys.HostToParent);
            }
        }
    }

    private static TrayHostStartOptions Options()
    {
        Process current = Process.GetCurrentProcess();
        return new TrayHostStartOptions {
            ExePath = current.MainModule.FileName,
            RuntimeId = "test-runtime",
            ParentPid = current.Id,
            ParentCreationFileTimeUtc = current.StartTime.ToFileTimeUtc(),
            InitialPresentation = Snapshot(1UL)
        };
    }

    private static void TestDisposeRequestsGracefulShutdown()
    {
        PeerArguments = "--peer";
        TrayHostParentClient client = TrayHostParentClient.Start(Options());
        Stopwatch stopwatch = Stopwatch.StartNew();
        client.Dispose();
        stopwatch.Stop();
        AssertTrue(stopwatch.Elapsed < TimeSpan.FromSeconds(1), "Dispose sends a graceful shutdown before tearing down the tray host transport");
    }

    private static void TestDisposeAfterRemoteFaultDoesNotCrashParentReader()
    {
        PeerArguments = "--fault-peer";
        FieldInfo readerHook = typeof(TrayHostParentClient).GetField("TestBeforeReaderStopSignal", BindingFlags.Static | BindingFlags.NonPublic);
        FieldInfo waitHandleDisposeHook = typeof(TrayHostParentClient).GetField("TestBeforeWaitHandleDispose", BindingFlags.Static | BindingFlags.NonPublic);
        AssertTrue(readerHook != null && waitHandleDisposeHook != null, "parent client exposes the disposal-race synchronization hooks");
        ManualResetEvent readerBlocked = new ManualResetEvent(false);
        ManualResetEvent releaseReader = new ManualResetEvent(false);
        ManualResetEvent waitHandleDisposeStarted = new ManualResetEvent(false);
        TrayHostParentClient client = null;
        Thread disposer = null;
        Exception disposeError = null;
        try
        {
            readerHook.SetValue(null, (Action)delegate { readerBlocked.Set(); releaseReader.WaitOne(TimeSpan.FromSeconds(3)); });
            waitHandleDisposeHook.SetValue(null, (Action)delegate { waitHandleDisposeStarted.Set(); });
            client = TrayHostParentClient.Start(Options());
            bool faultReceived = false;
            DateTime deadline = DateTime.UtcNow.AddSeconds(2);
            while (!faultReceived && DateTime.UtcNow < deadline)
            {
                client.WaitForActivity(TimeSpan.FromMilliseconds(100));
                TrayHostEvent value;
                while (client.TryDequeueEvent(out value)) { if (value.Kind == TrayHostEventKind.Fault) { faultReceived = true; } }
            }
            AssertTrue(faultReceived, "fault peer reaches the parent reader before disposal");
            TrayHostParentClient closingClient = client;
            disposer = new Thread((ThreadStart)delegate { try { closingClient.Dispose(); } catch (Exception error) { disposeError = error; } });
            disposer.IsBackground = true;
            disposer.Start();
            AssertTrue(readerBlocked.WaitOne(TimeSpan.FromSeconds(4)), "reader reaches its stop signal while disposal is in progress");
            AssertTrue(!waitHandleDisposeStarted.WaitOne(TimeSpan.FromMilliseconds(200)), "parent does not dispose wait handles before the reader exits");
            releaseReader.Set();
            AssertTrue(disposer.Join(TimeSpan.FromSeconds(4)), "disposal completes after the reader is released");
            AssertTrue(disposeError == null, "disposal does not throw after a remote fault");
            AssertTrue(waitHandleDisposeStarted.WaitOne(TimeSpan.Zero), "wait handles are disposed only after the reader has exited");
            client = null;
        }
        finally
        {
            releaseReader.Set();
            if (disposer != null && disposer.IsAlive) { disposer.Join(TimeSpan.FromSeconds(4)); }
            if (client != null) { client.Dispose(); }
            if (readerHook != null) { readerHook.SetValue(null, null); }
            if (waitHandleDisposeHook != null) { waitHandleDisposeHook.SetValue(null, null); }
            readerBlocked.Dispose(); releaseReader.Dispose(); waitHandleDisposeStarted.Dispose();
            PeerArguments = "--peer";
        }
    }

    private static void TestCorrelatedActionResults()
    {
        PeerArguments = "--action-peer";
        TrayHostParentClient client = null;
        try
        {
            client = TrayHostParentClient.Start(Options());
            TrayHostEvent action = null; DateTime deadline = DateTime.UtcNow.AddSeconds(2);
            while (action == null && DateTime.UtcNow < deadline)
            {
                client.WaitForActivity(TimeSpan.FromMilliseconds(100));
                TrayHostEvent value;
                while (client.TryDequeueEvent(out value)) { if (value.Kind == TrayHostEventKind.Action) { action = value; break; } }
            }
            AssertTrue(action != null && action.Command == TrayCommand.CheckAndRepair && action.Revision == 1UL, "parent receives the exact v2 action event");
            Guid transactionId = Guid.Parse("11111111-2222-3333-4444-555555555555");
            AssertTrue(client.TryAcknowledgeAction(new TrayActionResult(action.ActionId, action.Revision, TrayActionResultStatus.Accepted, null, transactionId)), "parent queues the accepted action result");
            bool completed = false; deadline = DateTime.UtcNow.AddSeconds(2);
            while (!completed && DateTime.UtcNow < deadline)
            {
                completed = client.TryAcknowledgeAction(new TrayActionResult(action.ActionId, action.Revision, TrayActionResultStatus.Completed, null, transactionId));
                if (!completed) { Thread.Sleep(20); }
            }
            AssertTrue(completed, "parent queues the terminal result after the accepted result drains");
        }
        finally { if (client != null) { client.Dispose(); } PeerArguments = "--peer"; }
    }

    public static int Main(string[] args)
    {
        try
        {
            if (args.Length == 1 && args[0] == "--peer") { RunPeer(false, false); return 0; }
            if (args.Length == 1 && args[0] == "--fault-peer") { RunPeer(true, false); return 0; }
            if (args.Length == 1 && args[0] == "--action-peer") { RunPeer(false, true); return 0; }
            TrayHostParentClient.TestProcessFactory = StartPeer;
            TrayHostParentClient client = TrayHostParentClient.Start(Options());
            AssertTrue(client.Receipt.ProtocolMajor == 2 && client.GetHealth() == TrayHostHealth.Ready, "parent waits for verified v2 ready");
            AssertTrue(client.TryPublish(Snapshot(2UL)), "parent publishes presentation without blocking");
            AssertTrue(client.WaitForActivity(TimeSpan.FromSeconds(2)), "parent observes host acknowledgement");
            TrayHostEvent value;
            AssertTrue(client.TryDequeueEvent(out value) && value.Kind == TrayHostEventKind.PresentationAck && value.Revision == 2UL, "presentation acknowledgement is surfaced");
            AssertTrue(client.BeginShutdown(ShutdownReason.SupervisorExit, 2UL), "shutdown is accepted");
            AssertTrue(client.WaitForStopped(TimeSpan.FromSeconds(2)), "shutdown completes within deadline");
            client.Dispose();
            TestDisposeRequestsGracefulShutdown();
            TestDisposeAfterRemoteFaultDoesNotCrashParentReader();
            TestCorrelatedActionResults();
            Console.WriteLine("TrayHost parent-client self-tests passed: 4");
            return 0;
        }
        catch (Exception error)
        {
            Console.Error.WriteLine("TrayHost parent-client self-test failed: " + error.GetType().FullName);
            Console.Error.WriteLine(error.Message);
            return 1;
        }
    }
}
