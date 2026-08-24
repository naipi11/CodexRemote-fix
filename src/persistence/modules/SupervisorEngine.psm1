Set-StrictMode -Version Latest

$script:CcodSupervisorContextFields = @(
    'AutomationEnabled','CandidateCompatibleOptIn','AutomaticCandidateTrialsAllowed','StateDamageBlocksActions',
    'ControllerRunning','ActiveTransaction','CurrentUserSid','CurrentSessionId','RuntimeId','PackageFullName',
    'AppAsarSha256','Classification','VerifiedPackages','Ordinary','Special','AttemptKeys','RecoveryIgnoreKeys','SuppressionKeys'
)
$script:CcodProcessSnapshotFields = @(
    'Pid','CreationTimeUtc','SessionId','UserSid','Path','PackageFamilyName','CommandLine','ParentPid',
    'IsTopLevel','Mode','RendererPort','MainPort'
)
$script:CcodTransitionFields = @(
    'transactionId','stage','sourcePid','sourceCreationTimeUtc','packageFullName','appAsarSha256','runtimeId',
    'mainPort','rendererPort','specialPid','specialCreationTimeUtc','recoveryPid','recoveryCreationTimeUtc',
    'createdAtUtc','updatedAtUtc'
)
$script:CcodControllerResultFields = @(
    'schemaVersion','action','ok','outcome','safeState','stage','transactionId','package','source','special',
    'probes','recovery','error','logFile'
)
$script:CcodStableControllerErrorCodes = @(
    'BRIDGE_PROOF_INCOMPLETE',
    'CCOD_ATOMIC_NAME_EXHAUSTED','CCOD_ATOMIC_NAME_INVALID','CCOD_ATOMIC_RECOVERY_FAILED','CCOD_ATOMIC_REPLACE_FAILED',
    'CCOD_BRIDGE_JSON_INVALID','CCOD_CLOCK_INVALID','CCOD_CLOSE_UNPROVEN','CCOD_CODEX_HOME_INVALID',
    'CCOD_LIVE_PROBE_INVALID','CCOD_LIVE_PROBE_MISMATCH','CCOD_LIVE_PROBE_REQUIRED','CCOD_LOG_ENTRY_TOO_LARGE',
    'CCOD_MAIN_INSPECTOR_OPEN','CCOD_NODE_CANDIDATE_INVALID','CCOD_PATH_MISSING','CCOD_PATH_OUTSIDE_ROOT','CCOD_PATHS_INVALID',
    'CCOD_PORT_UNAVAILABLE','CCOD_RECOVERY_UNPROVEN','CCOD_REPARSE_PATH','CCOD_REPLAY_INPUT_INVALID','CCOD_REQUEST_INVALID',
    'CCOD_SCHEMA_UNSUPPORTED','CCOD_SESSION_FAILED','CCOD_SETTINGS_INVALID','CCOD_SOURCE_AMBIGUOUS','CCOD_SOURCE_CHANGED',
    'CCOD_SPECIAL_START_FAILED','CCOD_STALE_PACKAGE_AMBIGUOUS','CCOD_STALE_PACKAGE_UNPROVEN','CCOD_STATE_ALREADY_INITIALIZED','CCOD_STATE_BLOCKED','CCOD_STATE_MALFORMED','CCOD_STATE_MISSING','CCOD_STATE_STALE_PACKAGE',
    'CCOD_STATUS_INVALID','CCOD_STOP_UNCONFIRMED','CCOD_TRANSITION_ARCHIVE_FAILED','CCOD_TRANSITION_COMPLETION_INVALID',
    'CCOD_TRANSITION_CONFLICT','CCOD_TRANSITION_INVALID','CCOD_TRANSITION_RECEIPT_INVALID','CCOD_TRANSITION_STAGE_INVALID',
    'CCOD_VERIFIED_PACKAGES_INVALID'
)

function Throw-CcodSupervisorError {
    param([string]$Code, [string]$Message, $Target)
    $exception = [InvalidOperationException]::new($Message)
    $record = [Management.Automation.ErrorRecord]::new(
        $exception,
        $Code,
        [Management.Automation.ErrorCategory]::InvalidData,
        $Target
    )
    throw $record
}

function Get-CcodObjectPropertyNames {
    param($Value)
    if ($Value -is [Collections.IDictionary]) {
        foreach ($key in $Value.Keys) { [string]$key }
        return
    }
    foreach ($property in $Value.PSObject.Properties) { $property.Name }
}

function Get-CcodObjectPropertyValue {
    param($Value, [string]$Name)
    if ($Value -is [Collections.IDictionary]) {
        foreach ($key in $Value.Keys) {
            if ([string]$key -ceq $Name) { return ,$Value[$key] }
        }
        return $null
    }
    foreach ($property in $Value.PSObject.Properties) {
        if ($property.Name -ceq $Name) { return ,$property.Value }
    }
    return $null
}

function Assert-CcodExactObject {
    param($Value, [string[]]$Expected, [string]$Code, [string]$Kind)
    if ($null -eq $Value -or ($Value -isnot [pscustomobject] -and $Value -isnot [Collections.IDictionary])) {
        Throw-CcodSupervisorError $Code "$Kind must be an exact object" $Value
    }
    $actual = @(Get-CcodObjectPropertyNames $Value)
    if ($actual.Count -ne $Expected.Count) {
        Throw-CcodSupervisorError $Code "$Kind fields are invalid" $Value
    }
    foreach ($name in $Expected) {
        if ($actual -cnotcontains $name) { Throw-CcodSupervisorError $Code "$Kind fields are invalid" $Value }
    }
    foreach ($name in $actual) {
        if ($Expected -cnotcontains $name) { Throw-CcodSupervisorError $Code "$Kind fields are invalid" $Value }
    }
}

function Test-CcodCanonicalUtc {
    param($Value)
    if ($Value -isnot [string]) { return $false }
    $parsed = [DateTime]::MinValue
    return [DateTime]::TryParseExact(
        $Value,
        'o',
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind,
        [ref]$parsed
    ) -and $parsed.Kind -eq [DateTimeKind]::Utc -and
        $parsed.ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture) -ceq $Value
}

function Test-CcodCanonicalGuid {
    param($Value)
    if ($Value -isnot [string]) { return $false }
    $parsed = [guid]::Empty
    return [guid]::TryParseExact($Value,'D',[ref]$parsed) -and $parsed.ToString('D') -ceq $Value
}

function Test-CcodExactInt32 {
    param($Value, [int]$Minimum)
    return $Value -is [int] -and $Value -ge $Minimum
}

