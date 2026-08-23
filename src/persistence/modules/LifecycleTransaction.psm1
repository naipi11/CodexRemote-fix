Set-StrictMode -Version 2.0

Import-Module (Join-Path $PSScriptRoot 'PersistenceIO.psm1') -Force

$script:CcodLifecycleKinds = @('RestartAndRepair','CheckAndRepair','SafeExit')
$script:CcodLifecycleOrigins = @('Installer','Tray','ExplicitStart','Guardian')
$script:CcodLifecycleTransitions = [ordered]@{
    Requested = @('CloseRequested','SupersededByUpgrade','CancelledBeforeClose')
    CloseRequested = @('CloseConfirmed','CloseFailed')
    CloseConfirmed = @('OrdinaryLaunchRequested','RepairRequested')
    OrdinaryLaunchRequested = @('OrdinaryObserved','WaitingForManualLaunch','OrdinaryLaunchFailed','OrdinaryObservationTimedOut')
    WaitingForManualLaunch = @('OrdinaryObserved','LaunchWindowExpired')
    OrdinaryObserved = @('RepairRequested')
    RepairRequested = @('RemoteVerified','RepairFailed','VerificationFailed')
    RemoteVerified = @('Completed')
}
$script:CcodLifecycleTerminal = @(
    'Completed','CloseFailed','OrdinaryLaunchFailed','OrdinaryObservationTimedOut','LaunchWindowExpired','RepairFailed',
    'VerificationFailed','CancelledBeforeClose','SupersededByUpgrade'
)
$script:CcodLifecycleRequestProperties = @(
    'schemaVersion','transactionId','kind','origin','runtimeId','runtimeGeneration','leaseEpoch','ownerIdentity','logonIdentity','phase',
    'createdAtUtc','updatedAtUtc','launchRequestedAtUtc','manualLaunchExpiresAtUtc','automaticLaunchAttempts','error'
)

function Throw-CcodLifecycleError {
    param([string]$Id, [string]$Message, $TargetObject)

    throw [Management.Automation.ErrorRecord]::new(
        [InvalidOperationException]::new($Message), $Id, [Management.Automation.ErrorCategory]::InvalidData, $TargetObject)
}

function Get-CcodLifecycleMutexName {
    param([Parameter(Mandatory)][string]$StateRoot)

    try {
        $canonicalRoot = [IO.Path]::GetFullPath($StateRoot).ToLowerInvariant()
    } catch {
        Throw-CcodLifecycleError 'CCOD_LIFECYCLE_STATE_INVALID' 'Lifecycle state root is invalid' $StateRoot
    }
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = [BitConverter]::ToString($sha256.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonicalRoot))).Replace('-', '').ToLowerInvariant()
        return 'Local\CcodLifecycleTransaction-' + $hash
    } finally {
        $sha256.Dispose()
    }
}

