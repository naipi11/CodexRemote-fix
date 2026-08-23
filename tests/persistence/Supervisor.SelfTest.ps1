$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$supervisorPath = Join-Path $repositoryRoot 'src\persistence\Supervisor.ps1'
$localizationPath = Join-Path $repositoryRoot 'src\persistence\modules\UiLocalization.psm1'
$processControlPath = Join-Path $repositoryRoot 'src\persistence\modules\ProcessControl.psm1'
$supervisorEnginePath = Join-Path $repositoryRoot 'src\persistence\modules\SupervisorEngine.psm1'
$lifecycleTransactionPath = Join-Path $repositoryRoot 'src\persistence\modules\LifecycleTransaction.psm1'
$lifecycleCoordinatorPath = Join-Path $repositoryRoot 'src\persistence\modules\LifecycleCoordinator.psm1'
$workerRuntimePath = Join-Path $repositoryRoot 'src\persistence\modules\WorkerRuntime.psm1'
$resourcesRoot = Join-Path $repositoryRoot 'src\persistence\resources'
if (-not [IO.File]::Exists($supervisorPath)) {
    throw 'CCOD_TEST_SUPERVISOR_CONTRACT_MISSING'
}

Import-Module $localizationPath -Force
Import-Module $processControlPath -Force
Import-Module $supervisorEnginePath -Force
Import-Module $lifecycleTransactionPath -Force
Import-Module $lifecycleCoordinatorPath -Force -WarningAction SilentlyContinue
Import-Module $workerRuntimePath -Force
$script:TestSystemCatalog=Get-CcodUiCatalog -ResourcesRoot $resourcesRoot -LanguageMode System -SystemCultureName zh-CN
$script:TestChineseCatalog=Get-CcodUiCatalog -ResourcesRoot $resourcesRoot -LanguageMode zh-CN -SystemCultureName zh-CN
$script:TestEnglishCatalog=Get-CcodUiCatalog -ResourcesRoot $resourcesRoot -LanguageMode en-US -SystemCultureName zh-CN
$readyToken = 'a' * 64
. $supervisorPath -ReadyToken $readyToken

function Assert-CcodTrue {
    param([bool]$Condition,[string]$Message)
    if(-not $Condition){throw "ASSERT_TRUE_FAILED: $Message"}
}

function Assert-CcodEqual {
    param($Expected,$Actual,[string]$Message)
    if($Expected -is [array] -or $Actual -is [array]){
        $left=@($Expected)-join '|';$right=@($Actual)-join '|'
        if($left -cne $right){throw "ASSERT_EQUAL_FAILED: $Message expected=[$left] actual=[$right]"}
    }elseif($Expected -is [string] -or $Actual -is [string]){
        if([string]$Expected -cne [string]$Actual){throw "ASSERT_EQUAL_FAILED: $Message expected=[$Expected] actual=[$Actual]"}
    }elseif($Expected -ne $Actual){throw "ASSERT_EQUAL_FAILED: $Message expected=[$Expected] actual=[$Actual]"}
}

function Assert-CcodReceipt {
    param($Receipt,[string]$Outcome,[int]$ExitCode)
    Assert-CcodEqual 'SchemaVersion|Outcome|ExitCode|CleanupCodes' (@($Receipt.PSObject.Properties.Name)-join '|') 'host receipt fields are exact and ordered'
    Assert-CcodEqual 1 $Receipt.SchemaVersion 'host receipt schema'
    Assert-CcodEqual $Outcome $Receipt.Outcome 'host receipt outcome'
    Assert-CcodEqual $ExitCode $Receipt.ExitCode 'host receipt exit code'
    Assert-CcodTrue ($Receipt.CleanupCodes -is [array]) 'cleanup codes are an array'
}

function New-CcodSupervisorFake {
    param([string]$FailAt=$null,[bool]$ShutdownSignaled=$false,[string]$FirstLeaseOutcome='Acquired',[string]$SecondLeaseOutcome='Acquired',[bool]$AccountAbandoned=$false,[bool]$LocalAbandoned=$false)
    $systemCatalog=$script:TestSystemCatalog;$chineseCatalog=$script:TestChineseCatalog;$englishCatalog=$script:TestEnglishCatalog
    $coordinatorModule=Import-Module $lifecycleCoordinatorPath -Force -PassThru -WarningAction SilentlyContinue
    $transactionModule=Import-Module $lifecycleTransactionPath -Force -PassThru
    $workerRuntimeModule=Import-Module $workerRuntimePath -Force -PassThru
    $world=[pscustomobject]@{
        Calls=[Collections.Generic.List[string]]::new();FailAt=$FailAt;ShutdownSignaled=$ShutdownSignaled
        FirstLeaseOutcome=$FirstLeaseOutcome;SecondLeaseOutcome=$SecondLeaseOutcome;AccountAbandoned=$AccountAbandoned;LocalAbandoned=$LocalAbandoned
        Elapsed=[Collections.Generic.Queue[long]]::new();ReadySignals=0;StateReads=0;JournalReads=0
        CommandQueue=[Collections.Generic.Queue[object]]::new();EventQueue=[Collections.Generic.Queue[object]]::new();OnTick=$null
        TryDequeueSawRealQueue=$false;NewTraySawRealQueue=$false;NewWatcherSawRealQueue=$false
        ActiveJournal=$null;Decision=[pscustomobject][ordered]@{Action='KeepOrdinary';Reason='Idle';Target=$null;AttemptKey=$null;SuppressionKey=$null;EffectiveClassification=$null;RequiresController=$false}
        ProcessIds=@();Snapshots=@{};Poll=[pscustomobject][ordered]@{Completed=$false;ExitCode=$null;StdoutText='';StdoutByteCount=0;StdoutOverflow=$false;StderrByteCount=0;StderrOverflow=$false}
        WorkerResult=$null;TickCount=0
        Preference=[pscustomobject][ordered]@{LanguageMode='System';FallbackUsed=$false;ErrorCode=$null};StoredLanguageMode='System';SystemCultureName='zh-CN'
        SetUiLanguageModes=[Collections.Generic.List[string]]::new();TrayArguments=$null;PresentationArguments=[Collections.Generic.List[object]]::new()
        PresentationInputs=[Collections.Generic.List[object]]::new()
        UiFailureRecords=[Collections.Generic.List[object]]::new();TrayErrors=[Collections.Generic.List[object]]::new()
        ActiveRuntime=[pscustomobject][ordered]@{schemaVersion=2;activeRuntime='runtime-1';generation=[UInt64]7}
        LogonIdentity=[pscustomobject][ordered]@{authenticationId='00000000:00001234';userSid='S-1-5-21-111-222-333-1001';sessionId=[int]1}
        LifecycleOwnership=$null;LifecycleOwnershipEntries=0;LifecycleFenceAssertions=0;LifecycleOwnershipExits=0
        ActiveLifecycleRequest=$null;LifecycleSubmissions=[Collections.Generic.Queue[object]]::new();LifecycleSubmissionReceipts=[Collections.Generic.List[object]]::new();CompletedLifecycleRequests=[Collections.Generic.List[object]]::new()
        LifecycleWrites=[Collections.Generic.List[object]]::new();LifecycleMoves=[Collections.Generic.List[string]]::new();StartedLifecycleRequests=[Collections.Generic.List[object]]::new();AutoCompleteLifecycleWorkers=$false
        WorkerWaitResults=[Collections.Generic.Queue[bool]]::new();WorkerTerminateResults=[Collections.Generic.Queue[bool]]::new()
    }
    $adapters=@{}
    foreach($name in Get-CcodSupervisorAdapterNames){
        $unusedName=$name
        $adapters[$name]={throw "UNEXPECTED_ADAPTER_$unusedName"}.GetNewClosure()
    }
    $identity=[pscustomobject][ordered]@{UserSid='S-1-5-21-111-222-333-1001';SessionId=[int]1;Pid=[int]41;CreationTimeUtc='2030-02-03T03:00:00.0000000Z'}
    $layout=[pscustomobject][ordered]@{
        InstallRoot='C:\Fake\CodexControlOtherDevices';RuntimeRoot='C:\Fake\CodexControlOtherDevices\runtime-1';RuntimeId='runtime-1'
        StateRoot='C:\Fake\CodexControlOtherDevices\state';WorkersRoot='C:\Fake\CodexControlOtherDevices\state\workers'
        ControllerPath='C:\Fake\CodexControlOtherDevices\runtime-1\src\persistence\SessionController.ps1'
        StaticWorkerPath='C:\Fake\CodexControlOtherDevices\runtime-1\src\persistence\StaticProbeWorker.ps1'
        LifecycleWorkerPath='C:\Fake\CodexControlOtherDevices\runtime-1\src\persistence\LifecycleWorker.ps1'
        PowerShellPath='C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe';LogDirectory='C:\Fake\CodexControlOtherDevices\logs'
        TransitionPath='C:\Fake\CodexControlOtherDevices\state\transition.json'
    }
    $newLease={
        param([string]$Kind,[string]$Outcome,[bool]$Abandoned)
        [pscustomobject][ordered]@{SchemaVersion=1;Name="Fake-$Kind";Kind=$Kind;Outcome=$Outcome;CreatedNew=($Outcome -ceq 'Acquired');Abandoned=($Abandoned -and $Outcome -ceq 'Acquired');Handle=$(if($Outcome -ceq 'Acquired'){New-Object object}else{$null});OwnerManagedThreadId=[Threading.Thread]::CurrentThread.ManagedThreadId;Released=$false}
    }
    $newEvent={
        param([string]$Kind)
        [pscustomobject][ordered]@{SchemaVersion=1;Name="Fake-$Kind";Kind=$Kind;CreatedNew=$false;Handle=[pscustomobject]@{Kind=$Kind};Disposed=$false}
    }
    $adapters.GetIdentity={$world.Calls.Add('Identity');$identity}.GetNewClosure()
    $adapters.ResolveLayout={$world.Calls.Add('Layout');$layout}.GetNewClosure()
    $adapters.StartClock={$world.Calls.Add('Clock');[pscustomobject]@{Kind='Clock'}}.GetNewClosure()
    $adapters.GetElapsedMilliseconds={param($Clock)if($world.Elapsed.Count){[long]$world.Elapsed.Dequeue()}else{[long]0}}.GetNewClosure()
    $adapters.GetUtcNow={[DateTime]::Parse('2030-02-03T03:04:05Z').ToUniversalTime()}.GetNewClosure()
    $adapters.EnterLease={
        param($Kind,$UserSid,$SessionId,$TimeoutMilliseconds)
        $world.Calls.Add("Enter:$Kind`:$TimeoutMilliseconds")
        if($world.FailAt -ceq "Enter$Kind"){throw 'PRIVATE_ENTER_SECRET'}
        if($Kind -ceq 'AccountSupervisor'){& $newLease $Kind $world.FirstLeaseOutcome $world.AccountAbandoned}else{& $newLease $Kind $world.SecondLeaseOutcome $world.LocalAbandoned}
    }.GetNewClosure()
    $adapters.ExitLease={param($Lease)$world.Calls.Add("Exit:$($Lease.Kind)");if($world.FailAt -ceq "Exit$($Lease.Kind)"){throw 'PRIVATE_EXIT_SECRET'};$true}.GetNewClosure()
    $adapters.OpenReadyEvent={param($UserSid,$SessionId,$Token)$world.Calls.Add('Open:Ready');if($world.FailAt -ceq 'OpenReady'){throw 'PRIVATE_READY_SECRET'};& $newEvent 'Ready'}.GetNewClosure()
    $adapters.OpenShutdownEvent={param($UserSid,$SessionId)$world.Calls.Add('Open:Shutdown');if($world.FailAt -ceq 'OpenShutdown'){throw 'PRIVATE_SHUTDOWN_SECRET'};& $newEvent 'Shutdown'}.GetNewClosure()
    $adapters.OpenLifecycleWakeEvent={param($UserSid,$SessionId)$world.Calls.Add('Open:LifecycleWake');if($world.FailAt -ceq 'OpenLifecycleWake'){throw 'PRIVATE_LIFECYCLE_WAKE_SECRET'};& $newEvent 'LifecycleWake'}.GetNewClosure()
    $adapters.ResetLifecycleWakeEvent={param($Event)$world.Calls.Add('Reset:LifecycleWake')}.GetNewClosure()
    $adapters.IsEventSignaled={param($Event)$world.Calls.Add("Check:$($Event.Kind)");if($Event.Kind -ceq 'Shutdown'){[bool]$world.ShutdownSignaled}else{$false}}.GetNewClosure()
    $adapters.SignalEvent={param($Event)$world.Calls.Add("Signal:$($Event.Kind)");if($world.FailAt -ceq 'SignalReady'){throw 'PRIVATE_SIGNAL_SECRET'};$world.ReadySignals++}.GetNewClosure()
    $adapters.CloseEvent={param($Event)$world.Calls.Add("Close:$($Event.Kind)");if($world.FailAt -ceq "Close$($Event.Kind)"){throw 'PRIVATE_CLOSE_SECRET'}}.GetNewClosure()
    $adapters.ReadState={param($StateRoot)$world.Calls.Add('Read:State');$world.StateReads++;if($world.FailAt -ceq 'ReadState'){throw 'PRIVATE_STATE_SECRET'};[pscustomobject]@{AutomationEnabled=$true;Settings=[pscustomobject]@{candidateCompatibleOptIn=$false};Damage=$null}}.GetNewClosure()
    $adapters.ReadActiveRuntime={param($InstallRoot)$world.Calls.Add('Read:ActiveRuntime');if($world.FailAt -ceq 'ReadActiveRuntime'){throw 'PRIVATE_RUNTIME_POINTER_SECRET'};$world.ActiveRuntime}.GetNewClosure()
    $adapters.GetTrustedLogonIdentity={param($ExpectedUserSid,$ExpectedSessionId)$world.Calls.Add('Read:LogonIdentity');if($world.FailAt -ceq 'GetTrustedLogonIdentity'){throw 'PRIVATE_LOGON_SECRET'};$world.LogonIdentity}.GetNewClosure()
    $adapters.EnterLifecycleOwnership={
        param($InstallRoot,$RuntimeId,$RuntimeGeneration,$OwnerIdentity,$UserSid,$SessionId,$TimeoutMilliseconds)
        $world.Calls.Add("Enter:LifecycleOwnership:$RuntimeGeneration");if($world.FailAt -ceq 'EnterLifecycleOwnership'){throw 'PRIVATE_OWNERSHIP_SECRET'};$world.LifecycleOwnershipEntries++
        $world.LifecycleOwnership=[pscustomobject][ordered]@{schemaVersion=1;lease=[pscustomobject]@{Released=$false};epoch=[UInt64]11;runtimeId=$RuntimeId;runtimeGeneration=[UInt64]$RuntimeGeneration;ownerIdentity=$OwnerIdentity;released=$false}
        $world.LifecycleOwnership
    }.GetNewClosure()
    $adapters.AssertLifecycleFence={param($InstallRoot,$Ownership)$world.Calls.Add("Fence:$($Ownership.epoch)");$world.LifecycleFenceAssertions++;$true}.GetNewClosure()
    $adapters.ExitLifecycleOwnership={param($Ownership)$world.Calls.Add("Exit:LifecycleOwnership:$($Ownership.epoch)");$world.LifecycleOwnershipExits++;if($world.FailAt -ceq 'ExitLifecycleOwnership'){throw 'PRIVATE_OWNERSHIP_RELEASE_SECRET'};$Ownership.released=$true;$true}.GetNewClosure()
    $adapters.ReadLifecycleRequest={param($StateRoot)$world.Calls.Add('Read:LifecycleRequest');if($world.FailAt -ceq 'ReadLifecycleRequest'){throw 'PRIVATE_LIFECYCLE_REQUEST_SECRET'};$world.ActiveLifecycleRequest}.GetNewClosure()
    $adapters.ReceiveLifecycleSubmissions={
        param($StateRoot,$MaximumCount)
        $world.Calls.Add("Receive:Lifecycle:$MaximumCount")
        if($world.LifecycleSubmissions.Count -gt 0){$world.LifecycleSubmissions.Dequeue()}else{$null}
    }.GetNewClosure()
    $adapters.WriteLifecycleSubmissionReceipt={
        param($StateRoot,$SubmissionId,$Accepted,$TransactionId,$ErrorCode)
        $world.Calls.Add("Receipt:Lifecycle:$SubmissionId`:$Accepted")
        $world.LifecycleSubmissionReceipts.Add([pscustomobject][ordered]@{submissionId=$SubmissionId;accepted=[bool]$Accepted;transactionId=$TransactionId;errorCode=$ErrorCode})
    }.GetNewClosure()
    $adapters.NewLifecycleRequest={
        param($Kind,$Origin,$RuntimeId,$RuntimeGeneration,$LeaseEpoch,$OwnerIdentity,$LogonIdentity,$NowUtc)
        $world.Calls.Add("New:Lifecycle:$Kind")
        & $transactionModule {param($K,$O,$R,$G,$E,$Owner,$Logon,$Now)New-CcodLifecycleRequest -Kind $K -Origin $O -RuntimeId $R -RuntimeGeneration $G -LeaseEpoch $E -OwnerIdentity $Owner -LogonIdentity $Logon -NowUtc $Now} $Kind $Origin $RuntimeId $RuntimeGeneration $LeaseEpoch $OwnerIdentity $LogonIdentity $NowUtc
    }.GetNewClosure()
    $adapters.WriteLifecycleRequest={param($StateRoot,$Request)$world.Calls.Add("Write:Lifecycle:$($Request.phase)");$world.ActiveLifecycleRequest=$Request;$world.LifecycleWrites.Add($Request)}.GetNewClosure()
    $adapters.MoveLifecyclePhase={param($Request,$NextPhase,$NowUtc)$world.Calls.Add("Move:Lifecycle:$NextPhase");$world.LifecycleMoves.Add($NextPhase);& $transactionModule {param($Value,$Phase,$Now)Move-CcodLifecyclePhase -Request $Value -NextPhase $Phase -NowUtc $Now} $Request $NextPhase $NowUtc}.GetNewClosure()
    $adapters.CompleteLifecycleRequest={param($StateRoot,$Request)$world.Calls.Add("Complete:Lifecycle:$($Request.phase)");$world.CompletedLifecycleRequests.Add($Request);$world.ActiveLifecycleRequest=$null}.GetNewClosure()
    $adapters.GetLifecycleStep={param($Request,$Observation,$NowUtc)& $coordinatorModule {param($Value,$Observed,$Now)Get-CcodLifecycleStep -Request $Value -Observation $Observed -NowUtc $Now} $Request $Observation $NowUtc}.GetNewClosure()
    $adapters.ReduceLifecycleWorkerResult={param($Request,$Result,$NowUtc)& $coordinatorModule {param($Value,$WorkerResult,$Now)Reduce-CcodLifecycleWorkerResult -Request $Value -Result $WorkerResult -NowUtc $Now} $Request $Result $NowUtc}.GetNewClosure()
    $adapters.NewLifecycleWorkerRequest={
        param($TransactionId,$Action,$RuntimeId,$RuntimeGeneration,$LeaseEpoch,$OwnerIdentity,$NotBeforeUtc,$TimeoutMilliseconds)
        $world.Calls.Add("New:LifecycleWorker:$Action")
        & $workerRuntimeModule {param($Id,$WorkerAction,$Runtime,$Generation,$Epoch,$Owner,$NotBefore,$Timeout)New-CcodLifecycleWorkerRequest -TransactionId $Id -Action $WorkerAction -RuntimeId $Runtime -RuntimeGeneration $Generation -LeaseEpoch $Epoch -OwnerIdentity $Owner -NotBeforeUtc $NotBefore -TimeoutMilliseconds $Timeout} $TransactionId $Action $RuntimeId $RuntimeGeneration $LeaseEpoch $OwnerIdentity $NotBeforeUtc $TimeoutMilliseconds
    }.GetNewClosure()
    $adapters.AssertLifecycleWorkerResult={param($Result,$ExpectedRequest)& $workerRuntimeModule {param($Value,$Expected)Assert-CcodLifecycleWorkerResult -Result $Value -ExpectedRequest $Expected|Out-Null} $Result $ExpectedRequest}.GetNewClosure()
    $adapters.ReadJournal={param($Path)$world.Calls.Add('Read:Journal');$world.JournalReads++;if($world.FailAt -ceq 'ReadJournal'){throw 'PRIVATE_JOURNAL_SECRET'};$world.ActiveJournal}.GetNewClosure()
    $adapters.ReadUiPreference={param($StateRoot)$world.Calls.Add('Read:UiPreference');if($world.FailAt -ceq 'ReadUiPreference'){throw 'PRIVATE_UI_PREFERENCE_SECRET'};$world.Preference}.GetNewClosure()
    $adapters.SetUiLanguageMode={param($StateRoot,$Mode)$world.Calls.Add("Persist:UiLanguage:$Mode");$world.SetUiLanguageModes.Add($Mode);if($world.FailAt -ceq 'SetUiLanguageMode'){throw 'PRIVATE_UI_WRITE_SECRET'};$world.StoredLanguageMode=$Mode}.GetNewClosure()
    $adapters.GetSystemCultureName={$world.Calls.Add('Get:SystemCulture');[string]$world.SystemCultureName}.GetNewClosure()
    $adapters.GetUiCatalog={
        param($ResourcesRoot,$Mode,$CultureName)
        $world.Calls.Add("Get:UiCatalog:$Mode")
        if($world.FailAt -ceq 'GetUiCatalog'){throw 'PRIVATE_CATALOG_SECRET'}
        if($Mode -ceq 'System'){$systemCatalog}elseif($Mode -ceq 'zh-CN'){$chineseCatalog}elseif($Mode -ceq 'en-US'){$englishCatalog}else{throw 'PRIVATE_INVALID_MODE'}
    }.GetNewClosure()
    $adapters.ShowTrayError={param($Tray,$Catalog,$Key)$world.Calls.Add("Show:TrayError:$Key");if($world.FailAt -ceq 'ShowTrayError'){throw 'PRIVATE_DIALOG_SECRET'};$world.TrayErrors.Add([pscustomobject][ordered]@{Tray=$Tray;Catalog=$Catalog;Key=$Key})}.GetNewClosure()
    $adapters.EnumerateProcessIds={$world.Calls.Add('Enumerate');Write-Output -NoEnumerate @($world.ProcessIds)}.GetNewClosure()
    $adapters.GetProcessSnapshot={param($Pid)$world.Calls.Add("Snapshot:$Pid");if($world.Snapshots.ContainsKey([int]$Pid)){$world.Snapshots[[int]$Pid]}else{$null}}.GetNewClosure()
    $adapters.GetSupervisorDecision={param($Context)$world.Calls.Add('Decision');$world.Decision}.GetNewClosure()
    $adapters.AddObservedEvent={param($Observed,$Pid,$Created)$world.Calls.Add("Observed:$Pid");$true}.GetNewClosure()
    $adapters.CompleteControllerRun={param($Result,$TransactionId,$Action,$RuntimeId)$world.Calls.Add("Reduce:$Action");[pscustomobject][ordered]@{SessionState='Idle';BlockAutomaticActions=$false;AttemptKey=$null;RecoveryIgnoreKey=$null;SuppressionKey=$null;ErrorCode=$null;Reason='Reduced'}}.GetNewClosure()
    $adapters.GetTrayPresentation={param($Arguments)$world.PresentationInputs.Add($Arguments);[pscustomobject][ordered]@{Color='Gray';StateKey='Waiting';SessionReadyVisible=$false;ApplyNowVisible=$true;ApplyNowEnabled=$true;ManualRetryVisible=$false;ManualRetryEnabled=$false;AutomationToggleEnabled=$true;AutomationChecked=[bool]$Arguments.AutomationEnabled;CandidateOptInToggleEnabled=$true;CandidateOptInChecked=[bool]$Arguments.CandidateCompatibleOptIn;OpenLogsEnabled=$true;UninstallEnabled=$false;Busy=$false}}.GetNewClosure()
    $adapters.NewQueue={param($Kind)$world.Calls.Add("Queue:$Kind");if($Kind -ceq 'Command'){Write-Output -NoEnumerate $world.CommandQueue}else{Write-Output -NoEnumerate $world.EventQueue}}.GetNewClosure()
    $adapters.GetQueueCount={param($Queue)[int]$Queue.Count}.GetNewClosure()
    $adapters.TryDequeue={param($Queue)$world.TryDequeueSawRealQueue=[object]::ReferenceEquals($Queue,$world.CommandQueue);if($Queue.Count){[pscustomobject][ordered]@{Succeeded=$true;Value=$Queue.Dequeue()}}else{[pscustomobject][ordered]@{Succeeded=$false;Value=$null}}}.GetNewClosure()
    $adapters.NewTray={param($Queue,$OnTick,$Catalog,$LanguageMode,$SystemCultureName)$world.NewTraySawRealQueue=[object]::ReferenceEquals($Queue,$world.CommandQueue);$world.Calls.Add('New:Tray');if($world.FailAt -ceq 'NewTray'){throw 'PRIVATE_TRAY_SECRET'};$world.OnTick=$OnTick;$world.TrayArguments=[pscustomobject][ordered]@{Queue=$Queue;OnTick=$OnTick;Catalog=$Catalog;LanguageMode=$LanguageMode;SystemCultureName=$SystemCultureName};[pscustomobject]@{Kind='Tray';Timer=[pscustomobject]@{Kind='Timer'};ApplicationContext=[pscustomobject]@{Kind='App'}}}.GetNewClosure()
    $adapters.SetTrayPresentation={param($Tray,$Presentation,$Catalog,$LanguageMode,$SystemCultureName,$WaitForAcknowledgement)$world.Calls.Add('Set:Presentation');if($world.FailAt -ceq 'SetTrayPresentation'){throw 'PRIVATE_PRESENTATION_SECRET'};$world.PresentationArguments.Add([pscustomobject][ordered]@{Tray=$Tray;Presentation=$Presentation;Catalog=$Catalog;LanguageMode=$LanguageMode;SystemCultureName=$SystemCultureName;WaitForAcknowledgement=[bool]$WaitForAcknowledgement})}.GetNewClosure()
    $adapters.StopTrayTimer={param($Tray)$world.Calls.Add('Stop:Timer');if($world.FailAt -ceq 'StopTimer'){throw 'PRIVATE_TIMER_SECRET'}}.GetNewClosure()
    $adapters.RequestUiExit={param($Tray)$world.Calls.Add('Exit:UI')}.GetNewClosure()
    $adapters.CloseTray={param($Tray)$world.Calls.Add('Close:Tray');if($world.FailAt -ceq 'CloseTray'){throw 'PRIVATE_TRAY_CLOSE_SECRET'};[pscustomobject][ordered]@{SchemaVersion=1;Closed=$true;CleanupCodes=@()}}.GetNewClosure()
    $adapters.NewWatcher={param($Queue,$OnFull)$world.NewWatcherSawRealQueue=[object]::ReferenceEquals($Queue,$world.EventQueue);$world.Calls.Add('New:Watcher');if($world.FailAt -ceq 'NewWatcher'){throw 'PRIVATE_WATCHER_SECRET'};[pscustomobject]@{Kind='Watcher';Mode='ReconciliationOnly'}}.GetNewClosure()
    $adapters.StopWatcher={param($Watcher)$world.Calls.Add('Stop:Watcher');if($world.FailAt -ceq 'StopWatcher'){throw 'PRIVATE_WATCHER_STOP_SECRET'};[pscustomobject][ordered]@{SchemaVersion=1;Stopped=$true;CleanupCodes=@()}}.GetNewClosure()
    $adapters.GetWorkerLeafState={param($Path)$world.Calls.Add("Leaf:$([IO.Path]::GetFileName($Path))");[pscustomobject][ordered]@{Exists=$false;IsReparse=$false}}.GetNewClosure()
    $adapters.WriteWorkerRequest={param($Path,$Request)$world.Calls.Add("Write:$($Request.action)");if($null -ne $Request.PSObject.Properties['leaseEpoch']){$world.StartedLifecycleRequests.Add($Request)}}.GetNewClosure()
    $adapters.StartWorker={param($Kind,$ScriptPath,$RequestPath,$ResultPath,$StderrPath,$Request,$PowerShellPath)$world.Calls.Add("Start:$Kind`:$($Request.action)");[pscustomobject][ordered]@{ProcessId=501;CreationTimeUtc='2030-02-03T03:05:00.0000000Z';Handle=[pscustomobject]@{Kind='Worker'};JobHandle=[pscustomobject]@{Kind='Job';IsClosed=$false};StartupGate=[pscustomobject]@{Name='Fake-Gate';Token=('a'*64);Handle=[pscustomobject]@{Kind='Gate'};Released=$true;Disposed=$false}}}.GetNewClosure()
    $adapters.PollWorker={
        param($Slot)
        $world.Calls.Add("Poll:$($Slot.Kind)")
        if($Slot.Kind -ceq 'Lifecycle' -and $world.AutoCompleteLifecycleWorkers){
            $world.WorkerResult=switch($Slot.Action){
                'Apply' {[pscustomobject][ordered]@{schemaVersion=1;transactionId=$Slot.Request.transactionId;action='Apply';ok=$true;outcome='Activated';observation='Special';error=$null}}
                'VerifyRemote' {[pscustomobject][ordered]@{schemaVersion=1;transactionId=$Slot.Request.transactionId;action='VerifyRemote';ok=$true;outcome='Inspected';observation='RemoteVerified';error=$null}}
                default {throw "UNEXPECTED_LIFECYCLE_ACTION_$($Slot.Action)"}
            }
            $json=$world.WorkerResult|ConvertTo-Json -Depth 8 -Compress
            return [pscustomobject][ordered]@{Completed=$true;ExitCode=0;StdoutText=$json;StdoutByteCount=[Text.Encoding]::UTF8.GetByteCount($json);StdoutOverflow=$false;StderrByteCount=0;StderrOverflow=$false}
        }
        $world.Poll
    }.GetNewClosure()
    $adapters.ReadWorkerResult={param($Path)$world.Calls.Add('Read:WorkerResult');$world.WorkerResult}.GetNewClosure()
    $adapters.WaitWorker={param($Slot,$Timeout)$world.Calls.Add("Wait:Worker:$Timeout");if($world.WorkerWaitResults.Count){[bool]$world.WorkerWaitResults.Dequeue()}else{$true}}.GetNewClosure()
    $adapters.GetWorkerIdentity={param($Pid)$world.Calls.Add("WorkerIdentity:$Pid");[pscustomobject][ordered]@{Pid=$Pid;CreationTimeUtc='2030-02-03T03:05:00.0000000Z'}}.GetNewClosure()
    $adapters.TerminateWorker={param($Slot)$world.Calls.Add("Terminate:$($Slot.ProcessId)");if($world.WorkerTerminateResults.Count){[bool]$world.WorkerTerminateResults.Dequeue()}else{$true}}.GetNewClosure()
    $adapters.DisposeWorker={param($Slot)$world.Calls.Add("Dispose:$($Slot.ProcessId)")}.GetNewClosure()
    $adapters.DeleteWorkerFile={param($Path)$world.Calls.Add("Delete:$([IO.Path]::GetFileName($Path))")}.GetNewClosure()
    $adapters.ClearFailedAttempt={param($StateRoot,$Package,$Hash,$Runtime,$Timestamp)$world.Calls.Add('Manual:Clear');[pscustomobject][ordered]@{Outcome='Cleared'}}.GetNewClosure()
    $adapters.SetAutomationEnabled={param($StateRoot,$Enabled)$world.Calls.Add("Automation:$Enabled")}.GetNewClosure()
    $adapters.SetCandidateOptIn={param($StateRoot,$Enabled)$world.Calls.Add("Candidate:$Enabled")}.GetNewClosure()
    $adapters.OpenLogs={param($Path)$world.Calls.Add('Open:Logs')}.GetNewClosure()
    $adapters.RunUiContext={param($Tray)$world.Calls.Add('Run:UI');if($world.FailAt -ceq 'RunUi'){throw 'PRIVATE_UI_SECRET'};if($world.TickCount -gt 0){foreach($index in 1..$world.TickCount){& $world.OnTick}}}.GetNewClosure()
    $adapters.WriteLog={param($Record)$world.Calls.Add("Log:$($Record.code)");if($world.FailAt -ceq 'WriteLog'){throw 'PRIVATE_LOG_SECRET'};$world.UiFailureRecords.Add($Record)}.GetNewClosure()
    [pscustomobject]@{World=$world;Adapters=$adapters;Identity=$identity;Layout=$layout}
}

