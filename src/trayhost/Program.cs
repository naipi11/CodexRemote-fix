using System;
using System.Diagnostics;
using System.IO;
using System.Security.Cryptography;
using System.Threading;

internal static class Program
{
    private static readonly object WriteGate = new object();

    internal static int Main(string[] args)
    {
        try
        {
            if (args != null && args.Length == 1 && String.Equals(args[0], "--headless-smoke", StringComparison.Ordinal)) { return RunHeadlessSmoke(); }
            if (args != null && args.Length == 7 && String.Equals(args[0], "--child", StringComparison.Ordinal)) { return RunChild(args); }
            return 2;
        }
        catch { return 1; }
    }

    private static int RunChild(string[] args)
    {
        int expectedParentPid; long expectedParentCreation; string expectedRuntime;
        if (!Int32.TryParse(args[2], out expectedParentPid) || !Int64.TryParse(args[4], out expectedParentCreation) || String.IsNullOrEmpty(args[6]) || !String.Equals(args[1], "--parent-pid", StringComparison.Ordinal) || !String.Equals(args[3], "--parent-created", StringComparison.Ordinal) || !String.Equals(args[5], "--runtime-id", StringComparison.Ordinal)) { return 2; }
        expectedRuntime = args[6];
        Stream input = Console.OpenStandardInput(); Stream output = Console.OpenStandardOutput();
        ProtocolFrame bootstrap = ProtocolCodec.ReadBootstrap(input, ProtocolDirection.ParentToHost);
        TrayHostHello parent = TrayHostWire.ReadParentHello(bootstrap.Payload);
        if (parent.ProcessId != expectedParentPid || parent.CreationFileTimeUtc != expectedParentCreation || !String.Equals(parent.RuntimeId, expectedRuntime, StringComparison.Ordinal) || !VerifyParentIdentity(expectedParentPid, expectedParentCreation)) { return 2; }
        byte[] nonce = new byte[32]; using (RandomNumberGenerator rng = RandomNumberGenerator.Create()) { rng.GetBytes(nonce); }
        ulong epoch = (ulong)DateTime.UtcNow.Ticks;
        Process self = Process.GetCurrentProcess();
        ProtocolCodec.WriteBootstrap(output, ProtocolFrame.Bootstrap(ProtocolDirection.HostToParent, TrayHostMessageType.HostHello, TrayHostWire.WriteHostHello(self.Id, self.StartTime.ToFileTimeUtc(), expectedRuntime, nonce, epoch)));
        SessionKeys keys = ProtocolCodec.DeriveDirectionalKeys(parent.SessionSeed, parent.ParentChallenge, nonce, epoch);
        ulong inboundSequence = 1UL; ulong outboundSequence = 1UL;
        ProtocolFrame initialFrame = ProtocolCodec.ReadAuthenticated(input, ProtocolDirection.ParentToHost, epoch, inboundSequence++, keys.ParentToHost);
        if (initialFrame.MessageType != TrayHostMessageType.Presentation) { return 2; }
        PresentationSnapshot initial = TrayHostWire.ReadPresentation(initialFrame.Payload);
        Win32TrayPlatform platform = new Win32TrayPlatform();
        TrayWindow window = new TrayWindow(platform);
        HostTransport transport = new HostTransport();
        bool shutdownRequested = false; bool shutdownSent = false; object stateGate = new object();
        TrayHostApplication application = null;
        Action<TrayCommand, ulong> command = delegate(TrayCommand selected, ulong revision)
        {
            TrayHostAction action;
            try { action = new TrayHostAction(Guid.NewGuid(), selected, revision); }
            catch (ArgumentException) { return; }
            if (!transport.TryRegisterAction(action)) { return; }
            lock (WriteGate) { ProtocolCodec.WriteAuthenticated(output, ProtocolFrame.Authenticated(ProtocolDirection.HostToParent, TrayHostMessageType.Action, epoch, outboundSequence++, TrayHostWire.WriteAction(action)), keys.HostToParent); }
        };
        Action work = delegate
        {
            PresentationSnapshot next;
            if (transport.TryTakePresentation(out next))
            {
                window.Apply(next);
                lock (WriteGate) { ProtocolCodec.WriteAuthenticated(output, ProtocolFrame.Authenticated(ProtocolDirection.HostToParent, TrayHostMessageType.PresentationAck, epoch, outboundSequence++, TrayHostWire.WriteRevision(next.Revision)), keys.HostToParent); }
            }
            bool shouldShutdown;
            lock (stateGate) { shouldShutdown = shutdownRequested && !shutdownSent; if (shouldShutdown) { shutdownSent = true; } }
            if (shouldShutdown)
            {
                window.RequestShutdown();
                lock (WriteGate) { ProtocolCodec.WriteAuthenticated(output, ProtocolFrame.Authenticated(ProtocolDirection.HostToParent, TrayHostMessageType.ShutdownAck, epoch, outboundSequence++, TrayHostWire.WriteRevision(window.CurrentRevision)), keys.HostToParent); }
                application.RequestExit();
            }
        };
        window.CommandSelected += command;
        application = new TrayHostApplication(platform, window, command, work);
        window.Create(initial);
        lock (WriteGate)
        {
            ProtocolCodec.WriteAuthenticated(output, ProtocolFrame.Authenticated(ProtocolDirection.HostToParent, TrayHostMessageType.PresentationAck, epoch, outboundSequence++, TrayHostWire.WriteRevision(initial.Revision)), keys.HostToParent);
            ProtocolCodec.WriteAuthenticated(output, ProtocolFrame.Authenticated(ProtocolDirection.HostToParent, TrayHostMessageType.UiReady, epoch, outboundSequence++, TrayHostWire.WriteRevision(initial.Revision)), keys.HostToParent);
        }
        Thread reader = new Thread(new ThreadStart(delegate
        {
            try
            {
                while (true)
                {
                    ProtocolFrame frame = ProtocolCodec.ReadAuthenticated(input, ProtocolDirection.ParentToHost, epoch, inboundSequence++, keys.ParentToHost);
                    if (frame.MessageType == TrayHostMessageType.Presentation) { transport.TryAcceptPresentation(TrayHostWire.ReadPresentation(frame.Payload)); application.PostWork(); }
                    else if (frame.MessageType == TrayHostMessageType.ActionResult) { if (!transport.TryAcknowledgeAction(TrayHostWire.ReadActionResult(frame.Payload))) { throw new ProtocolViolationException("action result is uncorrelated"); } }
                    else if (frame.MessageType == TrayHostMessageType.Shutdown) { lock (stateGate) { shutdownRequested = true; } application.PostWork(); }
                    else if (frame.MessageType == TrayHostMessageType.Ping) { lock (WriteGate) { ProtocolCodec.WriteAuthenticated(output, ProtocolFrame.Authenticated(ProtocolDirection.HostToParent, TrayHostMessageType.Pong, epoch, outboundSequence++, frame.Payload), keys.HostToParent); } }
                }
            }
            catch { application.RequestExit(); }
        })) { IsBackground = true, Name = "CodexRemote.TrayHost.Reader" };
        reader.Start();
        int result = application.Run();
        application.Dispose(); transport.Dispose(); return result;
    }

