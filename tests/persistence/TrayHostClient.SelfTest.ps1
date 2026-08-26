$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'TestSupport.ps1')
$repositoryRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$modulePath=Join-Path $repositoryRoot 'src\persistence\modules\TrayHostClient.psm1'
$localizationPath=Join-Path $repositoryRoot 'src\persistence\modules\UiLocalization.psm1'
Invoke-CcodTest 'TrayHost client wrapper is source-auditable and does not start a host on import' {
    Assert-CcodTrue (Test-Path -LiteralPath $modulePath -PathType Leaf) 'TrayHost client module exists'
    Import-Module $modulePath -Force
    foreach($name in @('New-CcodTrayHostContext','Set-CcodTrayHostPresentation','Receive-CcodTrayHostEvents','Send-CcodTrayHostActionResult','Invoke-CcodTrayHostRunLoop','Request-CcodTrayHostExit','Close-CcodTrayHostContext','Show-CcodTrayHostError','End-CcodTrayHostMenu')){Assert-CcodTrue ($null -ne (Get-Command $name -ErrorAction SilentlyContinue)) "wrapper export exists: $name"}
    Assert-CcodTrue ($null -eq (Get-Command New-CcodTrayContext -ErrorAction SilentlyContinue)) 'wrapper does not re-export the legacy UI constructor'
}

Invoke-CcodTest 'Supervisor imports the TrayHost client as its only production tray constructor' {
    $supervisor=Get-Content -LiteralPath (Join-Path $repositoryRoot 'src\persistence\Supervisor.ps1') -Raw
    Assert-CcodTrue ($supervisor -match "'TrayHostClient\.psm1'") 'Supervisor imports TrayHostClient'
    Assert-CcodTrue ($supervisor -match 'New-CcodTrayHostContext') 'default NewTray delegates to TrayHostClient'
    Assert-CcodTrue ($supervisor -match 'Invoke-CcodTrayHostRunLoop') 'default RunUiContext delegates to TrayHostClient'
}

Invoke-CcodTest 'TrayHost client carries the localized About item and active runtime version contract' {
    $source = Get-Content -LiteralPath $modulePath -Raw -Encoding UTF8
    Assert-CcodTrue ($source -cmatch "Menu\.AboutVersion") 'snapshot formats the localized About version string'
    Assert-CcodTrue ($source -cmatch "RuntimeId -is \[string\].*\^\(\?<version\>\\d\+\\\.\\d\+\\\.\\d\+\)-") 'snapshot extracts the semantic version from the active runtime id'
    Assert-CcodTrue ($source -cmatch "Menu\.About',") 'snapshot carries the localized About menu label'
    Assert-CcodTrue ($source -cmatch '\$aboutVersion') 'snapshot appends the About message to the presentation payload'
}

Invoke-CcodTest 'TrayHost client maps only v2 actions and returns correlated action receipts' {
    $source = Get-Content -LiteralPath $modulePath -Raw -Encoding UTF8
    $receive=[regex]::Match($source,'function Receive-CcodTrayHostEvents \{(?s:.*?)\n\}\n\nfunction Send-CcodTrayHostActionResult').Value
    Assert-CcodTrue ($source -cmatch 'CheckAndRepair') 'wrapper maps the v2 repair action'
    Assert-CcodTrue ($source -cmatch 'ActionId') 'wrapper preserves the authenticated action identifier'
    Assert-CcodTrue ($source -cmatch 'TryAcknowledgeAction') 'wrapper sends one correlated action result through the parent client'
    Assert-CcodTrue ($source -cmatch 'ActionId=\$event\.ActionId;Command=\$command;Revision=\[UInt64\]\$event\.Revision') 'wrapper queues the exact v2 action identity command and revision contract'
    Assert-CcodTrue ($receive -cnotmatch 'ConfirmUninstall|SetCandidateOptIn|SetAutomation|ApplyNow|ManualRetry') 'receive path does not expose legacy wire actions'
}

Invoke-CcodTest 'TrayHost client emits the fixed v2 connection protection snapshot fields' {
    $source = Get-Content -LiteralPath $modulePath -Raw -Encoding UTF8
    Assert-CcodTrue ($source -cmatch 'Convert-CcodTrayHostConnection') 'snapshot converts the v2 connection state'
    Assert-CcodTrue ($source -cmatch 'Convert-CcodTrayHostProtection') 'snapshot converts the v2 protection state'
    Assert-CcodTrue ($source -cmatch 'ConnectionState') 'snapshot carries the current connection state'
    Assert-CcodTrue ($source -cmatch 'ProtectionState') 'snapshot carries the current protection state'
}

