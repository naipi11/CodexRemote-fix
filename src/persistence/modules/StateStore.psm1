Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'PersistenceIO.psm1') -Force

function Throw-CcodStateError {
    param([string]$Id, [string]$Message, $TargetObject)

    $exception = [InvalidOperationException]::new($Message)
    $record = [Management.Automation.ErrorRecord]::new($exception, $Id, [Management.Automation.ErrorCategory]::InvalidData, $TargetObject)
    throw $record
}

function Get-CcodStateAdapters {
    param([hashtable]$Adapters)

    $result = @{
        UtcNow = { [DateTime]::UtcNow }
        TestVerifiedNodeCandidate = { param($Path) Test-Path -LiteralPath $Path -PathType Leaf }
        DirectoryExists = { param($Path) [IO.Directory]::Exists($Path) }
        CreateDirectory = { param($Path) [IO.Directory]::CreateDirectory($Path) | Out-Null }
        BeforeFailedPackageAttemptRecheck = { param($Path, $SuppressionKey) }
        WriteAtomicJson = { param($Path, $Value) Write-CcodAtomicJson -Path $Path -Value $Value }
    }
    if ($null -ne $Adapters) {
        foreach ($key in $Adapters.Keys) { $result[$key] = $Adapters[$key] }
    }
    return $result
}

function Test-CcodStateProperty {
    param([Parameter(Mandatory)]$Value, [Parameter(Mandatory)][string]$Name)

    if ($Value -is [Collections.IDictionary]) { return $Value.Contains($Name) }
    return $null -ne $Value.PSObject.Properties[$Name]
}

function Get-CcodStatePropertyNames {
    param([Parameter(Mandatory)]$Value)

    if ($Value -is [Collections.IDictionary]) { return @($Value.Keys | ForEach-Object { [string]$_ }) }
    return @($Value.PSObject.Properties | ForEach-Object { $_.Name })
}

function Assert-CcodExactProperties {
    param([Parameter(Mandatory)]$Value, [Parameter(Mandatory)][string[]]$Expected, [Parameter(Mandatory)][string]$ErrorId, [Parameter(Mandatory)][string]$Kind)

    $actual = @(Get-CcodStatePropertyNames -Value $Value | Sort-Object)
    $wanted = @($Expected | Sort-Object)
    if ($actual.Count -ne $wanted.Count -or @($actual | Where-Object { $wanted -cnotcontains $_ }).Count -ne 0) {
        Throw-CcodStateError $ErrorId "$Kind state has unexpected or missing fields" $Value
    }
}

function Test-CcodSchemaVersionOne {
    param([Parameter(Mandatory)]$Value)

    return (Test-CcodStateProperty -Value $Value -Name 'schemaVersion') -and
        ($Value.schemaVersion -is [int] -or $Value.schemaVersion -is [long]) -and $Value.schemaVersion -eq 1
}

function Assert-CcodUtcTimestamp {
    param([Parameter(Mandatory)]$Value, [Parameter(Mandatory)][string]$ErrorId, [Parameter(Mandatory)][string]$Name)

    if ($Value -isnot [string]) { Throw-CcodStateError $ErrorId "$Name must be a UTC round-trip timestamp" $Value }
    $parsed = [DateTime]::MinValue
    if (-not [DateTime]::TryParseExact($Value, 'o', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed) -or
        $parsed.Kind -ne [DateTimeKind]::Utc -or $parsed.ToUniversalTime().ToString('o') -cne $Value) {
        Throw-CcodStateError $ErrorId "$Name must be a UTC round-trip timestamp" $Value
    }
}

function Assert-CcodCanonicalGuid {
    param([Parameter(Mandatory)]$Value, [Parameter(Mandatory)][string]$ErrorId, [Parameter(Mandatory)][string]$Name)

    if ($Value -isnot [string]) { Throw-CcodStateError $ErrorId "$Name must be a canonical lowercase GUID in D form" $Value }
    $parsed = [guid]::Empty
    if (-not [guid]::TryParseExact($Value, 'D', [ref]$parsed) -or $parsed.ToString('D') -cne $Value) {
        Throw-CcodStateError $ErrorId "$Name must be a canonical lowercase GUID in D form" $Value
    }
}

function Assert-CcodPositiveInteger {
    param([Parameter(Mandatory)]$Value, [Parameter(Mandatory)][string]$ErrorId, [Parameter(Mandatory)][string]$Name)

    if (($Value -isnot [int] -and $Value -isnot [long]) -or $Value -lt 1) {
        Throw-CcodStateError $ErrorId "$Name must be a positive integer" $Value
    }
}

function Assert-CcodTcpPort {
    param([Parameter(Mandatory)]$Value, [Parameter(Mandatory)][string]$ErrorId, [Parameter(Mandatory)][string]$Name)

    if (($Value -isnot [int] -and $Value -isnot [long]) -or $Value -lt 1 -or $Value -gt 65535) {
        Throw-CcodStateError $ErrorId "$Name must be a legal TCP port" $Value
    }
}

function Get-CcodStatePath {
    param([Parameter(Mandatory)][string]$StateRoot, [Parameter(Mandatory)][string]$Leaf)

    return (Resolve-CcodContainedPath -Root $StateRoot -RelativePath $Leaf -AllowMissingLeaf)
}

function Get-CcodStateTimestamp {
    param([hashtable]$Adapters)

    $now = & $Adapters.UtcNow
    if ($now -isnot [DateTime]) {
        Throw-CcodStateError 'CCOD_CLOCK_INVALID' 'State clock must return a DateTime value' $now
    }
    return $now.ToUniversalTime().ToString('o')
}

function Assert-CcodAbsoluteNodeCandidates {
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$NodeCandidates, [hashtable]$Adapters)

    $adapters = Get-CcodStateAdapters -Adapters $Adapters
    foreach ($candidate in $NodeCandidates) {
        $normalized = $null
        try { $normalized = [IO.Path]::GetFullPath($candidate) } catch { }
        if ([string]::IsNullOrWhiteSpace($candidate) -or
            $candidate -notmatch '^(?:[A-Za-z]:\\|\\\\[^\\]+\\[^\\]+\\)' -or
            $null -eq $normalized -or
            $candidate -cne $normalized -or
            [IO.Path]::GetFileName($normalized) -cne 'node.exe' -or
            -not (& $adapters.TestVerifiedNodeCandidate $candidate)) {
            Throw-CcodStateError 'CCOD_NODE_CANDIDATE_INVALID' 'Node candidates must be installer-verified absolute paths' $candidate
        }
    }
}

function New-CcodSettings {
    param(
        [string[]]$NodeCandidates,
        [bool]$CandidateCompatibleOptIn,
        [bool]$AutomationEnabled,
        [Parameter(Mandatory)][string]$UpdatedAtUtc
    )

    return [ordered]@{
        schemaVersion = 1
        automationEnabled = $AutomationEnabled
        candidateCompatibleOptIn = $CandidateCompatibleOptIn
        nodeCandidates = @($NodeCandidates)
        updatedAtUtc = $UpdatedAtUtc
    }
}

