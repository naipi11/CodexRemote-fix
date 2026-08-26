[CmdletBinding()]
param([string]$RequestPath,[string]$ResultPath)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$VerbosePreference='SilentlyContinue'
$InformationPreference='SilentlyContinue'

# Import and bind the worker dependency closure before defining adapter
# scriptblocks. A scriptblock created in this script must call the exact
# manifest-bound module export; relying on an unqualified command later in the
# script can leave the worker without PersistenceIO/RuntimeManifest commands
# when it is launched as a separate -File process.
$script:CcodLifecycleWorkerModuleRoot=Join-Path $PSScriptRoot 'modules'
$script:CcodLifecycleWorkerModuleBindings=@{}
foreach($specification in @(
    [pscustomobject]@{Name='PersistenceIO';File='PersistenceIO.psm1';Exports=@('Read-CcodStrictJson','Write-CcodAtomicJson')},
    [pscustomobject]@{Name='RuntimeManifest';File='RuntimeManifest.psm1';Exports=@('Resolve-CcodActiveRuntimeContext')},
    [pscustomobject]@{Name='LifecycleEpoch';File='LifecycleEpoch.psm1';Exports=@('Enter-CcodLifecycleDelegation','Exit-CcodLifecycleDelegation','Assert-CcodLifecycleFence')},
    [pscustomobject]@{Name='ProcessControl';File='ProcessControl.psm1';Exports=@('Request-CcodOrdinaryPackagedLaunch','Wait-CcodVerifiedOrdinaryRoot')},
    [pscustomobject]@{Name='WorkerRuntime';File='WorkerRuntime.psm1';Exports=@()}
)){
    $modulePath=[IO.Path]::GetFullPath((Join-Path $script:CcodLifecycleWorkerModuleRoot $specification.File))
    $loaded=@(Import-Module -Name $modulePath -PassThru -Force -Scope Local -ErrorAction Stop -WarningAction SilentlyContinue)
    if($loaded.Count -ne 1 -or [IO.Path]::GetFullPath($loaded[0].Path) -cne $modulePath){throw 'The lifecycle worker dependency module path is not manifest-bound.'}
    $exports=[ordered]@{}
    foreach($functionName in @($specification.Exports)){
        $command=$loaded[0].ExportedFunctions[[string]$functionName]
        if($null -eq $command -or $command -isnot [Management.Automation.FunctionInfo] -or $command.ScriptBlock -isnot [scriptblock] -or
           $null -eq $command.Module -or [IO.Path]::GetFullPath($command.Module.Path) -cne $modulePath){throw 'The lifecycle worker dependency export is not manifest-bound.'}
        $exports[[string]$functionName]=$command.ScriptBlock
    }
    $script:CcodLifecycleWorkerModuleBindings[[string]$specification.Name]=$exports
}

function Invoke-CcodLifecycleWorkerModuleFunction {
    param([Parameter(Mandatory)][string]$Module,[Parameter(Mandatory)][string]$Function,[object[]]$Arguments)
    $binding=$script:CcodLifecycleWorkerModuleBindings[$Module]
    if($null -eq $binding -or -not $binding.Contains($Function) -or $binding[$Function] -isnot [scriptblock]){throw 'The lifecycle worker dependency export is unavailable.'}
    & $binding[$Function] @Arguments
}

$script:CcodLifecycleWorkerScriptPath=if([string]::IsNullOrWhiteSpace($PSCommandPath)){$null}else{[IO.Path]::GetFullPath($PSCommandPath)}
$script:CcodLifecycleWorkerRequestFields=@('schemaVersion','transactionId','action','runtimeId','runtimeGeneration','leaseEpoch','ownerIdentity','notBeforeUtc','timeoutMilliseconds')
$script:CcodLifecycleWorkerResultFields=@('schemaVersion','transactionId','action','ok','outcome','observation','error')
$script:CcodLifecycleWorkerActions=@('Inspect','Close','RequestOrdinaryLaunch','ObserveOrdinary','Apply','VerifyRemote')
$script:CcodLifecycleWorkerErrorFields=@('code','stage','message')
$script:CcodLifecycleWorkerRequiredFiles=@(
    'src/check-package.mjs','src/runtime/orchestrator.js','src/runtime/main-payload.js',
    'src/persistence/LifecycleWorker.ps1','src/persistence/SessionController.ps1',
    'src/persistence/modules/CompatibilityProbe.psm1','src/persistence/modules/PersistenceIO.psm1','src/persistence/modules/StateStore.psm1',
    'src/persistence/modules/ProcessControl.psm1','src/persistence/modules/RendererIntegration.psm1','src/persistence/modules/TransitionJournal.psm1',
    'src/persistence/modules/SessionEngine.psm1','src/persistence/modules/RuntimeManifest.psm1','src/persistence/modules/LifecycleEpoch.psm1',
    'src/persistence/modules/KernelObjects.psm1','src/persistence/modules/WorkerRuntime.psm1'
)

