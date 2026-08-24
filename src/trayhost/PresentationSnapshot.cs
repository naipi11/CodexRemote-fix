using System;
using System.Collections.Generic;

public enum TrayColor : byte { Gray = 0, Green = 1, Yellow = 2, Red = 3 }
public enum LanguageMode : byte { System = 0, Chinese = 1, English = 2 }
public enum ConnectionState : byte { WaitingForCodex = 0, Checking = 1, Connected = 2, RepairNeeded = 3, Error = 4 }
public enum ProtectionState : byte { Running = 0, Reconnecting = 1, Stopping = 2 }

[Flags]
public enum PresentationFlags : uint
{
    None = 0,
    RepairEnabled = 1u << 0,
    LanguageEnabled = 1u << 1,
    OpenLogsEnabled = 1u << 2,
    AboutEnabled = 1u << 3,
    ExitEnabled = 1u << 4,
    Busy = 1u << 5
}

public sealed class PresentationSnapshot
{
    public ulong Revision { get; private set; }
    public TrayColor Color { get; private set; }
    public ConnectionState Connection { get; private set; }
    public ProtectionState Protection { get; private set; }
    public LanguageMode Language { get; private set; }
    public PresentationFlags Flags { get; private set; }
    public IReadOnlyList<string> Strings { get; private set; }

    public PresentationSnapshot(ulong revision, TrayColor color, ConnectionState connection, ProtectionState protection, LanguageMode language, PresentationFlags flags, string[] strings)
    {
        if (revision == 0UL) { throw new ArgumentException("revision must be positive", "revision"); }
        if (!Enum.IsDefined(typeof(TrayColor), color) || !Enum.IsDefined(typeof(ConnectionState), connection) || !Enum.IsDefined(typeof(ProtectionState), protection) || !Enum.IsDefined(typeof(LanguageMode), language)) { throw new ArgumentException("presentation enum is invalid"); }
        if ((((uint)flags) & ~0x0000003fu) != 0u) { throw new ArgumentException("presentation flags are invalid", "flags"); }
        if (strings == null || strings.Length != 16) { throw new ArgumentException("presentation string count is invalid", "strings"); }
        string[] copy = (string[])strings.Clone();
        for (int i = 0; i < copy.Length; i++)
        {
            if (String.IsNullOrEmpty(copy[i]) || copy[i].Length > 300) { throw new ArgumentException("presentation string length is invalid", "strings"); }
            for (int j = 0; j < copy[i].Length; j++) { if (Char.IsControl(copy[i][j])) { throw new ArgumentException("presentation string contains a control character", "strings"); } }
        }
        Revision = revision;
        Color = color;
        Connection = connection;
        Protection = protection;
        Language = language;
        Flags = flags;
        Strings = Array.AsReadOnly(copy);
    }
}
