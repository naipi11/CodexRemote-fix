using System;

internal sealed class WindowsTrayHostRuntime : ITrayHostRuntime
{
    private Win32TrayPlatform _platform;
    private TrayWindow _window;
    private TrayHostApplication _application;
    private bool _disposed;

    public ulong CurrentRevision { get { return _window == null ? 0UL : _window.CurrentRevision; } }

    public void Initialize(Action<bool> menuOpenChanged, Action<TrayCommand, ulong> commandSelected, Action work, Action<uint> receiptWork)
    {
        if (_disposed || _application != null || commandSelected == null || work == null || receiptWork == null) { throw new InvalidOperationException("Windows tray runtime initialization is invalid"); }
        _platform = new Win32TrayPlatform();
        _window = new TrayWindow(_platform, menuOpenChanged);
        _window.CommandSelected += commandSelected;
        _application = new TrayHostApplication(_platform, _window, commandSelected, work, receiptWork);
    }

    public void Create(PresentationSnapshot initial) { RequireWindow().Create(initial); }
    public bool Apply(PresentationSnapshot snapshot) { return RequireWindow().Apply(snapshot); }
    public void PostWork()
    {
        TrayHostApplication application = _application;
        if (!_disposed && application != null) { application.PostWork(); }
    }

    public bool PostReceiptWork(uint token)
    {
        TrayHostApplication application = _application;
        return !_disposed && application != null && application.PostReceiptWork(token);
    }
    public void ShowAbout() { RequireWindow().ShowAbout(); }
    public void ShowActionFailed() { RequireWindow().ShowActionFailed(); }
    public void RequestShutdown()
    {
        TrayWindow window = _window;
        if (!_disposed && window != null) { window.RequestShutdown(); }
    }

    public void RequestExit()
    {
        TrayHostApplication application = _application;
        if (!_disposed && application != null) { application.RequestExit(); }
    }
    public int Run() { return RequireApplication().Run(); }

    public void Dispose()
    {
        if (_disposed) { return; }
        _disposed = true;
        if (_application != null) { _application.Dispose(); }
        else if (_window != null) { _window.Dispose(); }
        _application = null;
        _window = null;
        _platform = null;
    }

    private TrayWindow RequireWindow()
    {
        if (_disposed || _window == null) { throw new InvalidOperationException("Windows tray runtime is unavailable"); }
        return _window;
    }

    private TrayHostApplication RequireApplication()
    {
        if (_disposed || _application == null) { throw new InvalidOperationException("Windows tray runtime is unavailable"); }
        return _application;
    }
}
