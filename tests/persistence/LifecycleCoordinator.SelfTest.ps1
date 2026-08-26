$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestSupport.ps1')

$repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$modulePath = Join-Path $repositoryRoot 'src\persistence\modules\LifecycleCoordinator.psm1'
if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) { throw "LifecycleCoordinator module is missing: $modulePath" }
Import-Module $modulePath -Force

function New-CcodCoordinatorFixture {
    param(
        [string]$Phase = 'Requested',
        [string]$Kind = 'RestartAndRepair',
        [int]$AutomaticLaunchAttempts = 0,
        [AllowNull()]$LaunchRequestedAtUtc = $null,
        [AllowNull()]$ManualLaunchExpiresAtUtc = $null,
        [AllowNull()]$ErrorCode = $null
    )
    [pscustomobject][ordered]@{
        schemaVersion=1;transactionId='11111111-2222-3333-4444-555555555555';kind=$Kind;origin='Tray'
        runtimeId='2.5.0-a';runtimeGeneration=[UInt64]4;leaseEpoch=[UInt64]9
        ownerIdentity=[pscustomobject][ordered]@{pid=401;creationTimeUtc='2030-02-03T04:05:06.0000000Z'}
        logonIdentity=[pscustomobject][ordered]@{authenticationId='00000000:000003E7';userSid='S-1-5-21-1-2-3-1001';sessionId=2}
        phase=$Phase;createdAtUtc='2030-02-03T04:05:00.0000000Z';updatedAtUtc='2030-02-03T04:05:00.0000000Z'
        launchRequestedAtUtc=$LaunchRequestedAtUtc;manualLaunchExpiresAtUtc=$ManualLaunchExpiresAtUtc
        automaticLaunchAttempts=$AutomaticLaunchAttempts;error=$ErrorCode
    }
}

function Assert-CcodCoordinatorStep {
    param($Step,[string]$Kind,[AllowNull()]$Next,[string]$Action,[AllowNull()]$Deadline,[AllowNull()]$ErrorCode,[string]$Message)
    Assert-CcodEqual 'kind,nextPhase,workerAction,deadlineUtc,errorCode' (($Step.PSObject.Properties.Name) -join ',') "$Message exact step shape"
    Assert-CcodEqual $Kind $Step.kind "$Message kind"
    Assert-CcodEqual $Next $Step.nextPhase "$Message next phase"
    Assert-CcodEqual $Action $Step.workerAction "$Message worker action"
    Assert-CcodEqual $Deadline $Step.deadlineUtc "$Message deadline"
    Assert-CcodEqual $ErrorCode $Step.errorCode "$Message error"
}

$results = @()

$results += Invoke-CcodTest 'phase table selects one exact lifecycle operation' {
    $cases = @(
        @{Phase='Requested';Kind='RestartAndRepair';Observation='Special';Next='CloseRequested';Action='Close'},
        @{Phase='CloseConfirmed';Kind='RestartAndRepair';Observation='NoCodex';Next='OrdinaryLaunchRequested';Action='RequestOrdinaryLaunch'},
        @{Phase='WaitingForManualLaunch';Kind='RestartAndRepair';Observation='Ordinary';Next='OrdinaryObserved';Action='None'},
        @{Phase='OrdinaryObserved';Kind='RestartAndRepair';Observation='Ordinary';Next='RepairRequested';Action='Apply'},
        @{Phase='RepairRequested';Kind='RestartAndRepair';Observation='RemoteVerified';Next='RemoteVerified';Action='None'}
    )
    foreach ($case in $cases) {
        $request = New-CcodCoordinatorFixture -Phase $case.Phase -Kind $case.Kind
        if ($case.Phase -ceq 'WaitingForManualLaunch') {
            $request.launchRequestedAtUtc='2030-02-03T04:05:10.0000000Z'
            $request.manualLaunchExpiresAtUtc='2030-02-03T04:15:10.0000000Z'
            $request.automaticLaunchAttempts=3
        }
        $step = Get-CcodLifecycleStep -Request $request -Observation $case.Observation -NowUtc '2030-02-03T04:06:00.0000000Z'
        Assert-CcodEqual $case.Next $step.nextPhase "$($case.Phase) next phase"
        Assert-CcodEqual $case.Action $step.workerAction "$($case.Phase) worker action"
    }
}