function New-CcodStatusStore {
    return [ordered]@{
        schemaVersion = 1
        session = $null
    }
}

function New-CcodVerifiedPackagesStore {
    return [ordered]@{
        schemaVersion = 1
        packages = [ordered]@{}
    }
}

function New-CcodTransitionStore {
    return [ordered]@{ schemaVersion = 1; activeTransaction = $null }
}

function Assert-CcodSettingsShape {
    param([Parameter(Mandatory)]$Settings, [hashtable]$Adapters)

    Assert-CcodExactProperties -Value $Settings -Expected @('schemaVersion', 'automationEnabled', 'candidateCompatibleOptIn', 'nodeCandidates', 'updatedAtUtc') -ErrorId 'CCOD_SETTINGS_INVALID' -Kind 'Settings'
    if (-not (Test-CcodSchemaVersionOne -Value $Settings)) { Throw-CcodStateError 'CCOD_SETTINGS_INVALID' 'Settings schemaVersion must be integer 1' $Settings }
    if ($Settings.automationEnabled -isnot [bool] -or $Settings.candidateCompatibleOptIn -isnot [bool] -or
        $Settings.updatedAtUtc -isnot [string] -or [string]::IsNullOrWhiteSpace($Settings.updatedAtUtc)) {
        Throw-CcodStateError 'CCOD_SETTINGS_INVALID' 'Settings state has invalid consent or timestamp fields' $Settings
    }
    if ($null -eq $Settings.nodeCandidates -or $Settings.nodeCandidates -is [string] -or $Settings.nodeCandidates -isnot [Collections.IEnumerable]) {
        Throw-CcodStateError 'CCOD_SETTINGS_INVALID' 'Settings node candidates must be a string array' $Settings
    }
    $candidates = @($Settings.nodeCandidates)
    if (@($candidates | Where-Object { $_ -isnot [string] }).Count -ne 0) { Throw-CcodStateError 'CCOD_SETTINGS_INVALID' 'Settings node candidates must be a string array' $Settings }
    Assert-CcodUtcTimestamp -Value $Settings.updatedAtUtc -ErrorId 'CCOD_SETTINGS_INVALID' -Name 'updatedAtUtc'
    Assert-CcodAbsoluteNodeCandidates -NodeCandidates $candidates -Adapters $Adapters
}

function Assert-CcodStatusShape {
    param([Parameter(Mandatory)]$Status, [hashtable]$Adapters)

    Assert-CcodExactProperties -Value $Status -Expected @('schemaVersion', 'session') -ErrorId 'CCOD_STATUS_INVALID' -Kind 'Status'
    if (-not (Test-CcodSchemaVersionOne -Value $Status)) { Throw-CcodStateError 'CCOD_STATUS_INVALID' 'Status schemaVersion must be integer 1' $Status }
    if ($null -eq $Status.session) { return }
    if ($Status.session -isnot [pscustomobject] -and $Status.session -isnot [Collections.IDictionary]) { Throw-CcodStateError 'CCOD_STATUS_INVALID' 'Status session must be null or an object' $Status }
    $required = @('supervisorPid', 'supervisorCreationTimeUtc', 'sessionId', 'runtimeId', 'sessionState', 'codex')
    Assert-CcodExactProperties -Value $Status.session -Expected $required -ErrorId 'CCOD_STATUS_INVALID' -Kind 'Status session'
    Assert-CcodPositiveInteger -Value $Status.session.supervisorPid -ErrorId 'CCOD_STATUS_INVALID' -Name 'supervisorPid'
    Assert-CcodUtcTimestamp -Value $Status.session.supervisorCreationTimeUtc -ErrorId 'CCOD_STATUS_INVALID' -Name 'supervisorCreationTimeUtc'
    foreach ($name in @('sessionId', 'runtimeId', 'sessionState')) {
        if ($Status.session.$name -isnot [string] -or [string]::IsNullOrWhiteSpace($Status.session.$name)) { Throw-CcodStateError 'CCOD_STATUS_INVALID' "Status $name must be a non-empty string" $Status }
    }
    if (@('Ordinary', 'Active', 'Transitioning', 'Recovering', 'Error', 'Paused') -cnotcontains $Status.session.sessionState) { Throw-CcodStateError 'CCOD_STATUS_INVALID' 'Status sessionState is invalid' $Status }
    if ($null -eq $Status.session.codex) {
        if ($Status.session.sessionState -ceq 'Active') { Throw-CcodStateError 'CCOD_STATUS_INVALID' 'Active status requires a validated Codex identity' $Status }
        return
    }
    if ($Status.session.sessionState -cne 'Active') { Throw-CcodStateError 'CCOD_STATUS_INVALID' 'A validated Codex identity requires Active sessionState' $Status }
    if ($Status.session.codex -isnot [pscustomobject] -and $Status.session.codex -isnot [Collections.IDictionary]) { Throw-CcodStateError 'CCOD_STATUS_INVALID' 'Status codex must be null or an object' $Status }
    $codexFields = @('pid', 'creationTimeUtc', 'packageFullName', 'packageVersion', 'appAsarSha256', 'mainPort', 'rendererPort', 'mainProbe', 'rendererProbe')
    Assert-CcodExactProperties -Value $Status.session.codex -Expected $codexFields -ErrorId 'CCOD_STATUS_INVALID' -Kind 'Status codex'
    foreach ($name in @('packageFullName', 'packageVersion', 'appAsarSha256', 'mainProbe', 'rendererProbe')) {
        if ($Status.session.codex.$name -isnot [string] -or [string]::IsNullOrWhiteSpace($Status.session.codex.$name)) { Throw-CcodStateError 'CCOD_STATUS_INVALID' "Status codex $name must be a non-empty string" $Status }
    }
    Assert-CcodPositiveInteger -Value $Status.session.codex.pid -ErrorId 'CCOD_STATUS_INVALID' -Name 'codex.pid'
    Assert-CcodUtcTimestamp -Value $Status.session.codex.creationTimeUtc -ErrorId 'CCOD_STATUS_INVALID' -Name 'codex.creationTimeUtc'
    if ($Status.session.codex.appAsarSha256 -cnotmatch '^[0-9a-f]{64}$') { Throw-CcodStateError 'CCOD_STATUS_INVALID' 'Status codex appAsarSha256 must be lowercase SHA-256' $Status }
    Assert-CcodTcpPort -Value $Status.session.codex.mainPort -ErrorId 'CCOD_STATUS_INVALID' -Name 'codex.mainPort'
    Assert-CcodTcpPort -Value $Status.session.codex.rendererPort -ErrorId 'CCOD_STATUS_INVALID' -Name 'codex.rendererPort'
    if ($Status.session.codex.mainPort -eq $Status.session.codex.rendererPort) { Throw-CcodStateError 'CCOD_STATUS_INVALID' 'Status ports must be distinct' $Status }
    if ($Status.session.codex.mainProbe -cne 'Closed' -or $Status.session.codex.rendererProbe -cne 'BridgeValid') { Throw-CcodStateError 'CCOD_STATUS_INVALID' 'Active status must confirm a closed main Inspector and valid renderer bridge' $Status }
}

