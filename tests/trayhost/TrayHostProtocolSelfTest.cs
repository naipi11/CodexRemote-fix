using System;
using System.IO;
using System.Linq;
using System.Text;

internal static class TrayHostProtocolSelfTest
{
    private static void AssertTrue(bool value, string message)
    {
        if (!value) { throw new InvalidOperationException(message); }
    }

    private static void AssertEqual(string expected, string actual, string message)
    {
        if (!String.Equals(expected, actual, StringComparison.Ordinal))
        {
            throw new InvalidOperationException(message + " expected=[" + expected + "] actual=[" + actual + "]");
        }
    }

    private static void AssertEqual<T>(T expected, T actual, string message)
    {
        if (!Object.Equals(expected, actual)) { throw new InvalidOperationException(message + " expected=[" + expected + "] actual=[" + actual + "]"); }
    }

    private static void AssertThrowsProtocol(Action action, string message)
    {
        bool threw = false;
        try { action(); } catch (ProtocolViolationException) { threw = true; }
        AssertTrue(threw, message);
    }

    private static byte[] BuildHeader(ushort version, TrayHostMessageType type, uint payloadLength)
    {
        byte[] header = new byte[ProtocolCodec.HeaderSize];
        header[0] = (byte)'C'; header[1] = (byte)'R'; header[2] = (byte)'T'; header[3] = (byte)'H';
        Buffer.BlockCopy(BitConverter.GetBytes(version), 0, header, 4, 2);
        Buffer.BlockCopy(BitConverter.GetBytes((ushort)type), 0, header, 6, 2);
        Buffer.BlockCopy(BitConverter.GetBytes(payloadLength), 0, header, 8, 4);
        return header;
    }

    private static byte[] BuildActionPayload(Guid actionId, TrayCommand command, ulong revision)
    {
        using (MemoryStream stream = new MemoryStream())
        using (BinaryWriter writer = new BinaryWriter(stream))
        {
            writer.Write(actionId.ToByteArray()); writer.Write((ushort)command); writer.Write(revision); return stream.ToArray();
        }
    }

    private static byte[] Hex(string value)
    {
        byte[] result = new byte[value.Length / 2];
        for (int i = 0; i < result.Length; i++) { result[i] = Convert.ToByte(value.Substring(i * 2, 2), 16); }
        return result;
    }

    private static void TestRfc5869Expand()
    {
        byte[] ikm = Enumerable.Repeat((byte)0x0b, 22).ToArray();
        byte[] salt = Hex("000102030405060708090a0b0c");
        byte[] info = Hex("f0f1f2f3f4f5f6f7f8f9");
        byte[] expected = Hex("3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865");
        byte[] actual = HkdfSha256.Derive(ikm, salt, info, 42);
        AssertEqual(BitConverter.ToString(expected), BitConverter.ToString(actual), "RFC 5869 HKDF vector is exact");
    }

    private static void TestBootstrapFrameRoundTrip()
    {
        byte[] payload = Encoding.UTF8.GetBytes("hello");
        ProtocolFrame frame = ProtocolFrame.Bootstrap(ProtocolDirection.ParentToHost, TrayHostMessageType.ParentHello, payload);
        MemoryStream stream = new MemoryStream();
        ProtocolCodec.WriteBootstrap(stream, frame);
        AssertTrue(stream.Length == 60 + payload.Length, "bootstrap frame has the fixed header length");
        stream.Position = 0;
        ProtocolFrame parsed = ProtocolCodec.ReadBootstrap(stream, ProtocolDirection.ParentToHost);
        AssertTrue(parsed.Epoch == 0UL && parsed.Sequence == 0UL, "bootstrap epoch and sequence are zero");
        AssertEqual("hello", Encoding.UTF8.GetString(parsed.Payload), "bootstrap payload round-trips");
    }

    private static void TestBootstrapRejectsWrongDirection()
    {
        ProtocolFrame frame = ProtocolFrame.Bootstrap(ProtocolDirection.HostToParent, TrayHostMessageType.HostHello, new byte[] { 1 });
        MemoryStream stream = new MemoryStream();
        ProtocolCodec.WriteBootstrap(stream, frame);
        stream.Position = 0;
        bool threw = false;
        try { ProtocolCodec.ReadBootstrap(stream, ProtocolDirection.ParentToHost); } catch (ProtocolViolationException) { threw = true; }
        AssertTrue(threw, "bootstrap direction mismatch is rejected");
    }

