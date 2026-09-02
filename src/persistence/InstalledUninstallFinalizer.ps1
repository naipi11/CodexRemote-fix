[CmdletBinding(DefaultParameterSetName='Initial')]
param(
    [ValidatePattern('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')][string]$TransactionId,
    [string]$RuntimeRoot,
    [string]$InstallRoot,
    [Parameter(ParameterSetName='Initial')][Parameter(ParameterSetName='WrapperResume')][int]$WrapperProcessId,
    [Parameter(ParameterSetName='Initial')][Parameter(ParameterSetName='WrapperResume')][string]$WrapperCreationTimeUtc,
    [Parameter(ParameterSetName='WrapperResume')][switch]$WrapperResume,
    [Parameter(ParameterSetName='Resume')][switch]$Resume
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$script:CcodInstalledFinalizerPayloadEntries=@('src/persistence/UninstallBootstrap.ps1','src/persistence/PortableUninstallFinalizer.ps1','src/persistence/InstalledUninstallFinalizer.ps1','src/persistence/modules/GenerationReclamation.psm1','src/persistence/modules/InstallLifecycle.psm1','src/persistence/modules/ProductRegistration.psm1','src/persistence/modules/PortableRelease.psm1','src/persistence/modules/PersistenceIO.psm1','src/persistence/modules/RuntimeManifest.psm1','src/persistence/modules/LifecycleEpoch.psm1','src/persistence/modules/StateStore.psm1','src/persistence/modules/TrustedLogonIdentity.psm1','src/persistence/modules/ScheduledTask.psm1','src/persistence/modules/KernelObjects.psm1','src/persistence/modules/CompatibilityProbe.psm1','src/persistence/modules/UiPreferences.psm1','src/persistence/modules/LifecycleTransaction.psm1')

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
function Test-CcodInstalledFinalizerStagedPayload {
    param($Transaction,[string]$PayloadRoot)
    try{
        $root=[IO.Path]::GetFullPath($PayloadRoot).TrimEnd('\');$rootItem=Get-Item -LiteralPath $root -Force -ErrorAction Stop;if(-not$rootItem.PSIsContainer-or($rootItem.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){return $false}
        $records=@($Transaction.installedBinding.payloadRecords);if($records.Count-ne$script:CcodInstalledFinalizerPayloadEntries.Count){return $false}
        for($index=0;$index-lt$records.Count;$index++){
            $record=$records[$index];$relative=$script:CcodInstalledFinalizerPayloadEntries[$index];$integerTypes=@([byte],[uint16],[uint32],[uint64],[int16],[int32],[int64]);if($record.path-cne$relative-or$integerTypes-cnotcontains$record.length.GetType()-or[decimal]$record.length-lt0-or$record.sha256-isnot[string]-or$record.sha256-cnotmatch'^[0-9a-f]{64}$'){return $false}
            $path=[IO.Path]::GetFullPath((Join-Path $root $relative.Replace('/','\')));if(-not$path.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)){return $false}
            $cursor=$root;foreach($segment in $relative.Replace('/','\').Split('\')){$cursor=Join-Path $cursor $segment;$item=Get-Item -LiteralPath $cursor -Force -ErrorAction Stop;if(($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){return $false}}
            $file=Get-Item -LiteralPath $path -Force -ErrorAction Stop;if($file.PSIsContainer-or$file-isnot[IO.FileInfo]-or[int64]$file.Length-ne[int64]$record.length){return $false};$streams=@(Get-Item -LiteralPath $path -Stream * -ErrorAction Stop);if($streams.Count-ne1-or[string]$streams[0].Stream-cne':$DATA'){return $false}
            $hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant();if($hash-cne[string]$record.sha256){return $false}
        }
        $self=@($records|Where-Object{$_.path-ceq'src/persistence/InstalledUninstallFinalizer.ps1'});return $self.Count-eq1-and[uint64]$self[0].length-eq[uint64]$Transaction.installedBinding.resumeScriptLength-and$self[0].sha256-ceq$Transaction.installedBinding.resumeScriptSha256
    }catch{return $false}
}
function Test-CcodInstalledFinalizerJsonHasNoDuplicateProperties {
    param([string]$Json)
    if($null-eq$Json){return $false};$objects=[Collections.Generic.Stack[object]]::new()
    for($index=0;$index-lt$Json.Length;$index++){$character=$Json[$index];if($character-eq'{'){$objects.Push([Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal));continue};if($character-eq'}'){if($objects.Count-eq0){return $false};[void]$objects.Pop();continue};if($character-ne'"'){continue};$name=[Text.StringBuilder]::new();$index++;while($index-lt$Json.Length){$character=$Json[$index];if($character-eq'"'){break};if($character-ne[char]92){[void]$name.Append($character);$index++;continue};$index++;if($index-ge$Json.Length){return $false};$escape=$Json[$index];if($escape-eq'u'){if($index+4-ge$Json.Length){return $false};try{[void]$name.Append([char][Convert]::ToInt32($Json.Substring($index+1,4),16))}catch{return $false};$index+=5;continue};switch([string]$escape){'"'{$decoded='"'};'\'{$decoded=[char]92};'/'{$decoded='/'};'b'{$decoded=[char]8};'f'{$decoded=[char]12};'n'{$decoded=[char]10};'r'{$decoded=[char]13};'t'{$decoded=[char]9};default{return $false}};[void]$name.Append($decoded);$index++};if($index-ge$Json.Length){return $false};$next=$index+1;while($next-lt$Json.Length-and[char]::IsWhiteSpace($Json[$next])){$next++};if($next-lt$Json.Length-and$Json[$next]-eq':'){if($objects.Count-eq0-or-not$objects.Peek().Add($name.ToString())){return $false}}};return $objects.Count-eq0
}
function Read-CcodInstalledFinalizerJson {
    param([string]$Path)
    try{$item=Get-Item -LiteralPath $Path -Force -ErrorAction Stop;if($item.PSIsContainer-or$item-isnot[IO.FileInfo]-or($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0-or$item.Length-lt1-or$item.Length-gt1048576){throw 'unsafe json'};$streams=@(Get-Item -LiteralPath $Path -Stream * -ErrorAction Stop);if($streams.Count-ne1-or[string]$streams[0].Stream-cne':$DATA'){throw 'json stream'};$json=[IO.File]::ReadAllText($Path,[Text.UTF8Encoding]::new($false,$true));if(-not(Test-CcodInstalledFinalizerJsonHasNoDuplicateProperties $json)){throw 'duplicate json'};$value=$json|ConvertFrom-Json -ErrorAction Stop;if($value-isnot[pscustomobject]){throw 'json object'};$value}catch{Throw-CcodInstalledFinalizerError 'CCOD_INSTALLED_FINALIZER_INVALID' 'Installed finalizer envelope is malformed or unsafe' $Path}
}
function Assert-CcodInstalledFinalizerDirectoryAcl {
    param([string]$Path,[string]$UserSid,[switch]$RequireProtected)
    try{$item=Get-Item -LiteralPath $Path -Force -ErrorAction Stop;$security=$item.GetAccessControl();$owner=$security.GetOwner([Security.Principal.SecurityIdentifier]);if($null-eq$owner-or$owner.Value-cne$UserSid-or($RequireProtected-and-not$security.AreAccessRulesProtected)){throw 'owner/protection'};$allowed=@($UserSid,'S-1-5-18');$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);foreach($rule in @($security.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))){if($rule.AccessControlType-ne[Security.AccessControl.AccessControlType]::Allow-or$allowed-cnotcontains$rule.IdentityReference.Value-or(($rule.FileSystemRights-band[Security.AccessControl.FileSystemRights]::FullControl)-ne[Security.AccessControl.FileSystemRights]::FullControl)){throw 'rule'};[void]$seen.Add($rule.IdentityReference.Value)};if($seen.Count-ne2){throw 'principals'}}catch{Throw-CcodInstalledFinalizerError 'CCOD_INSTALLED_FINALIZER_INVALID' 'Installed finalizer directory ACL is invalid' $Path}
}
function Read-CcodInstalledFinalizerEnvelope {
    param([string]$TransactionRoot,[string]$TransactionId,[string]$PayloadRoot,[string]$RuntimeRoot,[string]$InstallRoot)
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent();try{$sid=[string]$identity.User.Value}finally{$identity.Dispose()}
    foreach($directory in @($TransactionRoot,(Join-Path $TransactionRoot $TransactionId),$PayloadRoot)){$item=Get-Item -LiteralPath $directory -Force -ErrorAction Stop;if(-not$item.PSIsContainer-or($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){Throw-CcodInstalledFinalizerError 'CCOD_INSTALLED_FINALIZER_INVALID' 'Installed finalizer directory is unsafe' $directory}}
    Assert-CcodInstalledFinalizerDirectoryAcl -Path $TransactionRoot -UserSid $sid -RequireProtected;Assert-CcodInstalledFinalizerDirectoryAcl -Path (Join-Path $TransactionRoot $TransactionId) -UserSid $sid -RequireProtected;Assert-CcodInstalledFinalizerDirectoryAcl -Path $PayloadRoot -UserSid $sid
    $current=Read-CcodInstalledFinalizerJson (Join-Path $TransactionRoot 'current.json');if((@($current.PSObject.Properties.Name)-join'|')-cne'schemaVersion|transactionId'-or$current.schemaVersion-ne1-or$current.transactionId-cne$TransactionId){Throw-CcodInstalledFinalizerError 'CCOD_INSTALLED_FINALIZER_INVALID' 'Installed finalizer locator is invalid' $current}
    $transaction=Read-CcodInstalledFinalizerJson (Join-Path (Join-Path $TransactionRoot $TransactionId) 'transaction.json');$transactionFields=@('schemaVersion','transactionId','runtimeId','runtimeGeneration','leaseEpoch','userSid','sessionId','readyEvidence','installedBinding','phase','resumePhase','startedAtUtc','updatedAtUtc','errorCode');$bindingFields=@('selectedRuntimeRoot','runtimeManifestSha256','wrapperPid','wrapperCreationTimeUtc','wrapperSessionId','wrapperUserSid','resumeWrapperPid','resumeWrapperCreationTimeUtc','resumeWrapperSessionId','resumeWrapperUserSid','resumeScriptPath','resumeScriptLength','resumeScriptSha256','resumeCommand','payloadRecords');$readyFields=@('phase','installRoot','runtimeId','runtimeGeneration','packageSha256','manifestSha256','startMenuSha256','desktopSha256','targetPath','arguments')
    try{$install=[IO.Path]::GetFullPath($InstallRoot);$runtime=[IO.Path]::GetFullPath($RuntimeRoot);$resumeScript=[IO.Path]::GetFullPath((Join-Path $PayloadRoot 'src\persistence\InstalledUninstallFinalizer.ps1'));$system=[Environment]::GetFolderPath([Environment+SpecialFolder]::System);$powershell=[IO.Path]::GetFullPath((Join-Path $system 'WindowsPowerShell\v1.0\powershell.exe'));$command='"{0}" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{1}" -Resume -TransactionId "{2}" -RuntimeRoot "{3}" -InstallRoot "{4}"'-f$powershell,$resumeScript,$TransactionId,$runtime,$install}catch{Throw-CcodInstalledFinalizerError 'CCOD_INSTALLED_FINALIZER_INVALID' 'Installed finalizer envelope paths are invalid' $transaction}
    if((@($transaction.PSObject.Properties.Name)-join'|')-cne($transactionFields-join'|')-or$transaction.schemaVersion-ne1-or$transaction.transactionId-cne$TransactionId-or$transaction.userSid-cne$sid-or
       (@($transaction.readyEvidence.PSObject.Properties.Name)-join'|')-cne($readyFields-join'|')-or$transaction.readyEvidence.installRoot-cne$install-or$transaction.readyEvidence.runtimeId-cne$transaction.runtimeId-or
       (@($transaction.installedBinding.PSObject.Properties.Name)-join'|')-cne($bindingFields-join'|')-or$transaction.installedBinding.selectedRuntimeRoot-cne$runtime-or$transaction.installedBinding.resumeScriptPath-cne$resumeScript-or
       $transaction.installedBinding.resumeCommand-cne$command-or$transaction.installedBinding.wrapperUserSid-cne$transaction.userSid-or$transaction.installedBinding.wrapperSessionId-ne$transaction.sessionId-or
       $transaction.installedBinding.runtimeManifestSha256-cne$transaction.readyEvidence.manifestSha256-or-not(Test-CcodInstalledFinalizerStagedPayload -Transaction $transaction -PayloadRoot $PayloadRoot)){Throw-CcodInstalledFinalizerError 'CCOD_INSTALLED_FINALIZER_INVALID' 'Installed finalizer envelope is not bound to the staged payload' $transaction}
    return $transaction
}
function Get-CcodInstalledFinalizerAdapters {
    param([hashtable]$Adapters,[string]$TransactionRoot,[string]$PayloadRoot,[string]$RuntimeRoot,[string]$InstallRoot)
    $bootstrap=Join-Path $PayloadRoot 'src\persistence\UninstallBootstrap.ps1'
    $productModule=Join-Path $PayloadRoot 'src\persistence\modules\ProductRegistration.psm1'
    $kernelModule=Join-Path $PayloadRoot 'src\persistence\modules\KernelObjects.psm1'
    $finalizerRuntimeRoot=$RuntimeRoot;$finalizerInstallRoot=$InstallRoot;$stagedBootstrapPath=$bootstrap
    $defaults=@{
        GetCurrentIdentity={. $bootstrap;Get-CcodUninstallBootstrapCurrentIdentity}.GetNewClosure()
        EnterAccountTransition={param($UserSid)Import-Module $kernelModule -Force -DisableNameChecking -ErrorAction Stop;$lease=Enter-CcodMutex -Kind AccountTransition -UserSid $UserSid -TimeoutMilliseconds 30000;if($null-eq$lease-or$lease.Outcome-cne'Acquired'-or$lease.Kind-cne'AccountTransition'){throw 'account transition unavailable'};$lease}.GetNewClosure()
        ExitAccountTransition={param($Lease)Import-Module $kernelModule -Force -DisableNameChecking -ErrorAction Stop;[void](Exit-CcodMutex -Lease $Lease)}.GetNewClosure()
        EnterTransactionLock={param($UserSid);. $bootstrap;Enter-CcodUninstallBootstrapTransactionLock -UserSid $UserSid}.GetNewClosure()
        ExitTransactionLock={param($Lock);. $bootstrap;Exit-CcodUninstallBootstrapTransactionLock -Lock $Lock}.GetNewClosure()
        WaitWrapperExit={param($Identity,$Timeout);$process=Get-Process -Id $Identity.pid -ErrorAction SilentlyContinue;if($null-eq$process){return [pscustomobject]@{verifiedAtStart=$true;exited=$true}};try{if($process.StartTime.ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture)-cne$Identity.creationTimeUtc-or[int]$process.SessionId-ne[int]$Identity.sessionId){return [pscustomobject]@{verifiedAtStart=$true;exited=$true}}}finally{$process.Dispose()};$owner=$null;try{$owner=(Get-CimInstance Win32_Process -Filter ('ProcessId='+$Identity.pid)-ErrorAction Stop|Invoke-CimMethod -MethodName GetOwnerSid -ErrorAction Stop)}catch{};if($null-eq$owner-or[int]$owner.ReturnValue-ne0-or[string]$owner.Sid-cne[string]$Identity.userSid){return [pscustomobject]@{verifiedAtStart=$false;exited=$false}};$stopwatch=[Diagnostics.Stopwatch]::StartNew();while($stopwatch.ElapsedMilliseconds-lt$Timeout){$current=Get-Process -Id $Identity.pid -ErrorAction SilentlyContinue;if($null-eq$current){return [pscustomobject]@{verifiedAtStart=$true;exited=$true}};try{if($current.StartTime.ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture)-cne$Identity.creationTimeUtc){return [pscustomobject]@{verifiedAtStart=$true;exited=$true}}}finally{$current.Dispose()};Start-Sleep -Milliseconds 100};[pscustomobject]@{verifiedAtStart=$true;exited=$false}}
        ReadPreparedTransaction={param($Id,$ExpectedInstallRoot);. $bootstrap;$identity=Get-CcodUninstallBootstrapCurrentIdentity;$value=Read-CcodUninstallBootstrapStoredTransaction -TransactionRoot $TransactionRoot -ExpectedUserSid $identity.userSid -IncludeCompleted -ExpectedInstallRoot $ExpectedInstallRoot;if($null-eq$value-or$value.transactionId-cne$Id){return $null};$value}.GetNewClosure()
        ValidateStagedPayload={param($Transaction,$Root)Test-CcodInstalledFinalizerStagedPayload -Transaction $Transaction -PayloadRoot $Root}
        ValidateSelectedGeneration={param($SelectedRuntime,$Root,$Transaction);. $bootstrap;$context=Get-CcodUninstallBootstrapVerifiedRuntimeContext -InstallerRoot $SelectedRuntime -InstallRoot $Root -InvocationPath (Join-Path $SelectedRuntime 'src\persistence\UninstallBootstrap.ps1');$manifest=Get-CcodUninstallBootstrapFileFingerprint -Path (Join-Path $SelectedRuntime 'manifest.json');$context.runtimeId-ceq$Transaction.runtimeId-and[uint64]$context.runtimeGeneration-eq[uint64]$Transaction.runtimeGeneration-and$manifest.sha256-ceq$Transaction.installedBinding.runtimeManifestSha256}.GetNewClosure()
        ReadCurrentEpoch={param($Root);. $bootstrap;$record=Read-CcodUninstallBootstrapJson -Path (Join-Path $Root 'state\lifecycle-epoch.json') -Kind 'Lifecycle epoch';[uint64]$record.epoch}.GetNewClosure()
        GetSelectedRootState={param($Root)try{$item=Get-Item -LiteralPath $Root -Force -ErrorAction Stop;if($item.PSIsContainer-and($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-eq0){'Present'}else{'Invalid'}}catch [Management.Automation.ItemNotFoundException]{'Absent'}catch{throw}}
        InstallResumeProductRegistration={param($Transaction)Import-Module $productModule -Force -DisableNameChecking -ErrorAction Stop;Set-CcodInstalledUninstallResumeRegistration -Transaction $Transaction|Out-Null}.GetNewClosure()
        GetResumeProductRegistrationState={param($Transaction)Import-Module $productModule -Force -DisableNameChecking -ErrorAction Stop;Get-CcodInstalledUninstallResumeRegistrationState -Transaction $Transaction}.GetNewClosure()
        ReclaimSelectedGeneration={param($SelectedRuntime,$Transaction);$expected=[IO.Path]::GetFullPath([string]$Transaction.installedBinding.selectedRuntimeRoot);if([IO.Path]::GetFullPath($SelectedRuntime)-cne$expected){throw 'selected root changed'};$modulePath=Join-Path $PayloadRoot 'src\persistence\modules\GenerationReclamation.psm1';if(-not[IO.File]::Exists($modulePath)){throw 'generation reclamation module missing'};Import-Module $modulePath -Force -DisableNameChecking -ErrorAction Stop;$reclaimed=Remove-CcodVerifiedGenerationTree -InstallRoot $Transaction.readyEvidence.installRoot -RuntimeRoot $expected -RuntimeId $Transaction.runtimeId -ExpectedManifestSha256 $Transaction.installedBinding.runtimeManifestSha256;if($null-eq$reclaimed-or$reclaimed.phase-cne'Completed'-or$reclaimed.result-cne'Reclaimed'-or$reclaimed.runtimeId-cne$Transaction.runtimeId){throw 'generation reclamation proof invalid'};$reclaimed}.GetNewClosure()
        WriteReadyForInno={param($Transaction);. $bootstrap;$Transaction.phase='ReadyForInno';$Transaction.resumePhase='ReadyForInno';$Transaction.updatedAtUtc=[DateTime]::UtcNow.ToString('o',[Globalization.CultureInfo]::InvariantCulture);$Transaction.errorCode=$null;Write-CcodUninstallBootstrapStoredTransaction -TransactionDirectory (Join-Path $TransactionRoot $Transaction.transactionId) -Transaction $Transaction;$Transaction}.GetNewClosure()
        RemoveMatchedProductShortcuts={param($Transaction)Import-Module $productModule -Force -DisableNameChecking -ErrorAction Stop;Remove-CcodInstalledUninstallProductShortcuts -Transaction $Transaction|Out-Null}.GetNewClosure()
        FinalizeReceipt={param($Transaction);$runtimeForReceipt=$finalizerRuntimeRoot;$installForReceipt=$finalizerInstallRoot;$bootstrapForReceipt=$stagedBootstrapPath;. $bootstrapForReceipt;$validation={param($Root,$Value,$Identity)Assert-CcodUninstallBootstrapFinalizationInvocation -TransactionRoot $Root -Transaction $Value -Identity $Identity -InvocationPath $bootstrapForReceipt};$absence={param($Root)try{$item=Get-Item -LiteralPath $Root -Force -ErrorAction Stop;return $false}catch [Management.Automation.ItemNotFoundException]{return $true}catch{throw}};Invoke-CcodUninstallBootstrap -InstallerRoot $runtimeForReceipt -InstallRoot $installForReceipt -Mode FinalizeReceipt -Adapters @{ValidateFinalizationInvocation=$validation;TestInstallRootAbsent=$absence}}.GetNewClosure()
        TestCompletedReceipt={param($Transaction);. $bootstrap;$identity=Get-CcodUninstallBootstrapCurrentIdentity;Test-CcodUninstallBootstrapStoredCompletedReceipt -TransactionRoot $TransactionRoot -Transaction $Transaction -ExpectedUserSid $identity.userSid}.GetNewClosure()
        RemoveResumeProductRegistration={param($Transaction)Import-Module $productModule -Force -DisableNameChecking -ErrorAction Stop;Remove-CcodInstalledUninstallResumeRegistration -Transaction $Transaction -CompletedReceiptProven}.GetNewClosure()
    }
    if($null-eq$Adapters){return $defaults};$resolved=@{};foreach($name in $defaults.Keys){$resolved[$name]=$defaults[$name]};foreach($name in $Adapters.Keys){if(-not$resolved.ContainsKey($name)-or$Adapters[$name]-isnot[scriptblock]){Throw-CcodInstalledFinalizerError 'CCOD_INSTALLED_FINALIZER_INVALID' 'Finalizer adapter contract is invalid' $name};$resolved[$name]=$Adapters[$name]};$resolved
}
function Assert-CcodInstalledFinalizerTransactionBinding {
    param($Transaction,[string]$TransactionId,[string]$RuntimeRoot,[string]$InstallRoot,$CallerIdentity,$WrapperIdentity,[bool]$IsResume,[bool]$IsWrapperResume,[string]$PayloadRoot)
    $binding=if($null-ne$Transaction){$Transaction.installedBinding}else{$null};$effectivePhase=if($null-ne$Transaction-and$Transaction.phase-ceq'Failed'){$Transaction.resumePhase}elseif($null-ne$Transaction){$Transaction.phase}else{$null}
    try{$expectedRuntime=[IO.Path]::GetFullPath((Join-Path (Join-Path $InstallRoot 'runtime') ([string]$Transaction.runtimeId)));$expectedScript=[IO.Path]::GetFullPath((Join-Path $PayloadRoot 'src\persistence\InstalledUninstallFinalizer.ps1'));$system=[Environment]::GetFolderPath([Environment+SpecialFolder]::System);$powershell=[IO.Path]::GetFullPath((Join-Path $system 'WindowsPowerShell\v1.0\powershell.exe'));$expectedCommand='"{0}" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{1}" -Resume -TransactionId "{2}" -RuntimeRoot "{3}" -InstallRoot "{4}"'-f$powershell,$expectedScript,$TransactionId,$expectedRuntime,$InstallRoot}catch{Throw-CcodInstalledFinalizerError 'CCOD_INSTALLED_FINALIZER_INVALID' 'Durable installed uninstall paths are invalid' $Transaction}
    if($null-eq$Transaction-or$Transaction.transactionId-cne$TransactionId-or$Transaction.userSid-isnot[string]-or$Transaction.userSid-cne$CallerIdentity.userSid-or
       $effectivePhase-notin@('TaskRemoved','ReadyForInno','Completed')-or$null-eq$binding-or$binding.wrapperUserSid-cne$Transaction.userSid-or[int]$binding.wrapperSessionId-ne[int]$Transaction.sessionId-or
       [IO.Path]::GetFullPath([string]$binding.selectedRuntimeRoot)-cne$expectedRuntime-or$RuntimeRoot-cne$expectedRuntime-or[IO.Path]::GetFullPath([string]$binding.resumeScriptPath)-cne$expectedScript-or$binding.resumeCommand-cne$expectedCommand-or
       $binding.runtimeManifestSha256-isnot[string]-or$binding.runtimeManifestSha256-cnotmatch'^[0-9a-f]{64}$'-or$Transaction.readyEvidence.runtimeId-cne$Transaction.runtimeId-or
       [uint64]$Transaction.readyEvidence.runtimeGeneration-ne[uint64]$Transaction.runtimeGeneration-or$Transaction.readyEvidence.manifestSha256-cne$binding.runtimeManifestSha256-or
       $binding.resumeScriptSha256-isnot[string]-or$binding.resumeScriptSha256-cnotmatch'^[0-9a-f]{64}$'-or[uint64]$binding.resumeScriptLength-lt1-or$null-eq$binding.payloadRecords){Throw-CcodInstalledFinalizerError 'CCOD_INSTALLED_FINALIZER_INVALID' 'Durable installed uninstall transaction identity is invalid' $Transaction}
    $resumeRecords=@($binding.payloadRecords|Where-Object{$_.path-ceq'src/persistence/InstalledUninstallFinalizer.ps1'});if($resumeRecords.Count-ne1-or[uint64]$resumeRecords[0].length-ne[uint64]$binding.resumeScriptLength-or$resumeRecords[0].sha256-cne$binding.resumeScriptSha256){Throw-CcodInstalledFinalizerError 'CCOD_INSTALLED_FINALIZER_INVALID' 'Durable resume script is not bound to the staged payload set' $binding}
    if(-not$IsResume){
        if($null-eq$WrapperIdentity-or-not(Test-CcodInstalledFinalizerIdentity $WrapperIdentity)-or$effectivePhase-cne'TaskRemoved'){Throw-CcodInstalledFinalizerError 'CCOD_INSTALLED_FINALIZER_INVALID' 'Installed finalizer wrapper binding is invalid' $WrapperIdentity}
        if($IsWrapperResume){if([int]$binding.resumeWrapperPid-ne$WrapperIdentity.pid-or[string]$binding.resumeWrapperCreationTimeUtc-cne$WrapperIdentity.creationTimeUtc-or[int]$binding.resumeWrapperSessionId-ne$WrapperIdentity.sessionId-or[string]$binding.resumeWrapperUserSid-cne$WrapperIdentity.userSid){Throw-CcodInstalledFinalizerError 'CCOD_INSTALLED_FINALIZER_INVALID' 'Replacement wrapper launch binding is invalid' $WrapperIdentity}}
        elseif($null-ne$binding.resumeWrapperPid-or[int]$binding.wrapperPid-ne$WrapperIdentity.pid-or[string]$binding.wrapperCreationTimeUtc-cne$WrapperIdentity.creationTimeUtc-or[int]$binding.wrapperSessionId-ne$WrapperIdentity.sessionId-or[string]$binding.wrapperUserSid-cne$WrapperIdentity.userSid){Throw-CcodInstalledFinalizerError 'CCOD_INSTALLED_FINALIZER_INVALID' 'Initial historical wrapper binding is invalid or was superseded' $WrapperIdentity}
    }
    return $effectivePhase
}

function Invoke-CcodInstalledUninstallFinalizer {
    param([Parameter(Mandatory)][string]$TransactionId,[Parameter(Mandatory)][string]$RuntimeRoot,[Parameter(Mandatory)][string]$InstallRoot,[AllowNull()]$WrapperIdentity,[switch]$Resume,[switch]$WrapperResume,[hashtable]$Adapters)
    if(($Resume-and$WrapperResume)-or$TransactionId-cnotmatch'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'-or-not[IO.Path]::IsPathRooted($RuntimeRoot)-or-not[IO.Path]::IsPathRooted($InstallRoot)-or(-not$Resume-and-not(Test-CcodInstalledFinalizerIdentity $WrapperIdentity))){Throw-CcodInstalledFinalizerError 'CCOD_INSTALLED_FINALIZER_INVALID' 'Installed finalizer inputs are invalid' $TransactionId}
    $runtime=[IO.Path]::GetFullPath($RuntimeRoot);$install=[IO.Path]::GetFullPath($InstallRoot);$local=Get-CcodInstalledFinalizerLocalAppData;$transactionRoot=[IO.Path]::GetFullPath((Join-Path $local 'CodexRemote-fix-uninstall'));$payloadRoot=[IO.Path]::GetFullPath((Join-Path (Join-Path $transactionRoot $TransactionId) 'payload'))
    if($null-eq$Adapters){$expectedSelf=[IO.Path]::GetFullPath((Join-Path $payloadRoot 'src\persistence\InstalledUninstallFinalizer.ps1'));if([string]::IsNullOrWhiteSpace($PSCommandPath)-or[IO.Path]::GetFullPath($PSCommandPath)-cne$expectedSelf){Throw-CcodInstalledFinalizerError 'CCOD_INSTALLED_FINALIZER_INVALID' 'Installed finalizer is outside the durable staged payload' $PSCommandPath};[void](Read-CcodInstalledFinalizerEnvelope -TransactionRoot $transactionRoot -TransactionId $TransactionId -PayloadRoot $payloadRoot -RuntimeRoot $runtime -InstallRoot $install)}
    $adapter=Get-CcodInstalledFinalizerAdapters -Adapters $Adapters -TransactionRoot $transactionRoot -PayloadRoot $payloadRoot -RuntimeRoot $runtime -InstallRoot $install;$caller=&$adapter.GetCurrentIdentity
    if($null-eq$caller-or$caller.userSid-isnot[string]-or$caller.userSid-cnotmatch'^S-1-'){Throw-CcodInstalledFinalizerError 'CCOD_INSTALLED_FINALIZER_INVALID' 'Current resume caller identity is invalid' $caller}
    $accountLease=$null;$lock=$null
    try{
        $lock=&$adapter.EnterTransactionLock $caller.userSid
        if($null-eq$lock){Throw-CcodInstalledFinalizerError 'CCOD_INSTALLED_FINALIZER_INVALID' 'Installed finalizer transaction lock was not acquired' $caller.userSid}
        $accountLease=&$adapter.EnterAccountTransition $caller.userSid
        if($null-eq$accountLease){Throw-CcodInstalledFinalizerError 'CCOD_INSTALLED_FINALIZER_INVALID' 'Shared account transition authority was not acquired' $caller.userSid}
        $transaction=&$adapter.ReadPreparedTransaction $TransactionId $install
        $phase=Assert-CcodInstalledFinalizerTransactionBinding -Transaction $transaction -TransactionId $TransactionId -RuntimeRoot $runtime -InstallRoot $install -CallerIdentity $caller -WrapperIdentity $WrapperIdentity -IsResume ([bool]$Resume) -IsWrapperResume ([bool]$WrapperResume) -PayloadRoot $payloadRoot
        if(-not(&$adapter.ValidateStagedPayload $transaction $payloadRoot)){Throw-CcodInstalledFinalizerError 'CCOD_INSTALLED_FINALIZER_INVALID' 'Durable staged uninstall payload is invalid' $payloadRoot}
        if([uint64](&$adapter.ReadCurrentEpoch $install)-ne[uint64]$transaction.leaseEpoch){Throw-CcodInstalledFinalizerError 'CCOD_INSTALLED_FINALIZER_INVALID' 'Lifecycle epoch no longer matches the uninstall transaction' $install}

        if(-not$Resume){$wrapperExit=&$adapter.WaitWrapperExit $WrapperIdentity 15000;if($null-eq$wrapperExit-or$wrapperExit.verifiedAtStart-isnot[bool]-or-not$wrapperExit.verifiedAtStart-or$wrapperExit.exited-isnot[bool]-or-not$wrapperExit.exited){Throw-CcodInstalledFinalizerError 'CCOD_INSTALLED_FINALIZER_INVALID' 'Installed wrapper was not verified before its exact exit' $WrapperIdentity}}
        $resumeAnchorState=if($Resume){[string](&$adapter.GetResumeProductRegistrationState $transaction)}else{'Invalid'}

        if($phase-ceq'TaskRemoved'){
            $rootState=&$adapter.GetSelectedRootState $runtime
            if($rootState-ceq'Present'){
                if($Resume){$latestWrapper=if($null-ne$transaction.installedBinding.resumeWrapperPid){[pscustomobject]@{pid=[int]$transaction.installedBinding.resumeWrapperPid;creationTimeUtc=[string]$transaction.installedBinding.resumeWrapperCreationTimeUtc;sessionId=[int]$transaction.installedBinding.resumeWrapperSessionId;userSid=[string]$transaction.installedBinding.resumeWrapperUserSid}}else{[pscustomobject]@{pid=[int]$transaction.installedBinding.wrapperPid;creationTimeUtc=[string]$transaction.installedBinding.wrapperCreationTimeUtc;sessionId=[int]$transaction.installedBinding.wrapperSessionId;userSid=[string]$transaction.installedBinding.wrapperUserSid}};$resumeWrapperExit=&$adapter.WaitWrapperExit $latestWrapper 15000;if($null-eq$resumeWrapperExit-or-not$resumeWrapperExit.verifiedAtStart-or-not$resumeWrapperExit.exited){Throw-CcodInstalledFinalizerError 'CCOD_INSTALLED_FINALIZER_INVALID' 'Public resume could not prove the latest runtime wrapper exited' $latestWrapper}}
                if([uint64](&$adapter.ReadCurrentEpoch $install)-ne[uint64]$transaction.leaseEpoch){Throw-CcodInstalledFinalizerError 'CCOD_INSTALLED_FINALIZER_INVALID' 'Lifecycle epoch changed before generation reclamation' $install}
                if(-not(&$adapter.ValidateSelectedGeneration $runtime $install $transaction)){Throw-CcodInstalledFinalizerError 'CCOD_INSTALLED_FINALIZER_INVALID' 'Selected generation manifest does not match the transaction' $runtime}
                if($resumeAnchorState-cne'Exact'){&$adapter.InstallResumeProductRegistration $transaction;$resumeAnchorState=[string](&$adapter.GetResumeProductRegistrationState $transaction);if($resumeAnchorState-cne'Exact'){Throw-CcodInstalledFinalizerError 'CCOD_INSTALLED_FINALIZER_INVALID' 'Durable public resume entry was not committed before reclamation' $TransactionId}}
                &$adapter.ReclaimSelectedGeneration $runtime $transaction|Out-Null
                if((&$adapter.GetSelectedRootState $runtime)-cne'Absent'){Throw-CcodInstalledFinalizerError 'CCOD_INSTALLED_FINALIZER_INVALID' 'Selected generation removal was not proven' $runtime}
            }elseif($rootState-cne'Absent'-or-not$Resume-or$resumeAnchorState-cne'Exact'){Throw-CcodInstalledFinalizerError 'CCOD_INSTALLED_FINALIZER_INVALID' 'Selected generation state is not resumable' $runtime}
            if($resumeAnchorState-cne'Exact'-or[string](&$adapter.GetResumeProductRegistrationState $transaction)-cne'Exact'){Throw-CcodInstalledFinalizerError 'CCOD_INSTALLED_FINALIZER_INVALID' 'Generation absence lacks its write-ahead resume authority' $TransactionId}
            $transaction=&$adapter.WriteReadyForInno $transaction
            if($null-eq$transaction-or$transaction.phase-cne'ReadyForInno'){Throw-CcodInstalledFinalizerError 'CCOD_INSTALLED_FINALIZER_INVALID' 'ReadyForInno phase was not durable' $TransactionId}
            $phase='ReadyForInno'
        }
        if($phase-ceq'ReadyForInno'){
            if([string](&$adapter.GetResumeProductRegistrationState $transaction)-cne'Exact'){Throw-CcodInstalledFinalizerError 'CCOD_INSTALLED_FINALIZER_INVALID' 'Product tail lacks its durable public resume entry' $TransactionId}
            &$adapter.RemoveMatchedProductShortcuts $transaction
            if([string](&$adapter.GetResumeProductRegistrationState $transaction)-cne'Exact'){Throw-CcodInstalledFinalizerError 'CCOD_INSTALLED_FINALIZER_INVALID' 'Public resume entry disappeared before completion receipt' $TransactionId}
            [void](&$adapter.FinalizeReceipt $transaction)
            $transaction=&$adapter.ReadPreparedTransaction $TransactionId $install
            $phase=Assert-CcodInstalledFinalizerTransactionBinding -Transaction $transaction -TransactionId $TransactionId -RuntimeRoot $runtime -InstallRoot $install -CallerIdentity $caller -WrapperIdentity $WrapperIdentity -IsResume $true -IsWrapperResume $false -PayloadRoot $payloadRoot
        }
        if($phase-cne'Completed'){Throw-CcodInstalledFinalizerError 'CCOD_INSTALLED_FINALIZER_INVALID' 'Installed uninstall tail did not reach Completed' $TransactionId}
        if(-not(&$adapter.TestCompletedReceipt $transaction)){[void](&$adapter.FinalizeReceipt $transaction);$transaction=&$adapter.ReadPreparedTransaction $TransactionId $install;if(-not(&$adapter.TestCompletedReceipt $transaction)){Throw-CcodInstalledFinalizerError 'CCOD_INSTALLED_FINALIZER_INVALID' 'Completed receipt is not durable' $TransactionId}}
        $completedAnchor=[string](&$adapter.GetResumeProductRegistrationState $transaction);if($completedAnchor-ceq'Exact'){[void](&$adapter.RemoveResumeProductRegistration $transaction)}elseif($completedAnchor-cne'Absent'){Throw-CcodInstalledFinalizerError 'CCOD_INSTALLED_FINALIZER_INVALID' 'Completed uninstall has an invalid final public anchor' $TransactionId}
        return $transaction
    }finally{if($null-ne$accountLease){&$adapter.ExitAccountTransition $accountLease};if($null-ne$lock){&$adapter.ExitTransactionLock $lock}}
}

if($MyInvocation.InvocationName-ne'.'){
    $identity=$null
    if(-not$Resume){$currentIdentity=[Security.Principal.WindowsIdentity]::GetCurrent();$process=[Diagnostics.Process]::GetCurrentProcess();try{$identity=[pscustomobject]@{pid=[int]$WrapperProcessId;creationTimeUtc=$WrapperCreationTimeUtc;sessionId=[int]$process.SessionId;userSid=[string]$currentIdentity.User.Value}}finally{$process.Dispose();$currentIdentity.Dispose()}}
    try{Invoke-CcodInstalledUninstallFinalizer -TransactionId $TransactionId -RuntimeRoot $RuntimeRoot -InstallRoot $InstallRoot -WrapperIdentity $identity -Resume:$Resume -WrapperResume:$WrapperResume|Out-Null;exit 0}catch{[Console]::Error.WriteLine([string]$_.FullyQualifiedErrorId);exit 3}
}
