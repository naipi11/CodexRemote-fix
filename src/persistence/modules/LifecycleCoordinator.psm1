Set-StrictMode -Version 2.0

Import-Module (Join-Path $PSScriptRoot 'LifecycleTransaction.psm1') -Force

$script:CcodImmediateLaunchTimeoutMilliseconds = 45000
$script:CcodManualLaunchWindowMilliseconds = 600000
$script:CcodMaximumAutomaticLaunchAttempts = 3
$script:CcodLifecycleCoordinatorActions = @('None','Inspect','Close','RequestOrdinaryLaunch','ObserveOrdinary','Apply','VerifyRemote')
$script:CcodLifecycleCoordinatorObservations = @('Unknown','NoCodex','Ordinary','Special','RemoteVerified','Closed','CloseFailed','LaunchRequested','ObservationTimedOut','ApplyFailed','VerificationFailed','Error')
$script:CcodLifecycleCoordinatorTerminal = @(
    'Completed','CloseFailed','OrdinaryLaunchFailed','OrdinaryObservationTimedOut','LaunchWindowExpired','RepairFailed',
    'VerificationFailed','CancelledBeforeClose','SupersededByUpgrade'
)
$script:CcodLifecycleWorkerResultFields = @('schemaVersion','transactionId','action','ok','outcome','observation','error')

function Throw-CcodLifecycleCoordinatorError {
    param([string]$Id,[string]$Message,$Target)
    throw [Management.Automation.ErrorRecord]::new(
        [InvalidOperationException]::new($Message),$Id,[Management.Automation.ErrorCategory]::InvalidData,$Target)
}

function Assert-CcodCoordinatorRequest {
    param($Request)
    try {
        $module = Get-Module LifecycleTransaction | Select-Object -First 1
        if ($null -eq $module) { throw 'LifecycleTransaction module is unavailable' }
        & $module { param($Value) Assert-CcodLifecycleRequest -Request $Value } $Request
    } catch {
        Throw-CcodLifecycleCoordinatorError 'CCOD_LIFECYCLE_COORDINATOR_INVALID' ("Lifecycle coordinator request is invalid: {0}" -f $_.Exception.Message) $Request
    }
}

function ConvertTo-CcodCoordinatorUtc {
    param($Value,[string]$Name)
    $parsed=[DateTime]::MinValue
    if($Value -isnot [string] -or -not [DateTime]::TryParseExact($Value,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$parsed) -or
        $parsed.Kind -ne [DateTimeKind]::Utc -or $parsed.ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture) -cne $Value){
        Throw-CcodLifecycleCoordinatorError 'CCOD_LIFECYCLE_COORDINATOR_INVALID' "$Name must be a canonical UTC timestamp" $Value
    }
    return $parsed.ToUniversalTime()
}

function Add-CcodCoordinatorMilliseconds {
    param([string]$Value,[int]$Milliseconds)
    return (ConvertTo-CcodCoordinatorUtc $Value 'timestamp').AddMilliseconds($Milliseconds).ToString('o',[Globalization.CultureInfo]::InvariantCulture)
}

function New-CcodLifecycleStepResult {
    param([string]$Kind,[string]$NextPhase,[string]$WorkerAction,[AllowNull()][string]$DeadlineUtc,[AllowNull()][string]$ErrorCode)
    if($script:CcodLifecycleCoordinatorActions -cnotcontains $WorkerAction){Throw-CcodLifecycleCoordinatorError 'CCOD_LIFECYCLE_COORDINATOR_INVALID' 'Lifecycle worker action is invalid' $WorkerAction}
    return [pscustomobject][ordered]@{kind=$Kind;nextPhase=$NextPhase;workerAction=$WorkerAction;deadlineUtc=$DeadlineUtc;errorCode=$ErrorCode}
}