$results += Invoke-CcodTest 'a recovered close request cannot skip a still-running ordinary root' {
    $request = New-CcodCoordinatorFixture -Phase CloseRequested -Kind RestartAndRepair
    $step = Get-CcodLifecycleStep -Request $request -Observation Ordinary -NowUtc '2030-02-03T04:06:00.0000000Z'
    Assert-CcodCoordinatorStep $step Operation $null Close $null $null 'recovered close request with ordinary root'
}

$results += Invoke-CcodTest 'repair is idempotent and safe exit never selects Apply' {
    $connected = Get-CcodLifecycleStep -Request (New-CcodCoordinatorFixture -Kind CheckAndRepair) -Observation RemoteVerified -NowUtc '2030-02-03T04:06:00.0000000Z'
    Assert-CcodCoordinatorStep $connected Completed CancelledBeforeClose None $null $null 'already connected repair'
    foreach ($observation in @('Ordinary','NoCodex')) {
        $safe = Get-CcodLifecycleStep -Request (New-CcodCoordinatorFixture -Kind SafeExit) -Observation $observation -NowUtc '2030-02-03T04:06:00.0000000Z'
        Assert-CcodCoordinatorStep $safe Completed CancelledBeforeClose None $null $null "safe exit $observation"
    }
    foreach ($phase in @('Requested','CloseRequested','CloseConfirmed','OrdinaryLaunchRequested','WaitingForManualLaunch','OrdinaryObserved','RepairRequested','RemoteVerified')) {
        $request = New-CcodCoordinatorFixture -Kind SafeExit -Phase $phase -LaunchRequestedAtUtc '2030-02-03T04:05:10.0000000Z' -ManualLaunchExpiresAtUtc '2030-02-03T04:15:10.0000000Z'
        $step = Get-CcodLifecycleStep -Request $request -Observation Special -NowUtc '2030-02-03T04:06:00.0000000Z'
        Assert-CcodTrue ($step.workerAction -cne 'Apply') "safe exit phase $phase cannot apply remote control"
    }
}

$results += Invoke-CcodTest 'coordinator never invents an edge outside the durable transaction graph' {
    $edges=[ordered]@{
        Requested=@('CloseRequested','SupersededByUpgrade','CancelledBeforeClose');CloseRequested=@('CloseConfirmed','CloseFailed')
        CloseConfirmed=@('OrdinaryLaunchRequested','RepairRequested');OrdinaryLaunchRequested=@('OrdinaryObserved','WaitingForManualLaunch','OrdinaryLaunchFailed','OrdinaryObservationTimedOut')
        WaitingForManualLaunch=@('OrdinaryObserved','LaunchWindowExpired');OrdinaryObserved=@('RepairRequested')
        RepairRequested=@('RemoteVerified','RepairFailed','VerificationFailed');RemoteVerified=@('Completed')
    }
    foreach($kind in @('RestartAndRepair','CheckAndRepair','SafeExit')){
        foreach($phase in $edges.Keys){
            $request=New-CcodCoordinatorFixture -Kind $kind -Phase $phase -LaunchRequestedAtUtc '2030-02-03T04:05:10.0000000Z' -ManualLaunchExpiresAtUtc '2030-02-03T04:15:10.0000000Z'
            if($phase -ceq 'OrdinaryLaunchRequested'){$request.automaticLaunchAttempts=3}
            foreach($observation in @('NoCodex','Ordinary','Special','RemoteVerified','ObservationTimedOut')){
                $step=Get-CcodLifecycleStep -Request $request -Observation $observation -NowUtc '2030-02-03T04:06:00.0000000Z'
                Assert-CcodTrue ($null -eq $step.nextPhase -or $edges[$phase] -ccontains $step.nextPhase) "$kind $phase/$observation uses legal next phase $($step.nextPhase)"
            }
        }
    }
}