function New-CcodTickFixture {
    $fake=New-CcodSupervisorFake
    $shutdown=[pscustomobject][ordered]@{SchemaVersion=1;Name='Fake-Shutdown';Kind='Shutdown';CreatedNew=$false;Handle=[pscustomobject]@{Kind='Shutdown'};Disposed=$false}
    $state=[pscustomobject]@{AutomationEnabled=$true;AutomaticCandidateTrialsAllowed=$false;Settings=[pscustomobject]@{candidateCompatibleOptIn=$false};VerifiedPackages=[pscustomobject][ordered]@{schemaVersion=1;packages=[ordered]@{}};Damage=[pscustomobject]@{}}
    [void](& $fake.Adapters.EnterLifecycleOwnership $fake.Layout.InstallRoot $fake.Layout.RuntimeId ([UInt64]7) ([pscustomobject][ordered]@{pid=$fake.Identity.Pid;creationTimeUtc=$fake.Identity.CreationTimeUtc}) $fake.Identity.UserSid $fake.Identity.SessionId 5000)
    $wake=& $fake.Adapters.OpenLifecycleWakeEvent $fake.Identity.UserSid $fake.Identity.SessionId
    $hostState=New-CcodSupervisorHostState -Identity $fake.Identity -Layout $fake.Layout -Clock ([pscustomobject]@{Kind='Clock'}) -ShutdownEvent $shutdown -LifecycleWakeEvent $wake -CommandQueue $fake.World.CommandQueue -EventQueue $fake.World.EventQueue -State $state -Journal $null -LifecycleOwnership $fake.World.LifecycleOwnership -LifecycleRequest $fake.World.ActiveLifecycleRequest -LogonIdentity $fake.World.LogonIdentity
    $hostState.Tray=[pscustomobject]@{Kind='Tray';RenderedLanguageMode='System';RenderedCatalog=$script:TestSystemCatalog;RenderedText='old-stable'}
    $hostState.UiLanguageMode='System';$hostState.UiCatalog=$script:TestSystemCatalog
    [pscustomobject]@{Fake=$fake;Host=$hostState}
}

function New-CcodLanguageRecoveryFixture {
    param(
        [ValidateSet('None','BeforeWrite','AfterWrite')][string]$PreferenceRollbackFailure='None',
        [bool]$TrayRecoveryFailure=$false
    )
    $fixture=New-CcodTickFixture;$world=$fixture.Fake.World;$hostState=$fixture.Host
    $renderAttempts=[Collections.Generic.List[string]]::new();$renderCount=[pscustomobject]@{Value=0}
    $systemCatalog=$script:TestSystemCatalog;$englishCatalog=$script:TestEnglishCatalog
    $fixture.Fake.Adapters.SetUiLanguageMode={
        param($StateRoot,$Mode)
        $world.Calls.Add("Persist:UiLanguage:$Mode");$world.SetUiLanguageModes.Add($Mode)
        if($Mode -ceq 'System' -and $PreferenceRollbackFailure -ceq 'BeforeWrite'){throw 'PRIVATE_PREFERENCE_ROLLBACK_BEFORE_WRITE'}
        $world.StoredLanguageMode=$Mode
        if($Mode -ceq 'System' -and $PreferenceRollbackFailure -ceq 'AfterWrite'){throw 'PRIVATE_PREFERENCE_ROLLBACK_AFTER_WRITE'}
    }.GetNewClosure()
    $fixture.Fake.Adapters.ReadUiPreference={
        param($StateRoot)
        $world.Calls.Add('Read:UiPreference:Recovery')
        [pscustomobject][ordered]@{LanguageMode=[string]$world.StoredLanguageMode;FallbackUsed=$false;ErrorCode=$null}
    }.GetNewClosure()
    $fixture.Fake.Adapters.SetTrayPresentation={
        param($Tray,$Presentation,$Catalog,$LanguageMode,$SystemCultureName)
        $renderCount.Value++;$renderAttempts.Add($LanguageMode)
        $world.PresentationArguments.Add([pscustomobject][ordered]@{Tray=$Tray;Presentation=$Presentation;Catalog=$Catalog;LanguageMode=$LanguageMode;SystemCultureName=$SystemCultureName})
        $Tray.RenderedLanguageMode=$LanguageMode;$Tray.RenderedCatalog=$Catalog
        if($renderCount.Value -eq 1){$Tray.RenderedText='new-partial';throw 'PRIVATE_PARTIAL_NEW_RENDER'}
        if($TrayRecoveryFailure){$Tray.RenderedText='recovery-partial';throw 'PRIVATE_RECOVERY_RENDER'}
        if($LanguageMode -ceq 'System'){$Tray.RenderedText='old-restored';$Tray.RenderedCatalog=$systemCatalog}
        elseif($LanguageMode -ceq 'en-US'){$Tray.RenderedText='new-restored';$Tray.RenderedCatalog=$englishCatalog}
        else{throw 'PRIVATE_UNEXPECTED_RECOVERY_MODE'}
    }.GetNewClosure()
    [pscustomobject]@{Fixture=$fixture;World=$world;Host=$hostState;RenderAttempts=$renderAttempts}
}

function New-CcodTestTransition {
    [pscustomobject][ordered]@{
        transactionId='5f496d99-c839-4458-a6a2-d37ea1afdbda';stage='IntentWritten';sourcePid=71;sourceCreationTimeUtc='2030-02-03T03:01:00.0000000Z'
        packageFullName='OpenAI.Codex_1.0.0.0_x64__2p2nqsd0c76g0';appAsarSha256=('b'*64);runtimeId='runtime-1';mainPort=41002;rendererPort=41001
        specialPid=$null;specialCreationTimeUtc=$null;recoveryPid=$null;recoveryCreationTimeUtc=$null;createdAtUtc='2030-02-03T03:02:00.0000000Z';updatedAtUtc='2030-02-03T03:02:00.0000000Z'
    }
}

function New-CcodSupervisorTestSnapshot {
    param([int]$ProcessId=71,[string]$CreationTimeUtc='2030-02-03T03:01:00.0000000Z')
    [pscustomobject][ordered]@{
        Pid=[int]$ProcessId
        CreationTimeUtc=[string]$CreationTimeUtc
        SessionId=[int]1
        UserSid='S-1-5-21-111-222-333-1001'
        Path='C:\Program Files\WindowsApps\OpenAI.Codex_1.0.0.0_x64__2p2nqsd0c76g0\ChatGPT.exe'
        PackageFamilyName='OpenAI.Codex_1.0.0.0_x64__2p2nqsd0c76g0'
        CommandLine='"C:\Program Files\WindowsApps\OpenAI.Codex_1.0.0.0_x64__2p2nqsd0c76g0\ChatGPT.exe"'
        ParentPid=[int]0
        IsTopLevel=$true
        Mode='Ordinary'
        RendererPort=$null
        MainPort=$null
    }
}

