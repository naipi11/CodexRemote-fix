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
function Test-CcodInstalledFinalizerIdentity($Value){$Value.pid-is[int]-and$Value.pid-gt0-and$Value.creationTimeUtc-is[string]-and$Value.creationTimeUtc-cmatch'^\d{4}-\d{2}-\d{2}T'-and$Value.sessionId-is[int]-and$Value.sessionId-ge0-and$Value.userSid-is[string]-and$Value.userSid-cmatch'^S-1-'}
function Get-CcodInstalledFinalizerLocalAppData {
    $value=[Environment]::GetEnvironmentVariable('LOCALAPPDATA','Process')
    if(-not[string]::IsNullOrWhiteSpace($value)){
        try{if([IO.Path]::IsPathRooted($value)){return [IO.Path]::GetFullPath($value).TrimEnd('\')}}catch{}
        Throw-CcodInstalledFinalizerError 'CCOD_INSTALLED_FINALIZER_INVALID' 'Process LOCALAPPDATA is not a canonical absolute path' $value
    }
    $value=[Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    if([string]::IsNullOrWhiteSpace($value)-or-not[IO.Path]::IsPathRooted($value)){Throw-CcodInstalledFinalizerError 'CCOD_INSTALLED_FINALIZER_INVALID' 'Current-user local application data is unavailable' $value}
    [IO.Path]::GetFullPath($value).TrimEnd('\')
}
function Get-CcodInstalledFinalizerAdapters {
    param([hashtable]$Adapters,[string]$TransactionRoot,[string]$PayloadRoot)
    $bootstrap=Join-Path $PayloadRoot 'src\persistence\UninstallBootstrap.ps1'
    $lifecycle=Join-Path $PayloadRoot 'src\persistence\modules\InstallLifecycle.psm1'
    $defaults=@{
        WaitWrapperExit={param($Identity,$Timeout);$process=Get-Process -Id $Identity.pid -ErrorAction SilentlyContinue;if($null-eq$process){return [pscustomobject]@{verifiedAtStart=$false;exited=$false}};try{if($process.StartTime.ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture)-cne$Identity.creationTimeUtc-or[int]$process.SessionId-ne[int]$Identity.sessionId){return [pscustomobject]@{verifiedAtStart=$false;exited=$false}}}finally{$process.Dispose()};$owner=$null;try{$owner=(Get-CimInstance Win32_Process -Filter ('ProcessId='+$Identity.pid)-ErrorAction Stop|Invoke-CimMethod -MethodName GetOwnerSid -ErrorAction Stop)}catch{};if($null-eq$owner-or[int]$owner.ReturnValue-ne0-or[string]$owner.Sid-cne[string]$Identity.userSid){return [pscustomobject]@{verifiedAtStart=$false;exited=$false}};$stopwatch=[Diagnostics.Stopwatch]::StartNew();while($stopwatch.ElapsedMilliseconds-lt$Timeout){$current=Get-Process -Id $Identity.pid -ErrorAction SilentlyContinue;if($null-eq$current){return [pscustomobject]@{verifiedAtStart=$true;exited=$true}};try{if($current.StartTime.ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture)-cne$Identity.creationTimeUtc){return [pscustomobject]@{verifiedAtStart=$true;exited=$true}}}finally{$current.Dispose()};Start-Sleep -Milliseconds 100};[pscustomobject]@{verifiedAtStart=$true;exited=$false}}
        ReadPreparedTransaction={param($Id,$ExpectedInstallRoot);. $bootstrap;$identity=Get-CcodUninstallBootstrapCurrentIdentity;$value=Read-CcodUninstallBootstrapStoredTransaction -TransactionRoot $TransactionRoot -ExpectedUserSid $identity.userSid -IncludeCompleted -ExpectedInstallRoot $ExpectedInstallRoot;if($null-eq$value-or$value.transactionId-cne$Id){return $null};$value}.GetNewClosure()
        ValidateSelectedGeneration={param($SelectedRuntime,$Root,$Transaction);. $bootstrap;$context=Get-CcodUninstallBootstrapVerifiedRuntimeContext -InstallerRoot $SelectedRuntime -InstallRoot $Root -InvocationPath (Join-Path $SelectedRuntime 'src\persistence\UninstallBootstrap.ps1');$manifest=Get-CcodUninstallBootstrapFileFingerprint -Path (Join-Path $SelectedRuntime 'manifest.json');$context.runtimeId-ceq$Transaction.runtimeId-and[uint64]$context.runtimeGeneration-eq[uint64]$Transaction.runtimeGeneration-and$manifest.sha256-ceq$Transaction.installedBinding.runtimeManifestSha256}.GetNewClosure()
        ReadCurrentEpoch={param($Root);. $bootstrap;$record=Read-CcodUninstallBootstrapJson -Path (Join-Path $Root 'state\lifecycle-epoch.json') -Kind 'Lifecycle epoch';[uint64]$record.epoch}.GetNewClosure()
        RemoveSelectedGeneration={param($SelectedRuntime,$Transaction);. $bootstrap;$expected=[IO.Path]::GetFullPath([string]$Transaction.installedBinding.selectedRuntimeRoot);if([IO.Path]::GetFullPath($SelectedRuntime)-cne$expected){throw 'selected root changed'};$item=Get-Item -LiteralPath $expected -Force -ErrorAction Stop;if(-not$item.PSIsContainer-or($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){throw 'selected root unsafe'};Remove-Item -LiteralPath $expected -Recurse -Force -ErrorAction Stop;$Transaction.phase='ReadyForInno';$Transaction.resumePhase='ReadyForInno';Write-CcodUninstallBootstrapStoredTransaction -TransactionDirectory (Join-Path $TransactionRoot $Transaction.transactionId) -Transaction $Transaction;$Transaction}.GetNewClosure()
        TestSelectedRootAbsent={param($Root)-not([IO.Directory]::Exists($Root)-or[IO.File]::Exists($Root))}
        RemoveMatchedProductRegistration={param($Transaction);. $bootstrap;Remove-CcodUninstallBootstrapProductRegistration -Context ([pscustomobject][ordered]@{runtimeId=$Transaction.runtimeId;runtimeGeneration=[uint64]$Transaction.runtimeGeneration;leaseEpoch=[uint64]$Transaction.leaseEpoch;userSid=$Transaction.userSid;sessionId=[int]$Transaction.sessionId;readyEvidence=$Transaction.readyEvidence;payloadRecords=New-CcodUninstallBootstrapPayloadRecords -ResumeOnly})}
        FinalizeReceipt={param($Transaction);& $bootstrap -InstallerRoot $RuntimeRoot -InstallRoot $InstallRoot -Mode FinalizeReceipt;Throw-CcodInstalledFinalizerError 'CCOD_INSTALLED_FINALIZER_INVALID' 'Finalization bootstrap returned unexpectedly' $Transaction.transactionId}.GetNewClosure()
    }
    if($null-eq$Adapters){return $defaults};$resolved=@{};foreach($name in $defaults.Keys){$resolved[$name]=$defaults[$name]};foreach($name in $Adapters.Keys){if(-not$resolved.ContainsKey($name)-or$Adapters[$name]-isnot[scriptblock]){Throw-CcodInstalledFinalizerError 'CCOD_INSTALLED_FINALIZER_INVALID' 'Finalizer adapter contract is invalid' $name};$resolved[$name]=$Adapters[$name]};$resolved
}
function Invoke-CcodInstalledUninstallFinalizer {
    param([Parameter(Mandatory)][string]$TransactionId,[Parameter(Mandatory)][string]$RuntimeRoot,[Parameter(Mandatory)][string]$InstallRoot,[Parameter(Mandatory)]$WrapperIdentity,[hashtable]$Adapters)
    if($TransactionId-cnotmatch'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'-or-not[IO.Path]::IsPathRooted($RuntimeRoot)-or-not[IO.Path]::IsPathRooted($InstallRoot)-or-not(Test-CcodInstalledFinalizerIdentity $WrapperIdentity)){Throw-CcodInstalledFinalizerError 'CCOD_INSTALLED_FINALIZER_INVALID' 'Installed finalizer inputs are invalid' $TransactionId}
    $runtime=[IO.Path]::GetFullPath($RuntimeRoot);$install=[IO.Path]::GetFullPath($InstallRoot);$expected=[IO.Path]::GetFullPath((Join-Path (Join-Path $install 'runtime') ([IO.Path]::GetFileName($runtime))));if($runtime-cne$expected){Throw-CcodInstalledFinalizerError 'CCOD_INSTALLED_FINALIZER_INVALID' 'Runtime root is outside the fixed install runtime parent' $runtime}
    $local=Get-CcodInstalledFinalizerLocalAppData;$transactionRoot=[IO.Path]::GetFullPath((Join-Path $local 'CodexRemote-fix-uninstall'));$payloadRoot=[IO.Path]::GetFullPath((Join-Path (Join-Path $transactionRoot $TransactionId) 'payload'));if($null-eq$Adapters){$expectedSelf=[IO.Path]::GetFullPath((Join-Path $payloadRoot 'src\persistence\InstalledUninstallFinalizer.ps1'));if([string]::IsNullOrWhiteSpace($PSCommandPath)-or[IO.Path]::GetFullPath($PSCommandPath)-cne$expectedSelf){Throw-CcodInstalledFinalizerError 'CCOD_INSTALLED_FINALIZER_INVALID' 'Installed finalizer is outside the durable staged payload' $PSCommandPath};$self=Get-Item -LiteralPath $expectedSelf -Force -ErrorAction Stop;if($self.PSIsContainer-or($self.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){Throw-CcodInstalledFinalizerError 'CCOD_INSTALLED_FINALIZER_INVALID' 'Installed finalizer path is unsafe' $expectedSelf}};$adapter=Get-CcodInstalledFinalizerAdapters -Adapters $Adapters -TransactionRoot $transactionRoot -PayloadRoot $payloadRoot
    $wrapperExit=&$adapter.WaitWrapperExit $WrapperIdentity 15000;if($null-eq$wrapperExit-or$wrapperExit.verifiedAtStart-isnot[bool]-or-not$wrapperExit.verifiedAtStart-or$wrapperExit.exited-isnot[bool]-or-not$wrapperExit.exited){Throw-CcodInstalledFinalizerError 'CCOD_INSTALLED_FINALIZER_INVALID' 'Installed wrapper was not verified before its exact exit' $WrapperIdentity}
    $transaction=&$adapter.ReadPreparedTransaction $TransactionId $install
    $binding=if($null-ne$transaction){$transaction.installedBinding}else{$null};if($null-eq$transaction-or$transaction.transactionId-cne$TransactionId-or$transaction.phase-cne'TaskRemoved'-or$transaction.resumePhase-cne'TaskRemoved'-or$transaction.runtimeId-isnot[string]-or[IO.Path]::GetFileName($runtime)-cne[string]$transaction.runtimeId-or$null-eq$binding-or[IO.Path]::GetFullPath([string]$binding.selectedRuntimeRoot)-cne$runtime-or$binding.runtimeManifestSha256-isnot[string]-or$binding.runtimeManifestSha256-cnotmatch'^[0-9a-f]{64}$'-or[int]$binding.wrapperPid-ne$WrapperIdentity.pid-or[string]$binding.wrapperCreationTimeUtc-cne$WrapperIdentity.creationTimeUtc-or[int]$binding.wrapperSessionId-ne$WrapperIdentity.sessionId-or[string]$binding.wrapperUserSid-cne$WrapperIdentity.userSid){Throw-CcodInstalledFinalizerError 'CCOD_INSTALLED_FINALIZER_INVALID' 'Durable installed uninstall transaction identity is invalid' $transaction}
    if([uint64](&$adapter.ReadCurrentEpoch $install)-ne[uint64]$transaction.leaseEpoch-or-not(&$adapter.ValidateSelectedGeneration $runtime $install $transaction)){Throw-CcodInstalledFinalizerError 'CCOD_INSTALLED_FINALIZER_INVALID' 'Selected generation manifest or epoch does not match the transaction' $runtime}
    $ready=&$adapter.RemoveSelectedGeneration $runtime $transaction
    if($null-eq$ready-or$ready.phase-cne'ReadyForInno'-or-not(&$adapter.TestSelectedRootAbsent $runtime)){Throw-CcodInstalledFinalizerError 'CCOD_INSTALLED_FINALIZER_INVALID' 'Selected generation removal was not proven' $runtime}
    &$adapter.RemoveMatchedProductRegistration $ready
    $receipt=&$adapter.FinalizeReceipt $ready
    if($null-eq$receipt-or$receipt.phase-cne'Completed'){Throw-CcodInstalledFinalizerError 'CCOD_INSTALLED_FINALIZER_INVALID' 'Completion receipt was not proven' $TransactionId}
    $receipt
}

if($MyInvocation.InvocationName-ne'.'){
    $currentIdentity=[Security.Principal.WindowsIdentity]::GetCurrent();$process=[Diagnostics.Process]::GetCurrentProcess();try{$identity=[pscustomobject]@{pid=[int]$WrapperProcessId;creationTimeUtc=$WrapperCreationTimeUtc;sessionId=[int]$process.SessionId;userSid=[string]$currentIdentity.User.Value}}finally{$process.Dispose();$currentIdentity.Dispose()}
    try{Invoke-CcodInstalledUninstallFinalizer -TransactionId $TransactionId -RuntimeRoot $RuntimeRoot -InstallRoot $InstallRoot -WrapperIdentity $identity|Out-Null;exit 0}catch{[Console]::Error.WriteLine([string]$_.FullyQualifiedErrorId);exit 3}
}
