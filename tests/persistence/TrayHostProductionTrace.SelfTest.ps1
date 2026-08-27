param([Parameter(Mandatory)][string]$AssemblyPath)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'TestSupport.ps1')
$repositoryRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
[Reflection.Assembly]::LoadFrom([IO.Path]::GetFullPath($AssemblyPath))|Out-Null
Import-Module (Join-Path $repositoryRoot 'src\persistence\modules\TrayHostClient.psm1') -Force

function Invoke-CcodProductionTraceCase {
    param([bool]$Stale)
    $client=[TrayHostProductionTraceFixture]::Start($AssemblyPath,$Stale)
    try{
        $queue=[Collections.Generic.Queue[object]]::new()
        $context=[pscustomobject][ordered]@{Client=$client;CommandQueue=$queue;Exited=$false;LastError=$null;PublishedPresentations=[ordered]@{};AcknowledgedPresentations=[ordered]@{}}
        $deadline=[DateTime]::UtcNow.AddSeconds(3)
        while($queue.Count-eq0-and[DateTime]::UtcNow-lt$deadline){[void]$client.WaitForActivity([TimeSpan]::FromMilliseconds(100));Receive-CcodTrayHostEvents -Context $context}
        Assert-CcodEqual 1 $queue.Count 'real TrayHostClient receives one authenticated production action'
        $action=$queue.Dequeue()
        Assert-CcodEqual 'OpenLogs' $action.Command 'production trace preserves command through TrayHostWire and TrayHostClient'
        $expectedRevision=if($Stale){[UInt64]8}else{[UInt64]1}
        Assert-CcodEqual $expectedRevision $action.Revision 'production trace preserves the exact presentation revision'
        $status=if($Stale){'Rejected'}else{'Completed'}
        $code=if($Stale){'CCOD_TRAY_ACTION_STALE'}else{$null}
        Assert-CcodEqual $true (Send-CcodTrayHostActionResult -Context $context -ActionId $action.ActionId -Revision $action.Revision -Status $status -ErrorCode $code -TransactionId $null) 'real TrayHostClient sends the authenticated correlated terminal result'
        Assert-CcodTrue $client.WaitForStopped([TimeSpan]::FromSeconds(3)) 'production trace peer validates Program dispatch and exits'
    }finally{$client.Dispose()}
}

Invoke-CcodProductionTraceCase $false
Invoke-CcodProductionTraceCase $true
Write-Host 'TrayHost production correlation trace passed: 2'