function New-CcodPersistedLifecycleRequest {
    param(
        [ValidateSet('RestartAndRepair','CheckAndRepair','SafeExit')][string]$Kind='CheckAndRepair',
        [ValidateSet('Requested','WaitingForManualLaunch')][string]$Phase='Requested',
        [string]$TransactionId='11111111-2222-3333-4444-555555555555'
    )
    $owner=[pscustomobject][ordered]@{pid=[int]41;creationTimeUtc='2030-02-03T03:00:00.0000000Z'}
    $logon=[pscustomobject][ordered]@{authenticationId='00000000:00001234';userSid='S-1-5-21-111-222-333-1001';sessionId=[int]1}
    $coordinatorModule=Import-Module $lifecycleCoordinatorPath -Force -PassThru -WarningAction SilentlyContinue
    $transactionModule=Import-Module $lifecycleTransactionPath -Force -PassThru
    $request=& $transactionModule {param($K,$Owner,$Logon,$Id)New-CcodLifecycleRequest -Kind $K -Origin Guardian -RuntimeId 'runtime-1' -RuntimeGeneration 7 -LeaseEpoch 11 -OwnerIdentity $Owner -LogonIdentity $Logon -NowUtc '2030-02-03T03:01:00.0000000Z' -TransactionId $Id} $Kind $owner $logon $TransactionId
    if($Phase -ceq 'WaitingForManualLaunch'){
        $request=& $transactionModule {param($Value)Move-CcodLifecyclePhase $Value CloseRequested '2030-02-03T03:01:01.0000000Z'} $request
        $request=& $transactionModule {param($Value)Move-CcodLifecyclePhase $Value CloseConfirmed '2030-02-03T03:01:02.0000000Z'} $request
        $request=& $transactionModule {param($Value)Move-CcodLifecyclePhase $Value OrdinaryLaunchRequested '2030-02-03T03:01:03.0000000Z'} $request
        $request.automaticLaunchAttempts=3
        $request.launchRequestedAtUtc='2030-02-03T03:01:03.0000000Z'
        $request.manualLaunchExpiresAtUtc='2030-02-03T03:20:00.0000000Z'
        $request=& $transactionModule {param($Value)Move-CcodLifecyclePhase $Value WaitingForManualLaunch '2030-02-03T03:01:04.0000000Z'} $request
    }
    return $request
}

$results=[Collections.Generic.List[string]]::new()
function Invoke-CcodTest {
    param([string]$Name,[scriptblock]$Body)
    & $Body
    $results.Add($Name);Write-Output "PASS $Name"
}

Invoke-CcodTest 'exposes only the frozen ReadyToken CLI and rejects an invalid token before adapters' {
    $parameters=(Get-Command $supervisorPath).Parameters.Keys|Where-Object{$_ -notin @('Verbose','Debug','ErrorAction','WarningAction','InformationAction','ErrorVariable','WarningVariable','InformationVariable','OutVariable','OutBuffer','PipelineVariable')}
    Assert-CcodEqual 'ReadyToken' (@($parameters)-join '|') 'Supervisor CLI has one business parameter'
    $fake=New-CcodSupervisorFake
    $receipt=Invoke-CcodSupervisorHost -ReadyToken ('A'*64) -Adapters $fake.Adapters
    Assert-CcodReceipt $receipt 'StartupRejected' 2
    Assert-CcodEqual 0 $fake.World.Calls.Count 'invalid token invokes no adapter'
}

Invoke-CcodTest 'acquires both lifetime leases and signals Ready only after all prerequisites' {
    $fake=New-CcodSupervisorFake
    $receipt=Invoke-CcodSupervisorHost -ReadyToken $readyToken -Adapters $fake.Adapters
    Assert-CcodReceipt $receipt 'Stopped' 0
    Assert-CcodEqual 1 $fake.World.ReadySignals 'Ready signals once'
    Assert-CcodTrue $fake.World.NewTraySawRealQueue 'tray receives the command queue itself'
    Assert-CcodTrue $fake.World.NewWatcherSawRealQueue 'watcher receives the event queue itself'
    $calls=@($fake.World.Calls)
    foreach($before in @('Enter:AccountSupervisor:5000','Enter:Supervisor:5000','Read:ActiveRuntime','Read:LogonIdentity','Enter:LifecycleOwnership:7','Open:Ready','Open:Shutdown','Open:LifecycleWake','Read:State','Read:Journal','Read:LifecycleRequest','Read:UiPreference','Get:SystemCulture','Get:UiCatalog:System','Queue:Command','Queue:Event','New:Tray','New:Watcher')){
        Assert-CcodTrue ([Array]::IndexOf($calls,$before) -ge 0) "$before occurs"
        Assert-CcodTrue ([Array]::IndexOf($calls,$before) -lt [Array]::IndexOf($calls,'Signal:Ready')) "$before precedes Ready"
    }
    Assert-CcodTrue ([object]::ReferenceEquals($script:TestSystemCatalog,$fake.World.TrayArguments.Catalog)) 'tray receives the validated initial catalog'
    Assert-CcodEqual 'System' $fake.World.TrayArguments.LanguageMode 'tray receives exact initial mode'
    Assert-CcodEqual 'zh-CN' $fake.World.TrayArguments.SystemCultureName 'tray receives system culture'
    Assert-CcodTrue ([Array]::IndexOf($calls,'Signal:Ready') -lt [Array]::IndexOf($calls,'Run:UI')) 'Ready precedes message loop'
    Assert-CcodEqual 1 $fake.World.LifecycleOwnershipEntries 'Supervisor enters one lifecycle epoch'
    Assert-CcodEqual 1 $fake.World.LifecycleOwnershipExits 'Supervisor releases one lifecycle epoch'
    Assert-CcodTrue ([Array]::IndexOf($calls,'Exit:LifecycleOwnership:11') -lt [Array]::IndexOf($calls,'Exit:Supervisor')) 'lifecycle ownership releases before lifetime leases'
    Assert-CcodTrue ([Array]::IndexOf($calls,'Exit:Supervisor') -lt [Array]::IndexOf($calls,'Exit:AccountSupervisor')) 'leases release in reverse order'
}

Invoke-CcodTest 'uses one monotonic 5000ms acquisition budget' {
    $fake=New-CcodSupervisorFake
    $fake.World.Elapsed.Enqueue([long]0);$fake.World.Elapsed.Enqueue([long]4200)
    $receipt=Invoke-CcodSupervisorHost -ReadyToken $readyToken -Adapters $fake.Adapters
    Assert-CcodReceipt $receipt 'Stopped' 0
    Assert-CcodTrue ($fake.World.Calls.Contains('Enter:AccountSupervisor:5000')) 'first lease receives full budget'
    Assert-CcodTrue ($fake.World.Calls.Contains('Enter:Supervisor:800')) 'second lease receives only remainder'
}

Invoke-CcodTest 'does not take over or signal Ready when either lifetime lease times out' {
    foreach($case in @(
        [pscustomobject]@{First='TimedOut';Second='Acquired';Expected='Enter:AccountSupervisor:5000';Forbidden='Enter:Supervisor:5000'},
        [pscustomobject]@{First='Acquired';Second='TimedOut';Expected='Enter:Supervisor:5000';Forbidden='Open:Ready'}
    )){
        $fake=New-CcodSupervisorFake -FirstLeaseOutcome $case.First -SecondLeaseOutcome $case.Second
        $receipt=Invoke-CcodSupervisorHost -ReadyToken $readyToken -Adapters $fake.Adapters
        Assert-CcodReceipt $receipt 'StartupRejected' 2
        Assert-CcodEqual 0 $fake.World.ReadySignals 'timeout never signals Ready'
        Assert-CcodTrue ($fake.World.Calls.Contains($case.Expected)) 'expected lease attempt occurs'
        Assert-CcodTrue (-not $fake.World.Calls.Contains($case.Forbidden)) 'timeout prevents takeover path'
        Assert-CcodTrue (@($fake.World.Calls|Where-Object{$_ -like 'Terminate*'}).Count -eq 0) 'timeout never terminates another process'
    }
}

Invoke-CcodTest 'treats abandoned leases as ownership and records only a fixed warning' {
    $fake=New-CcodSupervisorFake -AccountAbandoned $true -LocalAbandoned $true
    $receipt=Invoke-CcodSupervisorHost -ReadyToken $readyToken -Adapters $fake.Adapters
    Assert-CcodReceipt $receipt 'Stopped' 0
    Assert-CcodTrue ($fake.World.Calls.Contains('Log:CCOD_SUPERVISOR_LEASE_ABANDONED')) 'abandonment produces fixed warning code'
    Assert-CcodEqual 1 $fake.World.StateReads 'fresh state is read'
    Assert-CcodEqual 1 $fake.World.JournalReads 'fresh journal is read'
}

Invoke-CcodTest 'never signals Ready when Shutdown is already signaled' {
    $fake=New-CcodSupervisorFake -ShutdownSignaled $true
    $receipt=Invoke-CcodSupervisorHost -ReadyToken $readyToken -Adapters $fake.Adapters
    Assert-CcodReceipt $receipt 'StartupRejected' 2
    Assert-CcodEqual 0 $fake.World.ReadySignals 'pre-signaled Shutdown blocks Ready'
    Assert-CcodTrue (-not $fake.World.Calls.Contains('Run:UI')) 'message loop never starts'
    Assert-CcodTrue ($fake.World.Calls.Contains('Close:Shutdown')) 'Shutdown handle is still closed'
}

Invoke-CcodTest 'contains initialization secrets and runs every available cleanup stage' {
    foreach($stage in @('ReadActiveRuntime','GetTrustedLogonIdentity','EnterLifecycleOwnership','OpenLifecycleWake','ReadState','ReadJournal','ReadLifecycleRequest','ReadUiPreference','GetUiCatalog','NewTray','NewWatcher','SignalReady','RunUi')){
        $fake=New-CcodSupervisorFake -FailAt $stage
        $receipt=Invoke-CcodSupervisorHost -ReadyToken $readyToken -Adapters $fake.Adapters
        Assert-CcodReceipt $receipt 'Failed' 1
        Assert-CcodEqual 0 (($receipt|ConvertTo-Json -Compress).Contains('PRIVATE_')) "$stage secret is absent from receipt"
        Assert-CcodTrue ($fake.World.Calls.Contains('Exit:Supervisor')) "$stage releases local lease"
        Assert-CcodTrue ($fake.World.Calls.Contains('Exit:AccountSupervisor')) "$stage releases account lease"
    }
}

Invoke-CcodTest 'continues cleanup after timer watcher tray event and lease failures' {
    foreach($stage in @('StopTimer','StopWatcher','CloseTray','CloseReady','CloseShutdown','CloseLifecycleWake','ExitLifecycleOwnership','ExitSupervisor','ExitAccountSupervisor')){
        $fake=New-CcodSupervisorFake -FailAt $stage
        $receipt=Invoke-CcodSupervisorHost -ReadyToken $readyToken -Adapters $fake.Adapters
        Assert-CcodReceipt $receipt 'Stopped' 0
        Assert-CcodTrue ($receipt.CleanupCodes.Count -ge 1) "$stage yields a bounded cleanup code"
        Assert-CcodTrue ($fake.World.Calls.Contains('Exit:AccountSupervisor')) "$stage does not skip final account release attempt"
        Assert-CcodEqual 0 (($receipt|ConvertTo-Json -Compress).Contains('PRIVATE_')) "$stage secret is absent from cleanup receipt"
    }
}

Invoke-CcodTest 'surviving lifecycle worker keeps framing and lifecycle ownership contained' {
    $fake=New-CcodSupervisorFake
    $fake.World.LifecycleSubmissions.Enqueue([pscustomobject][ordered]@{schemaVersion=1;submissionId='dddddddd-eeee-ffff-0000-111111111111';kind='RestartAndRepair';origin='Installer';runtimeId='runtime-1';runtimeGeneration=[UInt64]7;createdAtUtc='2030-02-03T03:04:05.0000000Z'})
    foreach($value in @($false,$false,$false)){$fake.World.WorkerWaitResults.Enqueue($value)}
    foreach($value in @($false,$false)){$fake.World.WorkerTerminateResults.Enqueue($value)}
    $fake.World.TickCount=1
    $receipt=Invoke-CcodSupervisorHost -ReadyToken $readyToken -Adapters $fake.Adapters
    Assert-CcodReceipt $receipt 'Stopped' 0
    Assert-CcodTrue ($receipt.CleanupCodes-ccontains'CCOD_SUPERVISOR_WORKER_SURVIVED') 'survivor produces one stable cleanup diagnostic'
    Assert-CcodEqual 0 @($fake.World.Calls|Where-Object{$_ -like 'Dispose:*' -or $_ -like 'Delete:*'}).Count 'survivor retains process Job gate and framing files'
    Assert-CcodEqual 0 @($fake.World.Calls|Where-Object{$_ -like 'Exit:LifecycleOwnership:*' -or $_ -eq 'Exit:Supervisor' -or $_ -eq 'Exit:AccountSupervisor'}).Count 'survivor prevents every explicit ownership release'
}

Invoke-CcodTest 'shutdown waits and cleans a reachable StaticProbe before lifecycle ownership release' {
    $fake=New-CcodSupervisorFake;$target=New-CcodSupervisorTestSnapshot
    $fake.World.ProcessIds=@([int]$target.Pid);$fake.World.Snapshots[[int]$target.Pid]=$target
    $fake.World.Decision=[pscustomobject][ordered]@{Action='InspectOrdinary';Reason='StaticProbeRequired';Target=$target;AttemptKey='71|2030-02-03T03:01:00.0000000Z';SuppressionKey=$null;EffectiveClassification=$null;RequiresController=$true}
    $fake.World.TickCount=1
    $receipt=Invoke-CcodSupervisorHost -ReadyToken $readyToken -Adapters $fake.Adapters
    Assert-CcodReceipt $receipt 'Stopped' 0
    $calls=@($fake.World.Calls);$wait=[Array]::IndexOf($calls,'Wait:Worker:2000');$dispose=[Array]::IndexOf($calls,'Dispose:501');$release=[Array]::IndexOf($calls,'Exit:LifecycleOwnership:11')
    Assert-CcodTrue ($wait-ge0-and$dispose-gt$wait-and$release-gt$dispose) 'StaticProbe exit is proven and handles/files are cleaned before epoch release'
    Assert-CcodEqual 2 @($calls|Where-Object{$_ -like 'Delete:static-probe-*'}).Count 'StaticProbe request and result framing are both removed'
}

Invoke-CcodTest 'rejects malformed or partial adapter sets before any lifecycle action' {
    $fake=New-CcodSupervisorFake
    [void]$fake.Adapters.Remove('OpenReadyEvent')
    $receipt=Invoke-CcodSupervisorHost -ReadyToken $readyToken -Adapters $fake.Adapters
    Assert-CcodReceipt $receipt 'StartupRejected' 2
    Assert-CcodEqual 0 $fake.World.Calls.Count 'partial adapter set invokes nothing'
    $fake2=New-CcodSupervisorFake;$fake2.Adapters.Extra={}
    $receipt2=Invoke-CcodSupervisorHost -ReadyToken $readyToken -Adapters $fake2.Adapters
    Assert-CcodReceipt $receipt2 'StartupRejected' 2
    Assert-CcodEqual 0 $fake2.World.Calls.Count 'extra adapter set invokes nothing'
}

Invoke-CcodTest 'routes one uninstall launch and contains launch receipt and dialog failures without stopping Supervisor or Codex' {
    $success=New-CcodTickFixture;$successWorld=$success.Fake.World;$successHost=$success.Host
    $successState=$successHost.State;$successQueue=$successHost.CommandQueue;$successTray=$successHost.Tray;$successSession=$successHost.SessionState
    $starts=[Collections.Generic.List[object]]::new()
    $success.Fake.Adapters.StartUninstall={
        param($InstallRoot,$RuntimeRoot,$PowerShellPath)
        $starts.Add([pscustomobject][ordered]@{InstallRoot=$InstallRoot;RuntimeRoot=$RuntimeRoot;PowerShellPath=$PowerShellPath})
        [pscustomobject][ordered]@{Started=$true;Pid=[int]5050;CreationTimeUtc='2030-02-03T03:06:00.0000000Z'}
    }.GetNewClosure()
    $command=[pscustomobject][ordered]@{Kind='Uninstall';Value=$null;EnqueuedAtUtc='2026-08-05T00:00:00.0000000Z'}
    Assert-CcodEqual 0 @(Invoke-CcodSupervisorCommand -Command $command -HostState $successHost -Adapters $success.Fake.Adapters).Count 'successful uninstall routing emits no output'
    Assert-CcodEqual 1 $starts.Count 'one verified launcher call occurs'
    Assert-CcodEqual $success.Fake.Layout.InstallRoot $starts[0].InstallRoot 'launcher receives exact install root'
    Assert-CcodEqual $success.Fake.Layout.RuntimeRoot $starts[0].RuntimeRoot 'launcher receives exact runtime root'
    Assert-CcodEqual $success.Fake.Layout.PowerShellPath $starts[0].PowerShellPath 'launcher receives exact PowerShell host'
    Assert-CcodEqual $false $successHost.ShutdownRequested 'successful launch does not request direct shutdown'
    Assert-CcodEqual 0 @($successWorld.Calls|Where-Object{$_ -ceq 'Exit:UI'}).Count 'successful launch does not request direct UI exit'
    Assert-CcodTrue ([object]::ReferenceEquals($successState,$successHost.State) -and [object]::ReferenceEquals($successQueue,$successHost.CommandQueue) -and [object]::ReferenceEquals($successTray,$successHost.Tray) -and $successHost.SessionState -ceq $successSession) 'successful launch leaves Supervisor and current Codex state running'

    foreach($mode in @('Throw','Malformed')){
        $failure=New-CcodTickFixture;$world=$failure.Fake.World;$failureHost=$failure.Host
        $oldState=$failureHost.State;$oldQueue=$failureHost.CommandQueue;$oldTray=$failureHost.Tray;$oldSession=$failureHost.SessionState;$oldBlock=$failureHost.BlockAutomaticActions
        if($mode -ceq 'Throw'){$failure.Fake.Adapters.StartUninstall={param($InstallRoot,$RuntimeRoot,$PowerShellPath)throw 'PRIVATE_UNINSTALL_PATH_OR_TOKEN'}}
        else{$failure.Fake.Adapters.StartUninstall={param($InstallRoot,$RuntimeRoot,$PowerShellPath)[pscustomobject][ordered]@{Started='true';Pid=0;CreationTimeUtc='bad';Extra='secret'}}}
        Assert-CcodEqual 0 @(Invoke-CcodSupervisorCommand -Command $command -HostState $failureHost -Adapters $failure.Fake.Adapters).Count "$mode launcher failure emits no output"
        Assert-CcodEqual 'UninstallStart|CCOD_UNINSTALL_START_FAILED' (($world.UiFailureRecords|ForEach-Object{"$($_.stage)|$($_.code)"})-join ',') "$mode launcher failure logs one stable record"
        Assert-CcodTrue (($world.UiFailureRecords|ConvertTo-Json -Compress) -cnotmatch 'PRIVATE|Fake|CodexControlOtherDevices|secret|token') "$mode log contains no exception path or input"
        Assert-CcodEqual 1 $world.TrayErrors.Count "$mode launcher failure shows one localized error"
        Assert-CcodEqual 'Error.UninstallStart' $world.TrayErrors[0].Key "$mode error key is exact"
        Assert-CcodTrue ([object]::ReferenceEquals($failureHost.UiCatalog,$world.TrayErrors[0].Catalog)) "$mode dialog uses the existing validated catalog"
        Assert-CcodEqual $false $failureHost.ShutdownRequested "$mode failure does not request direct shutdown"
        Assert-CcodEqual 0 @($world.Calls|Where-Object{$_ -ceq 'Exit:UI'}).Count "$mode failure does not request UI exit"
        Assert-CcodTrue ([object]::ReferenceEquals($oldState,$failureHost.State) -and [object]::ReferenceEquals($oldQueue,$failureHost.CommandQueue) -and [object]::ReferenceEquals($oldTray,$failureHost.Tray) -and $failureHost.SessionState -ceq $oldSession -and $failureHost.BlockAutomaticActions -eq $oldBlock) "$mode failure leaves Supervisor and current Codex state running"
    }

    $dialog=New-CcodTickFixture;$dialogWorld=$dialog.Fake.World;$dialogHost=$dialog.Host
    $dialog.Fake.Adapters.StartUninstall={param($InstallRoot,$RuntimeRoot,$PowerShellPath)throw 'PRIVATE_START_SECRET'}
    $dialog.Fake.Adapters.ShowTrayError={param($Tray,$Catalog,$Key)throw 'PRIVATE_DIALOG_SECRET'}
    Assert-CcodEqual 0 @(Invoke-CcodSupervisorCommand -Command $command -HostState $dialogHost -Adapters $dialog.Fake.Adapters).Count 'dialog failure is contained with no output'
    Assert-CcodEqual 'CCOD_UNINSTALL_START_FAILED,CCOD_UI_ERROR_DIALOG_FAILED' (@($dialogWorld.UiFailureRecords.code)-join ',') 'dialog failure is logged separately after launch failure'
    Assert-CcodEqual $false $dialogHost.ShutdownRequested 'dialog failure leaves Supervisor running'
    Assert-CcodEqual 0 @($dialogWorld.Calls|Where-Object{$_ -ceq 'Exit:UI'}).Count 'dialog failure leaves tray loop running'
}