function Throw-CcodLifecycleWorkerError {
    param([string]$Id,[string]$Message,$Target)
    throw [Management.Automation.ErrorRecord]::new([InvalidOperationException]::new($Message),$Id,[Management.Automation.ErrorCategory]::InvalidData,$Target)
}

function Get-CcodLifecycleWorkerErrorId {
    param($Failure)
    if($null -eq $Failure -or $Failure.FullyQualifiedErrorId -isnot [string]){return $null}
    return ([string]$Failure.FullyQualifiedErrorId -split ',')[0]
}

function Test-CcodLifecycleWorkerExactObject {
    param($Value,[string[]]$Fields)
    return $null -ne $Value -and $Value -is [pscustomobject] -and (@($Value.PSObject.Properties.Name)-join "`0") -ceq ($Fields-join "`0") -and
        @($Value.PSObject.Properties|Where-Object{$_.MemberType -ne [Management.Automation.PSMemberTypes]::NoteProperty}).Count -eq 0
}

function Test-CcodLifecycleWorkerCanonicalUtc {
    param($Value)
    $parsed=[DateTime]::MinValue
    return $Value -is [string] -and [DateTime]::TryParseExact($Value,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$parsed) -and
        $parsed.Kind -eq [DateTimeKind]::Utc -and $parsed.ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture) -ceq $Value
}

function Test-CcodLifecycleWorkerCanonicalGuid {
    param($Value)
    $parsed=[guid]::Empty
    return $Value -is [string] -and [guid]::TryParseExact($Value,'D',[ref]$parsed) -and $parsed.ToString('D') -ceq $Value
}

function ConvertTo-CcodLifecycleWorkerUInt64 {
    param($Value,[string]$Name)
    if($Value -is [decimal]){if($Value -lt 1 -or [decimal]::Truncate($Value) -ne $Value){Throw-CcodLifecycleWorkerError 'CCOD_LIFECYCLE_WORKER_REQUEST_INVALID' "$Name is invalid" $Value};try{return [UInt64]$Value}catch{}}
    elseif($Value -is [byte] -or $Value -is [uint16] -or $Value -is [uint32] -or $Value -is [uint64] -or $Value -is [int16] -or $Value -is [int32] -or $Value -is [int64]){if($Value -gt 0){return [UInt64]$Value}}
    Throw-CcodLifecycleWorkerError 'CCOD_LIFECYCLE_WORKER_REQUEST_INVALID' "$Name is invalid" $Value
}

function Assert-CcodLifecycleWorkerRequest {
    param($Request)
    if(-not(Test-CcodLifecycleWorkerExactObject $Request $script:CcodLifecycleWorkerRequestFields) -or $Request.schemaVersion -isnot [int] -or $Request.schemaVersion -ne 1 -or
        -not(Test-CcodLifecycleWorkerCanonicalGuid $Request.transactionId) -or $Request.action -isnot [string] -or $script:CcodLifecycleWorkerActions -cnotcontains $Request.action -or
        $Request.runtimeId -isnot [string] -or $Request.runtimeId -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$' -or
        -not(Test-CcodLifecycleWorkerExactObject $Request.ownerIdentity @('pid','creationTimeUtc')) -or
        ($Request.ownerIdentity.pid -isnot [int] -and $Request.ownerIdentity.pid -isnot [long]) -or $Request.ownerIdentity.pid -lt 1 -or $Request.ownerIdentity.pid -gt [int]::MaxValue -or
        -not(Test-CcodLifecycleWorkerCanonicalUtc $Request.ownerIdentity.creationTimeUtc) -or -not(Test-CcodLifecycleWorkerCanonicalUtc $Request.notBeforeUtc) -or
        $Request.timeoutMilliseconds -isnot [int] -or $Request.timeoutMilliseconds -lt 1 -or $Request.timeoutMilliseconds -gt 600000){
        Throw-CcodLifecycleWorkerError 'CCOD_LIFECYCLE_WORKER_REQUEST_INVALID' 'Lifecycle worker request is invalid' $Request
    }
    $Request.runtimeGeneration=ConvertTo-CcodLifecycleWorkerUInt64 $Request.runtimeGeneration 'runtimeGeneration'
    $Request.leaseEpoch=ConvertTo-CcodLifecycleWorkerUInt64 $Request.leaseEpoch 'leaseEpoch'
    return $Request
}

