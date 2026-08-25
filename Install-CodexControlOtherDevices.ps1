[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [string]$InstallRoot,
    [switch]$EnableCandidateCompatibleUpdates,
    [switch]$RepairState,
    [switch]$DoNotStart,
    [string]$ActivationId
)

$ErrorActionPreference = 'Stop'

function Resolve-CcodInstallerModule {
    param([Parameter(Mandatory)][string]$CheckoutRoot)

    $modulePath = [IO.Path]::GetFullPath((Join-Path $CheckoutRoot 'src\persistence\modules\InstallLifecycle.psm1'))
    if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
        throw [Management.Automation.ErrorRecord]::new(
            [InvalidOperationException]::new('InstallLifecycle.psm1 is missing from this checkout. Run the installer from a complete repository checkout.'),
            'CCOD_INSTALLER_MODULE_MISSING',
            [Management.Automation.ErrorCategory]::ObjectNotFound,
            $modulePath
        )
    }
    return $modulePath
}

$script:InstallerModule = Resolve-CcodInstallerModule -CheckoutRoot $PSScriptRoot
Import-Module $script:InstallerModule -Force

if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
    $InstallRoot = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'CodexControlOtherDevices'
}

$receipt = Invoke-CcodInstall `
    -SourceRoot $PSScriptRoot `
    -InstallRoot $InstallRoot `
    -EnableCandidateCompatibleUpdates:([bool]$EnableCandidateCompatibleUpdates) `
    -RepairState:([bool]$RepairState) `
    -DoNotStart:([bool]$DoNotStart) `
    -ActivationId $ActivationId

Write-Host ''
Write-Host 'CodexRemote-fix - install result' -ForegroundColor Cyan
Write-Host ('  Outcome:          {0}' -f $receipt.Outcome)
if ($receipt.RuntimeId) { Write-Host ('  Runtime ID:       {0}' -f $receipt.RuntimeId) }
if ($receipt.PreviousRuntimeId) { Write-Host ('  Previous runtime: {0}' -f $receipt.PreviousRuntimeId) }
if ($receipt.Outcome -eq 'Repaired') {
    Write-Host '  State was recreated with automation and candidate-compatible updates disabled.' -ForegroundColor Yellow
    Write-Host '  Re-enable them from the tray after confirming the package and Node environment.' -ForegroundColor Yellow
}
Write-Host ''
if ($receipt.Outcome -eq 'Installed' -or $receipt.Outcome -eq 'Upgraded') {
    Write-Host 'The persistent tray supervisor is installed and runs at next logon (or now).' -ForegroundColor Green
    Write-Host 'Open Settings > Connections > Control other devices after starting Codex normally.' -ForegroundColor Green
    Write-Host ''
}
return $receipt