function Test-CcodTask5Integer {
    param($Value, [long]$Minimum, [long]$Maximum)
    return ($Value -is [int] -or $Value -is [long]) -and $Value -ge $Minimum -and $Value -le $Maximum
}

function Assert-CcodProcessSnapshot {
    param($Snapshot, [string]$Code)
    Assert-CcodExactObject $Snapshot $script:CcodProcessSnapshotFields $Code 'Process snapshot'
    if (-not (Test-CcodExactInt32 $Snapshot.Pid 1) -or
        -not (Test-CcodCanonicalUtc $Snapshot.CreationTimeUtc) -or
        -not (Test-CcodExactInt32 $Snapshot.SessionId 0) -or
        $Snapshot.UserSid -isnot [string] -or [string]::IsNullOrWhiteSpace($Snapshot.UserSid) -or
        $Snapshot.Path -isnot [string] -or [string]::IsNullOrWhiteSpace($Snapshot.Path) -or
        $Snapshot.PackageFamilyName -isnot [string] -or [string]::IsNullOrWhiteSpace($Snapshot.PackageFamilyName) -or
        ($null -ne $Snapshot.CommandLine -and $Snapshot.CommandLine -isnot [string]) -or
        $Snapshot.IsTopLevel -isnot [bool] -or
        $Snapshot.Mode -isnot [string] -or @('Ordinary','Special','Unrelated') -cnotcontains $Snapshot.Mode) {
        Throw-CcodSupervisorError $Code 'Process snapshot scalar fields are invalid' $Snapshot
    }
    if ($null -ne $Snapshot.ParentPid -and -not (Test-CcodExactInt32 $Snapshot.ParentPid 0)) {
        Throw-CcodSupervisorError $Code 'Process snapshot parent identity is invalid' $Snapshot
    }
    foreach ($name in @('RendererPort','MainPort')) {
        $port = Get-CcodObjectPropertyValue $Snapshot $name
        if ($null -ne $port -and (-not (Test-CcodExactInt32 $port 1) -or $port -gt 65535)) {
            Throw-CcodSupervisorError $Code 'Process snapshot port is invalid' $Snapshot
        }
    }
}

function Assert-CcodNullableTransitionIdentity {
    param($Transition, [string]$PidName, [string]$TimeName, [string]$Code)
    $processIdValue = Get-CcodObjectPropertyValue $Transition $PidName
    $time = Get-CcodObjectPropertyValue $Transition $TimeName
    if ($null -eq $processIdValue -and $null -eq $time) { return }
    if ($null -eq $processIdValue -or $null -eq $time -or
        -not (Test-CcodTask5Integer $processIdValue 1 ([int]::MaxValue)) -or
        -not (Test-CcodCanonicalUtc $time)) {
        Throw-CcodSupervisorError $Code 'Transition process identity is invalid' $Transition
    }
}

function Assert-CcodActiveTransaction {
    param($Transition, [string]$Code)
    Assert-CcodExactObject $Transition $script:CcodTransitionFields $Code 'Active transaction'
    if (-not (Test-CcodCanonicalGuid $Transition.transactionId) -or
        $Transition.stage -isnot [string] -or
        @('IntentWritten','StopRequested','OrdinaryStopped','SpecialLaunchRequested','SpecialStarted','Validated','RecoveryLaunchRequested','Recovered','CloseRequested','Closed') -cnotcontains $Transition.stage -or
        $Transition.packageFullName -isnot [string] -or [string]::IsNullOrWhiteSpace($Transition.packageFullName) -or
        $Transition.appAsarSha256 -isnot [string] -or $Transition.appAsarSha256 -cnotmatch '^[0-9a-f]{64}$' -or
        $Transition.runtimeId -isnot [string] -or [string]::IsNullOrWhiteSpace($Transition.runtimeId) -or
        -not (Test-CcodCanonicalUtc $Transition.createdAtUtc) -or
        -not (Test-CcodCanonicalUtc $Transition.updatedAtUtc)) {
        Throw-CcodSupervisorError $Code 'Active transaction scalar fields are invalid' $Transition
    }
    $created = [DateTime]::ParseExact($Transition.createdAtUtc,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
    $updated = [DateTime]::ParseExact($Transition.updatedAtUtc,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
    if ($updated -lt $created) { Throw-CcodSupervisorError $Code 'Active transaction timestamps are contradictory' $Transition }
    Assert-CcodNullableTransitionIdentity $Transition 'sourcePid' 'sourceCreationTimeUtc' $Code
    Assert-CcodNullableTransitionIdentity $Transition 'specialPid' 'specialCreationTimeUtc' $Code
    Assert-CcodNullableTransitionIdentity $Transition 'recoveryPid' 'recoveryCreationTimeUtc' $Code
    $hasMain = $null -ne $Transition.mainPort
    $hasRenderer = $null -ne $Transition.rendererPort
    if ($hasMain -ne $hasRenderer) { Throw-CcodSupervisorError $Code 'Active transaction ports are not paired' $Transition }
    if ($hasMain -and (
        -not (Test-CcodTask5Integer $Transition.mainPort 1 65535) -or
        -not (Test-CcodTask5Integer $Transition.rendererPort 1 65535) -or
        $Transition.mainPort -eq $Transition.rendererPort)) {
        Throw-CcodSupervisorError $Code 'Active transaction ports are invalid' $Transition
    }
    $hasSource = $null -ne $Transition.sourcePid
    $hasSpecial = $null -ne $Transition.specialPid
    $hasRecovery = $null -ne $Transition.recoveryPid
    if ($Transition.stage -ceq 'StopRequested' -and -not $hasSource) {
        Throw-CcodSupervisorError $Code 'StopRequested requires a source identity' $Transition
    }
    if (@('IntentWritten','StopRequested','OrdinaryStopped','SpecialLaunchRequested') -ccontains $Transition.stage -and $hasSpecial) {
        Throw-CcodSupervisorError $Code 'Special identity exists before its durable stage' $Transition
    }
    if (@('SpecialStarted','Validated') -ccontains $Transition.stage -and (-not $hasSpecial -or -not $hasMain)) {
        Throw-CcodSupervisorError $Code 'Special stage lacks durable identity or ports' $Transition
    }
    if ($Transition.stage -ceq 'SpecialLaunchRequested' -and -not $hasMain) {
        Throw-CcodSupervisorError $Code 'Special launch stage lacks durable ports' $Transition
    }
    if ($hasSpecial -and -not $hasMain) {
        Throw-CcodSupervisorError $Code 'Special identity lacks its durable ports' $Transition
    }
    if ($Transition.stage -ceq 'Recovered' -and -not $hasRecovery) {
        Throw-CcodSupervisorError $Code 'Recovered stage lacks recovery identity' $Transition
    }
    if ($Transition.stage -cne 'Recovered' -and $hasRecovery) {
        Throw-CcodSupervisorError $Code 'Recovery identity exists before Recovered' $Transition
    }
    if (@('CloseRequested','Closed') -ccontains $Transition.stage) {
        if ($hasSource -eq $hasSpecial -or $hasRecovery -or ($hasSource -and $hasMain) -or ($hasSpecial -and -not $hasMain)) {
            Throw-CcodSupervisorError $Code 'Close transition identity is contradictory' $Transition
        }
    }
}

function Assert-CcodVerifiedPackages {
    param($Store, [string]$Code)
    Assert-CcodExactObject $Store @('schemaVersion','packages') $Code 'Verified package store'
    if (($Store.schemaVersion -isnot [int] -and $Store.schemaVersion -isnot [long]) -or $Store.schemaVersion -ne 1) {
        Throw-CcodSupervisorError $Code 'Verified package schema is invalid' $Store
    }
    $packages = Get-CcodObjectPropertyValue $Store 'packages'
    if ($null -eq $packages -or ($packages -isnot [pscustomobject] -and $packages -isnot [Collections.IDictionary])) {
        Throw-CcodSupervisorError $Code 'Verified package map is invalid' $Store
    }
    $keys = @(Get-CcodObjectPropertyNames $packages)
    foreach ($key in $keys) {
        if ($key -isnot [string] -or [string]::IsNullOrWhiteSpace($key)) {
            Throw-CcodSupervisorError $Code 'Verified package key is invalid' $packages
        }
        $record = Get-CcodObjectPropertyValue $packages $key
        Assert-CcodExactObject $record @('packageFullName','packageVersion','appAsarSha256','runtimeId','staticClassification','dynamicOutcome','probeState','confirmedAtUtc') $Code 'Verified package record'
        foreach ($name in @('packageFullName','packageVersion','appAsarSha256','runtimeId','staticClassification','dynamicOutcome','probeState')) {
            $value = Get-CcodObjectPropertyValue $record $name
            if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value)) {
                Throw-CcodSupervisorError $Code 'Verified package record string is invalid' $record
            }
        }
        if ($record.appAsarSha256 -cnotmatch '^[0-9a-f]{64}$' -or
            @('CandidateCompatible','NativeModulePresent','UnknownOrIncompatible','VerifiedCompatible') -cnotcontains $record.staticClassification -or
            @('Succeeded','Failed') -cnotcontains $record.dynamicOutcome -or
            @('Valid','Invalid','NotRun') -cnotcontains $record.probeState -or
            -not (Test-CcodCanonicalUtc $record.confirmedAtUtc)) {
            Throw-CcodSupervisorError $Code 'Verified package record enum or timestamp is invalid' $record
        }
        if (($record.dynamicOutcome -ceq 'Succeeded' -and $record.probeState -cne 'Valid') -or
            ($record.dynamicOutcome -ceq 'Failed' -and @('Invalid','NotRun') -cnotcontains $record.probeState) -or
            (@('NativeModulePresent','UnknownOrIncompatible') -ccontains $record.staticClassification -and $record.dynamicOutcome -ceq 'Succeeded')) {
            Throw-CcodSupervisorError $Code 'Verified package record evidence is contradictory' $record
        }
        $expectedKey = '{0}|{1}|{2}' -f $record.packageFullName,$record.appAsarSha256,$record.runtimeId
        if ($key -cne $expectedKey) { Throw-CcodSupervisorError $Code 'Verified package key does not match its record' $record }
    }
}