$results += Invoke-CcodTest 'automatic launch has three attempts then one ten minute manual window' {
    $first = Get-CcodLifecycleStep -Request (New-CcodCoordinatorFixture -Phase CloseConfirmed) -Observation NoCodex -NowUtc '2030-02-03T04:05:10.0000000Z'
    Assert-CcodCoordinatorStep $first Operation OrdinaryLaunchRequested RequestOrdinaryLaunch '2030-02-03T04:05:55.0000000Z' $null 'first automatic launch'
    foreach ($attempts in @(1,2)) {
        $request = New-CcodCoordinatorFixture -Phase OrdinaryLaunchRequested -AutomaticLaunchAttempts $attempts -LaunchRequestedAtUtc '2030-02-03T04:05:10.0000000Z' -ManualLaunchExpiresAtUtc '2030-02-03T04:15:10.0000000Z'
        $step = Get-CcodLifecycleStep -Request $request -Observation ObservationTimedOut -NowUtc '2030-02-03T04:06:00.0000000Z'
        Assert-CcodEqual RequestOrdinaryLaunch $step.workerAction "attempt $attempts retries activation"
        Assert-CcodEqual '2030-02-03T04:06:45.0000000Z' $step.deadlineUtc "attempt $attempts receives 45 second deadline"
    }
    $exhausted = New-CcodCoordinatorFixture -Phase OrdinaryLaunchRequested -AutomaticLaunchAttempts 3 -LaunchRequestedAtUtc '2030-02-03T04:05:10.0000000Z' -ManualLaunchExpiresAtUtc '2030-02-03T04:15:10.0000000Z'
    $manual = Get-CcodLifecycleStep -Request $exhausted -Observation ObservationTimedOut -NowUtc '2030-02-03T04:07:00.0000000Z'
    Assert-CcodCoordinatorStep $manual Waiting WaitingForManualLaunch ObserveOrdinary '2030-02-03T04:15:10.0000000Z' $null 'manual launch window'
    $expired = Get-CcodLifecycleStep -Request $exhausted -Observation ObservationTimedOut -NowUtc '2030-02-03T04:15:10.0000000Z'
    Assert-CcodCoordinatorStep $expired Failed LaunchWindowExpired None $null CODEX_LAUNCH_WINDOW_EXPIRED 'manual launch expiry'
}

$results += Invoke-CcodTest 'worker failures and stale ownership reduce to stable terminal phases' {
    $cases = @(
        @{Phase='CloseRequested';Action='Close';Code='CCOD_CLOSE_UNPROVEN';Next='CloseFailed'},
        @{Phase='RepairRequested';Action='Apply';Code='CCOD_APPLY_FAILED';Next='RepairFailed'},
        @{Phase='RepairRequested';Action='VerifyRemote';Code='CCOD_VERIFY_FAILED';Next='VerificationFailed'},
        @{Phase='RepairRequested';Action='VerifyRemote';Code='CCOD_LIFECYCLE_FENCE_STALE';Next='VerificationFailed'}
    )
    foreach ($case in $cases) {
        $request = New-CcodCoordinatorFixture -Phase $case.Phase
        $result = [pscustomobject][ordered]@{
            schemaVersion=1;transactionId=$request.transactionId;action=$case.Action;ok=$false;outcome='Error';observation='Error'
            error=[pscustomobject][ordered]@{code=$case.Code;stage='Operation';message='The lifecycle worker failed safely.'}
        }
        $reduced = Reduce-CcodLifecycleWorkerResult -Request $request -Result $result -NowUtc '2030-02-03T04:06:00.0000000Z'
        Assert-CcodEqual $case.Next $reduced.phase "$($case.Action) failure terminal phase"
        Assert-CcodEqual $case.Code $reduced.error "$($case.Action) preserves stable code"
    }
}