function Get-CcodLifecycleStep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Request,
        [Parameter(Mandatory)][string]$Observation,
        [Parameter(Mandatory)][string]$NowUtc
    )
    Assert-CcodCoordinatorRequest $Request
    $now=ConvertTo-CcodCoordinatorUtc $NowUtc 'NowUtc'
    if($script:CcodLifecycleCoordinatorObservations -cnotcontains $Observation){Throw-CcodLifecycleCoordinatorError 'CCOD_LIFECYCLE_COORDINATOR_INVALID' 'Lifecycle observation is invalid' $Observation}
    if($script:CcodLifecycleCoordinatorTerminal -ccontains $Request.phase){return New-CcodLifecycleStepResult Terminal $Request.phase None $null $Request.error}

    if($Request.kind -ceq 'CheckAndRepair' -and $Request.phase -ceq 'Requested' -and $Observation -ceq 'RemoteVerified'){
        return New-CcodLifecycleStepResult Completed CancelledBeforeClose None $null $null
    }
    if($Request.kind -ceq 'SafeExit' -and $Request.phase -ceq 'Requested' -and @('Ordinary','NoCodex') -ccontains $Observation){
        return New-CcodLifecycleStepResult Completed CancelledBeforeClose None $null $null
    }

    switch($Request.phase){
        'Requested' { return New-CcodLifecycleStepResult Operation CloseRequested Close $null $null }
        'CloseRequested' {
            if($Observation -ceq 'CloseFailed' -or $Observation -ceq 'Error'){return New-CcodLifecycleStepResult Failed CloseFailed None $null $(if($Request.error){$Request.error}else{'CCOD_CLOSE_FAILED'})}
            if(@('Closed','NoCodex','Ordinary') -ccontains $Observation){return New-CcodLifecycleStepResult Progress CloseConfirmed None $null $null}
            return New-CcodLifecycleStepResult Operation CloseRequested Close $null $null
        }
        'CloseConfirmed' {
            if($Observation -ceq 'Ordinary'){
                if($Request.kind -ceq 'SafeExit'){return New-CcodLifecycleStepResult Progress RepairRequested None $null $null}
                return New-CcodLifecycleStepResult Operation RepairRequested Apply $null $null
            }
            $deadline=$now.AddMilliseconds($script:CcodImmediateLaunchTimeoutMilliseconds).ToString('o',[Globalization.CultureInfo]::InvariantCulture)
            return New-CcodLifecycleStepResult Operation OrdinaryLaunchRequested RequestOrdinaryLaunch $deadline $null
        }
        'OrdinaryLaunchRequested' {
            if($Observation -ceq 'Ordinary'){return New-CcodLifecycleStepResult Progress OrdinaryObserved None $null $null}
            if($Observation -ceq 'LaunchRequested'){
                $base=if($null -eq $Request.launchRequestedAtUtc){$NowUtc}else{$Request.launchRequestedAtUtc}
                return New-CcodLifecycleStepResult Waiting OrdinaryLaunchRequested ObserveOrdinary (Add-CcodCoordinatorMilliseconds $base $script:CcodImmediateLaunchTimeoutMilliseconds) $null
            }
            if($Request.automaticLaunchAttempts -lt $script:CcodMaximumAutomaticLaunchAttempts){
                $deadline=$now.AddMilliseconds($script:CcodImmediateLaunchTimeoutMilliseconds).ToString('o',[Globalization.CultureInfo]::InvariantCulture)
                return New-CcodLifecycleStepResult Operation OrdinaryLaunchRequested RequestOrdinaryLaunch $deadline $null
            }
            $expires=$Request.manualLaunchExpiresAtUtc
            if($null -eq $expires){
                $base=if($null -eq $Request.launchRequestedAtUtc){$NowUtc}else{$Request.launchRequestedAtUtc}
                $expires=Add-CcodCoordinatorMilliseconds $base $script:CcodManualLaunchWindowMilliseconds
            }
            if($now -ge (ConvertTo-CcodCoordinatorUtc $expires 'manualLaunchExpiresAtUtc')){return New-CcodLifecycleStepResult Failed LaunchWindowExpired None $null CODEX_LAUNCH_WINDOW_EXPIRED}
            return New-CcodLifecycleStepResult Waiting WaitingForManualLaunch ObserveOrdinary $expires $null
        }
        'WaitingForManualLaunch' {
            if($Observation -ceq 'Ordinary'){return New-CcodLifecycleStepResult Progress OrdinaryObserved None $null $null}
            $expires=$Request.manualLaunchExpiresAtUtc
            if($null -eq $expires){Throw-CcodLifecycleCoordinatorError 'CCOD_LIFECYCLE_COORDINATOR_INVALID' 'Manual launch phase requires an expiry' $Request}
            if($now -ge (ConvertTo-CcodCoordinatorUtc $expires 'manualLaunchExpiresAtUtc')){return New-CcodLifecycleStepResult Failed LaunchWindowExpired None $null CODEX_LAUNCH_WINDOW_EXPIRED}
            return New-CcodLifecycleStepResult Waiting WaitingForManualLaunch ObserveOrdinary $expires $null
        }
        'OrdinaryObserved' {
            if($Request.kind -ceq 'SafeExit'){return New-CcodLifecycleStepResult Progress RepairRequested None $null $null}
            return New-CcodLifecycleStepResult Operation RepairRequested Apply $null $null
        }
        'RepairRequested' {
            if($Request.kind -ceq 'SafeExit'){return New-CcodLifecycleStepResult Progress RemoteVerified None $null $null}
            if($Observation -ceq 'RemoteVerified'){return New-CcodLifecycleStepResult Progress RemoteVerified None $null $null}
            if($Observation -ceq 'ApplyFailed'){return New-CcodLifecycleStepResult Failed RepairFailed None $null $(if($Request.error){$Request.error}else{'CCOD_REPAIR_FAILED'})}
            if(@('VerificationFailed','Error') -ccontains $Observation){return New-CcodLifecycleStepResult Failed VerificationFailed None $null $(if($Request.error){$Request.error}else{'CCOD_VERIFICATION_FAILED'})}
            return New-CcodLifecycleStepResult Operation RepairRequested VerifyRemote $null $null
        }
        'RemoteVerified' { return New-CcodLifecycleStepResult Completed Completed None $null $null }
        default { Throw-CcodLifecycleCoordinatorError 'CCOD_LIFECYCLE_COORDINATOR_INVALID' 'Lifecycle phase is unsupported' $Request.phase }
    }
}