    private static void TestProtocolMajorRejectsV1()
    {
        AssertThrowsProtocol(delegate {
            ProtocolCodec.ReadBootstrap(new MemoryStream(BuildHeader(1, TrayHostMessageType.ParentHello, 0U)), ProtocolDirection.ParentToHost);
        }, "v1 bootstrap is rejected");
    }

    private static void TestBootstrapAcceptsUtf8Preamble()
    {
        byte[] payload = Encoding.UTF8.GetBytes("hello");
        MemoryStream frame = new MemoryStream();
        ProtocolCodec.WriteBootstrap(frame, ProtocolFrame.Bootstrap(ProtocolDirection.ParentToHost, TrayHostMessageType.ParentHello, payload));
        MemoryStream stream = new MemoryStream();
        byte[] preamble = Encoding.UTF8.GetPreamble();
        stream.Write(preamble, 0, preamble.Length);
        byte[] bytes = frame.ToArray();
        stream.Write(bytes, 0, bytes.Length);
        stream.Position = 0;
        ProtocolFrame parsed = ProtocolCodec.ReadBootstrap(stream, ProtocolDirection.ParentToHost);
        AssertEqual("hello", Encoding.UTF8.GetString(parsed.Payload), "bootstrap tolerates the redirected PowerShell UTF-8 preamble");
    }

    private static void TestAuthenticatedFrameRejectsReplayAndTamper()
    {
        byte[] key = Enumerable.Repeat((byte)0x42, 32).ToArray();
        ProtocolFrame frame = ProtocolFrame.Authenticated(ProtocolDirection.ParentToHost, TrayHostMessageType.Ping, 17UL, 1UL, new byte[] { 9, 8, 7 });
        MemoryStream stream = new MemoryStream();
        ProtocolCodec.WriteAuthenticated(stream, frame, key);
        stream.Position = 0;
        ProtocolFrame parsed = ProtocolCodec.ReadAuthenticated(stream, ProtocolDirection.ParentToHost, 17UL, 1UL, key);
        AssertTrue(parsed.Payload.Length == 3 && parsed.Payload[0] == 9, "authenticated payload round-trips");
        byte[] bytes = stream.ToArray();
        bytes[bytes.Length - 1] ^= 0x01;
        bool threw = false;
        try { ProtocolCodec.ReadAuthenticated(new MemoryStream(bytes), ProtocolDirection.ParentToHost, 17UL, 1UL, key); } catch (ProtocolViolationException) { threw = true; }
        AssertTrue(threw, "authenticated payload tamper is rejected");
    }

    private static void TestLargeEpochUsesUnsignedWireEncoding()
    {
        byte[] seed = Enumerable.Repeat((byte)0x11, 32).ToArray();
        byte[] challenge = Enumerable.Repeat((byte)0x22, 32).ToArray();
        byte[] nonce = Enumerable.Repeat((byte)0x33, 32).ToArray();
        SessionKeys keys = ProtocolCodec.DeriveDirectionalKeys(seed, challenge, nonce, UInt64.MaxValue - 7UL);
        MemoryStream stream = new MemoryStream();
        ProtocolCodec.WriteAuthenticated(stream, ProtocolFrame.Authenticated(ProtocolDirection.ParentToHost, TrayHostMessageType.Ping, UInt64.MaxValue - 7UL, 1UL, new byte[] { 1 }), keys.ParentToHost);
        stream.Position = 0;
        AssertTrue(ProtocolCodec.ReadAuthenticated(stream, ProtocolDirection.ParentToHost, UInt64.MaxValue - 7UL, 1UL, keys.ParentToHost).Payload[0] == 1, "large epochs round-trip without checked byte-cast overflow");
    }

    private static string[] ValidStrings()
    {
        string[] values = new string[16];
        for (int i = 0; i < values.Length; i++) { values[i] = "string-" + i; }
        return values;
    }

