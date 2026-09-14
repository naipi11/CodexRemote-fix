using System;
using System.Diagnostics;
using System.IO;
using System.Security.Cryptography;
using System.Threading;

internal sealed class TrayHostChildIdentity
{
    internal int ParentProcessId { get; private set; }
    internal long ParentCreationFileTimeUtc { get; private set; }
    internal string RuntimeId { get; private set; }

    internal TrayHostChildIdentity(int parentProcessId, long parentCreationFileTimeUtc, string runtimeId)
    {
        ParentProcessId = parentProcessId;
        ParentCreationFileTimeUtc = parentCreationFileTimeUtc;
        RuntimeId = runtimeId;
    }
}

internal interface ITrayHostRuntime : IDisposable
{
    ulong CurrentRevision { get; }
    void Initialize(Action<bool> menuOpenChanged, Action<TrayCommand, ulong> commandSelected, Action work, Action<uint> receiptWork);
    void Create(PresentationSnapshot initial);
    bool Apply(PresentationSnapshot snapshot);
    void PostWork();
    bool PostReceiptWork(uint token);
    void ShowAbout();
    void ShowActionFailed();
    void RequestShutdown();
    void RequestExit();
    int Run();
}

internal static class TrayHostChildSession
{
    internal static bool TryCreateIdentity(string[] args, out TrayHostChildIdentity identity)
    {
        identity = null;
        int parentProcessId;
        long parentCreation;
        if (args == null || args.Length != 7 ||
            !String.Equals(args[0], "--child", StringComparison.Ordinal) ||
            !String.Equals(args[1], "--parent-pid", StringComparison.Ordinal) ||
            !Int32.TryParse(args[2], out parentProcessId) ||
            !String.Equals(args[3], "--parent-created", StringComparison.Ordinal) ||
            !Int64.TryParse(args[4], out parentCreation) ||
            !String.Equals(args[5], "--runtime-id", StringComparison.Ordinal) ||
            String.IsNullOrEmpty(args[6])) { return false; }
        identity = new TrayHostChildIdentity(parentProcessId, parentCreation, args[6]);
        return true;
    }