function Assert-CcodVerifiedPackagesShape {
    param([Parameter(Mandatory)]$VerifiedPackages, [hashtable]$Adapters)

    Assert-CcodExactProperties -Value $VerifiedPackages -Expected @('schemaVersion', 'packages') -ErrorId 'CCOD_VERIFIED_PACKAGES_INVALID' -Kind 'Verified packages'
    if (-not (Test-CcodSchemaVersionOne -Value $VerifiedPackages)) { Throw-CcodStateError 'CCOD_VERIFIED_PACKAGES_INVALID' 'Verified package schemaVersion must be integer 1' $VerifiedPackages }
    if ($null -eq $VerifiedPackages.packages -or $VerifiedPackages.packages -is [string] -or $VerifiedPackages.packages -isnot [pscustomobject] -and $VerifiedPackages.packages -isnot [Collections.IDictionary]) {
        Throw-CcodStateError 'CCOD_VERIFIED_PACKAGES_INVALID' 'Verified package state packages must be an object' $VerifiedPackages
    }
    foreach ($key in Get-CcodStatePropertyNames -Value $VerifiedPackages.packages) {
        $record = $VerifiedPackages.packages.$key
        if ($record -isnot [pscustomobject] -and $record -isnot [Collections.IDictionary]) { Throw-CcodStateError 'CCOD_VERIFIED_PACKAGES_INVALID' 'Verified package record must be an object' $record }
        $required = @('packageFullName', 'packageVersion', 'appAsarSha256', 'runtimeId', 'staticClassification', 'dynamicOutcome', 'probeState', 'confirmedAtUtc')
        Assert-CcodExactProperties -Value $record -Expected $required -ErrorId 'CCOD_VERIFIED_PACKAGES_INVALID' -Kind 'Verified package record'
        foreach ($name in $required | Where-Object { $_ -ne 'confirmedAtUtc' }) {
            if ($record.$name -isnot [string] -or [string]::IsNullOrWhiteSpace($record.$name)) { Throw-CcodStateError 'CCOD_VERIFIED_PACKAGES_INVALID' "Verified record $name must be a non-empty string" $record }
        }
        if ($record.appAsarSha256 -cnotmatch '^[0-9a-f]{64}$' -or @('CandidateCompatible', 'NativeModulePresent', 'UnknownOrIncompatible', 'VerifiedCompatible') -cnotcontains $record.staticClassification -or @('Succeeded', 'Failed') -cnotcontains $record.dynamicOutcome -or @('Valid', 'Invalid', 'NotRun') -cnotcontains $record.probeState) {
            Throw-CcodStateError 'CCOD_VERIFIED_PACKAGES_INVALID' 'Verified record has an invalid classification or outcome' $record
        }
        if (($record.dynamicOutcome -ceq 'Succeeded' -and $record.probeState -cne 'Valid') -or
            ($record.dynamicOutcome -ceq 'Failed' -and @('Invalid', 'NotRun') -cnotcontains $record.probeState) -or
            (@('NativeModulePresent', 'UnknownOrIncompatible') -ccontains $record.staticClassification -and $record.dynamicOutcome -ceq 'Succeeded')) {
            Throw-CcodStateError 'CCOD_VERIFIED_PACKAGES_INVALID' 'Verified record has an invalid classification, outcome, or probe pairing' $record
        }
        Assert-CcodUtcTimestamp -Value $record.confirmedAtUtc -ErrorId 'CCOD_VERIFIED_PACKAGES_INVALID' -Name 'confirmedAtUtc'
        if ($key -cne (Get-CcodSuppressionKey -PackageFullName $record.packageFullName -AppAsarSha256 $record.appAsarSha256 -RuntimeId $record.runtimeId)) { Throw-CcodStateError 'CCOD_VERIFIED_PACKAGES_INVALID' 'Verified package key does not match record identity' $record }
    }
}

function Assert-CcodNullableProcessIdentity {
    param([Parameter(Mandatory)]$Value, [Parameter(Mandatory)][string]$PidName, [Parameter(Mandatory)][string]$TimeName, [Parameter(Mandatory)][string]$ErrorId)

    $pid = $Value.$PidName
    $time = $Value.$TimeName
    if ($null -eq $pid -and $null -eq $time) { return }
    if ($null -eq $pid -or $null -eq $time) { Throw-CcodStateError $ErrorId "$PidName and $TimeName must be paired" $Value }
    Assert-CcodPositiveInteger -Value $pid -ErrorId $ErrorId -Name $PidName
    if ($pid -gt [int]::MaxValue) { Throw-CcodStateError $ErrorId "$PidName exceeds the legal Int32 process range" $Value }
    Assert-CcodUtcTimestamp -Value $time -ErrorId $ErrorId -Name $TimeName
}

function Assert-CcodNullablePortPair {
    param([Parameter(Mandatory)]$Value, [Parameter(Mandatory)][string]$ErrorId)

    $mainPort = $Value.mainPort
    $rendererPort = $Value.rendererPort
    if ($null -eq $mainPort -and $null -eq $rendererPort) { return }
    if ($null -eq $mainPort -or $null -eq $rendererPort) { Throw-CcodStateError $ErrorId 'mainPort and rendererPort must be paired' $Value }
    Assert-CcodTcpPort -Value $mainPort -ErrorId $ErrorId -Name 'mainPort'
    Assert-CcodTcpPort -Value $rendererPort -ErrorId $ErrorId -Name 'rendererPort'
    if ($mainPort -eq $rendererPort) { Throw-CcodStateError $ErrorId 'Transition ports must be distinct' $Value }
}