Invoke-CcodTest 'TrayHost starts fail-closed until the Supervisor publishes an eligible Exit presentation' {
    # Production mutation caught: enabling the native Exit action in the initial pre-Supervisor snapshot.
    $presentation=New-CcodTrayHostInitialPresentation
    Assert-CcodEqual $false $presentation.ExitEnabled 'initial native presentation keeps Exit disabled before lifecycle ownership and recovery checks'
    Assert-CcodEqual $false $presentation.Busy 'initial presentation is an idle disabled action surface, not a synthetic busy state'
}

Invoke-CcodTest 'TrayHost reuses an identical presentation revision and records only an exact acknowledgement' {
    if($null-eq('PresentationSnapshot' -as [type])){Add-Type -Path (Join-Path $repositoryRoot 'src\trayhost\PresentationSnapshot.cs')}
    Import-Module $localizationPath -Force
    $catalog=Get-CcodUiCatalog -ResourcesRoot (Join-Path $repositoryRoot 'src\persistence\resources') -LanguageMode en-US -SystemCultureName en-US
    $presentation=[pscustomobject][ordered]@{Color='Green';ConnectionState='Connected';ProtectionState='Running';RepairEnabled=$false;LanguageEnabled=$true;OpenLogsEnabled=$true;AboutEnabled=$true;ExitEnabled=$true;Busy=$false}
    $published=[Collections.Generic.List[object]]::new();$events=[Collections.Generic.Queue[object]]::new()
    $client=[pscustomobject]@{Published=$published;Events=$events}
    $client|Add-Member -MemberType ScriptMethod -Name TryPublish -Value {param($Snapshot)$this.Published.Add($Snapshot);return $true}
    $client|Add-Member -MemberType ScriptMethod -Name TryDequeueEvent -Value {param([ref]$Event)if($this.Events.Count-eq0){return $false};$Event.Value=$this.Events.Dequeue();return $true}
    $context=[pscustomobject][ordered]@{
        Client=$client;CommandQueue=[Collections.Generic.Queue[object]]::new();Catalog=$catalog;LanguageMode='en-US';SystemCultureName='en-US';RuntimeId='2.5.20-test'
        CurrentRevision=[UInt64]1;LastAcknowledgedRevision=[UInt64]1;LastPublishedSnapshot=$null
        PublishedPresentations=[ordered]@{};AcknowledgedPresentations=[ordered]@{};Exited=$false;LastError=$null
    }
    Set-CcodTrayHostPresentation -Context $context -Presentation $presentation -Catalog $catalog -LanguageMode en-US -SystemCultureName en-US
    Set-CcodTrayHostPresentation -Context $context -Presentation $presentation -Catalog $catalog -LanguageMode en-US -SystemCultureName en-US
    Assert-CcodEqual 1 $published.Count 'an identical semantic projection publishes only once'
    Assert-CcodEqual ([UInt64]2) $context.CurrentRevision 'an identical semantic projection keeps the published revision stable'
    $events.Enqueue([pscustomobject][ordered]@{Kind='PresentationAck';Revision=[UInt64]99})
    Receive-CcodTrayHostEvents -Context $context
    Assert-CcodEqual ([UInt64]1) $context.LastAcknowledgedRevision 'an unknown higher acknowledgement cannot advance confirmed presentation state'
    Assert-CcodTrue $context.PublishedPresentations.Contains('2') 'an unknown higher acknowledgement cannot discard the pending exact presentation'
    Assert-CcodTrue (-not$context.AcknowledgedPresentations.Contains('99')) 'an unknown higher acknowledgement creates no presentation authority'
    $events.Enqueue([pscustomobject][ordered]@{Kind='PresentationAck';Revision=[UInt64]2})
    Receive-CcodTrayHostEvents -Context $context
    Assert-CcodTrue $context.AcknowledgedPresentations.Contains('2') 'the exact host acknowledgement records the revision presentation authority'
    Assert-CcodEqual $true $context.AcknowledgedPresentations['2'].ExitEnabled 'acknowledged authority preserves the presented action capability'
    Assert-CcodTrue (-not$context.AcknowledgedPresentations.Contains('1')) 'an unrecorded revision is never inferred from a higher acknowledgement'
}

Write-Host 'TrayHost client self-tests passed.'
