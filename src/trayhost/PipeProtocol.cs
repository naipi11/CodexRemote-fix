using System;
using System.IO;
using System.Security.Cryptography;
using System.Text;

internal enum ProtocolDirection : byte
{
    ParentToHost = 1,
    HostToParent = 2
}

internal enum TrayHostMessageType : ushort
{
    ParentHello = 1,
    HostHello = 2,
    Presentation = 3,
    PresentationAck = 4,
    Action = 5,
    ActionResult = 6,
    Ping = 7,
    Pong = 8,
    Shutdown = 9,
    ShutdownAck = 10,
    Fault = 11,
    UiReady = 12
}

public enum TrayCommand : ushort
{
    None = 0,
    CheckAndRepair = 2001,
    SetLanguageSystem = 2002,
    SetLanguageChinese = 2003,
    SetLanguageEnglish = 2004,
    OpenLogs = 2005,
    ShowAbout = 2006,
    Exit = 2007
}

internal sealed class ProtocolViolationException : IOException
{
    internal ProtocolViolationException(string message) : base(message) { }
}

internal sealed class ProtocolFrame
{
    internal ProtocolDirection Direction { get; private set; }
    internal TrayHostMessageType MessageType { get; private set; }
    internal ulong Epoch { get; private set; }
    internal ulong Sequence { get; private set; }
    internal byte[] Payload { get; private set; }
    internal byte[] Tag { get; private set; }

    private ProtocolFrame(ProtocolDirection direction, TrayHostMessageType messageType, ulong epoch, ulong sequence, byte[] payload, byte[] tag)
    {
        Direction = direction;
        MessageType = messageType;
        Epoch = epoch;
        Sequence = sequence;
        Payload = payload ?? new byte[0];
        Tag = tag ?? new byte[32];
    }

    internal static ProtocolFrame Bootstrap(ProtocolDirection direction, TrayHostMessageType messageType, byte[] payload)
    {
        if ((direction == ProtocolDirection.ParentToHost && messageType != TrayHostMessageType.ParentHello) ||
            (direction == ProtocolDirection.HostToParent && messageType != TrayHostMessageType.HostHello))
        {
            throw new ProtocolViolationException("bootstrap message direction is invalid");
        }
        return new ProtocolFrame(direction, messageType, 0UL, 0UL, payload, new byte[32]);
    }

    internal static ProtocolFrame Authenticated(ProtocolDirection direction, TrayHostMessageType messageType, ulong epoch, ulong sequence, byte[] payload)
    {
        if (epoch == 0UL || sequence == 0UL) { throw new ProtocolViolationException("authenticated frame identity is invalid"); }
        return new ProtocolFrame(direction, messageType, epoch, sequence, payload, new byte[32]);
    }

    internal ProtocolFrame WithTag(byte[] tag)
    {
        if (tag == null || tag.Length != 32) { throw new ProtocolViolationException("frame tag length is invalid"); }
        return new ProtocolFrame(Direction, MessageType, Epoch, Sequence, Payload, (byte[])tag.Clone());
    }
}

internal sealed class SessionKeys
{
    internal byte[] ParentToHost { get; private set; }
    internal byte[] HostToParent { get; private set; }
    internal ulong HostEpoch { get; private set; }

    internal SessionKeys(byte[] parentToHost, byte[] hostToParent, ulong hostEpoch)
    {
        ParentToHost = parentToHost;
        HostToParent = hostToParent;
        HostEpoch = hostEpoch;
    }
}

internal static class HkdfSha256
{
    internal static byte[] Derive(byte[] ikm, byte[] salt, byte[] info, int length)
    {
        if (ikm == null || salt == null || info == null || length < 0 || length > 255 * 32) { throw new ProtocolViolationException("HKDF input is invalid"); }
        byte[] prk;
        using (HMACSHA256 hmac = new HMACSHA256(salt)) { prk = hmac.ComputeHash(ikm); }
        byte[] output = new byte[length];
        byte[] previous = new byte[0];
        int written = 0;
        byte counter = 1;
        while (written < length)
        {
            byte[] input = new byte[previous.Length + info.Length + 1];
            Buffer.BlockCopy(previous, 0, input, 0, previous.Length);
            Buffer.BlockCopy(info, 0, input, previous.Length, info.Length);
            input[input.Length - 1] = counter++;
            using (HMACSHA256 hmac = new HMACSHA256(prk)) { previous = hmac.ComputeHash(input); }
            int copy = Math.Min(previous.Length, length - written);
            Buffer.BlockCopy(previous, 0, output, written, copy);
            written += copy;
        }
        return output;
    }
}