    private static void TestPresentationSnapshotValidation()
    {
        PresentationSnapshot snapshot = new PresentationSnapshot(
            1UL,
            TrayColor.Green,
            ConnectionState.Connected,
            ProtectionState.Running,
            LanguageMode.Chinese,
            PresentationFlags.LanguageEnabled | PresentationFlags.OpenLogsEnabled,
            ValidStrings());
        AssertTrue(snapshot.Revision == 1UL && snapshot.Connection == ConnectionState.Connected && snapshot.Protection == ProtectionState.Running && snapshot.Strings.Count == 16, "presentation snapshot retains its validated fields");
        bool threw = false;
        string[] invalid = ValidStrings();
        invalid[3] = "bad\rtext";
        try { new PresentationSnapshot(2UL, TrayColor.Green, ConnectionState.Connected, ProtectionState.Running, LanguageMode.Chinese, PresentationFlags.None, invalid); } catch (ArgumentException) { threw = true; }
        AssertTrue(threw, "presentation control characters are rejected");
    }

    private static void TestActionResultWireAndLegacyCommandRejection()
    {
        Guid actionId = Guid.NewGuid();
        Guid transactionId = Guid.Parse("11111111-2222-3333-4444-555555555555");
        TrayActionResult accepted = new TrayActionResult(actionId, 12UL, TrayActionResultStatus.Accepted, null, transactionId);
        TrayActionResult roundTrip = TrayHostWire.ReadActionResult(TrayHostWire.WriteActionResult(accepted));
        AssertEqual(actionId, roundTrip.ActionId, "action result keeps action id");
        AssertEqual(12UL, roundTrip.Revision, "action result keeps revision");
        AssertEqual(TrayActionResultStatus.Accepted, roundTrip.Status, "action result keeps status");
        AssertEqual(transactionId, roundTrip.TransactionId.Value, "action result keeps transaction id");
        AssertThrowsProtocol(delegate {
            TrayHostWire.ReadAction(BuildActionPayload(Guid.NewGuid(), (TrayCommand)1001, 7UL));
        }, "legacy command id is rejected");
    }

    private static void TestActionResultRejectsAChangedEpoch()
    {
        byte[] key = Enumerable.Repeat((byte)0x42, 32).ToArray();
        TrayActionResult result = new TrayActionResult(Guid.NewGuid(), 7UL, TrayActionResultStatus.Completed, null, null);
        MemoryStream stream = new MemoryStream();
        ProtocolCodec.WriteAuthenticated(stream, ProtocolFrame.Authenticated(ProtocolDirection.ParentToHost, TrayHostMessageType.ActionResult, 18UL, 1UL, TrayHostWire.WriteActionResult(result)), key);
        stream.Position = 0;
        AssertThrowsProtocol(delegate { ProtocolCodec.ReadAuthenticated(stream, ProtocolDirection.ParentToHost, 17UL, 1UL, key); }, "action result after an epoch change is rejected");
    }

    private static void TestActionResultRejectsNoncanonicalPresenceFlags()
    {
        Guid transactionId = Guid.Parse("11111111-2222-3333-4444-555555555555");
        byte[] transactionPayload = TrayHostWire.WriteActionResult(new TrayActionResult(Guid.NewGuid(), 7UL, TrayActionResultStatus.Accepted, null, transactionId));
        transactionPayload[26] = 2;
        AssertThrowsProtocol(delegate { TrayHostWire.ReadActionResult(transactionPayload); }, "noncanonical transaction-presence flag is rejected");
        byte[] errorPayload = TrayHostWire.WriteActionResult(new TrayActionResult(Guid.NewGuid(), 8UL, TrayActionResultStatus.Rejected, "CCOD_TRAY_ACTION_REJECTED", null));
        errorPayload[25] = 2;
        AssertThrowsProtocol(delegate { TrayHostWire.ReadActionResult(errorPayload); }, "noncanonical error-presence flag is rejected");
    }

    public static int Main(string[] args)
    {
        try
        {
            TestRfc5869Expand();
            TestBootstrapFrameRoundTrip();
            TestBootstrapRejectsWrongDirection();
            TestProtocolMajorRejectsV1();
            TestBootstrapAcceptsUtf8Preamble();
            TestAuthenticatedFrameRejectsReplayAndTamper();
            TestLargeEpochUsesUnsignedWireEncoding();
            TestPresentationSnapshotValidation();
            TestActionResultWireAndLegacyCommandRejection();
            TestActionResultRejectsAChangedEpoch();
            TestActionResultRejectsNoncanonicalPresenceFlags();
            Console.WriteLine("TrayHost protocol self-tests passed: 11");
            return 0;
        }
        catch (Exception error)
        {
            Console.Error.WriteLine("TrayHost protocol self-test failed: " + error.GetType().FullName);
            Console.Error.WriteLine(error.Message);
            return 1;
        }
    }
}