    internal static int Run(
        Stream input,
        Stream output,
        TrayHostChildIdentity identity,
        ITrayHostRuntime runtime,
        Func<HostTransport, TrayTerminalReceiptSink> createReceiptSink)
    {
        if (input == null || output == null || identity == null || runtime == null || createReceiptSink == null) { throw new ArgumentNullException("child session dependency"); }
        HostTransport transport = null;
        TrayTerminalReceiptSink receiptSink = null;
        try
        {
            ProtocolFrame bootstrap = ProtocolCodec.ReadBootstrap(input, ProtocolDirection.ParentToHost);
            TrayHostHello parent = TrayHostWire.ReadParentHello(bootstrap.Payload);
            if (parent.ProcessId != identity.ParentProcessId ||
                parent.CreationFileTimeUtc != identity.ParentCreationFileTimeUtc ||
                !String.Equals(parent.RuntimeId, identity.RuntimeId, StringComparison.Ordinal) ||
                !VerifyParentIdentity(identity.ParentProcessId, identity.ParentCreationFileTimeUtc)) { return 2; }

            byte[] nonce = new byte[32];
            using (RandomNumberGenerator random = RandomNumberGenerator.Create()) { random.GetBytes(nonce); }
            ulong epoch = (ulong)DateTime.UtcNow.Ticks;
            Process self = Process.GetCurrentProcess();
            try
            {
                ProtocolCodec.WriteBootstrap(output, ProtocolFrame.Bootstrap(
                    ProtocolDirection.HostToParent,
                    TrayHostMessageType.HostHello,
                    TrayHostWire.WriteHostHello(self.Id, self.StartTime.ToFileTimeUtc(), identity.RuntimeId, nonce, epoch)));
            }
            finally { self.Dispose(); }

            SessionKeys keys = ProtocolCodec.DeriveDirectionalKeys(parent.SessionSeed, parent.ParentChallenge, nonce, epoch);
            ulong inboundSequence = 1UL;
            ulong outboundSequence = 1UL;
            object writeGate = new object();
            ProtocolFrame initialFrame = ProtocolCodec.ReadAuthenticated(input, ProtocolDirection.ParentToHost, epoch, inboundSequence++, keys.ParentToHost);
            if (initialFrame.MessageType != TrayHostMessageType.Presentation) { return 2; }
            PresentationSnapshot initial = TrayHostWire.ReadPresentation(initialFrame.Payload);

            transport = new HostTransport(
                delegate { runtime.PostWork(); },
                delegate(uint token) { return runtime.PostReceiptWork(token); });
            receiptSink = createReceiptSink(transport);
            if (receiptSink == null) { throw new InvalidOperationException("receipt sink is unavailable"); }

            bool shutdownRequested = false;
            bool shutdownSent = false;
            object stateGate = new object();
            HostTransport currentTransport = transport;
            TrayTerminalReceiptSink currentReceiptSink = receiptSink;

            Action<TrayCommand, ulong> command = delegate(TrayCommand selected, ulong revision)
            {
                TrayHostAction action;
                try { action = new TrayHostAction(Guid.NewGuid(), selected, revision); }
                catch (ArgumentException) { return; }
                if (!currentTransport.TryRegisterAction(action)) { return; }
                lock (writeGate)
                {
                    ProtocolCodec.WriteAuthenticated(output, ProtocolFrame.Authenticated(
                        ProtocolDirection.HostToParent,
                        TrayHostMessageType.Action,
                        epoch,
                        outboundSequence++,
                        TrayHostWire.WriteAction(action)), keys.HostToParent);
                }
            };

            Action work = delegate
            {
                PresentationSnapshot next;
                if (currentTransport.TryTakePresentation(out next) && runtime.Apply(next))
                {
                    lock (writeGate)
                    {
                        ProtocolCodec.WriteAuthenticated(output, ProtocolFrame.Authenticated(
                            ProtocolDirection.HostToParent,
                            TrayHostMessageType.PresentationAck,
                            epoch,
                            outboundSequence++,
                            TrayHostWire.WriteRevision(next.Revision)), keys.HostToParent);
                    }
                }
                bool shouldShutdown;
                lock (stateGate)
                {
                    shouldShutdown = shutdownRequested && !shutdownSent;
                    if (shouldShutdown) { shutdownSent = true; }
                }
                if (shouldShutdown)
                {
                    runtime.RequestShutdown();
                    lock (writeGate)
                    {
                        ProtocolCodec.WriteAuthenticated(output, ProtocolFrame.Authenticated(
                            ProtocolDirection.HostToParent,
                            TrayHostMessageType.ShutdownAck,
                            epoch,
                            outboundSequence++,
                            TrayHostWire.WriteRevision(runtime.CurrentRevision)), keys.HostToParent);
                    }
                    runtime.RequestExit();
                }
            };

            Action<uint> receiptWork = delegate(uint token)
            {
                TrayTerminalReceiptUiKind kind;
                TrayActionResult receiptResult;
                if (!currentTransport.TryTakeReceiptUi(token, out kind, out receiptResult)) { return; }
                if (kind == TrayTerminalReceiptUiKind.About) { runtime.ShowAbout(); }
                else if (kind == TrayTerminalReceiptUiKind.Failure) { runtime.ShowActionFailed(); }
            };

            runtime.Initialize(currentTransport.SetMenuOpen, command, work, receiptWork);
            runtime.Create(initial);
            lock (writeGate)
            {
                ProtocolCodec.WriteAuthenticated(output, ProtocolFrame.Authenticated(
                    ProtocolDirection.HostToParent,
                    TrayHostMessageType.PresentationAck,
                    epoch,
                    outboundSequence++,
                    TrayHostWire.WriteRevision(initial.Revision)), keys.HostToParent);
                ProtocolCodec.WriteAuthenticated(output, ProtocolFrame.Authenticated(
                    ProtocolDirection.HostToParent,
                    TrayHostMessageType.UiReady,
                    epoch,
                    outboundSequence++,
                    TrayHostWire.WriteRevision(initial.Revision)), keys.HostToParent);
            }

            Thread reader = new Thread(new ThreadStart(delegate
            {
                try
                {
                    while (true)
                    {
                        ProtocolFrame frame = ProtocolCodec.ReadAuthenticated(input, ProtocolDirection.ParentToHost, epoch, inboundSequence++, keys.ParentToHost);
                        if (frame.MessageType == TrayHostMessageType.Presentation)
                        {
                            currentTransport.TryAcceptPresentation(TrayHostWire.ReadPresentation(frame.Payload));
                            runtime.PostWork();
                        }
                        else if (frame.MessageType == TrayHostMessageType.ActionResult)
                        {
                            if (!TryDispatchAuthenticatedActionResult(currentTransport, currentReceiptSink, frame.Payload)) { throw new ProtocolViolationException("action result is uncorrelated"); }
                        }
                        else if (frame.MessageType == TrayHostMessageType.Shutdown)
                        {
                            lock (stateGate) { shutdownRequested = true; }
                            runtime.PostWork();
                        }
                        else if (frame.MessageType == TrayHostMessageType.Ping)
                        {
                            lock (writeGate)
                            {
                                ProtocolCodec.WriteAuthenticated(output, ProtocolFrame.Authenticated(
                                    ProtocolDirection.HostToParent,
                                    TrayHostMessageType.Pong,
                                    epoch,
                                    outboundSequence++,
                                    frame.Payload), keys.HostToParent);
                            }
                        }
                    }
                }
                catch { runtime.RequestExit(); }
            })) { IsBackground = true, Name = "CodexRemote.TrayHost.Reader" };
            reader.Start();
            return runtime.Run();
        }
        finally
        {
            if (receiptSink != null) { receiptSink.Dispose(); }
            if (transport != null) { transport.Dispose(); }
            runtime.Dispose();
        }
    }

    private static bool TryDispatchAuthenticatedActionResult(HostTransport transport, TrayTerminalReceiptSink receiptSink, byte[] payload)
    {
        if (transport == null || receiptSink == null || payload == null) { return false; }
        TrayTerminalReceipt receipt;
        if (!transport.TryAcknowledgeAction(TrayHostWire.ReadActionResult(payload), out receipt)) { return false; }
        if (receipt != null)
        {
            try { receiptSink.TrySubmit(receipt); }
            catch { }
        }
        return true;
    }

    private static bool VerifyParentIdentity(int processId, long creationFileTimeUtc)
    {
        try
        {
            using (Process process = Process.GetProcessById(processId)) { return process.StartTime.ToFileTimeUtc() == creationFileTimeUtc; }
        }
        catch { return false; }
    }
}
