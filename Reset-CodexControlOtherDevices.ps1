[CmdletBinding()]
param(
    [switch]$BackupDeviceKeyStore,
    [switch]$DoNotRestart
)

$ErrorActionPreference='Stop'
$migrationMessage='BackupDeviceKeyStore was removed in 2.5.0; the device-key store is preserved in place. Use Codex device management to revoke authorization if needed.'
if($BackupDeviceKeyStore){throw "CCOD_RESET_BACKUP_REMOVED: $migrationMessage"}
if($DoNotRestart){throw 'CCOD_RESET_DONOTRESTART_REMOVED: DoNotRestart is not applicable to SafeExit; the Supervisor proves ordinary/no-Codex recovery before it exits.'}

function Resolve-CcodResetLifecycleRequestModule {
    param([Parameter(Mandatory)][string]$InstallRoot)
    $manifestModule=Join-Path $PSScriptRoot 'src\persistence\modules\RuntimeManifest.psm1'
    if(-not(Test-Path -LiteralPath $manifestModule -PathType Leaf)){throw 'CodexRemote-fix support files are incomplete. Run the installer from a complete checkout.'}
    Import-Module $manifestModule -Force
    if(-not(Test-Path -LiteralPath (Join-Path $InstallRoot 'active.json') -PathType Leaf)){throw 'CCOD_INSTALL_REQUIRED: CodexRemote-fix is not installed. Run Install-CodexControlOtherDevices.ps1 first.'}
    $active=Read-CcodActiveRuntime -InstallRoot $InstallRoot
    $runtime=[IO.Path]::GetFullPath((Join-Path $InstallRoot ('runtime\'+$active.activeRuntime)))
    $validation=Test-CcodRuntimeManifest -RuntimeDirectory $runtime -ExpectedRuntimeId $active.activeRuntime
    if(-not$validation.Valid){throw "Installed runtime validation failed: $($validation.Code). Repair or reinstall CodexRemote-fix."}
    $modulePath=Join-Path $runtime 'src\persistence\modules\LifecycleRequest.psm1'
    if(-not(Test-Path -LiteralPath $modulePath -PathType Leaf)){throw 'The verified active runtime lacks lifecycle submission support. Repair or reinstall.'}
    [pscustomobject][ordered]@{RuntimeId=[string]$active.activeRuntime;Generation=[UInt64]$active.generation;ModulePath=[IO.Path]::GetFullPath($modulePath)}
}

function Submit-CcodResetSafeExit {
    param([Parameter(Mandatory)]$Resolved,[Parameter(Mandatory)][string]$InstallRoot)
    Import-Module $Resolved.ModulePath -Force
    Submit-CcodLifecycleRequest -InstallRoot $InstallRoot -Kind SafeExit -Origin ExplicitStart -RuntimeId $Resolved.RuntimeId -RuntimeGeneration ([UInt64]$Resolved.Generation) -TimeoutMilliseconds 30000
}

if($MyInvocation.InvocationName -ne '.'){
    $installRoot=[IO.Path]::GetFullPath((Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CodexControlOtherDevices'))
    $resolved=Resolve-CcodResetLifecycleRequestModule -InstallRoot $installRoot
    $receipt=Submit-CcodResetSafeExit -Resolved $resolved -InstallRoot $installRoot
    if(-not$receipt.accepted){throw "Safe Exit was not accepted: $($receipt.errorCode)"}
    Write-Host 'Safe Exit was submitted. CodexRemote-fix will close only after ordinary/no-Codex recovery is proven.'
}