Invoke-CcodTest 'adds the exact localization adapters and host fields at the frozen boundaries' {
    $names=Get-CcodSupervisorAdapterNames
    $first=[Array]::IndexOf($names,'ReadUiPreference')
    Assert-CcodTrue ($first -ge 0) 'ReadUiPreference adapter exists'
    Assert-CcodEqual 'ReadUiPreference,SetUiLanguageMode,GetSystemCultureName,GetUiCatalog,ShowTrayError,StartUninstall' (@($names[$first..($first+5)])-join ',') 'localization and uninstall adapter order is exact'
    foreach($name in @('ReadActiveRuntime','GetTrustedLogonIdentity','EnterLifecycleOwnership','AssertLifecycleFence','ExitLifecycleOwnership','OpenLifecycleWakeEvent','ResetLifecycleWakeEvent','ReadLifecycleRequest','ReceiveLifecycleSubmissions','WriteLifecycleSubmissionReceipt','NewLifecycleRequest','WriteLifecycleRequest','MoveLifecyclePhase','CompleteLifecycleRequest','GetLifecycleStep','ReduceLifecycleWorkerResult','NewLifecycleWorkerRequest','AssertLifecycleWorkerResult')){
        Assert-CcodTrue ($names -ccontains $name) "$name lifecycle adapter exists"
    }
    $fixture=New-CcodTickFixture
    $hostNames=@($fixture.Host.PSObject.Properties.Name)
    $trayIndex=[Array]::IndexOf($hostNames,'Tray')
    Assert-CcodEqual 'Tray,TrayCallbackFailureLogged,UiLanguageMode,UiCatalog,State' (@($hostNames[$trayIndex..($trayIndex+4)])-join ',') 'UI host fields occur immediately after Tray'
    foreach($name in @('LifecycleOwnership','LifecycleRequest','LifecycleWorkerSlot','ConnectionState','ProtectionState')){Assert-CcodTrue ($hostNames -ccontains $name) "$name host field exists"}
}

Invoke-CcodTest 'accepts at most one of two simultaneous durable submissions and rejects the other while busy' {
    $fake=New-CcodSupervisorFake
    foreach($id in @('aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee','bbbbbbbb-cccc-dddd-eeee-ffffffffffff')){
        $fake.World.LifecycleSubmissions.Enqueue([pscustomobject][ordered]@{schemaVersion=1;submissionId=$id;kind='RestartAndRepair';origin='Installer';runtimeId='runtime-1';runtimeGeneration=[UInt64]7;createdAtUtc='2030-02-03T03:04:05.0000000Z'})
    }
    $fake.World.TickCount=2
    $receipt=Invoke-CcodSupervisorHost -ReadyToken $readyToken -Adapters $fake.Adapters
    Assert-CcodReceipt $receipt 'Stopped' 0
    Assert-CcodEqual 2 $fake.World.LifecycleSubmissionReceipts.Count 'both submissions receive one bounded decision'
    Assert-CcodEqual 1 @($fake.World.LifecycleSubmissionReceipts|Where-Object{$_.accepted}).Count 'only one submission is accepted'
    Assert-CcodEqual 1 @($fake.World.LifecycleSubmissionReceipts|Where-Object{-not $_.accepted -and $_.errorCode -ceq 'CCOD_LIFECYCLE_SUPERVISOR_BUSY'}).Count 'second submission is rejected busy'
    Assert-CcodTrue ($null -ne $fake.World.ActiveLifecycleRequest) 'one accepted lifecycle remains durable'
    Assert-CcodEqual 1 $fake.World.LifecycleOwnershipEntries 'simultaneous submissions share one ownership epoch'
    Assert-CcodEqual 0 @($fake.World.Calls|Where-Object{$_ -like 'Start:Controller:*'}).Count 'submission acceptance never dispatches legacy controller mutation'
}

Invoke-CcodTest 'rejects a durable submission for a stale runtime generation without creating a transaction' {
    $fake=New-CcodSupervisorFake
    $fake.World.LifecycleSubmissions.Enqueue([pscustomobject][ordered]@{schemaVersion=1;submissionId='cccccccc-dddd-eeee-ffff-000000000000';kind='RestartAndRepair';origin='Installer';runtimeId='runtime-1';runtimeGeneration=[UInt64]6;createdAtUtc='2030-02-03T03:04:05.0000000Z'})
    $fake.World.TickCount=1
    $receipt=Invoke-CcodSupervisorHost -ReadyToken $readyToken -Adapters $fake.Adapters
    Assert-CcodReceipt $receipt 'Stopped' 0
    Assert-CcodEqual 1 $fake.World.LifecycleSubmissionReceipts.Count 'stale generation receives one rejection'
    Assert-CcodEqual 'CCOD_LIFECYCLE_RUNTIME_STALE' $fake.World.LifecycleSubmissionReceipts[0].errorCode 'stale generation error is stable'
    Assert-CcodEqual $null $fake.World.ActiveLifecycleRequest 'stale generation creates no active lifecycle'
    Assert-CcodEqual 0 @($fake.World.Calls|Where-Object{$_ -like 'Start:*'}).Count 'stale generation dispatches no worker'
}

Invoke-CcodTest 'resumes WaitingForManualLaunch after Supervisor restart and completes Apply under one epoch' {
    $fake=New-CcodSupervisorFake
    $fake.World.ActiveLifecycleRequest=New-CcodPersistedLifecycleRequest -Phase WaitingForManualLaunch
    $fake.World.ActiveLifecycleRequest.leaseEpoch=[UInt64]10
    $fake.World.ActiveLifecycleRequest.ownerIdentity=[pscustomobject][ordered]@{pid=[int]40;creationTimeUtc='2030-02-03T02:59:00.0000000Z'}
    $ordinary=New-CcodSupervisorTestSnapshot -ProcessId 71
    $fake.World.ProcessIds=@([int]71);$fake.World.Snapshots[[int]71]=$ordinary
    $fake.World.AutoCompleteLifecycleWorkers=$true;$fake.World.TickCount=6
    $receipt=Invoke-CcodSupervisorHost -ReadyToken $readyToken -Adapters $fake.Adapters
    Assert-CcodReceipt $receipt 'Stopped' 0
    Assert-CcodEqual 1 $fake.World.CompletedLifecycleRequests.Count 'resumed transaction reaches one terminal completion'
    Assert-CcodEqual 'Completed' $fake.World.CompletedLifecycleRequests[0].phase 'resumed transaction completes'
    Assert-CcodEqual 'WaitingForManualLaunch|OrdinaryObserved|RepairRequested|RepairRequested|RemoteVerified|Completed' (@($fake.World.LifecycleWrites.phase)-join '|') 'resume rebinds then persists every Task 1 reducer state including null-phase Apply result'
    Assert-CcodEqual 'OrdinaryObserved|RepairRequested|Completed' (@($fake.World.LifecycleMoves)-join '|') 'Supervisor never calls Move for the null-phase Apply reduction'
    Assert-CcodEqual 'Apply|VerifyRemote' (@($fake.World.StartedLifecycleRequests.action)-join '|') 'resume executes one action per lifecycle worker'
    foreach($request in @($fake.World.StartedLifecycleRequests)){
        Assert-CcodEqual 11 $request.leaseEpoch 'every worker request keeps the one Supervisor epoch'
        Assert-CcodEqual 7 $request.runtimeGeneration 'every worker request keeps the active generation'
    }
    Assert-CcodEqual 1 $fake.World.LifecycleOwnershipEntries 'Supervisor restart enters one ownership epoch'
    Assert-CcodEqual 0 @($fake.World.Calls|Where-Object{$_ -like 'Start:Controller:*'}).Count 'resume performs no mutation outside LifecycleWorker slot'
}

Invoke-CcodTest 'treats error-free CancelledBeforeClose as successful already-satisfied completion without mutation' {
    foreach($case in @(
        [pscustomobject]@{Kind='CheckAndRepair';Observation='RemoteVerified';Connection='Connected';Id='40000000-0000-0000-0000-000000000001'},
        [pscustomobject]@{Kind='SafeExit';Observation='Ordinary';Connection='Ordinary';Id='40000000-0000-0000-0000-000000000002'},
        [pscustomobject]@{Kind='SafeExit';Observation='NoCodex';Connection='Disconnected';Id='40000000-0000-0000-0000-000000000003'}
    )){
        $fixture=New-CcodTickFixture;$world=$fixture.Fake.World;$hostState=$fixture.Host
        $request=New-CcodPersistedLifecycleRequest -Kind $case.Kind -TransactionId $case.Id
        $world.ActiveLifecycleRequest=$request;$hostState.LifecycleRequest=$request;$hostState.LifecycleObservation=$case.Observation
        $hostState.ObservationDirty=$false;$hostState.ForceReconcile=$false;$hostState.NextObservationMilliseconds=[long]1000
        $world.Calls.Clear();Invoke-CcodSupervisorTick $hostState $fixture.Fake.Adapters
        Assert-CcodEqual 1 $world.CompletedLifecycleRequests.Count "$($case.Kind) $($case.Observation) completes once"
        Assert-CcodEqual 'CancelledBeforeClose' $world.CompletedLifecycleRequests[0].phase 'already-satisfied phase is the legal terminal edge'
        Assert-CcodEqual $null $world.CompletedLifecycleRequests[0].error 'already-satisfied completion carries no error'
        Assert-CcodEqual $case.Connection $hostState.ConnectionState 'connection state remains truthful after no-op completion'
        Assert-CcodEqual 'Running' $hostState.ProtectionState 'owned Supervisor protection remains running'
        Assert-CcodEqual 0 @($world.Calls|Where-Object{$_ -like 'Start:*'}).Count 'already-satisfied completion starts no worker mutation'
    }
}

Invoke-CcodTest 'commits one valid UI language command before refreshing the existing tray in place' {
    $fixture=New-CcodTickFixture;$world=$fixture.Fake.World;$hostState=$fixture.Host
    $tray=$hostState.Tray;$oldState=$hostState.State;$oldQueue=$hostState.CommandQueue
    $command=[pscustomobject][ordered]@{Kind='SetUiLanguage';Value='en-US';EnqueuedAtUtc='2026-08-05T00:00:00.0000000Z'}
    Assert-CcodEqual 0 @(Invoke-CcodSupervisorCommand -Command $command -HostState $hostState -Adapters $fixture.Fake.Adapters).Count 'language command emits no output'
    Assert-CcodEqual 'en-US' $hostState.UiLanguageMode 'mode changes only after persistence'
    Assert-CcodTrue ([object]::ReferenceEquals($script:TestEnglishCatalog,$hostState.UiCatalog)) 'catalog refreshes immediately'
    Assert-CcodEqual 'en-US' $world.StoredLanguageMode 'atomic preference stores exact mode'
    Assert-CcodEqual 1 $world.SetUiLanguageModes.Count 'one atomic write occurs'
    Assert-CcodEqual 1 $world.PresentationArguments.Count 'existing tray refreshes once'
    $render=$world.PresentationArguments[0]
    Assert-CcodTrue ([object]::ReferenceEquals($tray,$render.Tray)) 'tray is not recreated'
    Assert-CcodTrue ([object]::ReferenceEquals($script:TestEnglishCatalog,$render.Catalog)) 'new validated catalog is rendered'
    Assert-CcodEqual 'en-US' $render.LanguageMode 'render receives exact new mode'
    Assert-CcodEqual $true $render.WaitForAcknowledgement 'language render waits for the native TrayHost acknowledgement before returning'
    Assert-CcodTrue ([object]::ReferenceEquals($oldState,$hostState.State) -and [object]::ReferenceEquals($oldQueue,$hostState.CommandQueue)) 'controller state and bounded queue remain running'
    $calls=@($world.Calls)
    Assert-CcodTrue ([Array]::IndexOf($calls,'Get:UiCatalog:en-US') -lt [Array]::IndexOf($calls,'Persist:UiLanguage:en-US')) 'catalog validation precedes persistence'
    Assert-CcodTrue ([Array]::IndexOf($calls,'Persist:UiLanguage:en-US') -lt [Array]::IndexOf($calls,'Set:Presentation')) 'tray mutates only after persistence'
}

Invoke-CcodTest 'restores the existing tray with the old catalog after a new-language render failure' {
    $recovery=New-CcodLanguageRecoveryFixture;$fixture=$recovery.Fixture;$world=$recovery.World;$hostState=$recovery.Host
    $oldCatalog=$hostState.UiCatalog;$controllerState=$hostState.State;$queue=$hostState.CommandQueue;$session=$hostState.SessionState;$blocked=$hostState.BlockAutomaticActions
    $command=[pscustomobject][ordered]@{Kind='SetUiLanguage';Value='en-US';EnqueuedAtUtc='2026-08-05T00:00:00.0000000Z'}
    Assert-CcodEqual 0 @(Invoke-CcodSupervisorCommand -Command $command -HostState $hostState -Adapters $fixture.Fake.Adapters).Count 'render failure and rollback emit no output'
    Assert-CcodEqual 'en-US,System' (@($recovery.RenderAttempts)-join ',') 'partial new render is followed by one old-mode tray redraw'
    Assert-CcodEqual 'old-restored' $hostState.Tray.RenderedText 'old redraw reverses the observable partial new-language text'
    Assert-CcodEqual 'System' $hostState.Tray.RenderedLanguageMode 'visible tray returns to old language'
    Assert-CcodTrue ([object]::ReferenceEquals($oldCatalog,$hostState.Tray.RenderedCatalog)) 'visible tray returns to old catalog identity'
    Assert-CcodEqual 'en-US,System' (@($world.SetUiLanguageModes)-join ',') 'persisted preference is restored atomically after render failure'
    Assert-CcodEqual 'System' $world.StoredLanguageMode 'stored preference returns to old mode'
    Assert-CcodEqual 'System' $hostState.UiLanguageMode 'host returns to old mode'
    Assert-CcodTrue ([object]::ReferenceEquals($oldCatalog,$hostState.UiCatalog)) 'host returns to old catalog identity'
    Assert-CcodEqual 'LanguageChange|CCOD_UI_LANGUAGE_CHANGE_FAILED' (($world.UiFailureRecords|ForEach-Object{"$($_.stage)|$($_.code)"})-join ',') 'primary failure log remains exact'
    Assert-CcodEqual 1 $world.TrayErrors.Count 'old catalog reports the failed language change'
    Assert-CcodTrue ([object]::ReferenceEquals($controllerState,$hostState.State) -and [object]::ReferenceEquals($queue,$hostState.CommandQueue) -and $hostState.SessionState -ceq $session -and $hostState.BlockAutomaticActions -eq $blocked) 'partial render recovery leaves controller and Codex state unchanged'
}

Invoke-CcodTest 'confirms disk mode after preference rollback failure and aligns host and tray to that known mode' {
    $recovery=New-CcodLanguageRecoveryFixture -PreferenceRollbackFailure BeforeWrite;$fixture=$recovery.Fixture;$world=$recovery.World;$hostState=$recovery.Host
    $controllerState=$hostState.State;$queue=$hostState.CommandQueue;$session=$hostState.SessionState;$blocked=$hostState.BlockAutomaticActions
    $command=[pscustomobject][ordered]@{Kind='SetUiLanguage';Value='en-US';EnqueuedAtUtc='2026-08-05T00:00:00.0000000Z'}
    Assert-CcodEqual 0 @(Invoke-CcodSupervisorCommand -Command $command -HostState $hostState -Adapters $fixture.Fake.Adapters).Count 'preference recovery failure is contained with no output'
    Assert-CcodEqual 'en-US,en-US' (@($recovery.RenderAttempts)-join ',') 'known disk mode is used for the recovery redraw'
    Assert-CcodEqual 'en-US' $world.StoredLanguageMode 'failed old write leaves new mode on disk'
    Assert-CcodEqual 'en-US' $hostState.UiLanguageMode 'host follows confirmed new disk mode'
    Assert-CcodTrue ([object]::ReferenceEquals($script:TestEnglishCatalog,$hostState.UiCatalog)) 'host uses the validated catalog matching confirmed disk mode'
    Assert-CcodEqual 'new-restored' $hostState.Tray.RenderedText 'recovery redraw replaces partial text with a complete known-mode presentation'
    Assert-CcodEqual 'en-US' $hostState.Tray.RenderedLanguageMode 'visible tray follows confirmed disk mode'
    Assert-CcodTrue ([object]::ReferenceEquals($script:TestEnglishCatalog,$hostState.Tray.RenderedCatalog)) 'visible tray uses the catalog matching confirmed disk mode'
    Assert-CcodTrue ($world.Calls.Contains('Read:UiPreference:Recovery')) 'disk preference is read after rollback write failure'
    Assert-CcodEqual 'LanguageChange|CCOD_UI_LANGUAGE_CHANGE_FAILED,LanguagePreferenceRollback|CCOD_UI_LANGUAGE_PREFERENCE_ROLLBACK_FAILED' (($world.UiFailureRecords|ForEach-Object{"$($_.stage)|$($_.code)"})-join ',') 'primary and preference recovery logs are exact and ordered'
    Assert-CcodTrue (($world.UiFailureRecords|ConvertTo-Json -Compress) -cnotmatch 'PRIVATE|Fake|CodexControlOtherDevices|new-partial|en-US') 'recovery logs contain no exception path catalog text or user input'
    Assert-CcodEqual 'Error.LanguageChange' $world.TrayErrors[0].Key 'language error remains best-effort after confirmed-disk recovery'
    Assert-CcodTrue ([object]::ReferenceEquals($script:TestSystemCatalog,$world.TrayErrors[0].Catalog)) 'language error still resolves through the old validated catalog'
    Assert-CcodTrue ([object]::ReferenceEquals($controllerState,$hostState.State) -and [object]::ReferenceEquals($queue,$hostState.CommandQueue) -and $hostState.SessionState -ceq $session -and $hostState.BlockAutomaticActions -eq $blocked) 'preference recovery leaves controller and Codex state unchanged'
}

