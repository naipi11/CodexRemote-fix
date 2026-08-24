using System;
using System.ComponentModel;
using System.Collections.Generic;
using System.Runtime.InteropServices;

internal static class TrayNativeConstants
{
    internal const int WsPopup = unchecked((int)0x80000000);
    internal const int WsExToolWindow = 0x00000080;
    internal const uint MfString = 0x00000000;
    internal const uint MfSeparator = 0x00000800;
    internal const uint MfGrayed = 0x00000001;
    internal const uint MfDisabled = 0x00000002;
    internal const uint MfChecked = 0x00000008;
    internal const uint MfPopup = 0x00000010;
    internal const uint MfByPosition = 0x00000400;
    internal const uint TpmReturnCmd = 0x00000100;
    internal const uint TpmRightButton = 0x00000002;
    internal const uint TpmNoNotify = 0x00000080;
    internal const uint TpmLayoutRtl = 0x00004000;
    internal const int SwHide = 0;
    internal const int SwShownoactivate = 4;
    internal const uint WmNull = 0x0000;
    internal const uint WmApp = 0x8000;
    internal const uint NimAdd = 0x00000000;
    internal const uint NimModify = 0x00000001;
    internal const uint NimDelete = 0x00000002;
    internal const uint NimSetFocus = 0x00000003;
    internal const uint NimSetVersion = 0x00000004;
    internal const uint NotifyIconVersion4 = 4;
    internal const uint NifMessage = 0x00000001;
    internal const uint NifIcon = 0x00000002;
    internal const uint NifTip = 0x00000004;
    internal const uint SwpNoActivate = 0x0010;
    internal const int IdiApplication = 32512;
    internal const uint ImageIcon = 1;
    internal const uint LrDefaultSize = 0x00000040;
    internal const uint MbOk = 0x00000000;
    internal const uint MbIconInformation = 0x00000040;
    internal const uint MbYesNo = 0x00000004;
    internal const uint MbIconWarning = 0x00000030;
    internal const uint MbDefButton2 = 0x00000100;
    internal const int IdYes = 6;
}

[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
internal struct TrayIconData
{
    internal int cbSize;
    internal IntPtr hWnd;
    internal uint uID;
    internal uint uFlags;
    internal uint uCallbackMessage;
    internal IntPtr hIcon;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] internal string szTip;
    internal uint dwState;
    internal uint dwStateMask;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] internal string szInfo;
    internal uint uTimeoutOrVersion;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] internal string szInfoTitle;
    internal uint dwInfoFlags;
    internal Guid guidItem;
    internal IntPtr hBalloonIcon;
}

internal struct TrayPoint
{
    internal int X;
    internal int Y;

    internal TrayPoint(int x, int y)
    {
        X = x;
        Y = y;
    }
}

internal interface INativeTrayPlatform
{
    IntPtr CreateOwner();
    IntPtr AssociateOwnerInputContext(IntPtr owner, IntPtr context);
    IntPtr GetOwnerInputContext(IntPtr owner);
    bool ReleaseInputContext(IntPtr owner, IntPtr context);
    IntPtr LoadIcon();
    bool DestroyIcon(IntPtr icon);
    bool AddIcon(ref TrayIconData icon);
    bool SetIconVersion(ref TrayIconData icon);
    bool DeleteIcon(ref TrayIconData icon);
    IntPtr CreatePopupMenu();
    IntPtr CreateSubMenu();
    bool AppendMenu(IntPtr menu, uint flags, UIntPtr command, string text);
    bool AppendSubMenu(IntPtr menu, IntPtr child, string text);
    bool ShowOwner(IntPtr owner);
    bool HideOwner(IntPtr owner);
    bool SetForegroundWindow(IntPtr owner);
    IntPtr GetForegroundWindow();
    uint TrackPopupMenuEx(IntPtr menu, uint flags, int x, int y, IntPtr owner, IntPtr parameters);
    bool PostMessage(IntPtr owner, uint message, UIntPtr wParam, IntPtr lParam);
    bool SetNotificationFocus(ref TrayIconData icon);
    bool ShowMessageBox(IntPtr owner, string text, string caption);
    bool ConfirmExit(IntPtr owner, string text, string caption);
    bool DestroyMenu(IntPtr menu);
    bool EndMenu();
    bool DestroyOwner(IntPtr owner);
}

