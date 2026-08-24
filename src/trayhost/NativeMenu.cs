using System;
using System.Collections.Generic;

internal sealed class NativeMenu : IDisposable
{
    private readonly INativeTrayPlatform _native;
    private readonly PresentationSnapshot _snapshot;
    private readonly IntPtr _owner;
    private IntPtr _menu;
    private bool _destroyed;

    internal NativeMenu(INativeTrayPlatform native, IntPtr owner, PresentationSnapshot snapshot)
    {
        if (native == null) { throw new ArgumentNullException("native"); }
        _native = native;
        _owner = owner;
        if (snapshot == null) { throw new ArgumentNullException("snapshot"); }
        _snapshot = snapshot;
    }

    internal uint Show(TrayPoint point)
    {
        Build();
        bool ownerShown = false;
        try
        {
            ownerShown = _native.ShowOwner(_owner);
            if (!ownerShown) { return 0U; }
            _native.SetForegroundWindow(_owner);
            _native.GetForegroundWindow();
            uint flags = TrayNativeConstants.TpmReturnCmd | TrayNativeConstants.TpmRightButton | TrayNativeConstants.TpmNoNotify;
            // The Shell can deny foreground activation for a notification callback.
            // TrackPopupMenuEx still provides the native menu in that case; WM_NULL
            // and the owner cleanup below preserve the documented dismissal path.
            return _native.TrackPopupMenuEx(_menu, flags, point.X, point.Y, _owner, IntPtr.Zero);
        }
        finally
        {
            _native.PostMessage(_owner, TrayNativeConstants.WmNull, UIntPtr.Zero, IntPtr.Zero);
            TrayIconData focusData = new TrayIconData();
            focusData.cbSize = System.Runtime.InteropServices.Marshal.SizeOf(typeof(TrayIconData));
            focusData.hWnd = _owner;
            focusData.uID = 1U;
            _native.SetNotificationFocus(ref focusData);
            if (ownerShown) { _native.HideOwner(_owner); }
            Dispose();
        }
    }

    private void Build()
    {
        if (_menu != IntPtr.Zero) { return; }
        _menu = _native.CreatePopupMenu();
        if (_menu == IntPtr.Zero) { throw new InvalidOperationException("CreatePopupMenu failed"); }
        try
        {
            Append(_menu, TrayNativeConstants.MfString | TrayNativeConstants.MfDisabled | TrayNativeConstants.MfGrayed, 0U, 0);
            Append(_menu, TrayNativeConstants.MfString | TrayNativeConstants.MfDisabled | TrayNativeConstants.MfGrayed, 0U, 1);
            Append(_menu, TrayNativeConstants.MfString | TrayNativeConstants.MfDisabled | TrayNativeConstants.MfGrayed, 0U, 2);
            AppendSeparator(_menu);
            Append(_menu, TrayNativeConstants.MfString | Enabled(PresentationFlags.RepairEnabled), (uint)TrayCommand.CheckAndRepair, 3);

            IntPtr language = _native.CreateSubMenu();
            if (language == IntPtr.Zero) { throw new InvalidOperationException("CreateLanguageMenu failed"); }
            if (!_native.AppendSubMenu(_menu, language, _snapshot.Strings[4])) { throw new InvalidOperationException("AppendLanguageMenu failed"); }
            Append(language, TrayNativeConstants.MfString | Enabled(PresentationFlags.LanguageEnabled) | LanguageChecked(LanguageMode.System), (uint)TrayCommand.SetLanguageSystem, 5);
            Append(language, TrayNativeConstants.MfString | Enabled(PresentationFlags.LanguageEnabled) | LanguageChecked(LanguageMode.Chinese), (uint)TrayCommand.SetLanguageChinese, 6);
            Append(language, TrayNativeConstants.MfString | Enabled(PresentationFlags.LanguageEnabled) | LanguageChecked(LanguageMode.English), (uint)TrayCommand.SetLanguageEnglish, 7);

            Append(_menu, TrayNativeConstants.MfString | Enabled(PresentationFlags.OpenLogsEnabled), (uint)TrayCommand.OpenLogs, 8);
            Append(_menu, TrayNativeConstants.MfString | Enabled(PresentationFlags.AboutEnabled), (uint)TrayCommand.ShowAbout, 9);
            AppendSeparator(_menu);
            Append(_menu, TrayNativeConstants.MfString | Enabled(PresentationFlags.ExitEnabled), (uint)TrayCommand.Exit, 10);
        }
        catch
        {
            Dispose();
            throw;
        }
    }

    private uint Enabled(PresentationFlags flag) { return Has(flag) ? 0U : TrayNativeConstants.MfDisabled | TrayNativeConstants.MfGrayed; }

    private uint LanguageChecked(LanguageMode mode)
    {
        return _snapshot.Language == mode ? TrayNativeConstants.MfChecked : 0U;
    }

    private bool Has(PresentationFlags flag) { return (_snapshot.Flags & flag) == flag; }

    private void Append(IntPtr menu, uint flags, uint command, int stringIndex)
    {
        if (!_native.AppendMenu(menu, flags, new UIntPtr(command), _snapshot.Strings[stringIndex])) { throw new InvalidOperationException("AppendMenu failed"); }
    }

    private void AppendSeparator(IntPtr menu)
    {
        if (!_native.AppendMenu(menu, TrayNativeConstants.MfSeparator, UIntPtr.Zero, String.Empty)) { throw new InvalidOperationException("AppendSeparator failed"); }
    }

    public void Dispose()
    {
        if (_destroyed) { return; }
        _destroyed = true;
        if (_menu != IntPtr.Zero) { _native.DestroyMenu(_menu); _menu = IntPtr.Zero; }
    }
}