Invoke-CcodTest 'logs old-tray redraw failure independently and still shows the old-catalog error' {
    $recovery=New-CcodLanguageRecoveryFixture -TrayRecoveryFailure $true;$fixture=$recovery.Fixture;$world=$recovery.World;$hostState=$recovery.Host
    $oldCatalog=$hostState.UiCatalog;$controllerState=$hostState.State;$queue=$hostState.CommandQueue;$session=$hostState.SessionState;$blocked=$hostState.BlockAutomaticActions
    $command=[pscustomobject][ordered]@{Kind='SetUiLanguage';Value='en-US';EnqueuedAtUtc='2026-08-05T00:00:00.0000000Z'}
    Assert-CcodEqual 0 @(Invoke-CcodSupervisorCommand -Command $command -HostState $hostState -Adapters $fixture.Fake.Adapters).Count 'old tray redraw failure is contained with no output'
    Assert-CcodEqual 'System' $world.StoredLanguageMode 'preference rollback still succeeds'
    Assert-CcodEqual 'System' $hostState.UiLanguageMode 'host remains aligned with old disk mode'
    Assert-CcodTrue ([object]::ReferenceEquals($oldCatalog,$hostState.UiCatalog)) 'host retains old catalog'
    Assert-CcodEqual 'recovery-partial' $hostState.Tray.RenderedText 'failed redraw remains explicitly observable as incomplete in the fake boundary'
    Assert-CcodEqual 'LanguageChange|CCOD_UI_LANGUAGE_CHANGE_FAILED,LanguageTrayRollback|CCOD_UI_LANGUAGE_TRAY_ROLLBACK_FAILED' (($world.UiFailureRecords|ForEach-Object{"$($_.stage)|$($_.code)"})-join ',') 'primary and tray recovery logs are exact and ordered'
    Assert-CcodTrue (($world.UiFailureRecords|ConvertTo-Json -Compress) -cnotmatch 'PRIVATE|Fake|CodexControlOtherDevices|recovery-partial|en-US') 'tray recovery log contains no exception path catalog text or user input'
    Assert-CcodEqual 'Error.LanguageChange' $world.TrayErrors[0].Key 'tray recovery failure still shows the language error'
    Assert-CcodTrue ([object]::ReferenceEquals($oldCatalog,$world.TrayErrors[0].Catalog)) 'tray recovery failure still uses old validated catalog for the error'
    Assert-CcodTrue ([object]::ReferenceEquals($controllerState,$hostState.State) -and [object]::ReferenceEquals($queue,$hostState.CommandQueue) -and $hostState.SessionState -ceq $session -and $hostState.BlockAutomaticActions -eq $blocked) 'tray recovery failure leaves controller and Codex state unchanged'
}

Invoke-CcodTest 'contains combined preference and old-tray rollback failures with both stable recovery records' {
    $recovery=New-CcodLanguageRecoveryFixture -PreferenceRollbackFailure AfterWrite -TrayRecoveryFailure $true;$fixture=$recovery.Fixture;$world=$recovery.World;$hostState=$recovery.Host
    $oldCatalog=$hostState.UiCatalog;$controllerState=$hostState.State;$queue=$hostState.CommandQueue;$session=$hostState.SessionState;$blocked=$hostState.BlockAutomaticActions
    $command=[pscustomobject][ordered]@{Kind='SetUiLanguage';Value='en-US';EnqueuedAtUtc='2026-08-05T00:00:00.0000000Z'}
    Assert-CcodEqual 0 @(Invoke-CcodSupervisorCommand -Command $command -HostState $hostState -Adapters $fixture.Fake.Adapters).Count 'combined recovery failures are contained with no output'
    Assert-CcodTrue ($world.Calls.Contains('Read:UiPreference:Recovery')) 'combined case confirms disk state after the throwing preference adapter'
    Assert-CcodEqual 'System' $world.StoredLanguageMode 'after-write failure is confirmed as old mode on disk'
    Assert-CcodEqual 'System' $hostState.UiLanguageMode 'host follows confirmed old disk mode'
    Assert-CcodTrue ([object]::ReferenceEquals($oldCatalog,$hostState.UiCatalog)) 'host catalog matches confirmed old disk mode'
    Assert-CcodEqual 'LanguageChange|CCOD_UI_LANGUAGE_CHANGE_FAILED,LanguagePreferenceRollback|CCOD_UI_LANGUAGE_PREFERENCE_ROLLBACK_FAILED,LanguageTrayRollback|CCOD_UI_LANGUAGE_TRAY_ROLLBACK_FAILED' (($world.UiFailureRecords|ForEach-Object{"$($_.stage)|$($_.code)"})-join ',') 'combined recovery stages are independently and exactly logged'
    Assert-CcodTrue (($world.UiFailureRecords|ConvertTo-Json -Compress) -cnotmatch 'PRIVATE|Fake|CodexControlOtherDevices|recovery-partial|en-US') 'combined recovery logs remain bounded and non-sensitive'
    Assert-CcodEqual 1 $world.TrayErrors.Count 'combined recovery failure still attempts one old-catalog error dialog'
    Assert-CcodTrue ([object]::ReferenceEquals($oldCatalog,$world.TrayErrors[0].Catalog)) 'combined recovery error uses old validated catalog'
    Assert-CcodTrue ([object]::ReferenceEquals($controllerState,$hostState.State) -and [object]::ReferenceEquals($queue,$hostState.CommandQueue) -and $hostState.SessionState -ceq $session -and $hostState.BlockAutomaticActions -eq $blocked) 'combined recovery failures leave controller and Codex state unchanged'
}

Invoke-CcodTest 'rejects malformed language commands before catalog resolution or persistence' {
    $timestamp='2026-08-05T00:00:00.0000000Z'
    $cases=@(
        [pscustomobject][ordered]@{Kind='SetUiLanguage';Value='system';EnqueuedAtUtc=$timestamp},
        [pscustomobject][ordered]@{Kind='SetUiLanguage';Value='zh-cn';EnqueuedAtUtc=$timestamp},
        [pscustomobject][ordered]@{Kind='SetUiLanguage';Value='fr-FR';EnqueuedAtUtc=$timestamp},
        [pscustomobject][ordered]@{Kind='SetUiLanguage';EnqueuedAtUtc=$timestamp},
        [pscustomobject][ordered]@{Kind='SetUiLanguage';Value='en-US';EnqueuedAtUtc=$timestamp;Extra=$true},
        [pscustomobject][ordered]@{Kind='SetUiLanguage';Value=[int]1;EnqueuedAtUtc=$timestamp}
    )
    foreach($command in $cases){
        $fixture=New-CcodTickFixture;$world=$fixture.Fake.World;$hostState=$fixture.Host;$oldCatalog=$hostState.UiCatalog
        Assert-CcodEqual 0 @(Invoke-CcodSupervisorCommand -Command $command -HostState $hostState -Adapters $fixture.Fake.Adapters).Count 'rejected language command emits no output'
        Assert-CcodEqual 0 $world.SetUiLanguageModes.Count 'rejected value never persists'
        Assert-CcodEqual 0 @($world.Calls|Where-Object {$_ -like 'Get:UiCatalog:*'}).Count 'rejected value never reaches catalog adapter'
        Assert-CcodEqual 'System' $hostState.UiLanguageMode 'rejected value preserves old mode'
        Assert-CcodTrue ([object]::ReferenceEquals($oldCatalog,$hostState.UiCatalog)) 'rejected value preserves old catalog'
    }
}

Invoke-CcodTest 'rolls back catalog and persistence failures and reports only bounded stable UI records through the old catalog' {
    foreach($stage in @('GetUiCatalog','SetUiLanguageMode')){
        $fixture=New-CcodTickFixture;$world=$fixture.Fake.World;$hostState=$fixture.Host;$world.FailAt=$stage
        $oldCatalog=$hostState.UiCatalog;$oldMode=$hostState.UiLanguageMode;$oldStored=$world.StoredLanguageMode
        $oldSession=$hostState.SessionState;$oldBlock=$hostState.BlockAutomaticActions;$oldWorker=$hostState.WorkerSlot
        $command=[pscustomobject][ordered]@{Kind='SetUiLanguage';Value='en-US';EnqueuedAtUtc='2026-08-05T00:00:00.0000000Z'}
        Assert-CcodEqual 0 @(Invoke-CcodSupervisorCommand -Command $command -HostState $hostState -Adapters $fixture.Fake.Adapters).Count "$stage failure is contained with no output"
        Assert-CcodEqual $oldMode $hostState.UiLanguageMode "$stage preserves mode"
        Assert-CcodTrue ([object]::ReferenceEquals($oldCatalog,$hostState.UiCatalog)) "$stage preserves old catalog identity"
        Assert-CcodEqual $oldStored $world.StoredLanguageMode "$stage preserves stored preference"
        Assert-CcodEqual 1 $world.UiFailureRecords.Count "$stage writes one bounded failure record"
        $record=$world.UiFailureRecords[0]
        Assert-CcodEqual 'schemaVersion,timestampUtc,component,stage,code,outcome' (@($record.PSObject.Properties.Name)-join ',') 'failure record shape is exact'
        Assert-CcodEqual '1,2030-02-03T03:04:05.0000000Z,Supervisor,LanguageChange,CCOD_UI_LANGUAGE_CHANGE_FAILED,Failed' "$($record.schemaVersion),$($record.timestampUtc),$($record.component),$($record.stage),$($record.code),$($record.outcome)" 'failure record values are stable English'
        Assert-CcodTrue (($record|ConvertTo-Json -Compress) -cnotmatch 'PRIVATE|Fake|en-US|Catalog') 'failure record contains no exception path catalog or input'
        Assert-CcodEqual 1 $world.TrayErrors.Count "$stage shows one localized error"
        Assert-CcodEqual 'Error.LanguageChange' $world.TrayErrors[0].Key 'old-catalog language error key is exact'
        Assert-CcodTrue ([object]::ReferenceEquals($oldCatalog,$world.TrayErrors[0].Catalog)) 'dialog resolves through the old catalog'
        Assert-CcodTrue ($hostState.SessionState -ceq $oldSession -and $hostState.BlockAutomaticActions -eq $oldBlock -and [object]::ReferenceEquals($oldWorker,$hostState.WorkerSlot)) 'controller and Codex state remain untouched'
    }
}

Invoke-CcodTest 'contains error-dialog and UI-log failures independently without changing controller state' {
    $dialogFixture=New-CcodTickFixture;$dialogWorld=$dialogFixture.Fake.World;$dialogHost=$dialogFixture.Host
    $dialogSession=$dialogHost.SessionState
    $dialogWorld.FailAt='SetUiLanguageMode';$dialogFixture.Fake.Adapters.ShowTrayError={param($Tray,$Catalog,$Key)$dialogWorld.Calls.Add('Show:TrayError:failed');throw 'PRIVATE_DIALOG_SECRET'}.GetNewClosure()
    $command=[pscustomobject][ordered]@{Kind='SetUiLanguage';Value='zh-CN';EnqueuedAtUtc='2026-08-05T00:00:00.0000000Z'}
    Invoke-CcodSupervisorCommand -Command $command -HostState $dialogHost -Adapters $dialogFixture.Fake.Adapters
    Assert-CcodEqual 'CCOD_UI_LANGUAGE_CHANGE_FAILED,CCOD_UI_ERROR_DIALOG_FAILED' (@($dialogWorld.UiFailureRecords.code)-join ',') 'dialog failure is logged separately'
    Assert-CcodEqual 'System' $dialogHost.UiLanguageMode 'dialog failure preserves UI mode'
    Assert-CcodEqual $dialogSession $dialogHost.SessionState 'dialog failure preserves controller state'

    $logFixture=New-CcodTickFixture;$logWorld=$logFixture.Fake.World;$logHost=$logFixture.Host
    $logSession=$logHost.SessionState
    $logWorld.FailAt='SetUiLanguageMode';$logFixture.Fake.Adapters.WriteLog={param($Record)throw 'PRIVATE_LOG_SECRET'}
    Invoke-CcodSupervisorCommand -Command $command -HostState $logHost -Adapters $logFixture.Fake.Adapters
    Assert-CcodTrue $logHost.RuntimeCleanupCodes.Contains('CCOD_SUPERVISOR_LOG_FAILED') 'log failure is reduced to existing bounded cleanup code'
    Assert-CcodEqual 1 $logWorld.TrayErrors.Count 'log failure does not suppress the localized dialog'
    Assert-CcodEqual 'System' $logHost.UiLanguageMode 'log failure preserves UI mode'
    Assert-CcodEqual $logSession $logHost.SessionState 'log failure preserves controller state'
}

Invoke-CcodTest 'logs a tray callback failure once without suppressing the supervisor tick' {
    $fixture=New-CcodTickFixture;$world=$fixture.Fake.World;$hostState=$fixture.Host
    $hostState.Tray | Add-Member -NotePropertyName CallbackFailure -NotePropertyValue $true
    Invoke-CcodSupervisorTick -HostState $hostState -Adapters $fixture.Fake.Adapters
    Assert-CcodEqual 1 $world.UiFailureRecords.Count 'the first observed tray callback failure writes one bounded record'
    Assert-CcodEqual 'TrayCallback|CCOD_TRAY_CALLBACK_FAILED' (($world.UiFailureRecords|ForEach-Object{"$($_.stage)|$($_.code)"})-join ',') 'the tray callback diagnostic is stable and sanitized'
    Assert-CcodEqual $true $hostState.TrayCallbackFailureLogged 'the host remembers that the sticky callback failure was reported'
    Invoke-CcodSupervisorTick -HostState $hostState -Adapters $fixture.Fake.Adapters
    Assert-CcodEqual 1 $world.UiFailureRecords.Count 'a sticky tray callback failure is not logged repeatedly'
}

Invoke-CcodTest 'gives Shutdown absolute priority over a slot journal command and decision' {
    $fixture=New-CcodTickFixture;$world=$fixture.Fake.World;$hostState=$fixture.Host
    $world.ShutdownSignaled=$true;$world.ActiveJournal=New-CcodTestTransition
    $world.Decision=[pscustomobject][ordered]@{Action='ApplyOrdinary';Reason='Ready';Target=(New-CcodSupervisorTestSnapshot);AttemptKey='71|2030-02-03T03:01:00.0000000Z';SuppressionKey=$null;EffectiveClassification='CandidateCompatible';RequiresController=$true}
    $world.CommandQueue.Enqueue([pscustomobject][ordered]@{Kind='ApplyNow';Value=$null;EnqueuedAtUtc='2030-02-03T03:04:05.0000000Z'})
    $hostState.WorkerSlot=[pscustomobject]@{Kind='Controller';ProcessId=501}
    Invoke-CcodSupervisorTick $hostState $fixture.Fake.Adapters
    Assert-CcodTrue $hostState.ShutdownRequested 'shutdown latches'
    Assert-CcodTrue ($world.Calls.Contains('Exit:UI')) 'shutdown requests message-loop exit'
    Assert-CcodEqual 0 @($world.Calls|Where-Object{$_ -like 'Poll:*' -or $_ -like 'Start:*' -or $_ -eq 'Read:State'}).Count 'no lower priority work runs'
}

Invoke-CcodTest 'menu-open tick checks shutdown but skips every heavy supervisor path' {
    $fixture=New-CcodTickFixture;$world=$fixture.Fake.World;$hostState=$fixture.Host
    $world.CommandQueue.Enqueue([pscustomobject][ordered]@{Kind='OpenLogs';Value=$null;EnqueuedAtUtc='2030-02-03T03:04:05.0000000Z'})
    Invoke-CcodSupervisorTick $hostState $fixture.Fake.Adapters $true
    Assert-CcodEqual 0 $world.StateReads 'menu-open tick performs no state read'
    Assert-CcodEqual 0 $world.JournalReads 'menu-open tick performs no journal read'
    Assert-CcodEqual 0 @($world.Calls|Where-Object{$_ -eq 'Enumerate' -or $_ -like 'Poll:*' -or $_ -like 'Start:*' -or $_ -eq 'Open:Logs'}).Count 'menu-open tick performs no process worker decision or command work'
    $world.ShutdownSignaled=$true
    Invoke-CcodSupervisorTick $hostState $fixture.Fake.Adapters $true
    Assert-CcodTrue $hostState.ShutdownRequested 'menu-open tick still latches shutdown'
    Assert-CcodTrue ($world.Calls.Contains('Exit:UI')) 'menu-open shutdown still exits the native menu loop'
}

Invoke-CcodTest 'default shutdown ends an active native menu before exit and still exits when EndMenu fails' {
    $defaults=Get-CcodSupervisorDefaultAdapters
    $calls=[Collections.Generic.List[string]]::new()
    $applicationContext=[pscustomobject]@{}
    $applicationContext|Add-Member -MemberType ScriptMethod -Name ExitThread -Value {$calls.Add('Exit:UI')}
    $tray=[pscustomobject]@{
        MenuOpen=$true
        Adapters=@{EndNativeMenu={$calls.Add('End:Native');throw 'PRIVATE_NATIVE_END_FAILURE'}.GetNewClosure()}
        ApplicationContext=$applicationContext
    }
    & $defaults.RequestUiExit $tray
    Assert-CcodEqual 'End:Native|Exit:UI' (@($calls)-join '|') 'active-menu shutdown attempts EndMenu before it exits the same UI context'

    $calls.Clear()
    $tray.MenuOpen=$false
    & $defaults.RequestUiExit $tray
    Assert-CcodEqual 'Exit:UI' (@($calls)-join '|') 'closed menu does not receive an unnecessary EndMenu call'
}

Invoke-CcodTest 'default active-menu shutdown contains nonterminating EndMenu diagnostics without polluting caller errors' {
    $defaults=Get-CcodSupervisorDefaultAdapters
    $calls=[Collections.Generic.List[string]]::new()
    $applicationContext=[pscustomobject]@{}
    $applicationContext|Add-Member -MemberType ScriptMethod -Name ExitThread -Value {$calls.Add('Exit:UI')}
    $tray=[pscustomobject]@{
        MenuOpen=$true
        Adapters=@{EndNativeMenu={$calls.Add('End:Native');Write-Error 'PRIVATE_NATIVE_END_NONTERMINATING'}.GetNewClosure()}
        ApplicationContext=$applicationContext
    }
    $startingErrors=[object[]]@($global:Error)
    try{
        $output=@(& $defaults.RequestUiExit $tray *>&1)
        Assert-CcodEqual 0 $output.Count 'nonterminating EndMenu diagnostics do not escape the shutdown adapter'
        Assert-CcodEqual 'End:Native|Exit:UI' (@($calls)-join '|') 'diagnostic EndMenu still precedes UI exit'
        Assert-CcodEqual $startingErrors.Count $global:Error.Count 'shutdown restores the caller error history length'
        for($index=0;$index -lt $startingErrors.Count;$index++){
            Assert-CcodTrue ([object]::ReferenceEquals($startingErrors[$index],$global:Error[$index])) 'shutdown restores the exact caller error history'
        }
    }finally{
        $global:Error.Clear()
        foreach($startingError in $startingErrors){[void]$global:Error.Add($startingError)}
    }
}

Invoke-CcodTest 'observes and renders at 0 and 1000ms but not at intervening 250ms safety ticks' {
    $fixture=New-CcodTickFixture;$world=$fixture.Fake.World;$hostState=$fixture.Host
    foreach($elapsed in @([long]0,[long]250,[long]500,[long]750,[long]999,[long]1000)){$world.Elapsed.Enqueue($elapsed)}

    Invoke-CcodSupervisorTick $hostState $fixture.Fake.Adapters
    Assert-CcodEqual 1 $world.StateReads 'initial zero-millisecond tick reads state once'
    Assert-CcodEqual 1 $world.JournalReads 'initial zero-millisecond tick reads journal once'
    Assert-CcodEqual 1 $world.PresentationArguments.Count 'initial zero-millisecond tick renders once'
    Assert-CcodEqual 1 @($world.Calls|Where-Object {$_ -eq 'Enumerate'}).Count 'initial forced reconcile observes processes once'

    foreach($elapsed in @(250,500,750,999)){
        Invoke-CcodSupervisorTick $hostState $fixture.Fake.Adapters
        Assert-CcodEqual 1 $world.StateReads "$elapsed millisecond safety tick does not reread state"
        Assert-CcodEqual 1 $world.JournalReads "$elapsed millisecond safety tick does not reread journal"
        Assert-CcodEqual 1 $world.PresentationArguments.Count "$elapsed millisecond safety tick does not rewrite the presentation"
        Assert-CcodEqual 1 @($world.Calls|Where-Object {$_ -eq 'Enumerate'}).Count "$elapsed millisecond safety tick does not repurpose the three-second reconcile deadline"
    }

    Invoke-CcodSupervisorTick $hostState $fixture.Fake.Adapters
    Assert-CcodEqual 2 $world.StateReads '1000 millisecond deadline reads state again'
    Assert-CcodEqual 2 $world.JournalReads '1000 millisecond deadline reads journal again'
    Assert-CcodEqual 2 $world.PresentationArguments.Count '1000 millisecond deadline renders exactly once more'
    Assert-CcodEqual 1 @($world.Calls|Where-Object {$_ -eq 'Enumerate'}).Count 'one-second observation leaves the separate three-second process deadline intact'
}

