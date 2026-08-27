using System;
using System.IO;

internal sealed class TrayTerminalDiagnostic
{
    internal TrayCommand Command { get; private set; }
    internal ulong Revision { get; private set; }
    internal TrayActionResultStatus Status { get; private set; }
    internal string Code { get; private set; }

    internal TrayTerminalDiagnostic(TrayCommand command, ulong revision, TrayActionResultStatus status, string errorCode)
    {
        if (!TrayCommandPolicy.IsWireCommand(command) || revision == 0UL || status == TrayActionResultStatus.Accepted || !Enum.IsDefined(typeof(TrayActionResultStatus), status)) { throw new ArgumentException("terminal diagnostic is invalid"); }
        string code = status == TrayActionResultStatus.Completed ? "CCOD_TRAY_ACTION_COMPLETED" : errorCode;
        if (!TrayCommandPolicy.IsCanonicalErrorCode(code)) { code = "CCOD_TRAY_ACTION_FAILED"; }
        Command = command; Revision = revision; Status = status; Code = code;
    }
}

internal static class TrayTerminalDiagnosticLog
{
    private static readonly object Gate = new object();

    internal static bool TryAppend(string path, TrayTerminalDiagnostic record)
    {
        if (String.IsNullOrEmpty(path) || record == null) { return false; }
        try
        {
            string line = "command=" + record.Command.ToString() + " revision=" + record.Revision.ToString(System.Globalization.CultureInfo.InvariantCulture) + " status=" + record.Status.ToString() + " code=" + record.Code + Environment.NewLine;
            lock (Gate) { File.AppendAllText(path, line); }
            return true;
        }
        catch { return false; }
    }
}