$results += Invoke-CcodTest 'launch receipt increments attempts once and fixes both persisted windows' {
    $request = New-CcodCoordinatorFixture -Phase OrdinaryLaunchRequested
    $result = [pscustomobject][ordered]@{schemaVersion=1;transactionId=$request.transactionId;action='RequestOrdinaryLaunch';ok=$true;outcome='LaunchRequested';observation='NoCodex';error=$null}
    $reduced = Reduce-CcodLifecycleWorkerResult -Request $request -Result $result -NowUtc '2030-02-03T04:05:10.0000000Z'
    Assert-CcodEqual 1 $reduced.automaticLaunchAttempts 'one receipt increments once'
    Assert-CcodEqual '2030-02-03T04:05:10.0000000Z' $reduced.launchRequestedAtUtc 'first request timestamp is persisted'
    Assert-CcodEqual '2030-02-03T04:15:10.0000000Z' $reduced.manualLaunchExpiresAtUtc 'manual window is fixed from first request'
}

$results += Invoke-CcodTest 'terminal lifecycle phases are exact no-ops' {
    foreach ($phase in @('Completed','CloseFailed','OrdinaryLaunchFailed','OrdinaryObservationTimedOut','LaunchWindowExpired','RepairFailed','VerificationFailed','CancelledBeforeClose','SupersededByUpgrade')) {
        $request = New-CcodCoordinatorFixture -Phase $phase -ErrorCode $(if($phase -ceq 'Completed'){$null}else{'CCOD_TERMINAL'})
        $step = Get-CcodLifecycleStep -Request $request -Observation NoCodex -NowUtc '2030-02-03T04:06:00.0000000Z'
        Assert-CcodCoordinatorStep $step Terminal $null None $null $request.error "terminal $phase"
    }
}

$results += Invoke-CcodTest 'retry launch receipts receive fresh immediate deadlines without extending manual expiry' {
    foreach($attempt in @(1,2)){
        $request=New-CcodCoordinatorFixture -Phase OrdinaryLaunchRequested -AutomaticLaunchAttempts $attempt -LaunchRequestedAtUtc '2030-02-03T04:05:10.0000000Z' -ManualLaunchExpiresAtUtc '2030-02-03T04:15:10.0000000Z'
        $now=$(if($attempt -eq 1){'2030-02-03T04:06:01.0000000Z'}else{'2030-02-03T04:07:02.0000000Z'})
        $want=$(if($attempt -eq 1){'2030-02-03T04:06:46.0000000Z'}else{'2030-02-03T04:07:47.0000000Z'})
        $step=Get-CcodLifecycleStep -Request $request -Observation LaunchRequested -NowUtc $now
        Assert-CcodCoordinatorStep $step Waiting $null ObserveOrdinary $want $null "attempt $($attempt+1) fresh immediate window"
        Assert-CcodEqual '2030-02-03T04:15:10.0000000Z' $request.manualLaunchExpiresAtUtc "attempt $($attempt+1) does not extend manual expiry"
    }
}