internal static class ProtocolCodec
{
    internal const ushort ProtocolMajor = 2;
    internal const int HeaderSize = 60;
    internal const int MaximumPayload = 16 * 1024;
    private static readonly byte[] Magic = new byte[] { (byte)'C', (byte)'R', (byte)'T', (byte)'H' };

    internal static SessionKeys DeriveDirectionalKeys(byte[] sessionSeed, byte[] parentChallenge, byte[] hostNonce, ulong hostEpoch)
    {
        if (sessionSeed == null || sessionSeed.Length != 32 || parentChallenge == null || parentChallenge.Length != 32 || hostNonce == null || hostNonce.Length != 32 || hostEpoch == 0UL)
        {
            throw new ProtocolViolationException("handshake key material is invalid");
        }
        byte[] label = Encoding.ASCII.GetBytes("CodexRemote.TrayHost/v2");
        byte[] saltInput = new byte[label.Length + 32 + 32 + 8];
        Buffer.BlockCopy(label, 0, saltInput, 0, label.Length);
        Buffer.BlockCopy(parentChallenge, 0, saltInput, label.Length, 32);
        Buffer.BlockCopy(hostNonce, 0, saltInput, label.Length + 32, 32);
        WriteUInt64(saltInput, label.Length + 64, hostEpoch);
        byte[] salt;
        using (SHA256 sha = SHA256.Create()) { salt = sha.ComputeHash(saltInput); }
        byte[] p2h = HkdfSha256.Derive(sessionSeed, salt, Encoding.ASCII.GetBytes("CodexRemote.TrayHost/v2/parent-to-host"), 32);
        byte[] h2p = HkdfSha256.Derive(sessionSeed, salt, Encoding.ASCII.GetBytes("CodexRemote.TrayHost/v2/host-to-parent"), 32);
        return new SessionKeys(p2h, h2p, hostEpoch);
    }

    internal static void WriteBootstrap(Stream output, ProtocolFrame frame)
    {
        if (output == null || frame == null || frame.Epoch != 0UL || frame.Sequence != 0UL || frame.Tag.Length != 32 || !AllZero(frame.Tag)) { throw new ProtocolViolationException("bootstrap frame is invalid"); }
        WriteFrame(output, frame);
    }

    internal static ProtocolFrame ReadBootstrap(Stream input, ProtocolDirection expectedDirection)
    {
        ProtocolFrame frame = ReadFrame(input, expectedDirection, true, null, 0UL, 0UL);
        if ((expectedDirection == ProtocolDirection.ParentToHost && frame.MessageType != TrayHostMessageType.ParentHello) ||
            (expectedDirection == ProtocolDirection.HostToParent && frame.MessageType != TrayHostMessageType.HostHello))
        {
            throw new ProtocolViolationException("bootstrap message type is invalid");
        }
        return frame;
    }

    internal static void WriteAuthenticated(Stream output, ProtocolFrame frame, byte[] key)
    {
        if (output == null || frame == null || key == null || key.Length != 32 || frame.Epoch == 0UL || frame.Sequence == 0UL) { throw new ProtocolViolationException("authenticated frame is invalid"); }
        using (HMACSHA256 hmac = new HMACSHA256(key)) { frame = frame.WithTag(hmac.ComputeHash(AuthenticationBytes(frame))); }
        WriteFrame(output, frame);
    }

    internal static ProtocolFrame ReadAuthenticated(Stream input, ProtocolDirection expectedDirection, ulong expectedEpoch, ulong expectedSequence, byte[] key)
    {
        if (key == null || key.Length != 32 || expectedEpoch == 0UL || expectedSequence == 0UL) { throw new ProtocolViolationException("authenticated identity is invalid"); }
        return ReadFrame(input, expectedDirection, false, key, expectedEpoch, expectedSequence);
    }

    private static void WriteFrame(Stream output, ProtocolFrame frame)
    {
        byte[] header = HeaderBytes(frame, false);
        output.Write(header, 0, header.Length);
        if (frame.Payload.Length > 0) { output.Write(frame.Payload, 0, frame.Payload.Length); }
        output.Flush();
    }