Invoke-CcodTest 'keeps queued commands and shutdown immediate inside the observation throttle window' {
    $commandFixture=New-CcodTickFixture;$commandWorld=$commandFixture.Fake.World;$commandHost=$commandFixture.Host
    $commandWorld.Elapsed.Enqueue([long]0);$commandWorld.Elapsed.Enqueue([long]250)
    Invoke-CcodSupervisorTick $commandHost $commandFixture.Fake.Adapters
    $commandWorld.CommandQueue.Enqueue([pscustomobject][ordered]@{Kind='OpenLogs';Value=$null;EnqueuedAtUtc='2030-02-03T03:04:05.0000000Z'})
    Invoke-CcodSupervisorTick $commandHost $commandFixture.Fake.Adapters
    Assert-CcodTrue ($commandWorld.Calls.Contains('Open:Logs')) 'a queued command executes on the next 250 millisecond tick'
    Assert-CcodEqual 1 $commandWorld.StateReads 'command tick does not force an unrelated state read'
    Assert-CcodEqual 1 $commandWorld.JournalReads 'command tick does not force an unrelated journal read'
    Assert-CcodEqual 1 $commandWorld.PresentationArguments.Count 'nonvisual command does not force a presentation write'

    $shutdownFixture=New-CcodTickFixture;$shutdownWorld=$shutdownFixture.Fake.World;$shutdownHost=$shutdownFixture.Host
    $shutdownWorld.Elapsed.Enqueue([long]0)
    Invoke-CcodSupervisorTick $shutdownHost $shutdownFixture.Fake.Adapters
    $shutdownWorld.ShutdownSignaled=$true
    Invoke-CcodSupervisorTick $shutdownHost $shutdownFixture.Fake.Adapters
    Assert-CcodTrue $shutdownHost.ShutdownRequested 'shutdown latches on the next 250 millisecond tick'
    Assert-CcodTrue ($shutdownWorld.Calls.Contains('Exit:UI')) 'shutdown requests UI exit without waiting for observation'
    Assert-CcodEqual 1 $shutdownWorld.StateReads 'shutdown tick performs no state read'
    Assert-CcodEqual 1 $shutdownWorld.JournalReads 'shutdown tick performs no journal read'
    Assert-CcodEqual 1 $shutdownWorld.PresentationArguments.Count 'shutdown tick performs no presentation write'
}

Invoke-CcodTest 'reserves the whole tick for a slot that existed at tick entry' {
    foreach($completed in @($false,$true)){
        $fixture=New-CcodTickFixture;$world=$fixture.Fake.World;$hostState=$fixture.Host
        $world.ActiveJournal=New-CcodTestTransition
        $world.Poll=[pscustomobject][ordered]@{Completed=[bool]$completed;ExitCode=$(if($completed){0}else{$null});StdoutText='';StdoutByteCount=0;StdoutOverflow=$false;StderrByteCount=0;StderrOverflow=$false}
        $hostState.WorkerSlot=[pscustomobject][ordered]@{Kind='Controller';Action='Inspect';RequestId=('c'*32);RuntimeId='runtime-1';Request=$null;RequestPath='C:\Fake\CodexControlOtherDevices\state\workers\controller-cccccccccccccccccccccccccccccccc.request.json';ResultPath='C:\Fake\CodexControlOtherDevices\state\workers\controller-cccccccccccccccccccccccccccccccc.result.json';StderrPath='C:\Fake\CodexControlOtherDevices\state\workers\controller-cccccccccccccccccccccccccccccccc.stderr.log';ProcessId=501;CreationTimeUtc='2030-02-03T03:05:00.0000000Z';Handle=[pscustomobject]@{Kind='Worker'}}
        Invoke-CcodSupervisorTick $hostState $fixture.Fake.Adapters
        Assert-CcodEqual 1 @($world.Calls|Where-Object{$_ -eq 'Poll:Controller'}).Count 'slot polls once'
        Assert-CcodEqual 0 @($world.Calls|Where-Object{$_ -like 'Start:*'}).Count 'no same-tick replacement starts'
        Assert-CcodEqual 0 @($world.Calls|Where-Object{$_ -eq 'Read:State'}).Count 'slot tick does no lower-priority state read'
        if($completed){Assert-CcodEqual $null $hostState.WorkerSlot 'completed slot clears after cleanup'}else{Assert-CcodTrue ($null -ne $hostState.WorkerSlot) 'incomplete slot remains owned'}
    }
}

Invoke-CcodTest 'blocks a legacy transition journal without dispatching Recover before one queued command' {
    $fixture=New-CcodTickFixture;$world=$fixture.Fake.World;$hostState=$fixture.Host
    $world.ActiveJournal=New-CcodTestTransition
    $world.CommandQueue.Enqueue([pscustomobject][ordered]@{Kind='OpenLogs';Value=$null;EnqueuedAtUtc='2030-02-03T03:04:05.0000000Z'})
    Invoke-CcodSupervisorTick $hostState $fixture.Fake.Adapters
    Assert-CcodEqual 0 @($world.Calls|Where-Object{$_ -like 'Start:Controller:*'}).Count 'Supervisor never dispatches legacy Recover'
    Assert-CcodEqual 'LegacyTransitionBlocked' $hostState.Reason 'legacy journal fails closed with stable state'
    Assert-CcodEqual 1 $world.CommandQueue.Count 'blocked legacy journal leaves command queued'
}

Invoke-CcodTest 'converts persisted-special inspection into one durable lifecycle before a queued command' {
    $fixture=New-CcodTickFixture;$world=$fixture.Fake.World;$hostState=$fixture.Host
    $hostState.SpecialNeedsInspect=$true
    $world.CommandQueue.Enqueue([pscustomobject][ordered]@{Kind='OpenLogs';Value=$null;EnqueuedAtUtc='2030-02-03T03:04:05.0000000Z'})
    Invoke-CcodSupervisorTick $hostState $fixture.Fake.Adapters
    Assert-CcodEqual 0 @($world.Calls|Where-Object{$_ -like 'Start:Controller:*'}).Count 'special proof never starts a controller worker directly'
    Assert-CcodTrue ($null-ne$hostState.LifecycleRequest -and $hostState.LifecycleRequest.kind-ceq'CheckAndRepair') 'special proof creates one durable CheckAndRepair lifecycle'
    Assert-CcodEqual 1 $world.CommandQueue.Count 'durable lifecycle leaves command queued'
}

Invoke-CcodTest 'bounds stale-package special reconciliation to one live process identity without clearing state or keys' {
    $fixture=New-CcodTickFixture;$world=$fixture.Fake.World;$hostState=$fixture.Host
    $special=New-CcodSupervisorTestSnapshot -ProcessId 201 -CreationTimeUtc '2030-02-03T03:02:00.0000000Z'
    $special.Mode='Special';$special.RendererPort=[int]41001;$special.MainPort=[int]41002
    $hostState.Special=[object[]]@([pscustomobject][ordered]@{Snapshot=$special;IdentityValid=$true;ProbeValid=$false})
    $hostState.SpecialNeedsInspect=$true
    $stateBefore=$hostState.State|ConvertTo-Json -Depth 20 -Compress
    $hostState.AttemptKeys['keep']='value';$attemptsBefore=$hostState.AttemptKeys|ConvertTo-Json -Compress
    $fixture.Fake.Adapters.ReadState={param($StateRoot,$SuppressionKey)$hostState.State}.GetNewClosure()
    $fixture.Fake.Adapters.CompleteControllerRun={
        param($Result,$TransactionId,$Action,$RuntimeId)
        $world.Calls.Add("Reduce:$Action")
        [pscustomobject][ordered]@{SessionState='Error';BlockAutomaticActions=$true;AttemptKey=$null;RecoveryIgnoreKey=$null;SuppressionKey=$null;ErrorCode='CCOD_STATE_STALE_PACKAGE';Reason='StalePackageStatus'}
    }.GetNewClosure()
    $world.WorkerResult=[pscustomobject][ordered]@{ok=$false;outcome='Error';safeState='Error';special=$null}
    $stdout=$world.WorkerResult|ConvertTo-Json -Depth 20 -Compress
    $world.Poll=[pscustomobject][ordered]@{Completed=$true;ExitCode=[int]0;StdoutText=$stdout;StdoutByteCount=[int]$stdout.Length;StdoutOverflow=$false;StderrByteCount=[int]0;StderrOverflow=$false}
    Start-CcodSupervisorWorkerSlot $hostState $fixture.Fake.Adapters 'Controller' 'Inspect' $null|Out-Null
    Invoke-CcodSupervisorPollSlot $hostState $fixture.Fake.Adapters
    Assert-CcodEqual 'StalePackageStatus' $hostState.Reason 'stale worker result exposes only the fixed reason'
    Assert-CcodEqual $false $hostState.SpecialNeedsInspect 'completed stale inspection is not immediately rescheduled'
    Assert-CcodTrue ([object]::ReferenceEquals($special,$hostState.SpecialProof)) 'stale suppression binds the current live special identity only'

    $world.Calls.Clear();$world.ProcessIds=@(201);$world.Snapshots[201]=$special;$world.Elapsed.Enqueue([long]0);$hostState.ForceReconcile=$true
    Invoke-CcodSupervisorTick $hostState $fixture.Fake.Adapters
    Assert-CcodEqual 0 @($world.Calls|Where-Object{$_ -like 'Start:*' -or $_ -eq 'Decision'}).Count 'matching stale identity takes no second worker or reconcile action'
    Assert-CcodEqual $stateBefore ($hostState.State|ConvertTo-Json -Depth 20 -Compress) 'bounded stale suppression does not clear persisted state'
    Assert-CcodEqual $attemptsBefore ($hostState.AttemptKeys|ConvertTo-Json -Compress) 'bounded stale suppression does not clear key membership'

    $changed=New-CcodSupervisorTestSnapshot -ProcessId 202 -CreationTimeUtc '2030-02-03T03:03:00.0000000Z'
    $changed.Mode='Special';$changed.RendererPort=[int]42001;$changed.MainPort=[int]42002
    $world.Calls.Clear();$world.ProcessIds=@(202);$world.Snapshots[202]=$changed;$hostState.ForceReconcile=$true
    Invoke-CcodSupervisorTick $hostState $fixture.Fake.Adapters
    Assert-CcodEqual $null $hostState.SpecialProof 'changed live special identity clears stale suppression'
    Assert-CcodTrue ($world.Calls.Contains('Enumerate')) 'changed identity is observed before stale handling'
    Assert-CcodEqual 0 @($world.Calls|Where-Object{$_ -like 'Start:Controller:*'}).Count 'changed identity never re-enters direct controller validation'
    Assert-CcodTrue ($null-ne$hostState.LifecycleRequest -and $hostState.LifecycleRequest.kind-ceq'CheckAndRepair') 'changed identity enters one durable lifecycle validation'
    Assert-CcodEqual $stateBefore ($hostState.State|ConvertTo-Json -Depth 20 -Compress) 'changed identity recovery does not clear persisted state'
    Assert-CcodEqual $attemptsBefore ($hostState.AttemptKeys|ConvertTo-Json -Compress) 'changed identity recovery does not clear key membership'
}

Invoke-CcodTest 'uses a constrained stale reconciliation candidate for only an exact persisted old MSIX path' {
    $fixture=New-CcodTickFixture;$world=$fixture.Fake.World;$hostState=$fixture.Host
    $oldInstall='C:\Program Files\WindowsApps\OpenAI.Codex_1.0.0.0_x64__2p2nqsd0c76g0';$oldExecutable=$oldInstall+'\app\ChatGPT.exe'
    $liveInstall='C:\Program Files\WindowsApps\OpenAI.Codex_2.0.0.0_x64__2p2nqsd0c76g0';$liveExecutable=$liveInstall+'\app\ChatGPT.exe'
    $mismatchedOldExecutable='C:\Program Files\WindowsApps\OpenAI.Codex_1.0.0.0_x64__2p2nqsd0c76g0-tampered\app\ChatGPT.exe'
    $live=[pscustomobject][ordered]@{Found=$true;FullName='OpenAI.Codex_2.0.0.0_x64__2p2nqsd0c76g0';FamilyName='OpenAI.Codex_2p2nqsd0c76g0';Version='2.0.0.0';InstallLocation=$liveInstall;ExecutablePath=$liveExecutable}
    $definitions=[ordered]@{}
    $definitions['201']=[pscustomobject][ordered]@{Pid=[int]201;CreationTimeUtc='2030-02-03T03:02:00.0000000Z';Path=$oldExecutable;CommandLine=('"'+$oldExecutable+'" --remote-debugging-address=127.0.0.1 --remote-debugging-port=41001 --inspect=127.0.0.1:41002');Arguments=@($oldExecutable,'--remote-debugging-address=127.0.0.1','--remote-debugging-port=41001','--inspect=127.0.0.1:41002')}
    $definitions['333']=[pscustomobject][ordered]@{Pid=[int]333;CreationTimeUtc='2030-02-03T03:02:30.0000000Z';Path=$oldExecutable;CommandLine=('"'+$oldExecutable+'" --inspect=127.0.0.1:49999');Arguments=@($oldExecutable,'--inspect=127.0.0.1:49999')}
    $definitions['334']=[pscustomobject][ordered]@{Pid=[int]334;CreationTimeUtc='2030-02-03T03:02:40.0000000Z';Path=$mismatchedOldExecutable;CommandLine=('"'+$mismatchedOldExecutable+'" --remote-debugging-address=127.0.0.1 --remote-debugging-port=41001 --inspect=127.0.0.1:41002');Arguments=@($mismatchedOldExecutable,'--remote-debugging-address=127.0.0.1','--remote-debugging-port=41001','--inspect=127.0.0.1:41002')}
    $snapshotAdapters=@{
        GetPackageIdentity={$live}.GetNewClosure()
        GetCurrentSessionId={[int]1}
        GetCurrentUserSid={'S-1-5-21-111-222-333-1001'}
        GetNativeProcess={param($ProcessId)$entry=$definitions[[string][int]$ProcessId];if($null -eq $entry){return $null};[pscustomobject][ordered]@{Pid=[int]$entry.Pid;CreationTimeUtc=[string]$entry.CreationTimeUtc;SessionId=[int]1;UserSid='S-1-5-21-111-222-333-1001';Path=[string]$entry.Path;PackageFamilyName=$live.FamilyName}}.GetNewClosure()
        GetCimProcess={param($ProcessId)$entry=$definitions[[string][int]$ProcessId];if($null -eq $entry){return $null};[pscustomobject][ordered]@{ProcessId=[int]$entry.Pid;ParentProcessId=[int]0;CommandLine=[string]$entry.CommandLine}}.GetNewClosure()
        ParseCommandLine={param($CommandLine)foreach($entry in @($definitions.Values)){if($entry.CommandLine -ceq $CommandLine){return @($entry.Arguments)}};return $null}.GetNewClosure()
        ProbeSpecial={param($ProcessId,$RendererPort,$MainPort)[pscustomobject][ordered]@{Valid=$true;RendererUrl='app://-/index.html'}}
    }
    $codex=[pscustomobject][ordered]@{pid=[int]201;creationTimeUtc='2030-02-03T03:02:00.0000000Z';packageFullName='OpenAI.Codex_1.0.0.0_x64__2p2nqsd0c76g0';packageVersion='1.0.0.0';appAsarSha256=('a'*64);mainPort=[int]41002;rendererPort=[int]41001;mainProbe='Closed';rendererProbe='BridgeValid'}
    $status=[pscustomobject][ordered]@{schemaVersion=[int]1;session=[pscustomobject][ordered]@{supervisorPid=[int]41;supervisorCreationTimeUtc='2030-02-03T03:00:00.0000000Z';sessionId='1';runtimeId='runtime-old';sessionState='Active';codex=$codex}}
    $key='OpenAI.Codex_1.0.0.0_x64__2p2nqsd0c76g0|'+('a'*64)+'|runtime-old'
    $record=[pscustomobject][ordered]@{packageFullName=$codex.packageFullName;packageVersion=$codex.packageVersion;appAsarSha256=$codex.appAsarSha256;runtimeId='runtime-old';staticClassification='CandidateCompatible';dynamicOutcome='Succeeded';probeState='Valid';confirmedAtUtc='2030-02-03T03:01:00.0000000Z'}
    $state=[pscustomobject][ordered]@{AutomationEnabled=$true;AutomaticCandidateTrialsAllowed=$false;Settings=[pscustomobject][ordered]@{candidateCompatibleOptIn=$true};Status=$status;VerifiedPackages=[pscustomobject][ordered]@{schemaVersion=[int]1;packages=[pscustomobject][ordered]@{$key=$record}};Damage=[pscustomobject]@{}}
    $mismatchedCodex=[pscustomobject][ordered]@{pid=[int]334;creationTimeUtc='2030-02-03T03:02:40.0000000Z';packageFullName=$codex.packageFullName;packageVersion=$codex.packageVersion;appAsarSha256=$codex.appAsarSha256;mainPort=[int]41002;rendererPort=[int]41001;mainProbe='Closed';rendererProbe='BridgeValid'}
    $mismatchedStatus=[pscustomobject][ordered]@{schemaVersion=[int]1;session=[pscustomobject][ordered]@{supervisorPid=[int]41;supervisorCreationTimeUtc='2030-02-03T03:00:00.0000000Z';sessionId='1';runtimeId='runtime-old';sessionState='Active';codex=$mismatchedCodex}}
    $mismatchedState=[pscustomobject][ordered]@{AutomationEnabled=$true;AutomaticCandidateTrialsAllowed=$false;Settings=[pscustomobject][ordered]@{candidateCompatibleOptIn=$true};Status=$mismatchedStatus;VerifiedPackages=$state.VerifiedPackages;Damage=[pscustomobject]@{}}
    $inactiveSession=$status.session.PSObject.Copy();$inactiveSession.sessionState='Idle'
    $inactiveStatus=$status.PSObject.Copy();$inactiveStatus.session=$inactiveSession
    $inactiveState=[pscustomobject][ordered]@{AutomationEnabled=$true;AutomaticCandidateTrialsAllowed=$false;Settings=[pscustomobject][ordered]@{candidateCompatibleOptIn=$true};Status=$inactiveStatus;VerifiedPackages=$state.VerifiedPackages;Damage=[pscustomobject]@{}}
    $unverifiedState=[pscustomobject][ordered]@{AutomationEnabled=$true;AutomaticCandidateTrialsAllowed=$false;Settings=[pscustomobject][ordered]@{candidateCompatibleOptIn=$true};Status=$status;VerifiedPackages=[pscustomobject][ordered]@{schemaVersion=[int]1;packages=[pscustomobject][ordered]@{}};Damage=[pscustomobject]@{}}
    $stateBefore=$state|ConvertTo-Json -Depth 20 -Compress
    $hostState.AttemptKeys['preserved-attempt']=$true;$hostState.RecoveryIgnoreKeys['preserved-ignore']=$true;$hostState.SuppressionKeys['preserved-suppression']=$true
    $keysBefore=($hostState.AttemptKeys|ConvertTo-Json -Compress)+($hostState.RecoveryIgnoreKeys|ConvertTo-Json -Compress)+($hostState.SuppressionKeys|ConvertTo-Json -Compress)
    $seenStatusEvidence=[Collections.Generic.List[object]]::new()
    $fixture.Fake.Adapters.ReadState={param($StateRoot,$SuppressionKey)$state}.GetNewClosure()
    $fixture.Fake.Adapters.GetPackageIdentity={$live}.GetNewClosure()
    $fixture.Fake.Adapters.GetProcessSnapshot={param($ProcessId,$StatusEvidence)$world.Calls.Add("Snapshot:$ProcessId");$seenStatusEvidence.Add($StatusEvidence);Get-CcodProcessSnapshot -ProcessId ([int]$ProcessId) -StatusEvidence $StatusEvidence -Adapters $snapshotAdapters}.GetNewClosure()
    $fixture.Fake.Adapters.ParseStaleCandidateCommandLine={param($CommandLine)foreach($entry in @($definitions.Values)){if($entry.CommandLine -ceq $CommandLine){return @($entry.Arguments)}};return $null}.GetNewClosure()
    $fixture.Fake.Adapters.GetSupervisorDecision={param($Context)$world.Calls.Add('Decision');Get-CcodSupervisorDecision -Context $Context}.GetNewClosure()
    $unproven=Get-CcodProcessSnapshot -ProcessId 201 -StatusEvidence $status -Adapters $snapshotAdapters
    $arbitrary=Get-CcodProcessSnapshot -ProcessId 333 -StatusEvidence $status -Adapters $snapshotAdapters
    $mismatched=Get-CcodProcessSnapshot -ProcessId 334 -StatusEvidence $mismatchedStatus -Adapters $snapshotAdapters
    $arbitraryExact=$unproven.PSObject.Copy();$arbitraryExact.CommandLine=$definitions['333'].CommandLine
    Assert-CcodEqual 'Unrelated' $unproven.Mode 'stale package proof never elevates an exact debug launch to Special'
    Assert-CcodEqual $false $unproven.IsTopLevel 'normal current-package path remains strict for the old executable'
    Assert-CcodEqual 'Unrelated' $arbitrary.Mode 'arbitrary debug arguments are never elevated to Special'
    Assert-CcodEqual 'Unrelated' $mismatched.Mode 'mismatched old path is never elevated to Special'
    Assert-CcodEqual $null (Get-CcodSupervisorStaleReconciliationCandidate $state $arbitrary $live $hostState.Identity $fixture.Fake.Adapters) 'arbitrary debug process identity never becomes a stale candidate'
    Assert-CcodEqual $null (Get-CcodSupervisorStaleReconciliationCandidate $state $arbitraryExact $live $hostState.Identity $fixture.Fake.Adapters) 'arbitrary debug arguments never become a stale candidate even with the exact old identity'
    Assert-CcodEqual $null (Get-CcodSupervisorStaleReconciliationCandidate $mismatchedState $mismatched $live $hostState.Identity $fixture.Fake.Adapters) 'mismatched old MSIX executable path never becomes a stale candidate'
    Assert-CcodEqual $null (Get-CcodSupervisorStaleReconciliationCandidate $inactiveState $unproven $live $hostState.Identity $fixture.Fake.Adapters) 'stale candidate requires an Active persisted status'
    Assert-CcodEqual $null (Get-CcodSupervisorStaleReconciliationCandidate $unverifiedState $unproven $live $hostState.Identity $fixture.Fake.Adapters) 'stale candidate requires exact successful prior verification'

    $world.Calls.Clear();$world.ProcessIds=@(201,333);$hostState.ForceReconcile=$true
    Invoke-CcodSupervisorTick $hostState $fixture.Fake.Adapters
    Assert-CcodTrue (@($seenStatusEvidence|Where-Object{[object]::ReferenceEquals($_,$status)}).Count -eq 2) 'refresh passes persisted status evidence through the production snapshot call shape'
    Assert-CcodEqual 0 @($hostState.Special).Count 'unproven debug processes remain outside the Special set'
    Assert-CcodEqual 'StalePackageStatus' $hostState.Reason 'one constrained stale candidate produces the fixed reason'
    $candidateProperty=$hostState.PSObject.Properties['StaleReconciliationCandidate']
    Assert-CcodTrue ($null -ne $candidateProperty -and $null -ne $candidateProperty.Value -and $candidateProperty.Value.Pid -eq 201) 'candidate binds only the exact prior verified process identity'
    Assert-CcodEqual 0 @($world.Calls|Where-Object{$_ -like 'Start:Controller:*'}).Count 'stale package evidence never dispatches direct controller repair'
    Assert-CcodTrue ($null-eq$hostState.WorkerSlot -and $null-eq$hostState.LifecycleWorkerSlot) 'stale evidence starts no mutation worker'
    Assert-CcodEqual 'Error' $hostState.ConnectionState 'stale package evidence fails the connection closed'
    Assert-CcodEqual 'Running' $hostState.ProtectionState 'Supervisor protection ownership remains running while stale evidence is blocked'
    Assert-CcodTrue $hostState.BlockAutomaticActions 'stale package evidence remains blocked for explicit later migration'
    Assert-CcodEqual $stateBefore ($state|ConvertTo-Json -Depth 20 -Compress) 'candidate reconciliation does not clear persisted state'
    $keysAfter=($hostState.AttemptKeys|ConvertTo-Json -Compress)+($hostState.RecoveryIgnoreKeys|ConvertTo-Json -Compress)+($hostState.SuppressionKeys|ConvertTo-Json -Compress)
    Assert-CcodEqual $keysBefore $keysAfter 'candidate reconciliation and targeted retry preserve unrelated key or authorization membership'
    Assert-CcodEqual 0 @($world.Calls|Where-Object{$_ -eq 'Manual:Clear'}).Count 'candidate reconciliation never clears failed package records'
}