function Find-CcodVerifiedRecord {
    param($Store, [string]$Key)
    $packages = Get-CcodObjectPropertyValue $Store 'packages'
    foreach ($candidate in @(Get-CcodObjectPropertyNames $packages)) {
        if ($candidate -ceq $Key) { return Get-CcodObjectPropertyValue $packages $candidate }
    }
    return $null
}

function Test-CcodExactDictionaryMembership {
    param([Collections.IDictionary]$Dictionary, [string]$Key)
    foreach ($candidate in $Dictionary.Keys) {
        if ($candidate -is [string] -and $candidate -ceq $Key) { return $true }
    }
    return $false
}

function Test-CcodRecoveryMembership {
    param([Collections.IDictionary]$Dictionary, [string]$AttemptKey)
    $prefix = $AttemptKey + '|'
    foreach ($candidate in $Dictionary.Keys) {
        if ($candidate -isnot [string] -or -not $candidate.StartsWith($prefix,[StringComparison]::Ordinal)) { continue }
        $suffix = $candidate.Substring($prefix.Length)
        if (Test-CcodCanonicalGuid $suffix) { return $true }
    }
    return $false
}

function Assert-CcodSupervisorContext {
    param($Context)
    $code = 'CCOD_SUPERVISOR_CONTEXT_INVALID'
    Assert-CcodExactObject $Context $script:CcodSupervisorContextFields $code 'Supervisor context'
    foreach ($name in @('AutomationEnabled','CandidateCompatibleOptIn','AutomaticCandidateTrialsAllowed','StateDamageBlocksActions','ControllerRunning')) {
        if ((Get-CcodObjectPropertyValue $Context $name) -isnot [bool]) {
            Throw-CcodSupervisorError $code 'Supervisor context Boolean is invalid' $Context
        }
    }
    if ($Context.CurrentUserSid -isnot [string] -or [string]::IsNullOrWhiteSpace($Context.CurrentUserSid) -or
        -not (Test-CcodExactInt32 $Context.CurrentSessionId 0) -or
        $Context.RuntimeId -isnot [string] -or [string]::IsNullOrWhiteSpace($Context.RuntimeId)) {
        Throw-CcodSupervisorError $code 'Supervisor identity is invalid' $Context
    }
    $hasPackage = $null -ne $Context.PackageFullName
    $hasHash = $null -ne $Context.AppAsarSha256
    if ($hasPackage -ne $hasHash -or
        ($hasPackage -and ($Context.PackageFullName -isnot [string] -or [string]::IsNullOrWhiteSpace($Context.PackageFullName) -or
            $Context.AppAsarSha256 -isnot [string] -or $Context.AppAsarSha256 -cnotmatch '^[0-9a-f]{64}$'))) {
        Throw-CcodSupervisorError $code 'Supervisor package tuple is invalid' $Context
    }
    if ($null -ne $Context.Classification -and $Context.Classification -isnot [string]) {
        Throw-CcodSupervisorError $code 'Static classification is invalid' $Context
    }
    $classificationBlank = $null -eq $Context.Classification -or [string]::IsNullOrWhiteSpace($Context.Classification)
    if (-not $classificationBlank -and @('CandidateCompatible','NativeModulePresent','UnknownOrIncompatible') -cnotcontains $Context.Classification) {
        Throw-CcodSupervisorError $code 'Static classification is invalid' $Context
    }
    if ($classificationBlank -ne (-not $hasPackage)) {
        Throw-CcodSupervisorError $code 'Static classification and package tuple are inconsistent' $Context
    }
    if ($null -eq $Context.VerifiedPackages) {
        if (-not $Context.StateDamageBlocksActions) {
            Throw-CcodSupervisorError $code 'Healthy state requires verified package store' $Context
        }
    } else {
        Assert-CcodVerifiedPackages $Context.VerifiedPackages $code
    }
    if ($null -ne $Context.ActiveTransaction) { Assert-CcodActiveTransaction $Context.ActiveTransaction $code }
    foreach ($name in @('Ordinary','Special')) {
        $value = Get-CcodObjectPropertyValue $Context $name
        if ($value -isnot [Array] -or $value.Rank -ne 1) {
            Throw-CcodSupervisorError $code 'Process observations must be arrays' $Context
        }
    }
    foreach ($snapshot in @($Context.Ordinary)) {
        Assert-CcodProcessSnapshot $snapshot $code
        if (-not $snapshot.IsTopLevel -or $snapshot.Mode -cne 'Ordinary' -or $null -ne $snapshot.RendererPort -or $null -ne $snapshot.MainPort) {
            Throw-CcodSupervisorError $code 'Ordinary observations must remain exact ordinary roots' $snapshot
        }
    }
    foreach ($observation in @($Context.Special)) {
        Assert-CcodExactObject $observation @('Snapshot','IdentityValid','ProbeValid') $code 'Special observation'
        if ($observation.IdentityValid -isnot [bool] -or $observation.ProbeValid -isnot [bool]) {
            Throw-CcodSupervisorError $code 'Special evidence flags are invalid' $observation
        }
        Assert-CcodProcessSnapshot $observation.Snapshot $code
    }
    foreach ($name in @('AttemptKeys','RecoveryIgnoreKeys','SuppressionKeys')) {
        if ((Get-CcodObjectPropertyValue $Context $name) -isnot [Collections.IDictionary]) {
            Throw-CcodSupervisorError $code 'Membership collections must be dictionaries' $Context
        }
    }
}