function Assert-CcodCoordinatorWorkerResult {
    param($Request,$Result)
    if($null -eq $Result -or $Result -isnot [pscustomobject]){Throw-CcodLifecycleCoordinatorError 'CCOD_LIFECYCLE_WORKER_RESULT_INVALID' 'Lifecycle worker result must be an exact object' $Result}
    $actual=@($Result.PSObject.Properties.Name)
    if(($actual -join "`0") -cne ($script:CcodLifecycleWorkerResultFields -join "`0") -or $Result.schemaVersion -isnot [int] -or $Result.schemaVersion -ne 1 -or
        $Result.transactionId -isnot [string] -or $Result.transactionId -cne $Request.transactionId -or $Result.action -isnot [string] -or
        $script:CcodLifecycleCoordinatorActions -cnotcontains $Result.action -or $Result.action -ceq 'None' -or $Result.ok -isnot [bool] -or
        $Result.outcome -isnot [string] -or $Result.observation -isnot [string] -or $script:CcodLifecycleCoordinatorObservations -cnotcontains $Result.observation){
        Throw-CcodLifecycleCoordinatorError 'CCOD_LIFECYCLE_WORKER_RESULT_INVALID' 'Lifecycle worker result is invalid or uncorrelated' $Result
    }
    if($Result.ok){if($null -ne $Result.error){Throw-CcodLifecycleCoordinatorError 'CCOD_LIFECYCLE_WORKER_RESULT_INVALID' 'Successful lifecycle result cannot contain an error' $Result}}
    else{
        if($null -eq $Result.error -or $Result.error -isnot [pscustomobject] -or (@($Result.error.PSObject.Properties.Name)-join ',') -cne 'code,stage,message' -or
            $Result.error.code -isnot [string] -or $Result.error.code -cnotmatch '^[A-Z][A-Z0-9_]{0,127}$'){
            Throw-CcodLifecycleCoordinatorError 'CCOD_LIFECYCLE_WORKER_RESULT_INVALID' 'Failed lifecycle result requires one stable error' $Result
        }
    }
}

function Copy-CcodCoordinatorRequest {
    param($Request)
    return ($Request|ConvertTo-Json -Depth 16|ConvertFrom-Json)
}

function Reduce-CcodLifecycleWorkerResult {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Request,[Parameter(Mandatory)]$Result,[Parameter(Mandatory)][string]$NowUtc)
    Assert-CcodCoordinatorRequest $Request
    [void](ConvertTo-CcodCoordinatorUtc $NowUtc 'NowUtc')
    Assert-CcodCoordinatorWorkerResult $Request $Result
    $next=Copy-CcodCoordinatorRequest $Request
    $next.updatedAtUtc=$NowUtc
    if(-not $Result.ok){
        $next.error=$Result.error.code
        switch($Result.action){
            'Close'{$next.phase='CloseFailed'}
            'RequestOrdinaryLaunch'{$next.phase='OrdinaryLaunchFailed'}
            'ObserveOrdinary'{$next.phase=if($Request.phase -ceq 'WaitingForManualLaunch'){'LaunchWindowExpired'}else{'OrdinaryObservationTimedOut'}}
            'Apply'{$next.phase='RepairFailed'}
            default{$next.phase='VerificationFailed'}
        }
        return $next
    }
    $next.error=$null
    switch($Result.action){
        'Inspect'{if($Result.observation -ceq 'RemoteVerified'){$next.phase='CancelledBeforeClose'}}
        'Close'{$next.phase='CloseConfirmed'}
        'RequestOrdinaryLaunch'{
            $next.phase='OrdinaryLaunchRequested';$next.automaticLaunchAttempts=[int]$Request.automaticLaunchAttempts+1
            if($null -eq $Request.launchRequestedAtUtc){$next.launchRequestedAtUtc=$NowUtc;$next.manualLaunchExpiresAtUtc=Add-CcodCoordinatorMilliseconds $NowUtc $script:CcodManualLaunchWindowMilliseconds}
        }
        'ObserveOrdinary'{if($Result.observation -ceq 'Ordinary'){$next.phase='OrdinaryObserved'}}
        'Apply'{$next.phase='RepairRequested'}
        'VerifyRemote'{if($Result.observation -ceq 'RemoteVerified'){$next.phase='RemoteVerified'}}
    }
    Assert-CcodCoordinatorRequest $next
    return $next
}

Export-ModuleMember -Function Get-CcodLifecycleStep,Reduce-CcodLifecycleWorkerResult
