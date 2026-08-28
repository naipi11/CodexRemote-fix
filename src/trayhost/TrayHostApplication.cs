using System;
using System.Diagnostics;
using System.IO;

internal sealed class TrayHostApplication : IDisposable
{
    private readonly TrayWindow _window;
    private readonly INativeTrayPlatform _platform;
    private readonly Action<TrayCommand, ulong> _command;
    private readonly Action _work;
    private readonly Action<uint> _receiptWork;
    private readonly uint _taskbarCreated;
    private bool _exitRequested;

    internal TrayHostApplication(TrayWindow window)
    {
        if (window == null) { throw new ArgumentNullException("window"); }
        _window = window;
    }

    internal TrayHostApplication(INativeTrayPlatform platform, TrayWindow window, Action<TrayCommand, ulong> command, Action work)
        : this(platform, window, command, work, null)
    {
    }

    internal TrayHostApplication(INativeTrayPlatform platform, TrayWindow window, Action<TrayCommand, ulong> command, Action work, Action<uint> receiptWork)
    {
        if (platform == null) { throw new ArgumentNullException("platform"); }
        if (window == null) { throw new ArgumentNullException("window"); }
        _platform = platform; _window = window; _command = command; _work = work; _receiptWork = receiptWork; _taskbarCreated = (uint)Win32TrayPlatform.RegisterTaskbarCreatedMessage().ToInt64();
        _platform.SetMessageHandler(HandleMessage);
    }

    internal TrayWindow Window { get { return _window; } }

    internal int Run()
    {
        if (_platform == null) { return 0; }
        while (!_exitRequested)
        {
            Win32TrayPlatform.Message message;
            int result = Win32TrayPlatform.GetMessageLoop(out message);
            if (result <= 0) { break; }
            Win32TrayPlatform.TranslateAndDispatch(message);
        }
        return 0;
    }

    internal void PostWork() { if (_platform != null && _window.OwnerHandle != IntPtr.Zero) { _platform.PostMessage(_window.OwnerHandle, TrayNativeConstants.WmApp + 2U, UIntPtr.Zero, IntPtr.Zero); } }
    internal bool PostReceiptWork(uint token) { return token != 0U && _platform != null && _window.OwnerHandle != IntPtr.Zero && _platform.PostMessage(_window.OwnerHandle, TrayNativeConstants.WmApp + 3U, new UIntPtr(token), IntPtr.Zero); }
    internal void RequestExit()
    {
        if (_exitRequested) { return; }
        _exitRequested = true;
        _window.RequestShutdown();
        Win32TrayPlatform.PostQuit(0);
    }

    internal static bool IsContextMenuEvent(uint message, IntPtr callbackData)
    {
        return IsContextMenuEvent(message, IntPtr.Zero, callbackData);
    }

    internal static bool TryDecodeReceiptWorkToken(uint message, IntPtr wParam, IntPtr lParam, out uint token)
    {
        token = 0U;
        if (message != TrayNativeConstants.WmApp + 3U || lParam != IntPtr.Zero) { return false; }
        ulong raw = IntPtr.Size == 4 ? unchecked((uint)wParam.ToInt32()) : unchecked((ulong)wParam.ToInt64());
        if (raw == 0UL || raw > UInt32.MaxValue) { return false; }
        token = unchecked((uint)raw); return true;
    }

    internal static bool IsContextMenuEvent(uint message, IntPtr wParam, IntPtr lParam)
    {
        const uint wmContextMenu = 0x007bU;
        const uint wmRButtonDown = 0x0204U;
        const uint wmRButtonUp = 0x0205U;
        if (message == wmContextMenu || message == wmRButtonDown || message == wmRButtonUp) { return true; }
        if (message != TrayNativeConstants.WmApp + 1U) { return false; }
        return HasContextMenuEvent(wParam, wmContextMenu, wmRButtonDown, wmRButtonUp) ||
               HasContextMenuEvent(lParam, wmContextMenu, wmRButtonDown, wmRButtonUp);
    }

    private static bool HasContextMenuEvent(IntPtr value, uint wmContextMenu, uint wmRButtonDown, uint wmRButtonUp)
    {
        uint eventCode = unchecked((uint)value.ToInt64());
        return (eventCode & 0xffffU) == wmContextMenu || (eventCode & 0xffffU) == wmRButtonDown || (eventCode & 0xffffU) == wmRButtonUp ||
               ((eventCode >> 16) & 0xffffU) == wmContextMenu || ((eventCode >> 16) & 0xffffU) == wmRButtonDown || ((eventCode >> 16) & 0xffffU) == wmRButtonUp;
    }

    private void HandleMessage(uint message, IntPtr wParam, IntPtr lParam)
    {
        uint receiptToken;
        if (TryDecodeReceiptWorkToken(message, wParam, lParam, out receiptToken))
        {
            Action<uint> receiptWork = _receiptWork; if (receiptWork != null) { receiptWork(receiptToken); }
            return;
        }
        if (message == TrayNativeConstants.WmApp + 2U)
        {
            Action work = _work; if (work != null) { work(); }
            return;
        }
        if (message == _taskbarCreated)
        {
            _window.ReAddAfterTaskbarCreated();
            return;
        }
        if (message == 0x0012U || message == 0x0016U || message == 0x0011U)
        {
            RequestExit(); return;
        }
        if (IsContextMenuEvent(message, wParam, lParam))
        {
            TrayPoint point;
            if (!Win32TrayPlatform.GetCursorPosition(out point)) { point = new TrayPoint(0, 0); }
            WriteDiagnostic("callback message=" + message.ToString("x") + " wParam=" + wParam.ToInt64().ToString("x") + " lParam=" + lParam.ToInt64().ToString("x") + " revision=" + _window.CurrentRevision.ToString() + " menuOpen=" + _window.MenuOpen.ToString());
            try
            {
                uint? result = _window.HandleContextMenu(point);
                WriteDiagnostic("callback handled result=" + (result.HasValue ? result.Value.ToString() : "null") + " revision=" + _window.CurrentRevision.ToString());
            }
            catch (Exception error)
            {
                WriteDiagnostic("callback error=" + error.GetType().Name);
            }
        }
    }

    private static void WriteDiagnostic(string message)
    {
        try
        {
            string root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CodexControlOtherDevices", "logs");
            Directory.CreateDirectory(root);
            string path = Path.Combine(root, "trayhost-callback.log");
            File.AppendAllText(path, DateTime.UtcNow.ToString("o") + " pid=" + Process.GetCurrentProcess().Id.ToString() + " " + message + Environment.NewLine);
            FileInfo info = new FileInfo(path);
            if (info.Length > 64 * 1024) { File.WriteAllText(path, DateTime.UtcNow.ToString("o") + " pid=" + Process.GetCurrentProcess().Id.ToString() + " log-truncated" + Environment.NewLine); }
        }
        catch { }
    }

    public void Dispose()
    {
        _window.Dispose();
    }
}