function Invoke-CcodLifecycleExclusive {
    param([Parameter(Mandatory)][string]$StateRoot, [Parameter(Mandatory)][scriptblock]$Action)

    $mutex = [Threading.Mutex]::new($false, (Get-CcodLifecycleMutexName -StateRoot $StateRoot))
    $entered = $false
    try {
        try {
            $entered = $mutex.WaitOne(30000)
        } catch [Threading.AbandonedMutexException] {
            $entered = $true
        }
        if (-not $entered) {
            Throw-CcodLifecycleError 'CCOD_LIFECYCLE_LOCK_TIMEOUT' 'Lifecycle transaction lock could not be acquired' $StateRoot
        }
        return (& $Action)
    } finally {
        if ($entered) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Get-CcodLifecyclePropertyNames {
    param([Parameter(Mandatory)]$Value)

    if ($Value -is [Collections.IDictionary]) { return @($Value.Keys | ForEach-Object { [string]$_ }) }
    return @($Value.PSObject.Properties | ForEach-Object { $_.Name })
}

function Assert-CcodLifecycleExactProperties {
    param([Parameter(Mandatory)]$Value, [Parameter(Mandatory)][string[]]$Expected, [Parameter(Mandatory)][string]$Kind)

    if ($Value -isnot [pscustomobject] -and $Value -isnot [Collections.IDictionary]) {
        Throw-CcodLifecycleError 'CCOD_LIFECYCLE_STATE_INVALID' "$Kind must be an object" $Value
    }
    $actual = @(Get-CcodLifecyclePropertyNames -Value $Value)
    if ($actual.Count -ne $Expected.Count -or ($actual -join "`0") -cne ($Expected -join "`0")) {
        Throw-CcodLifecycleError 'CCOD_LIFECYCLE_STATE_INVALID' "$Kind has unexpected, missing, or reordered fields" $Value
    }
    foreach ($property in @($Value.PSObject.Properties)) {
        if ($property.MemberType -notin @('NoteProperty', 'Property')) {
            Throw-CcodLifecycleError 'CCOD_LIFECYCLE_STATE_INVALID' "$Kind contains a non-data property" $Value
        }
    }
}

function Assert-CcodLifecycleUtcTimestamp {
    param([Parameter(Mandatory)]$Value, [Parameter(Mandatory)][string]$Name)

    if ($Value -isnot [string]) { Throw-CcodLifecycleError 'CCOD_LIFECYCLE_STATE_INVALID' "$Name must be a canonical UTC timestamp" $Value }
    $parsed = [DateTime]::MinValue
    if (-not [DateTime]::TryParseExact($Value, 'o', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed) -or
        $parsed.Kind -ne [DateTimeKind]::Utc -or $parsed.ToUniversalTime().ToString('o') -cne $Value) {
        Throw-CcodLifecycleError 'CCOD_LIFECYCLE_STATE_INVALID' "$Name must be a canonical UTC timestamp" $Value
    }
    return $parsed
}

function Assert-CcodLifecycleCanonicalGuid {
    param([Parameter(Mandatory)]$Value)

    $parsed = [guid]::Empty
    if ($Value -isnot [string] -or -not [guid]::TryParseExact($Value, 'D', [ref]$parsed) -or $parsed.ToString('D') -cne $Value) {
        Throw-CcodLifecycleError 'CCOD_LIFECYCLE_STATE_INVALID' 'transactionId must be a canonical lowercase GUID in D form' $Value
    }
}

function Assert-CcodLifecycleUnsignedInteger {
    param([Parameter(Mandatory)]$Value, [Parameter(Mandatory)][string]$Name, [switch]$AllowZero)

    if ($Value -isnot [byte] -and $Value -isnot [uint16] -and $Value -isnot [uint32] -and $Value -isnot [uint64] -and
        $Value -isnot [int16] -and $Value -isnot [int32] -and $Value -isnot [int64]) {
        Throw-CcodLifecycleError 'CCOD_LIFECYCLE_STATE_INVALID' "$Name must be an unsigned integer" $Value
    }
    if ($Value -lt 0 -or (-not $AllowZero -and $Value -eq 0)) {
        Throw-CcodLifecycleError 'CCOD_LIFECYCLE_STATE_INVALID' "$Name must be a positive unsigned integer" $Value
    }
}

function Assert-CcodLifecycleOwnerIdentity {
    param([Parameter(Mandatory)]$OwnerIdentity)

    Assert-CcodLifecycleExactProperties -Value $OwnerIdentity -Expected @('pid','creationTimeUtc') -Kind 'Lifecycle owner identity'
    Assert-CcodLifecycleUnsignedInteger -Value $OwnerIdentity.pid -Name 'ownerIdentity.pid'
    if ($OwnerIdentity.pid -gt [int]::MaxValue) { Throw-CcodLifecycleError 'CCOD_LIFECYCLE_STATE_INVALID' 'ownerIdentity.pid exceeds the legal process range' $OwnerIdentity }
    [void](Assert-CcodLifecycleUtcTimestamp -Value $OwnerIdentity.creationTimeUtc -Name 'ownerIdentity.creationTimeUtc')
}

function Assert-CcodLifecycleLogonIdentity {
    param([Parameter(Mandatory)]$LogonIdentity)

    Assert-CcodLifecycleExactProperties -Value $LogonIdentity -Expected @('authenticationId','userSid','sessionId') -Kind 'Lifecycle logon identity'
    if ($LogonIdentity.authenticationId -isnot [string] -or $LogonIdentity.authenticationId -cnotmatch '^[0-9A-F]{8}:[0-9A-F]{8}$') {
        Throw-CcodLifecycleError 'CCOD_LIFECYCLE_STATE_INVALID' 'logonIdentity.authenticationId must be a canonical LUID' $LogonIdentity
    }
    if ($LogonIdentity.userSid -isnot [string] -or $LogonIdentity.userSid -cnotmatch '^S-\d-\d+(?:-\d+)+$') {
        Throw-CcodLifecycleError 'CCOD_LIFECYCLE_STATE_INVALID' 'logonIdentity.userSid must be a canonical SID' $LogonIdentity
    }
    Assert-CcodLifecycleUnsignedInteger -Value $LogonIdentity.sessionId -Name 'logonIdentity.sessionId' -AllowZero
}

function Test-CcodLifecyclePhase {
    param([Parameter(Mandatory)][string]$Phase)

    return $script:CcodLifecycleTransitions.Contains($Phase) -or $script:CcodLifecycleTerminal -ccontains $Phase
}

function Assert-CcodLifecycleRequest {
    param([Parameter(Mandatory)]$Request)

    Assert-CcodLifecycleExactProperties -Value $Request -Expected $script:CcodLifecycleRequestProperties -Kind 'Lifecycle request'
    if ($Request.schemaVersion -isnot [int] -and $Request.schemaVersion -isnot [long] -or $Request.schemaVersion -ne 1) {
        Throw-CcodLifecycleError 'CCOD_LIFECYCLE_STATE_INVALID' 'Lifecycle request schemaVersion must be integer 1' $Request
    }
    Assert-CcodLifecycleCanonicalGuid -Value $Request.transactionId
    if ($Request.kind -isnot [string] -or $script:CcodLifecycleKinds -cnotcontains $Request.kind -or
        $Request.origin -isnot [string] -or $script:CcodLifecycleOrigins -cnotcontains $Request.origin) {
        Throw-CcodLifecycleError 'CCOD_LIFECYCLE_STATE_INVALID' 'Lifecycle request kind or origin is invalid' $Request
    }
    if ($Request.runtimeId -isnot [string] -or $Request.runtimeId -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$') {
        Throw-CcodLifecycleError 'CCOD_LIFECYCLE_STATE_INVALID' 'Lifecycle request runtimeId is invalid' $Request
    }
    Assert-CcodLifecycleUnsignedInteger -Value $Request.runtimeGeneration -Name 'runtimeGeneration'
    Assert-CcodLifecycleUnsignedInteger -Value $Request.leaseEpoch -Name 'leaseEpoch'
    Assert-CcodLifecycleOwnerIdentity -OwnerIdentity $Request.ownerIdentity
    Assert-CcodLifecycleLogonIdentity -LogonIdentity $Request.logonIdentity
    if ($Request.phase -isnot [string] -or -not (Test-CcodLifecyclePhase -Phase $Request.phase)) {
        Throw-CcodLifecycleError 'CCOD_LIFECYCLE_STATE_INVALID' 'Lifecycle request phase is invalid' $Request
    }
    $created = Assert-CcodLifecycleUtcTimestamp -Value $Request.createdAtUtc -Name 'createdAtUtc'
    $updated = Assert-CcodLifecycleUtcTimestamp -Value $Request.updatedAtUtc -Name 'updatedAtUtc'
    if ($updated -lt $created) { Throw-CcodLifecycleError 'CCOD_LIFECYCLE_STATE_INVALID' 'updatedAtUtc cannot precede createdAtUtc' $Request }
    foreach ($name in @('launchRequestedAtUtc','manualLaunchExpiresAtUtc')) {
        if ($null -ne $Request.$name) { [void](Assert-CcodLifecycleUtcTimestamp -Value $Request.$name -Name $name) }
    }
    Assert-CcodLifecycleUnsignedInteger -Value $Request.automaticLaunchAttempts -Name 'automaticLaunchAttempts' -AllowZero
    if ($null -ne $Request.error -and ($Request.error -isnot [string] -or $Request.error -cnotmatch '^[A-Z][A-Z0-9_]{0,127}$')) {
        Throw-CcodLifecycleError 'CCOD_LIFECYCLE_STATE_INVALID' 'Lifecycle request error must be null or a stable code' $Request
    }
}

function New-CcodLifecycleRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('RestartAndRepair','CheckAndRepair','SafeExit')][string]$Kind,
        [Parameter(Mandatory)][ValidateSet('Installer','Tray','ExplicitStart','Guardian')][string]$Origin,
        [Parameter(Mandatory)][string]$RuntimeId,
        [Parameter(Mandatory)][UInt64]$RuntimeGeneration,
        [Parameter(Mandatory)][UInt64]$LeaseEpoch,
        [Parameter(Mandatory)]$OwnerIdentity,
        [Parameter(Mandatory)]$LogonIdentity,
        [Parameter(Mandatory)][string]$NowUtc,
        [string]$TransactionId = ([guid]::NewGuid().ToString('D'))
    )
    $request = [pscustomobject][ordered]@{
        schemaVersion=1; transactionId=$TransactionId; kind=$Kind; origin=$Origin
        runtimeId=$RuntimeId; runtimeGeneration=$RuntimeGeneration; leaseEpoch=$LeaseEpoch
        ownerIdentity=$OwnerIdentity; logonIdentity=$LogonIdentity; phase='Requested'
        createdAtUtc=$NowUtc; updatedAtUtc=$NowUtc; launchRequestedAtUtc=$null
        manualLaunchExpiresAtUtc=$null; automaticLaunchAttempts=0; error=$null
    }
    Assert-CcodLifecycleRequest -Request $request
    return $request
}