internal sealed class Win32TrayPlatform : INativeTrayPlatform
{
    private const string WindowClass = "CodexRemoteFixTrayHost";
    private static readonly object WindowGate = new object();
    private static readonly Dictionary<IntPtr, Win32TrayPlatform> Windows = new Dictionary<IntPtr, Win32TrayPlatform>();
    private static readonly WndProcDelegate WindowProcThunk = WindowProc;
    private Action<uint, IntPtr, IntPtr> _messageHandler;
    private IntPtr _owner;

    internal void SetMessageHandler(Action<uint, IntPtr, IntPtr> handler) { _messageHandler = handler; }

    public IntPtr CreateOwner()
    {
        EnsureWindowClass();
        IntPtr owner = CreateWindowExW(
            TrayNativeConstants.WsExToolWindow,
            WindowClass,
            "CodexRemote-fix",
            TrayNativeConstants.WsPopup,
            -32000,
            -32000,
            1,
            1,
            IntPtr.Zero,
            IntPtr.Zero,
            GetModuleHandleW(null),
            IntPtr.Zero);
        if (owner == IntPtr.Zero) { throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateOwner failed"); }
        _owner = owner;
        lock (WindowGate) { Windows[owner] = this; }
        return owner;
    }

    public IntPtr AssociateOwnerInputContext(IntPtr owner, IntPtr context) { return ImmAssociateContext(owner, context); }
    public IntPtr GetOwnerInputContext(IntPtr owner) { return ImmGetContext(owner); }
    public bool ReleaseInputContext(IntPtr owner, IntPtr context) { return ImmReleaseContext(owner, context); }
    public IntPtr LoadIcon()
    {
        IntPtr instance = GetModuleHandleW(null);
        IntPtr icon = LoadImageW(instance, new IntPtr(TrayNativeConstants.IdiApplication), TrayNativeConstants.ImageIcon, 0, 0, TrayNativeConstants.LrDefaultSize);
        if (icon == IntPtr.Zero) { icon = LoadIconW(instance, new IntPtr(TrayNativeConstants.IdiApplication)); }
        if (icon == IntPtr.Zero) { icon = LoadIconW(IntPtr.Zero, new IntPtr(TrayNativeConstants.IdiApplication)); }
        return icon;
    }
    public bool DestroyIcon(IntPtr icon) { return icon == IntPtr.Zero || DestroyIconNative(icon); }

    public bool AddIcon(ref TrayIconData icon) { return Shell_NotifyIconW(TrayNativeConstants.NimAdd, ref icon); }
    public bool SetIconVersion(ref TrayIconData icon)
    {
        icon.uFlags = 0;
        icon.uTimeoutOrVersion = TrayNativeConstants.NotifyIconVersion4;
        return Shell_NotifyIconW(TrayNativeConstants.NimSetVersion, ref icon);
    }
    public bool DeleteIcon(ref TrayIconData icon) { return Shell_NotifyIconW(TrayNativeConstants.NimDelete, ref icon); }
    public bool SetNotificationFocus(ref TrayIconData icon) { return Shell_NotifyIconW(TrayNativeConstants.NimSetFocus, ref icon); }
    public bool ShowMessageBox(IntPtr owner, string text, string caption) { return MessageBoxW(owner, text ?? String.Empty, caption ?? String.Empty, TrayNativeConstants.MbOk | TrayNativeConstants.MbIconInformation) != 0; }
    public bool ConfirmExit(IntPtr owner, string text, string caption) { return MessageBoxW(owner, text ?? String.Empty, caption ?? String.Empty, TrayNativeConstants.MbYesNo | TrayNativeConstants.MbIconWarning | TrayNativeConstants.MbDefButton2) == TrayNativeConstants.IdYes; }

    public IntPtr CreatePopupMenu() { return CreatePopupMenuNative(); }
    public IntPtr CreateSubMenu() { return CreatePopupMenuNative(); }
    public bool AppendMenu(IntPtr menu, uint flags, UIntPtr command, string text) { return AppendMenuW(menu, flags, command, text ?? String.Empty); }
    public bool AppendSubMenu(IntPtr menu, IntPtr child, string text) { return AppendMenuW(menu, TrayNativeConstants.MfPopup | TrayNativeConstants.MfString, new UIntPtr(unchecked((ulong)child.ToInt64())), text ?? String.Empty); }
    public bool ShowOwner(IntPtr owner) { ShowWindowNative(owner, TrayNativeConstants.SwShownoactivate); return true; }
    public bool HideOwner(IntPtr owner) { ShowWindowNative(owner, TrayNativeConstants.SwHide); return true; }
    public bool SetForegroundWindow(IntPtr owner)
    {
        uint foregroundProcessId;
        uint foregroundThread = GetWindowThreadProcessId(GetForegroundWindowNative(), out foregroundProcessId);
        uint ownerProcessId;
        uint ownerThread = GetWindowThreadProcessId(owner, out ownerProcessId);
        uint currentThread = GetCurrentThreadId();
        bool attachedForeground = foregroundThread != 0U && foregroundThread != currentThread && AttachThreadInput(currentThread, foregroundThread, true);
        bool attachedOwner = ownerThread != 0U && ownerThread != currentThread && ownerThread != foregroundThread && AttachThreadInput(currentThread, ownerThread, true);
        try { return SetForegroundWindowNative(owner); }
        finally
        {
            if (attachedOwner) { AttachThreadInput(currentThread, ownerThread, false); }
            if (attachedForeground) { AttachThreadInput(currentThread, foregroundThread, false); }
        }
    }
    public IntPtr GetForegroundWindow() { return GetForegroundWindowNative(); }
    public uint TrackPopupMenuEx(IntPtr menu, uint flags, int x, int y, IntPtr owner, IntPtr parameters) { return TrackPopupMenuExNative(menu, flags, x, y, owner, parameters); }
    public bool PostMessage(IntPtr owner, uint message, UIntPtr wParam, IntPtr lParam) { return PostMessageW(owner, message, wParam, lParam); }
    public bool DestroyMenu(IntPtr menu) { return DestroyMenuNative(menu); }
    public bool EndMenu() { return EndMenuNative(); }
    public bool DestroyOwner(IntPtr owner)
    {
        lock (WindowGate) { Windows.Remove(owner); }
        _owner = IntPtr.Zero;
        return DestroyWindow(owner);
    }

    internal static IntPtr RegisterTaskbarCreatedMessage() { return RegisterWindowMessageW("TaskbarCreated"); }
    internal static bool GetCursorPosition(out TrayPoint point)
    {
        POINT value;
        bool ok = GetCursorPos(out value);
        point = new TrayPoint(value.X, value.Y);
        return ok;
    }
    internal static int GetMessageLoop(out Message value)
    {
        MSG message;
        int result = GetMessageW(out message, IntPtr.Zero, 0U, 0U);
        value = new Message(message.Message, message.WParam, message.LParam);
        return result;
    }
    internal static void TranslateAndDispatch(Message message)
    {
        MSG native = new MSG { Message = message.MessageId, WParam = message.WParam, LParam = message.LParam };
        TranslateMessage(ref native); DispatchMessageW(ref native);
    }
    internal static void PostQuit(int exitCode) { PostQuitMessage(exitCode); }
    internal static bool PostToWindow(IntPtr window, uint message) { return PostMessageW(window, message, UIntPtr.Zero, IntPtr.Zero); }

    internal struct Message
    {
        internal uint MessageId; internal IntPtr WParam; internal IntPtr LParam;
        internal Message(uint messageId, IntPtr wParam, IntPtr lParam) { MessageId = messageId; WParam = wParam; LParam = lParam; }
    }

    [StructLayout(LayoutKind.Sequential)] private struct POINT { internal int X; internal int Y; }
    [StructLayout(LayoutKind.Sequential)] private struct MSG { internal IntPtr HWnd; internal uint Message; internal IntPtr WParam; internal IntPtr LParam; internal uint Time; internal POINT Point; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] private struct WNDCLASSEX { internal uint Size; internal uint Style; internal WndProcDelegate WndProc; internal int ClsExtra; internal int WndExtra; internal IntPtr Instance; internal IntPtr Icon; internal IntPtr Cursor; internal IntPtr Background; [MarshalAs(UnmanagedType.LPWStr)] internal string MenuName; [MarshalAs(UnmanagedType.LPWStr)] internal string ClassName; internal IntPtr SmallIcon; }
    private delegate IntPtr WndProcDelegate(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);

    private static IntPtr WindowProc(IntPtr window, uint message, IntPtr wParam, IntPtr lParam)
    {
        Win32TrayPlatform platform = null;
        lock (WindowGate) { Windows.TryGetValue(window, out platform); }
        if (platform != null && platform._messageHandler != null)
        {
            try { platform._messageHandler(message, wParam, lParam); } catch { }
        }
        return DefWindowProcW(window, message, wParam, lParam);
    }

    private static void EnsureWindowClass()
    {
        WNDCLASSEX value = new WNDCLASSEX { Size = (uint)Marshal.SizeOf(typeof(WNDCLASSEX)), WndProc = WindowProcThunk, Instance = GetModuleHandleW(null), ClassName = WindowClass };
        ushort atom = RegisterClassExW(ref value);
        if (atom == 0 && Marshal.GetLastWin32Error() != 1410) { throw new Win32Exception(Marshal.GetLastWin32Error(), "RegisterClassEx failed"); }
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateWindowExW(int exStyle, string className, string windowName, int style, int x, int y, int width, int height, IntPtr parent, IntPtr menu, IntPtr instance, IntPtr parameter);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern ushort RegisterClassExW(ref WNDCLASSEX value);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr DefWindowProcW(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr RegisterWindowMessageW(string name);
    [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetCursorPos(out POINT point);
    [DllImport("user32.dll", SetLastError = true)] private static extern int GetMessageW(out MSG message, IntPtr window, uint minFilter, uint maxFilter);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool TranslateMessage(ref MSG message);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr DispatchMessageW(ref MSG message);
    [DllImport("user32.dll")] private static extern void PostQuitMessage(int exitCode);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr GetModuleHandleW(string moduleName);
    [DllImport("imm32.dll", SetLastError = true)] private static extern IntPtr ImmAssociateContext(IntPtr window, IntPtr context);
    [DllImport("imm32.dll", SetLastError = true)] private static extern IntPtr ImmGetContext(IntPtr window);
    [DllImport("imm32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool ImmReleaseContext(IntPtr window, IntPtr context);
    [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool Shell_NotifyIconW(uint message, ref TrayIconData data);
    [DllImport("user32.dll", EntryPoint = "CreatePopupMenu", SetLastError = true)] private static extern IntPtr CreatePopupMenuNative();
    [DllImport("user32.dll", SetLastError = true)] private static extern IntPtr LoadImageW(IntPtr instance, IntPtr name, uint type, int width, int height, uint flags);
    [DllImport("user32.dll", SetLastError = true)] private static extern IntPtr LoadIconW(IntPtr instance, IntPtr name);
    [DllImport("user32.dll", EntryPoint = "DestroyIcon", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool DestroyIconNative(IntPtr icon);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool AppendMenuW(IntPtr menu, uint flags, UIntPtr newItem, string text);
    [DllImport("user32.dll", EntryPoint = "ShowWindow", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool ShowWindowNative(IntPtr window, int command);
    [DllImport("user32.dll", EntryPoint = "SetForegroundWindow", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SetForegroundWindowNative(IntPtr window);
    [DllImport("user32.dll", EntryPoint = "GetForegroundWindow", SetLastError = true)] private static extern IntPtr GetForegroundWindowNative();
    [DllImport("user32.dll", SetLastError = true)] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
    [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool AttachThreadInput(uint attachThread, uint attachToThread, [MarshalAs(UnmanagedType.Bool)] bool attach);
    [DllImport("user32.dll", EntryPoint = "TrackPopupMenuEx", SetLastError = true)] private static extern uint TrackPopupMenuExNative(IntPtr menu, uint flags, int x, int y, IntPtr owner, IntPtr parameters);
    [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool PostMessageW(IntPtr window, uint message, UIntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", EntryPoint = "DestroyMenu", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool DestroyMenuNative(IntPtr menu);
    [DllImport("user32.dll", EntryPoint = "EndMenu", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool EndMenuNative();
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern int MessageBoxW(IntPtr owner, string text, string caption, uint type);
    [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool DestroyWindow(IntPtr window);
}