    private static ProtocolFrame ReadFrame(Stream input, ProtocolDirection direction, bool bootstrap, byte[] key, ulong expectedEpoch, ulong expectedSequence)
    {
        byte[] header = ReadExact(input, HeaderSize);
        if (bootstrap && header[0] == 0xEF && header[1] == 0xBB && header[2] == 0xBF)
        {
            Buffer.BlockCopy(header, 3, header, 0, HeaderSize - 3);
            byte[] tail = ReadExact(input, 3);
            Buffer.BlockCopy(tail, 0, header, HeaderSize - 3, 3);
        }
        for (int i = 0; i < 4; i++) { if (header[i] != Magic[i]) { throw new ProtocolViolationException("frame magic is invalid"); } }
        ushort version = BitConverter.ToUInt16(header, 4);
        ushort typeValue = BitConverter.ToUInt16(header, 6);
        uint payloadLength = BitConverter.ToUInt32(header, 8);
        ulong epoch = BitConverter.ToUInt64(header, 12);
        ulong sequence = BitConverter.ToUInt64(header, 20);
        if (version != ProtocolMajor || payloadLength > MaximumPayload) { throw new ProtocolViolationException("frame header is invalid"); }
        if (bootstrap != (epoch == 0UL && sequence == 0UL)) { throw new ProtocolViolationException("frame phase is invalid"); }
        if (!bootstrap && (epoch != expectedEpoch || sequence != expectedSequence)) { throw new ProtocolViolationException("frame replay identity is invalid"); }
        byte[] tag = new byte[32];
        Buffer.BlockCopy(header, 28, tag, 0, 32);
        if (bootstrap && !AllZero(tag)) { throw new ProtocolViolationException("bootstrap tag is not zero"); }
        byte[] payload = ReadExact(input, checked((int)payloadLength));
        TrayHostMessageType messageType = (TrayHostMessageType)typeValue;
        if (!Enum.IsDefined(typeof(TrayHostMessageType), messageType)) { throw new ProtocolViolationException("message type is invalid"); }
        ProtocolFrame frame = bootstrap ? ProtocolFrame.Bootstrap(direction, messageType, payload) : ProtocolFrame.Authenticated(direction, messageType, epoch, sequence, payload);
        if (!bootstrap)
        {
            byte[] expectedTag;
            using (HMACSHA256 hmac = new HMACSHA256(key)) { expectedTag = hmac.ComputeHash(AuthenticationBytes(frame)); }
            if (!FixedEquals(expectedTag, tag)) { throw new ProtocolViolationException("frame HMAC is invalid"); }
        }
        return frame.WithTag(tag);
    }

    private static byte[] AuthenticationBytes(ProtocolFrame frame)
    {
        byte[] header = HeaderBytes(frame, true);
        byte[] input = new byte[HeaderSize + frame.Payload.Length];
        Buffer.BlockCopy(header, 0, input, 0, HeaderSize);
        Buffer.BlockCopy(frame.Payload, 0, input, HeaderSize, frame.Payload.Length);
        return input;
    }

    private static byte[] HeaderBytes(ProtocolFrame frame, bool zeroTag)
    {
        byte[] header = new byte[HeaderSize];
        Buffer.BlockCopy(Magic, 0, header, 0, 4);
        WriteUInt16(header, 4, ProtocolMajor);
        WriteUInt16(header, 6, (ushort)frame.MessageType);
        WriteUInt32(header, 8, (uint)frame.Payload.Length);
        WriteUInt64(header, 12, frame.Epoch);
        WriteUInt64(header, 20, frame.Sequence);
        if (!zeroTag)
        {
            Buffer.BlockCopy(frame.Tag, 0, header, 28, 32);
        }
        return header;
    }

    private static byte[] ReadExact(Stream input, int count)
    {
        byte[] bytes = new byte[count];
        int offset = 0;
        while (offset < count)
        {
            int read = input.Read(bytes, offset, count - offset);
            if (read <= 0) { throw new ProtocolViolationException("truncated frame"); }
            offset += read;
        }
        return bytes;
    }

    private static bool AllZero(byte[] bytes) { for (int i = 0; i < bytes.Length; i++) { if (bytes[i] != 0) { return false; } } return true; }
    private static bool FixedEquals(byte[] left, byte[] right) { if (left.Length != right.Length) { return false; } int diff = 0; for (int i = 0; i < left.Length; i++) { diff |= left[i] ^ right[i]; } return diff == 0; }
    private static void WriteUInt16(byte[] target, int offset, ushort value) { target[offset] = unchecked((byte)value); target[offset + 1] = unchecked((byte)(value >> 8)); }
    private static void WriteUInt32(byte[] target, int offset, uint value) { for (int i = 0; i < 4; i++) { target[offset + i] = unchecked((byte)(value >> (8 * i))); } }
    private static void WriteUInt64(byte[] target, int offset, ulong value) { for (int i = 0; i < 8; i++) { target[offset + i] = unchecked((byte)(value >> (8 * i))); } }
}