function Assert-CcodTransitionShape {
    param([Parameter(Mandatory)]$Transition, [hashtable]$Adapters)

    Assert-CcodExactProperties -Value $Transition -Expected @('schemaVersion', 'activeTransaction') -ErrorId 'CCOD_TRANSITION_INVALID' -Kind 'Transition'
    if (-not (Test-CcodSchemaVersionOne -Value $Transition)) { Throw-CcodStateError 'CCOD_TRANSITION_INVALID' 'Transition schemaVersion must be integer 1' $Transition }
    if ($null -eq $Transition.activeTransaction) { return }
    if ($Transition.activeTransaction -isnot [pscustomobject] -and $Transition.activeTransaction -isnot [Collections.IDictionary]) {
        Throw-CcodStateError 'CCOD_TRANSITION_INVALID' 'Transition activeTransaction must be null or an object' $Transition
    }
    $transaction = $Transition.activeTransaction
    $required = @('transactionId', 'stage', 'sourcePid', 'sourceCreationTimeUtc', 'packageFullName', 'appAsarSha256', 'runtimeId', 'mainPort', 'rendererPort', 'specialPid', 'specialCreationTimeUtc', 'recoveryPid', 'recoveryCreationTimeUtc', 'createdAtUtc', 'updatedAtUtc')
    Assert-CcodExactProperties -Value $transaction -Expected $required -ErrorId 'CCOD_TRANSITION_INVALID' -Kind 'Active transition'
    foreach ($name in @('transactionId', 'packageFullName', 'runtimeId')) { if ($transaction.$name -isnot [string] -or [string]::IsNullOrWhiteSpace($transaction.$name)) { Throw-CcodStateError 'CCOD_TRANSITION_INVALID' "$name must be a non-empty string" $transaction } }
    Assert-CcodCanonicalGuid -Value $transaction.transactionId -ErrorId 'CCOD_TRANSITION_INVALID' -Name 'transactionId'
    if ($transaction.stage -isnot [string] -or @('IntentWritten', 'StopRequested', 'OrdinaryStopped', 'SpecialLaunchRequested', 'SpecialStarted', 'Validated', 'RecoveryLaunchRequested', 'Recovered', 'CloseRequested', 'Closed') -cnotcontains $transaction.stage) { Throw-CcodStateError 'CCOD_TRANSITION_INVALID' 'Transition stage is invalid' $transaction }
    Assert-CcodNullableProcessIdentity -Value $transaction -PidName 'sourcePid' -TimeName 'sourceCreationTimeUtc' -ErrorId 'CCOD_TRANSITION_INVALID'
    if ($transaction.appAsarSha256 -isnot [string] -or $transaction.appAsarSha256 -cnotmatch '^[0-9a-f]{64}$') { Throw-CcodStateError 'CCOD_TRANSITION_INVALID' 'appAsarSha256 must be lowercase SHA-256' $transaction }
    Assert-CcodNullablePortPair -Value $transaction -ErrorId 'CCOD_TRANSITION_INVALID'
    Assert-CcodNullableProcessIdentity -Value $transaction -PidName 'specialPid' -TimeName 'specialCreationTimeUtc' -ErrorId 'CCOD_TRANSITION_INVALID'
    Assert-CcodNullableProcessIdentity -Value $transaction -PidName 'recoveryPid' -TimeName 'recoveryCreationTimeUtc' -ErrorId 'CCOD_TRANSITION_INVALID'
    Assert-CcodUtcTimestamp -Value $transaction.createdAtUtc -ErrorId 'CCOD_TRANSITION_INVALID' -Name 'createdAtUtc'
    Assert-CcodUtcTimestamp -Value $transaction.updatedAtUtc -ErrorId 'CCOD_TRANSITION_INVALID' -Name 'updatedAtUtc'
    if ([DateTime]::ParseExact($transaction.updatedAtUtc, 'o', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) -lt
        [DateTime]::ParseExact($transaction.createdAtUtc, 'o', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)) {
        Throw-CcodStateError 'CCOD_TRANSITION_INVALID' 'updatedAtUtc cannot precede createdAtUtc' $transaction
    }

    $hasSource = $null -ne $transaction.sourcePid
    $hasPorts = $null -ne $transaction.mainPort
    $hasSpecial = $null -ne $transaction.specialPid
    $hasRecovery = $null -ne $transaction.recoveryPid
    if (-not $hasSource -and $transaction.stage -ceq 'StopRequested') {
        Throw-CcodStateError 'CCOD_TRANSITION_INVALID' 'A manual transaction cannot request a source stop' $transaction
    }
    if (@('IntentWritten', 'StopRequested', 'OrdinaryStopped', 'SpecialLaunchRequested') -ccontains $transaction.stage -and $hasSpecial) {
        Throw-CcodStateError 'CCOD_TRANSITION_INVALID' 'special identity cannot exist before SpecialStarted' $transaction
    }
    if (@('SpecialStarted', 'Validated') -ccontains $transaction.stage -and -not $hasSpecial) {
        Throw-CcodStateError 'CCOD_TRANSITION_INVALID' 'SpecialStarted and Validated require special identity' $transaction
    }
    if (@('SpecialLaunchRequested', 'SpecialStarted', 'Validated') -ccontains $transaction.stage -and -not $hasPorts) {
        Throw-CcodStateError 'CCOD_TRANSITION_INVALID' 'Special launch stages require allocated distinct ports' $transaction
    }
    if ($hasSpecial -and -not $hasPorts) {
        Throw-CcodStateError 'CCOD_TRANSITION_INVALID' 'A recorded special identity requires its allocated ports' $transaction
    }
    if (@('CloseRequested', 'Closed') -ccontains $transaction.stage) {
        if ($hasSource -eq $hasSpecial) {
            Throw-CcodStateError 'CCOD_TRANSITION_INVALID' 'A close transaction requires exactly one recorded source or special root' $transaction
        }
        if ($hasSource -and $hasPorts) {
            Throw-CcodStateError 'CCOD_TRANSITION_INVALID' 'An ordinary close target cannot retain debug ports' $transaction
        }
        if ($hasRecovery) {
            Throw-CcodStateError 'CCOD_TRANSITION_INVALID' 'A close transaction cannot record a recovery identity' $transaction
        }
    }
    if ($transaction.stage -cne 'Recovered' -and $hasRecovery) {
        Throw-CcodStateError 'CCOD_TRANSITION_INVALID' 'recovery identity cannot exist before Recovered' $transaction
    }
    if ($transaction.stage -ceq 'Recovered' -and -not $hasRecovery) {
        Throw-CcodStateError 'CCOD_TRANSITION_INVALID' 'Recovered requires recovery identity' $transaction
    }
}

function Read-CcodTypedState {
    param(
        [Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)][string]$Leaf,
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][scriptblock]$Validator,
        [hashtable]$Adapters
    )

    $path = Get-CcodStatePath -StateRoot $StateRoot -Leaf $Leaf
    $value = Read-CcodStrictJson -Path $path -ExpectedSchema 1 -Kind $Kind
    & $Validator $value $Adapters
    return $value
}

function Write-CcodTypedState {
    param(
        [Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)][string]$Leaf,
        [Parameter(Mandatory)]$Value,
        [Parameter(Mandatory)][scriptblock]$Validator,
        [hashtable]$Adapters
    )

    if (-not (Test-CcodSchemaVersionOne -Value $Value)) {
        Throw-CcodStateError 'CCOD_SCHEMA_UNSUPPORTED' 'State writes require schema version 1' $Value
    }
    & $Validator $Value $Adapters
    Write-CcodAtomicJson -Path (Get-CcodStatePath -StateRoot $StateRoot -Leaf $Leaf) -Value $Value
}

