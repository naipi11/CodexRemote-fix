[CmdletBinding()]
param(
    [ValidateSet('All','zh-CN','en-US')]
    [string]$Locale = 'All',
    [ValidateSet('All','WaitingForCodex','Checking','Connected','RepairNeeded','Error')]
    [string]$State = 'All',
    [ValidateRange(1,600)]
    [int]$DurationSeconds = 8,
    [switch]$OpenMenu
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) {
    throw 'The tray gallery must run in a Windows PowerShell STA.'
}

Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop

$repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$moduleRoot = Join-Path $repositoryRoot 'src\persistence\modules'
$resourcesRoot = Join-Path $repositoryRoot 'src\persistence\resources'

Import-Module (Join-Path $moduleRoot 'UiLocalization.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $moduleRoot 'TrayUi.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $moduleRoot 'SupervisorEngine.psm1') -Force -ErrorAction Stop

Write-Warning 'Visual-only legacy diagnostic gallery: it does not inspect, stop, launch, or modify Codex, and it never writes preference or safety state. The shipped product tray is TrayHost v2.'
Write-Host 'Right-click the diagnostic tray icon to inspect translated connection/protection labels. Close this window or wait for the selected gallery sequence to finish.'

$locales = if ($Locale -ceq 'All') { @('zh-CN','en-US') } else { @($Locale) }
$allFixtures = @(
    [pscustomobject][ordered]@{
        Name = 'WaitingForCodex'; ConnectionState = 'WaitingForCodex'; ProtectionState = 'Running'; Busy = $false; StateDamageBlocksActions = $false
    },
    [pscustomobject][ordered]@{
        Name = 'Checking'; ConnectionState = 'Checking'; ProtectionState = 'Reconnecting'; Busy = $true; StateDamageBlocksActions = $false
    },
    [pscustomobject][ordered]@{
        Name = 'Connected'; ConnectionState = 'Connected'; ProtectionState = 'Running'; Busy = $false; StateDamageBlocksActions = $false
    },
    [pscustomobject][ordered]@{
        Name = 'RepairNeeded'; ConnectionState = 'RepairNeeded'; ProtectionState = 'Running'; Busy = $false; StateDamageBlocksActions = $false
    },
    [pscustomobject][ordered]@{
        Name = 'Error'; ConnectionState = 'Error'; ProtectionState = 'Stopping'; Busy = $false; StateDamageBlocksActions = $true
    }
)
$fixtures = if ($State -ceq 'All') {
    $allFixtures
} else {
    @($allFixtures | Where-Object { $_.Name -ceq $State })
}

$commandQueue = [Collections.Concurrent.ConcurrentQueue[object]]::new()
$galleryAdapters = @{
    # Accept commands in memory only so menu clicks cannot mutate preference/safety state.
    TryEnqueue = { param($Queue,$Value) $true }
}

foreach ($selectedLocale in $locales) {
    $context = $null
    try {
        $catalog = Get-CcodUiCatalog -ResourcesRoot $resourcesRoot -LanguageMode $selectedLocale -SystemCultureName $selectedLocale
        $context = New-CcodTrayContext `
            -CommandQueue $commandQueue `
            -OnTick {} `
            -Catalog $catalog `
            -LanguageMode $selectedLocale `
            -SystemCultureName $selectedLocale `
            -Adapters $galleryAdapters

        foreach ($fixture in $fixtures) {
            $presentation = Get-CcodTrayPresentation `
                -ConnectionState $fixture.ConnectionState `
                -ProtectionState $fixture.ProtectionState `
                -Busy:$fixture.Busy `
                -StateDamageBlocksActions:$fixture.StateDamageBlocksActions
            Set-CcodTrayPresentation `
                -Context $context `
                -Presentation $presentation `
                -Catalog $catalog `
                -LanguageMode $selectedLocale `
                -SystemCultureName $selectedLocale

            Write-Host ('Gallery state: {0} | locale: {1} | {2}s' -f $fixture.Name,$selectedLocale,$DurationSeconds)
            if($OpenMenu){
                # Screenshot helper only: open the native menu without synthesizing
                # a click, and keep all command callbacks in the in-memory queue.
                $context.Menu.Show([Drawing.Point]::new(360,220))
            }
            $deadline = [DateTime]::UtcNow.AddSeconds($DurationSeconds)
            while ([DateTime]::UtcNow -lt $deadline) {
                [Windows.Forms.Application]::DoEvents()
                Start-Sleep -Milliseconds 50
            }
        }
    } finally {
        if ($null -ne $context) {
            try {
                Close-CcodTrayContext -Context $context | Out-Null
            } catch {
                Write-Warning 'Visual gallery cleanup reported a contained tray-resource error.'
            }
        }
    }
}