function New-CcodLifecycleWorkerErrorResult {
    param($Request,[string]$Code,[string]$Stage)
    $correlated=$false
    try{if($null -ne $Request){Assert-CcodLifecycleWorkerRequest $Request|Out-Null;$correlated=$true}}catch{$correlated=$false}
    [pscustomobject][ordered]@{
        schemaVersion=1;transactionId=$(if($correlated){$Request.transactionId}else{$null});action=$(if($correlated){$Request.action}else{$null})
        ok=$false;outcome='Error';observation='Error';error=[pscustomobject][ordered]@{code=$Code;stage=$Stage;message='The lifecycle worker failed safely.'}
    }
}

function Assert-CcodLifecycleWorkerPublicResult {
    param($Result,$Request)
    if(-not(Test-CcodLifecycleWorkerExactObject $Result $script:CcodLifecycleWorkerResultFields) -or $Result.schemaVersion -isnot [int] -or $Result.schemaVersion -ne 1 -or
        $Result.transactionId -isnot [string] -or $Result.transactionId -cne $Request.transactionId -or $Result.action -isnot [string] -or $Result.action -cne $Request.action -or
        $Result.ok -isnot [bool] -or $Result.outcome -isnot [string] -or $Result.observation -isnot [string]){
        Throw-CcodLifecycleWorkerError 'CCOD_LIFECYCLE_WORKER_RESULT_INVALID' 'Lifecycle worker result is invalid or uncorrelated' $Result
    }
    if($Result.ok){if($null -ne $Result.error){Throw-CcodLifecycleWorkerError 'CCOD_LIFECYCLE_WORKER_RESULT_INVALID' 'Successful lifecycle result contains an error' $Result}}
    elseif(-not(Test-CcodLifecycleWorkerExactObject $Result.error $script:CcodLifecycleWorkerErrorFields) -or $Result.error.code -isnot [string] -or $Result.error.code -cnotmatch '^CCOD_[A-Z0-9_]+$'){
        Throw-CcodLifecycleWorkerError 'CCOD_LIFECYCLE_WORKER_RESULT_INVALID' 'Failed lifecycle result has no stable error' $Result
    }
    return $Result
}

function Get-CcodLifecycleWorkerBootstrapContext {
    param([string]$ScriptPath)
    try{
        if([string]::IsNullOrWhiteSpace($ScriptPath) -or -not[IO.Path]::IsPathRooted($ScriptPath) -or [IO.Path]::GetFullPath($ScriptPath) -cne $ScriptPath -or [IO.Path]::GetFileName($ScriptPath) -cne 'LifecycleWorker.ps1'){throw 'self'}
        $persistence=Split-Path $ScriptPath -Parent;$src=Split-Path $persistence -Parent;$runtime=Split-Path $src -Parent;$container=Split-Path $runtime -Parent;$install=Split-Path $container -Parent
        if((Split-Path $persistence -Leaf) -cne 'persistence' -or (Split-Path $src -Leaf) -cne 'src' -or (Split-Path $container -Leaf) -cne 'runtime'){throw 'layout'}
        $install=[IO.Path]::GetFullPath($install)
        return [pscustomobject][ordered]@{InstallRoot=$install;WorkersRoot=[IO.Path]::GetFullPath((Join-Path $install 'state\workers'))}
    }catch{Throw-CcodLifecycleWorkerError 'CCOD_LIFECYCLE_WORKER_RUNTIME_UNAUTHORIZED' 'Lifecycle worker is not in an installed runtime layout' $ScriptPath}
}

function Get-CcodLifecycleWorkerPathAdapters {
    param([hashtable]$Adapters)
    $resolved=@{
        GetItem={param($Path,$AllowMissing)try{Get-Item -LiteralPath $Path -Force -ErrorAction Stop}catch [Management.Automation.ItemNotFoundException]{if($AllowMissing){return $null};throw}}
        FileExists={param($Path)[IO.File]::Exists($Path)};DirectoryExists={param($Path)[IO.Directory]::Exists($Path)}
    }
    if($null -ne $Adapters){foreach($name in @('GetItem','FileExists','DirectoryExists')){if($Adapters.ContainsKey($name)){$resolved[$name]=$Adapters[$name]}}}
    return $resolved
}

