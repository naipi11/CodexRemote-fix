using System;
using System.IO;
using System.Text;

internal sealed class TrayHostHello
{
    internal int ProcessId { get; private set; }
    internal long CreationFileTimeUtc { get; private set; }
    internal string RuntimeId { get; private set; }
    internal byte[] SessionSeed { get; private set; }
    internal byte[] ParentChallenge { get; private set; }
    internal byte[] HostNonce { get; private set; }
    internal ulong HostEpoch { get; private set; }

    internal TrayHostHello(int processId, long creationFileTimeUtc, string runtimeId, byte[] sessionSeed, byte[] parentChallenge, byte[] hostNonce, ulong hostEpoch)
    {
        ProcessId = processId;
        CreationFileTimeUtc = creationFileTimeUtc;
        RuntimeId = runtimeId;
        SessionSeed = sessionSeed;
        ParentChallenge = parentChallenge;
        HostNonce = hostNonce;
        HostEpoch = hostEpoch;
    }
}

internal static class TrayHostWire
{
    private static readonly Encoding Utf8 = new UTF8Encoding(false, true);

    internal static byte[] WriteParentHello(byte[] seed, byte[] challenge, int parentPid, long parentCreationFileTimeUtc, string runtimeId)
    {
        if (seed == null || seed.Length != 32 || challenge == null || challenge.Length != 32) { throw new ArgumentException("handshake secret length is invalid"); }
        using (MemoryStream stream = new MemoryStream())
        using (BinaryWriter writer = new BinaryWriter(stream, Utf8))
        {
            writer.Write((byte)ProtocolCodec.ProtocolMajor);
            writer.Write(seed);
            writer.Write(challenge);
            writer.Write(parentPid);
            writer.Write(parentCreationFileTimeUtc);
            WriteString(writer, runtimeId, 128);
            return stream.ToArray();
        }
    }

    internal static TrayHostHello ReadParentHello(byte[] payload)
    {
        using (MemoryStream stream = new MemoryStream(payload ?? new byte[0]))
        using (BinaryReader reader = new BinaryReader(stream, Utf8))
        {
            if (reader.ReadByte() != (byte)ProtocolCodec.ProtocolMajor) { throw new ProtocolViolationException("parent hello version is invalid"); }
            byte[] seed = reader.ReadBytes(32); byte[] challenge = reader.ReadBytes(32);
            if (seed.Length != 32 || challenge.Length != 32) { throw new ProtocolViolationException("parent hello secret is truncated"); }
            int pid = reader.ReadInt32(); long creation = reader.ReadInt64(); string runtime = ReadString(reader, 128);
            RequireEnd(stream);
            return new TrayHostHello(pid, creation, runtime, seed, challenge, null, 0UL);
        }
    }

    internal static byte[] WriteHostHello(int hostPid, long creationFileTimeUtc, string runtimeId, byte[] nonce, ulong epoch)
    {
        if (nonce == null || nonce.Length != 32 || epoch == 0UL) { throw new ArgumentException("host hello is invalid"); }
        using (MemoryStream stream = new MemoryStream())
        using (BinaryWriter writer = new BinaryWriter(stream, Utf8))
        {
            writer.Write((byte)ProtocolCodec.ProtocolMajor); writer.Write(hostPid); writer.Write(creationFileTimeUtc); writer.Write(nonce); writer.Write(epoch); WriteString(writer, runtimeId, 128); return stream.ToArray();
        }
    }

    internal static TrayHostHello ReadHostHello(byte[] payload)
    {
        using (MemoryStream stream = new MemoryStream(payload ?? new byte[0]))
        using (BinaryReader reader = new BinaryReader(stream, Utf8))
        {
            if (reader.ReadByte() != (byte)ProtocolCodec.ProtocolMajor) { throw new ProtocolViolationException("host hello version is invalid"); }
            int pid = reader.ReadInt32(); long creation = reader.ReadInt64(); byte[] nonce = reader.ReadBytes(32); ulong epoch = reader.ReadUInt64(); string runtime = ReadString(reader, 128);
            if (nonce.Length != 32 || epoch == 0UL) { throw new ProtocolViolationException("host hello is truncated"); }
            RequireEnd(stream);
            return new TrayHostHello(pid, creation, runtime, null, null, nonce, epoch);
        }
    }

