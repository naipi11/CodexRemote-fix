[CmdletBinding()]
param(
    [ValidatePattern('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')][string]$TransactionId,
    [string]$RuntimeRoot,
    [string]$InstallRoot,
    [int]$WrapperProcessId,
    [string]$WrapperCreationTimeUtc
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

function Throw-CcodInstalledFinalizerError {
    param([string]$Id,[string]$Message,$Target)
    throw [Management.Automation.ErrorRecord]::new([InvalidOperationException]::new($Message),$Id,[Management.Automation.ErrorCategory]::InvalidData,$Target)
}
function Test-CcodInstalledFinalizerIdentity($Value){$Value.pid-is[int]-and$Value.pid-gt0-and$Value.creationTimeUtc-is[string]-and$Value.creationTimeUtc-cmatch'^\d{4}-\d{2}-\d{2}T'}
function Get-CcodInstalledFinalizerAdapters {
    param([hashtable]$Adapters,[string]$TransactionRoot,[string]$PayloadRoot)
    $bootstrap=Join-Path $PayloadRoot 'src\persistence\UninstallBootstrap.ps1'
    $lifecycle=Join-Path $PayloadRoot 'src\persistence\modules\InstallLifecycle.psm1'
    $defaults=@{
        WaitWrapperExit={param($Identity,$Timeout);$stopwatch=[Diagnostics.Stopwatch]::StartNew();while($stopwatch.ElapsedMilliseconds-lt$Timeout){$process=Get-Process -Id $Identity.pid -ErrorAction SilentlyContinue;if($null-eq$process){return $true};try{if($process.StartTime.ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture)-cne$Identity.creationTimeUtc){return $true}}finally{$process.Dispose()};Start-Sleep -Milliseconds 100};$false}
        ReadPreparedTransaction={param($Id);. $bootstrap;$identity=Get-CcodUninstallBootstrapCurrentIdentity;$value=Read-CcodUninstallBootstrapStoredTransaction -TransactionRoot $TransactionRoot -ExpectedUserSid $identity.userSid -IncludeCompleted;if($null-eq$value-or$value.transactionId-cne$Id){return $null};$value}.GetNewClosure()
        ValidateSelectedGeneration={param($SelectedRuntime,$Root,$Transaction);. $bootstrap;$context=Get-CcodUninstallBootstrapVerifiedRuntimeContext -InstallerRoot $SelectedRuntime -InstallRoot $Root -InvocationPath (Join-Path $SelectedRuntime 'src\persistence\UninstallBootstrap.ps1');$context.runtimeId-ceq$Transaction.runtimeId-and[uint64]$context.runtimeGeneration-eq[uint64]$Transaction.runtimeGeneration}.GetNewClosure()
        RemoveMatchedApplicationState={param($SelectedRuntime,$Root,$Transaction);. $bootstrap;$module=Import-Module $lifecycle -Force -PassThru -ErrorAction Stop;$directory=Join-Path $TransactionRoot $Transaction.transactionId;$writer={param($Value)Write-CcodUninstallBootstrapStoredTransaction -TransactionDirectory $directory -Transaction $Value}.GetNewClosure();&$module {param($Install,$Value,$Write)Invoke-CcodUninstallCleanup -InstallRoot $Install -Transaction $Value -WriteTransaction $Write -StopAfterTaskRemoval:$false} $Root $Transaction $writer}.GetNewClosure()
        TestInstallRootAbsent={param($Root)-not([IO.Directory]::Exists($Root)-or[IO.File]::Exists($Root))}
        RemoveMatchedProductRegistration={param($Transaction);. $bootstrap;Remove-CcodUninstallBootstrapProductRegistration -Context ([pscustomobject][ordered]@{runtimeId=$Transaction.runtimeId;runtimeGeneration=[uint64]$Transaction.runtimeGeneration;leaseEpoch=[uint64]$Transaction.leaseEpoch;userSid=$Transaction.userSid;sessionId=[int]$Transaction.sessionId;payloadRecords=New-CcodUninstallBootstrapPayloadRecords -ResumeOnly})}
        FinalizeReceipt={param($Transaction);& $bootstrap -InstallerRoot $RuntimeRoot -InstallRoot $InstallRoot -Mode FinalizeReceipt;Throw-CcodInstalledFinalizerError 'CCOD_INSTALLED_FINALIZER_INVALID' 'Finalization bootstrap returned unexpectedly' $Transaction.transactionId}.GetNewClosure()
    }
    if($null-eq$Adapters){return $defaults};$resolved=@{};foreach($name in $defaults.Keys){$resolved[$name]=$defaults[$name]};foreach($name in $Adapters.Keys){if(-not$resolved.ContainsKey($name)-or$Adapters[$name]-isnot[scriptblock]){Throw-CcodInstalledFinalizerError 'CCOD_INSTALLED_FINALIZER_INVALID' 'Finalizer adapter contract is invalid' $name};$resolved[$name]=$Adapters[$name]};$resolved
}
function Invoke-CcodInstalledUninstallFinalizer {
    param([Parameter(Mandatory)][string]$TransactionId,[Parameter(Mandatory)][string]$RuntimeRoot,[Parameter(Mandatory)][string]$InstallRoot,[Parameter(Mandatory)]$WrapperIdentity,[hashtable]$Adapters)
    if($TransactionId-cnotmatch'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'-or-not[IO.Path]::IsPathRooted($RuntimeRoot)-or-not[IO.Path]::IsPathRooted($InstallRoot)-or-not(Test-CcodInstalledFinalizerIdentity $WrapperIdentity)){Throw-CcodInstalledFinalizerError 'CCOD_INSTALLED_FINALIZER_INVALID' 'Installed finalizer inputs are invalid' $TransactionId}
    $runtime=[IO.Path]::GetFullPath($RuntimeRoot);$install=[IO.Path]::GetFullPath($InstallRoot);$expected=[IO.Path]::GetFullPath((Join-Path (Join-Path $install 'runtime') ([IO.Path]::GetFileName($runtime))));if($runtime-cne$expected){Throw-CcodInstalledFinalizerError 'CCOD_INSTALLED_FINALIZER_INVALID' 'Runtime root is outside the fixed install runtime parent' $runtime}
    $local=[Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData);$transactionRoot=[IO.Path]::GetFullPath((Join-Path $local 'CodexRemote-fix-uninstall'));$payloadRoot=[IO.Path]::GetFullPath((Join-Path (Join-Path $transactionRoot $TransactionId) 'payload'));if($null-eq$Adapters){$expectedSelf=[IO.Path]::GetFullPath((Join-Path $payloadRoot 'src\persistence\InstalledUninstallFinalizer.ps1'));if([string]::IsNullOrWhiteSpace($PSCommandPath)-or[IO.Path]::GetFullPath($PSCommandPath)-cne$expectedSelf){Throw-CcodInstalledFinalizerError 'CCOD_INSTALLED_FINALIZER_INVALID' 'Installed finalizer is outside the durable staged payload' $PSCommandPath};$self=Get-Item -LiteralPath $expectedSelf -Force -ErrorAction Stop;if($self.PSIsContainer-or($self.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){Throw-CcodInstalledFinalizerError 'CCOD_INSTALLED_FINALIZER_INVALID' 'Installed finalizer path is unsafe' $expectedSelf}};$adapter=Get-CcodInstalledFinalizerAdapters -Adapters $Adapters -TransactionRoot $transactionRoot -PayloadRoot $payloadRoot
    if(-not(& $adapter.WaitWrapperExit $WrapperIdentity 15000)){Throw-CcodInstalledFinalizerError 'CCOD_INSTALLED_FINALIZER_INVALID' 'Installed wrapper did not exit with the expected identity' $WrapperIdentity}
    $transaction=&$adapter.ReadPreparedTransaction $TransactionId
    if($null-eq$transaction-or$transaction.transactionId-cne$TransactionId-or$transaction.phase-cne'TaskRemoved'-or$transaction.resumePhase-cne'TaskRemoved'){Throw-CcodInstalledFinalizerError 'CCOD_INSTALLED_FINALIZER_INVALID' 'Durable installed uninstall transaction is not at TaskRemoved' $transaction}
    if(-not(&$adapter.ValidateSelectedGeneration $runtime $install $transaction)){Throw-CcodInstalledFinalizerError 'CCOD_INSTALLED_FINALIZER_INVALID' 'Selected generation proof does not match the transaction' $runtime}
    $ready=&$adapter.RemoveMatchedApplicationState $runtime $install $transaction
    if($null-eq$ready-or$ready.phase-cne'ReadyForInno'-or-not(&$adapter.TestInstallRootAbsent $install)){Throw-CcodInstalledFinalizerError 'CCOD_INSTALLED_FINALIZER_INVALID' 'Matched application state removal was not proven' $install}
    &$adapter.RemoveMatchedProductRegistration $ready
    $receipt=&$adapter.FinalizeReceipt $ready
    if($null-eq$receipt-or$receipt.phase-cne'Completed'){Throw-CcodInstalledFinalizerError 'CCOD_INSTALLED_FINALIZER_INVALID' 'Completion receipt was not proven' $TransactionId}
    $receipt
}

if($MyInvocation.InvocationName-ne'.'){
    $identity=[pscustomobject]@{pid=[int]$WrapperProcessId;creationTimeUtc=$WrapperCreationTimeUtc}
    try{Invoke-CcodInstalledUninstallFinalizer -TransactionId $TransactionId -RuntimeRoot $RuntimeRoot -InstallRoot $InstallRoot -WrapperIdentity $identity|Out-Null;exit 0}catch{Write-Error ([string]$_.FullyQualifiedErrorId);exit 3}
}