Invoke-CcodTest 'processes at most one command before reducer decisions' {
    $fixture=New-CcodTickFixture;$world=$fixture.Fake.World;$hostState=$fixture.Host
    $world.Decision=[pscustomobject][ordered]@{Action='RepairRenderer';Reason='Repair';Target=$null;AttemptKey=$null;SuppressionKey=$null;EffectiveClassification=$null;RequiresController=$true}
    foreach($kind in @('OpenLogs','ApplyNow')){$world.CommandQueue.Enqueue([pscustomobject][ordered]@{Kind=$kind;Value=$null;EnqueuedAtUtc='2030-02-03T03:04:05.0000000Z'})}
    Invoke-CcodSupervisorTick $hostState $fixture.Fake.Adapters
    Assert-CcodTrue ($world.Calls.Contains('Open:Logs')) 'first command executes'
    Assert-CcodTrue $world.TryDequeueSawRealQueue 'command dequeue receives the queue object itself'
    Assert-CcodEqual 1 $world.CommandQueue.Count 'only one command is consumed'
    Assert-CcodEqual 0 @($world.Calls|Where-Object{$_ -like 'Start:*'}).Count 'decision does not run in command tick'
}

Invoke-CcodTest 'passes queue objects themselves during host creation with non-empty queues' {
    $fake=New-CcodSupervisorFake
    $fake.World.CommandQueue.Enqueue([pscustomobject][ordered]@{Kind='OpenLogs';Value=$null;EnqueuedAtUtc='2030-02-03T03:04:05.0000000Z'})
    $fake.World.EventQueue.Enqueue([pscustomobject][ordered]@{ProcessId=71;EventKind='Started';ObservedAtUtc='2030-02-03T03:04:05.0000000Z'})
    $receipt=Invoke-CcodSupervisorHost -ReadyToken $readyToken -Adapters $fake.Adapters
    Assert-CcodReceipt $receipt 'Stopped' 0
    Assert-CcodTrue $fake.World.NewTraySawRealQueue 'non-empty command queue is not enumerated into tray arguments'
    Assert-CcodTrue $fake.World.NewWatcherSawRealQueue 'non-empty event queue is not enumerated into watcher arguments'
    Assert-CcodTrue ($null -ne $fake.World.OnTick) 'tray callback is the second argument'
}

Invoke-CcodTest 'drains the command queue through the real queue object' {
    $fixture=New-CcodTickFixture;$world=$fixture.Fake.World
    foreach($kind in @('OpenLogs','ApplyNow')){$world.CommandQueue.Enqueue([pscustomobject][ordered]@{Kind=$kind;Value=$null;EnqueuedAtUtc='2030-02-03T03:04:05.0000000Z'})}
    Invoke-CcodSupervisorDrainQueue $world.CommandQueue $fixture.Fake.Adapters
    Assert-CcodEqual 0 $world.CommandQueue.Count 'drain consumes every queued command'
    Assert-CcodTrue $world.TryDequeueSawRealQueue 'drain dequeue receives the queue object itself'
}

Invoke-CcodTest 'routes repair and apply decisions into durable lifecycle while StaticProbe remains read-only' {
    $cases=@(
        [pscustomobject]@{Decision='RepairRenderer';Kind='Lifecycle';Action=$null;Target=$null},
        [pscustomobject]@{Decision='InspectOrdinary';Kind='StaticProbe';Action='StaticProbe';Target=(New-CcodSupervisorTestSnapshot)},
        [pscustomobject]@{Decision='ApplyOrdinary';Kind='Lifecycle';Action=$null;Target=(New-CcodSupervisorTestSnapshot)}
    )
    foreach($case in $cases){
        $fixture=New-CcodTickFixture;$world=$fixture.Fake.World;$hostState=$fixture.Host
        $world.Decision=[pscustomobject][ordered]@{Action=$case.Decision;Reason='Test';Target=$case.Target;AttemptKey=$(if($null -ne $case.Target){'71|2030-02-03T03:01:00.0000000Z'}else{$null});SuppressionKey=$null;EffectiveClassification=$(if($case.Decision -eq 'ApplyOrdinary'){'CandidateCompatible'}else{$null});RequiresController=$true}
        Invoke-CcodSupervisorTick $hostState $fixture.Fake.Adapters
        if($case.Kind-ceq'StaticProbe'){
            Assert-CcodTrue ($world.Calls.Contains('Start:StaticProbe:StaticProbe')) 'static inspection maps to the read-only worker'
            Assert-CcodEqual 'StaticProbe' $hostState.WorkerSlot.Kind 'static inspection owns the legacy read-only slot'
        }else{
            Assert-CcodEqual 0 @($world.Calls|Where-Object{$_ -like 'Start:Controller:*'}).Count "$($case.Decision) never starts a controller worker"
            Assert-CcodTrue ($null-ne$hostState.LifecycleRequest -and $hostState.LifecycleRequest.kind-ceq'CheckAndRepair') "$($case.Decision) creates one durable CheckAndRepair request"
        }
    }
}

Invoke-CcodTest 'false migration preferences remain truthful in presentation while guardian Apply proceeds' {
    $fixture=New-CcodTickFixture;$world=$fixture.Fake.World;$hostState=$fixture.Host
    $hostState.State.AutomationEnabled=$false;$hostState.State.AutomaticCandidateTrialsAllowed=$false
    $hostState.State.Settings.candidateCompatibleOptIn=$false
    $hostState.PackageFullName='OpenAI.Codex_1.0.0.0_x64__2p2nqsd0c76g0';$hostState.AppAsarSha256=('a'*64);$hostState.Classification='CandidateCompatible'
    $ordinary=New-CcodSupervisorTestSnapshot;$world.ProcessIds=@([int]$ordinary.Pid);$world.Snapshots[[int]$ordinary.Pid]=$ordinary
    $fixture.Fake.Adapters.ReadState={param($StateRoot,$SuppressionKey)$hostState.State}.GetNewClosure()
    $fixture.Fake.Adapters.GetSupervisorDecision={param($Context)$world.Calls.Add('Decision');Get-CcodSupervisorDecision -Context $Context}.GetNewClosure()
    Invoke-CcodSupervisorTick $hostState $fixture.Fake.Adapters
    Assert-CcodTrue ($null-ne$hostState.LifecycleRequest -and $hostState.LifecycleRequest.kind-ceq'CheckAndRepair') 'guardian creates the durable Apply lifecycle despite false migration values'
    Assert-CcodTrue ($world.PresentationInputs.Count-gt0) 'one truthful presentation input is projected'
    $presentationInput=$world.PresentationInputs[$world.PresentationInputs.Count-1]
    Assert-CcodEqual $false $presentationInput.AutomationEnabled 'presentation preserves persisted false automation migration value'
    Assert-CcodEqual $false $presentationInput.CandidateCompatibleOptIn 'presentation preserves persisted false candidate migration value'
}

Invoke-CcodTest 'Apply controller request carries the full process snapshot source' {
    $fixture=New-CcodTickFixture
    $target=New-CcodSupervisorTestSnapshot
    $request=New-CcodSupervisorControllerRequest -HostState $fixture.Host -Action 'Apply' -Target $target
    Assert-CcodEqual 'schemaVersion,action,transactionId,runtimeId,supervisorIdentity,source,existingOnly,rendererPort,mainPort,timeoutMilliseconds,restartOrdinary' (@($request.PSObject.Properties.Name)-join ',') 'Apply request keeps the controller schema'
    $expected=@('Pid','CreationTimeUtc','SessionId','UserSid','Path','PackageFamilyName','CommandLine','ParentPid','IsTopLevel','Mode','RendererPort','MainPort')
    Assert-CcodEqual ($expected-join ',') (@($request.source.PSObject.Properties.Name)-join ',') 'Apply source is the full process snapshot'
    Assert-CcodEqual $target.Pid $request.source.Pid 'source Pid survives'
    Assert-CcodEqual $target.CreationTimeUtc $request.source.CreationTimeUtc 'source creation time survives'
    Assert-CcodEqual $target.Path $request.source.Path 'source executable path survives'
    Assert-CcodTrue ($request.existingOnly -and $request.restartOrdinary -and $null -eq $request.rendererPort -and $null -eq $request.mainPort) 'Apply flags stay consistent'

    $staleOnly=New-CcodSupervisorControllerRequest -HostState $fixture.Host -Action 'Apply' -Target $null
    Assert-CcodTrue ($null -eq $staleOnly.source -and -not $staleOnly.existingOnly -and $staleOnly.restartOrdinary) 'stale-only Apply is an explicit source-less repair request'
}

Invoke-CcodTest 'Apply rejects a partial source target before a worker request is written' {
    $fixture=New-CcodTickFixture
    $partial=[pscustomobject][ordered]@{Pid=71;CreationTimeUtc='2030-02-03T03:01:00.0000000Z'}
    $threw=$false
    try{New-CcodSupervisorControllerRequest -HostState $fixture.Host -Action 'Apply' -Target $partial|Out-Null}catch{$threw=$true}
    Assert-CcodTrue $threw 'partial Apply target is rejected'
}

Invoke-CcodTest 'keeps production defaults lazy and source free of forbidden direct mutations' {
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($supervisorPath,[ref]$tokens,[ref]$errors)
    Assert-CcodEqual 0 @($errors).Count 'Supervisor parses cleanly'
    $paramNames=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.ParameterAst]},$true)|ForEach-Object{$_.Name.VariablePath.UserPath})
    Assert-CcodEqual 0 @($paramNames|Where-Object{$_ -ieq 'Pid'}).Count 'supervisor adapter callbacks avoid the read-only automatic PID variable name'
    $commands=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst]},$true)|ForEach-Object{$_.GetCommandName()}|Where-Object{$_})
    foreach($forbidden in @('Get-AppxPackage','Stop-Process','Start-Process','schtasks.exe','Set-ItemProperty','New-ItemProperty','netsh.exe')){
        Assert-CcodEqual 0 @($commands|Where-Object{$_ -ceq $forbidden}).Count "$forbidden is absent from Supervisor AST"
    }
}

