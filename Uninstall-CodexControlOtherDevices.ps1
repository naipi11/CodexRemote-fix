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
    Throw-CcodPublicUninstallError 'CCOD_UNINSTALL_OPTION_REMOVED' 'Legacy session and device-key uninstall options were removed. The device key remains in place.' $PSBoundParameters
}
if ($PSBoundParameters.ContainsKey('InstallRoot')) {
    Throw-CcodPublicUninstallError 'CCOD_UNINSTALL_OPTION_REMOVED' 'The public uninstaller no longer accepts an install-root override.' $InstallRoot
}

$installerRoot = [IO.Path]::GetFullPath($PSScriptRoot)
$localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
if ([string]::IsNullOrWhiteSpace($localAppData) -or -not [IO.Path]::IsPathRooted($localAppData)) {
    Throw-CcodPublicUninstallError 'CCOD_UNINSTALL_PORTABLE_INVALID' 'Local application data is unavailable for the current user.' $localAppData
}
$expectedInstallerRoot = [IO.Path]::GetFullPath((Join-Path $localAppData 'CodexControlOtherDevices-installer'))
$expectedInstallRoot = [IO.Path]::GetFullPath((Join-Path $localAppData 'CodexControlOtherDevices'))
$portableMarkerPath = Join-Path $installerRoot 'portable-release.json'
if ([IO.File]::Exists($portableMarkerPath) -or [IO.Directory]::Exists($portableMarkerPath)) {
    if ($installerRoot -cne $expectedInstallerRoot) {
        Throw-CcodPublicUninstallError 'CCOD_UNINSTALL_PORTABLE_INVALID' 'The portable uninstaller was not launched from the current-user installer root.' $installerRoot
    }
    $portableModulePath = [IO.Path]::GetFullPath((Join-Path $installerRoot 'src\persistence\modules\PortableRelease.psm1'))
    $bootstrapPath = [IO.Path]::GetFullPath((Join-Path $installerRoot 'src\persistence\UninstallBootstrap.ps1'))
    foreach ($path in @($portableModulePath,$bootstrapPath)) {
        if (-not [IO.File]::Exists($path)) {
            Throw-CcodPublicUninstallError 'CCOD_UNINSTALL_PORTABLE_INVALID' 'The portable uninstaller payload is incomplete.' $path
        }
        $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            Throw-CcodPublicUninstallError 'CCOD_UNINSTALL_PORTABLE_INVALID' 'The portable uninstaller payload is not a safe regular file.' $path
        }
    }
    Import-Module $portableModulePath -Force -ErrorAction Stop
    $marker = Assert-CcodPortableInstalledMarker -InstallerRoot $installerRoot
    if (-not $PSCmdlet.ShouldProcess($installerRoot,'Run protected cleanup and detach the verified portable installer root')) {
        return [pscustomobject][ordered]@{ Outcome='WhatIf'; KeptDeviceKeyStore=$true }
    }
    try {
        $prepared = & $bootstrapPath -InstallerRoot $installerRoot -InstallRoot $expectedInstallRoot -Mode Prepare
    } catch {
        Throw-CcodPublicUninstallError 'CCOD_UNINSTALL_PORTABLE_PREPARE_FAILED' 'Protected portable uninstall cleanup did not reach its finalization boundary.' $_
    }
    if ($null -eq $prepared -or $prepared.transactionId -isnot [string] -or $prepared.transactionId -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' -or
        $prepared.phase -cne 'ReadyForInno' -or $prepared.runtimeId -cne $marker.runtimeId -or [uint64]$prepared.runtimeGeneration -ne [uint64]$marker.generation) {
        Throw-CcodPublicUninstallError 'CCOD_UNINSTALL_PORTABLE_PREPARE_FAILED' 'Protected portable uninstall cleanup returned an invalid transaction receipt.' $prepared
    }
    $transactionRoot = [IO.Path]::GetFullPath((Join-Path $localAppData 'CodexRemote-fix-uninstall'))
    $transactionDirectory = [IO.Path]::GetFullPath((Join-Path $transactionRoot $prepared.transactionId))
    $finalizerPath = [IO.Path]::GetFullPath((Join-Path $transactionDirectory 'payload\src\persistence\PortableUninstallFinalizer.ps1'))
    if (-not [IO.File]::Exists($finalizerPath)) {
        Throw-CcodPublicUninstallError 'CCOD_UNINSTALL_PORTABLE_FINALIZER_MISSING' 'The external portable finalizer was not staged with the verified cleanup payload.' $finalizerPath
    }
    $finalizerItem = Get-Item -LiteralPath $finalizerPath -Force -ErrorAction Stop
    if ($finalizerItem.PSIsContainer -or (($finalizerItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        Throw-CcodPublicUninstallError 'CCOD_UNINSTALL_PORTABLE_FINALIZER_MISSING' 'The external portable finalizer is not a safe regular file.' $finalizerPath
    }
    $powershellPath = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::System)) 'WindowsPowerShell\v1.0\powershell.exe'
    if (-not [IO.File]::Exists($powershellPath)) {
        Throw-CcodPublicUninstallError 'CCOD_UNINSTALL_PORTABLE_FINALIZER_MISSING' 'The Windows PowerShell host required for the external finalizer is unavailable.' $powershellPath
    }
    function ConvertTo-CcodPublicUninstallPowerShellLiteral {
        param([Parameter(Mandatory)][string]$Value)
        return "'" + $Value.Replace("'","''") + "'"
    }
    $stdoutPath = Join-Path $transactionDirectory 'portable-finalizer.stdout.log'
    $stderrPath = Join-Path $transactionDirectory 'portable-finalizer.stderr.log'
    $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File {0} -TransactionId {1} -InstallerRoot {2} -InstallRoot {3}' -f (ConvertTo-CcodPublicUninstallPowerShellLiteral $finalizerPath), (ConvertTo-CcodPublicUninstallPowerShellLiteral $prepared.transactionId), (ConvertTo-CcodPublicUninstallPowerShellLiteral $installerRoot), (ConvertTo-CcodPublicUninstallPowerShellLiteral $expectedInstallRoot)
    try {
        $process = Start-Process -FilePath $powershellPath -ArgumentList $arguments -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru -ErrorAction Stop
    } catch {
        Throw-CcodPublicUninstallError 'CCOD_UNINSTALL_PORTABLE_FINALIZER_START_FAILED' 'The external portable finalizer could not be started. Installer files were retained.' $_
    }
    return [pscustomobject][ordered]@{
        Outcome = 'PortableFinalizationStarted'
        TransactionId = [string]$prepared.transactionId
        FinalizerProcessId = [int]$process.Id
        KeptDeviceKeyStore = $true
    }
}

$uninstaller = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'unins000.exe'))
if (-not [IO.File]::Exists($uninstaller)) {
    Throw-CcodPublicUninstallError 'CCOD_UNINSTALL_USE_INNO' 'No verified portable marker or installed Inno uninstaller was found.' $uninstaller
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
