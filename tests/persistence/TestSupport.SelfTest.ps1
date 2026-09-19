$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestSupport.ps1')

$tempRoot = Get-CcodTestCanonicalTempRoot
$root = Join-Path $tempRoot ('ccod-test-support-' + [guid]::NewGuid().ToString('N'))
$plain = Join-Path $root 'plain'
$sentinel = Join-Path $tempRoot ('sentinel-' + [guid]::NewGuid().ToString('N'))
try {
    [IO.Directory]::CreateDirectory($plain) | Out-Null
    [IO.File]::WriteAllText((Join-Path $plain 'a.txt'), 'a')
    [IO.Directory]::CreateDirectory((Join-Path $plain 'nested')) | Out-Null
    [IO.File]::WriteAllText((Join-Path $plain 'nested/b.txt'), 'b')
    Remove-CcodTestOwnedTree -Path $root
    if ([IO.Directory]::Exists($root)) { throw 'ASSERT_TRUE: plain test tree was not removed' }

    [IO.Directory]::CreateDirectory($sentinel) | Out-Null
    $failure = $null
    try { Remove-CcodTestOwnedTree -Path $sentinel } catch { $failure = $_ }
    if ($null -eq $failure -or $failure.Exception.Message -notlike '*unnamed*') { throw 'ASSERT_THROWS: ordinary temp tree was accepted' }
    if (-not [IO.Directory]::Exists($sentinel)) { throw 'ASSERT_TRUE: rejected sentinel was removed' }

    $failure = $null
    try { Remove-CcodTestOwnedTree -Path ([IO.Path]::GetTempPath()).TrimEnd('\') } catch { $failure = $_ }
    if ($null -eq $failure -or $failure.Exception.Message -notlike '*non-temporary*') { throw 'ASSERT_THROWS: temp root was accepted' }


    # A hosted runner can expose an 8.3 short-name TEMP alias. Fixture roots built
    # from that alias are rejected by the installed lifecycle observation boundary,
    # so the shared helper must always return the canonical long form.
    $canonical = Get-CcodTestCanonicalTempRoot
    if ([string]::IsNullOrWhiteSpace($canonical) -or -not [IO.Path]::IsPathRooted($canonical)) {
        throw 'ASSERT_TRUE: canonical temp root must be an absolute path'
    }
    if ($canonical.Contains('~')) { throw 'ASSERT_TRUE: canonical temp root still contains a short-name alias' }
    if ($canonical -cne [IO.Path]::GetFullPath($canonical)) { throw 'ASSERT_EQUAL: canonical temp root is not canonical' }
    if ($canonical -cne [IO.Path]::GetFullPath(([IO.Path]::GetTempPath()).TrimEnd('\'))) { throw 'ASSERT_EQUAL: canonical temp root is detached from the ambient temp path' }
    if ($canonical.TrimEnd('\') -cne ($canonical + '\').TrimEnd('\')) { throw 'ASSERT_TRUE: canonical temp root keeps a stable trailing boundary' }


    # A hosted runner can present a UTF-8 console page. Windows PowerShell 5.1 then
    # makes Process.StandardInput emit a byte-order mark unless the payload is written
    # as explicit bytes, and the receiving child must tolerate a BOM either way.
    $handshakeRoot = Join-Path $tempRoot ('ccod-handshake-' + [guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($handshakeRoot) | Out-Null
    $childScript = Join-Path $handshakeRoot 'handshake.ps1'
    [IO.File]::WriteAllText($childScript, @'
$reader = [IO.StreamReader]::new([Console]::OpenStandardInput(), [Text.UTF8Encoding]::new($false), $true)
$line = $reader.ReadLine()
if ($line -cne 'continue') { [Console]::Error.WriteLine('handshake failed'); exit 1 }
[Console]::Out.WriteLine('CCOD_HANDSHAKE_OK')
'@, [Text.UTF8Encoding]::new($false))

    $previousInputEncoding = [Console]::InputEncoding
    $handshake = $null
    try {
        [Console]::InputEncoding = [Text.UTF8Encoding]::new($true)
        $start = [Diagnostics.ProcessStartInfo]::new()
        $start.FileName = Join-Path $PSHOME 'powershell.exe'
        $start.Arguments = '-NoLogo -NoProfile -NonInteractive -File "' + $childScript + '"'
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardInput = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
        $start.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
        [void]$start.EnvironmentVariables.Remove('PSExecutionPolicyPreference')
        $handshake = [Diagnostics.Process]::Start($start)
        $stdout = $handshake.StandardOutput.ReadToEndAsync()
        $stderr = $handshake.StandardError.ReadToEndAsync()
        Write-CcodTestProcessInput -Process $handshake -Text 'continue' -AddNewLine
        $handshake.StandardInput.Close()
        if (-not $handshake.WaitForExit(30000)) { throw 'ASSERT_TRUE: handshake child did not exit' }
        if ($handshake.ExitCode -ne 0) { throw ('ASSERT_EQUAL: handshake child failed: ' + $stderr.Result) }
        if ($stdout.Result -cne ('CCOD_HANDSHAKE_OK' + [Environment]::NewLine)) { throw ('ASSERT_EQUAL: handshake output mismatch: ' + $stdout.Result) }
        if ($stderr.Result.Length -ne 0) { throw ('ASSERT_EQUAL: handshake child stderr: ' + $stderr.Result) }
        if ((Read-CcodTestStandardInputText) -cne '') { throw 'ASSERT_EQUAL: helper read no explicit input as non-empty' }
    } finally {
        [Console]::InputEncoding = $previousInputEncoding
        if ($null -ne $handshake) {
            try { if (-not $handshake.HasExited) { $handshake.Kill(); $handshake.WaitForExit() } } finally { $handshake.Dispose() }
        }
        if ([IO.Directory]::Exists($handshakeRoot)) { Remove-CcodTestOwnedTree -Path $handshakeRoot }
        if ([IO.Directory]::Exists($root)) { Remove-CcodTestOwnedTree -Path $root }
    }


    # npm and Actions start these suites from a PowerShell 7 shell, which leaks a
    # PowerShell 7 PSModulePath into the Windows PowerShell 5.1 child processes.
    $previousModulePath = [Environment]::GetEnvironmentVariable('PSModulePath', 'Process')
    try {
        if ($PSVersionTable.PSEdition -eq 'Desktop') {
            [Environment]::SetEnvironmentVariable('PSModulePath', 'C:\Program Files\PowerShell\7\Modules', 'Process')
            Restore-CcodTestDesktopModulePath
            $restored = [Environment]::GetEnvironmentVariable('PSModulePath', 'Process')
            if ($restored -match 'PowerShell\\7(\\|$|;)') { throw 'ASSERT_TRUE: a leaked PowerShell 7 module path was not replaced' }
            if ([string]::IsNullOrWhiteSpace($restored)) { throw 'ASSERT_TRUE: the restored module path is empty' }
            [Environment]::SetEnvironmentVariable('PSModulePath', 'C:\custom-desktop-modules', 'Process')
            Restore-CcodTestDesktopModulePath
            if ([Environment]::GetEnvironmentVariable('PSModulePath', 'Process') -cne 'C:\custom-desktop-modules') {
                throw 'ASSERT_EQUAL: a Desktop-only module path was overwritten'
            }
        }
    } finally {
        [Environment]::SetEnvironmentVariable('PSModulePath', $previousModulePath, 'Process')
    }

    Write-Output 'TestSupport self-tests passed.'
} finally {
    if ([IO.Directory]::Exists($sentinel)) { [IO.Directory]::Delete($sentinel, $true) }
    if ([IO.Directory]::Exists($root)) { Remove-CcodTestOwnedTree -Path $root }
}
	exit 0
