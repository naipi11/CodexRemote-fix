using System;
using System.IO;

internal static class Program
{
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
        TrayHostChildIdentity identity;
        if (!TrayHostChildSession.TryCreateIdentity(args, out identity)) { return 2; }
        return TrayHostChildSession.Run(
            Console.OpenStandardInput(),
            Console.OpenStandardOutput(),
            identity,
            new WindowsTrayHostRuntime(),
            delegate(HostTransport transport)
            {
                TrayTerminalDiagnosticStore terminalStore = new TrayTerminalDiagnosticStore();
                return new TrayTerminalReceiptSink(terminalStore.TryAppendDurably, transport.TryPublishDurableReceipt, terminalStore.Dispose);
            });
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
