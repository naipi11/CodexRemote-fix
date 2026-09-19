$ErrorActionPreference='Stop'
function Get-CcodProbeInner { return 'INNER-OK' }
function Invoke-CcodProbeOuter { param([Parameter(Mandatory)][scriptblock]$Action) return (& $Action) }
function Get-CcodProbeInnerDeep { return 'DEEP-OK' }
function Invoke-CcodProbeOuterDeep {
    param([Parameter(Mandatory)][scriptblock]$Action)
    return (& { param($a) & $a } $Action)
}
Write-Output ("RESULT_DIRECT=" + (Invoke-CcodProbeOuter -Action ({ Get-CcodProbeInner })))
Write-Output ("RESULT_DEEP=" + (Invoke-CcodProbeOuterDeep -Action ({ Get-CcodProbeInnerDeep })))
Write-Output ("SCRIPT_ROOT=" + $PSScriptRoot)
Write-Output 'LIB_DONE'
