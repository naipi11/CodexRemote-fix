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
        if([UInt64]$Request.automaticLaunchAttempts -gt [UInt64]$script:CcodMaximumAutomaticLaunchAttempts){throw 'automaticLaunchAttempts exceeds the lifecycle policy'}
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
    param([string]$Kind,[AllowNull()]$NextPhase,[string]$WorkerAction,[AllowNull()]$DeadlineUtc,[AllowNull()]$ErrorCode)
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
    if($script:CcodLifecycleCoordinatorTerminal -ccontains $Request.phase){return New-CcodLifecycleStepResult Terminal $null None $null $Request.error}

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
            return New-CcodLifecycleStepResult Operation $null Close $null $null
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
                return New-CcodLifecycleStepResult Waiting $null ObserveOrdinary ($now.AddMilliseconds($script:CcodImmediateLaunchTimeoutMilliseconds).ToString('o',[Globalization.CultureInfo]::InvariantCulture)) $null
            }
            if($Request.automaticLaunchAttempts -lt $script:CcodMaximumAutomaticLaunchAttempts){
                $deadline=$now.AddMilliseconds($script:CcodImmediateLaunchTimeoutMilliseconds).ToString('o',[Globalization.CultureInfo]::InvariantCulture)
                return New-CcodLifecycleStepResult Operation $null RequestOrdinaryLaunch $deadline $null
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
            return New-CcodLifecycleStepResult Waiting $null ObserveOrdinary $expires $null
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
            return New-CcodLifecycleStepResult Operation $null VerifyRemote $null $null
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

function Assert-CcodCoordinatorWorkerResultForPhase {
    param($Request,$Result)
    $allowed=$false
    switch($Request.phase){
        'Requested'{$allowed=$Result.action -ceq 'Inspect'}
        'CloseRequested'{$allowed=$Result.action -ceq 'Close'}
        'OrdinaryLaunchRequested'{$allowed=@('RequestOrdinaryLaunch','ObserveOrdinary') -ccontains $Result.action}
        'WaitingForManualLaunch'{$allowed=$Result.action -ceq 'ObserveOrdinary'}
        'RepairRequested'{$allowed=@('Apply','VerifyRemote') -ccontains $Result.action}
        default{$allowed=$false}
    }
    if(-not $allowed){Throw-CcodLifecycleCoordinatorError 'CCOD_LIFECYCLE_WORKER_RESULT_INVALID' 'Lifecycle worker action is not valid for the current phase' $Result}
    if(-not $Result.ok){
        if($Result.outcome -cne 'Error' -or $Result.observation -cne 'Error'){Throw-CcodLifecycleCoordinatorError 'CCOD_LIFECYCLE_WORKER_RESULT_INVALID' 'Failed lifecycle worker tuple is incompatible' $Result}
        return
    }
    $compatible=switch($Result.action){
        'Inspect'{$Result.outcome -ceq 'Inspected' -and @('RemoteVerified','Special','Ordinary','NoCodex') -ccontains $Result.observation}
        'Close'{$Result.outcome -ceq 'Closed' -and $Result.observation -ceq 'NoCodex'}
        'RequestOrdinaryLaunch'{$Result.outcome -ceq 'LaunchRequested' -and $Result.observation -ceq 'NoCodex' -and [UInt64]$Request.automaticLaunchAttempts -lt [UInt64]$script:CcodMaximumAutomaticLaunchAttempts}
        'ObserveOrdinary'{($Result.outcome -ceq 'OrdinaryObserved' -and $Result.observation -ceq 'Ordinary') -or ($Result.outcome -ceq 'ObservationTimedOut' -and $Result.observation -ceq 'ObservationTimedOut')}
        'Apply'{@('Activated','NoAction') -ccontains $Result.outcome -and $Result.observation -ceq 'Special'}
        'VerifyRemote'{$Result.outcome -ceq 'Inspected' -and @('RemoteVerified','Special','Ordinary','NoCodex') -ccontains $Result.observation}
        default{$false}
    }
    if(-not $compatible){Throw-CcodLifecycleCoordinatorError 'CCOD_LIFECYCLE_WORKER_RESULT_INVALID' 'Lifecycle worker outcome and observation are incompatible with the current operation' $Result}
}

function Copy-CcodCoordinatorRequest {
    param($Request)
    return ($Request|ConvertTo-Json -Depth 16|ConvertFrom-Json)
}

function New-CcodCoordinatorReducedRequest {
    param($Request,[AllowNull()]$NextPhase,[string]$NowUtc)
    if($null -ne $NextPhase){return Move-CcodLifecyclePhase -Request $Request -NextPhase $NextPhase -NowUtc $NowUtc}
    $clone=Copy-CcodCoordinatorRequest $Request;$clone.updatedAtUtc=$NowUtc;return $clone
}

function Reduce-CcodLifecycleWorkerResult {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Request,[Parameter(Mandatory)]$Result,[Parameter(Mandatory)][string]$NowUtc)
    Assert-CcodCoordinatorRequest $Request
    [void](ConvertTo-CcodCoordinatorUtc $NowUtc 'NowUtc')
    Assert-CcodCoordinatorWorkerResult $Request $Result
    Assert-CcodCoordinatorWorkerResultForPhase $Request $Result
    if(-not $Result.ok){
        $failurePhase=switch($Result.action){
            'Inspect'{'CancelledBeforeClose'}
            'Close'{'CloseFailed'}
            'RequestOrdinaryLaunch'{'OrdinaryLaunchFailed'}
            'ObserveOrdinary'{$(if($Request.phase -ceq 'WaitingForManualLaunch'){'LaunchWindowExpired'}else{'OrdinaryObservationTimedOut'})}
            'Apply'{'RepairFailed'}
            default{'VerificationFailed'}
        }
        $next=New-CcodCoordinatorReducedRequest $Request $failurePhase $NowUtc;$next.error=$Result.error.code
        Assert-CcodCoordinatorRequest $next
        return $next
    }
    $nextPhase=$null;$stableError=$null
    switch($Result.action){
        'Inspect'{if($Result.observation -ceq 'RemoteVerified'){$nextPhase='CancelledBeforeClose'}}
        'Close'{$nextPhase='CloseConfirmed'}
        'RequestOrdinaryLaunch'{
            $nextPhase=$null
        }
        'ObserveOrdinary'{if($Result.observation -ceq 'Ordinary'){$nextPhase='OrdinaryObserved'}}
        'Apply'{$nextPhase=$null}
        'VerifyRemote'{if($Result.observation -ceq 'RemoteVerified'){$nextPhase='RemoteVerified'}else{$nextPhase='VerificationFailed';$stableError='CCOD_VERIFICATION_FAILED'}}
    }
    $next=New-CcodCoordinatorReducedRequest $Request $nextPhase $NowUtc
    $next.error=$stableError
    if($Result.action -ceq 'RequestOrdinaryLaunch'){
        $next.automaticLaunchAttempts=[int]$Request.automaticLaunchAttempts+1
        if($next.automaticLaunchAttempts -gt $script:CcodMaximumAutomaticLaunchAttempts){Throw-CcodLifecycleCoordinatorError 'CCOD_LIFECYCLE_WORKER_RESULT_INVALID' 'Lifecycle automatic launch attempts would overflow' $Result}
        if($null -eq $Request.launchRequestedAtUtc){$next.launchRequestedAtUtc=$NowUtc;$next.manualLaunchExpiresAtUtc=Add-CcodCoordinatorMilliseconds $NowUtc $script:CcodManualLaunchWindowMilliseconds}
    }
    Assert-CcodCoordinatorRequest $next
    return $next
}

Export-ModuleMember -Function Get-CcodLifecycleStep,Reduce-CcodLifecycleWorkerResult