function New-CcodSupervisorDecision {
    param([string]$Action, [string]$Reason, $Target, $AttemptKey, $SuppressionKey, $EffectiveClassification)
    $requiresController = @('RepairRenderer','InspectOrdinary','ApplyOrdinary','ReplayTransition') -ccontains $Action
    return [pscustomobject][ordered]@{
        Action=$Action
        Reason=$Reason
        Target=$Target
        AttemptKey=$AttemptKey
        SuppressionKey=$SuppressionKey
        EffectiveClassification=$EffectiveClassification
        RequiresController=[bool]$requiresController
    }
}

function Get-CcodSupervisorDecision {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)

    Assert-CcodSupervisorContext $Context
    $suppressionKey = $null
    if ($null -ne $Context.PackageFullName) {
        $suppressionKey = '{0}|{1}|{2}' -f $Context.PackageFullName,$Context.AppAsarSha256,$Context.RuntimeId
    }
    $effectiveClassification = $null
    if ($null -ne $Context.Classification -and -not [string]::IsNullOrWhiteSpace($Context.Classification)) {
        $effectiveClassification = $Context.Classification
    }
    $history = $null
    if ($null -ne $suppressionKey -and $null -ne $Context.VerifiedPackages) {
        $history = Find-CcodVerifiedRecord $Context.VerifiedPackages $suppressionKey
    }
    if ($effectiveClassification -ceq 'CandidateCompatible' -and $null -ne $history -and
        $history.packageFullName -ceq $Context.PackageFullName -and
        $history.appAsarSha256 -ceq $Context.AppAsarSha256 -and
        $history.runtimeId -ceq $Context.RuntimeId -and
        $history.dynamicOutcome -ceq 'Succeeded' -and $history.probeState -ceq 'Valid') {
        $effectiveClassification = 'VerifiedCompatible'
    }

    if ($Context.StateDamageBlocksActions) {
        return New-CcodSupervisorDecision 'ShowError' 'StateDamaged' $null $null $suppressionKey $effectiveClassification
    }
    if ($Context.ControllerRunning) {
        return New-CcodSupervisorDecision 'Wait' 'ControllerBusy' $null $null $suppressionKey $effectiveClassification
    }
    if ($null -ne $Context.ActiveTransaction) {
        return New-CcodSupervisorDecision 'ReplayTransition' 'ActiveTransaction' $null $null $suppressionKey $effectiveClassification
    }

    $ordinary = @()
    foreach ($snapshot in @($Context.Ordinary)) {
        if ($snapshot.UserSid -ceq $Context.CurrentUserSid -and $snapshot.SessionId -eq $Context.CurrentSessionId) {
            $ordinary += ,$snapshot
        }
    }
    $special = @()
    foreach ($observation in @($Context.Special)) {
        if ($observation.Snapshot.UserSid -ceq $Context.CurrentUserSid -and
            $observation.Snapshot.SessionId -eq $Context.CurrentSessionId) {
            $special += ,$observation
        }
    }
    $invalidSpecial = $false
    foreach ($observation in $special) {
        if (-not $observation.IdentityValid) { $invalidSpecial = $true }
    }
    if (($ordinary.Count -gt 0 -and $special.Count -gt 0) -or
        $ordinary.Count -gt 1 -or $special.Count -gt 1 -or $invalidSpecial) {
        return New-CcodSupervisorDecision 'ShowError' 'IdentityUncertain' $null $null $suppressionKey $effectiveClassification
    }
    if ($special.Count -eq 1) {
        $target = $special[0].Snapshot
        $attemptKey = '{0}|{1}' -f $target.Pid,$target.CreationTimeUtc
        if ($special[0].ProbeValid) {
            return New-CcodSupervisorDecision 'AdoptSpecial' 'ValidatedSpecial' $target $attemptKey $suppressionKey $effectiveClassification
        }
        return New-CcodSupervisorDecision 'RepairRenderer' 'RendererTargetChanged' $target $attemptKey $suppressionKey $effectiveClassification
    }
    if ($ordinary.Count -eq 0) {
        return New-CcodSupervisorDecision 'Wait' 'NoCodex' $null $null $suppressionKey $effectiveClassification
    }

    $target = $ordinary[0]
    $attemptKey = '{0}|{1}' -f $target.Pid,$target.CreationTimeUtc
    if (Test-CcodRecoveryMembership $Context.RecoveryIgnoreKeys $attemptKey) {
        return New-CcodSupervisorDecision 'KeepOrdinary' 'RecoveryIgnored' $target $attemptKey $suppressionKey $effectiveClassification
    }
    $failedHistory = $null -ne $history -and $history.packageFullName -ceq $Context.PackageFullName -and
        $history.appAsarSha256 -ceq $Context.AppAsarSha256 -and $history.runtimeId -ceq $Context.RuntimeId -and
        $history.dynamicOutcome -ceq 'Failed'
    if (($null -ne $suppressionKey -and (Test-CcodExactDictionaryMembership $Context.SuppressionKeys $suppressionKey)) -or $failedHistory) {
        return New-CcodSupervisorDecision 'KeepOrdinary' 'DynamicSuppressed' $target $attemptKey $suppressionKey $effectiveClassification
    }
    if (Test-CcodExactDictionaryMembership $Context.AttemptKeys $attemptKey) {
        return New-CcodSupervisorDecision 'KeepOrdinary' 'AlreadyAttempted' $target $attemptKey $suppressionKey $effectiveClassification
    }
    if ($null -eq $effectiveClassification) {
        return New-CcodSupervisorDecision 'InspectOrdinary' 'StaticProbeRequired' $target $attemptKey $suppressionKey $effectiveClassification
    }
    if (@('NativeModulePresent','UnknownOrIncompatible') -ccontains $effectiveClassification) {
        return New-CcodSupervisorDecision 'KeepOrdinary' $effectiveClassification $target $attemptKey $suppressionKey $effectiveClassification
    }
    return New-CcodSupervisorDecision 'ApplyOrdinary' 'Compatible' $target $attemptKey $suppressionKey $effectiveClassification
}

