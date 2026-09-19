Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Test-CleanReleaseRunner.ps1')
Export-ModuleMember -Function Test-CcodCleanReleaseRunner
