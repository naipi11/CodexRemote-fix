using System;

public enum TrayHostHealth : byte
{
    Starting = 0,
    Ready = 1,
    Stopping = 2,
    Stopped = 3,
    Faulted = 4
}

public enum ShutdownReason : byte
{
    SupervisorExit = 1,
    Upgrade = 2,
    Uninstall = 3,
    ParentFault = 4
}

internal enum TrayHostControlKind : byte
{
    PresentationAck = 1,
    Shutdown = 2,
    ShutdownAck = 3,
    Ping = 4,
    Pong = 5,
    Fault = 6,
    UiReady = 7
}

internal enum TrayHostOutboundKind : byte
{
    Presentation = 1,
    Control = 2,
    Action = 3,
    ActionResult = 4
}

public enum TrayHostEventKind : byte
{
    PresentationAck = 1,
    Action = 2,
    Fault = 3,
    Exited = 4
}

public enum TrayActionResultStatus : byte
{
    Accepted = 1,
    Completed = 2,
    Rejected = 3,
    Failed = 4
}

internal static class TrayCommandPolicy
{
    internal static bool IsWireCommand(TrayCommand command)
    {
        return command == TrayCommand.CheckAndRepair || command == TrayCommand.SetLanguageSystem ||
            command == TrayCommand.SetLanguageChinese || command == TrayCommand.SetLanguageEnglish ||
            command == TrayCommand.OpenLogs || command == TrayCommand.ShowAbout || command == TrayCommand.Exit;
    }

    internal static bool RequiresAcceptedBeforeCompleted(TrayCommand command)
    {
        return command == TrayCommand.CheckAndRepair || command == TrayCommand.Exit;
    }

    internal static bool RequiresTransactionWhenAccepted(TrayCommand command)
    {
        return command == TrayCommand.CheckAndRepair || command == TrayCommand.Exit;
    }

    internal static bool IsCanonicalErrorCode(string value)
    {
        if (String.IsNullOrEmpty(value) || value.Length <= 5 || value.Length > 96 || !value.StartsWith("CCOD_", StringComparison.Ordinal)) { return false; }
        for (int index = 5; index < value.Length; index++)
        {
            char current = value[index];
            if ((current < 'A' || current > 'Z') && (current < '0' || current > '9') && current != '_') { return false; }
        }
        return true;
    }
}

public sealed class TrayActionResult
{
    public Guid ActionId { get; private set; }
    public ulong Revision { get; private set; }
    public TrayActionResultStatus Status { get; private set; }
    public string ErrorCode { get; private set; }
    public Guid? TransactionId { get; private set; }

    public TrayActionResult(Guid actionId, ulong revision, TrayActionResultStatus status, string errorCode, Guid? transactionId)
    {
        if (actionId == Guid.Empty || revision == 0UL || !Enum.IsDefined(typeof(TrayActionResultStatus), status)) { throw new ArgumentException("action result is invalid"); }
        bool success = status == TrayActionResultStatus.Accepted || status == TrayActionResultStatus.Completed;
        if (success && !String.IsNullOrEmpty(errorCode)) { throw new ArgumentException("successful action result has an error", "errorCode"); }
        if (!success && !TrayCommandPolicy.IsCanonicalErrorCode(errorCode)) { throw new ArgumentException("action result error code is invalid", "errorCode"); }
        if (transactionId.HasValue && transactionId.Value == Guid.Empty) { throw new ArgumentException("action result transaction is invalid", "transactionId"); }
        ActionId = actionId; Revision = revision; Status = status; ErrorCode = errorCode; TransactionId = transactionId;
    }
}

public sealed class TrayHostEvent
{
    public TrayHostEventKind Kind { get; internal set; }
    public Guid ActionId { get; internal set; }
    public TrayCommand Command { get; internal set; }
    public ulong Revision { get; internal set; }
    public bool? BoolValue { get; internal set; }
    public LanguageMode? LanguageValue { get; internal set; }
    public string ErrorCode { get; internal set; }

    internal static TrayHostEvent Ack(ulong revision) { return new TrayHostEvent { Kind = TrayHostEventKind.PresentationAck, Revision = revision }; }
    internal static TrayHostEvent Action(TrayHostAction action) { return new TrayHostEvent { Kind = TrayHostEventKind.Action, ActionId = action.ActionId, Command = action.Command, Revision = action.Revision, BoolValue = action.BoolValue, LanguageValue = action.LanguageValue }; }
    internal static TrayHostEvent Fault(string code) { return new TrayHostEvent { Kind = TrayHostEventKind.Fault, ErrorCode = code ?? "CCOD_TRAYHOST_FAULT" }; }
    internal static TrayHostEvent Exited() { return new TrayHostEvent { Kind = TrayHostEventKind.Exited }; }
}

internal sealed class TrayHostControl
{
    internal TrayHostControlKind Kind { get; private set; }
    internal ShutdownReason Reason { get; private set; }
    internal ulong Revision { get; private set; }
    internal string ErrorCode { get; private set; }

    internal TrayHostControl(TrayHostControlKind kind, ShutdownReason reason, ulong revision)
    {
        Kind = kind;
        Reason = reason;
        Revision = revision;
    }

    internal TrayHostControl(TrayHostControlKind kind, string errorCode)
    {
        Kind = kind;
        ErrorCode = errorCode ?? String.Empty;
    }

}

internal sealed class TrayHostAction
{
    internal Guid ActionId { get; private set; }
    internal TrayCommand Command { get; private set; }
    internal ulong Revision { get; private set; }
    internal bool? BoolValue { get; private set; }
    internal LanguageMode? LanguageValue { get; private set; }

    internal TrayHostAction(Guid actionId, TrayCommand command, ulong revision)
    {
        if (actionId == Guid.Empty) { throw new ArgumentException("action id is required", "actionId"); }
        if (revision == 0UL || !TrayCommandPolicy.IsWireCommand(command)) { throw new ArgumentException("command is invalid", "command"); }
        ActionId = actionId;
        Command = command;
        Revision = revision;
    }

    internal TrayHostAction(Guid actionId, TrayCommand command, ulong revision, bool? boolValue, LanguageMode? languageValue)
        : this(actionId, command, revision)
    {
        BoolValue = boolValue; LanguageValue = languageValue;
    }
}

internal sealed class TrayHostOutbound
{
    internal TrayHostOutboundKind Kind { get; private set; }
    internal PresentationSnapshot Presentation { get; private set; }
    internal TrayHostControl Control { get; private set; }
    internal TrayHostAction Action { get; private set; }
    internal TrayActionResult ActionResult { get; private set; }

    internal static TrayHostOutbound FromPresentation(PresentationSnapshot value) { return new TrayHostOutbound { Kind = TrayHostOutboundKind.Presentation, Presentation = value }; }
    internal static TrayHostOutbound FromControl(TrayHostControl value) { return new TrayHostOutbound { Kind = TrayHostOutboundKind.Control, Control = value }; }
    internal static TrayHostOutbound FromAction(TrayHostAction value) { return new TrayHostOutbound { Kind = TrayHostOutboundKind.Action, Action = value }; }
    internal static TrayHostOutbound FromActionResult(TrayActionResult value) { return new TrayHostOutbound { Kind = TrayHostOutboundKind.ActionResult, ActionResult = value }; }
}