function Add-CcodObservedEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$ObservedKeys,
        [Parameter(Mandatory)]$ProcessId,
        [Parameter(Mandatory)]$CreationTimeUtc
    )
    $code = 'CCOD_OBSERVED_EVENT_INVALID'
    if ($ObservedKeys -isnot [Collections.IDictionary] -or
        -not (Test-CcodExactInt32 $ProcessId 1) -or
        -not (Test-CcodCanonicalUtc $CreationTimeUtc)) {
        Throw-CcodSupervisorError $code 'Observed event identity is invalid' $null
    }
    $key = '{0}|{1}' -f $ProcessId,$CreationTimeUtc
    foreach ($candidate in $ObservedKeys.Keys) {
        if ($candidate -isnot [string]) { Throw-CcodSupervisorError $code 'Observed event dictionary key is invalid' $ObservedKeys }
        if ($candidate -ceq $key) { return [bool]$false }
        if ([string]::Equals($candidate,$key,[StringComparison]::OrdinalIgnoreCase)) {
            Throw-CcodSupervisorError $code 'Observed event dictionary has a non-ordinal collision' $ObservedKeys
        }
    }
    if ($ObservedKeys.IsReadOnly -or $ObservedKeys.IsFixedSize) {
        Throw-CcodSupervisorError $code 'Observed event dictionary is not mutable' $ObservedKeys
    }
    try { $ObservedKeys.Add($key,$true) }
    catch { Throw-CcodSupervisorError $code 'Observed event dictionary rejected the exact key' $ObservedKeys }
    return [bool]$true
}

function Assert-CcodControllerIdentity {
    param($Identity, [string]$Kind)
    Assert-CcodExactObject $Identity @('pid','creationTimeUtc') 'CCOD_CONTROLLER_RESULT_INVALID' $Kind
    if (-not (Test-CcodExactInt32 $Identity.pid 1) -or -not (Test-CcodCanonicalUtc $Identity.creationTimeUtc)) {
        Throw-CcodSupervisorError 'CCOD_CONTROLLER_RESULT_INVALID' "$Kind identity is invalid" $Identity
    }
}

function Assert-CcodControllerStaleSource {
    param($Source)
    $names=@('pid','creationTimeUtc','sessionId','userSid','path','packageFamilyName','commandLine','parentPid','isTopLevel','mode','rendererPort','mainPort')
    Assert-CcodExactObject $Source $names 'CCOD_CONTROLLER_RESULT_INVALID' 'Controller stale source'
    if(-not (Test-CcodExactInt32 $Source.pid 1) -or -not (Test-CcodCanonicalUtc $Source.creationTimeUtc) -or
       -not (Test-CcodExactInt32 $Source.sessionId 0) -or $Source.userSid -isnot [string] -or [string]::IsNullOrWhiteSpace($Source.userSid) -or
       $Source.path -isnot [string] -or [string]::IsNullOrWhiteSpace($Source.path) -or
       $Source.packageFamilyName -isnot [string] -or [string]::IsNullOrWhiteSpace($Source.packageFamilyName) -or
       $Source.commandLine -isnot [string] -or [string]::IsNullOrWhiteSpace($Source.commandLine) -or
       ($null -ne $Source.parentPid -and -not (Test-CcodExactInt32 $Source.parentPid 0)) -or
       $Source.isTopLevel -isnot [bool] -or -not $Source.isTopLevel -or $Source.mode -cne 'Unrelated' -or
       -not (Test-CcodExactInt32 $Source.rendererPort 1) -or $Source.rendererPort -gt 65535 -or
       -not (Test-CcodExactInt32 $Source.mainPort 1) -or $Source.mainPort -gt 65535 -or $Source.rendererPort -eq $Source.mainPort){
        Throw-CcodSupervisorError 'CCOD_CONTROLLER_RESULT_INVALID' 'Controller stale source is invalid' $Source
    }
}

