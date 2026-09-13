$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestSupport.ps1')

$root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-test-support-' + [guid]::NewGuid().ToString('N'))
$plain = Join-Path ([IO.Path]::GetTempPath()) ('plain-test-support-root-' + [guid]::NewGuid().ToString('N'))
try {
    [IO.Directory]::CreateDirectory((Join-Path $root 'nested/deep')) | Out-Null
    [IO.File]::WriteAllText((Join-Path $root 'nested/deep/payload.txt'), 'payload')
    [IO.Directory]::Move((Join-Path $root 'nested'), (Join-Path $root 'nested-released'))
    Remove-CcodTestOwnedTree -Path $root
    if ([IO.Directory]::Exists($root)) { throw 'ASSERT_TRUE: renamed payload tree was not removed' }

    [IO.Directory]::CreateDirectory($plain) | Out-Null
    $failure = $null
    try { Remove-CcodTestOwnedTree -Path $plain } catch { $failure = $_ }
    if ($null -eq $failure -or $failure.Exception.Message -notlike '*unnamed*') {
        throw 'ASSERT_THROWS: unnamed temp tree was accepted'
    }

    $outside = Join-Path ([IO.Path]::GetTempPath()) ('ccod-test-support-outside-' + [guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($outside) | Out-Null
    $reparse = Join-Path $root 'reparse-child'
    New-Item -ItemType Junction -Path $reparse -Target $outside | Out-Null
    $failure = $null
    try { Remove-CcodTestOwnedTree -Path $root } catch { $failure = $_ }
    if ($null -eq $failure -or $failure.Exception.Message -notlike '*reparse-point*') {
        throw 'ASSERT_THROWS: reparse-point child was accepted'
    }
} finally {
    if ([IO.Directory]::Exists($root)) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    if ([IO.Directory]::Exists($plain)) { [IO.Directory]::Delete($plain, $true) }
    if ($outside -and [IO.Directory]::Exists($outside)) { Remove-Item -LiteralPath $outside -Recurse -Force -ErrorAction SilentlyContinue }
}

'TestSupport self-tests passed.'
