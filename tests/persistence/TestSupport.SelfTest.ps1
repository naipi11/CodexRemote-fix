$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestSupport.ps1')

$root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-test-support-' + [guid]::NewGuid().ToString('N'))
$plain = Join-Path $root 'plain'
$sentinel = Join-Path ([IO.Path]::GetTempPath()) ('sentinel-' + [guid]::NewGuid().ToString('N'))
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

    Write-Output 'TestSupport self-tests passed.'
} finally {
    if ([IO.Directory]::Exists($sentinel)) { [IO.Directory]::Delete($sentinel, $true) }
    if ([IO.Directory]::Exists($root)) { Remove-CcodTestOwnedTree -Path $root }
}
	exit 0