function Assert-CcodRepairStaleCorrelation {
    param($Result,$ExpectedSource)
    Assert-CcodProcessSnapshot $ExpectedSource 'CCOD_CONTROLLER_RESULT_INVALID'
    if(-not $ExpectedSource.IsTopLevel -or $ExpectedSource.Mode -cne 'Unrelated' -or
       -not (Test-CcodExactInt32 $ExpectedSource.RendererPort 1) -or $ExpectedSource.RendererPort -gt 65535 -or
       -not (Test-CcodExactInt32 $ExpectedSource.MainPort 1) -or $ExpectedSource.MainPort -gt 65535 -or
       $ExpectedSource.RendererPort -eq $ExpectedSource.MainPort){
        Throw-CcodSupervisorError 'CCOD_CONTROLLER_RESULT_INVALID' 'Expected stale source is invalid' $ExpectedSource
    }
    if($Result.ok -and $Result.safeState -ceq 'OrdinaryRunning'){return}
    if($null -eq $Result.source){
        if($Result.ok){Throw-CcodSupervisorError 'CCOD_CONTROLLER_RESULT_INVALID' 'Successful stale repair lacks correlated source evidence' $Result}
        return
    }
    Assert-CcodControllerStaleSource $Result.source
    $mapping=[ordered]@{pid='Pid';creationTimeUtc='CreationTimeUtc';sessionId='SessionId';userSid='UserSid';path='Path';packageFamilyName='PackageFamilyName';commandLine='CommandLine';parentPid='ParentPid';isTopLevel='IsTopLevel';mode='Mode';rendererPort='RendererPort';mainPort='MainPort'}
    foreach($entry in $mapping.GetEnumerator()){
        if(-not [object]::Equals($Result.source.($entry.Key),$ExpectedSource.($entry.Value))){
            Throw-CcodSupervisorError 'CCOD_CONTROLLER_RESULT_INVALID' 'RepairStale result source does not match its dispatched request' $Result.source
        }
    }
}

function Assert-CcodControllerPackage {
    param($Package)
    if ($null -eq $Package) { return }
    Assert-CcodExactObject $Package @('fullName','familyName','version','appAsarSha256') 'CCOD_CONTROLLER_RESULT_INVALID' 'Controller package'
    foreach ($name in @('fullName','familyName','version')) {
        $value = Get-CcodObjectPropertyValue $Package $name
        if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value)) {
            Throw-CcodSupervisorError 'CCOD_CONTROLLER_RESULT_INVALID' 'Controller package is invalid' $Package
        }
    }
    if ($Package.appAsarSha256 -isnot [string] -or $Package.appAsarSha256 -cnotmatch '^[0-9a-f]{64}$') {
        Throw-CcodSupervisorError 'CCOD_CONTROLLER_RESULT_INVALID' 'Controller package hash is invalid' $Package
    }
}

function Assert-CcodControllerSpecial {
    param($Special)
    if ($null -eq $Special) { return }
    Assert-CcodExactObject $Special @('pid','creationTimeUtc','rendererPort','mainPort') 'CCOD_CONTROLLER_RESULT_INVALID' 'Controller special'
    if (-not (Test-CcodExactInt32 $Special.pid 1) -or -not (Test-CcodCanonicalUtc $Special.creationTimeUtc) -or
        -not (Test-CcodExactInt32 $Special.rendererPort 1) -or $Special.rendererPort -gt 65535 -or
        -not (Test-CcodExactInt32 $Special.mainPort 1) -or $Special.mainPort -gt 65535 -or
        $Special.rendererPort -eq $Special.mainPort) {
        Throw-CcodSupervisorError 'CCOD_CONTROLLER_RESULT_INVALID' 'Controller special identity is invalid' $Special
    }
}

function Assert-CcodControllerProbes {
    param($Probes)
    if ($null -eq $Probes) { return }
    $names = @(Get-CcodObjectPropertyNames $Probes)
    $rendererOnly = $names.Count -eq 1 -and $names[0] -ceq 'renderer'
    $full = $names.Count -eq 2 -and $names -ccontains 'main' -and $names -ccontains 'renderer'
    if (-not $rendererOnly -and -not $full) {
        Throw-CcodSupervisorError 'CCOD_CONTROLLER_RESULT_INVALID' 'Controller probes shape is invalid' $Probes
    }
    $renderer = Get-CcodObjectPropertyValue $Probes 'renderer'
    Assert-CcodExactObject $renderer @('targetUrl','currentDocument','newDocumentScriptInstalled','probe') 'CCOD_CONTROLLER_RESULT_INVALID' 'Renderer proof'
    Assert-CcodExactObject $renderer.currentDocument @('installed') 'CCOD_CONTROLLER_RESULT_INVALID' 'Current document proof'
    Assert-CcodExactObject $renderer.probe @('proof','targetGate') 'CCOD_CONTROLLER_RESULT_INVALID' 'Renderer gate proof'
    if ($renderer.targetUrl -isnot [string] -or [string]::IsNullOrWhiteSpace($renderer.targetUrl) -or
        $renderer.currentDocument.installed -isnot [bool] -or $renderer.newDocumentScriptInstalled -isnot [bool] -or
        $renderer.probe.proof -isnot [bool] -or $renderer.probe.targetGate -isnot [string] -or
        [string]::IsNullOrWhiteSpace($renderer.probe.targetGate)) {
        Throw-CcodSupervisorError 'CCOD_CONTROLLER_RESULT_INVALID' 'Renderer proof fields are invalid' $renderer
    }
    if ($full) {
        $main = Get-CcodObjectPropertyValue $Probes 'main'
        Assert-CcodExactObject $main @('inspectorPortClosed') 'CCOD_CONTROLLER_RESULT_INVALID' 'Main proof'
        Assert-CcodExactObject $main.inspectorPortClosed @('confirmed','code') 'CCOD_CONTROLLER_RESULT_INVALID' 'Main refusal proof'
        if ($main.inspectorPortClosed.confirmed -isnot [bool] -or
            $main.inspectorPortClosed.code -isnot [string] -or [string]::IsNullOrWhiteSpace($main.inspectorPortClosed.code)) {
            Throw-CcodSupervisorError 'CCOD_CONTROLLER_RESULT_INVALID' 'Main refusal proof fields are invalid' $main
        }
    }
}

function Assert-CcodControllerRecovery {
    param($Recovery)
    if ($null -eq $Recovery) { return }
    Assert-CcodExactObject $Recovery @('pid','creationTimeUtc','ignoreKey','suppressionKey','portsClosed','disposition','priorTransactionId') 'CCOD_CONTROLLER_RESULT_INVALID' 'Controller recovery'
    if (-not (Test-CcodExactInt32 $Recovery.pid 1) -or -not (Test-CcodCanonicalUtc $Recovery.creationTimeUtc) -or
        $Recovery.ignoreKey -isnot [string] -or $Recovery.suppressionKey -isnot [string] -or
        $Recovery.portsClosed -isnot [bool] -or -not $Recovery.portsClosed -or
        $Recovery.disposition -isnot [string] -or @('AdoptedDuringObservation','LaunchedOnce','ReplayAdopted') -cnotcontains $Recovery.disposition -or
        -not (Test-CcodCanonicalGuid $Recovery.priorTransactionId)) {
        Throw-CcodSupervisorError 'CCOD_CONTROLLER_RESULT_INVALID' 'Controller recovery evidence is invalid' $Recovery
    }
    $expectedIgnore = '{0}|{1}|{2}' -f $Recovery.pid,$Recovery.creationTimeUtc,$Recovery.priorTransactionId
    if ($Recovery.ignoreKey -cne $expectedIgnore -or $Recovery.suppressionKey -cnotmatch '^[^|]+\|[0-9a-f]{64}\|[^|]+$') {
        Throw-CcodSupervisorError 'CCOD_CONTROLLER_RESULT_INVALID' 'Controller recovery keys are invalid' $Recovery
    }
}

