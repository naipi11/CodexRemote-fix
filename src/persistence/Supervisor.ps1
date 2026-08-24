[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$ReadyToken
)

Set-StrictMode -Version 2.0

$script:CcodSupervisorScriptPath=if([string]::IsNullOrWhiteSpace($PSCommandPath)){$null}else{[IO.Path]::GetFullPath($PSCommandPath)}
$script:CcodSupervisorLogPath=$null
$script:CcodSupervisorAdapterNames=@(
    'GetIdentity','ResolveLayout','StartClock','GetElapsedMilliseconds','GetUtcNow',
    'EnterLease','ExitLease','OpenReadyEvent','OpenShutdownEvent','IsEventSignaled','SignalEvent','CloseEvent',
    'ReadActiveRuntime','GetTrustedLogonIdentity','WriteSafeExitIntent','ClearSafeExitIntent','EnterLifecycleOwnership','AssertLifecycleFence','SuspendLifecycleOwnership','ResumeLifecycleOwnership','ExitLifecycleOwnership','OpenLifecycleWakeEvent','ResetLifecycleWakeEvent',
    'ReadLifecycleRequest','ReceiveLifecycleSubmissions','WriteLifecycleSubmissionReceipt','NewLifecycleRequest','WriteLifecycleRequest','MoveLifecyclePhase','CompleteLifecycleRequest','GetLifecycleStep','ReduceLifecycleWorkerResult','NewLifecycleWorkerRequest','AssertLifecycleWorkerResult',
    'ReadState','ReadJournal','ReadUiPreference','SetUiLanguageMode','GetSystemCultureName','GetUiCatalog','ShowTrayError','EnumerateProcessIds','GetProcessSnapshot','ParseStaleCandidateCommandLine','GetPackageIdentity','GetSupervisorDecision','AddObservedEvent','CompleteControllerRun','HandoffRenderer','GetTrayPresentation',
    'NewQueue','GetQueueCount','TryDequeue','NewTray','SetTrayPresentation','SendTrayActionResult','VerifyActiveRuntimeForAbout','StopTrayTimer','RequestUiExit','CloseTray','NewWatcher','StopWatcher',
    'GetWorkerLeafState','WriteWorkerRequest','StartWorker','PollWorker','ReadWorkerResult','WaitWorker','GetWorkerIdentity','TerminateWorker','DisposeWorker','DeleteWorkerFile',
    'ClearFailedAttempt','SetAutomationEnabled','SetCandidateOptIn','OpenLogs','WriteLog','RunUiContext'
)
$script:CcodSupervisorUiLanguageModes=@('System','zh-CN','en-US')
$script:CcodSupervisorUiKeys=@(
    'Tray.Title',
    'Connection.WaitingForCodex','Connection.Checking','Connection.Connected','Connection.RepairNeeded','Connection.Error',
    'Protection.Running','Protection.Reconnecting','Protection.Stopping',
    'Menu.CheckAndRepair','Menu.Language','Menu.FollowSystem','Menu.Chinese','Menu.English','Menu.OpenLogs','Menu.About','Menu.AboutVersion','Menu.Exit',
    'Dialog.ExitTitle','Dialog.ExitMessage','Error.ActionFailed','Error.LanguageChange'
)
$script:CcodSupervisorCleanupAllowlist=@(
    'CCOD_SUPERVISOR_LOG_FAILED','CCOD_SUPERVISOR_TIMER_STOP_FAILED','CCOD_SUPERVISOR_WORKER_WAIT_FAILED',
    'CCOD_SUPERVISOR_WORKER_TERMINATE_FAILED','CCOD_SUPERVISOR_WORKER_DISPOSE_FAILED','CCOD_SUPERVISOR_WORKER_FILE_DELETE_FAILED',
    'CCOD_SUPERVISOR_WORKER_SURVIVED',
    'CCOD_SUPERVISOR_WATCHER_STOP_FAILED','CCOD_SUPERVISOR_QUEUE_DRAIN_FAILED','CCOD_SUPERVISOR_TRAY_CLOSE_FAILED',
    'CCOD_SUPERVISOR_READY_CLOSE_FAILED','CCOD_SUPERVISOR_SHUTDOWN_CLOSE_FAILED','CCOD_SUPERVISOR_LOCAL_RELEASE_FAILED',
    'CCOD_SUPERVISOR_LIFECYCLE_WAKE_CLOSE_FAILED','CCOD_SUPERVISOR_LIFECYCLE_RELEASE_FAILED','CCOD_SUPERVISOR_ACCOUNT_RELEASE_FAILED'
)

function Get-CcodSupervisorAdapterNames {
    return @($script:CcodSupervisorAdapterNames)
}

function Test-CcodSupervisorExactProperties {
    param($Value,[string[]]$Names)
    try{
        if($null -eq $Value -or $Value -isnot [pscustomobject]){return $false}
        $actual=@($Value.PSObject.Properties.Name)
        if($actual.Count -ne $Names.Count){return $false}
        for($index=0;$index -lt $Names.Count;$index++){
            if($actual[$index] -cne $Names[$index] -or $Value.PSObject.Properties[$actual[$index]].MemberType -ne [Management.Automation.PSMemberTypes]::NoteProperty){return $false}
        }
        return $true
    }catch{return $false}
}

function Test-CcodSupervisorStaticProbeResult {
    param($Result,$Request)
    try{
        $resultFields=@('schemaVersion','action','ok','requestId','runtimeId','targetIdentity','probe','error')
        $probeFields=@('ready','code','staticClassification','affectedBuildDetected','packageInstalled','packageFullName','packageFamilyName','packageVersion','executablePath','appAsarSha256','nodeVersion','nodeMajor','nodeSupported','nativeModulePresent','signatures')
        $signatureFields=@('invertedGate','deviceKeyModuleReference','macOnlyGuard','windowsControllerUi')
        if(-not (Test-CcodSupervisorExactProperties $Result $resultFields) -or
           ($Result.schemaVersion -isnot [int] -and $Result.schemaVersion -isnot [long]) -or $Result.schemaVersion -ne 1 -or
           $Result.action -isnot [string] -or $Result.action -cne 'StaticProbe' -or $Result.ok -isnot [bool] -or -not $Result.ok -or $null -ne $Result.error -or
           $Result.requestId -isnot [string] -or $Result.requestId -cne $Request.requestId -or $Result.runtimeId -isnot [string] -or $Result.runtimeId -cne $Request.runtimeId -or
           -not (Test-CcodSupervisorExactProperties $Result.targetIdentity @('pid','creationTimeUtc')) -or
           ($Result.targetIdentity.pid -isnot [int] -and $Result.targetIdentity.pid -isnot [long]) -or $Result.targetIdentity.pid -ne $Request.targetIdentity.pid -or
           $Result.targetIdentity.creationTimeUtc -isnot [string] -or $Result.targetIdentity.creationTimeUtc -cne $Request.targetIdentity.creationTimeUtc -or
           -not (Test-CcodSupervisorExactProperties $Result.probe $probeFields)){return $false}
        $probe=$Result.probe
        if($probe.ready -isnot [bool] -or $probe.code -isnot [string] -or $probe.code -cne 'CHECKER_OK' -or
           $probe.staticClassification -isnot [string] -or @('CandidateCompatible','NativeModulePresent','UnknownOrIncompatible') -cnotcontains $probe.staticClassification -or
           $probe.affectedBuildDetected -isnot [bool] -or $probe.packageInstalled -isnot [bool] -or -not $probe.packageInstalled -or
           $probe.nodeSupported -isnot [bool] -or -not $probe.nodeSupported -or $probe.nativeModulePresent -isnot [bool] -or
           ($probe.nodeMajor -isnot [int] -and $probe.nodeMajor -isnot [long]) -or $probe.nodeMajor -lt 22 -or
           -not (Test-CcodSupervisorExactProperties $probe.signatures $signatureFields)){return $false}
        foreach($name in @('packageFullName','packageFamilyName','packageVersion','executablePath','appAsarSha256','nodeVersion')){
            if($probe.$name -isnot [string] -or [string]::IsNullOrWhiteSpace($probe.$name) -or $probe.$name -match '[\r\n]'){return $false}
        }
        foreach($name in $signatureFields){if($probe.signatures.$name -isnot [bool]){return $false}}
        if($probe.appAsarSha256 -cnotmatch '^[0-9a-f]{64}$' -or $probe.nodeVersion -cnotmatch '^v(?<major>[0-9]+)\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$' -or [int]$Matches.major -ne $probe.nodeMajor){return $false}
        $allSentinels=@($signatureFields|Where-Object{-not $probe.signatures.$_}).Count -eq 0
        return ($probe.staticClassification -ceq 'CandidateCompatible' -and $probe.ready -and $probe.affectedBuildDetected -and $allSentinels) -or
               ($probe.staticClassification -ceq 'NativeModulePresent' -and -not $probe.ready -and -not $probe.affectedBuildDetected -and $probe.nativeModulePresent -and -not $allSentinels) -or
               ($probe.staticClassification -ceq 'UnknownOrIncompatible' -and -not $probe.ready -and -not $probe.affectedBuildDetected -and -not $probe.nativeModulePresent -and -not $allSentinels)
    }catch{return $false}
}

function Test-CcodSupervisorCanonicalUtc {
    param($Value)
    if($Value -isnot [string] -or $Value -cnotmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}Z$'){return $false}
    $parsed=[DateTime]::MinValue
    return [DateTime]::TryParseExact($Value,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$parsed) -and
        $parsed.Kind -eq [DateTimeKind]::Utc -and $parsed.ToString('o',[Globalization.CultureInfo]::InvariantCulture) -ceq $Value
}

function Test-CcodSupervisorDiagnosticRecord {
    param($Value)
    return $Value -is [Management.Automation.ErrorRecord] -or $Value -is [Management.Automation.WarningRecord] -or
        $Value -is [Management.Automation.VerboseRecord] -or $Value -is [Management.Automation.DebugRecord] -or
        $Value -is [Management.Automation.InformationRecord]
}

function Test-CcodSupervisorUiText {
    param($Value)
    if($Value -isnot [string] -or $Value.Length -lt 1 -or $Value.Length -gt 300){return $false}
    foreach($character in $Value.ToCharArray()){if([char]::IsControl($character)){return $false}}
    return $true
}

function Test-CcodSupervisorUiCatalog {
    param($Catalog,[string]$ExpectedMode)
    try{
        if(-not (Test-CcodSupervisorExactProperties $Catalog @('LanguageMode','EffectiveLocale','Strings','UsedEmergencyCatalog','ErrorCode')) -or
           $Catalog.LanguageMode -isnot [string] -or $script:CcodSupervisorUiLanguageModes -cnotcontains $Catalog.LanguageMode -or
           $Catalog.LanguageMode -cne $ExpectedMode -or $Catalog.EffectiveLocale -isnot [string] -or @('zh-CN','en-US') -cnotcontains $Catalog.EffectiveLocale -or
           $Catalog.UsedEmergencyCatalog -isnot [bool] -or
           ($null -ne $Catalog.ErrorCode -and ($Catalog.ErrorCode -isnot [string] -or @('','CCOD_UI_RESOURCE_INVALID') -cnotcontains $Catalog.ErrorCode)) -or
           -not (Test-CcodSupervisorExactProperties $Catalog.Strings $script:CcodSupervisorUiKeys)){return $false}
        foreach($key in $script:CcodSupervisorUiKeys){if(-not (Test-CcodSupervisorUiText $Catalog.Strings.PSObject.Properties[$key].Value)){return $false}}
        return $true
    }catch{return $false}
}

function Test-CcodSupervisorUiPreference {
    param($Preference)
    return (Test-CcodSupervisorExactProperties $Preference @('LanguageMode','FallbackUsed','ErrorCode')) -and
        $Preference.LanguageMode -is [string] -and $script:CcodSupervisorUiLanguageModes -ccontains $Preference.LanguageMode -and
        $Preference.FallbackUsed -is [bool] -and ($null -eq $Preference.ErrorCode -or
        ($Preference.ErrorCode -is [string] -and @('','CCOD_UI_PREFERENCES_MISSING','CCOD_UI_PREFERENCES_INVALID') -ccontains $Preference.ErrorCode))
}

function Test-CcodSupervisorCultureName {
    param($Value)
    if($Value -isnot [string] -or $Value.Length -lt 1 -or $Value.Length -gt 85){return $false}
    foreach($character in $Value.ToCharArray()){if([char]::IsControl($character)){return $false}}
    return $true
}

function Invoke-CcodSupervisorAdapterCapture {
    param([scriptblock]$Callback,[object[]]$Arguments)
    if($Callback -isnot [scriptblock]){return [pscustomobject]@{Threw=$true;Items=@()}}
    $items=[Collections.Generic.List[object]]::new();$threw=$false;$startingErrors=[object[]]@($global:Error)
    $variables=[Collections.Generic.List[Management.Automation.PSVariable]]::new()
    foreach($name in @('ErrorActionPreference','WarningPreference','VerbosePreference','DebugPreference','InformationPreference')){
        $variables.Add([Management.Automation.PSVariable]::new($name,'Continue'))
    }
    $invoker={param($InnerCallback,$InnerVariables,$InnerArguments)$InnerCallback.InvokeWithContext($null,$InnerVariables,[object[]]$InnerArguments)}
    try{
        & $invoker $Callback $variables $Arguments *>&1|ForEach-Object{
            if($items.Count -ge 16){throw 'adapter output limit exceeded'}
            $items.Add($_)
        }
    }catch{$threw=$true}
    finally{
        # WinForms/WMI adapters can append non-terminating records to $Error without failing.
        # Preserve caller history; only stream items and terminating throws count as adapter failure.
        $global:Error.Clear();foreach($entry in $startingErrors){[void]$global:Error.Add($entry)}
    }
    return [pscustomobject]@{Threw=[bool]$threw;Items=@($items)}
}

function Invoke-CcodSupervisorAdapter {
    param([scriptblock]$Callback,[object[]]$Arguments,[int]$OutputCount)
    $capture=Invoke-CcodSupervisorAdapterCapture $Callback $Arguments
    if($capture.Threw){throw [InvalidOperationException]::new('The supervisor adapter failed safely.')}
    foreach($item in $capture.Items){if(Test-CcodSupervisorDiagnosticRecord $item){throw [InvalidOperationException]::new('The supervisor adapter failed safely.')}}
    if($capture.Items.Count -ne $OutputCount){throw [InvalidOperationException]::new('The supervisor adapter failed safely.')}
    if($OutputCount -eq 1){Write-Output -NoEnumerate $capture.Items[0]}
}

function Invoke-CcodSupervisorNullableAdapter {
    param([scriptblock]$Callback,[object[]]$Arguments)
    $capture=Invoke-CcodSupervisorAdapterCapture $Callback $Arguments
    if($capture.Threw){throw [InvalidOperationException]::new('The supervisor adapter failed safely.')}
    foreach($item in $capture.Items){if(Test-CcodSupervisorDiagnosticRecord $item){throw [InvalidOperationException]::new('The supervisor adapter failed safely.')}}
    if($capture.Items.Count -gt 1){throw [InvalidOperationException]::new('The supervisor adapter failed safely.')}
    if($capture.Items.Count -eq 1){Write-Output -NoEnumerate $capture.Items[0]}
}

function Import-CcodSupervisorModules {
    if($null -eq $script:CcodSupervisorScriptPath){throw 'supervisor script path is unavailable'}
    $moduleRoot=Join-Path (Split-Path $script:CcodSupervisorScriptPath -Parent) 'modules'
    foreach($leaf in @('KernelObjects.psm1','PersistenceIO.psm1','RuntimeManifest.psm1','LifecycleEpoch.psm1','LifecycleTransaction.psm1','LifecycleCoordinator.psm1','LifecycleRequest.psm1','TrustedLogonIdentity.psm1','StateStore.psm1','TransitionJournal.psm1','ProcessControl.psm1','RendererIntegration.psm1','SupervisorEngine.psm1','UiLocalization.psm1','UiPreferences.psm1','TrayUi.psm1','TrayHostClient.psm1','WorkerRuntime.psm1')){
        Import-Module -Name (Join-Path $moduleRoot $leaf) -Force -ErrorAction Stop
    }
    foreach($leaf in @('KernelObjects.psm1','LifecycleTransaction.psm1')){
        Import-Module -Name (Join-Path $moduleRoot $leaf) -Force -ErrorAction Stop
    }
}

