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

function Invoke-CcodPublicUninstallPrepare {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Runtime,[Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$PrepareMode,$Identity)
    # Dot-source only definitions, then call the function. The script's CLI tail
    # deliberately exits instead of returning a receipt to a PowerShell caller.
    . $Path
    Invoke-CcodUninstallBootstrap -InstallerRoot $Runtime -InstallRoot $Root -Mode $PrepareMode -WrapperIdentity $Identity
}

function Start-CcodPublicInstalledFinalizer {
    param([Parameter(Mandatory)][string]$SourceBootstrap,[Parameter(Mandatory)][string]$PayloadRoot,[Parameter(Mandatory)][object[]]$PayloadRecords,[Parameter(Mandatory)][string]$PowerShellPath,[Parameter(Mandatory)][string]$Arguments,[Parameter(Mandatory)][string]$TransactionDirectory)
    $payloadAuthority=$null;$readyPipe=$null;$child=$null;$handedOff=$false
    try {
        . $SourceBootstrap
        $payloadAuthority=Open-CcodUninstallBootstrapPayloadAuthority -PayloadRoot $PayloadRoot -Records $PayloadRecords
        $readyPipe=[IO.Pipes.AnonymousPipeServerStream]::new([IO.Pipes.PipeDirection]::In,[IO.HandleInheritability]::Inheritable)
        $readyHandle=$readyPipe.GetClientHandleAsString()
        $child=Start-Process -FilePath $PowerShellPath -ArgumentList ($Arguments+' -AuthorityReadyHandle '+$readyHandle) -WindowStyle Hidden -RedirectStandardOutput (Join-Path $TransactionDirectory 'installed-finalizer.stdout.log') -RedirectStandardError (Join-Path $TransactionDirectory 'installed-finalizer.stderr.log') -PassThru -ErrorAction Stop
        [void]$child.Handle
        $readyPipe.DisposeLocalCopyOfClientHandle()
        $buffer=[byte[]]::new(4);$received=0;$clock=[Diagnostics.Stopwatch]::StartNew()
        while ($received -lt $buffer.Length) {
            $remaining=15000-[int]$clock.ElapsedMilliseconds
            if ($remaining -le 0) { throw 'finalizer authority timeout' }
            $pending=$readyPipe.ReadAsync($buffer,$received,$buffer.Length-$received)
            if (-not $pending.Wait($remaining) -or $pending.Result -le 0) { throw 'finalizer authority unavailable' }
            $received+=$pending.Result
        }
        if ([BitConverter]::ToInt32($buffer,0) -ne $child.Id) { throw 'finalizer authority identity' }
        # The exact native child now owns its complete staged payload closure.
        # These external holds may close; installed holds close before wrapper exit.
        $handedOff=$true
        return $child
    } finally {
        if ($null -ne $readyPipe) { $readyPipe.Dispose() }
        if (-not $handedOff -and $null -ne $child) {
            try { if (-not $child.HasExited) { $child.Kill();$child.WaitForExit() } } finally { $child.Dispose() }
        }
        if ($null -ne $payloadAuthority) { $payloadAuthority.Dispose() }
    }
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
$runtimeParent = [IO.Path]::GetFullPath((Join-Path $expectedInstallRoot 'runtime'))
$runtimePrefix = $runtimeParent.TrimEnd('\') + '\'
$installedRuntimeId = if ($installerRoot.StartsWith($runtimePrefix,[StringComparison]::OrdinalIgnoreCase)) { $installerRoot.Substring($runtimePrefix.Length) } else { $null }
if ($null -ne $installedRuntimeId -and $installedRuntimeId -cmatch '^2\.5\.22-[0-9a-f]{16}-[0-9a-f]{32}$' -and $installedRuntimeId.IndexOf('\') -lt 0) {
    $bootstrapPath = [IO.Path]::GetFullPath((Join-Path $installerRoot 'src\persistence\UninstallBootstrap.ps1'))
    if (-not [IO.File]::Exists($bootstrapPath)) { Throw-CcodPublicUninstallError 'CCOD_UNINSTALL_INSTALLED_INVALID' 'The sealed generation uninstall bootstrap is missing.' $bootstrapPath }
    $bootstrapItem = Get-Item -LiteralPath $bootstrapPath -Force -ErrorAction Stop
    if ($bootstrapItem.PSIsContainer -or (($bootstrapItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { Throw-CcodPublicUninstallError 'CCOD_UNINSTALL_INSTALLED_INVALID' 'The sealed generation uninstall bootstrap is unsafe.' $bootstrapPath }
    if (-not $PSCmdlet.ShouldProcess($expectedInstallRoot,'Run manifest-bound cleanup from the selected sealed generation')) { return [pscustomobject][ordered]@{Outcome='WhatIf';KeptDeviceKeyStore=$true} }
    $current=[Diagnostics.Process]::GetCurrentProcess();$windowsIdentity=[Security.Principal.WindowsIdentity]::GetCurrent();try{$wrapperId=[int]$current.Id;$wrapperCreated=$current.StartTime.ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture);$wrapperIdentity=[pscustomobject]@{pid=$wrapperId;creationTimeUtc=$wrapperCreated;sessionId=[int]$current.SessionId;userSid=[string]$windowsIdentity.User.Value}}finally{$current.Dispose();$windowsIdentity.Dispose()}
    try { $prepared=Invoke-CcodPublicUninstallPrepare -Path $bootstrapPath -Runtime $installerRoot -Root $expectedInstallRoot -PrepareMode PrepareInstalled -Identity $wrapperIdentity }
    catch { Throw-CcodPublicUninstallError 'CCOD_UNINSTALL_INSTALLED_PREPARE_FAILED' 'Sealed generation cleanup did not reach its external finalization boundary.' $_ }
    if($null-eq$prepared-or$prepared.transactionId-isnot[string]-or$prepared.transactionId-cnotmatch'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'-or$prepared.phase-cne'TaskRemoved'-or$prepared.runtimeId-cne$installedRuntimeId){Throw-CcodPublicUninstallError 'CCOD_UNINSTALL_INSTALLED_PREPARE_FAILED' 'Sealed generation cleanup returned an invalid receipt.' $prepared}
    $transactionRoot=[IO.Path]::GetFullPath((Join-Path $localAppData 'CodexRemote-fix-uninstall'))
    $transactionDirectory=[IO.Path]::GetFullPath((Join-Path $transactionRoot $prepared.transactionId))
    $finalizer=[IO.Path]::GetFullPath((Join-Path $transactionDirectory 'payload\src\persistence\InstalledUninstallFinalizer.ps1'))
    if(-not[IO.File]::Exists($finalizer)){Throw-CcodPublicUninstallError 'CCOD_UNINSTALL_INSTALLED_FINALIZER_MISSING' 'The verified external installed finalizer is missing.' $finalizer}
    $powershellPath=Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::System)) 'WindowsPowerShell\v1.0\powershell.exe'
    if(-not[IO.File]::Exists($powershellPath)){Throw-CcodPublicUninstallError 'CCOD_UNINSTALL_INSTALLED_FINALIZER_MISSING' 'The Windows PowerShell host is unavailable.' $powershellPath}
    function ConvertTo-CcodInstalledUninstallLiteral([string]$Value){
        return '"' + ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)\z', '$1$1') + '"'
    }
    $historical=$prepared.installedBinding;$resumeExisting=$null-ne$historical-and([int]$historical.wrapperPid-ne$wrapperId-or[string]$historical.wrapperCreationTimeUtc-cne$wrapperCreated-or[int]$historical.wrapperSessionId-ne[int]$wrapperIdentity.sessionId-or[string]$historical.wrapperUserSid-cne[string]$wrapperIdentity.userSid)
    $arguments=if($resumeExisting){'-NoProfile -NonInteractive -ExecutionPolicy Bypass -File {0} -WrapperResume -TransactionId {1} -RuntimeRoot {2} -InstallRoot {3} -WrapperProcessId {4} -WrapperCreationTimeUtc {5}'-f(ConvertTo-CcodInstalledUninstallLiteral $finalizer),(ConvertTo-CcodInstalledUninstallLiteral $prepared.transactionId),(ConvertTo-CcodInstalledUninstallLiteral $installerRoot),(ConvertTo-CcodInstalledUninstallLiteral $expectedInstallRoot),$wrapperId,(ConvertTo-CcodInstalledUninstallLiteral $wrapperCreated)}else{'-NoProfile -NonInteractive -ExecutionPolicy Bypass -File {0} -TransactionId {1} -RuntimeRoot {2} -InstallRoot {3} -WrapperProcessId {4} -WrapperCreationTimeUtc {5}'-f(ConvertTo-CcodInstalledUninstallLiteral $finalizer),(ConvertTo-CcodInstalledUninstallLiteral $prepared.transactionId),(ConvertTo-CcodInstalledUninstallLiteral $installerRoot),(ConvertTo-CcodInstalledUninstallLiteral $expectedInstallRoot),$wrapperId,(ConvertTo-CcodInstalledUninstallLiteral $wrapperCreated)}
    try{$process=Start-CcodPublicInstalledFinalizer -SourceBootstrap $bootstrapPath -PayloadRoot (Join-Path $transactionDirectory 'payload') -PayloadRecords @($prepared.installedBinding.payloadRecords) -PowerShellPath $powershellPath -Arguments $arguments -TransactionDirectory $transactionDirectory}catch{Throw-CcodPublicUninstallError 'CCOD_UNINSTALL_INSTALLED_FINALIZER_START_FAILED' 'The external installed finalizer could not acquire its verified payload; application state was retained.' $_}
    return [pscustomobject][ordered]@{Outcome='InstalledFinalizationStarted';TransactionId=[string]$prepared.transactionId;FinalizerProcessId=[int]$process.Id;KeptDeviceKeyStore=$true}
}
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
        $prepared = Invoke-CcodPublicUninstallPrepare -Path $bootstrapPath -Runtime $installerRoot -Root $expectedInstallRoot -PrepareMode Prepare -Identity $null
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
        return '"' + ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)\z', '$1$1') + '"'
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