function Assert-CcodControllerError {
    param($ErrorValue)
    if ($null -eq $ErrorValue) { return }
    Assert-CcodExactObject $ErrorValue @('code','stage','message') 'CCOD_CONTROLLER_RESULT_INVALID' 'Controller error'
    if ($ErrorValue.code -isnot [string] -or $script:CcodStableControllerErrorCodes -cnotcontains $ErrorValue.code -or
        $ErrorValue.stage -isnot [string] -or [string]::IsNullOrWhiteSpace($ErrorValue.stage) -or
        $ErrorValue.message -isnot [string] -or [string]::IsNullOrWhiteSpace($ErrorValue.message)) {
        Throw-CcodSupervisorError 'CCOD_CONTROLLER_RESULT_INVALID' 'Controller error is not sanitized' $ErrorValue
    }
}

function Assert-CcodControllerEnvelopeShape {
    param($Result)
    $code = 'CCOD_CONTROLLER_RESULT_INVALID'
    Assert-CcodExactObject $Result $script:CcodControllerResultFields $code 'Controller result'
    if ($Result.schemaVersion -isnot [int] -or $Result.schemaVersion -ne 1 -or
        $Result.action -isnot [string] -or @('Inspect','Apply','RepairStale','RepairRenderer','Recover') -cnotcontains $Result.action -or
        $Result.ok -isnot [bool] -or $Result.outcome -isnot [string] -or $Result.safeState -isnot [string] -or
        $Result.stage -isnot [string] -or $Result.stage -cnotmatch '^[A-Za-z][A-Za-z0-9]*$' -or
        -not (Test-CcodCanonicalGuid $Result.transactionId) -or
        ($null -ne $Result.logFile -and ($Result.logFile -isnot [string] -or [string]::IsNullOrWhiteSpace($Result.logFile)))) {
        Throw-CcodSupervisorError $code 'Controller result scalar fields are invalid' $Result
    }
    Assert-CcodControllerPackage $Result.package
    if ($null -ne $Result.source) {
        if($Result.action -ceq 'RepairStale' -and $Result.outcome -cne 'Recovered'){Assert-CcodControllerStaleSource $Result.source}
        else{Assert-CcodControllerIdentity $Result.source 'Controller source'}
    }
    Assert-CcodControllerSpecial $Result.special
    Assert-CcodControllerProbes $Result.probes
    Assert-CcodControllerRecovery $Result.recovery
    Assert-CcodControllerError $Result.error
    if (-not $Result.ok) {
        if ($Result.outcome -cne 'Error' -or $Result.safeState -cne 'Error' -or $null -eq $Result.error -or $null -ne $Result.recovery) {
            Throw-CcodSupervisorError $code 'Controller failure envelope is contradictory' $Result
        }
        return
    }
    if ($null -ne $Result.error) { Throw-CcodSupervisorError $code 'Controller success contains an error' $Result }
    $tuple = $Result.outcome + '|' + $Result.safeState
    $allowed = @(
        'Activated|SpecialValidated','Inspected|SpecialValidated','Inspected|RendererRepairRequired',
        'Inspected|OrdinaryRunning','Inspected|NoCodex','NoAction|SpecialValidated','NoAction|OrdinaryRunning',
        'NoAction|NoCodex','Recovered|OrdinaryRunning','Closed|Closed'
    )
    if ($allowed -cnotcontains $tuple) { Throw-CcodSupervisorError $code 'Controller success tuple is invalid' $Result }
    if (@('SpecialValidated','RendererRepairRequired') -ccontains $Result.safeState -and $null -eq $Result.special) {
        Throw-CcodSupervisorError $code 'Controller special safe state lacks identity' $Result
    }
    if ($Result.safeState -ceq 'OrdinaryRunning' -and $null -eq $Result.source) {
        Throw-CcodSupervisorError $code 'Controller ordinary safe state lacks identity' $Result
    }
    if ($Result.outcome -ceq 'Recovered') {
        if ($null -eq $Result.package -or $null -eq $Result.recovery -or
            $Result.source.pid -ne $Result.recovery.pid -or
            $Result.source.creationTimeUtc -cne $Result.recovery.creationTimeUtc) {
            Throw-CcodSupervisorError $code 'Controller recovery does not match ordinary identity' $Result
        }
        $suppressionParts = @($Result.recovery.suppressionKey.Split([char]'|'))
        if ($suppressionParts.Count -ne 3 -or
            $suppressionParts[0] -cne $Result.package.fullName -or
            $suppressionParts[1] -cne $Result.package.appAsarSha256) {
            Throw-CcodSupervisorError $code 'Controller recovery suppression does not match package identity' $Result
        }
    } elseif ($null -ne $Result.recovery) {
        Throw-CcodSupervisorError $code 'Non-recovery result contains recovery evidence' $Result
    }
}

function Test-CcodActionOutcomeStageCompatibility {
    param($Result)
    $tuple = $Result.outcome + '|' + $Result.safeState + '|' + $Result.stage
    switch ($Result.action) {
        'Inspect' {
            return @(
                'Inspected|SpecialValidated|Inspected','Inspected|RendererRepairRequired|Inspected',
                'Inspected|OrdinaryRunning|Inspected','Inspected|NoCodex|Inspected'
            ) -ccontains $tuple
        }
        'Apply' {
            return @(
                'Activated|SpecialValidated|Completed','NoAction|NoCodex|Cancelled',
                'Recovered|OrdinaryRunning|Recovered'
            ) -ccontains $tuple
        }
        'RepairStale' {
            return @(
                'Activated|SpecialValidated|Completed','Recovered|OrdinaryRunning|Recovered'
            ) -ccontains $tuple
        }
        'RepairRenderer' {
            return @('NoAction|SpecialValidated|RendererRepaired','Recovered|OrdinaryRunning|Recovered') -ccontains $tuple
        }
        'Recover' {
            return @(
                'NoAction|SpecialValidated|Activated','NoAction|OrdinaryRunning|OrdinaryKept',
                'NoAction|OrdinaryRunning|Cancelled','NoAction|NoCodex|Cancelled',
                'Recovered|OrdinaryRunning|Recovered','Closed|Closed|Closed'
            ) -ccontains $tuple
        }
    }
    return $false
}