function Resolve-CcodSupervisorLayout {
    if($null -eq $script:CcodSupervisorScriptPath -or -not [IO.Path]::IsPathRooted($script:CcodSupervisorScriptPath)){throw 'runtime path is unavailable'}
    $persistenceRoot=Split-Path $script:CcodSupervisorScriptPath -Parent
    $sourceRoot=Split-Path $persistenceRoot -Parent
    $runtimeRoot=[IO.Path]::GetFullPath((Split-Path $sourceRoot -Parent))
    $runtimeId=Split-Path $runtimeRoot -Leaf
    $runtimeContainer=Split-Path $runtimeRoot -Parent
    if((Split-Path $runtimeContainer -Leaf) -cne 'runtime'){throw 'runtime container is invalid'}
    $installRoot=[IO.Path]::GetFullPath((Split-Path $runtimeContainer -Parent))
    $stateRoot=[IO.Path]::GetFullPath((Join-Path $installRoot 'state'))
    [pscustomobject][ordered]@{
        InstallRoot=$installRoot;RuntimeRoot=$runtimeRoot;RuntimeId=$runtimeId;StateRoot=$stateRoot
        WorkersRoot=[IO.Path]::GetFullPath((Join-Path $stateRoot 'workers'))
        ControllerPath=[IO.Path]::GetFullPath((Join-Path $persistenceRoot 'SessionController.ps1'))
        StaticWorkerPath=[IO.Path]::GetFullPath((Join-Path $persistenceRoot 'StaticProbeWorker.ps1'))
        LifecycleWorkerPath=[IO.Path]::GetFullPath((Join-Path $persistenceRoot 'LifecycleWorker.ps1'))
        PowerShellPath=[IO.Path]::GetFullPath((Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'))
        LogDirectory=[IO.Path]::GetFullPath((Join-Path $installRoot 'logs'))
        TransitionPath=[IO.Path]::GetFullPath((Join-Path $stateRoot 'transition.json'))
    }
}

function New-CcodSupervisorLifecycleWakeEvent {
    param([string]$UserSid,[int]$SessionId)
    if($UserSid -cnotmatch '^S-\d-\d+(?:-\d+)+$' -or $SessionId -lt 0){throw 'lifecycle wake identity is invalid'}
    $name="Local\CodexControlOtherDevices.LifecycleWake.$UserSid.$SessionId"
    $created=$false;$handle=$null
    try{
        $handle=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,$name,[ref]$created,(New-CcodEventSecurity -UserSid $UserSid))
        $module=Get-Module LifecycleRequest|Select-Object -First 1
        if($null -eq $module){throw 'lifecycle request module is unavailable'}
        & $module {param($Value,$Sid)Assert-CcodLifecycleWakeAcl -Handle $Value -UserSid $Sid} $handle $UserSid
        $result=[pscustomobject][ordered]@{SchemaVersion=1;Name=$name;Kind='LifecycleWake';CreatedNew=[bool]$created;Handle=$handle;Disposed=$false}
        $handle=$null
        return $result
    }finally{if($null-ne$handle){$handle.Dispose()}}
}

function Get-CcodSupervisorDefaultAdapters {
    Import-CcodSupervisorModules
    $defaults=@{}
    $defaults.GetIdentity={
        $windowsIdentity=$null;$process=$null
        try{
            $windowsIdentity=[Security.Principal.WindowsIdentity]::GetCurrent();$process=[Diagnostics.Process]::GetCurrentProcess()
            [pscustomobject][ordered]@{UserSid=$windowsIdentity.User.Value;SessionId=[int]$process.SessionId;Pid=[int]$process.Id;CreationTimeUtc=$process.StartTime.ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture)}
        }finally{if($null -ne $process){$process.Dispose()};if($null -ne $windowsIdentity){$windowsIdentity.Dispose()}}
    }
    $defaults.ResolveLayout={Resolve-CcodSupervisorLayout}
    $defaults.StartClock={[Diagnostics.Stopwatch]::StartNew()}
    $defaults.GetElapsedMilliseconds={param($Clock)[long]$Clock.ElapsedMilliseconds}
    $defaults.GetUtcNow={[DateTime]::UtcNow}
    $defaults.EnterLease={param($Kind,$UserSid,$SessionId,$TimeoutMilliseconds)if($Kind -ceq 'AccountSupervisor'){Enter-CcodMutex -Kind $Kind -UserSid $UserSid -TimeoutMilliseconds $TimeoutMilliseconds}else{Enter-CcodMutex -Kind $Kind -UserSid $UserSid -SessionId $SessionId -TimeoutMilliseconds $TimeoutMilliseconds}}
    $defaults.ExitLease={param($Lease)Exit-CcodMutex -Lease $Lease}
    $defaults.OpenReadyEvent={param($UserSid,$SessionId,$Token)Open-CcodEvent -Kind Ready -UserSid $UserSid -SessionId $SessionId -ReadyToken $Token}
    $defaults.OpenShutdownEvent={param($UserSid,$SessionId)New-CcodEvent -Kind Shutdown -UserSid $UserSid -SessionId $SessionId}
    $defaults.OpenLifecycleWakeEvent={param($UserSid,$SessionId)New-CcodSupervisorLifecycleWakeEvent -UserSid $UserSid -SessionId $SessionId}
    $defaults.ResetLifecycleWakeEvent={param($Event)[void]$Event.Handle.Reset()}
    $defaults.IsEventSignaled={param($Event)[bool]$Event.Handle.WaitOne(0)}
    $defaults.SignalEvent={param($Event)[void]$Event.Handle.Set()}
    $defaults.CloseEvent={param($Event)$Event.Handle.Dispose();$Event.Disposed=$true}
    $defaults.ReadActiveRuntime={param($InstallRoot)Read-CcodActiveRuntime -InstallRoot $InstallRoot}
    $defaults.GetTrustedLogonIdentity={param($ExpectedUserSid,$ExpectedSessionId)Get-CcodTrustedLogonIdentity -ExpectedUserSid $ExpectedUserSid -ExpectedSessionId $ExpectedSessionId}
    $defaults.WriteSafeExitIntent={param($StateRoot,$LogonIdentity,$RuntimeId,$RecoveryTransactionId,$NowUtc)Write-CcodSafeExitIntent -StateRoot $StateRoot -LogonIdentity $LogonIdentity -RuntimeId $RuntimeId -RecoveryTransactionId $RecoveryTransactionId -NowUtc $NowUtc}
    $defaults.ClearSafeExitIntent={param($StateRoot)Clear-CcodSafeExitIntent -StateRoot $StateRoot|Out-Null}
    $defaults.EnterLifecycleOwnership={param($InstallRoot,$RuntimeId,$RuntimeGeneration,$OwnerIdentity,$UserSid,$SessionId,$TimeoutMilliseconds)Enter-CcodLifecycleOwnership -InstallRoot $InstallRoot -RuntimeId $RuntimeId -RuntimeGeneration $RuntimeGeneration -OwnerIdentity $OwnerIdentity -UserSid $UserSid -SessionId $SessionId -TimeoutMilliseconds $TimeoutMilliseconds}
    $defaults.AssertLifecycleFence={param($InstallRoot,$Ownership)Assert-CcodLifecycleFence -InstallRoot $InstallRoot -Ownership $Ownership}
    $defaults.SuspendLifecycleOwnership={param($Ownership,$InstallRoot)Suspend-CcodLifecycleOwnership -Ownership $Ownership -InstallRoot $InstallRoot}
    $defaults.ResumeLifecycleOwnership={param($Ownership,$InstallRoot,$UserSid,$SessionId)Resume-CcodLifecycleOwnership -Ownership $Ownership -InstallRoot $InstallRoot -UserSid $UserSid -SessionId $SessionId}
    $defaults.ExitLifecycleOwnership={param($Ownership)Exit-CcodLifecycleOwnership -Ownership $Ownership}
    $defaults.ReadLifecycleRequest={param($StateRoot)Read-CcodLifecycleRequest -StateRoot $StateRoot}
    $defaults.ReceiveLifecycleSubmissions={param($StateRoot,$MaximumCount)Receive-CcodLifecycleSubmissions -StateRoot $StateRoot -MaximumCount $MaximumCount}
    $defaults.WriteLifecycleSubmissionReceipt={param($StateRoot,$SubmissionId,$Accepted,$TransactionId,$ErrorCode)Write-CcodLifecycleSubmissionReceipt -StateRoot $StateRoot -SubmissionId $SubmissionId -Accepted ([bool]$Accepted) -TransactionId $TransactionId -ErrorCode $ErrorCode|Out-Null}
    $defaults.NewLifecycleRequest={param($Kind,$Origin,$RuntimeId,$RuntimeGeneration,$LeaseEpoch,$OwnerIdentity,$LogonIdentity,$NowUtc)New-CcodLifecycleRequest -Kind $Kind -Origin $Origin -RuntimeId $RuntimeId -RuntimeGeneration $RuntimeGeneration -LeaseEpoch $LeaseEpoch -OwnerIdentity $OwnerIdentity -LogonIdentity $LogonIdentity -NowUtc $NowUtc}
    $defaults.WriteLifecycleRequest={param($StateRoot,$Request)Write-CcodLifecycleRequest -StateRoot $StateRoot -Request $Request}
    $defaults.MoveLifecyclePhase={param($Request,$NextPhase,$NowUtc)Move-CcodLifecyclePhase -Request $Request -NextPhase $NextPhase -NowUtc $NowUtc}
    $defaults.CompleteLifecycleRequest={param($StateRoot,$Request)Complete-CcodLifecycleRequest -StateRoot $StateRoot -Request $Request}
    $defaults.GetLifecycleStep={param($Request,$Observation,$NowUtc)Get-CcodLifecycleStep -Request $Request -Observation $Observation -NowUtc $NowUtc}
    $defaults.ReduceLifecycleWorkerResult={param($Request,$Result,$NowUtc)Reduce-CcodLifecycleWorkerResult -Request $Request -Result $Result -NowUtc $NowUtc}
    $defaults.NewLifecycleWorkerRequest={param($TransactionId,$Action,$RuntimeId,$RuntimeGeneration,$LeaseEpoch,$OwnerIdentity,$NotBeforeUtc,$TimeoutMilliseconds)New-CcodLifecycleWorkerRequest -TransactionId $TransactionId -Action $Action -RuntimeId $RuntimeId -RuntimeGeneration $RuntimeGeneration -LeaseEpoch $LeaseEpoch -OwnerIdentity $OwnerIdentity -NotBeforeUtc $NotBeforeUtc -TimeoutMilliseconds $TimeoutMilliseconds}
    $defaults.AssertLifecycleWorkerResult={param($Result,$ExpectedRequest)Assert-CcodLifecycleWorkerResult -Result $Result -ExpectedRequest $ExpectedRequest|Out-Null}
    $defaults.ReadState={param($StateRoot,$SuppressionKey)if([string]::IsNullOrWhiteSpace($SuppressionKey)){Read-CcodState -StateRoot $StateRoot}else{Read-CcodState -StateRoot $StateRoot -CurrentSuppressionKey $SuppressionKey}}
    $defaults.ReadJournal={param($Path)Read-CcodTransition -Path $Path}
    $defaults.ReadUiPreference={param($StateRoot)Read-CcodUiPreference -StateRoot $StateRoot}
    $defaults.SetUiLanguageMode={param($StateRoot,$LanguageMode)Set-CcodUiLanguageMode -StateRoot $StateRoot -LanguageMode $LanguageMode|Out-Null}
    $defaults.GetSystemCultureName={[Globalization.CultureInfo]::CurrentUICulture.Name}
    $defaults.GetUiCatalog={param($ResourcesRoot,$LanguageMode,$SystemCultureName)Get-CcodUiCatalog -ResourcesRoot $ResourcesRoot -LanguageMode $LanguageMode -SystemCultureName $SystemCultureName}
    $defaults.ShowTrayError={param($Tray,$Catalog,$Key)if($null -ne $Tray -and $null -ne $Tray.PSObject.Properties['Client']){Show-CcodTrayHostError -Context $Tray -Catalog $Catalog -Key $Key}else{Show-CcodTrayError -Context $Tray -Catalog $Catalog -Key $Key}}
    $defaults.EnumerateProcessIds={Get-CcodChatGptProcessIds}
    $defaults.GetProcessSnapshot={param($ProcessId,$StatusEvidence)Get-CcodProcessSnapshot -ProcessId $ProcessId -StatusEvidence $StatusEvidence}
    $defaults.ParseStaleCandidateCommandLine={
        param($CommandLine)
        if($CommandLine -isnot [string] -or [string]::IsNullOrWhiteSpace($CommandLine)){return}
        $processControl=Get-Module -Name ProcessControl
        if($null -eq $processControl){throw 'process command-line parser is unavailable'}
        & $processControl {
            param($Value)
            Initialize-CcodProcessNativeApi
            [Ccod.Persistence.Native.CommandLineV1]::Parse([string]$Value)
        } $CommandLine
    }
    $defaults.GetPackageIdentity={
        if($null -eq (Get-Command Get-CcodPackageIdentity -ErrorAction SilentlyContinue)){
            $modulePath=Join-Path (Join-Path (Split-Path $script:CcodSupervisorScriptPath -Parent) 'modules') 'CompatibilityProbe.psm1'
            Import-Module -Name $modulePath -Force -Verbose:$false -ErrorAction Stop | Out-Null
        }
        Get-CcodPackageIdentity
    }
    $defaults.GetSupervisorDecision={param($Context)Get-CcodSupervisorDecision -Context $Context}
    $defaults.AddObservedEvent={param($Observed,$ProcessId,$Created)Add-CcodObservedEvent -ObservedKeys $Observed -ProcessId $ProcessId -CreationTimeUtc $Created}
    $defaults.CompleteControllerRun={param($Result,$TransactionId,$Action,$RuntimeId,$ExpectedSource)Complete-CcodControllerRun -Result $Result -ExpectedTransactionId $TransactionId -ExpectedAction $Action -ExpectedRuntimeId $RuntimeId -ExpectedSource $ExpectedSource}
    $defaults.HandoffRenderer={
        param($Result,$RendererPort)
        $layout=Get-CcodRendererLayout
        if(-not $layout.Installed){return [pscustomobject][ordered]@{Outcome='Skipped';Code='CCOD_RENDERER_NOT_INSTALLED';ProcessId=$null}}
        if(Test-CcodRendererPaused -Layout $layout){return [pscustomobject][ordered]@{Outcome='Skipped';Code='CCOD_RENDERER_PAUSED';ProcessId=$null}}
        $state=Read-CcodRendererState -Layout $layout
        if($null -eq $state -and ([IO.File]::Exists($layout.StatePath) -or [IO.Directory]::Exists($layout.StatePath))){return [pscustomobject][ordered]@{Outcome='Skipped';Code='CCOD_RENDERER_STATE_UNAVAILABLE';ProcessId=$null}}
        $currentBrowserId=Get-CcodRendererCurrentBrowserId -RendererPort $RendererPort
        if($null -eq $currentBrowserId){return [pscustomobject][ordered]@{Outcome='Skipped';Code='CCOD_RENDERER_IDENTITY_UNAVAILABLE';ProcessId=$null}}
        if($null -ne $state -and $currentBrowserId -ceq $state.BrowserId -and $state.InjectorAlive){return [pscustomobject][ordered]@{Outcome='Skipped';Code='CCOD_RENDERER_ALREADY_ATTACHED';ProcessId=$null}}
        return Start-CcodRendererHandoff -RendererPort $RendererPort -Layout $layout
    }
    $defaults.GetTrayPresentation={param($Arguments)Get-CcodTrayPresentation @Arguments}
    $defaults.NewQueue={param($Kind)Write-Output -NoEnumerate ([Collections.Concurrent.ConcurrentQueue[object]]::new())}
    $defaults.GetQueueCount={param($Queue)[int]$Queue.Count}
    $defaults.TryDequeue={param($Queue)$value=$null;$ok=$Queue.TryDequeue([ref]$value);[pscustomobject][ordered]@{Succeeded=[bool]$ok;Value=$value}}
    $defaults.NewTray={param($Queue,$OnTick,$Catalog,$LanguageMode,$SystemCultureName)New-CcodTrayHostContext -CommandQueue $Queue -OnTick $OnTick -Catalog $Catalog -LanguageMode $LanguageMode -SystemCultureName $SystemCultureName}
    $defaults.SetTrayPresentation={param($Tray,$Presentation,$Catalog,$LanguageMode,$SystemCultureName,$WaitForAcknowledgement)Set-CcodTrayHostPresentation -Context $Tray -Presentation $Presentation -Catalog $Catalog -LanguageMode $LanguageMode -SystemCultureName $SystemCultureName -WaitForAcknowledgement:([bool]$WaitForAcknowledgement)}
    $defaults.SendTrayActionResult={param($Tray,$ActionId,$Revision,$Status,$ErrorCode,$TransactionId)Send-CcodTrayHostActionResult -Context $Tray -ActionId $ActionId -Revision $Revision -Status $Status -ErrorCode $ErrorCode -TransactionId $TransactionId}
    $defaults.VerifyActiveRuntimeForAbout={
        param($InstallRoot,$RuntimeId)
        $active=Read-CcodActiveRuntime -InstallRoot $InstallRoot
        if($active.activeRuntime-cne$RuntimeId){throw 'active runtime mismatch'}
        $runtimeRoot=[IO.Path]::GetFullPath((Join-Path (Join-Path $InstallRoot 'runtime') $active.activeRuntime))
        $manifest=Test-CcodRuntimeManifest -RuntimeDirectory $runtimeRoot -ExpectedRuntimeId $active.activeRuntime
        if(-not$manifest.Valid){throw 'runtime manifest invalid'}
        $version='';if($RuntimeId-cmatch'^(?<version>\d+\.\d+\.\d+)-'){$version=$Matches['version']}
        if([string]::IsNullOrWhiteSpace($version)){throw 'runtime version invalid'}
        return [pscustomobject][ordered]@{RuntimeId=$RuntimeId;Version=$version}
    }
    $defaults.StopTrayTimer={param($Tray)if($null -ne $Tray -and $null -ne $Tray.PSObject.Properties['Client']){return};$Tray.Timer.Stop()}
    $defaults.RequestUiExit={
        param($Tray)
        if($null -eq $Tray){return}
        $menuOpen=$false
        try{
            $menuOpenProperty=$Tray.PSObject.Properties['MenuOpen']
            $menuOpen=($null -ne $menuOpenProperty -and $menuOpenProperty.Value -is [bool] -and $menuOpenProperty.Value)
            if($menuOpen){
                $trayAdaptersProperty=$Tray.PSObject.Properties['Adapters']
                $endNativeMenu=$null
                if($null -ne $trayAdaptersProperty -and $trayAdaptersProperty.Value -is [hashtable]){
                    $endNativeMenu=$trayAdaptersProperty.Value['EndMenu']
                    if($null -eq $endNativeMenu){$endNativeMenu=$trayAdaptersProperty.Value['EndNativeMenu']}
                }
                if($endNativeMenu -is [scriptblock]){
                    try{[void](Invoke-CcodSupervisorAdapterCapture $endNativeMenu @())}catch{}
                }
            }
        }catch{}
        if($null -ne $Tray -and $null -ne $Tray.PSObject.Properties['Client']){Request-CcodTrayHostExit -Context $Tray;return}
        $applicationContextProperty=$Tray.PSObject.Properties['ApplicationContext']
        if($null -ne $applicationContextProperty -and $null -ne $applicationContextProperty.Value){$applicationContextProperty.Value.ExitThread()}
    }
    $defaults.CloseTray={param($Tray)if($null -ne $Tray -and $null -ne $Tray.PSObject.Properties['Client']){Close-CcodTrayHostContext -Context $Tray}else{Close-CcodTrayContext -Context $Tray}}
    $defaults.NewWatcher={param($Queue,$OnFull)Start-CcodProcessWatcher -Queue $Queue -OnFullReconciliationRequired $OnFull}
    $defaults.StopWatcher={param($Watcher)Stop-CcodProcessWatcher -Watcher $Watcher}
    $defaults.GetWorkerLeafState={param($Path)Get-CcodWorkerLeafState -Path $Path}
    $defaults.WriteWorkerRequest={param($Path,$Request)Write-CcodWorkerRequest -Path $Path -Request $Request}
    $defaults.StartWorker={param($Kind,$ScriptPath,$RequestPath,$ResultPath,$StderrPath,$Request,$PowerShellPath)Start-CcodWorkerProcess -Kind $Kind -ScriptPath $ScriptPath -RequestPath $RequestPath -ResultPath $ResultPath -StderrPath $StderrPath -PowerShellPath $PowerShellPath}
    $defaults.PollWorker={param($Slot)Get-CcodWorkerPoll -Slot $Slot}
    $defaults.ReadWorkerResult={param($Path)Read-CcodWorkerResult -Path $Path}
    $defaults.WaitWorker={param($Slot,$TimeoutMilliseconds)Wait-CcodWorkerExit -Slot $Slot -TimeoutMilliseconds $TimeoutMilliseconds}
    $defaults.GetWorkerIdentity={param($ProcessId)Get-CcodWorkerIdentity -Pid $ProcessId}
    $defaults.TerminateWorker={param($Slot)Stop-CcodWorkerProcess -Slot $Slot}
    $defaults.DisposeWorker={param($Slot)Close-CcodWorkerHandle -Slot $Slot}
    $defaults.DeleteWorkerFile={param($Path)Remove-CcodWorkerFile -Path $Path}
    $defaults.ClearFailedAttempt={
        param($StateRoot,$Package,$Hash,$Runtime,$Timestamp)
        Clear-CcodFailedPackageAttempt -StateRoot $StateRoot -PackageFullName $Package -AppAsarSha256 $Hash -RuntimeId $Runtime -ExpectedConfirmedAtUtc $Timestamp
    }
    $defaults.SetAutomationEnabled={
        param($StateRoot,$Enabled)
        Set-CcodAutomationEnabled -StateRoot $StateRoot -Enabled ([bool]$Enabled)
    }
    $defaults.SetCandidateOptIn={
        param($StateRoot,$Enabled)
        Set-CcodCandidateCompatibleOptIn -StateRoot $StateRoot -Enabled ([bool]$Enabled)
    }
    $defaults.OpenLogs={param($Path)Open-CcodLogDirectory -Path $Path}
    $defaults.WriteLog={param($Record)if($null -ne $script:CcodSupervisorLogPath){Write-CcodRotatingLog -Path $script:CcodSupervisorLogPath -Message ($Record|ConvertTo-Json -Depth 4 -Compress)}}
    $defaults.RunUiContext={param($Tray)if($null -ne $Tray -and $null -ne $Tray.PSObject.Properties['Client']){Invoke-CcodTrayHostRunLoop -Context $Tray}else{Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop;[Windows.Forms.Application]::Run($Tray.ApplicationContext)}}
    return $defaults
}