function Initialize-CcodState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StateRoot,
        [string[]]$NodeCandidates = @(),
        [bool]$CandidateCompatibleOptIn = $false,
        [hashtable]$Adapters
    )

    $adapters = Get-CcodStateAdapters -Adapters $Adapters
    Import-Module (Join-Path $PSScriptRoot 'LifecycleTransaction.psm1')
    if (-not (& $adapters.DirectoryExists $StateRoot)) { & $adapters.CreateDirectory $StateRoot }
    $paths = @('settings.json', 'status.json', 'verified-packages.json', 'transition.json')
    $existing = @($paths | Where-Object { [IO.File]::Exists((Get-CcodStatePath -StateRoot $StateRoot -Leaf $_)) })
    $lifecycleRoot = Join-Path $StateRoot 'lifecycle'
    if (-not (& $adapters.DirectoryExists $lifecycleRoot)) { & $adapters.CreateDirectory $lifecycleRoot }
    $receiptRoot = Join-Path $lifecycleRoot 'receipts'
    if (-not (& $adapters.DirectoryExists $receiptRoot)) { & $adapters.CreateDirectory $receiptRoot }
    Read-CcodLifecycleRequest -StateRoot $StateRoot | Out-Null
    if ($existing.Count -eq $paths.Count) {
        return
    }
    if ($existing.Count -ne 0) {
        Throw-CcodStateError 'CCOD_STATE_ALREADY_INITIALIZED' 'State initialization refuses to overwrite existing evidence; use explicit repair' $StateRoot
    }

    Write-CcodSettings -StateRoot $StateRoot -Settings (New-CcodSettings -NodeCandidates $NodeCandidates -CandidateCompatibleOptIn $CandidateCompatibleOptIn -AutomationEnabled $true -UpdatedAtUtc (Get-CcodStateTimestamp -Adapters $adapters)) -Adapters $adapters
    Write-CcodTypedState -StateRoot $StateRoot -Leaf 'status.json' -Value (New-CcodStatusStore) -Validator ${function:Assert-CcodStatusShape} -Adapters $adapters
    Write-CcodVerifiedPackages -StateRoot $StateRoot -VerifiedPackages (New-CcodVerifiedPackagesStore) -Adapters $adapters
    Write-CcodTypedState -StateRoot $StateRoot -Leaf 'transition.json' -Value (New-CcodTransitionStore) -Validator ${function:Assert-CcodTransitionShape} -Adapters $adapters
}

function Read-CcodSettings {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StateRoot, [hashtable]$Adapters)
    return Read-CcodTypedState -StateRoot $StateRoot -Leaf 'settings.json' -Kind 'settings' -Validator ${function:Assert-CcodSettingsShape} -Adapters (Get-CcodStateAdapters -Adapters $Adapters)
}

function Write-CcodSettings {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StateRoot, [Parameter(Mandatory)]$Settings, [hashtable]$Adapters)
    Write-CcodTypedState -StateRoot $StateRoot -Leaf 'settings.json' -Value $Settings -Validator ${function:Assert-CcodSettingsShape} -Adapters (Get-CcodStateAdapters -Adapters $Adapters)
}

function Read-CcodStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StateRoot, [hashtable]$Adapters)
    return Read-CcodTypedState -StateRoot $StateRoot -Leaf 'status.json' -Kind 'status' -Validator ${function:Assert-CcodStatusShape} -Adapters (Get-CcodStateAdapters -Adapters $Adapters)
}

function Assert-CcodLiveProbeShape {
    param([Parameter(Mandatory)]$LiveProbeResult)

    Assert-CcodExactProperties -Value $LiveProbeResult -Expected @('Valid', 'runtimeId', 'pid', 'creationTimeUtc', 'packageFullName', 'packageVersion', 'appAsarSha256', 'mainPort', 'rendererPort', 'mainProbe', 'rendererProbe') -ErrorId 'CCOD_LIVE_PROBE_INVALID' -Kind 'Live probe'
    if ($LiveProbeResult.Valid -isnot [bool] -or $LiveProbeResult.Valid -ne $true) { Throw-CcodStateError 'CCOD_LIVE_PROBE_INVALID' 'Live probe Valid must be boolean true' $LiveProbeResult }
    foreach ($name in @('runtimeId', 'packageFullName', 'packageVersion', 'appAsarSha256', 'mainProbe', 'rendererProbe')) {
        if ($LiveProbeResult.$name -isnot [string] -or [string]::IsNullOrWhiteSpace($LiveProbeResult.$name)) { Throw-CcodStateError 'CCOD_LIVE_PROBE_INVALID' "Live probe $name must be a non-empty string" $LiveProbeResult }
    }
    Assert-CcodPositiveInteger -Value $LiveProbeResult.pid -ErrorId 'CCOD_LIVE_PROBE_INVALID' -Name 'live probe pid'
    Assert-CcodUtcTimestamp -Value $LiveProbeResult.creationTimeUtc -ErrorId 'CCOD_LIVE_PROBE_INVALID' -Name 'live probe creationTimeUtc'
    if ($LiveProbeResult.appAsarSha256 -cnotmatch '^[0-9a-f]{64}$') { Throw-CcodStateError 'CCOD_LIVE_PROBE_INVALID' 'Live probe appAsarSha256 must be lowercase SHA-256' $LiveProbeResult }
    Assert-CcodTcpPort -Value $LiveProbeResult.mainPort -ErrorId 'CCOD_LIVE_PROBE_INVALID' -Name 'live probe mainPort'
    Assert-CcodTcpPort -Value $LiveProbeResult.rendererPort -ErrorId 'CCOD_LIVE_PROBE_INVALID' -Name 'live probe rendererPort'
    if ($LiveProbeResult.mainPort -eq $LiveProbeResult.rendererPort -or $LiveProbeResult.mainProbe -cne 'Closed' -or $LiveProbeResult.rendererProbe -cne 'BridgeValid') { Throw-CcodStateError 'CCOD_LIVE_PROBE_INVALID' 'Live probe ports and probe states are invalid' $LiveProbeResult }
}

function Write-CcodStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)]$Status,
        $LiveProbeResult,
        [hashtable]$Adapters
    )

    $adapters = Get-CcodStateAdapters -Adapters $Adapters
    Assert-CcodStatusShape -Status $Status -Adapters $adapters
    if ($null -ne $Status.session) {
        if ($null -eq $LiveProbeResult) {
            Throw-CcodStateError 'CCOD_LIVE_PROBE_REQUIRED' 'Status may only be rebuilt from a supplied successful live probe result' $LiveProbeResult
        }
        Assert-CcodLiveProbeShape -LiveProbeResult $LiveProbeResult
        if ($LiveProbeResult.runtimeId -cne $Status.session.runtimeId) {
            Throw-CcodStateError 'CCOD_LIVE_PROBE_MISMATCH' 'Live probe does not match status runtimeId' $LiveProbeResult
        }
        if ($null -eq $Status.session.codex) { Throw-CcodStateError 'CCOD_LIVE_PROBE_REQUIRED' 'A non-empty status write requires Codex identity and probe evidence' $Status }
        foreach ($name in @('pid', 'creationTimeUtc', 'packageFullName', 'packageVersion', 'appAsarSha256', 'mainPort', 'rendererPort', 'mainProbe', 'rendererProbe')) {
            if (($LiveProbeResult.$name -is [string] -and $LiveProbeResult.$name -cne $Status.session.codex.$name) -or
                ($LiveProbeResult.$name -isnot [string] -and $LiveProbeResult.$name -ne $Status.session.codex.$name)) {
                Throw-CcodStateError 'CCOD_LIVE_PROBE_MISMATCH' "Live probe does not match status $name" $LiveProbeResult
            }
        }
    }
    Write-CcodTypedState -StateRoot $StateRoot -Leaf 'status.json' -Value $Status -Validator ${function:Assert-CcodStatusShape} -Adapters $adapters
}