    internal static byte[] WritePresentation(PresentationSnapshot snapshot)
    {
        if (snapshot == null) { throw new ArgumentNullException("snapshot"); }
        using (MemoryStream stream = new MemoryStream())
        using (BinaryWriter writer = new BinaryWriter(stream, Utf8))
        {
            writer.Write(snapshot.Revision); writer.Write((byte)snapshot.Color); writer.Write((byte)snapshot.State); writer.Write((byte)snapshot.Language); writer.Write((uint)snapshot.Flags); writer.Write((byte)snapshot.Strings.Count);
            for (int i = 0; i < snapshot.Strings.Count; i++) { WriteString(writer, snapshot.Strings[i], 300); }
            return stream.ToArray();
        }
    }

    internal static PresentationSnapshot ReadPresentation(byte[] payload)
    {
        using (MemoryStream stream = new MemoryStream(payload ?? new byte[0]))
        using (BinaryReader reader = new BinaryReader(stream, Utf8))
        {
            ulong revision = reader.ReadUInt64(); TrayColor color = (TrayColor)reader.ReadByte(); TrayState state = (TrayState)reader.ReadByte(); LanguageMode language = (LanguageMode)reader.ReadByte(); PresentationFlags flags = (PresentationFlags)reader.ReadUInt32(); int count = reader.ReadByte();
            if (count != 20) { throw new ProtocolViolationException("presentation string count is invalid"); }
            string[] strings = new string[count]; for (int i = 0; i < count; i++) { strings[i] = ReadString(reader, 300); }
            RequireEnd(stream);
            try { return new PresentationSnapshot(revision, color, state, language, flags, strings); } catch (ArgumentException error) { throw new ProtocolViolationException(error.Message); }
        }
    }

    internal static byte[] WriteRevision(ulong revision) { return BitConverter.GetBytes(revision); }
    internal static ulong ReadRevision(byte[] payload)
    {
        if (payload == null || payload.Length != 8) { throw new ProtocolViolationException("revision payload is invalid"); }
        return BitConverter.ToUInt64(payload, 0);
    }

    internal static byte[] WriteShutdown(ShutdownReason reason, ulong revision)
    {
        using (MemoryStream stream = new MemoryStream()) using (BinaryWriter writer = new BinaryWriter(stream)) { writer.Write((byte)reason); writer.Write(revision); return stream.ToArray(); }
    }

    internal static byte[] WriteAction(TrayHostAction action)
    {
        if (action == null) { throw new ArgumentNullException("action"); }
        using (MemoryStream stream = new MemoryStream()) using (BinaryWriter writer = new BinaryWriter(stream)) { writer.Write(action.ActionId.ToByteArray()); writer.Write((ushort)action.Command); writer.Write(action.Revision); return stream.ToArray(); }
    }

    internal static TrayHostAction ReadAction(byte[] payload)
    {
        using (MemoryStream stream = new MemoryStream(payload ?? new byte[0]))
        using (BinaryReader reader = new BinaryReader(stream))
        {
            byte[] idBytes = reader.ReadBytes(16); if (idBytes.Length != 16) { throw new ProtocolViolationException("action id is truncated"); }
            TrayCommand command = (TrayCommand)reader.ReadUInt16(); ulong revision = reader.ReadUInt64(); RequireEnd(stream);
            try { return new TrayHostAction(new Guid(idBytes), command, revision); } catch (ArgumentException error) { throw new ProtocolViolationException(error.Message); }
        }
    }