function Test-CcodSupervisorAdapterSet {
    param($Adapters)
    try{
        if($Adapters -isnot [hashtable] -or $Adapters.Count -ne $script:CcodSupervisorAdapterNames.Count){return $false}
        foreach($name in $script:CcodSupervisorAdapterNames){if(-not $Adapters.ContainsKey($name) -or $Adapters[$name] -isnot [scriptblock]){return $false}}
        foreach($key in $Adapters.Keys){if($key -isnot [string] -or $script:CcodSupervisorAdapterNames -cnotcontains $key){return $false}}
        return $true
    }catch{return $false}
}

function Get-CcodSupervisorAdapters {
    param($Adapters)
    if($null -eq $Adapters){return Get-CcodSupervisorDefaultAdapters}
    if(-not (Test-CcodSupervisorAdapterSet $Adapters)){return $null}
    return $Adapters
}

function Test-CcodSupervisorIdentity {
    param($Identity)
    return (Test-CcodSupervisorExactProperties $Identity @('UserSid','SessionId','Pid','CreationTimeUtc')) -and
        $Identity.UserSid -is [string] -and $Identity.UserSid -cmatch '^S-1-(?:\d+-){1,14}\d+$' -and
        $Identity.SessionId -is [int] -and $Identity.SessionId -ge 0 -and $Identity.Pid -is [int] -and $Identity.Pid -gt 0 -and
        (Test-CcodSupervisorCanonicalUtc $Identity.CreationTimeUtc)
}

function Test-CcodSupervisorLayout {
    param($Layout)
    $names=@('InstallRoot','RuntimeRoot','RuntimeId','StateRoot','WorkersRoot','ControllerPath','StaticWorkerPath','LifecycleWorkerPath','PowerShellPath','LogDirectory','TransitionPath')
    if(-not (Test-CcodSupervisorExactProperties $Layout $names) -or $Layout.RuntimeId -isnot [string] -or $Layout.RuntimeId -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'){return $false}
    foreach($name in $names|Where-Object{$_ -ne 'RuntimeId'}){
        $value=$Layout.$name;$full=$null
        if($value -isnot [string]){return $false}
        try{$full=[IO.Path]::GetFullPath($value)}catch{return $false}
        if(-not [IO.Path]::IsPathRooted($value) -or $full -cne $value){return $false}
    }
    return $true
}

function Test-CcodSupervisorLease {
    param($Lease,[string]$Kind)
    $names=@('SchemaVersion','Name','Kind','Outcome','CreatedNew','Abandoned','Handle','OwnerManagedThreadId','Released')
    return (Test-CcodSupervisorExactProperties $Lease $names) -and $Lease.SchemaVersion -is [int] -and $Lease.SchemaVersion -eq 1 -and
        $Lease.Name -is [string] -and $Lease.Kind -is [string] -and $Lease.Kind -ceq $Kind -and $Lease.Outcome -is [string] -and
        @('Acquired','TimedOut') -ccontains $Lease.Outcome -and $Lease.CreatedNew -is [bool] -and $Lease.Abandoned -is [bool] -and
        $Lease.OwnerManagedThreadId -is [int] -and $Lease.OwnerManagedThreadId -gt 0 -and $Lease.Released -is [bool] -and
        (($Lease.Outcome -ceq 'Acquired' -and $null -ne $Lease.Handle -and -not $Lease.Released) -or ($Lease.Outcome -ceq 'TimedOut' -and $null -eq $Lease.Handle -and -not $Lease.Abandoned))
}

function Test-CcodSupervisorEvent {
    param($Event,[string]$Kind)
    return (Test-CcodSupervisorExactProperties $Event @('SchemaVersion','Name','Kind','CreatedNew','Handle','Disposed')) -and
        $Event.SchemaVersion -is [int] -and $Event.SchemaVersion -eq 1 -and $Event.Name -is [string] -and $Event.Kind -is [string] -and
        $Event.Kind -ceq $Kind -and $Event.CreatedNew -is [bool] -and $null -ne $Event.Handle -and $Event.Disposed -is [bool] -and -not $Event.Disposed
}

function New-CcodSupervisorReceipt {
    param([ValidateSet('Stopped','StartupRejected','Failed')][string]$Outcome,[int]$ExitCode,[string[]]$CleanupCodes)
    $safe=@($CleanupCodes|Where-Object{$script:CcodSupervisorCleanupAllowlist -ccontains $_}|Select-Object -Unique)
    [pscustomobject][ordered]@{SchemaVersion=1;Outcome=$Outcome;ExitCode=$ExitCode;CleanupCodes=$safe}
}

function Add-CcodSupervisorCleanupCode {
    param([Collections.Generic.List[string]]$Codes,[string]$Code)
    if($script:CcodSupervisorCleanupAllowlist -ccontains $Code -and -not $Codes.Contains($Code) -and $Codes.Count -lt 16){$Codes.Add($Code)}
}

function Invoke-CcodSupervisorCleanupStage {
    param([scriptblock]$Action,[Collections.Generic.List[string]]$Codes,[string]$Code)
    try{& $Action}catch{Add-CcodSupervisorCleanupCode $Codes $Code}
}

function Get-CcodSupervisorRemainingBudget {
    param($Clock,[hashtable]$Adapters)
    $elapsed=Invoke-CcodSupervisorAdapter $Adapters.GetElapsedMilliseconds @($Clock) 1
    if(($elapsed -isnot [int] -and $elapsed -isnot [long]) -or $elapsed -lt 0){throw 'monotonic clock is invalid'}
    if([long]$elapsed -ge 5000){return [int]0}
    return [int](5000-[long]$elapsed)
}

function Invoke-CcodSupervisorDrainQueue {
    param($Queue,[hashtable]$Adapters)
    if($null -eq $Queue){return}
    $queueArgument=[object[]]::new(1);$queueArgument[0]=$Queue
    $count=Invoke-CcodSupervisorAdapter $Adapters.GetQueueCount $queueArgument 1
    if($count -isnot [int] -or $count -lt 0){throw 'queue count is invalid'}
    $limit=[Math]::Min($count,256)
    for($index=0;$index -lt $limit;$index++){
        $receipt=Invoke-CcodSupervisorAdapter $Adapters.TryDequeue $queueArgument 1
        if(-not (Test-CcodSupervisorExactProperties $receipt @('Succeeded','Value')) -or $receipt.Succeeded -isnot [bool]){throw 'queue receipt is invalid'}
        if(-not $receipt.Succeeded){break}
    }
    $remaining=Invoke-CcodSupervisorAdapter $Adapters.GetQueueCount $queueArgument 1
    if($remaining -isnot [int] -or $remaining -ne 0){throw 'queue did not drain'}
}

function New-CcodSupervisorHostState {
    [CmdletBinding()]
    param($Identity,$Layout,$Clock,$ShutdownEvent,$LifecycleWakeEvent,$CommandQueue,$EventQueue,$State,$Journal,$LifecycleOwnership,$LifecycleRequest,$LogonIdentity)
    if(-not (Test-CcodSupervisorIdentity $Identity) -or -not (Test-CcodSupervisorLayout $Layout) -or $null -eq $Clock -or
       -not (Test-CcodSupervisorEvent $ShutdownEvent 'Shutdown') -or -not (Test-CcodSupervisorEvent $LifecycleWakeEvent 'LifecycleWake') -or $null -eq $CommandQueue -or $null -eq $EventQueue -or $null -eq $State -or $null -eq $LifecycleOwnership -or $null -eq $LogonIdentity){throw 'host state inputs are invalid'}
    [pscustomobject][ordered]@{
        SchemaVersion=1;ShutdownRequested=$false;ShutdownEvent=$ShutdownEvent;Tray=$null;TrayCallbackFailureLogged=$false;UiLanguageMode=$null;UiCatalog=$null;LastAcknowledgedPresentation=$null;State=$State;Journal=$Journal;WorkerSlot=$null
        LifecycleOwnership=$LifecycleOwnership;LifecycleRequest=$LifecycleRequest;LifecycleWorkerSlot=$null;LifecycleWakeEvent=$LifecycleWakeEvent;LogonIdentity=$LogonIdentity;LifecycleObservation='Unknown';ConnectionState='Unknown';ProtectionState='Running'
        Identity=$Identity;Layout=$Layout;CommandQueue=$CommandQueue;EventQueue=$EventQueue;Clock=$Clock
        ObservedKeys=[ordered]@{};AttemptKeys=[ordered]@{};RecoveryIgnoreKeys=[ordered]@{};SuppressionKeys=[ordered]@{};TrayActionIds=[ordered]@{}
        StaticCache=[ordered]@{};TransportRetries=[ordered]@{};TerminalRecoveries=[ordered]@{}
        PackageFullName=$null;AppAsarSha256=$null;Classification=$null
        Ordinary=[object[]]@();Special=[object[]]@();SpecialNeedsInspect=$false;SpecialProof=$null;StaleReconciliationCandidate=$null;FailedStaleRepairKey=$null
        SessionState='Idle';BlockAutomaticActions=$false;Reason='Idle';ObservationDirty=$false;NextObservationMilliseconds=[long]0
        ForceReconcile=$true;NextReconcileMilliseconds=[long]0;LastDecision=$null
        RuntimeCleanupCodes=[Collections.Generic.List[string]]::new()
    }
}

function Get-CcodSupervisorNowUtc {
    param([hashtable]$Adapters)
    $now=Invoke-CcodSupervisorAdapter $Adapters.GetUtcNow @() 1
    if($now -isnot [DateTime]){throw 'lifecycle clock is invalid'}
    return $now.ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture)
}

function Test-CcodSupervisorActiveRuntime {
    param($Pointer,[string]$RuntimeId)
    return (Test-CcodSupervisorExactProperties $Pointer @('schemaVersion','activeRuntime','previousRuntime','generation','updatedAtUtc')) -and
        $Pointer.schemaVersion -is [int] -and $Pointer.schemaVersion -eq 2 -and $Pointer.activeRuntime -is [string] -and $Pointer.activeRuntime -cmatch '^[A-Za-z0-9._-]{1,96}$' -and $Pointer.activeRuntime -ceq $RuntimeId -and
        ($null -eq $Pointer.previousRuntime -or ($Pointer.previousRuntime -is [string] -and $Pointer.previousRuntime -cmatch '^[A-Za-z0-9._-]{1,96}$')) -and
        (Test-CcodSupervisorCanonicalUtc $Pointer.updatedAtUtc) -and
        ($Pointer.generation -is [int] -or $Pointer.generation -is [long] -or $Pointer.generation -is [uint64] -or $Pointer.generation -is [decimal]) -and [decimal]$Pointer.generation -ge 1 -and [decimal]$Pointer.generation -le [decimal][UInt64]::MaxValue -and [decimal]::Truncate([decimal]$Pointer.generation) -eq [decimal]$Pointer.generation
}

function Test-CcodSupervisorLifecycleOwnership {
    param($Value,$Identity,$Pointer)
    return (Test-CcodSupervisorExactProperties $Value @('schemaVersion','lease','epoch','runtimeId','runtimeGeneration','ownerIdentity','released')) -and
        $Value.schemaVersion-is[int] -and $Value.schemaVersion-eq1 -and $null-ne$Value.lease -and $Value.released-is[bool] -and -not$Value.released -and
        ($Value.epoch-is[int] -or $Value.epoch-is[long] -or $Value.epoch-is[uint64] -or $Value.epoch-is[decimal]) -and [decimal]$Value.epoch-ge1 -and [decimal]$Value.epoch-le[decimal][UInt64]::MaxValue -and [decimal]::Truncate([decimal]$Value.epoch)-eq[decimal]$Value.epoch -and
        $Value.runtimeId-is[string] -and $Value.runtimeId-ceq$Pointer.activeRuntime -and [UInt64]$Value.runtimeGeneration-eq[UInt64]$Pointer.generation -and
        (Test-CcodSupervisorExactProperties $Value.ownerIdentity @('pid','creationTimeUtc')) -and $Value.ownerIdentity.pid-is[int] -and $Value.ownerIdentity.pid-eq$Identity.Pid -and $Value.ownerIdentity.creationTimeUtc-is[string] -and $Value.ownerIdentity.creationTimeUtc-ceq$Identity.CreationTimeUtc
}

function Test-CcodSupervisorLogonIdentity {
    param($Value,$Identity)
    return (Test-CcodSupervisorExactProperties $Value @('authenticationId','userSid','sessionId')) -and
        $Value.authenticationId -is [string] -and $Value.authenticationId -cmatch '^[0-9A-F]{8}:[0-9A-F]{8}$' -and
        $Value.userSid -is [string] -and $Value.userSid -ceq $Identity.UserSid -and $Value.sessionId -is [int] -and $Value.sessionId -eq $Identity.SessionId
}

