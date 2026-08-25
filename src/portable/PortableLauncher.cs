// SPDX-License-Identifier: MIT
// Copyright (c) 2026 CodexRemote-fix contributors

using System;
using System.Diagnostics;
using System.IO;

internal static class PortableLauncher
{
    internal static int Main(string[] args)
    {
        if (args != null && args.Length == 1 && String.Equals(args[0], "--headless-smoke", StringComparison.Ordinal))
        {
            return 0;
        }

        string root = AppDomain.CurrentDomain.BaseDirectory;
        string script = Path.Combine(root, "Install-CodexRemote-fix.ps1");
        if (!File.Exists(script))
        {
            return 2;
        }

        ProcessStartInfo start = new ProcessStartInfo
        {
            FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32", "WindowsPowerShell", "v1.0", "powershell.exe"),
            UseShellExecute = false,
            CreateNoWindow = true,
            WorkingDirectory = root
        };
        start.Arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + script.Replace("\"", "\\\"") + "\" -Confirm:$false";
        try
        {
            using (Process process = Process.Start(start))
            {
                if (process == null) { return 3; }
                process.WaitForExit();
                return process.ExitCode;
            }
        }
        catch
        {
            return 4;
        }
    }
}
