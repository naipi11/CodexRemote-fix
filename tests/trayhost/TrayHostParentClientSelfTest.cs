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
        string[] strings = new string[20];
        for (int i = 0; i < strings.Length; i++) { strings[i] = "string-" + i; }
        return new PresentationSnapshot(revision, TrayColor.Green, TrayState.Active, LanguageMode.Chinese, PresentationFlags.OpenLogsEnabled, strings);
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

    private static void RunPeer(bool emitFaultAndIgnoreShutdown)
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

    public static int Main(string[] args)
    {
        try
        {
            if (args.Length == 1 && args[0] == "--peer") { RunPeer(false); return 0; }
            if (args.Length == 1 && args[0] == "--fault-peer") { RunPeer(true); return 0; }
            TrayHostParentClient.TestProcessFactory = StartPeer;
            TrayHostParentClient client = TrayHostParentClient.Start(Options());
            AssertTrue(client.Receipt.ProtocolMajor == 1 && client.GetHealth() == TrayHostHealth.Ready, "parent waits for verified ready");
            AssertTrue(client.TryPublish(Snapshot(2UL)), "parent publishes presentation without blocking");
            AssertTrue(client.WaitForActivity(TimeSpan.FromSeconds(2)), "parent observes host acknowledgement");
            TrayHostEvent value;
            AssertTrue(client.TryDequeueEvent(out value) && value.Kind == TrayHostEventKind.PresentationAck && value.Revision == 2UL, "presentation acknowledgement is surfaced");
            AssertTrue(client.BeginShutdown(ShutdownReason.SupervisorExit, 2UL), "shutdown is accepted");
            AssertTrue(client.WaitForStopped(TimeSpan.FromSeconds(2)), "shutdown completes within deadline");
            client.Dispose();
            TestDisposeRequestsGracefulShutdown();
            TestDisposeAfterRemoteFaultDoesNotCrashParentReader();
            Console.WriteLine("TrayHost parent-client self-tests passed: 3");
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
