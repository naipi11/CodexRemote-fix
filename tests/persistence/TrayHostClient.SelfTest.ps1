$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'TestSupport.ps1')
$repositoryRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$modulePath=Join-Path $repositoryRoot 'src\persistence\modules\TrayHostClient.psm1'
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

Write-Host 'TrayHost client self-tests passed.'