Invoke-CcodTest 'loading the supervisor keeps WinForms deferred until the UI context runs' {
    $escapedPath = $supervisorPath.Replace("'", "''")
    $probe = @"
`$ErrorActionPreference = 'Stop'
. '$escapedPath' -ReadyToken ('a' * 64)
`$loaded = @([AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { `$_.GetName().Name -ceq 'System.Windows.Forms' })
if (`$loaded.Count -ne 0) { exit 17 }
"@
    & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $probe
    Assert-CcodEqual 0 $LASTEXITCODE 'supervisor loading does not initialize the tray UI assembly'
}

Invoke-CcodTest 'production worker identity adapter avoids the read-only PID variable collision' {
    $adapters=Get-CcodSupervisorAdapters
    $identity=$null
    try{$identity=& $adapters.GetWorkerIdentity $PID}catch{}
    Assert-CcodTrue ($null -ne $identity) 'worker identity adapter must resolve without overwriting the automatic PID variable'
    Assert-CcodEqual $PID $identity.Pid 'worker identity resolves the exact current process'
    Assert-CcodTrue ($identity.CreationTimeUtc -is [string] -and -not [string]::IsNullOrWhiteSpace($identity.CreationTimeUtc)) 'worker identity creation time is present'
}


Invoke-CcodTest 'default adapters keep imported modules visible for lease acquisition' {
    $defaults = Get-CcodSupervisorDefaultAdapters
    Assert-CcodTrue ($defaults.ContainsKey('EnterLease')) 'default EnterLease exists'
    $identity = & $defaults.GetIdentity
    Assert-CcodTrue ($identity.UserSid -is [string] -and $identity.UserSid.Length -gt 0) 'default identity returns current SID'
    $lease = $null
    try {
        $lease = & $defaults.EnterLease 'AccountSupervisor' $identity.UserSid $null 1000
        Assert-CcodEqual 'AccountSupervisor' $lease.Kind 'default EnterLease returns AccountSupervisor lease'
        Assert-CcodTrue (@('Acquired','TimedOut') -ccontains $lease.Outcome) 'default EnterLease returns a valid outcome'
    } finally {
        if ($null -ne $lease -and $lease.Outcome -ceq 'Acquired') {
            $released = & $defaults.ExitLease $lease
            Assert-CcodEqual $true $released 'default ExitLease releases the lease'
        }
    }
}

Invoke-CcodTest 'adapter capture ignores nonterminating $Error pollution from successful adapters' {
    $adapters = Get-CcodSupervisorDefaultAdapters
    $adapters.Polluted = {
        $global:Error.Insert(0, [Management.Automation.ErrorRecord]::new(
            [InvalidOperationException]::new('noise'),
            'CCOD_TEST_NOISE',
            [Management.Automation.ErrorCategory]::NotSpecified,
            $null
        ))
        [pscustomobject][ordered]@{SchemaVersion=1;Value='ok'}
    }
    $before = @($global:Error)
    $result = Invoke-CcodSupervisorAdapter $adapters.Polluted @() 1
    Assert-CcodEqual 'ok' $result.Value 'successful polluted adapter still returns its object'
    Assert-CcodEqual $before.Count $global:Error.Count 'caller error history count is restored'
    if ($before.Count -gt 0) {
        Assert-CcodTrue ([object]::ReferenceEquals($before[0], $global:Error[0])) 'caller error history head is restored'
    }
}

Invoke-CcodTest 'worker request ids are canonical D-format GUIDs for probe framing' {
    $fixture = New-CcodTickFixture
    $target = New-CcodSupervisorTestSnapshot
    $slot = Start-CcodSupervisorWorkerSlot -HostState $fixture.Host -Adapters $fixture.Fake.Adapters -Kind 'StaticProbe' -Action 'StaticProbe' -Target $target
    Assert-CcodTrue ($slot.RequestId -cmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') 'worker request id is a canonical D-format GUID'
    Assert-CcodEqual $slot.RequestId $slot.Request.requestId 'static probe request carries the same request id'
    Assert-CcodTrue ($slot.RequestPath.EndsWith("static-probe-$($slot.RequestId).request.json")) 'request path matches StaticProbeWorker framing'
}

Invoke-CcodTest 'fails closed when a static worker fabricates a ready candidate without sentinel proof' {
    $fixture=New-CcodTickFixture;$world=$fixture.Fake.World;$hostState=$fixture.Host
    $target=New-CcodSupervisorTestSnapshot
    $slot=Start-CcodSupervisorWorkerSlot $hostState $fixture.Fake.Adapters 'StaticProbe' 'StaticProbe' $target
    $world.WorkerResult=[pscustomobject][ordered]@{
        schemaVersion=1;action='StaticProbe';ok=$true;requestId=$slot.Request.requestId;runtimeId=$slot.Request.runtimeId
        targetIdentity=[pscustomobject][ordered]@{pid=$slot.Request.targetIdentity.pid;creationTimeUtc=$slot.Request.targetIdentity.creationTimeUtc}
        probe=[pscustomobject][ordered]@{
            ready=$true;code='CHECKER_OK';staticClassification='CandidateCompatible';packageInstalled=$true
            packageFullName='OpenAI.Codex_1.0.0.0_x64__2p2nqsd0c76g0';packageFamilyName='OpenAI.Codex_2p2nqsd0c76g0';packageVersion='1.0.0.0'
            executablePath='C:\Fake\Codex\app\ChatGPT.exe';appAsarSha256=('a'*64);nodeVersion='v22.23.1';nodeMajor=22;nodeSupported=$true;nativeModulePresent=$true
        };error=$null
    }
    $stdout=$world.WorkerResult|ConvertTo-Json -Depth 20 -Compress
    $world.Poll=[pscustomobject][ordered]@{Completed=$true;ExitCode=[int]0;StdoutText=$stdout;StdoutByteCount=[int]$stdout.Length;StdoutOverflow=$false;StderrByteCount=[int]0;StderrOverflow=$false}
    Invoke-CcodSupervisorPollSlot $hostState $fixture.Fake.Adapters
    Assert-CcodEqual 'UnknownOrIncompatible' $hostState.Classification 'incomplete public proof cannot update the candidate classification'
    Assert-CcodEqual 'WorkerFramingFailed' $hostState.Reason 'malformed public proof is recorded as a framing failure'
    Assert-CcodEqual $true $hostState.BlockAutomaticActions 'malformed public proof blocks automatic actions'
}

Invoke-CcodTest 'hands External renderer back only after a verified shared-renderer controller result' {
    $fixture=New-CcodTickFixture;$world=$fixture.Fake.World;$hostState=$fixture.Host
    $handoffCalls=[Collections.Generic.List[object]]::new()
    $fixture.Fake.Adapters.HandoffRenderer={
        param($Result,$RendererPort)
        $world.Calls.Add('HandoffRenderer')
        $handoffCalls.Add([pscustomobject][ordered]@{Result=$Result;RendererPort=$RendererPort})
        [pscustomobject][ordered]@{Outcome='Started';Code='CCOD_RENDERER_HANDOFF_STARTED';ProcessId=[int]77}
    }.GetNewClosure()
    $runResult={
        param($Action,$Result)
        $world.WorkerResult=$Result
        $stdout=$Result|ConvertTo-Json -Depth 20 -Compress
        $world.Poll=[pscustomobject][ordered]@{Completed=$true;ExitCode=[int]0;StdoutText=$stdout;StdoutByteCount=[int]$stdout.Length;StdoutOverflow=$false;StderrByteCount=[int]0;StderrOverflow=$false}
        Start-CcodSupervisorWorkerSlot $hostState $fixture.Fake.Adapters 'Controller' $Action $(if($Action -ceq 'Apply'){New-CcodSupervisorTestSnapshot}else{$null})|Out-Null
        Invoke-CcodSupervisorPollSlot $hostState $fixture.Fake.Adapters
    }
    $result=[pscustomobject][ordered]@{ok=$true;outcome='Activated';safeState='SpecialValidated';special=[pscustomobject][ordered]@{rendererPort=[int]9335}}
    & $runResult 'Apply' $result
    Assert-CcodEqual 1 $handoffCalls.Count 'verified Apply hands the shared renderer to External renderer once'
    Assert-CcodTrue ([object]::ReferenceEquals($result,$handoffCalls[0].Result)) 'handoff receives the worker result'
    Assert-CcodEqual 9335 $handoffCalls[0].RendererPort 'handoff receives the shared renderer port'
    $eventOrder=@($world.Calls|Where-Object{$_ -in @('Read:WorkerResult','Reduce:Apply','HandoffRenderer','Dispose:501')})
    Assert-CcodEqual @('Read:WorkerResult','Reduce:Apply','HandoffRenderer','Dispose:501') $eventOrder 'handoff runs after reduction and before worker disposal'

    $world.Calls.Clear();$handoffCalls.Clear()
    $failed=[pscustomobject][ordered]@{ok=$false;outcome='Failed';safeState='Error';special=$null}
    & $runResult 'RepairRenderer' $failed
    Assert-CcodEqual 0 $handoffCalls.Count 'failed controller results do not hand off External renderer'

    $world.Calls.Clear();$handoffCalls.Clear()
    $ordinary=[pscustomobject][ordered]@{ok=$true;outcome='Recovered';safeState='Ordinary';special=[pscustomobject][ordered]@{rendererPort=[int]9335}}
    & $runResult 'Recover' $ordinary
    Assert-CcodEqual 0 $handoffCalls.Count 'ordinary recovery results do not hand off External renderer'
}

Invoke-CcodTest 'default External renderer handoff skips paused and invalid saved state and rebinds after a dead injector' {
    $temporaryLocalAppData=Join-Path ([IO.Path]::GetTempPath()) ('ccod-supervisor-renderer-'+[guid]::NewGuid().ToString('N'))
    $previousLocalAppData=$env:LOCALAPPDATA
    try{
        $env:LOCALAPPDATA=$temporaryLocalAppData
        $root=Join-Path $temporaryLocalAppData 'CodexRenderer'
        New-Item -ItemType Directory -Path (Join-Path $root 'engine\scripts') -Force|Out-Null
        [IO.File]::WriteAllText((Join-Path $root 'engine\scripts\start-renderer.ps1'),'# test fixture',[Text.UTF8Encoding]::new($false))
        $defaults=Get-CcodSupervisorDefaultAdapters
        [IO.File]::WriteAllText((Join-Path $root 'paused'),'',[Text.UTF8Encoding]::new($false))
        $paused=& $defaults.HandoffRenderer $null 9444
        Assert-CcodEqual 'Skipped' $paused.Outcome 'pause marker skips the real default handoff adapter'
        Assert-CcodEqual 'CCOD_RENDERER_PAUSED' $paused.Code 'pause marker skip code is stable'
        Remove-Item -LiteralPath (Join-Path $root 'paused') -Force
        [IO.File]::WriteAllText((Join-Path $root 'state.json'),'{not-json',[Text.UTF8Encoding]::new($false))
        $invalid=& $defaults.HandoffRenderer $null 9444
        Assert-CcodEqual 'Skipped' $invalid.Outcome 'invalid saved state leaves optional handoff unavailable'
        Assert-CcodEqual 'CCOD_RENDERER_STATE_UNAVAILABLE' $invalid.Code 'invalid saved state has a stable skip code'
        Remove-Item -LiteralPath (Join-Path $root 'state.json') -Force
        New-Item -ItemType Directory -Path (Join-Path $root 'state.json') -Force|Out-Null
        $directoryState=& $defaults.HandoffRenderer $null 9444
        Assert-CcodEqual 'Skipped' $directoryState.Outcome 'a directory at state.json leaves optional handoff unavailable'
        Assert-CcodEqual 'CCOD_RENDERER_STATE_UNAVAILABLE' $directoryState.Code 'a state-path directory has the stable skip code'
        Remove-Item -LiteralPath (Join-Path $root 'state.json') -Recurse -Force
        $codexExe=(Join-Path $PSHOME 'powershell.exe')
        $validState=[ordered]@{port=[int]9335;browserId='browser-previous';injectorPid=[int]999999;codexExe=$codexExe}|ConvertTo-Json -Compress
        [IO.File]::WriteAllText((Join-Path $root 'state.json'),$validState,[Text.UTF8Encoding]::new($false))
        $identityUnavailable=& $defaults.HandoffRenderer $null 9444
        Assert-CcodEqual 'Skipped' $identityUnavailable.Outcome 'valid saved state skips when the current Browser ID cannot be read'
        Assert-CcodEqual 'CCOD_RENDERER_IDENTITY_UNAVAILABLE' $identityUnavailable.Code 'identity-unavailable skip avoids a port-only idempotency guess'
    }finally{
        $env:LOCALAPPDATA=$previousLocalAppData
        if([IO.Directory]::Exists($temporaryLocalAppData)){Remove-Item -LiteralPath $temporaryLocalAppData -Recurse -Force}
    }
}

Invoke-CcodTest 'default External renderer handoff rebinds after the saved injector died even when the renderer port changed' {
    $temporaryLocalAppData=Join-Path ([IO.Path]::GetTempPath()) ('ccod-supervisor-renderer-rebind-'+[guid]::NewGuid().ToString('N'))
    $previousLocalAppData=$env:LOCALAPPDATA
    try{
        $env:LOCALAPPDATA=$temporaryLocalAppData
        $root=Join-Path $temporaryLocalAppData 'CodexRenderer'
        $marker=Join-Path $temporaryLocalAppData 'received-port.txt'
        New-Item -ItemType Directory -Path (Join-Path $root 'engine\scripts') -Force|Out-Null
        $escapedMarker=$marker.Replace("'","''")
        $scriptText="param([int]`$Port)`n[IO.File]::WriteAllText('$escapedMarker',[string]`$Port,[Text.UTF8Encoding]::new(`$false))"
        [IO.File]::WriteAllText((Join-Path $root 'engine\scripts\start-renderer.ps1'),$scriptText,[Text.UTF8Encoding]::new($false))
        $codexExe=(Join-Path $PSHOME 'powershell.exe')
        $validState=[ordered]@{port=[int]9335;browserId='browser-previous';injectorPid=[int]999999;codexExe=$codexExe}|ConvertTo-Json -Compress
        [IO.File]::WriteAllText((Join-Path $root 'state.json'),$validState,[Text.UTF8Encoding]::new($false))
        $reserve=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
        $reserve.Start()
        try{$port=([Net.IPEndPoint]$reserve.LocalEndpoint).Port}finally{$reserve.Stop()}
        $server=Start-Job -ScriptBlock {
            param([int]$Port)
            $listener=[Net.HttpListener]::new()
            try{
                $listener.Prefixes.Add(('http://127.0.0.1:{0}/' -f $Port))
                $listener.Start()
                Write-Output 'READY'
                $context=$listener.GetContext()
                if($context.Request.RawUrl -cne '/json/version'){throw 'unexpected request path'}
                $body='{"Browser":"Chrome/Test","webSocketDebuggerUrl":"ws://127.0.0.1:'+$Port+'/devtools/browser/browser-current"}'
                $bytes=[Text.UTF8Encoding]::new($false).GetBytes($body)
                $context.Response.StatusCode=200
                $context.Response.ContentType='application/json'
                $context.Response.ContentLength64=$bytes.Length
                $context.Response.OutputStream.Write($bytes,0,$bytes.Length)
                $context.Response.OutputStream.Close()
            }finally{
                if($listener.IsListening){$listener.Stop()}
                $listener.Close()
            }
        } -ArgumentList $port
        try{
            $readyDeadline=[DateTime]::UtcNow.AddSeconds(5)
            while([DateTime]::UtcNow -lt $readyDeadline -and -not (@(Receive-Job -Job $server -Keep) -ccontains 'READY')){
                if($server.State -in @('Failed','Stopped','Completed')){break}
                Start-Sleep -Milliseconds 50
            }
            Assert-CcodTrue (@(Receive-Job -Job $server -Keep) -ccontains 'READY') 'rebind HTTP fixture starts'
            $defaults=Get-CcodSupervisorDefaultAdapters
            $started=& $defaults.HandoffRenderer $null $port
            Assert-CcodEqual 'Started' $started.Outcome 'dead saved injector allows a fresh handoff to the current renderer'
            Assert-CcodEqual 'CCOD_RENDERER_HANDOFF_STARTED' $started.Code 'dead saved injector rebind code is stable'
            $deadline=[DateTime]::UtcNow.AddSeconds(5)
            while(-not [IO.File]::Exists($marker) -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 50}
            Assert-CcodTrue ([IO.File]::Exists($marker)) 'dead saved injector rebind launches the official script'
            Assert-CcodEqual ([string]$port) ([IO.File]::ReadAllText($marker,[Text.UTF8Encoding]::new($false))) 'rebind uses the current renderer port, not the stale saved port'
        }finally{
            if($server.State -notin @('Completed','Failed','Stopped')){Stop-Job -Job $server -ErrorAction SilentlyContinue}
            Remove-Job -Job $server -Force -ErrorAction SilentlyContinue
        }
    }finally{
        $env:LOCALAPPDATA=$previousLocalAppData
        if([IO.Directory]::Exists($temporaryLocalAppData)){Remove-Item -LiteralPath $temporaryLocalAppData -Recurse -Force}
    }
}

Invoke-CcodTest 'default External renderer handoff stays attached when the saved injector is alive with the same Browser ID' {
    $temporaryLocalAppData=Join-Path ([IO.Path]::GetTempPath()) ('ccod-supervisor-renderer-attached-'+[guid]::NewGuid().ToString('N'))
    $previousLocalAppData=$env:LOCALAPPDATA
    try{
        $env:LOCALAPPDATA=$temporaryLocalAppData
        $root=Join-Path $temporaryLocalAppData 'CodexRenderer'
        New-Item -ItemType Directory -Path (Join-Path $root 'engine\scripts') -Force|Out-Null
        [IO.File]::WriteAllText((Join-Path $root 'engine\scripts\start-renderer.ps1'),'# test fixture',[Text.UTF8Encoding]::new($false))
        $current=[Diagnostics.Process]::GetCurrentProcess()
        try{
            $validState=[ordered]@{port=[int]9335;browserId='browser-current';injectorPid=[int]$current.Id;codexExe=(Join-Path $PSHOME 'powershell.exe')}|ConvertTo-Json -Compress
            [IO.File]::WriteAllText((Join-Path $root 'state.json'),$validState,[Text.UTF8Encoding]::new($false))
            $reserve=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
            $reserve.Start()
            try{$port=([Net.IPEndPoint]$reserve.LocalEndpoint).Port}finally{$reserve.Stop()}
            $server=Start-Job -ScriptBlock {
                param([int]$Port)
                $listener=[Net.HttpListener]::new()
                try{
                    $listener.Prefixes.Add(('http://127.0.0.1:{0}/' -f $Port))
                    $listener.Start()
                    Write-Output 'READY'
                    $context=$listener.GetContext()
                    if($context.Request.RawUrl -cne '/json/version'){throw 'unexpected request path'}
                    $body='{"Browser":"Chrome/Test","webSocketDebuggerUrl":"ws://127.0.0.1:'+$Port+'/devtools/browser/browser-current"}'
                    $bytes=[Text.UTF8Encoding]::new($false).GetBytes($body)
                    $context.Response.StatusCode=200
                    $context.Response.ContentType='application/json'
                    $context.Response.ContentLength64=$bytes.Length
                    $context.Response.OutputStream.Write($bytes,0,$bytes.Length)
                    $context.Response.OutputStream.Close()
                }finally{
                    if($listener.IsListening){$listener.Stop()}
                    $listener.Close()
                }
            } -ArgumentList $port
            try{
                $readyDeadline=[DateTime]::UtcNow.AddSeconds(5)
                while([DateTime]::UtcNow -lt $readyDeadline -and -not (@(Receive-Job -Job $server -Keep) -ccontains 'READY')){
                    if($server.State -in @('Failed','Stopped','Completed')){break}
                    Start-Sleep -Milliseconds 50
                }
                Assert-CcodTrue (@(Receive-Job -Job $server -Keep) -ccontains 'READY') 'attached HTTP fixture starts'
                $defaults=Get-CcodSupervisorDefaultAdapters
                $started=& $defaults.HandoffRenderer $null $port
                Assert-CcodEqual 'Skipped' $started.Outcome 'same Browser ID with a live saved injector stays attached'
                Assert-CcodEqual 'CCOD_RENDERER_ALREADY_ATTACHED' $started.Code 'same Browser ID with a live saved injector is idempotent'
            }finally{
                if($server.State -notin @('Completed','Failed','Stopped')){Stop-Job -Job $server -ErrorAction SilentlyContinue}
                Remove-Job -Job $server -Force -ErrorAction SilentlyContinue
            }
        }finally{$current.Dispose()}
    }finally{
        $env:LOCALAPPDATA=$previousLocalAppData
        if([IO.Directory]::Exists($temporaryLocalAppData)){Remove-Item -LiteralPath $temporaryLocalAppData -Recurse -Force}
    }
}

Invoke-CcodTest 'records a bounded handoff failure without changing the verified session state' {
    $fixture=New-CcodTickFixture;$world=$fixture.Fake.World;$hostState=$fixture.Host
    $fixture.Fake.Adapters.HandoffRenderer={param($Result,$RendererPort)[pscustomobject][ordered]@{Outcome='Failed';Code='CCOD_RENDERER_HANDOFF_FAILED';ProcessId=$null}}
    $hostState.SessionState='Active';$hostState.BlockAutomaticActions=$false;$hostState.Reason='SpecialValidated'
    $slot=[pscustomobject][ordered]@{Action='RepairRenderer'}
    $result=[pscustomobject][ordered]@{ok=$true;safeState='SpecialValidated';special=[pscustomobject][ordered]@{rendererPort=[int]9335}}
    Invoke-CcodSupervisorRendererHandoff $hostState $slot $result $fixture.Fake.Adapters
    Assert-CcodEqual 1 $world.UiFailureRecords.Count 'failed receipt records one bounded handoff diagnostic'
    Assert-CcodEqual 'CCOD_RENDERER_HANDOFF_FAILED' $world.UiFailureRecords[0].code 'failed receipt log code is stable'
    Assert-CcodEqual 'Active' $hostState.SessionState 'failed optional handoff preserves verified controller state'
    Assert-CcodEqual $false $hostState.BlockAutomaticActions 'failed optional handoff does not block controller actions'
    Assert-CcodEqual 'RendererHandoff' $hostState.Reason 'failed optional handoff exposes the tray status reason'
}

Invoke-CcodTest 'keeps the External renderer handoff warning visible across ordinary active reconciliation' {
    $fixture=New-CcodTickFixture;$world=$fixture.Fake.World;$hostState=$fixture.Host
    $hostState.SessionState='Active';$hostState.Reason='RendererHandoff';$hostState.ForceReconcile=$false;$hostState.NextReconcileMilliseconds=[long]3000
    $world.Elapsed.Enqueue([long]0)
    $world.Decision=[pscustomobject][ordered]@{Action='KeepSpecial';Reason='SpecialActive';Target=$null;AttemptKey=$null;SuppressionKey=$null;EffectiveClassification='Verified';RequiresController=$false}
    $seen=[pscustomobject]@{Reason=$null}
    $fixture.Fake.Adapters.GetTrayPresentation={
        param($Arguments)
        $seen.Reason=$Arguments.Reason
        [pscustomobject][ordered]@{Color='Yellow';StateKey='RendererHandoff';SessionReadyVisible=$true;ApplyNowVisible=$false;ApplyNowEnabled=$false;ManualRetryVisible=$false;ManualRetryEnabled=$false;AutomationToggleEnabled=$true;AutomationChecked=$true;CandidateOptInToggleEnabled=$true;CandidateOptInChecked=$false;OpenLogsEnabled=$true;UninstallEnabled=$true;Busy=$false}
    }.GetNewClosure()
    Invoke-CcodSupervisorTick $hostState $fixture.Fake.Adapters
    Assert-CcodEqual 'RendererHandoff' $hostState.Reason 'ordinary active reconciliation does not erase the handoff warning'
    Assert-CcodEqual 'RendererHandoff' $seen.Reason 'tray projection receives the persisted handoff warning'
}

Write-Output "Supervisor self-tests passed: $($results.Count)"
