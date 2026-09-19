function Assert-CcodTrue([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "ASSERT_TRUE: $Message" }
}

function Assert-CcodEqual($Expected, $Actual, [string]$Message) {
    if ($Expected -ne $Actual) { throw "ASSERT_EQUAL: $Message expected=[$Expected] actual=[$Actual]" }
}

function Assert-CcodThrows([scriptblock]$Action, [string]$ErrorId) {
    try { & $Action; throw "ASSERT_THROWS: expected $ErrorId" }
    catch { if ($_.FullyQualifiedErrorId -notlike "$ErrorId*") { throw } }
}

function Invoke-CcodTest([string]$Name, [scriptblock]$Action) {
    try {
        & $Action
        return [pscustomobject]@{ Name = $Name; Ok = $true }
    } catch {
        $safeName = ($Name -replace '[^A-Za-z0-9_.-]', '-') -replace '-+', '-'
        if ($safeName.Length -gt 120) { $safeName = $safeName.Substring(0,120) }
        $errorId = ([string]$_.FullyQualifiedErrorId -split '[,:]')[0]
        if ($errorId -cnotmatch '^(?:ASSERT|CCOD)_[A-Z0-9_]+$') { $errorId = 'UNCLASSIFIED' }
        [Console]::Error.WriteLine(('CCOD_SELFTEST_FAILED case={0} error={1}' -f $safeName,$errorId))
        throw
    }
}

function Get-CcodTestFileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $stream = [IO.File]::OpenRead([IO.Path]::GetFullPath($Path))
        try {
            return [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '').ToLowerInvariant()
        } finally {
            $stream.Dispose()
        }
    } finally {
        $sha.Dispose()
    }
}

function Write-CcodTestProcessInput {
    # Windows PowerShell 5.1 has no ProcessStartInfo.StandardInputEncoding, and
    # Process.StandardInput inherits Console.InputEncoding. Under a UTF-8 console
    # (for example chcp 65001 on a hosted runner) that writer emits a leading
    # byte-order mark, which corrupts the first token a child reads. Write explicit
    # UTF-8 bytes without a BOM instead.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Process,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [switch]$AddNewLine
    )
    $payload = if ($AddNewLine) { $Text + "`n" } else { $Text }
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($payload)
    $stream = $Process.StandardInput.BaseStream
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush()
}

function Read-CcodTestStandardInputText {
    # Read standard input as explicit UTF-8 bytes and tolerate an optional
    # byte-order mark, so a child handshake survives any ambient console page.
    [CmdletBinding()]
    param()
    $reader = [IO.StreamReader]::new([Console]::OpenStandardInput(), [Text.UTF8Encoding]::new($false), $true)
    try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
}

function Read-CcodTestStandardInputLine {
    # Read one standard input line without depending on the ambient console page.
    [CmdletBinding()]
    param()
    $reader = [IO.StreamReader]::new([Console]::OpenStandardInput(), [Text.UTF8Encoding]::new($false), $true)
    try { return $reader.ReadLine() } finally { $reader.Dispose() }
}

function Get-CcodTestCanonicalTempRoot {
    # $env:TEMP can be a Windows 8.3 short-name alias such as
    # C:\Users\RUNNER~1\AppData\Local\Temp on hosted runners. Fixture roots
    # built from the alias are rejected by the installed lifecycle harness, which
    # requires canonical long-form paths. Canonicalize once so every fixture root is
    # already canonical and owned-tree cleanup still matches its allowlist.
    return [IO.Path]::GetFullPath(([IO.Path]::GetTempPath()).TrimEnd('\'))
}

function Remove-CcodTestOwnedTree {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $full = [IO.Path]::GetFullPath($Path)
    $temp = [IO.Path]::GetFullPath(([IO.Path]::GetTempPath()).TrimEnd('\'))
    if ($full -eq $temp -or -not $full.StartsWith($temp + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Refusing to remove a non-temporary test tree.'
    }
    $leaf = [IO.Path]::GetFileName($full)
    if ($leaf -notmatch '^ccod-[A-Za-z0-9_.-]+$') {
        throw 'Refusing to remove an unnamed test tree.'
    }
    if (-not [IO.Directory]::Exists($full)) { return }

    $root = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    if ($root.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw 'Refusing to remove a reparse-point test root.'
    }
    $items = @(Get-ChildItem -LiteralPath $full -Force -Recurse -ErrorAction Stop |
        Sort-Object { $_.FullName.Length } -Descending)
    foreach ($item in $items) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            if ($item.PSIsContainer) {
                try { [IO.Directory]::Delete($item.FullName, $false) }
                catch [IO.DirectoryNotFoundException] { }
            } else {
                try { [IO.File]::SetAttributes($item.FullName, [IO.FileAttributes]::Normal); [IO.File]::Delete($item.FullName) }
                catch [IO.FileNotFoundException] { }
                catch [IO.DirectoryNotFoundException] { }
            }
            continue
        }
        try {
            if ($item.PSIsContainer) {
                [IO.Directory]::Delete($item.FullName, $false)
            } else {
                [IO.File]::SetAttributes($item.FullName, [IO.FileAttributes]::Normal)
                [IO.File]::Delete($item.FullName)
            }
        } catch [IO.FileNotFoundException] { }
          catch [IO.DirectoryNotFoundException] { }
    }
    try { [IO.Directory]::Delete($full, $false) }
    catch [IO.DirectoryNotFoundException] { }
    if ([IO.Directory]::Exists($full)) { throw ('Test-owned cleanup left residue: ' + $full) }
}
