using System;

internal sealed class TrayWindow : IDisposable
{
    private readonly INativeTrayPlatform _native;
    private InputModeGuard _inputGuard;
    private TrayIconData _icon;
    private IntPtr _owner;
    private PresentationSnapshot _current;
    private PresentationSnapshot _pending;
    private bool _created;
    private bool _menuOpen;
    private bool _disposed;

    internal event Action<TrayCommand, ulong> CommandSelected;
    internal ulong CurrentRevision { get { return _current == null ? 0UL : _current.Revision; } }
    internal bool MenuOpen { get { return _menuOpen; } }
    internal IntPtr OwnerHandle { get { return _owner; } }
    internal LanguageMode CurrentLanguage { get { return _current == null ? LanguageMode.System : _current.Language; } }

    internal TrayWindow(INativeTrayPlatform native)
    {
        if (native == null) { throw new ArgumentNullException("native"); }
        _native = native;
    }

    internal void Create(PresentationSnapshot initial)
    {
        if (_created || _disposed) { throw new InvalidOperationException("tray window lifecycle is invalid"); }
        if (initial == null) { throw new ArgumentNullException("initial"); }
        _owner = _native.CreateOwner();
        if (_owner == IntPtr.Zero) { throw new InvalidOperationException("tray owner creation failed"); }
        try
        {
            _inputGuard = new InputModeGuard(_native);
            _inputGuard.DetachOwnerInputContext(_owner);
            _inputGuard.VerifyNoOwnerInputContext(_owner);
            _icon = CreateIconData(_owner);
            if (!_native.AddIcon(ref _icon) || !_native.SetIconVersion(ref _icon)) { throw new InvalidOperationException("tray icon registration failed"); }
            _inputGuard.VerifyNoOwnerInputContext(_owner);
            _current = initial;
            _created = true;
        }
        catch
        {
            Dispose();
            throw;
        }
    }

    internal void Apply(PresentationSnapshot snapshot)
    {
        if (snapshot == null) { throw new ArgumentNullException("snapshot"); }
        if (!_created || _disposed) { throw new InvalidOperationException("tray window is not active"); }
        if (_menuOpen) { _pending = snapshot; return; }
        if (snapshot.Revision >= CurrentRevision) { _current = snapshot; }
    }

    internal uint? HandleContextMenu(TrayPoint point)
    {
        if (!_created || _disposed || _menuOpen || _current == null) { return null; }
        _menuOpen = true;
        uint result = 0U;
        try
        {
            _inputGuard.VerifyNoOwnerInputContext(_owner);
            using (NativeMenu menu = new NativeMenu(_native, _owner, _current)) { result = menu.Show(point); }
            if (result != 0U && Enum.IsDefined(typeof(TrayCommand), (ushort)result) && (TrayCommand)result != TrayCommand.None)
            {
                Action<TrayCommand, ulong> handler = CommandSelected;
                TrayCommand command = (TrayCommand)result;
                if (command == TrayCommand.Exit && !_native.ConfirmExit(_owner, _current.Strings[14], _current.Strings[13])) { return result; }
                if (handler != null) { handler(command, _current.Revision); }
            }
            return result;
        }
        finally
        {
            _menuOpen = false;
            if (_pending != null)
            {
                PresentationSnapshot pending = _pending;
                _pending = null;
                if (pending.Revision >= CurrentRevision) { _current = pending; }
            }
        }
    }

    internal void ReAddAfterTaskbarCreated()
    {
        if (!_created || _disposed) { return; }
        _native.AddIcon(ref _icon);
        _native.SetIconVersion(ref _icon);
    }

    internal void RequestShutdown()
    {
        if (_menuOpen) { _native.EndMenu(); }
    }

    private TrayIconData CreateIconData(IntPtr owner)
    {
        TrayIconData icon = new TrayIconData();
        icon.cbSize = System.Runtime.InteropServices.Marshal.SizeOf(typeof(TrayIconData));
        icon.hWnd = owner;
        icon.hIcon = _native.LoadIcon();
        if (icon.hIcon == IntPtr.Zero) { throw new InvalidOperationException("tray icon resource could not be loaded"); }
        icon.uID = 1U;
        icon.uFlags = TrayNativeConstants.NifMessage | TrayNativeConstants.NifIcon | TrayNativeConstants.NifTip;
        icon.uCallbackMessage = TrayNativeConstants.WmApp + 1U;
        icon.szTip = "CodexRemote-fix";
        icon.szInfo = String.Empty;
        icon.szInfoTitle = String.Empty;
        return icon;
    }

    public void Dispose()
    {
        if (_disposed) { return; }
        _disposed = true;
        try { if (_menuOpen) { _native.EndMenu(); } } catch { }
        try { if (_created) { _native.DeleteIcon(ref _icon); } } catch { }
        try { if (_icon.hIcon != IntPtr.Zero) { _native.DestroyIcon(_icon.hIcon); _icon.hIcon = IntPtr.Zero; } } catch { }
        try { if (_inputGuard != null) { _inputGuard.RestoreOwnerDefaultContext(_owner); } } catch { }
        try { if (_owner != IntPtr.Zero) { _native.DestroyOwner(_owner); } } catch { }
        _owner = IntPtr.Zero;
        _current = null;
        _pending = null;
        _created = false;
        _menuOpen = false;
    }
}
