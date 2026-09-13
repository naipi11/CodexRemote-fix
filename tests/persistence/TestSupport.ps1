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