function Read-CcodVerifiedPackages {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StateRoot, [hashtable]$Adapters)
    return Read-CcodTypedState -StateRoot $StateRoot -Leaf 'verified-packages.json' -Kind 'verified packages' -Validator ${function:Assert-CcodVerifiedPackagesShape} -Adapters (Get-CcodStateAdapters -Adapters $Adapters)
}

function Write-CcodVerifiedPackages {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StateRoot, [Parameter(Mandatory)]$VerifiedPackages, [hashtable]$Adapters)
    Write-CcodTypedState -StateRoot $StateRoot -Leaf 'verified-packages.json' -Value $VerifiedPackages -Validator ${function:Assert-CcodVerifiedPackagesShape} -Adapters (Get-CcodStateAdapters -Adapters $Adapters)
}

function New-CcodFailedAttemptClearReceipt {
    param([Parameter(Mandatory)][string]$Outcome)

    if (@('Cleared', 'NotFound', 'NotFailed', 'Conflict') -cnotcontains $Outcome) {
        Throw-CcodStateError 'CCOD_FAILED_ATTEMPT_CLEAR_INVALID' 'Failed-attempt clear receipt outcome is invalid' $Outcome
    }
    return [pscustomobject][ordered]@{ Outcome = $Outcome }
}

function Assert-CcodFailedAttemptAdapters {
    param([Parameter(Mandatory)][hashtable]$Adapters)

    foreach ($name in @('BeforeFailedPackageAttemptRecheck', 'WriteAtomicJson')) {
        if ($Adapters[$name] -isnot [scriptblock]) {
            Throw-CcodStateError 'CCOD_FAILED_ATTEMPT_ADAPTER_INVALID' 'Failed package attempt adapter contract is invalid' $null
        }
    }
}

function Invoke-CcodFailedAttemptCallback {
    param(
        [Parameter(Mandatory)][scriptblock]$Callback,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ArgumentList,
        [Parameter(Mandatory)][string]$Stage
    )

    if ($Stage -ceq 'Recheck') {
        $errorId = 'CCOD_FAILED_ATTEMPT_RECHECK_FAILED'
        $message = 'Failed package attempt precommit recheck failed'
    } elseif ($Stage -ceq 'Write') {
        $errorId = 'CCOD_FAILED_ATTEMPT_WRITE_FAILED'
        $message = 'Failed package attempt atomic write failed'
    } else {
        Throw-CcodStateError 'CCOD_FAILED_ATTEMPT_ADAPTER_INVALID' 'Failed package attempt adapter contract is invalid' $null
    }

    try {
        $emitted = @(& $Callback @ArgumentList *>&1)
    } catch {
        Throw-CcodStateError $errorId $message $null
    }
    if ($emitted.Count -ne 0) {
        Throw-CcodStateError $errorId $message $null
    }
}

function Assert-CcodFailedAttemptClearInputs {
    param(
        [AllowNull()]$StateRoot,
        [AllowNull()]$PackageFullName,
        [AllowNull()]$AppAsarSha256,
        [AllowNull()]$RuntimeId,
        [AllowNull()]$ExpectedConfirmedAtUtc
    )

    if ($StateRoot -isnot [string] -or [string]::IsNullOrWhiteSpace($StateRoot) -or -not [IO.Path]::IsPathRooted($StateRoot)) {
        Throw-CcodStateError 'CCOD_FAILED_ATTEMPT_CLEAR_INVALID' 'StateRoot must be an absolute canonical string' $StateRoot
    }
    try { $canonicalRoot = [IO.Path]::GetFullPath($StateRoot) } catch {
        Throw-CcodStateError 'CCOD_FAILED_ATTEMPT_CLEAR_INVALID' 'StateRoot must be an absolute canonical string' $StateRoot
    }
    if ($canonicalRoot -cne $StateRoot -or -not [IO.Directory]::Exists($canonicalRoot)) {
        Throw-CcodStateError 'CCOD_FAILED_ATTEMPT_CLEAR_INVALID' 'StateRoot must name an existing canonical directory' $StateRoot
    }
    if ($PackageFullName -isnot [string] -or [string]::IsNullOrWhiteSpace($PackageFullName) -or $PackageFullName.IndexOf('|') -ge 0) {
        Throw-CcodStateError 'CCOD_FAILED_ATTEMPT_CLEAR_INVALID' 'PackageFullName must be an exact non-empty package identity without delimiters' $PackageFullName
    }
    if ($AppAsarSha256 -isnot [string] -or $AppAsarSha256 -cnotmatch '^[0-9a-f]{64}$') {
        Throw-CcodStateError 'CCOD_FAILED_ATTEMPT_CLEAR_INVALID' 'AppAsarSha256 must be an exact lowercase SHA-256 string' $AppAsarSha256
    }
    if ($RuntimeId -isnot [string] -or $RuntimeId -cnotmatch '^[A-Za-z0-9._-]{1,96}$') {
        Throw-CcodStateError 'CCOD_FAILED_ATTEMPT_CLEAR_INVALID' 'RuntimeId must be a Task 1-safe runtime ID' $RuntimeId
    }
    if ($ExpectedConfirmedAtUtc -isnot [string]) {
        Throw-CcodStateError 'CCOD_FAILED_ATTEMPT_CLEAR_INVALID' 'ExpectedConfirmedAtUtc must be an exact canonical UTC timestamp string' $ExpectedConfirmedAtUtc
    }
    Assert-CcodUtcTimestamp -Value $ExpectedConfirmedAtUtc -ErrorId 'CCOD_FAILED_ATTEMPT_CLEAR_INVALID' -Name 'ExpectedConfirmedAtUtc'
    return $canonicalRoot
}