    private static bool VerifyParentIdentity(int pid, long creation)
    {
        try { using (Process process = Process.GetProcessById(pid)) { return process.StartTime.ToFileTimeUtc() == creation; } } catch { return false; }
    }

    private static int RunHeadlessSmoke()
    {
        string[] strings = new string[16]; for (int i = 0; i < strings.Length; i++) { strings[i] = "smoke-" + i; }
        PresentationSnapshot snapshot = new PresentationSnapshot(1UL, TrayColor.Green, ConnectionState.Connected, ProtectionState.Running, LanguageMode.Chinese, PresentationFlags.OpenLogsEnabled, strings);
        byte[] seed = new byte[32]; byte[] challenge = new byte[32]; byte[] nonce = new byte[32];
        SessionKeys keys = ProtocolCodec.DeriveDirectionalKeys(seed, challenge, nonce, 1UL);
        MemoryStream stream = new MemoryStream();
        ProtocolCodec.WriteAuthenticated(stream, ProtocolFrame.Authenticated(ProtocolDirection.ParentToHost, TrayHostMessageType.Presentation, 1UL, 1UL, TrayHostWire.WritePresentation(snapshot)), keys.ParentToHost);
        stream.Position = 0; ProtocolFrame parsed = ProtocolCodec.ReadAuthenticated(stream, ProtocolDirection.ParentToHost, 1UL, 1UL, keys.ParentToHost);
        if (TrayHostWire.ReadPresentation(parsed.Payload).Revision != 1UL) { return 1; }
        ParentTransport parent = new ParentTransport(); HostTransport host = new HostTransport(); parent.TrySetLatestPresentation(snapshot); PresentationSnapshot latest; parent.TryDequeueLatestPresentation(out latest); host.TryAcceptPresentation(latest); PresentationSnapshot applied; host.TryTakePresentation(out applied); parent.Dispose(); host.Dispose(); return applied == null ? 1 : 0;
    }
}