function Get-CcodLifecycleRequestPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StateRoot)

    return (Resolve-CcodContainedPath -Root $StateRoot -RelativePath 'lifecycle\active-request.json' -AllowMissingLeaf)
}

function Get-CcodLifecycleReceiptPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StateRoot, [Parameter(Mandatory)][string]$TransactionId)

    Assert-CcodLifecycleCanonicalGuid -Value $TransactionId
    return (Resolve-CcodContainedPath -Root $StateRoot -RelativePath ('lifecycle\receipts\' + $TransactionId + '.json') -AllowMissingLeaf)
}

function Read-CcodLifecycleRequest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StateRoot)

    $path = Get-CcodLifecycleRequestPath -StateRoot $StateRoot
    try {
        $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
    } catch [Management.Automation.ItemNotFoundException] {
        return $null
    } catch {
        Throw-CcodLifecycleError 'CCOD_LIFECYCLE_STATE_INVALID' 'Lifecycle request state is invalid' $path
    }
    if ($item.PSIsContainer -or $item -isnot [IO.FileInfo]) {
        Throw-CcodLifecycleError 'CCOD_LIFECYCLE_STATE_INVALID' 'Lifecycle request state is invalid' $path
    }
    try {
        $request = Read-CcodStrictJson -Path $path -ExpectedSchema 1 -Kind 'lifecycle request'
        Assert-CcodLifecycleRequest -Request $request
        return $request
    } catch {
        Throw-CcodLifecycleError 'CCOD_LIFECYCLE_STATE_INVALID' 'Lifecycle request state is invalid' $path
    }
}