function Get-CcodExactStateEntry {
    param([Parameter(Mandatory)]$Container, [Parameter(Mandatory)][string]$Name)

    if ($Container -is [Collections.IDictionary]) {
        foreach ($key in $Container.Keys) {
            if ([string]$key -ceq $Name) {
                return [pscustomobject]@{ Exists = $true; Value = $Container[$key] }
            }
        }
    } else {
        foreach ($property in $Container.PSObject.Properties) {
            if ($property.Name -ceq $Name) {
                return [pscustomobject]@{ Exists = $true; Value = $property.Value }
            }
        }
    }
    return [pscustomobject]@{ Exists = $false; Value = $null }
}

function Test-CcodFailedAttemptIdentity {
    param(
        [Parameter(Mandatory)]$Record,
        [Parameter(Mandatory)][string]$PackageFullName,
        [Parameter(Mandatory)][string]$AppAsarSha256,
        [Parameter(Mandatory)][string]$RuntimeId
    )

    return $Record.packageFullName -is [string] -and $Record.packageFullName -ceq $PackageFullName -and
        $Record.appAsarSha256 -is [string] -and $Record.appAsarSha256 -ceq $AppAsarSha256 -and
        $Record.runtimeId -is [string] -and $Record.runtimeId -ceq $RuntimeId
}

function New-CcodVerifiedPackagesWithoutKey {
    param([Parameter(Mandatory)]$VerifiedPackages, [Parameter(Mandatory)][string]$SuppressionKey, [hashtable]$Adapters)

    $packages = [ordered]@{}
    foreach ($name in Get-CcodStatePropertyNames -Value $VerifiedPackages.packages) {
        if ($name -cne $SuppressionKey) {
            $entry = Get-CcodExactStateEntry -Container $VerifiedPackages.packages -Name $name
            $packages[$name] = $entry.Value
        }
    }
    $result = [pscustomobject][ordered]@{ schemaVersion = 1; packages = $packages }
    Assert-CcodVerifiedPackagesShape -VerifiedPackages $result -Adapters $Adapters
    return $result
}

function Clear-CcodFailedPackageAttempt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()]$StateRoot,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()]$PackageFullName,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()]$AppAsarSha256,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()]$RuntimeId,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()]$ExpectedConfirmedAtUtc,
        [AllowNull()]$Adapters
    )

    $canonicalRoot = Assert-CcodFailedAttemptClearInputs -StateRoot $StateRoot -PackageFullName $PackageFullName -AppAsarSha256 $AppAsarSha256 -RuntimeId $RuntimeId -ExpectedConfirmedAtUtc $ExpectedConfirmedAtUtc
    if ($null -ne $Adapters -and $Adapters -isnot [hashtable]) {
        Throw-CcodStateError 'CCOD_FAILED_ATTEMPT_ADAPTER_INVALID' 'Failed package attempt adapter contract is invalid' $null
    }
    $adapters = Get-CcodStateAdapters -Adapters $Adapters
    Assert-CcodFailedAttemptAdapters -Adapters $adapters
    $path = Get-CcodStatePath -StateRoot $canonicalRoot -Leaf 'verified-packages.json'
    $suppressionKey = Get-CcodSuppressionKey -PackageFullName $PackageFullName -AppAsarSha256 $AppAsarSha256 -RuntimeId $RuntimeId

    $initial = Read-CcodVerifiedPackages -StateRoot $canonicalRoot -Adapters $adapters
    $initialEntry = Get-CcodExactStateEntry -Container $initial.packages -Name $suppressionKey
    if (-not $initialEntry.Exists) { return New-CcodFailedAttemptClearReceipt -Outcome 'NotFound' }
    if (-not (Test-CcodFailedAttemptIdentity -Record $initialEntry.Value -PackageFullName $PackageFullName -AppAsarSha256 $AppAsarSha256 -RuntimeId $RuntimeId)) {
        Throw-CcodStateError 'CCOD_VERIFIED_PACKAGES_INVALID' 'Verified package record identity does not match its exact suppression key' $initialEntry.Value
    }
    if ($initialEntry.Value.dynamicOutcome -cne 'Failed') { return New-CcodFailedAttemptClearReceipt -Outcome 'NotFailed' }
    if ($initialEntry.Value.confirmedAtUtc -cne $ExpectedConfirmedAtUtc) { return New-CcodFailedAttemptClearReceipt -Outcome 'Conflict' }

    $initialSnapshot = $initial | ConvertTo-Json -Depth 16 -Compress
    $updated = New-CcodVerifiedPackagesWithoutKey -VerifiedPackages $initial -SuppressionKey $suppressionKey -Adapters $adapters
    Invoke-CcodFailedAttemptCallback -Callback $adapters.BeforeFailedPackageAttemptRecheck -ArgumentList @($path, $suppressionKey) -Stage 'Recheck'

    $current = Read-CcodVerifiedPackages -StateRoot $canonicalRoot -Adapters $adapters
    $currentEntry = Get-CcodExactStateEntry -Container $current.packages -Name $suppressionKey
    if (-not $currentEntry.Exists -or
        -not (Test-CcodFailedAttemptIdentity -Record $currentEntry.Value -PackageFullName $PackageFullName -AppAsarSha256 $AppAsarSha256 -RuntimeId $RuntimeId) -or
        $currentEntry.Value.confirmedAtUtc -cne $ExpectedConfirmedAtUtc -or
        $currentEntry.Value.dynamicOutcome -cne 'Failed') {
        return New-CcodFailedAttemptClearReceipt -Outcome 'Conflict'
    }
    if (($current | ConvertTo-Json -Depth 16 -Compress) -cne $initialSnapshot) {
        return New-CcodFailedAttemptClearReceipt -Outcome 'Conflict'
    }

    Invoke-CcodFailedAttemptCallback -Callback $adapters.WriteAtomicJson -ArgumentList @($path, $updated) -Stage 'Write'
    return New-CcodFailedAttemptClearReceipt -Outcome 'Cleared'
}

function Read-CcodStatePart {
    param(
        [Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)][string]$Leaf,
        [Parameter(Mandatory)][scriptblock]$Reader,
        [Parameter(Mandatory)][hashtable]$Adapters,
        [Parameter(Mandatory)][hashtable]$Damage
    )

    try {
        return (& $Reader)
    } catch {
        $Damage[$Leaf] = (($_.FullyQualifiedErrorId -split ',')[0])
        $path = Get-CcodStatePath -StateRoot $StateRoot -Leaf $Leaf
        if ([IO.File]::Exists($path)) {
            Move-CcodCorruptState -Path $path -Reason $Damage[$Leaf] -Root $StateRoot -Adapters $Adapters | Out-Null
        }
        return $null
    }
}