function Test-CcodSupervisorLifecycleSubmission {
    param($Value)
    if(-not (Test-CcodSupervisorExactProperties $Value @('schemaVersion','submissionId','kind','origin','runtimeId','runtimeGeneration','createdAtUtc')) -or
       $Value.schemaVersion -isnot [int] -or $Value.schemaVersion -ne 1 -or $Value.submissionId -isnot [string] -or $Value.submissionId -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' -or
       $Value.kind -isnot [string] -or @('RestartAndRepair','CheckAndRepair','SafeExit') -cnotcontains $Value.kind -or $Value.origin -isnot [string] -or @('Installer','Tray','ExplicitStart','Guardian') -cnotcontains $Value.origin -or
       $Value.runtimeId -isnot [string] -or $Value.runtimeId -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$' -or -not(Test-CcodSupervisorCanonicalUtc $Value.createdAtUtc)){return $false}
    try{return [UInt64]$Value.runtimeGeneration -gt 0 -and [decimal]::Truncate([decimal]$Value.runtimeGeneration) -eq [decimal]$Value.runtimeGeneration}catch{return $false}
}

function ConvertTo-CcodSupervisorLifecycleObservation {
    param([string]$Observation)
    switch($Observation){
        'RemoteVerified'{return 'Connected'}
        'Special'{return 'Checking'}
        'Ordinary'{return 'RepairNeeded'}
        'NoCodex'{return 'WaitingForCodex'}
        'Closed'{return 'WaitingForCodex'}
        'LaunchRequested'{return 'WaitingForCodex'}
        default{return 'Error'}
    }
}

function Rebind-CcodSupervisorLifecycleRequest {
    param($Request,$Ownership,$LogonIdentity,[string]$NowUtc,[hashtable]$Adapters,[string]$StateRoot,[string]$InstallRoot)
    if($null -eq $Request){return $null}
    if($Request.runtimeId -cne $Ownership.runtimeId -or [UInt64]$Request.runtimeGeneration -ne [UInt64]$Ownership.runtimeGeneration -or
       $Request.logonIdentity.authenticationId -cne $LogonIdentity.authenticationId -or $Request.logonIdentity.userSid -cne $LogonIdentity.userSid -or [int]$Request.logonIdentity.sessionId -ne [int]$LogonIdentity.sessionId){throw 'persisted lifecycle request belongs to another runtime or logon'}
    $same=$Request.leaseEpoch -eq $Ownership.epoch -and $Request.ownerIdentity.pid -eq $Ownership.ownerIdentity.pid -and $Request.ownerIdentity.creationTimeUtc -ceq $Ownership.ownerIdentity.creationTimeUtc
    if($same){return $Request}
    $bound=$Request|ConvertTo-Json -Depth 16|ConvertFrom-Json
    $bound.leaseEpoch=[UInt64]$Ownership.epoch
    $bound.ownerIdentity=[pscustomobject][ordered]@{pid=[int]$Ownership.ownerIdentity.pid;creationTimeUtc=[string]$Ownership.ownerIdentity.creationTimeUtc}
    $bound.logonIdentity=[pscustomobject][ordered]@{authenticationId=[string]$LogonIdentity.authenticationId;userSid=[string]$LogonIdentity.userSid;sessionId=[int]$LogonIdentity.sessionId}
    $bound.updatedAtUtc=$NowUtc
    [void](Invoke-CcodSupervisorAdapter $Adapters.GetLifecycleStep @($bound,'Unknown',$NowUtc) 1)
    Invoke-CcodSupervisorAdapter $Adapters.AssertLifecycleFence @($InstallRoot,$Ownership) 1|Out-Null
    Invoke-CcodSupervisorAdapter $Adapters.WriteLifecycleRequest @($StateRoot,$bound) 0
    return $bound
}

function New-CcodSupervisorInternalLifecycleRequest {
    param($HostState,[hashtable]$Adapters,[ValidateSet('RestartAndRepair','CheckAndRepair','SafeExit')][string]$Kind,[ValidateSet('Installer','Tray','ExplicitStart','Guardian')][string]$Origin)
    if($null -ne $HostState.LifecycleRequest -or $null -ne $HostState.LifecycleWorkerSlot){return $false}
    $now=Get-CcodSupervisorNowUtc $Adapters
    $request=Invoke-CcodSupervisorAdapter $Adapters.NewLifecycleRequest @($Kind,$Origin,$HostState.Layout.RuntimeId,[UInt64]$HostState.LifecycleOwnership.runtimeGeneration,[UInt64]$HostState.LifecycleOwnership.epoch,$HostState.LifecycleOwnership.ownerIdentity,$HostState.LogonIdentity,$now) 1
    Invoke-CcodSupervisorAdapter $Adapters.AssertLifecycleFence @($HostState.Layout.InstallRoot,$HostState.LifecycleOwnership) 1|Out-Null
    Invoke-CcodSupervisorAdapter $Adapters.WriteLifecycleRequest @($HostState.Layout.StateRoot,$request) 0
    $HostState.LifecycleRequest=$request;$HostState.ProtectionState='Running'
    return $true
}

function Receive-CcodSupervisorLifecycleSubmission {
    param($HostState,[hashtable]$Adapters)
    $submission=Invoke-CcodSupervisorNullableAdapter $Adapters.ReceiveLifecycleSubmissions @($HostState.Layout.StateRoot,[int]1)
    Invoke-CcodSupervisorAdapter $Adapters.ResetLifecycleWakeEvent @($HostState.LifecycleWakeEvent) 0
    if($null -eq $submission){return}
    if(-not(Test-CcodSupervisorLifecycleSubmission $submission)){throw 'lifecycle submission is invalid'}
    if($null -ne $HostState.LifecycleRequest -or $null -ne $HostState.LifecycleWorkerSlot){
        Invoke-CcodSupervisorAdapter $Adapters.WriteLifecycleSubmissionReceipt @($HostState.Layout.StateRoot,$submission.submissionId,$false,$null,'CCOD_LIFECYCLE_SUPERVISOR_BUSY') 0
        return
    }
    if($submission.runtimeId -cne $HostState.LifecycleOwnership.runtimeId -or [UInt64]$submission.runtimeGeneration -ne [UInt64]$HostState.LifecycleOwnership.runtimeGeneration){
        Invoke-CcodSupervisorAdapter $Adapters.WriteLifecycleSubmissionReceipt @($HostState.Layout.StateRoot,$submission.submissionId,$false,$null,'CCOD_LIFECYCLE_RUNTIME_STALE') 0
        return
    }
    $now=Get-CcodSupervisorNowUtc $Adapters
    $request=Invoke-CcodSupervisorAdapter $Adapters.NewLifecycleRequest @($submission.kind,$submission.origin,$submission.runtimeId,[UInt64]$submission.runtimeGeneration,[UInt64]$HostState.LifecycleOwnership.epoch,$HostState.LifecycleOwnership.ownerIdentity,$HostState.LogonIdentity,$now) 1
    Invoke-CcodSupervisorAdapter $Adapters.AssertLifecycleFence @($HostState.Layout.InstallRoot,$HostState.LifecycleOwnership) 1|Out-Null
    Invoke-CcodSupervisorAdapter $Adapters.WriteLifecycleRequest @($HostState.Layout.StateRoot,$request) 0
    $HostState.LifecycleRequest=$request;$HostState.ProtectionState='Running'
    Invoke-CcodSupervisorAdapter $Adapters.WriteLifecycleSubmissionReceipt @($HostState.Layout.StateRoot,$submission.submissionId,$true,$request.transactionId,$null) 0
}

function New-CcodSupervisorLifecycleWorkerPaths {
    param($HostState,[string]$TransactionId)
    if($TransactionId -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'){throw 'lifecycle transaction identity is invalid'}
    $root=$HostState.Layout.WorkersRoot
    return [pscustomobject][ordered]@{
        RequestPath=[IO.Path]::GetFullPath((Join-Path $root ("lifecycle-$TransactionId.request.json")))
        ResultPath=[IO.Path]::GetFullPath((Join-Path $root ("lifecycle-$TransactionId.result.json")))
        StderrPath=$null
    }
}

function Start-CcodSupervisorLifecycleWorkerSlot {
    param($HostState,[hashtable]$Adapters,[string]$Action,[AllowNull()]$DeadlineUtc)
    if($null-ne$HostState.LifecycleWorkerSlot -or $null-ne$HostState.WorkerSlot -or $null-eq$HostState.LifecycleRequest){throw 'lifecycle worker slot is unavailable'}
    $requestState=$HostState.LifecycleRequest;$now=Get-CcodSupervisorNowUtc $Adapters;$timeout=30000
    if($null-ne$DeadlineUtc){
        if(-not(Test-CcodSupervisorCanonicalUtc $DeadlineUtc)){throw 'lifecycle deadline is invalid'}
        $deadline=[DateTime]::ParseExact($DeadlineUtc,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
        $current=[DateTime]::ParseExact($now,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
        $timeout=[int][Math]::Max(1,[Math]::Min(600000,[Math]::Ceiling(($deadline-$current).TotalMilliseconds)))
    }
    $paths=New-CcodSupervisorLifecycleWorkerPaths $HostState $requestState.transactionId
    $workerRequest=Invoke-CcodSupervisorAdapter $Adapters.NewLifecycleWorkerRequest @($requestState.transactionId,$Action,$requestState.runtimeId,[UInt64]$requestState.runtimeGeneration,[UInt64]$requestState.leaseEpoch,$requestState.ownerIdentity,$now,$timeout) 1
    $owned=[Collections.Generic.List[string]]::new();$suspended=$false
    try{
        Invoke-CcodSupervisorAdapter $Adapters.AssertLifecycleFence @($HostState.Layout.InstallRoot,$HostState.LifecycleOwnership) 1|Out-Null
        $stale=[Collections.Generic.List[string]]::new()
        foreach($path in @($paths.RequestPath,$paths.ResultPath)){
            $leaf=Invoke-CcodSupervisorAdapter $Adapters.GetWorkerLeafState @($path) 1
            if(-not(Test-CcodSupervisorExactProperties $leaf @('Exists','IsReparse')) -or $leaf.Exists-isnot[bool] -or $leaf.IsReparse-isnot[bool] -or $leaf.IsReparse){throw 'lifecycle worker leaf is unsafe'}
            if($leaf.Exists){$stale.Add($path)}
        }
        foreach($path in @($stale)){
            # A prior Supervisor owns the only kill-on-close Job and cannot coexist with this
            # lifetime lease, so direct leaves for the active transaction are stale crash residue.
            Invoke-CcodSupervisorAdapter $Adapters.DeleteWorkerFile @($path) 0
            $leaf=Invoke-CcodSupervisorAdapter $Adapters.GetWorkerLeafState @($path) 1
            if(-not(Test-CcodSupervisorExactProperties $leaf @('Exists','IsReparse')) -or $leaf.Exists-isnot[bool] -or $leaf.IsReparse-isnot[bool] -or $leaf.Exists -or $leaf.IsReparse){throw 'lifecycle worker stale framing could not be reclaimed'}
        }
        Invoke-CcodSupervisorAdapter $Adapters.WriteWorkerRequest @($paths.RequestPath,$workerRequest) 0;$owned.Add($paths.RequestPath)
        $handoff=Invoke-CcodSupervisorAdapter $Adapters.SuspendLifecycleOwnership @($HostState.LifecycleOwnership,$HostState.Layout.InstallRoot) 1
        if($handoff-isnot[bool]-or-not$handoff){throw 'lifecycle ownership handoff is invalid'}
        $suspended=$true
        $started=Invoke-CcodSupervisorAdapter $Adapters.StartWorker @('Lifecycle',$HostState.Layout.LifecycleWorkerPath,$paths.RequestPath,$paths.ResultPath,$null,$workerRequest,$HostState.Layout.PowerShellPath) 1
        if(-not(Test-CcodSupervisorExactProperties $started @('ProcessId','CreationTimeUtc','Handle','JobHandle')) -or $started.ProcessId-isnot[int] -or $started.ProcessId-lt1 -or -not(Test-CcodSupervisorCanonicalUtc $started.CreationTimeUtc) -or $null-eq$started.Handle -or $null-eq$started.JobHandle){throw 'lifecycle worker start receipt is invalid'}
        $HostState.LifecycleWorkerSlot=[pscustomobject][ordered]@{Kind='Lifecycle';Action=$Action;RequestId=$requestState.transactionId;RuntimeId=$requestState.runtimeId;Request=$workerRequest;RequestPath=$paths.RequestPath;ResultPath=$paths.ResultPath;StderrPath=$null;ProcessId=[int]$started.ProcessId;CreationTimeUtc=$started.CreationTimeUtc;Handle=$started.Handle;JobHandle=$started.JobHandle}
        return $HostState.LifecycleWorkerSlot
    }catch{
        if($suspended){
            try{
                $resumed=Invoke-CcodSupervisorAdapter $Adapters.ResumeLifecycleOwnership @($HostState.LifecycleOwnership,$HostState.Layout.InstallRoot,$HostState.Identity.UserSid,[int]$HostState.Identity.SessionId) 1
                if($resumed-isnot[bool]-or-not$resumed){throw 'lifecycle ownership reacquire receipt is invalid'}
                Invoke-CcodSupervisorAdapter $Adapters.AssertLifecycleFence @($HostState.Layout.InstallRoot,$HostState.LifecycleOwnership) 1|Out-Null
            }catch{throw 'lifecycle ownership could not be reacquired after worker-start failure'}
        }
        foreach($path in @($owned)){try{Invoke-CcodSupervisorAdapter $Adapters.DeleteWorkerFile @($path) 0}catch{}}
        throw
    }
}

function Clear-CcodSupervisorLifecycleWorkerSlot {
    param($HostState,[hashtable]$Adapters)
    $slot=$HostState.LifecycleWorkerSlot;if($null-eq$slot){return}
    try{Invoke-CcodSupervisorAdapter $Adapters.DisposeWorker @($slot) 0}catch{Add-CcodSupervisorCleanupCode $HostState.RuntimeCleanupCodes 'CCOD_SUPERVISOR_WORKER_DISPOSE_FAILED'}
    foreach($path in @($slot.RequestPath,$slot.ResultPath)){try{Invoke-CcodSupervisorAdapter $Adapters.DeleteWorkerFile @($path) 0}catch{Add-CcodSupervisorCleanupCode $HostState.RuntimeCleanupCodes 'CCOD_SUPERVISOR_WORKER_FILE_DELETE_FAILED'}}
    $HostState.LifecycleWorkerSlot=$null
}

function Stop-CcodSupervisorOwnedWorkerForShutdown {
    param($HostState,[hashtable]$Adapters,[ValidateSet('LifecycleWorkerSlot','WorkerSlot')][string]$PropertyName,[Collections.Generic.List[string]]$Codes)
    $slot=$HostState.$PropertyName;if($null-eq$slot){return $true}
    $proven=$false
    try{$waited=Invoke-CcodSupervisorAdapter $Adapters.WaitWorker @($slot,[int]2000) 1;if($waited-is[bool]-and$waited){$proven=$true}}catch{Add-CcodSupervisorCleanupCode $Codes 'CCOD_SUPERVISOR_WORKER_WAIT_FAILED'}
    for($attempt=0;$attempt-lt2-and-not$proven;$attempt++){
        try{$terminated=Invoke-CcodSupervisorAdapter $Adapters.TerminateWorker @($slot) 1;if($terminated-isnot[bool]){throw 'termination receipt'}}catch{Add-CcodSupervisorCleanupCode $Codes 'CCOD_SUPERVISOR_WORKER_TERMINATE_FAILED'}
        try{$waited=Invoke-CcodSupervisorAdapter $Adapters.WaitWorker @($slot,[int]5000) 1;if($waited-is[bool]-and$waited){$proven=$true}}catch{Add-CcodSupervisorCleanupCode $Codes 'CCOD_SUPERVISOR_WORKER_WAIT_FAILED'}
    }
    if(-not$proven){Add-CcodSupervisorCleanupCode $Codes 'CCOD_SUPERVISOR_WORKER_SURVIVED';return $false}
    if($PropertyName-ceq'LifecycleWorkerSlot'){Clear-CcodSupervisorLifecycleWorkerSlot $HostState $Adapters}else{Clear-CcodSupervisorWorkerSlot $HostState $Adapters}
    return $true
}

function Test-CcodSupervisorLifecycleTerminal {
    param([string]$Phase)
    return @('Completed','CloseFailed','OrdinaryLaunchFailed','OrdinaryObservationTimedOut','LaunchWindowExpired','RepairFailed','VerificationFailed','CancelledBeforeClose','SupersededByUpgrade') -ccontains $Phase
}

function Complete-CcodSupervisorLifecycleTerminal {
    param($HostState,[hashtable]$Adapters)
    $request=$HostState.LifecycleRequest
    if($null-eq$request -or -not(Test-CcodSupervisorLifecycleTerminal $request.phase)){throw 'lifecycle completion is not terminal'}
    $successful=$request.phase-ceq'Completed' -or ($request.phase-ceq'CancelledBeforeClose' -and $null-eq$request.error)
    if($request.kind-ceq'SafeExit' -and $successful){
        $markerWritten=$false
        try{
            Invoke-CcodSupervisorAdapter $Adapters.AssertLifecycleFence @($HostState.Layout.InstallRoot,$HostState.LifecycleOwnership) 1|Out-Null
            Invoke-CcodSupervisorAdapter $Adapters.WriteSafeExitIntent @($HostState.Layout.StateRoot,$HostState.LogonIdentity,$HostState.Layout.RuntimeId,$request.transactionId,(Get-CcodSupervisorNowUtc $Adapters)) 0|Out-Null
            $markerWritten=$true
            $HostState.ProtectionState='Stopping'
            Set-CcodSupervisorCurrentTrayPresentation $HostState $Adapters -WaitForAcknowledgement
            if(-not(Complete-CcodSupervisorLifecycleTrayAction $HostState $Adapters $request $true)){
                $HostState.ProtectionState='Running';$request.error='SAFE_EXIT_RECOVERY_FAILED'
                Invoke-CcodSupervisorAdapter $Adapters.WriteLifecycleRequest @($HostState.Layout.StateRoot,$request) 0
                return
            }
            Invoke-CcodSupervisorAdapter $Adapters.RequestUiExit @($HostState.Tray) 0
            Invoke-CcodSupervisorAdapter $Adapters.AssertLifecycleFence @($HostState.Layout.InstallRoot,$HostState.LifecycleOwnership) 1|Out-Null
            Invoke-CcodSupervisorAdapter $Adapters.CompleteLifecycleRequest @($HostState.Layout.StateRoot,$request) 0
            $HostState.ShutdownRequested=$true;$HostState.LifecycleRequest=$null
            return
        }catch{
            $HostState.ProtectionState='Running'
            $request.error='SAFE_EXIT_RECOVERY_FAILED'
            try{Invoke-CcodSupervisorAdapter $Adapters.WriteLifecycleRequest @($HostState.Layout.StateRoot,$request) 0}catch{}
            return
        }
    }
    Invoke-CcodSupervisorAdapter $Adapters.AssertLifecycleFence @($HostState.Layout.InstallRoot,$HostState.LifecycleOwnership) 1|Out-Null
    Invoke-CcodSupervisorAdapter $Adapters.CompleteLifecycleRequest @($HostState.Layout.StateRoot,$request) 0
    [void](Complete-CcodSupervisorLifecycleTrayAction $HostState $Adapters $request $successful)
    if(-not$successful){$HostState.ConnectionState='Error'}
    $HostState.ProtectionState='Running';$HostState.LifecycleRequest=$null
}

function Invoke-CcodSupervisorPollLifecycleSlot {
    param($HostState,[hashtable]$Adapters)
    $slot=$HostState.LifecycleWorkerSlot
    $poll=Invoke-CcodSupervisorAdapter $Adapters.PollWorker @($slot) 1
    if(-not(Test-CcodSupervisorExactProperties $poll @('Completed','ExitCode','StdoutText','StdoutByteCount','StdoutOverflow','StderrByteCount','StderrOverflow')) -or $poll.Completed-isnot[bool] -or $poll.StdoutText-isnot[string] -or $poll.StdoutByteCount-isnot[int] -or $poll.StderrByteCount-isnot[int]){Clear-CcodSupervisorLifecycleWorkerSlot $HostState $Adapters;throw 'lifecycle worker poll is invalid'}
    if(-not$poll.Completed){return}
    try{
        if($poll.ExitCode-isnot[int] -or @([int]0,[int]1)-cnotcontains$poll.ExitCode -or [string]::IsNullOrEmpty($poll.StdoutText) -or $poll.StdoutOverflow -or $poll.StderrOverflow -or $poll.StdoutByteCount-gt1048576 -or $poll.StderrByteCount-gt65536){throw 'lifecycle worker frame is invalid'}
        $exited=Invoke-CcodSupervisorAdapter $Adapters.WaitWorker @($slot,[int]2000) 1
        if($exited-isnot[bool]-or-not$exited){throw 'lifecycle worker exit is not proven'}
        $resumed=Invoke-CcodSupervisorAdapter $Adapters.ResumeLifecycleOwnership @($HostState.LifecycleOwnership,$HostState.Layout.InstallRoot,$HostState.Identity.UserSid,[int]$HostState.Identity.SessionId) 1
        if($resumed-isnot[bool]-or-not$resumed){throw 'lifecycle ownership reacquire receipt is invalid'}
        Invoke-CcodSupervisorAdapter $Adapters.AssertLifecycleFence @($HostState.Layout.InstallRoot,$HostState.LifecycleOwnership) 1|Out-Null
        $result=Invoke-CcodSupervisorAdapter $Adapters.ReadWorkerResult @($slot.ResultPath) 1
        $stdout=$poll.StdoutText|ConvertFrom-Json -ErrorAction Stop
        if(($stdout|ConvertTo-Json -Depth 16 -Compress)-cne($result|ConvertTo-Json -Depth 16 -Compress)){throw 'lifecycle worker frames differ'}
        Invoke-CcodSupervisorAdapter $Adapters.AssertLifecycleWorkerResult @($result,$slot.Request) 0
        $expectedExitCode=if($result.ok){[int]0}else{[int]1}
        if($poll.ExitCode-ne$expectedExitCode){throw 'lifecycle worker exit code does not match its result frame'}
        Invoke-CcodSupervisorAdapter $Adapters.AssertLifecycleFence @($HostState.Layout.InstallRoot,$HostState.LifecycleOwnership) 1|Out-Null
        $now=Get-CcodSupervisorNowUtc $Adapters
        $reduced=Invoke-CcodSupervisorAdapter $Adapters.ReduceLifecycleWorkerResult @($HostState.LifecycleRequest,$result,$now) 1
        Invoke-CcodSupervisorAdapter $Adapters.AssertLifecycleFence @($HostState.Layout.InstallRoot,$HostState.LifecycleOwnership) 1|Out-Null
        Invoke-CcodSupervisorAdapter $Adapters.WriteLifecycleRequest @($HostState.Layout.StateRoot,$reduced) 0
        $HostState.LifecycleRequest=$reduced;$HostState.LifecycleObservation=[string]$result.observation;$HostState.ConnectionState=ConvertTo-CcodSupervisorLifecycleObservation $HostState.LifecycleObservation
    }catch{$HostState.ConnectionState='Error';$HostState.ProtectionState='Running';throw}
    finally{Clear-CcodSupervisorLifecycleWorkerSlot $HostState $Adapters}
    if(Test-CcodSupervisorLifecycleTerminal $HostState.LifecycleRequest.phase){Complete-CcodSupervisorLifecycleTerminal $HostState $Adapters}
}

function Invoke-CcodSupervisorDriveLifecycle {
    param($HostState,[hashtable]$Adapters)
    if($null-eq$HostState.LifecycleRequest){return $false}
    if($HostState.LifecycleObservation-cne'Unknown'){$HostState.ConnectionState=ConvertTo-CcodSupervisorLifecycleObservation $HostState.LifecycleObservation}
    if($null-ne$HostState.LifecycleWorkerSlot){Invoke-CcodSupervisorPollLifecycleSlot $HostState $Adapters;return $true}
    if(Test-CcodSupervisorLifecycleTerminal $HostState.LifecycleRequest.phase){Complete-CcodSupervisorLifecycleTerminal $HostState $Adapters;return $true}
    $now=Get-CcodSupervisorNowUtc $Adapters
    $step=Invoke-CcodSupervisorAdapter $Adapters.GetLifecycleStep @($HostState.LifecycleRequest,$HostState.LifecycleObservation,$now) 1
    if(-not(Test-CcodSupervisorExactProperties $step @('kind','nextPhase','workerAction','deadlineUtc','errorCode')) -or $step.kind-isnot[string] -or $step.workerAction-isnot[string]){throw 'lifecycle step is invalid'}
    if($null-ne$step.nextPhase){
        Invoke-CcodSupervisorAdapter $Adapters.AssertLifecycleFence @($HostState.Layout.InstallRoot,$HostState.LifecycleOwnership) 1|Out-Null
        $moved=Invoke-CcodSupervisorAdapter $Adapters.MoveLifecyclePhase @($HostState.LifecycleRequest,[string]$step.nextPhase,$now) 1
        if($null-ne$step.errorCode){$moved.error=[string]$step.errorCode}
        Invoke-CcodSupervisorAdapter $Adapters.WriteLifecycleRequest @($HostState.Layout.StateRoot,$moved) 0
        $HostState.LifecycleRequest=$moved
        if(Test-CcodSupervisorLifecycleTerminal $moved.phase){Complete-CcodSupervisorLifecycleTerminal $HostState $Adapters;return $true}
    }
    if($step.workerAction-cne'None'){Start-CcodSupervisorLifecycleWorkerSlot $HostState $Adapters $step.workerAction $step.deadlineUtc|Out-Null}
    return $true
}

function Test-CcodSupervisorWorkerPaths {
    param($Paths,$WorkersRoot,[string]$Kind,[string]$RequestId)
    if(-not (Test-CcodSupervisorExactProperties $Paths @('RequestPath','ResultPath','StderrPath')) -or $RequestId -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'){return $false}
    $prefix=if($Kind -ceq 'Controller'){'controller'}elseif($Kind -ceq 'StaticProbe'){'static-probe'}else{return $false}
    $expected=@(
        "$prefix-$RequestId.request.json",
        "$prefix-$RequestId.result.json",
        $(if($Kind -ceq 'Controller'){"$prefix-$RequestId.stderr.log"}else{$null})
    )
    $values=@($Paths.RequestPath,$Paths.ResultPath,$Paths.StderrPath)
    for($index=0;$index -lt $values.Count;$index++){
        if($null -eq $expected[$index]){if($null -ne $values[$index]){return $false};continue}
        $full=$null;try{$full=[IO.Path]::GetFullPath($values[$index])}catch{return $false}
        if($values[$index] -isnot [string] -or -not [IO.Path]::IsPathRooted($values[$index]) -or $full -cne $values[$index] -or
           (Split-Path $full -Parent) -cne $WorkersRoot -or (Split-Path $full -Leaf) -cne $expected[$index]){return $false}
    }
    return $true
}

function New-CcodSupervisorWorkerPaths {
    param($HostState,[ValidateSet('Controller','StaticProbe')][string]$Kind,[string]$RequestId)
    $prefix=if($Kind -ceq 'Controller'){'controller'}else{'static-probe'}
    $root=$HostState.Layout.WorkersRoot
    $paths=[pscustomobject][ordered]@{
        RequestPath=[IO.Path]::GetFullPath((Join-Path $root "$prefix-$RequestId.request.json"))
        ResultPath=[IO.Path]::GetFullPath((Join-Path $root "$prefix-$RequestId.result.json"))
        StderrPath=$(if($Kind -ceq 'Controller'){[IO.Path]::GetFullPath((Join-Path $root "$prefix-$RequestId.stderr.log"))}else{$null})
    }
    if(-not (Test-CcodSupervisorWorkerPaths $paths $root $Kind $RequestId)){throw 'worker paths are invalid'}
    return $paths
}

function New-CcodSupervisorControllerRequest {
    param($HostState,[ValidateSet('Inspect','Apply','RepairStale','RepairRenderer','Recover')][string]$Action,$Target)
    $transactionId=if($Action -ceq 'Recover' -and $null -ne $HostState.Journal){$HostState.Journal.transactionId}else{[guid]::NewGuid().ToString('D')}
    if($transactionId -isnot [string] -or $transactionId -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'){throw 'transaction identity is invalid'}
    $source=$null
    if($Action -ceq 'Apply' -or $Action -ceq 'RepairStale'){
        if($null -eq $Target){
            if($Action -ceq 'RepairStale'){throw 'RepairStale target is required'}
            return [pscustomobject][ordered]@{
                schemaVersion=1;action=$Action;transactionId=$transactionId;runtimeId=$HostState.Layout.RuntimeId
                supervisorIdentity=[pscustomobject][ordered]@{pid=[int]$HostState.Identity.Pid;creationTimeUtc=$HostState.Identity.CreationTimeUtc;sessionId=$HostState.Identity.SessionId.ToString([Globalization.CultureInfo]::InvariantCulture)}
                source=$null;existingOnly=$false;rendererPort=$null;mainPort=$null;timeoutMilliseconds=[int]30000;restartOrdinary=$true
            }
        }
        $sourceFields=@('Pid','CreationTimeUtc','SessionId','UserSid','Path','PackageFamilyName','CommandLine','ParentPid','IsTopLevel','Mode','RendererPort','MainPort')
        $actual=@($Target.PSObject.Properties.Name)
        if($null -eq $Target -or ($Target -isnot [pscustomobject]) -or $actual.Count -ne $sourceFields.Count){throw "$Action target is invalid"}
        foreach($name in $sourceFields){if($actual -cnotcontains $name){throw "$Action target is invalid"}}
        if($Target.Pid -isnot [int] -or $Target.Pid -lt 1 -or -not (Test-CcodSupervisorCanonicalUtc $Target.CreationTimeUtc) -or
           $Target.SessionId -isnot [int] -or $Target.SessionId -lt 0 -or $Target.UserSid -isnot [string] -or [string]::IsNullOrWhiteSpace($Target.UserSid) -or
           $Target.Path -isnot [string] -or [string]::IsNullOrWhiteSpace($Target.Path) -or $Target.PackageFamilyName -isnot [string] -or [string]::IsNullOrWhiteSpace($Target.PackageFamilyName) -or
           $Target.CommandLine -isnot [string] -or
           ($null -ne $Target.ParentPid -and ($Target.ParentPid -isnot [int] -or $Target.ParentPid -lt 0)) -or
           $Target.IsTopLevel -isnot [bool] -or -not $Target.IsTopLevel){throw "$Action target is invalid"}
        if($Action -ceq 'Apply' -and ($Target.Mode -cne 'Ordinary' -or $null -ne $Target.RendererPort -or $null -ne $Target.MainPort)){throw 'Apply target is invalid'}
        if($Action -ceq 'RepairStale' -and ($Target.Mode -cne 'Unrelated' -or $Target.RendererPort -isnot [int] -or $Target.MainPort -isnot [int] -or
           $Target.RendererPort -lt 1 -or $Target.RendererPort -gt 65535 -or $Target.MainPort -lt 1 -or $Target.MainPort -gt 65535 -or
           $Target.RendererPort -eq $Target.MainPort)){throw 'RepairStale target is invalid'}
        $source=$Target
    }
    [pscustomobject][ordered]@{
        schemaVersion=1;action=$Action;transactionId=$transactionId;runtimeId=$HostState.Layout.RuntimeId
        supervisorIdentity=[pscustomobject][ordered]@{pid=[int]$HostState.Identity.Pid;creationTimeUtc=$HostState.Identity.CreationTimeUtc;sessionId=$HostState.Identity.SessionId.ToString([Globalization.CultureInfo]::InvariantCulture)}
        source=$source;existingOnly=$true;rendererPort=$null;mainPort=$null;timeoutMilliseconds=[int]30000;restartOrdinary=$true
    }
}

function New-CcodSupervisorStaticRequest {
    param($HostState,$Target,[string]$RequestId)
    if($null -eq $Target -or $Target.Pid -isnot [int] -or $Target.Pid -lt 1 -or -not (Test-CcodSupervisorCanonicalUtc $Target.CreationTimeUtc)){throw 'static target is invalid'}
    [pscustomobject][ordered]@{
        schemaVersion=1;action='StaticProbe';requestId=$RequestId;runtimeId=$HostState.Layout.RuntimeId
        supervisorIdentity=[pscustomobject][ordered]@{pid=[int]$HostState.Identity.Pid;creationTimeUtc=$HostState.Identity.CreationTimeUtc;sessionId=$HostState.Identity.SessionId.ToString([Globalization.CultureInfo]::InvariantCulture)}
        targetIdentity=[pscustomobject][ordered]@{pid=[int]$Target.Pid;creationTimeUtc=[string]$Target.CreationTimeUtc};timeoutMilliseconds=[int]30000
    }
}

function Start-CcodSupervisorWorkerSlot {
    param($HostState,[hashtable]$Adapters,[ValidateSet('Controller','StaticProbe')][string]$Kind,[string]$Action,$Target)
    if($null -ne $HostState.WorkerSlot){throw 'worker slot is occupied'}
    $requestId=[guid]::NewGuid().ToString('D')
    $paths=New-CcodSupervisorWorkerPaths $HostState $Kind $requestId
    $request=if($Kind -ceq 'StaticProbe'){New-CcodSupervisorStaticRequest $HostState $Target $requestId}else{New-CcodSupervisorControllerRequest $HostState $Action $Target}
    $ownedFiles=[Collections.Generic.List[string]]::new()
    try{
        foreach($path in @($paths.RequestPath,$paths.ResultPath,$paths.StderrPath)){
            if($null -eq $path){continue}
            $leaf=Invoke-CcodSupervisorAdapter $Adapters.GetWorkerLeafState @($path) 1
            if(-not (Test-CcodSupervisorExactProperties $leaf @('Exists','IsReparse')) -or $leaf.Exists -isnot [bool] -or $leaf.IsReparse -isnot [bool] -or $leaf.Exists -or $leaf.IsReparse){throw 'worker leaf is unsafe'}
        }
        Invoke-CcodSupervisorAdapter $Adapters.WriteWorkerRequest @($paths.RequestPath,$request) 0;$ownedFiles.Add($paths.RequestPath)
        $scriptPath=if($Kind -ceq 'StaticProbe'){$HostState.Layout.StaticWorkerPath}else{$HostState.Layout.ControllerPath}
        $started=Invoke-CcodSupervisorAdapter $Adapters.StartWorker @($Kind,$scriptPath,$paths.RequestPath,$paths.ResultPath,$paths.StderrPath,$request,$HostState.Layout.PowerShellPath) 1
        if(-not (Test-CcodSupervisorExactProperties $started @('ProcessId','CreationTimeUtc','Handle','JobHandle')) -or $started.ProcessId -isnot [int] -or $started.ProcessId -lt 1 -or
           -not (Test-CcodSupervisorCanonicalUtc $started.CreationTimeUtc) -or $null -eq $started.Handle -or $null-eq$started.JobHandle){throw 'worker start receipt is invalid'}
        $HostState.WorkerSlot=[pscustomobject][ordered]@{
            Kind=$Kind;Action=$request.action;RequestId=$requestId;RuntimeId=$HostState.Layout.RuntimeId;Request=$request
            RequestPath=$paths.RequestPath;ResultPath=$paths.ResultPath;StderrPath=$paths.StderrPath
            ProcessId=[int]$started.ProcessId;CreationTimeUtc=$started.CreationTimeUtc;Handle=$started.Handle;JobHandle=$started.JobHandle
        }
        return $HostState.WorkerSlot
    }catch{
        foreach($path in @($ownedFiles)){try{Invoke-CcodSupervisorAdapter $Adapters.DeleteWorkerFile @($path) 0}catch{}}
        throw
    }
}

function Clear-CcodSupervisorWorkerSlot {
    param($HostState,[hashtable]$Adapters)
    $slot=$HostState.WorkerSlot
    if($null -eq $slot){return}
    try{Invoke-CcodSupervisorAdapter $Adapters.DisposeWorker @($slot) 0}catch{Add-CcodSupervisorCleanupCode $HostState.RuntimeCleanupCodes 'CCOD_SUPERVISOR_WORKER_DISPOSE_FAILED'}
    foreach($path in @($slot.RequestPath,$slot.ResultPath,$slot.StderrPath)){
        if($null -eq $path){continue}
        try{Invoke-CcodSupervisorAdapter $Adapters.DeleteWorkerFile @($path) 0}catch{Add-CcodSupervisorCleanupCode $HostState.RuntimeCleanupCodes 'CCOD_SUPERVISOR_WORKER_FILE_DELETE_FAILED'}
    }
    $HostState.WorkerSlot=$null
}

function Write-CcodSupervisorRendererHandoffFailure {
    param($HostState,[hashtable]$Adapters)
    try{
        $record=[pscustomobject][ordered]@{schemaVersion=1;timestampUtc=[DateTime]::UtcNow.ToString('o',[Globalization.CultureInfo]::InvariantCulture);component='Supervisor';stage='RendererHandoff';code='CCOD_RENDERER_HANDOFF_FAILED';outcome='Failed'}
        Invoke-CcodSupervisorAdapter $Adapters.WriteLog @($record) 0
    }catch{}
    if($null -ne $HostState -and $HostState.SessionState -ceq 'Active'){$HostState.Reason='RendererHandoff'}
}

function Invoke-CcodSupervisorRendererHandoff {
    param($HostState,$Slot,$Result,[hashtable]$Adapters)
    try{
        if($null -eq $Result -or @('Apply','RepairStale','RepairRenderer','Recover') -cnotcontains $Slot.Action -or
           $null -eq $Result.PSObject.Properties['ok'] -or $Result.ok -isnot [bool] -or -not $Result.ok -or
           $null -eq $Result.PSObject.Properties['safeState'] -or $Result.safeState -cne 'SpecialValidated' -or
           $null -eq $Result.PSObject.Properties['special'] -or $null -eq $Result.special -or
           $null -eq $Result.special.PSObject.Properties['rendererPort']){return}
        $rendererPort=$Result.special.rendererPort
        if(($rendererPort -isnot [int] -and $rendererPort -isnot [long]) -or $rendererPort -lt 1 -or $rendererPort -gt 65535){return}
        $receipt=Invoke-CcodSupervisorAdapter $Adapters.HandoffRenderer @($Result,[int]$rendererPort) 1
        if(-not (Test-CcodSupervisorExactProperties $receipt @('Outcome','Code','ProcessId')) -or $receipt.Outcome -isnot [string] -or
           $receipt.Code -isnot [string] -or @('Started','Skipped','Failed') -cnotcontains $receipt.Outcome -or
           ($receipt.Outcome -ceq 'Failed')){Write-CcodSupervisorRendererHandoffFailure $HostState $Adapters}
    }catch{Write-CcodSupervisorRendererHandoffFailure $HostState $Adapters}
}

function Invoke-CcodSupervisorPollSlot {
    param($HostState,[hashtable]$Adapters)
    $slot=$HostState.WorkerSlot
    $staleRepairKey=$null
    if($slot.Kind -ceq 'Controller' -and $slot.Action -ceq 'RepairStale' -and $null -ne $slot.Request.source){
        $staleRepairKey=('{0}|{1}' -f $slot.Request.source.Pid,$slot.Request.source.CreationTimeUtc)
    }
    $poll=Invoke-CcodSupervisorAdapter $Adapters.PollWorker @($slot) 1
    $fields=@('Completed','ExitCode','StdoutText','StdoutByteCount','StdoutOverflow','StderrByteCount','StderrOverflow')
    if(-not (Test-CcodSupervisorExactProperties $poll $fields) -or $poll.Completed -isnot [bool] -or $poll.StdoutText -isnot [string] -or
       $poll.StdoutByteCount -isnot [int] -or $poll.StdoutByteCount -lt 0 -or $poll.StdoutOverflow -isnot [bool] -or
       $poll.StderrByteCount -isnot [int] -or $poll.StderrByteCount -lt 0 -or $poll.StderrOverflow -isnot [bool]){Clear-CcodSupervisorWorkerSlot $HostState $Adapters;return}
    if(-not $poll.Completed){return}
    try{
        if($poll.ExitCode -isnot [int] -or $poll.StdoutByteCount -gt 1048576 -or $poll.StderrByteCount -gt 65536 -or $poll.StdoutOverflow -or $poll.StderrOverflow){throw 'worker framing failed'}
        if(-not [string]::IsNullOrEmpty($poll.StdoutText)){
            $result=Invoke-CcodSupervisorNullableAdapter $Adapters.ReadWorkerResult @($slot.ResultPath)
            if($null -eq $result){throw 'worker result is missing'}
            $fromStdout=$poll.StdoutText|ConvertFrom-Json -ErrorAction Stop
            if(($fromStdout|ConvertTo-Json -Depth 20 -Compress) -cne ($result|ConvertTo-Json -Depth 20 -Compress)){throw 'worker frames differ'}
            if($slot.Kind -ceq 'Controller'){
                $expectedSource=if($slot.Action -ceq 'RepairStale'){$slot.Request.source}else{$null}
                $reduced=Invoke-CcodSupervisorAdapter $Adapters.CompleteControllerRun @($result,$slot.Request.transactionId,$slot.Action,$slot.RuntimeId,$expectedSource) 1
                if($null -ne $reduced){
                    $HostState.SessionState=[string]$reduced.SessionState
                    $HostState.BlockAutomaticActions=[bool]$reduced.BlockAutomaticActions
                    $HostState.Reason=[string]$reduced.Reason
                    if(-not [string]::IsNullOrWhiteSpace([string]$reduced.AttemptKey)){$HostState.AttemptKeys[[string]$reduced.AttemptKey]=$true}
                    if(-not [string]::IsNullOrWhiteSpace([string]$reduced.RecoveryIgnoreKey)){$HostState.RecoveryIgnoreKeys[[string]$reduced.RecoveryIgnoreKey]=$true}
                    if(-not [string]::IsNullOrWhiteSpace([string]$reduced.SuppressionKey)){$HostState.SuppressionKeys[[string]$reduced.SuppressionKey]=$true}
                    if($slot.Action -ceq 'RepairStale'){
                        if($reduced.SessionState -ceq 'Error' -or $reduced.BlockAutomaticActions){$HostState.FailedStaleRepairKey=$staleRepairKey}
                        elseif($HostState.FailedStaleRepairKey -ceq $staleRepairKey){$HostState.FailedStaleRepairKey=$null}
                    }
                    if($slot.Action -ceq 'Inspect'){
                        $HostState.SpecialNeedsInspect=$false
                        if($reduced.Reason -ceq 'StalePackageStatus' -and @($HostState.Special).Count -eq 1){$HostState.SpecialProof=$HostState.Special[0].Snapshot}
                    }
                }
                Invoke-CcodSupervisorRendererHandoff $HostState $slot $result $Adapters
            }elseif($slot.Kind -ceq 'StaticProbe'){
                if($result.ok -and $null -ne $result.probe){
                    if(-not (Test-CcodSupervisorStaticProbeResult $result $slot.Request)){$HostState.Classification='UnknownOrIncompatible';throw 'static probe framing failed'}
                    $HostState.PackageFullName=[string]$result.probe.packageFullName
                    $HostState.AppAsarSha256=[string]$result.probe.appAsarSha256
                    $HostState.Classification=[string]$result.probe.staticClassification
                    if($null -ne $slot.Request.targetIdentity){
                        $attemptKey=('{0}|{1}' -f $slot.Request.targetIdentity.pid,$slot.Request.targetIdentity.creationTimeUtc)
                        $HostState.StaticCache[$attemptKey]=$result
                    }
                }elseif($result.ok){
                    $HostState.Classification='UnknownOrIncompatible'
                    throw 'static probe framing failed'
                }else{
                    $HostState.Classification='UnknownOrIncompatible'
                }
            }
        }
    }catch{
        $HostState.SessionState='Error';$HostState.BlockAutomaticActions=$true;$HostState.Reason='WorkerFramingFailed'
        if($null -ne $staleRepairKey){$HostState.FailedStaleRepairKey=$staleRepairKey}
    }
    finally{Clear-CcodSupervisorWorkerSlot $HostState $Adapters}
}

function Get-CcodSupervisorResourcesRoot {
    if($null -eq $script:CcodSupervisorScriptPath){throw 'resources root is unavailable'}
    $root=[IO.Path]::GetFullPath((Join-Path (Split-Path $script:CcodSupervisorScriptPath -Parent) 'resources'))
    if(-not [IO.Path]::IsPathRooted($root)){throw 'resources root is invalid'}
    return $root
}

function Write-CcodSupervisorUiFailure {
    param($HostState,[hashtable]$Adapters,[ValidateSet('LanguageChange','LanguagePreferenceRollback','LanguageTrayRollback','ErrorDialog','TrayCallback')][string]$Stage,[string]$Code)
    try{
        $now=Invoke-CcodSupervisorAdapter $Adapters.GetUtcNow @() 1
        if($now -is [DateTimeOffset]){$timestamp=$now.UtcDateTime.ToString('o',[Globalization.CultureInfo]::InvariantCulture)}
        elseif($now -is [DateTime]){$timestamp=$now.ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture)}
        else{throw 'UI failure clock is invalid'}
        $record=[pscustomobject][ordered]@{schemaVersion=1;timestampUtc=$timestamp;component='Supervisor';stage=$Stage;code=$Code;outcome='Failed'}
        Invoke-CcodSupervisorAdapter $Adapters.WriteLog @($record) 0
    }catch{Add-CcodSupervisorCleanupCode $HostState.RuntimeCleanupCodes 'CCOD_SUPERVISOR_LOG_FAILED'}
}

function Set-CcodSupervisorCurrentTrayPresentation {
    param($HostState,[hashtable]$Adapters,[AllowNull()][string]$SystemCultureName=$null,[switch]$WaitForAcknowledgement)
    if($null -eq $HostState.Tray -or $HostState.UiLanguageMode -isnot [string] -or
       -not (Test-CcodSupervisorUiCatalog $HostState.UiCatalog $HostState.UiLanguageMode)){throw 'UI state is invalid'}
    $culture=$SystemCultureName
    if([string]::IsNullOrEmpty($culture)){$culture=Invoke-CcodSupervisorAdapter $Adapters.GetSystemCultureName @() 1}
    if(-not (Test-CcodSupervisorCultureName $culture)){throw 'UI culture is invalid'}
    $engine=New-CcodSupervisorEngineContext $HostState
    $connection=if(@('WaitingForCodex','Checking','Connected','RepairNeeded','Error') -ccontains $HostState.ConnectionState){$HostState.ConnectionState}else{'WaitingForCodex'}
    $lifecycleBusy=[bool]($null-ne$HostState.LifecycleWorkerSlot-or$null-ne$HostState.LifecycleRequest)
    $protection=if($HostState.ProtectionState-ceq'Stopping'){'Stopping'}elseif($lifecycleBusy){'Reconnecting'}elseif(@('Running','Reconnecting')-ccontains$HostState.ProtectionState){$HostState.ProtectionState}else{'Running'}
    $arguments=@{
        ConnectionState=$connection;ProtectionState=$protection
        Busy=[bool]($null-ne$HostState.WorkerSlot-or$lifecycleBusy-or$null-ne$HostState.Journal)
        StateDamageBlocksActions=[bool]$engine.StateDamageBlocksActions
    }
    $presentation=Invoke-CcodSupervisorAdapter $Adapters.GetTrayPresentation @($arguments) 1
    if($null -eq $presentation){throw 'tray presentation is invalid'}
    Invoke-CcodSupervisorAdapter $Adapters.SetTrayPresentation @($HostState.Tray,$presentation,$HostState.UiCatalog,$HostState.UiLanguageMode,$culture,[bool]$WaitForAcknowledgement) 0
    $HostState.LastAcknowledgedPresentation=$presentation
}

function Test-CcodSupervisorTrayAction {
    param($Action)
    return (Test-CcodSupervisorExactProperties $Action @('ActionId','Command','Revision')) -and $Action.ActionId-is[guid] -and $Action.ActionId-ne[guid]::Empty -and
        $Action.Command-is[string] -and @('CheckAndRepair','SetLanguageSystem','SetLanguageChinese','SetLanguageEnglish','OpenLogs','ShowAbout','Exit')-ccontains$Action.Command -and
        $Action.Revision-is[UInt64] -and $Action.Revision-gt0
}

function Throw-CcodSupervisorCommandError {
    param([string]$Code,[string]$Message,$Target)
    throw [Management.Automation.ErrorRecord]::new([InvalidOperationException]::new($Message),$Code,[Management.Automation.ErrorCategory]::InvalidData,$Target)
}

function Send-CcodSupervisorTrayActionResult {
    param($HostState,[hashtable]$Adapters,$Action,[ValidateSet('Accepted','Completed','Rejected','Failed')][string]$Status,[AllowNull()][string]$ErrorCode,[AllowNull()][string]$TransactionId)
    $result=[pscustomobject][ordered]@{ActionId=$Action.ActionId;Revision=[UInt64]$Action.Revision;Status=$Status;ErrorCode=$ErrorCode;TransactionId=$TransactionId}
    try{
        $delivered=Invoke-CcodSupervisorAdapter $Adapters.SendTrayActionResult @($HostState.Tray,$result.ActionId,$result.Revision,$result.Status,$result.ErrorCode,$result.TransactionId) 1
        if($delivered-isnot[bool]-or-not$delivered){throw 'tray action result was not acknowledged'}
        $result|Add-Member -NotePropertyName Delivered -NotePropertyValue $true
    }catch{$result|Add-Member -NotePropertyName Delivered -NotePropertyValue $false}
    return $result
}

function Complete-CcodSupervisorLifecycleTrayAction {
    param($HostState,[hashtable]$Adapters,$Request,[bool]$Successful,[AllowNull()][string]$FailureCode='CCOD_LIFECYCLE_ACTION_FAILED')
    foreach($key in @($HostState.TrayActionIds.Keys)){
        $entry=$HostState.TrayActionIds[$key]
        if($null-eq$entry-or$null-eq$entry.PSObject.Properties['Action']-or$null-eq$entry.PSObject.Properties['TransactionId']-or$null-eq$entry.PSObject.Properties['TerminalSent']){continue}
        if($entry.TerminalSent-or$entry.TransactionId-cne$Request.transactionId){continue}
        try{
            $status=if($Successful){'Completed'}else{'Failed'}
            $code=if($Successful){$null}else{$FailureCode}
            $delivery=Send-CcodSupervisorTrayActionResult $HostState $Adapters $entry.Action $status $code $entry.TransactionId
            if(-not$delivery.Delivered){return $false}
            $entry.TerminalSent=$true
        }catch{Write-CcodSupervisorUiFailure $HostState $Adapters 'ErrorDialog' 'CCOD_TRAY_ACTION_RESULT_FAILED'}
    }
    return $true
}

function Test-CcodSupervisorTrayActionBusy {
    param($HostState)
    $engine=New-CcodSupervisorEngineContext $HostState
    return [bool]($null-ne$HostState.WorkerSlot-or$null-ne$HostState.LifecycleWorkerSlot-or$null-ne$HostState.LifecycleRequest-or$null-ne$HostState.Journal-or$engine.StateDamageBlocksActions)
}

function Invoke-CcodSupervisorLanguageAction {
    param($HostState,[hashtable]$Adapters,$Action,[string]$Mode)
    $oldMode=$HostState.UiLanguageMode;$oldCatalog=$HostState.UiCatalog;$persisted=$false;$culture=$null
    try{
        $culture=Invoke-CcodSupervisorAdapter $Adapters.GetSystemCultureName @() 1
        if(-not(Test-CcodSupervisorCultureName $culture)){throw 'UI culture is invalid'}
        $newCatalog=Invoke-CcodSupervisorAdapter $Adapters.GetUiCatalog @((Get-CcodSupervisorResourcesRoot),$Mode,$culture) 1
        if(-not(Test-CcodSupervisorUiCatalog $newCatalog $Mode)){throw 'UI catalog is invalid'}
        Invoke-CcodSupervisorAdapter $Adapters.SetUiLanguageMode @($HostState.Layout.StateRoot,$Mode) 0
        $persisted=$true;$HostState.UiLanguageMode=$Mode;$HostState.UiCatalog=$newCatalog
        Set-CcodSupervisorCurrentTrayPresentation $HostState $Adapters $culture -WaitForAcknowledgement
        return Send-CcodSupervisorTrayActionResult $HostState $Adapters $Action Completed $null $null
    }catch{
        if($persisted){try{Invoke-CcodSupervisorAdapter $Adapters.SetUiLanguageMode @($HostState.Layout.StateRoot,$oldMode) 0}catch{}}
        $HostState.UiLanguageMode=$oldMode;$HostState.UiCatalog=$oldCatalog
        if($null-ne$culture){try{Set-CcodSupervisorCurrentTrayPresentation $HostState $Adapters $culture -WaitForAcknowledgement}catch{}}
        Write-CcodSupervisorUiFailure $HostState $Adapters 'LanguageChange' 'CCOD_LANGUAGE_CHANGE_ROLLED_BACK'
        return Send-CcodSupervisorTrayActionResult $HostState $Adapters $Action Failed 'CCOD_LANGUAGE_CHANGE_ROLLED_BACK' $null
    }
}

function Invoke-CcodSupervisorCommand {
    param($HostState,[hashtable]$Adapters,$Command)
    if(-not(Test-CcodSupervisorTrayAction $Command)){Throw-CcodSupervisorCommandError 'CCOD_SUPERVISOR_COMMAND_INVALID' 'Tray action is invalid' $Command}
    $revisionProperty=$HostState.Tray.PSObject.Properties['CurrentRevision']
    if($null-eq$revisionProperty-or$revisionProperty.Value-isnot[UInt64]-or$revisionProperty.Value-eq0-or[UInt64]$revisionProperty.Value-ne[UInt64]$Command.Revision){return Send-CcodSupervisorTrayActionResult $HostState $Adapters $Command Rejected 'CCOD_TRAY_ACTION_STALE' $null}
    if($HostState.TrayActionIds.Contains($Command.ActionId.ToString('D'))){Throw-CcodSupervisorCommandError 'CCOD_SUPERVISOR_COMMAND_INVALID' 'Tray action was already handled' $Command}
    $actionEntry=[pscustomobject][ordered]@{Action=$Command;TransactionId=$null;TerminalSent=$false}
    $HostState.TrayActionIds[$Command.ActionId.ToString('D')]=$actionEntry
    $busy=Test-CcodSupervisorTrayActionBusy $HostState
    switch($Command.Command){
        'CheckAndRepair' {
            if($busy-or$HostState.ConnectionState-cne'RepairNeeded'){return Send-CcodSupervisorTrayActionResult $HostState $Adapters $Command Rejected 'CCOD_TRAY_ACTION_UNAVAILABLE' $null}
            if(-not(New-CcodSupervisorInternalLifecycleRequest $HostState $Adapters CheckAndRepair Tray)){return Send-CcodSupervisorTrayActionResult $HostState $Adapters $Command Rejected 'CCOD_LIFECYCLE_SUPERVISOR_BUSY' $null}
            $actionEntry.TransactionId=$HostState.LifecycleRequest.transactionId
            return Send-CcodSupervisorTrayActionResult $HostState $Adapters $Command Accepted $null $HostState.LifecycleRequest.transactionId
        }
        'Exit' {
            $presentation=$HostState.PSObject.Properties['LastAcknowledgedPresentation']
            if($busy-or$null-eq$presentation-or$null-eq$presentation.Value-or$presentation.Value.ExitEnabled-isnot[bool]-or-not$presentation.Value.ExitEnabled){return Send-CcodSupervisorTrayActionResult $HostState $Adapters $Command Rejected 'CCOD_TRAY_ACTION_UNAVAILABLE' $null}
            if(-not(New-CcodSupervisorInternalLifecycleRequest $HostState $Adapters SafeExit Tray)){return Send-CcodSupervisorTrayActionResult $HostState $Adapters $Command Rejected 'CCOD_LIFECYCLE_SUPERVISOR_BUSY' $null}
            $actionEntry.TransactionId=$HostState.LifecycleRequest.transactionId
            return Send-CcodSupervisorTrayActionResult $HostState $Adapters $Command Accepted $null $HostState.LifecycleRequest.transactionId
        }
        'SetLanguageSystem' {if($busy){return Send-CcodSupervisorTrayActionResult $HostState $Adapters $Command Rejected 'CCOD_TRAY_ACTION_UNAVAILABLE' $null};return Invoke-CcodSupervisorLanguageAction $HostState $Adapters $Command System}
        'SetLanguageChinese' {if($busy){return Send-CcodSupervisorTrayActionResult $HostState $Adapters $Command Rejected 'CCOD_TRAY_ACTION_UNAVAILABLE' $null};return Invoke-CcodSupervisorLanguageAction $HostState $Adapters $Command zh-CN}
        'SetLanguageEnglish' {if($busy){return Send-CcodSupervisorTrayActionResult $HostState $Adapters $Command Rejected 'CCOD_TRAY_ACTION_UNAVAILABLE' $null};return Invoke-CcodSupervisorLanguageAction $HostState $Adapters $Command en-US}
        'OpenLogs' {
            try{Invoke-CcodSupervisorAdapter $Adapters.OpenLogs @($HostState.Layout.LogDirectory) 0;return Send-CcodSupervisorTrayActionResult $HostState $Adapters $Command Completed $null $null}
            catch{return Send-CcodSupervisorTrayActionResult $HostState $Adapters $Command Failed 'CCOD_TRAY_ACTION_FAILED' $null}
        }
        'ShowAbout' {
            try{
                $about=Invoke-CcodSupervisorAdapter $Adapters.VerifyActiveRuntimeForAbout @($HostState.Layout.InstallRoot,$HostState.Layout.RuntimeId) 1
                if(-not(Test-CcodSupervisorExactProperties $about @('RuntimeId','Version'))-or$about.RuntimeId-cne$HostState.Layout.RuntimeId-or$about.Version-isnot[string]-or$about.Version-cnotmatch'^\d+\.\d+\.\d+$'){throw 'about runtime is invalid'}
                Set-CcodSupervisorCurrentTrayPresentation $HostState $Adapters $null -WaitForAcknowledgement
                return Send-CcodSupervisorTrayActionResult $HostState $Adapters $Command Completed $null $null
            }catch{return Send-CcodSupervisorTrayActionResult $HostState $Adapters $Command Failed 'CCOD_TRAY_ACTION_FAILED' $null}
        }
        default {return Send-CcodSupervisorTrayActionResult $HostState $Adapters $Command Rejected 'CCOD_TRAY_ACTION_UNAVAILABLE' $null}
    }
}

function New-CcodSupervisorEngineContext {
    param($HostState)
    $state=$HostState.State
    $automation=$false;if($null-ne$state.PSObject.Properties['AutomationEnabled']-and$state.AutomationEnabled-is[bool]){$automation=[bool]$state.AutomationEnabled}
    $candidate=$false;if($null-ne$state.PSObject.Properties['Settings']-and$null-ne$state.Settings-and$null-ne$state.Settings.PSObject.Properties['candidateCompatibleOptIn']-and$state.Settings.candidateCompatibleOptIn-is[bool]){$candidate=[bool]$state.Settings.candidateCompatibleOptIn}
    $verified=if($null -ne $state.PSObject.Properties['VerifiedPackages']){$state.VerifiedPackages}else{$null}
    $damaged=$null -eq $verified
    if($null -ne $state.PSObject.Properties['Damage'] -and $null -ne $state.Damage){$damaged=$damaged -or @($state.Damage.PSObject.Properties).Count -gt 0}
    [pscustomobject][ordered]@{
        AutomationEnabled=$automation;CandidateCompatibleOptIn=$candidate
        AutomaticCandidateTrialsAllowed=$(if($null -ne $state.PSObject.Properties['AutomaticCandidateTrialsAllowed']){[bool]$state.AutomaticCandidateTrialsAllowed}else{$false})
        StateDamageBlocksActions=[bool]$damaged;ControllerRunning=[bool]($null -ne $HostState.WorkerSlot);ActiveTransaction=$HostState.Journal
        CurrentUserSid=$HostState.Identity.UserSid;CurrentSessionId=[int]$HostState.Identity.SessionId;RuntimeId=$HostState.Layout.RuntimeId
        PackageFullName=$HostState.PackageFullName;AppAsarSha256=$HostState.AppAsarSha256;Classification=$HostState.Classification;VerifiedPackages=$verified
        Ordinary=[object[]]@($HostState.Ordinary);Special=[object[]]@($HostState.Special)
        AttemptKeys=$HostState.AttemptKeys;RecoveryIgnoreKeys=$HostState.RecoveryIgnoreKeys;SuppressionKeys=$HostState.SuppressionKeys
    }
}

function Get-CcodSupervisorExactVerifiedRecord {
    param($Packages,[string]$Key)
    if($null -eq $Packages -or $Packages -isnot [pscustomobject] -or $Key -isnot [string]){return $null}
    foreach($property in @($Packages.PSObject.Properties)){if($property.Name -ceq $Key){return $property.Value}}
    return $null
}

function Get-CcodSupervisorExpectedStaleExecutablePath {
    param($LivePackage,[string]$StalePackageFullName)
    try{
        if($null -eq $LivePackage -or $StalePackageFullName -isnot [string] -or [string]::IsNullOrWhiteSpace($StalePackageFullName) -or
           [IO.Path]::IsPathRooted($StalePackageFullName) -or $StalePackageFullName.IndexOfAny([char[]]@('\','/',':')) -ge 0 -or
           [IO.Path]::GetFileName($StalePackageFullName) -cne $StalePackageFullName -or
           $LivePackage.FullName -isnot [string] -or [string]::IsNullOrWhiteSpace($LivePackage.FullName) -or
           $LivePackage.InstallLocation -isnot [string] -or [string]::IsNullOrWhiteSpace($LivePackage.InstallLocation) -or
           $LivePackage.ExecutablePath -isnot [string] -or [string]::IsNullOrWhiteSpace($LivePackage.ExecutablePath) -or
           -not [IO.Path]::IsPathRooted($LivePackage.InstallLocation) -or -not [IO.Path]::IsPathRooted($LivePackage.ExecutablePath)){return $null}
        $liveInstall=[IO.Path]::GetFullPath($LivePackage.InstallLocation).TrimEnd([char[]]@('\','/'))
        if([string]::IsNullOrWhiteSpace($liveInstall) -or [IO.Path]::GetFileName($liveInstall) -cne $LivePackage.FullName){return $null}
        $liveExecutable=[IO.Path]::GetFullPath($LivePackage.ExecutablePath)
        $expectedLiveExecutable=[IO.Path]::GetFullPath([IO.Path]::Combine($liveInstall,'app','ChatGPT.exe'))
        if(-not [string]::Equals($liveExecutable,$expectedLiveExecutable,[StringComparison]::OrdinalIgnoreCase)){return $null}
        $packageRoot=[IO.Path]::GetDirectoryName($liveInstall)
        if([string]::IsNullOrWhiteSpace($packageRoot)){return $null}
        $oldInstall=[IO.Path]::GetFullPath([IO.Path]::Combine($packageRoot,$StalePackageFullName))
        if(-not [string]::Equals([IO.Path]::GetDirectoryName($oldInstall),$packageRoot,[StringComparison]::OrdinalIgnoreCase)){return $null}
        return [IO.Path]::GetFullPath([IO.Path]::Combine($oldInstall,'app','ChatGPT.exe'))
    }catch{return $null}
}

function Test-CcodSupervisorExactStaleLaunch {
    param($Snapshot,[string]$ExpectedExecutablePath,[int]$RendererPort,[int]$MainPort,[hashtable]$Adapters)
    try{
        if($null -eq $Snapshot -or $Snapshot.CommandLine -isnot [string] -or [string]::IsNullOrWhiteSpace($Snapshot.CommandLine) -or
           $Adapters -isnot [hashtable] -or $Adapters.ParseStaleCandidateCommandLine -isnot [scriptblock]){return $false}
        $capture=Invoke-CcodSupervisorAdapterCapture $Adapters.ParseStaleCandidateCommandLine @($Snapshot.CommandLine)
        if($capture.Threw -or $capture.Items.Count -ne 4){return $false}
        $expected=@($ExpectedExecutablePath,'--remote-debugging-address=127.0.0.1',("--remote-debugging-port={0}" -f $RendererPort),("--inspect=127.0.0.1:{0}" -f $MainPort))
        for($index=0;$index -lt $expected.Count;$index++){
            $actual=$capture.Items[$index]
            if(Test-CcodSupervisorDiagnosticRecord $actual -or $actual -isnot [string]){return $false}
            if($index -eq 0){if(-not [string]::Equals($actual,$expected[$index],[StringComparison]::OrdinalIgnoreCase)){return $false}}
            elseif($actual -cne $expected[$index]){return $false}
        }
        return $true
    }catch{return $false}
}

function Get-CcodSupervisorStaleReconciliationCandidate {
    param($State,$Snapshot,$LivePackage,$Identity,[hashtable]$Adapters)
    try{
        if($null -eq $State -or $null -eq $Snapshot -or $null -eq $LivePackage -or $null -eq $Identity -or
           -not(Test-CcodSupervisorExactProperties $State.Status @('schemaVersion','session')) -or $State.Status.schemaVersion -isnot [int] -or $State.Status.schemaVersion -ne 1 -or
           -not(Test-CcodSupervisorExactProperties $State.Status.session @('supervisorPid','supervisorCreationTimeUtc','sessionId','runtimeId','sessionState','codex')) -or
           $State.Status.session.sessionState -cne 'Active' -or $State.Status.session.sessionId -cne $Identity.SessionId.ToString([Globalization.CultureInfo]::InvariantCulture) -or
           -not(Test-CcodSupervisorExactProperties $State.Status.session.codex @('pid','creationTimeUtc','packageFullName','packageVersion','appAsarSha256','mainPort','rendererPort','mainProbe','rendererProbe'))){return $null}
        $codex=$State.Status.session.codex
        if($codex.pid -isnot [int] -or $codex.pid -lt 1 -or -not(Test-CcodSupervisorCanonicalUtc $codex.creationTimeUtc) -or
           $codex.packageFullName -isnot [string] -or [string]::IsNullOrWhiteSpace($codex.packageFullName) -or $codex.packageVersion -isnot [string] -or [string]::IsNullOrWhiteSpace($codex.packageVersion) -or
           $codex.appAsarSha256 -isnot [string] -or $codex.appAsarSha256 -cnotmatch '^[0-9a-f]{64}$' -or $codex.mainPort -isnot [int] -or $codex.rendererPort -isnot [int] -or
           $codex.mainPort -lt 1 -or $codex.mainPort -gt 65535 -or $codex.rendererPort -lt 1 -or $codex.rendererPort -gt 65535 -or $codex.mainPort -eq $codex.rendererPort -or
           $codex.mainProbe -cne 'Closed' -or $codex.rendererProbe -cne 'BridgeValid'){return $null}
        if($LivePackage.Found -isnot [bool] -or -not $LivePackage.Found -or $LivePackage.FullName -isnot [string] -or [string]::IsNullOrWhiteSpace($LivePackage.FullName) -or
           $LivePackage.FamilyName -isnot [string] -or [string]::IsNullOrWhiteSpace($LivePackage.FamilyName) -or $LivePackage.Version -isnot [string] -or [string]::IsNullOrWhiteSpace($LivePackage.Version) -or
           $LivePackage.InstallLocation -isnot [string] -or [string]::IsNullOrWhiteSpace($LivePackage.InstallLocation) -or $LivePackage.ExecutablePath -isnot [string] -or [string]::IsNullOrWhiteSpace($LivePackage.ExecutablePath) -or
           ($LivePackage.FullName -ceq $codex.packageFullName -and $LivePackage.Version -ceq $codex.packageVersion)){return $null}
        $expectedOldExecutable=Get-CcodSupervisorExpectedStaleExecutablePath $LivePackage $codex.packageFullName
        if($expectedOldExecutable -isnot [string]){return $null}
        $key=('{0}|{1}|{2}' -f $codex.packageFullName,$codex.appAsarSha256,$State.Status.session.runtimeId)
        if($null -eq $State.VerifiedPackages -or -not(Test-CcodSupervisorExactProperties $State.VerifiedPackages @('schemaVersion','packages')) -or $State.VerifiedPackages.schemaVersion -isnot [int] -or $State.VerifiedPackages.schemaVersion -ne 1){return $null}
        $record=Get-CcodSupervisorExactVerifiedRecord $State.VerifiedPackages.packages $key
        if(-not(Test-CcodSupervisorExactProperties $record @('packageFullName','packageVersion','appAsarSha256','runtimeId','staticClassification','dynamicOutcome','probeState','confirmedAtUtc')) -or
           $record.packageFullName -cne $codex.packageFullName -or $record.packageVersion -cne $codex.packageVersion -or $record.appAsarSha256 -cne $codex.appAsarSha256 -or
           $record.runtimeId -cne $State.Status.session.runtimeId -or $record.staticClassification -cne 'CandidateCompatible' -or $record.dynamicOutcome -cne 'Succeeded' -or $record.probeState -cne 'Valid' -or
           -not(Test-CcodSupervisorCanonicalUtc $record.confirmedAtUtc)){return $null}
        if(-not(Test-CcodSupervisorExactProperties $Snapshot @('Pid','CreationTimeUtc','SessionId','UserSid','Path','PackageFamilyName','CommandLine','ParentPid','IsTopLevel','Mode','RendererPort','MainPort')) -or
           $Snapshot.Pid -isnot [int] -or $Snapshot.Pid -ne $codex.pid -or $Snapshot.CreationTimeUtc -isnot [string] -or $Snapshot.CreationTimeUtc -cne $codex.creationTimeUtc -or
           $Snapshot.SessionId -isnot [int] -or $Snapshot.SessionId -ne $Identity.SessionId -or $Snapshot.UserSid -isnot [string] -or $Snapshot.UserSid -cne $Identity.UserSid -or
           $Snapshot.Path -isnot [string] -or -not [string]::Equals($Snapshot.Path,$expectedOldExecutable,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($Snapshot.Path) -ine 'ChatGPT.exe' -or $Snapshot.PackageFamilyName -isnot [string] -or $Snapshot.PackageFamilyName -cne $LivePackage.FamilyName -or
           $Snapshot.ParentPid -isnot [int] -or $Snapshot.ParentPid -lt 0 -or $Snapshot.IsTopLevel -isnot [bool] -or $Snapshot.IsTopLevel -or $Snapshot.Mode -cne 'Unrelated' -or $null -ne $Snapshot.RendererPort -or $null -ne $Snapshot.MainPort -or
           -not(Test-CcodSupervisorExactStaleLaunch $Snapshot $expectedOldExecutable $codex.rendererPort $codex.mainPort $Adapters)){return $null}
        return [pscustomobject][ordered]@{
            Pid=[int]$Snapshot.Pid;CreationTimeUtc=[string]$Snapshot.CreationTimeUtc;SessionId=[int]$Snapshot.SessionId;UserSid=[string]$Snapshot.UserSid
            Path=[string]$Snapshot.Path;PackageFamilyName=[string]$Snapshot.PackageFamilyName;CommandLine=[string]$Snapshot.CommandLine;ParentPid=[int]$Snapshot.ParentPid
            IsTopLevel=$true;Mode='Unrelated';RendererPort=[int]$codex.rendererPort;MainPort=[int]$codex.mainPort
        }
    }catch{return $null}
}

function Invoke-CcodSupervisorRefreshObservations {
    param($HostState,[hashtable]$Adapters)
    $ids=Invoke-CcodSupervisorAdapter $Adapters.EnumerateProcessIds @() 1
    if($ids -isnot [array]){throw 'process enumeration is invalid'}
    $statusEvidence=if($null -ne $HostState.State -and $null -ne $HostState.State.PSObject.Properties['Status']){$HostState.State.Status}else{$null}
    $ordinary=[Collections.Generic.List[object]]::new();$special=[Collections.Generic.List[object]]::new();$staleCandidates=[Collections.Generic.List[object]]::new();$livePackage=$null;$livePackageRead=$false
    foreach($pidValue in @($ids|Select-Object -First 256)){
        if($pidValue -isnot [int] -or $pidValue -lt 1){continue}
        $snapshot=Invoke-CcodSupervisorNullableAdapter $Adapters.GetProcessSnapshot @([int]$pidValue,$statusEvidence)
        if($null -eq $snapshot){continue}
        if($snapshot.UserSid -cne $HostState.Identity.UserSid -or $snapshot.SessionId -ne $HostState.Identity.SessionId){continue}
        if($snapshot.Mode -ceq 'Ordinary' -and $snapshot.IsTopLevel){$ordinary.Add($snapshot)}
        elseif($snapshot.Mode -ceq 'Special' -and $snapshot.IsTopLevel){$special.Add([pscustomobject][ordered]@{Snapshot=$snapshot;IdentityValid=$true;ProbeValid=$false})}
        elseif($snapshot.Mode -ceq 'Unrelated'){
            if(-not $livePackageRead){$livePackage=Invoke-CcodSupervisorNullableAdapter $Adapters.GetPackageIdentity @();$livePackageRead=$true}
            $candidate=Get-CcodSupervisorStaleReconciliationCandidate $HostState.State $snapshot $livePackage $HostState.Identity $Adapters
            if($null -ne $candidate){$staleCandidates.Add($candidate)}
        }
    }
    $proofMatches=$false
    if($special.Count -eq 1 -and $null -ne $HostState.SpecialProof -and
       $null -ne $HostState.SpecialProof.PSObject.Properties['Pid'] -and $null -ne $HostState.SpecialProof.PSObject.Properties['CreationTimeUtc'] -and
       $HostState.SpecialProof.Pid -eq $special[0].Snapshot.Pid -and $HostState.SpecialProof.CreationTimeUtc -ceq $special[0].Snapshot.CreationTimeUtc){$proofMatches=$true}
    if(-not $proofMatches){$HostState.SpecialProof=$null}
    $HostState.Ordinary=[object[]]@($ordinary);$HostState.Special=[object[]]@($special)
    $HostState.StaleReconciliationCandidate=if($ordinary.Count -eq 0 -and $special.Count -eq 0 -and $staleCandidates.Count -eq 1){$staleCandidates[0]}else{$null}
    $HostState.SpecialNeedsInspect=$special.Count -gt 0 -and $null -eq $HostState.SpecialProof
    $HostState.LifecycleObservation=if($ordinary.Count-eq1 -and $special.Count-eq0){'Ordinary'}elseif($ordinary.Count-eq0 -and $special.Count-eq1 -and $null-ne$HostState.SpecialProof){'RemoteVerified'}elseif($ordinary.Count-eq0 -and $special.Count-eq1){'Special'}elseif($ordinary.Count-eq0 -and $special.Count-eq0){'NoCodex'}else{'Error'}
    $HostState.ConnectionState=ConvertTo-CcodSupervisorLifecycleObservation $HostState.LifecycleObservation
}

function Invoke-CcodSupervisorTick {
    param($HostState,[hashtable]$Adapters,[bool]$MenuOpenOnly=$false)
    if($null -eq $HostState -or $HostState.ShutdownRequested){return}
    $signaled=Invoke-CcodSupervisorAdapter $Adapters.IsEventSignaled @($HostState.ShutdownEvent) 1
    if($signaled -isnot [bool]){throw 'shutdown state is invalid'}
    if($signaled){
        $HostState.ShutdownRequested=$true
        Invoke-CcodSupervisorAdapter $Adapters.RequestUiExit @($HostState.Tray) 0
        return
    }
    if(-not $HostState.TrayCallbackFailureLogged -and $null -ne $HostState.Tray -and $null -ne $HostState.Tray.PSObject.Properties['CallbackFailure'] -and
       $HostState.Tray.CallbackFailure -is [bool] -and $HostState.Tray.CallbackFailure){
        $HostState.TrayCallbackFailureLogged=$true
        Write-CcodSupervisorUiFailure $HostState $Adapters 'TrayCallback' 'CCOD_TRAY_CALLBACK_FAILED'
    }
    if($MenuOpenOnly){return}
    Receive-CcodSupervisorLifecycleSubmission $HostState $Adapters
    if($null-ne$HostState.LifecycleWorkerSlot){Invoke-CcodSupervisorPollLifecycleSlot $HostState $Adapters;return}
    if($null-ne$HostState.LifecycleRequest){
        if($null-ne$HostState.WorkerSlot){Invoke-CcodSupervisorPollSlot $HostState $Adapters;return}
        if($HostState.LifecycleObservation-ceq'Unknown' -or $HostState.ObservationDirty -or $HostState.ForceReconcile){
            Invoke-CcodSupervisorRefreshObservations $HostState $Adapters
            $HostState.ObservationDirty=$false;$HostState.ForceReconcile=$false
        }
        [void](Invoke-CcodSupervisorDriveLifecycle $HostState $Adapters)
        return
    }
    if($null -ne $HostState.WorkerSlot){
        Invoke-CcodSupervisorPollSlot $HostState $Adapters
        if($null -eq $HostState.WorkerSlot){$HostState.ObservationDirty=$true}
        return
    }
    $elapsed=Invoke-CcodSupervisorAdapter $Adapters.GetElapsedMilliseconds @($HostState.Clock) 1
    if(($elapsed -isnot [int] -and $elapsed -isnot [long]) -or $elapsed -lt 0){throw 'observation clock is invalid'}
    $observationDue=$HostState.ObservationDirty -or $HostState.ForceReconcile -or [long]$elapsed -ge [long]$HostState.NextObservationMilliseconds
    if(-not $observationDue){
        if($null -ne $HostState.Journal){$HostState.SessionState='Error';$HostState.BlockAutomaticActions=$true;$HostState.Reason='LegacyTransitionBlocked';$HostState.ConnectionState='Error';return}
        if($HostState.SpecialNeedsInspect){[void](New-CcodSupervisorInternalLifecycleRequest $HostState $Adapters CheckAndRepair Guardian);return}
        $queueArgument=[object[]]::new(1);$queueArgument[0]=$HostState.CommandQueue
        $dequeued=Invoke-CcodSupervisorAdapter $Adapters.TryDequeue $queueArgument 1
        if(-not (Test-CcodSupervisorExactProperties $dequeued @('Succeeded','Value')) -or $dequeued.Succeeded -isnot [bool]){throw 'command queue receipt is invalid'}
        if($dequeued.Succeeded){
            $forceBefore=[bool]$HostState.ForceReconcile
            [void](Invoke-CcodSupervisorCommand $HostState $Adapters $dequeued.Value)
            if(-not $forceBefore -and $HostState.ForceReconcile){$HostState.ObservationDirty=$true}
        }
        return
    }
    $observationDeadline=[long]$HostState.NextObservationMilliseconds
    if($observationDeadline -le 0){$observationDeadline=1000}
    while($observationDeadline -le [long]$elapsed){$observationDeadline+=1000}
    $HostState.NextObservationMilliseconds=$observationDeadline;$HostState.ObservationDirty=$false
    $readStateArguments=[object[]]::new(2)
    $readStateArguments[0]=$HostState.Layout.StateRoot
    if(-not [string]::IsNullOrWhiteSpace([string]$HostState.PackageFullName) -and
       -not [string]::IsNullOrWhiteSpace([string]$HostState.AppAsarSha256)){
        $readStateArguments[1]=('{0}|{1}|{2}' -f $HostState.PackageFullName,$HostState.AppAsarSha256,$HostState.Layout.RuntimeId)
    }else{
        $readStateArguments[1]=$null
    }
    $HostState.State=Invoke-CcodSupervisorAdapter $Adapters.ReadState $readStateArguments 1
    if($null -eq $HostState.State){throw 'state read is invalid'}
    $HostState.Journal=Invoke-CcodSupervisorNullableAdapter $Adapters.ReadJournal @($HostState.Layout.TransitionPath)
    if($null -ne $HostState.Journal){$HostState.SessionState='Error';$HostState.BlockAutomaticActions=$true;$HostState.Reason='LegacyTransitionBlocked';$HostState.ConnectionState='Error';return}
    if($HostState.Reason -ceq 'StalePackageStatus' -and ($null -ne $HostState.SpecialProof -or $null -ne $HostState.StaleReconciliationCandidate)){
        if($HostState.ForceReconcile -or [long]$elapsed -ge $HostState.NextReconcileMilliseconds){
            Invoke-CcodSupervisorRefreshObservations $HostState $Adapters
            $deadline=[long]$HostState.NextReconcileMilliseconds
            if($deadline -le 0){$deadline=3000}
            while($deadline -le [long]$elapsed){$deadline+=3000}
            $HostState.NextReconcileMilliseconds=$deadline;$HostState.ForceReconcile=$false
        }
        if($null -ne $HostState.SpecialProof -or $null -ne $HostState.StaleReconciliationCandidate){
            if($HostState.SpecialNeedsInspect){[void](New-CcodSupervisorInternalLifecycleRequest $HostState $Adapters CheckAndRepair Guardian);return}
            Set-CcodSupervisorCurrentTrayPresentation $HostState $Adapters;return
        }
        $HostState.SessionState='Waiting';$HostState.BlockAutomaticActions=$false
        if($HostState.SpecialNeedsInspect){[void](New-CcodSupervisorInternalLifecycleRequest $HostState $Adapters CheckAndRepair Guardian);return}
    }
    if($HostState.SpecialNeedsInspect){[void](New-CcodSupervisorInternalLifecycleRequest $HostState $Adapters CheckAndRepair Guardian);return}
    $queueArgument=[object[]]::new(1);$queueArgument[0]=$HostState.CommandQueue
    $dequeued=Invoke-CcodSupervisorAdapter $Adapters.TryDequeue $queueArgument 1
    if(-not (Test-CcodSupervisorExactProperties $dequeued @('Succeeded','Value')) -or $dequeued.Succeeded -isnot [bool]){throw 'command queue receipt is invalid'}
    if($dequeued.Succeeded){
        $forceBefore=[bool]$HostState.ForceReconcile
        [void](Invoke-CcodSupervisorCommand $HostState $Adapters $dequeued.Value)
        if(-not $forceBefore -and $HostState.ForceReconcile){$HostState.ObservationDirty=$true}
        return
    }
    if($HostState.ForceReconcile -or [long]$elapsed -ge $HostState.NextReconcileMilliseconds){
        Invoke-CcodSupervisorRefreshObservations $HostState $Adapters
        $deadline=[long]$HostState.NextReconcileMilliseconds
        if($deadline -le 0){$deadline=3000}
        while($deadline -le [long]$elapsed){$deadline+=3000}
        $HostState.NextReconcileMilliseconds=$deadline;$HostState.ForceReconcile=$false
    }
    if($null -ne $HostState.StaleReconciliationCandidate){
        if($HostState.BlockAutomaticActions -and $HostState.Reason -cne 'StalePackageStatus'){
            Set-CcodSupervisorCurrentTrayPresentation $HostState $Adapters;return
        }
        $HostState.SessionState='Error';$HostState.BlockAutomaticActions=$true;$HostState.Reason='StalePackageStatus'
        $HostState.SessionState='Error';$HostState.BlockAutomaticActions=$true;$HostState.Reason='StalePackageStatus';$HostState.ConnectionState='Error';return
    }
    $context=New-CcodSupervisorEngineContext $HostState
    $decision=Invoke-CcodSupervisorAdapter $Adapters.GetSupervisorDecision @($context) 1
    if(-not (Test-CcodSupervisorExactProperties $decision @('Action','Reason','Target','AttemptKey','SuppressionKey','EffectiveClassification','RequiresController'))){throw 'supervisor decision is invalid'}
    $HostState.LastDecision=$decision
    if($HostState.SessionState -cne 'Active' -or $HostState.Reason -cne 'RendererHandoff'){
        $HostState.Reason=[string]$decision.Reason
    }
    Set-CcodSupervisorCurrentTrayPresentation $HostState $Adapters
    switch($decision.Action){
        'RepairRenderer' {[void](New-CcodSupervisorInternalLifecycleRequest $HostState $Adapters CheckAndRepair Guardian);return}
        'InspectOrdinary' {Start-CcodSupervisorWorkerSlot $HostState $Adapters 'StaticProbe' 'StaticProbe' $decision.Target|Out-Null;return}
        'ApplyOrdinary' {[void](New-CcodSupervisorInternalLifecycleRequest $HostState $Adapters CheckAndRepair Guardian);return}
    }
}

function Invoke-CcodSupervisorHost {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$ReadyToken,[hashtable]$Adapters)
    if($ReadyToken -cnotmatch '^[0-9a-f]{64}$'){return New-CcodSupervisorReceipt 'StartupRejected' 2 @()}
    $adapter=Get-CcodSupervisorAdapters $Adapters
    if($null -eq $adapter){return New-CcodSupervisorReceipt 'StartupRejected' 2 @()}
    $codes=[Collections.Generic.List[string]]::new();$outcome='Failed';$exitCode=1
    $accountLease=$null;$localLease=$null;$accountOwned=$false;$localOwned=$false
    $lifecycleOwnership=$null;$lifecycleOwned=$false;$workerCleanupSafe=$true;$lifecycleWakeEvent=$null;$readyEvent=$null;$shutdownEvent=$null;$commandQueue=$null;$eventQueue=$null;$tray=$null;$watcher=$null;$hostState=$null
    try{
        do{
            $identity=Invoke-CcodSupervisorAdapter $adapter.GetIdentity @() 1
            if(-not (Test-CcodSupervisorIdentity $identity)){throw 'identity contract is invalid'}
            $layout=Invoke-CcodSupervisorAdapter $adapter.ResolveLayout @() 1
            if(-not (Test-CcodSupervisorLayout $layout)){throw 'layout contract is invalid'}
            $script:CcodSupervisorLogPath=[IO.Path]::GetFullPath((Join-Path $layout.LogDirectory 'supervisor.log'))
            $clock=Invoke-CcodSupervisorAdapter $adapter.StartClock @() 1
            if($null -eq $clock){throw 'clock contract is invalid'}
            $remaining=Get-CcodSupervisorRemainingBudget $clock $adapter
            $accountLease=Invoke-CcodSupervisorAdapter $adapter.EnterLease @('AccountSupervisor',$identity.UserSid,$null,[int]$remaining) 1
            if(-not (Test-CcodSupervisorLease $accountLease 'AccountSupervisor')){throw 'account lease contract is invalid'}
            if($accountLease.Outcome -ceq 'TimedOut'){$outcome='StartupRejected';$exitCode=2;break}
            $accountOwned=$true
            $remaining=Get-CcodSupervisorRemainingBudget $clock $adapter
            $localLease=Invoke-CcodSupervisorAdapter $adapter.EnterLease @('Supervisor',$identity.UserSid,[int]$identity.SessionId,[int]$remaining) 1
            if(-not (Test-CcodSupervisorLease $localLease 'Supervisor')){throw 'local lease contract is invalid'}
            if($localLease.Outcome -ceq 'TimedOut'){$outcome='StartupRejected';$exitCode=2;break}
            $localOwned=$true
            if($accountLease.Abandoned -or $localLease.Abandoned){
                $record=[pscustomobject][ordered]@{schemaVersion=1;timestampUtc=(Invoke-CcodSupervisorAdapter $adapter.GetUtcNow @() 1).ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture);component='Supervisor';stage='LeaseAcquire';code='CCOD_SUPERVISOR_LEASE_ABANDONED';outcome='Warning'}
                try{Invoke-CcodSupervisorAdapter $adapter.WriteLog @($record) 0}catch{Add-CcodSupervisorCleanupCode $codes 'CCOD_SUPERVISOR_LOG_FAILED'}
            }
            $activeRuntime=Invoke-CcodSupervisorAdapter $adapter.ReadActiveRuntime @($layout.InstallRoot) 1
            if(-not(Test-CcodSupervisorActiveRuntime $activeRuntime $layout.RuntimeId)){throw 'active runtime contract is invalid'}
            $logonIdentity=Invoke-CcodSupervisorAdapter $adapter.GetTrustedLogonIdentity @($identity.UserSid,[int]$identity.SessionId) 1
            if(-not(Test-CcodSupervisorLogonIdentity $logonIdentity $identity)){throw 'trusted logon identity contract is invalid'}
            $remaining=Get-CcodSupervisorRemainingBudget $clock $adapter
            $ownerIdentity=[pscustomobject][ordered]@{pid=[int]$identity.Pid;creationTimeUtc=[string]$identity.CreationTimeUtc}
            $lifecycleOwnership=Invoke-CcodSupervisorAdapter $adapter.EnterLifecycleOwnership @($layout.InstallRoot,$layout.RuntimeId,[UInt64]$activeRuntime.generation,$ownerIdentity,$identity.UserSid,[int]$identity.SessionId,[int]$remaining) 1
            if(-not(Test-CcodSupervisorLifecycleOwnership $lifecycleOwnership $identity $activeRuntime)){throw 'lifecycle ownership contract is invalid'}
            $lifecycleOwned=$true
            $readyEvent=Invoke-CcodSupervisorAdapter $adapter.OpenReadyEvent @($identity.UserSid,[int]$identity.SessionId,$ReadyToken) 1
            if(-not (Test-CcodSupervisorEvent $readyEvent 'Ready')){throw 'Ready event contract is invalid'}
            $shutdownEvent=Invoke-CcodSupervisorAdapter $adapter.OpenShutdownEvent @($identity.UserSid,[int]$identity.SessionId) 1
            if(-not (Test-CcodSupervisorEvent $shutdownEvent 'Shutdown')){throw 'Shutdown event contract is invalid'}
            $lifecycleWakeEvent=Invoke-CcodSupervisorAdapter $adapter.OpenLifecycleWakeEvent @($identity.UserSid,[int]$identity.SessionId) 1
            if(-not(Test-CcodSupervisorEvent $lifecycleWakeEvent 'LifecycleWake')){throw 'Lifecycle wake event contract is invalid'}
            Invoke-CcodSupervisorAdapter $adapter.ResetLifecycleWakeEvent @($lifecycleWakeEvent) 0
            $shutdown=Invoke-CcodSupervisorAdapter $adapter.IsEventSignaled @($shutdownEvent) 1
            if($shutdown -isnot [bool]){throw 'Shutdown state is invalid'}
            if($shutdown){$outcome='StartupRejected';$exitCode=2;break}
            $state=Invoke-CcodSupervisorAdapter $adapter.ReadState @($layout.StateRoot) 1
            if($null -eq $state){throw 'state contract is invalid'}
            $journal=Invoke-CcodSupervisorAdapter $adapter.ReadJournal @($layout.TransitionPath) 1
            $lifecycleRequest=Invoke-CcodSupervisorNullableAdapter $adapter.ReadLifecycleRequest @($layout.StateRoot)
            if($null-ne$lifecycleRequest){$lifecycleRequest=Rebind-CcodSupervisorLifecycleRequest $lifecycleRequest $lifecycleOwnership $logonIdentity (Get-CcodSupervisorNowUtc $adapter) $adapter $layout.StateRoot $layout.InstallRoot}
            $preference=Invoke-CcodSupervisorAdapter $adapter.ReadUiPreference @($layout.StateRoot) 1
            if(-not (Test-CcodSupervisorUiPreference $preference)){throw 'UI preference contract is invalid'}
            $cultureName=Invoke-CcodSupervisorAdapter $adapter.GetSystemCultureName @() 1
            if(-not (Test-CcodSupervisorCultureName $cultureName)){throw 'UI culture contract is invalid'}
            $resourcesRoot=Get-CcodSupervisorResourcesRoot
            $catalog=Invoke-CcodSupervisorAdapter $adapter.GetUiCatalog @($resourcesRoot,$preference.LanguageMode,$cultureName) 1
            if(-not (Test-CcodSupervisorUiCatalog $catalog $preference.LanguageMode)){throw 'UI catalog contract is invalid'}
            $commandQueue=Invoke-CcodSupervisorAdapter $adapter.NewQueue @('Command') 1
            $eventQueue=Invoke-CcodSupervisorAdapter $adapter.NewQueue @('Event') 1
            if($null -eq $commandQueue -or $null -eq $eventQueue){throw 'queue contract is invalid'}
            $hostState=New-CcodSupervisorHostState -Identity $identity -Layout $layout -Clock $clock -ShutdownEvent $shutdownEvent -LifecycleWakeEvent $lifecycleWakeEvent -CommandQueue $commandQueue -EventQueue $eventQueue -State $state -Journal $journal -LifecycleOwnership $lifecycleOwnership -LifecycleRequest $lifecycleRequest -LogonIdentity $logonIdentity
            $hostState.UiLanguageMode=$preference.LanguageMode;$hostState.UiCatalog=$catalog
            $hostStateRef=$hostState;$adapterRef=$adapter
            $onTick={param($menuOpen)Invoke-CcodSupervisorTick $hostStateRef $adapterRef ([bool]$menuOpen)}.GetNewClosure()
            $trayArguments=[object[]]::new(5);$trayArguments[0]=$commandQueue;$trayArguments[1]=$onTick;$trayArguments[2]=$catalog;$trayArguments[3]=$preference.LanguageMode;$trayArguments[4]=$cultureName
            $tray=Invoke-CcodSupervisorAdapter $adapter.NewTray $trayArguments 1
            if($null -eq $tray){throw 'tray contract is invalid'}
            $hostState.Tray=$tray
            $onFull={}.GetNewClosure()
            $watcherArguments=[object[]]::new(2);$watcherArguments[0]=$eventQueue;$watcherArguments[1]=$onFull
            $watcher=Invoke-CcodSupervisorAdapter $adapter.NewWatcher $watcherArguments 1
            if($null -eq $watcher){throw 'watcher contract is invalid'}
            $shutdown=Invoke-CcodSupervisorAdapter $adapter.IsEventSignaled @($shutdownEvent) 1
            if($shutdown -isnot [bool]){throw 'Shutdown state is invalid'}
            if($shutdown){$outcome='StartupRejected';$exitCode=2;break}
            Invoke-CcodSupervisorAdapter $adapter.SignalEvent @($readyEvent) 0
            Invoke-CcodSupervisorAdapter $adapter.RunUiContext @($tray) 0
            $outcome='Stopped';$exitCode=0
        }while($false)
    }catch{$outcome='Failed';$exitCode=1}
    finally{
        if($null -ne $hostState){$hostState.ShutdownRequested=$true}
        if($null-ne$hostState){if(-not(Stop-CcodSupervisorOwnedWorkerForShutdown $hostState $adapter LifecycleWorkerSlot $codes)){$workerCleanupSafe=$false};if(-not(Stop-CcodSupervisorOwnedWorkerForShutdown $hostState $adapter WorkerSlot $codes)){$workerCleanupSafe=$false}}
        if($null -ne $tray){Invoke-CcodSupervisorCleanupStage {Invoke-CcodSupervisorAdapter $adapter.StopTrayTimer @($tray) 0} $codes 'CCOD_SUPERVISOR_TIMER_STOP_FAILED'}
        if($null -ne $watcher){Invoke-CcodSupervisorCleanupStage {Invoke-CcodSupervisorAdapter $adapter.StopWatcher @($watcher) 1|Out-Null} $codes 'CCOD_SUPERVISOR_WATCHER_STOP_FAILED'}
        if($null -ne $eventQueue){Invoke-CcodSupervisorCleanupStage {Invoke-CcodSupervisorDrainQueue $eventQueue $adapter} $codes 'CCOD_SUPERVISOR_QUEUE_DRAIN_FAILED'}
        if($null -ne $commandQueue){Invoke-CcodSupervisorCleanupStage {Invoke-CcodSupervisorDrainQueue $commandQueue $adapter} $codes 'CCOD_SUPERVISOR_QUEUE_DRAIN_FAILED'}
        if($null -ne $tray){Invoke-CcodSupervisorCleanupStage {Invoke-CcodSupervisorAdapter $adapter.CloseTray @($tray) 1|Out-Null} $codes 'CCOD_SUPERVISOR_TRAY_CLOSE_FAILED'}
        if($null -ne $readyEvent){Invoke-CcodSupervisorCleanupStage {Invoke-CcodSupervisorAdapter $adapter.CloseEvent @($readyEvent) 0} $codes 'CCOD_SUPERVISOR_READY_CLOSE_FAILED'}
        if($null -ne $shutdownEvent){Invoke-CcodSupervisorCleanupStage {Invoke-CcodSupervisorAdapter $adapter.CloseEvent @($shutdownEvent) 0} $codes 'CCOD_SUPERVISOR_SHUTDOWN_CLOSE_FAILED'}
        if($null-ne$lifecycleWakeEvent){Invoke-CcodSupervisorCleanupStage {Invoke-CcodSupervisorAdapter $adapter.CloseEvent @($lifecycleWakeEvent) 0} $codes 'CCOD_SUPERVISOR_LIFECYCLE_WAKE_CLOSE_FAILED'}
        if($null-ne$hostState){foreach($runtimeCode in @($hostState.RuntimeCleanupCodes)){Add-CcodSupervisorCleanupCode $codes $runtimeCode}}
        if($workerCleanupSafe){
            if($lifecycleOwned-and$null-ne$lifecycleOwnership-and-not$lifecycleOwnership.released-and$null-ne$lifecycleOwnership.lease.PSObject.Properties['Released']-and$lifecycleOwnership.lease.Released){$lifecycleOwnership.released=$true;$lifecycleOwned=$false}
            if($lifecycleOwned){Invoke-CcodSupervisorCleanupStage {$released=Invoke-CcodSupervisorAdapter $adapter.ExitLifecycleOwnership @($lifecycleOwnership) 1;if($released-isnot[bool] -or -not$released -or -not$lifecycleOwnership.released){throw 'lifecycle ownership release failed'}} $codes 'CCOD_SUPERVISOR_LIFECYCLE_RELEASE_FAILED'}
            if($localOwned){Invoke-CcodSupervisorCleanupStage {$released=Invoke-CcodSupervisorAdapter $adapter.ExitLease @($localLease) 1;if($released -isnot [bool] -or -not $released){throw 'local lease release failed'}} $codes 'CCOD_SUPERVISOR_LOCAL_RELEASE_FAILED'}
            if($accountOwned){Invoke-CcodSupervisorCleanupStage {$released=Invoke-CcodSupervisorAdapter $adapter.ExitLease @($accountLease) 1;if($released -isnot [bool] -or -not $released){throw 'account lease release failed'}} $codes 'CCOD_SUPERVISOR_ACCOUNT_RELEASE_FAILED'}
        }
        $script:CcodSupervisorLogPath=$null
    }
    return New-CcodSupervisorReceipt $outcome $exitCode @($codes)
}

if($MyInvocation.InvocationName -ne '.'){
    $receipt=Invoke-CcodSupervisorHost -ReadyToken $ReadyToken
    [Console]::Out.WriteLine(($receipt|ConvertTo-Json -Depth 6 -Compress))
    exit $receipt.ExitCode
}