$results += Invoke-CcodTest 'reducer rejects wrong phase action outcome replay and attempt overflow before mutation' {
    $cases=@(
        @{Name='wrong phase/action';Request=(New-CcodCoordinatorFixture -Phase CloseRequested);Result=[pscustomobject][ordered]@{schemaVersion=1;transactionId='11111111-2222-3333-4444-555555555555';action='Apply';ok=$true;outcome='Activated';observation='Special';error=$null}},
        @{Name='incompatible close outcome';Request=(New-CcodCoordinatorFixture -Phase CloseRequested);Result=[pscustomobject][ordered]@{schemaVersion=1;transactionId='11111111-2222-3333-4444-555555555555';action='Close';ok=$true;outcome='Activated';observation='Special';error=$null}},
        @{Name='incompatible apply observation';Request=(New-CcodCoordinatorFixture -Phase RepairRequested);Result=[pscustomobject][ordered]@{schemaVersion=1;transactionId='11111111-2222-3333-4444-555555555555';action='Apply';ok=$true;outcome='Activated';observation='RemoteVerified';error=$null}},
        @{Name='terminal replay';Request=(New-CcodCoordinatorFixture -Phase Completed);Result=[pscustomobject][ordered]@{schemaVersion=1;transactionId='11111111-2222-3333-4444-555555555555';action='Close';ok=$true;outcome='Closed';observation='NoCodex';error=$null}},
        @{Name='attempt overflow';Request=(New-CcodCoordinatorFixture -Phase OrdinaryLaunchRequested -AutomaticLaunchAttempts 3 -LaunchRequestedAtUtc '2030-02-03T04:05:10.0000000Z' -ManualLaunchExpiresAtUtc '2030-02-03T04:15:10.0000000Z');Result=[pscustomobject][ordered]@{schemaVersion=1;transactionId='11111111-2222-3333-4444-555555555555';action='RequestOrdinaryLaunch';ok=$true;outcome='LaunchRequested';observation='NoCodex';error=$null}}
    )
    foreach($case in $cases){
        $before=$case.Request|ConvertTo-Json -Depth 16 -Compress
        Assert-CcodThrows {Reduce-CcodLifecycleWorkerResult -Request $case.Request -Result $case.Result -NowUtc '2030-02-03T04:06:00.0000000Z'|Out-Null} 'CCOD_LIFECYCLE_WORKER_RESULT_INVALID'
        Assert-CcodEqual $before ($case.Request|ConvertTo-Json -Depth 16 -Compress) "$($case.Name) leaves request unchanged"
    }
    $closeRequest=New-CcodCoordinatorFixture -Phase CloseRequested
    $closeResult=[pscustomobject][ordered]@{schemaVersion=1;transactionId=$closeRequest.transactionId;action='Close';ok=$true;outcome='Closed';observation='NoCodex';error=$null}
    $closed=Reduce-CcodLifecycleWorkerResult -Request $closeRequest -Result $closeResult -NowUtc '2030-02-03T04:06:00.0000000Z'
    Assert-CcodEqual CloseConfirmed $closed.phase 'first close result advances legally'
    Assert-CcodThrows {Reduce-CcodLifecycleWorkerResult -Request $closed -Result $closeResult -NowUtc '2030-02-03T04:06:01.0000000Z'|Out-Null} 'CCOD_LIFECYCLE_WORKER_RESULT_INVALID'
}

$results += Invoke-CcodTest 'waiting retry and terminal steps never encode invented self edges' {
    $cases=@(
        @{Request=(New-CcodCoordinatorFixture -Phase CloseRequested);Observation='Special'},
        @{Request=(New-CcodCoordinatorFixture -Phase OrdinaryLaunchRequested -AutomaticLaunchAttempts 1 -LaunchRequestedAtUtc '2030-02-03T04:05:10.0000000Z' -ManualLaunchExpiresAtUtc '2030-02-03T04:15:10.0000000Z');Observation='ObservationTimedOut'},
        @{Request=(New-CcodCoordinatorFixture -Phase WaitingForManualLaunch -AutomaticLaunchAttempts 3 -LaunchRequestedAtUtc '2030-02-03T04:05:10.0000000Z' -ManualLaunchExpiresAtUtc '2030-02-03T04:15:10.0000000Z');Observation='NoCodex'},
        @{Request=(New-CcodCoordinatorFixture -Phase RepairRequested);Observation='Special'},
        @{Request=(New-CcodCoordinatorFixture -Phase Completed);Observation='RemoteVerified'}
    )
    foreach($case in $cases){
        $step=Get-CcodLifecycleStep -Request $case.Request -Observation $case.Observation -NowUtc '2030-02-03T04:06:00.0000000Z'
        Assert-CcodEqual $null $step.nextPhase "$($case.Request.phase)/$($case.Observation) has no persisted transition this tick"
    }
}

$results | Format-Table -AutoSize
Write-Host ("Lifecycle coordinator self-tests passed: {0}" -f $results.Count)