function Write-CcodLifecycleRequest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StateRoot, [Parameter(Mandatory)]$Request)

    Assert-CcodLifecycleRequest -Request $Request
    [IO.Directory]::CreateDirectory($StateRoot) | Out-Null
    Invoke-CcodLifecycleExclusive -StateRoot $StateRoot -Action {
        Write-CcodAtomicJson -Path (Get-CcodLifecycleRequestPath -StateRoot $StateRoot) -Value $Request
    }
}

function Move-CcodLifecyclePhase {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Request,
        [Parameter(Mandatory)][string]$NextPhase,
        [Parameter(Mandatory)][string]$NowUtc
    )

    Assert-CcodLifecycleRequest -Request $Request
    [void](Assert-CcodLifecycleUtcTimestamp -Value $NowUtc -Name 'NowUtc')
    if ($script:CcodLifecycleTerminal -ccontains $Request.phase -or -not $script:CcodLifecycleTransitions.Contains($Request.phase) -or
        $script:CcodLifecycleTransitions[$Request.phase] -cnotcontains $NextPhase) {
        Throw-CcodLifecycleError 'CCOD_LIFECYCLE_PHASE_INVALID' 'Lifecycle phase transition is not allowed' $Request
    }
    $clone = $Request | ConvertTo-Json -Depth 16 | ConvertFrom-Json
    $clone.phase = $NextPhase
    $clone.updatedAtUtc = $NowUtc
    Assert-CcodLifecycleRequest -Request $clone
    return $clone
}

function Complete-CcodLifecycleRequest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StateRoot, [Parameter(Mandatory)]$Request)

    Assert-CcodLifecycleRequest -Request $Request
    if ($script:CcodLifecycleTerminal -cnotcontains $Request.phase) {
        Throw-CcodLifecycleError 'CCOD_LIFECYCLE_STATE_INVALID' 'Only a terminal lifecycle request may be completed' $Request
    }
    [IO.Directory]::CreateDirectory($StateRoot) | Out-Null
    Invoke-CcodLifecycleExclusive -StateRoot $StateRoot -Action {
        $active = Read-CcodLifecycleRequest -StateRoot $StateRoot
        if ($null -eq $active -or $active.transactionId -cne $Request.transactionId) {
            Throw-CcodLifecycleError 'CCOD_LIFECYCLE_STATE_INVALID' 'Lifecycle completion does not match the active request' $Request
        }
        $receiptPath = Get-CcodLifecycleReceiptPath -StateRoot $StateRoot -TransactionId $Request.transactionId
        Write-CcodAtomicJson -Path $receiptPath -Value $Request
        $current = Read-CcodLifecycleRequest -StateRoot $StateRoot
        if ($null -eq $current -or $current.transactionId -cne $Request.transactionId) {
            if ([IO.File]::Exists($receiptPath)) { [IO.File]::Delete($receiptPath) }
            Throw-CcodLifecycleError 'CCOD_LIFECYCLE_STATE_INVALID' 'Lifecycle completion no longer matches the active request' $Request
        }
        [IO.File]::Delete((Get-CcodLifecycleRequestPath -StateRoot $StateRoot))
    }
}

Export-ModuleMember -Function New-CcodLifecycleRequest, Read-CcodLifecycleRequest, Write-CcodLifecycleRequest, Move-CcodLifecyclePhase, Complete-CcodLifecycleRequest, Get-CcodLifecycleRequestPath, Get-CcodLifecycleReceiptPath