function New-CcodControllerReduction {
    param([string]$SessionState, [bool]$Block, $AttemptKey, $RecoveryIgnoreKey, $SuppressionKey, $ErrorCode, [string]$Reason)
    return [pscustomobject][ordered]@{
        SessionState=$SessionState
        BlockAutomaticActions=$Block
        AttemptKey=$AttemptKey
        RecoveryIgnoreKey=$RecoveryIgnoreKey
        SuppressionKey=$SuppressionKey
        ErrorCode=$ErrorCode
        Reason=$Reason
    }
}

function Complete-CcodControllerRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()]$Result,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()]$ExpectedTransactionId,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()]$ExpectedAction,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()]$ExpectedRuntimeId,
        [AllowNull()]$ExpectedSource=$null
    )
    if (-not (Test-CcodCanonicalGuid $ExpectedTransactionId) -or
        $ExpectedAction -isnot [string] -or @('Inspect','Apply','RepairStale','RepairRenderer','Recover') -cnotcontains $ExpectedAction -or
        $ExpectedRuntimeId -isnot [string] -or $ExpectedRuntimeId -cnotmatch '^[A-Za-z0-9._-]{1,96}$') {
        return New-CcodControllerReduction 'Error' $true $null $null $null 'CCOD_CONTROLLER_RESULT_INVALID' 'ControllerResultInvalid'
    }
    try {
        Assert-CcodControllerEnvelopeShape $Result
        if($ExpectedAction -ceq 'RepairStale'){Assert-CcodRepairStaleCorrelation $Result $ExpectedSource}
        elseif($null -ne $ExpectedSource){Throw-CcodSupervisorError 'CCOD_CONTROLLER_RESULT_INVALID' 'Unexpected source correlation input' $ExpectedSource}
    }
    catch { return New-CcodControllerReduction 'Error' $true $null $null $null 'CCOD_CONTROLLER_RESULT_INVALID' 'ControllerResultInvalid' }
    if ($Result.transactionId -cne $ExpectedTransactionId -or $Result.action -cne $ExpectedAction) {
        return New-CcodControllerReduction 'Error' $true $null $null $null 'CCOD_CONTROLLER_RESULT_MISMATCH' 'ControllerResultMismatch'
    }
    $attemptKey = $null
    if ($null -ne $Result.source) { $attemptKey = '{0}|{1}' -f $Result.source.pid,$Result.source.creationTimeUtc }
    if (-not $Result.ok) {
        $reason = if ($Result.error.code -ceq 'CCOD_STATE_STALE_PACKAGE') { 'StalePackageStatus' } else { 'ControllerFailed' }
        return New-CcodControllerReduction 'Error' $true $attemptKey $null $null $Result.error.code $reason
    }
    if (-not (Test-CcodActionOutcomeStageCompatibility $Result)) {
        return New-CcodControllerReduction 'Error' $true $null $null $null 'CCOD_CONTROLLER_RESULT_INVALID' 'ControllerResultInvalid'
    }
    if ($Result.outcome -ceq 'Recovered') {
        $suppressionParts = @($Result.recovery.suppressionKey.Split([char]'|'))
        if ($suppressionParts.Count -ne 3 -or $suppressionParts[2] -cne $ExpectedRuntimeId) {
            return New-CcodControllerReduction 'Error' $true $null $null $null 'CCOD_CONTROLLER_RESULT_INVALID' 'ControllerResultInvalid'
        }
    }
    if ($Result.safeState -ceq 'SpecialValidated') {
        return New-CcodControllerReduction 'Active' $false $attemptKey $null $null $null 'SpecialValidated'
    }
    if ($Result.safeState -ceq 'RendererRepairRequired') {
        return New-CcodControllerReduction 'Inspecting' $false $attemptKey $null $null $null 'RendererRepairRequired'
    }
    if ($Result.outcome -ceq 'Recovered') {
        return New-CcodControllerReduction 'Recovered' $false $attemptKey $Result.recovery.ignoreKey $Result.recovery.suppressionKey $null 'OrdinaryRecovered'
    }
    if ($Result.safeState -ceq 'OrdinaryRunning') {
        return New-CcodControllerReduction 'Waiting' $false $attemptKey $null $null $null 'OrdinaryRunning'
    }
    if ($Result.safeState -ceq 'Closed') {
        return New-CcodControllerReduction 'Waiting' $false $attemptKey $null $null $null 'Closed'
    }
    return New-CcodControllerReduction 'Waiting' $false $attemptKey $null $null $null 'NoCodex'
}

function Get-CcodTrayPresentation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ConnectionState,
        [Parameter(Mandatory)][string]$ProtectionState,
        [Parameter(Mandatory)]$Busy,
        [Parameter(Mandatory)]$StateDamageBlocksActions
    )
    $code = 'CCOD_TRAY_INPUT_INVALID'
    if (@('WaitingForCodex','Checking','Connected','RepairNeeded','Error') -cnotcontains $ConnectionState) {
        Throw-CcodSupervisorError $code 'Tray connection state is invalid' $ConnectionState
    }
    if (@('Running','Reconnecting','Stopping') -cnotcontains $ProtectionState) {
        Throw-CcodSupervisorError $code 'Tray protection state is invalid' $ProtectionState
    }
    foreach ($value in @($Busy,$StateDamageBlocksActions)) {
        if ($value -isnot [bool]) { Throw-CcodSupervisorError $code 'Tray Boolean is invalid' $value }
    }
    $color = switch ($ConnectionState) {
        'Connected' { 'Green' }
        'Checking' { 'Yellow' }
        'RepairNeeded' { 'Yellow' }
        'Error' { 'Red' }
        default { 'Gray' }
    }
    $actionsBlocked = $Busy -or $StateDamageBlocksActions -or $ProtectionState -ceq 'Stopping'
    return [pscustomobject][ordered]@{
        Color=$color
        ConnectionState=$ConnectionState
        ProtectionState=$ProtectionState
        RepairEnabled=[bool]($ConnectionState -ceq 'RepairNeeded' -and -not $actionsBlocked)
        LanguageEnabled=[bool](-not $actionsBlocked)
        OpenLogsEnabled=[bool]$true
        AboutEnabled=[bool]$true
        ExitEnabled=$false
        Busy=[bool]$Busy
    }
}

Export-ModuleMember -Function @(
    'Get-CcodSupervisorDecision',
    'Add-CcodObservedEvent',
    'Complete-CcodControllerRun',
    'Get-CcodTrayPresentation'
)
