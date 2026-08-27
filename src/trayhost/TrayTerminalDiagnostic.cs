using System;
using System.IO;
using System.Text;

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
    internal const long MaximumBytes = 64L * 1024L;
    private static readonly object Gate = new object();

    internal static bool TryGetDefaultPath(out string path)
    {
        path = null;
        try
        {
            string local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            if (String.IsNullOrEmpty(local) || !Path.IsPathRooted(local) || !IsSafeExistingDirectory(local)) { return false; }
            string product = Path.Combine(local, "CodexControlOtherDevices");
            if (!TryCreateSafeChildDirectory(product)) { return false; }
            string logs = Path.Combine(product, "logs");
            if (!TryCreateSafeChildDirectory(logs)) { return false; }
            path = Path.Combine(logs, "trayhost-actions.log");
            return IsSafePath(path);
        }
        catch { path = null; return false; }
    }

    internal static bool TryAppend(string path, TrayTerminalDiagnostic record)
    {
        if (String.IsNullOrEmpty(path) || record == null || !Path.IsPathRooted(path)) { return false; }
        try
        {
            string line = "command=" + record.Command.ToString() + " revision=" + record.Revision.ToString(System.Globalization.CultureInfo.InvariantCulture) + " status=" + record.Status.ToString() + " code=" + record.Code + Environment.NewLine;
            byte[] bytes = new UTF8Encoding(false).GetBytes(line);
            if (bytes.LongLength > MaximumBytes) { return false; }
            string full = Path.GetFullPath(path);
            lock (Gate)
            {
                if (!IsSafePath(full)) { return false; }
                FileMode mode = File.Exists(full) && new FileInfo(full).Length + bytes.LongLength <= MaximumBytes ? FileMode.Append : FileMode.Create;
                using (FileStream stream = new FileStream(full, mode, FileAccess.Write, FileShare.Read))
                {
                    stream.Write(bytes, 0, bytes.Length);
                    stream.Flush(true);
                }
            }
            return true;
        }
        catch { return false; }
    }

    private static bool TryCreateSafeChildDirectory(string path)
    {
        if (Directory.Exists(path)) { return IsSafeExistingDirectory(path); }
        string parent = Path.GetDirectoryName(path);
        if (String.IsNullOrEmpty(parent) || !IsSafeExistingDirectory(parent)) { return false; }
        Directory.CreateDirectory(path);
        return IsSafeExistingDirectory(path);
    }

    private static bool IsSafePath(string path)
    {
        if (!Path.IsPathRooted(path) || !String.Equals(Path.GetFileName(path), "trayhost-actions.log", StringComparison.OrdinalIgnoreCase) || Directory.Exists(path)) { return false; }
        if (File.Exists(path) && (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0) { return false; }
        string directory = Path.GetDirectoryName(path);
        return !String.IsNullOrEmpty(directory) && IsSafeExistingDirectory(directory);
    }

    private static bool IsSafeExistingDirectory(string path)
    {
        DirectoryInfo current = new DirectoryInfo(path);
        if (!current.Exists) { return false; }
        while (current != null)
        {
            if (!current.Exists || (current.Attributes & FileAttributes.ReparsePoint) != 0) { return false; }
            current = current.Parent;
        }
        return true;
    }
}
