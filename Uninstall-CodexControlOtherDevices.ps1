[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string]$InstallRoot,
    [switch]$KeepCurrentSpecialSession,
    [switch]$BackupDeviceKeyStore,
    [switch]$RemoveDeviceKeyStore
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Throw-CcodPublicUninstallError {
    param([Parameter(Mandatory)][string]$Id,[Parameter(Mandatory)][string]$Message,$Target)
    throw [Management.Automation.ErrorRecord]::new(
        [InvalidOperationException]::new($Message),$Id,[Management.Automation.ErrorCategory]::InvalidOperation,$Target)
}

if ($KeepCurrentSpecialSession -or $BackupDeviceKeyStore -or $RemoveDeviceKeyStore) {
    Throw-CcodPublicUninstallError 'CCOD_UNINSTALL_OPTION_REMOVED' 'Legacy session and device-key uninstall options were removed; use Windows Settings or unins000.exe. The device key remains in place.' $PSBoundParameters
}
if ($PSBoundParameters.ContainsKey('InstallRoot')) {
    Throw-CcodPublicUninstallError 'CCOD_UNINSTALL_OPTION_REMOVED' 'The public uninstaller no longer accepts an install-root override; use Windows Settings or the installed unins000.exe.' $InstallRoot
}

$uninstaller = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'unins000.exe'))
if (-not [IO.File]::Exists($uninstaller)) {
    Throw-CcodPublicUninstallError 'CCOD_UNINSTALL_USE_INNO' 'The fail-closed uninstall bootstrap is owned by the installed unins000.exe. Run Windows Settings or unins000.exe from the installed application folder.' $uninstaller
}
$item = Get-Item -LiteralPath $uninstaller -Force -ErrorAction Stop
if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    Throw-CcodPublicUninstallError 'CCOD_UNINSTALL_USE_INNO' 'The installed Inno uninstaller is not a safe regular file.' $uninstaller
}

if (-not $PSCmdlet.ShouldProcess($uninstaller,'Launch the installed Inno uninstaller and its fail-closed cleanup bootstrap')) {
    return [pscustomobject][ordered]@{ Outcome='WhatIf'; KeptDeviceKeyStore=$true }
}

$process = Start-Process -FilePath $uninstaller -PassThru -Wait -ErrorAction Stop
if ($process.ExitCode -ne 0) {
    Throw-CcodPublicUninstallError 'CCOD_UNINSTALL_INNO_FAILED' 'The installed Inno uninstaller did not complete successfully. Installer files were protected if pre-deletion cleanup failed.' $process.ExitCode
}
return [pscustomobject][ordered]@{ Outcome='DelegatedToInno'; KeptDeviceKeyStore=$true }