function Read-CcodState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StateRoot, [string]$CurrentSuppressionKey, [hashtable]$Adapters)

    $adapters = Get-CcodStateAdapters -Adapters $Adapters
    $damage = @{}
    $settings = Read-CcodStatePart -StateRoot $StateRoot -Leaf 'settings.json' -Reader { Read-CcodSettings -StateRoot $StateRoot -Adapters $adapters } -Adapters $adapters -Damage $damage
    $status = Read-CcodStatePart -StateRoot $StateRoot -Leaf 'status.json' -Reader { Read-CcodStatus -StateRoot $StateRoot -Adapters $adapters } -Adapters $adapters -Damage $damage
    $verified = Read-CcodStatePart -StateRoot $StateRoot -Leaf 'verified-packages.json' -Reader { Read-CcodVerifiedPackages -StateRoot $StateRoot -Adapters $adapters } -Adapters $adapters -Damage $damage
    $transition = Read-CcodStatePart -StateRoot $StateRoot -Leaf 'transition.json' -Reader { Read-CcodTypedState -StateRoot $StateRoot -Leaf 'transition.json' -Kind 'transition' -Validator ${function:Assert-CcodTransitionShape} -Adapters $adapters } -Adapters $adapters -Damage $damage

    $automationEnabled = $null -ne $settings -and $settings.automationEnabled -eq $true -and -not $damage.ContainsKey('transition.json')
    $statusNeedsRebuild = $null -eq $status
    $suppressionKeyValid = -not [string]::IsNullOrWhiteSpace($CurrentSuppressionKey) -and $CurrentSuppressionKey -cmatch '^[^|]+\|[^|]+\|[^|]+$'
    $alreadyAttempted = $suppressionKeyValid -and $null -ne $verified -and (Test-CcodStateProperty -Value $verified.packages -Name $CurrentSuppressionKey)
    $candidateTrialsAllowed = $automationEnabled -and $settings.candidateCompatibleOptIn -eq $true -and $null -ne $verified -and -not $statusNeedsRebuild -and $suppressionKeyValid -and -not $alreadyAttempted
    $transitionActionsAllowed = $null -ne $transition
    return [pscustomobject]@{
        Settings = $settings
        Status = $status
        VerifiedPackages = $verified
        Transition = $transition
        AutomationEnabled = [bool]$automationEnabled
        AutomaticCandidateTrialsAllowed = [bool]$candidateTrialsAllowed
        TransitionActionsAllowed = [bool]$transitionActionsAllowed
        StatusRebuildRequired = [bool]$statusNeedsRebuild
        Damage = [pscustomobject]$damage
    }
}

function Set-CcodAutomationEnabled {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StateRoot, [Parameter(Mandatory)][bool]$Enabled, [hashtable]$Adapters)

    $adapters = Get-CcodStateAdapters -Adapters $Adapters
    $settings = Read-CcodSettings -StateRoot $StateRoot -Adapters $adapters
    Write-CcodSettings -StateRoot $StateRoot -Settings (New-CcodSettings -NodeCandidates @($settings.nodeCandidates) -CandidateCompatibleOptIn $settings.candidateCompatibleOptIn -AutomationEnabled $Enabled -UpdatedAtUtc (Get-CcodStateTimestamp -Adapters $adapters)) -Adapters $adapters
}

function Set-CcodCandidateCompatibleOptIn {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StateRoot, [Parameter(Mandatory)][bool]$Enabled, [hashtable]$Adapters)

    $adapters = Get-CcodStateAdapters -Adapters $Adapters
    $settings = Read-CcodSettings -StateRoot $StateRoot -Adapters $adapters
    Write-CcodSettings -StateRoot $StateRoot -Settings (New-CcodSettings -NodeCandidates @($settings.nodeCandidates) -CandidateCompatibleOptIn $Enabled -AutomationEnabled $settings.automationEnabled -UpdatedAtUtc (Get-CcodStateTimestamp -Adapters $adapters)) -Adapters $adapters
}

function Repair-CcodState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StateRoot, [hashtable]$Adapters)

    $adapters = Get-CcodStateAdapters -Adapters $Adapters
    [IO.Directory]::CreateDirectory($StateRoot) | Out-Null
    foreach ($leaf in @('settings.json', 'status.json', 'verified-packages.json', 'transition.json')) {
        $path = Get-CcodStatePath -StateRoot $StateRoot -Leaf $leaf
        if ([IO.File]::Exists($path)) {
            Move-CcodCorruptState -Path $path -Reason 'explicit repair' -Root $StateRoot -Adapters $adapters | Out-Null
        }
    }
    Write-CcodSettings -StateRoot $StateRoot -Settings (New-CcodSettings -NodeCandidates @() -CandidateCompatibleOptIn $false -AutomationEnabled $false -UpdatedAtUtc (Get-CcodStateTimestamp -Adapters $adapters)) -Adapters $adapters
    Write-CcodTypedState -StateRoot $StateRoot -Leaf 'status.json' -Value (New-CcodStatusStore) -Validator ${function:Assert-CcodStatusShape} -Adapters $adapters
    Write-CcodVerifiedPackages -StateRoot $StateRoot -VerifiedPackages (New-CcodVerifiedPackagesStore) -Adapters $adapters
    Write-CcodTypedState -StateRoot $StateRoot -Leaf 'transition.json' -Value (New-CcodTransitionStore) -Validator ${function:Assert-CcodTransitionShape} -Adapters $adapters
}

function Get-CcodAttemptKey([int]$Pid, [string]$CreationTimeUtc) { '{0}|{1}' -f $Pid, $CreationTimeUtc }
function Get-CcodRecoveryIgnoreKey([int]$Pid, [string]$CreationTimeUtc, [string]$TransactionId) { '{0}|{1}|{2}' -f $Pid, $CreationTimeUtc, $TransactionId }
function Get-CcodSuppressionKey([string]$PackageFullName, [string]$AppAsarSha256, [string]$RuntimeId) { '{0}|{1}|{2}' -f $PackageFullName, $AppAsarSha256, $RuntimeId }
function Get-CcodStaticKey([string]$PackageFullName, [string]$AppAsarSha256) { '{0}|{1}' -f $PackageFullName, $AppAsarSha256 }

function Resolve-CcodDeviceKeyStorePath {
    [CmdletBinding()]
    param()

    $codexHome = [Environment]::GetEnvironmentVariable('CODEX_HOME', 'Process')
    if ([string]::IsNullOrWhiteSpace($codexHome)) {
        $codexHome = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex'
    } elseif (-not [IO.Path]::IsPathRooted($codexHome)) {
        Throw-CcodStateError 'CCOD_CODEX_HOME_INVALID' 'CODEX_HOME must be an absolute path' $codexHome
    }
    return (Join-Path $codexHome 'remote-control-device-keys.windows.json')
}

Export-ModuleMember -Function Initialize-CcodState, Read-CcodState, Repair-CcodState, Read-CcodSettings, Write-CcodSettings, Read-CcodStatus, Write-CcodStatus, Read-CcodVerifiedPackages, Write-CcodVerifiedPackages, Clear-CcodFailedPackageAttempt, Set-CcodAutomationEnabled, Set-CcodCandidateCompatibleOptIn, Get-CcodAttemptKey, Get-CcodRecoveryIgnoreKey, Get-CcodSuppressionKey, Get-CcodStaticKey, Resolve-CcodDeviceKeyStorePath