    internal static byte[] WriteActionResult(TrayActionResult result)
    {
        if (result == null) { throw new ArgumentNullException("result"); }
        using (MemoryStream stream = new MemoryStream())
        using (BinaryWriter writer = new BinaryWriter(stream, Utf8))
        {
            writer.Write(result.ActionId.ToByteArray()); writer.Write(result.Revision); writer.Write((byte)result.Status);
            bool hasError = !String.IsNullOrEmpty(result.ErrorCode); writer.Write(hasError); if (hasError) { WriteString(writer, result.ErrorCode, 96); }
            bool hasTransaction = result.TransactionId.HasValue; writer.Write(hasTransaction); if (hasTransaction) { writer.Write(result.TransactionId.Value.ToByteArray()); }
            return stream.ToArray();
        }
    }

    internal static TrayActionResult ReadActionResult(byte[] payload)
    {
        try
        {
            using (MemoryStream stream = new MemoryStream(payload ?? new byte[0]))
            using (BinaryReader reader = new BinaryReader(stream, Utf8))
            {
                byte[] actionIdBytes = reader.ReadBytes(16); if (actionIdBytes.Length != 16) { throw new ProtocolViolationException("action result id is truncated"); }
                ulong revision = reader.ReadUInt64(); TrayActionResultStatus status = (TrayActionResultStatus)reader.ReadByte();
                bool hasError = ReadCanonicalBoolean(reader); string errorCode = hasError ? ReadString(reader, 96) : null;
                bool hasTransaction = ReadCanonicalBoolean(reader); Guid? transactionId = null;
                if (hasTransaction) { byte[] transactionBytes = reader.ReadBytes(16); if (transactionBytes.Length != 16) { throw new ProtocolViolationException("action result transaction is truncated"); } transactionId = new Guid(transactionBytes); }
                RequireEnd(stream);
                try { return new TrayActionResult(new Guid(actionIdBytes), revision, status, errorCode, transactionId); } catch (ArgumentException error) { throw new ProtocolViolationException(error.Message); }
            }
        }
        catch (EndOfStreamException) { throw new ProtocolViolationException("action result is truncated"); }
    }

    private static void WriteString(BinaryWriter writer, string value, int maximumChars)
    {
        if (value == null || value.Length == 0 || value.Length > maximumChars) { throw new ProtocolViolationException("string length is invalid"); }
        for (int i = 0; i < value.Length; i++) { if (Char.IsControl(value[i])) { throw new ProtocolViolationException("string contains a control character"); } }
        byte[] bytes = Utf8.GetBytes(value); if (bytes.Length > 1024 || bytes.Length > UInt16.MaxValue) { throw new ProtocolViolationException("string byte length is invalid"); }
        writer.Write((ushort)bytes.Length); writer.Write(bytes);
    }

    private static string ReadString(BinaryReader reader, int maximumChars)
    {
        int length = reader.ReadUInt16(); if (length == 0 || length > 1024) { throw new ProtocolViolationException("string byte length is invalid"); }
        byte[] bytes = reader.ReadBytes(length); if (bytes.Length != length) { throw new ProtocolViolationException("string is truncated"); }
        string value; try { value = Utf8.GetString(bytes); } catch (DecoderFallbackException) { throw new ProtocolViolationException("string UTF-8 is invalid"); }
        if (value.Length == 0 || value.Length > maximumChars) { throw new ProtocolViolationException("string character length is invalid"); }
        for (int i = 0; i < value.Length; i++) { if (Char.IsControl(value[i])) { throw new ProtocolViolationException("string contains a control character"); } }
        return value;
    }

    private static bool ReadCanonicalBoolean(BinaryReader reader)
    {
        byte value = reader.ReadByte();
        if (value > 1) { throw new ProtocolViolationException("boolean is noncanonical"); }
        return value == 1;
    }

    private static void RequireEnd(Stream stream) { if (stream.Position != stream.Length) { throw new ProtocolViolationException("payload has trailing bytes"); } }
}
