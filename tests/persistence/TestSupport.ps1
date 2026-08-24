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