function Assert-CcodLifecycleWorkerNoReparse {
    param([string]$Root,[string]$Path,[switch]$AllowMissingLeaf,[hashtable]$Adapters)
    $adapter=Get-CcodLifecycleWorkerPathAdapters $Adapters;$root=[IO.Path]::GetFullPath($Root).TrimEnd('\');$full=[IO.Path]::GetFullPath($Path)
    if($full -cne $root -and -not $full.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)){Throw-CcodLifecycleWorkerError 'CCOD_LIFECYCLE_WORKER_PATH_INVALID' 'Worker path is outside its authorized root' $Path}
    $cursor=$root;$segments=if($full.Length -gt $root.Length){@($full.Substring($root.Length).TrimStart('\')-split '\\')}else{@()}
    foreach($segment in @('')+$segments){
        if($segment -ne ''){$cursor=Join-Path $cursor $segment};$missing=[bool]($AllowMissingLeaf -and $cursor -ceq $full)
        try{$item=& $adapter.GetItem $cursor $missing}catch{Throw-CcodLifecycleWorkerError 'CCOD_LIFECYCLE_WORKER_PATH_INVALID' 'Worker path is missing or unreadable' $Path}
        if($null -eq $item){if($missing){return};Throw-CcodLifecycleWorkerError 'CCOD_LIFECYCLE_WORKER_PATH_INVALID' 'Worker path is missing' $Path}
        if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint)-ne 0){Throw-CcodLifecycleWorkerError 'CCOD_LIFECYCLE_WORKER_PATH_INVALID' 'Worker path crosses a reparse point' $Path}
        if($missing){Throw-CcodLifecycleWorkerError 'CCOD_LIFECYCLE_WORKER_PATH_INVALID' 'Worker result path already exists' $Path}
    }
}

function Assert-CcodLifecycleWorkerPaths {
    param($Bootstrap,[string]$RequestPath,[string]$ResultPath,$Request,[hashtable]$Adapters)
    $workers=[IO.Path]::GetFullPath($Bootstrap.WorkersRoot)
    foreach($path in @($RequestPath,$ResultPath)){
        $full=$null;try{$full=[IO.Path]::GetFullPath($path)}catch{}
        if($null -eq $full -or -not[IO.Path]::IsPathRooted($path) -or $full -cne $path -or (Split-Path $full -Parent)-cne $workers){Throw-CcodLifecycleWorkerError 'CCOD_LIFECYCLE_WORKER_PATH_INVALID' 'Worker paths must be canonical direct children' $path}
    }
    $adapter=Get-CcodLifecycleWorkerPathAdapters $Adapters
    if($RequestPath -ceq $ResultPath -or -not(& $adapter.DirectoryExists $workers) -or -not(& $adapter.FileExists $RequestPath) -or (& $adapter.FileExists $ResultPath)){
        Throw-CcodLifecycleWorkerError 'CCOD_LIFECYCLE_WORKER_PATH_INVALID' 'Worker framing path state is invalid' $null
    }
    Assert-CcodLifecycleWorkerNoReparse $Bootstrap.InstallRoot $workers -Adapters $Adapters
    Assert-CcodLifecycleWorkerNoReparse $Bootstrap.InstallRoot $RequestPath -Adapters $Adapters
    Assert-CcodLifecycleWorkerNoReparse $Bootstrap.InstallRoot $ResultPath -AllowMissingLeaf -Adapters $Adapters
    if($null -ne $Request){
        $prefix='lifecycle-'+$Request.transactionId
        if([IO.Path]::GetFileName($RequestPath)-cne ($prefix+'.request.json') -or [IO.Path]::GetFileName($ResultPath)-cne ($prefix+'.result.json')){Throw-CcodLifecycleWorkerError 'CCOD_LIFECYCLE_WORKER_PATH_INVALID' 'Worker framing leaves are not correlated' $Request}
    }
}

function Get-CcodLifecycleWorkerCurrentIdentity {
    $windows=$null;$process=$null
    try{$windows=[Security.Principal.WindowsIdentity]::GetCurrent();$process=[Diagnostics.Process]::GetCurrentProcess();[pscustomobject][ordered]@{UserSid=$windows.User.Value;SessionId=[int]$process.SessionId}}
    finally{if($null-ne$process){$process.Dispose()};if($null-ne$windows){$windows.Dispose()}}
}

function Assert-CcodLifecycleWorkerRuntimeClosure {
    param($Context)
    if($null-eq$Context -or $null-eq$Context.Manifest -or $null-eq$Context.Manifest.PSObject.Properties['files']){Throw-CcodLifecycleWorkerError 'CCOD_LIFECYCLE_WORKER_RUNTIME_UNAUTHORIZED' 'Lifecycle worker runtime manifest is unavailable' $Context}
    $records=@($Context.Manifest.files)
    foreach($relative in $script:CcodLifecycleWorkerRequiredFiles){
        if(@($records|Where-Object{$null-ne$_.PSObject.Properties['path'] -and $_.path -is[string] -and $_.path -ceq $relative}).Count -ne 1){Throw-CcodLifecycleWorkerError 'CCOD_LIFECYCLE_WORKER_RUNTIME_UNAUTHORIZED' 'Lifecycle worker runtime closure is incomplete' $relative}
    }
    return $Context
}

function Assert-CcodLifecycleWorkerFence {
    param($Context,$Request,$Delegation)
    $ownership=if($null-ne$Delegation){$Delegation}else{[pscustomobject][ordered]@{schemaVersion=1;lease=[pscustomobject][ordered]@{Released=$false};epoch=[UInt64]$Request.leaseEpoch;runtimeId=$Request.runtimeId;runtimeGeneration=[UInt64]$Request.runtimeGeneration;ownerIdentity=$Request.ownerIdentity;released=$false}}
    Invoke-CcodLifecycleWorkerModuleFunction -Module 'LifecycleEpoch' -Function 'Assert-CcodLifecycleFence' -Arguments @($Context.InstallRoot,$ownership)|Out-Null
}

function Invoke-CcodLifecycleControllerFacade {
    param([string]$Action,$Request,$Context,$Delegation)
    $controllerPath=[IO.Path]::GetFullPath((Join-Path $Context.RuntimeRoot 'src\persistence\SessionController.ps1'))
    $identity=Get-CcodLifecycleWorkerCurrentIdentity
    $controllerAction=if($Action -ceq 'VerifyRemote'){'Inspect'}else{$Action}
    $controllerRequest=[pscustomobject][ordered]@{
        schemaVersion=2;action=$controllerAction;transactionId=$Request.transactionId;runtimeId=$Request.runtimeId;runtimeGeneration=[UInt64]$Request.runtimeGeneration;leaseEpoch=[UInt64]$Request.leaseEpoch
        ownerIdentity=$Request.ownerIdentity;supervisorIdentity=[pscustomobject][ordered]@{pid=[int]$Request.ownerIdentity.pid;creationTimeUtc=$Request.ownerIdentity.creationTimeUtc;sessionId=$identity.SessionId.ToString([Globalization.CultureInfo]::InvariantCulture)}
        source=$null;existingOnly=[bool]($controllerAction -cne 'Apply');rendererPort=$null;mainPort=$null;timeoutMilliseconds=[Math]::Max(500,[Math]::Min(120000,$Request.timeoutMilliseconds));restartOrdinary=[bool]($controllerAction -cne 'Close')
    }
    $paths=[pscustomobject][ordered]@{StateRoot=[IO.Path]::GetFullPath((Join-Path $Context.InstallRoot 'state'));TransitionPath=[IO.Path]::GetFullPath((Join-Path $Context.InstallRoot 'state\transition.json'));TransitionLogPath=[IO.Path]::GetFullPath((Join-Path $Context.InstallRoot 'logs\transactions.log'));SessionLogPath=[IO.Path]::GetFullPath((Join-Path $Context.InstallRoot 'logs\session.log'));CheckerPath=[IO.Path]::GetFullPath((Join-Path $Context.RuntimeRoot 'src\check-package.mjs'));OrchestratorPath=[IO.Path]::GetFullPath((Join-Path $Context.RuntimeRoot 'src\runtime\orchestrator.js'));MainPayloadPath=[IO.Path]::GetFullPath((Join-Path $Context.RuntimeRoot 'src\runtime\main-payload.js'))}
    $run=& {
        param($Path,$Value,$ControllerPaths,$Delegated)
        $bound=$Delegated
        $getDelegatedOwnership={$bound}.GetNewClosure()
        . $Path
        $noWrite={param($P,$V)};$noLine={param($Line)}
        Invoke-CcodSessionController -Request $Value -Paths $ControllerPaths -ResultPath ([IO.Path]::GetFullPath((Join-Path $ControllerPaths.StateRoot 'workers\controller-unused.result.json'))) -Adapters @{WriteResult=$noWrite;WriteStdout=$noLine;WriteStderr=$noLine;GetDelegatedOwnership=$getDelegatedOwnership}
    } $controllerPath $controllerRequest $paths $Delegation
    return $run.Result
}

function ConvertFrom-CcodLifecycleControllerResult {
    param([string]$WorkerAction,$Controller,$Request)
    $expectedAction=if($WorkerAction -ceq 'VerifyRemote'){'Inspect'}else{$WorkerAction}
    $fields=@('schemaVersion','action','ok','outcome','safeState','stage','transactionId','package','source','special','probes','recovery','error','logFile')
    if(-not(Test-CcodLifecycleWorkerExactObject $Controller $fields) -or $Controller.schemaVersion -ne 1 -or $Controller.action -cne $expectedAction -or $Controller.transactionId -cne $Request.transactionId -or $Controller.ok -isnot [bool]){Throw-CcodLifecycleWorkerError 'CCOD_LIFECYCLE_WORKER_RESULT_INVALID' 'Controller result is invalid or uncorrelated' $Controller}
    if(-not $Controller.ok){$code=if($null-ne$Controller.error-and$Controller.error.code-is[string]-and$Controller.error.code-cmatch'^CCOD_[A-Z0-9_]+$'){$Controller.error.code}else{'CCOD_LIFECYCLE_OPERATION_FAILED'};return New-CcodLifecycleWorkerErrorResult $Request $code 'Operation'}
    $observation=switch($Controller.safeState){'SpecialValidated'{$(if($WorkerAction -ceq 'VerifyRemote' -or $WorkerAction -ceq 'Inspect'){'RemoteVerified'}else{'Special'})};'RendererRepairRequired'{'Special'};'OrdinaryRunning'{'Ordinary'};'NoCodex'{'NoCodex'};'Closed'{'NoCodex'};default{'Error'}}
    if($observation -ceq 'Error'){Throw-CcodLifecycleWorkerError 'CCOD_LIFECYCLE_WORKER_RESULT_INVALID' 'Controller safe state is unsupported' $Controller}
    return [pscustomobject][ordered]@{schemaVersion=1;transactionId=$Request.transactionId;action=$WorkerAction;ok=$true;outcome=$Controller.outcome;observation=$observation;error=$null}
}

function Get-CcodLifecycleWorkerAdapters {
    param([hashtable]$Adapters)
    $resolved=@{
        GetScriptPath={$script:CcodLifecycleWorkerScriptPath}
        GetBootstrapContext={param($Path)Get-CcodLifecycleWorkerBootstrapContext $Path}
        ReadRequest={param($Path)Invoke-CcodLifecycleWorkerModuleFunction -Module 'PersistenceIO' -Function 'Read-CcodStrictJson' -Arguments @($Path,1,'lifecycle worker request')}
        ResolveRuntime={param($Path,$Runtime,$Generation)$bootstrap=Get-CcodLifecycleWorkerBootstrapContext $Path;Invoke-CcodLifecycleWorkerModuleFunction -Module 'RuntimeManifest' -Function 'Resolve-CcodActiveRuntimeContext' -Arguments @($bootstrap.InstallRoot,$Runtime,$Generation,$Path,'src/persistence/LifecycleWorker.ps1')}
        EnterDelegation={param($Context,$Request)$identity=Get-CcodLifecycleWorkerCurrentIdentity;Invoke-CcodLifecycleWorkerModuleFunction -Module 'LifecycleEpoch' -Function 'Enter-CcodLifecycleDelegation' -Arguments @($Context.InstallRoot,$Request.runtimeId,$Request.runtimeGeneration,$Request.leaseEpoch,$Request.ownerIdentity,$identity.UserSid,$identity.SessionId,[Math]::Min(15000,$Request.timeoutMilliseconds))}
        ExitDelegation={param($Delegation)Invoke-CcodLifecycleWorkerModuleFunction -Module 'LifecycleEpoch' -Function 'Exit-CcodLifecycleDelegation' -Arguments @($Delegation)}
        AssertFence={param($Context,$Request,$Delegation)Assert-CcodLifecycleWorkerFence $Context $Request $Delegation}
        GetCurrentIdentity={Get-CcodLifecycleWorkerCurrentIdentity}
        InvokeController={param($Action,$Request,$Context,$Delegation)Invoke-CcodLifecycleControllerFacade $Action $Request $Context $Delegation}
        RequestOrdinaryLaunch={param($Request,$Context,$Delegation)$ownership=[pscustomobject][ordered]@{runtimeGeneration=[UInt64]$Request.runtimeGeneration;leaseEpoch=[UInt64]$Request.leaseEpoch;ownerIdentity=$Request.ownerIdentity};$boundContext=$Context;$boundRequest=$Request;$boundDelegation=$Delegation;Invoke-CcodLifecycleWorkerModuleFunction -Module 'ProcessControl' -Function 'Request-CcodOrdinaryPackagedLaunch' -Arguments @($Request.notBeforeUtc,$ownership,{param($Generation,$Epoch,$Owner)Assert-CcodLifecycleWorkerFence $boundContext $boundRequest $boundDelegation}.GetNewClosure())}
        ObserveOrdinary={param($Request,$Context)$identity=Get-CcodLifecycleWorkerCurrentIdentity;$status=[pscustomobject][ordered]@{schemaVersion=1;session=$null};Invoke-CcodLifecycleWorkerModuleFunction -Module 'ProcessControl' -Function 'Wait-CcodVerifiedOrdinaryRoot' -Arguments @($Request.notBeforeUtc,$identity.UserSid,$identity.SessionId,$status,[Math]::Min(45000,$Request.timeoutMilliseconds))}
        WriteResult={param($Path,$Value)Invoke-CcodLifecycleWorkerModuleFunction -Module 'PersistenceIO' -Function 'Write-CcodAtomicJson' -Arguments @($Path,$Value)}
        WriteStdout={param($Line)[Console]::Out.WriteLine($Line)};WriteStderr={param($Line)[Console]::Error.WriteLine($Line)}
    }
    if($null-ne$Adapters){foreach($key in $Adapters.Keys){$resolved[$key]=$Adapters[$key]}}
    return $resolved
}

function Get-CcodLifecycleWorkerFailureCode {
    param($Failure,[string]$Stage)
    $id=Get-CcodLifecycleWorkerErrorId $Failure
    if($id -ceq 'CCOD_LIFECYCLE_FENCE_STALE'){return $id}
    if($id -in @('CCOD_LIFECYCLE_WORKER_PATH_INVALID','CCOD_LIFECYCLE_WORKER_REQUEST_INVALID','CCOD_LIFECYCLE_WORKER_RUNTIME_UNAUTHORIZED','CCOD_LIFECYCLE_WORKER_RESULT_INVALID')){return $id}
    switch($Stage){'PathValidation'{'CCOD_LIFECYCLE_WORKER_PATH_INVALID'};'RequestValidation'{'CCOD_LIFECYCLE_WORKER_REQUEST_INVALID'};'RuntimeAuthorization'{'CCOD_LIFECYCLE_WORKER_RUNTIME_UNAUTHORIZED'};'ResultValidation'{'CCOD_LIFECYCLE_WORKER_RESULT_INVALID'};default{'CCOD_LIFECYCLE_OPERATION_FAILED'}}
}

function Invoke-CcodLifecycleWorker {
    [CmdletBinding()]
    param([string]$RequestPath,[string]$ResultPath,[hashtable]$Adapters)
    $adapter=Get-CcodLifecycleWorkerAdapters $Adapters;$request=$null;$requestValid=$false;$bootstrap=$null;$context=$null;$delegation=$null;$canPublish=$false;$result=$null;$stage='RuntimeAuthorization';$stale=$false
    try{
        $scriptPath=& $adapter.GetScriptPath;$bootstrap=& $adapter.GetBootstrapContext $scriptPath
        $stage='PathValidation';Assert-CcodLifecycleWorkerPaths $bootstrap $RequestPath $ResultPath $null $Adapters
        $stage='RequestValidation';$request=& $adapter.ReadRequest $RequestPath;Assert-CcodLifecycleWorkerRequest $request|Out-Null;$requestValid=$true
        $stage='PathValidation';Assert-CcodLifecycleWorkerPaths $bootstrap $RequestPath $ResultPath $request $Adapters
        $stage='RuntimeAuthorization';$context=& $adapter.ResolveRuntime $scriptPath $request.runtimeId $request.runtimeGeneration
        if($null-eq$context -or $context.RuntimeId -cne $request.runtimeId -or [UInt64]$context.RuntimeGeneration -ne [UInt64]$request.runtimeGeneration){Throw-CcodLifecycleWorkerError 'CCOD_LIFECYCLE_WORKER_RUNTIME_UNAUTHORIZED' 'Lifecycle request does not match active runtime generation' $request}
        Assert-CcodLifecycleWorkerRuntimeClosure $context|Out-Null
        $stage='Fence';$delegation=&$adapter.EnterDelegation $context $request;[void](& $adapter.AssertFence $context $request $delegation);$canPublish=$true
        $stage='Operation'
        switch($request.action){
            'RequestOrdinaryLaunch'{$receipt=& $adapter.RequestOrdinaryLaunch $request $context $delegation;if(-not(Test-CcodLifecycleWorkerExactObject $receipt @('outcome','requestedAtUtc','launcherPid'))-or$receipt.outcome-cne'LaunchRequested'-or$receipt.requestedAtUtc-cne$request.notBeforeUtc){Throw-CcodLifecycleWorkerError 'CCOD_LIFECYCLE_WORKER_RESULT_INVALID' 'Launch receipt is invalid' $receipt};$result=[pscustomobject][ordered]@{schemaVersion=1;transactionId=$request.transactionId;action=$request.action;ok=$true;outcome='LaunchRequested';observation='NoCodex';error=$null}}
            'ObserveOrdinary'{$ordinary=& $adapter.ObserveOrdinary $request $context;$found=$null-ne$ordinary;$result=[pscustomobject][ordered]@{schemaVersion=1;transactionId=$request.transactionId;action=$request.action;ok=$true;outcome=$(if($found){'OrdinaryObserved'}else{'ObservationTimedOut'});observation=$(if($found){'Ordinary'}else{'ObservationTimedOut'});error=$null}}
            default{$controller=& $adapter.InvokeController $request.action $request $context $delegation;$result=ConvertFrom-CcodLifecycleControllerResult $request.action $controller $request}
        }
        $stage='ResultValidation';Assert-CcodLifecycleWorkerPublicResult $result $request|Out-Null
    }catch{
        $code=Get-CcodLifecycleWorkerFailureCode $_ $stage;if($code -ceq 'CCOD_LIFECYCLE_FENCE_STALE'){$stale=$true}
        $result=New-CcodLifecycleWorkerErrorResult $(if($requestValid){$request}else{$null}) $code $stage
    }
    if(-not$canPublish -or $stale){
        if($null-ne$delegation){try{[void](&$adapter.ExitDelegation $delegation)}catch{}}
        try{& $adapter.WriteStderr $(if($null-ne$result.error-and$result.error.code-is[string]){$result.error.code}else{'CCOD_LIFECYCLE_OPERATION_FAILED'})}catch{}
        return [pscustomobject][ordered]@{Result=$result;ExitCode=1}
    }
    try{
        if($requestValid){Assert-CcodLifecycleWorkerPublicResult $result $request|Out-Null;$stage='Fence';[void](& $adapter.AssertFence $context $request $delegation)}
        $stage='ResultValidation';& $adapter.WriteResult $ResultPath $result
    }catch{
        if($null-ne$delegation){try{[void](&$adapter.ExitDelegation $delegation)}catch{}}
        $code=Get-CcodLifecycleWorkerFailureCode $_ $stage
        return [pscustomobject][ordered]@{Result=(New-CcodLifecycleWorkerErrorResult $(if($requestValid){$request}else{$null}) $code $stage);ExitCode=1}
    }
    try{& $adapter.WriteStdout ($result|ConvertTo-Json -Depth 12 -Compress)}catch{if($null-ne$delegation){try{[void](&$adapter.ExitDelegation $delegation)}catch{}};return [pscustomobject][ordered]@{Result=$result;ExitCode=1}}
    if($null-ne$delegation){try{if(-not[bool](&$adapter.ExitDelegation $delegation)){throw 'release'}}catch{return [pscustomobject][ordered]@{Result=(New-CcodLifecycleWorkerErrorResult $request 'CCOD_LIFECYCLE_OPERATION_FAILED' 'LeaseRelease');ExitCode=1}}}
    return [pscustomobject][ordered]@{Result=$result;ExitCode=$(if($result.ok){0}else{1})}
}

if($MyInvocation.InvocationName -ne '.'){
    $run=Invoke-CcodLifecycleWorker -RequestPath $RequestPath -ResultPath $ResultPath
    exit $run.ExitCode
}
