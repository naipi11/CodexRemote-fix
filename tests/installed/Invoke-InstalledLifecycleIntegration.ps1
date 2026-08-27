[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Run')][string]$InstallerPath,
    [Parameter(ParameterSetName = 'Run')][string]$PreviousInstallerPath,
    [Parameter(Mandatory, ParameterSetName = 'Run')][ValidatePattern('^\d+\.\d+\.\d+$')][string]$ExpectedVersion,
    [Parameter(Mandatory, ParameterSetName = 'Run')][string]$EvidenceRoot,
    [Parameter(ParameterSetName = 'Run')][switch]$AllowMachineMutation,
    [Parameter(ParameterSetName = 'Run')][switch]$AllowCodexRestart,
    [Parameter(Mandatory, ParameterSetName = 'Run')][ValidateSet('FreshLater','FreshRestart','Upgrade','SlowLaunch','ManualLaunchResume','LanguageStress','RepairStates','SafeExit','SettingsUninstall','DirectUninstall')][string]$Scenario,
    [Parameter(Mandatory, ParameterSetName = 'Library')][switch]$Library
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:CcodInstalledLifecycleRestartScenarios = @(
    'FreshRestart','Upgrade','SlowLaunch','ManualLaunchResume','LanguageStress','RepairStates','SafeExit','SettingsUninstall','DirectUninstall'
)
$script:CcodInstalledLifecycleTaskName = 'Codex Control Other Devices Supervisor'
$script:CcodInstalledLifecycleRepositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$script:CcodInstalledLifecyclePersistenceIoModule = Import-Module (Join-Path $script:CcodInstalledLifecycleRepositoryRoot 'src\persistence\modules\PersistenceIO.psm1') -Force -PassThru
$script:CcodInstalledLifecycleStateStoreModule = Import-Module (Join-Path $script:CcodInstalledLifecycleRepositoryRoot 'src\persistence\modules\StateStore.psm1') -Force -PassThru
$script:CcodInstalledLifecycleTransactionModule = Import-Module (Join-Path $script:CcodInstalledLifecycleRepositoryRoot 'src\persistence\modules\LifecycleTransaction.psm1') -Force -PassThru

function Throw-CcodInstalledLifecycleError {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Message,
        $Target
    )
    throw [Management.Automation.ErrorRecord]::new(
        [InvalidOperationException]::new($Message),
        $Id,
        [Management.Automation.ErrorCategory]::InvalidOperation,
        $Target
    )
}

function Get-CcodInstalledLifecycleErrorId {
    param([Parameter(Mandatory)]$ErrorRecord)
    $id = [string]$ErrorRecord.FullyQualifiedErrorId
    if ([string]::IsNullOrWhiteSpace($id)) { return $null }
    return ($id -split ',')[0]
}

function Get-CcodInstalledLifecycleHash {
    param([Parameter(Mandatory)][string]$Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $stream = [IO.File]::OpenRead($Path)
        try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
        finally { $stream.Dispose() }
    } finally { $sha.Dispose() }
}

function Test-CcodInstalledLifecycleCanonicalUtc {
    param([AllowNull()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    $parsed = [datetime]::MinValue
    if (-not [datetime]::TryParse($Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) { return $false }
    return $parsed.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture) -ceq $Value
}

function Assert-CcodInstalledLifecycleRegularFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Kind)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathRooted($Path)) {
        Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_CANDIDATE_INVALID' "$Kind must be an absolute path" $Path
    }
    $full = [IO.Path]::GetFullPath($Path)
    if (-not [IO.File]::Exists($full)) {
        Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_CANDIDATE_INVALID' "$Kind is missing" $full
    }
    $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_CANDIDATE_INVALID' "$Kind must be a regular non-reparse file" $full
    }
    return $full
}

function Assert-CcodInstalledLifecycleSafeDirectory {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Kind)
    $full = [IO.Path]::GetFullPath($Path)
    if (-not [IO.Directory]::Exists($full)) { [IO.Directory]::CreateDirectory($full) | Out-Null }
    $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    if (-not $item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_EVIDENCE_ROOT_INVALID' "$Kind must be a non-reparse directory" $full
    }
    return $full
}

function Get-CcodInstalledLifecycleDefaultAdapters {
    $defaults = @{}
    $defaults.GetGitStatus = {
        param($RepositoryRoot)
        $status = & git -C $RepositoryRoot status --porcelain --untracked-files=all 2>$null
        if ($LASTEXITCODE -ne 0) { throw [InvalidOperationException]::new('git status could not determine checkout cleanliness') }
        return @($status | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    }.GetNewClosure()
    $defaults.GetFileSha256 = { param($Path) Get-CcodInstalledLifecycleHash -Path $Path }.GetNewClosure()
    $defaults.ReadText = { param($Path) [IO.File]::ReadAllText($Path) }.GetNewClosure()
    $defaults.NewEvidenceDirectory = {
        param($Root, $TransactionId)
        $safeRoot = Assert-CcodInstalledLifecycleSafeDirectory -Path $Root -Kind 'Evidence root'
        $directory = [IO.Path]::GetFullPath((Join-Path $safeRoot ('installed-lifecycle-' + $TransactionId)))
        if ([IO.Directory]::Exists($directory) -or [IO.File]::Exists($directory)) {
            Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_EVIDENCE_EXISTS' 'The generated evidence directory already exists' $directory
        }
        [IO.Directory]::CreateDirectory($directory) | Out-Null
        return Assert-CcodInstalledLifecycleSafeDirectory -Path $directory -Kind 'Evidence directory'
    }.GetNewClosure()
    $defaults.WriteEvidence = {
        param($EvidenceDirectory, $Receipt)
        $directory = Assert-CcodInstalledLifecycleSafeDirectory -Path $EvidenceDirectory -Kind 'Evidence directory'
        $target = [IO.Path]::GetFullPath((Join-Path $directory 'receipt.json'))
        $temporary = "$target.$([guid]::NewGuid().ToString('N')).tmp"
        try {
            [IO.File]::WriteAllText($temporary, ($Receipt | ConvertTo-Json -Depth 16), [Text.UTF8Encoding]::new($false))
            [IO.File]::Move($temporary, $target)
            return $target
        } finally {
            if ([IO.File]::Exists($temporary)) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
        }
    }.GetNewClosure()
    $defaults.CaptureFacts = { param($InstallRoot) Get-CcodInstalledLifecycleFacts -InstallRoot $InstallRoot }.GetNewClosure()
    $defaults.CreateRollbackSnapshot = {
        param($Context, $Facts)
        return [pscustomobject][ordered]@{ kind = 'observation'; transactionId = $Context.transactionId; beforeFacts = $Facts }
    }.GetNewClosure()
    $defaults.RunScenario = { param($Context) Invoke-CcodInstalledLifecycleOperatorScenario -Context $Context }.GetNewClosure()
    $defaults.VerifyScenario = { param($Context, $BeforeFacts, $RunResult) Test-CcodInstalledLifecycleScenario -Context $Context -BeforeFacts $BeforeFacts -RunResult $RunResult }.GetNewClosure()
    $defaults.Rollback = { param($Context, $Snapshot) Invoke-CcodInstalledLifecycleRollback -Context $Context -Snapshot $Snapshot }.GetNewClosure()
    $defaults.CleanupRollback = { param($Context, $Snapshot) return $true }.GetNewClosure()
    $defaults.GetUtcNow = { [datetime]::UtcNow }.GetNewClosure()
    return $defaults
}

function Resolve-CcodInstalledLifecycleAdapters {
    param([hashtable]$Adapters)
    $resolved = Get-CcodInstalledLifecycleDefaultAdapters
    if ($null -eq $Adapters) { return $resolved }
    foreach ($name in $Adapters.Keys) {
        if (-not $resolved.ContainsKey([string]$name) -or $Adapters[$name] -isnot [scriptblock]) {
            Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_ADAPTER_INVALID' 'Installed lifecycle test adapters must replace known scriptblock adapters only' $name
        }
        $resolved[[string]$name] = $Adapters[$name]
    }
    return $resolved
}

function Get-CcodInstalledLifecycleCandidate {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$ExpectedVersion,
        [Parameter(Mandatory)][hashtable]$Adapters,
        [Parameter(Mandatory)][string]$Kind,
        [switch]$AllowAnyVersion
    )
    $installer = Assert-CcodInstalledLifecycleRegularFile -Path $Path -Kind $Kind
    $leaf = [IO.Path]::GetFileName($installer)
    $versionMatch = [regex]::Match($leaf, '^CodexRemote-fix-(\d+\.\d+\.\d+)-setup\.exe$')
    if (-not $versionMatch.Success -or (-not $AllowAnyVersion -and ([string]::IsNullOrWhiteSpace($ExpectedVersion) -or $versionMatch.Groups[1].Value -cne $ExpectedVersion))) {
        Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_CANDIDATE_INVALID' "$Kind filename does not bind the expected version" $installer
    }
    $checksum = Assert-CcodInstalledLifecycleRegularFile -Path "$installer.sha256.txt" -Kind "$Kind checksum"
    $text = & $Adapters.ReadText $checksum
    if ($text -isnot [string]) {
        Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_CHECKSUM_INVALID' "$Kind checksum could not be read as text" $checksum
    }
    $normalized = $text.TrimEnd("`r", "`n")
    $match = [regex]::Match($normalized, '^([0-9a-f]{64}) \*([^\r\n]+)$')
    if (-not $match.Success -or $match.Groups[2].Value -cne [IO.Path]::GetFileName($installer)) {
        Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_CHECKSUM_INVALID' "$Kind checksum is malformed or names a different asset" $checksum
    }
    $actualHash = [string](& $Adapters.GetFileSha256 $installer)
    if ($actualHash -cnotmatch '^[0-9a-f]{64}$' -or $actualHash -cne $match.Groups[1].Value) {
        Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_CHECKSUM_INVALID' "$Kind checksum does not match the exact installer bytes" $installer
    }
    return [pscustomobject][ordered]@{ Path = $installer; Version = $versionMatch.Groups[1].Value; Sha256 = $actualHash; ChecksumPath = $checksum }
}

function ConvertTo-CcodInstalledLifecycleIdentities {
    param($Records, [Parameter(Mandatory)][string]$Kind)
    $result = [Collections.Generic.List[object]]::new()
    foreach ($record in @($Records)) {
        if ($null -eq $record -or $record.Pid -isnot [int] -or [int]$record.Pid -le 0 -or
            $record.CreationTimeUtc -isnot [string] -or -not (Test-CcodInstalledLifecycleCanonicalUtc $record.CreationTimeUtc)) {
            Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_FACTS_INVALID' "$Kind process identity is malformed" $record
        }
        $result.Add([pscustomobject][ordered]@{ pid = [int]$record.Pid; creationTimeUtc = [string]$record.CreationTimeUtc })
    }
    return @($result | Sort-Object pid, creationTimeUtc)
}

function Test-CcodInstalledLifecycleExactProperties {
    param($Value, [Parameter(Mandatory)][string[]]$Expected)
    if ($null -eq $Value -or ($Value -isnot [pscustomobject] -and $Value -isnot [Collections.IDictionary])) { return $false }
    $actual = if ($Value -is [Collections.IDictionary]) { @($Value.Keys | ForEach-Object { [string]$_ }) } else { @($Value.PSObject.Properties.Name) }
    return $actual.Count -eq $Expected.Count -and ($actual -join "`0") -ceq ($Expected -join "`0")
}

function Test-CcodInstalledLifecyclePositiveInteger {
    param($Value, [switch]$AllowZero)
    if ($Value -isnot [byte] -and $Value -isnot [uint16] -and $Value -isnot [uint32] -and $Value -isnot [uint64] -and
        $Value -isnot [int16] -and $Value -isnot [int32] -and $Value -isnot [int64]) { return $false }
    return $Value -ge $(if ($AllowZero) { 0 } else { 1 })
}

function ConvertTo-CcodInstalledLifecycleNullableIdentity {
    param($Identity, [Parameter(Mandatory)][string]$Kind)
    if ($null -eq $Identity) { return $null }
    $converted = @(ConvertTo-CcodInstalledLifecycleIdentities -Records @($Identity) -Kind $Kind)
    if ($converted.Count -ne 1) { Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_FACTS_INVALID' "$Kind identity is malformed" $Identity }
    return $converted[0]
}

function ConvertTo-CcodInstalledLifecycleReceiptFact {
    param($Receipt)
    if ($null -eq $Receipt) { return $null }
    $fields = @('kind','origin','runtimeId','runtimeGeneration','phase')
    if (-not (Test-CcodInstalledLifecycleExactProperties -Value $Receipt -Expected $fields) -or
        $Receipt.kind -isnot [string] -or @('RestartAndRepair','CheckAndRepair','SafeExit') -cnotcontains $Receipt.kind -or
        $Receipt.origin -isnot [string] -or @('Installer','Tray','ExplicitStart','Guardian') -cnotcontains $Receipt.origin -or
        $Receipt.runtimeId -isnot [string] -or $Receipt.runtimeId -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$' -or
        -not (Test-CcodInstalledLifecyclePositiveInteger -Value $Receipt.runtimeGeneration) -or
        $Receipt.phase -isnot [string] -or @('Completed','CloseFailed','OrdinaryLaunchFailed','OrdinaryObservationTimedOut','LaunchWindowExpired','RepairFailed','VerificationFailed','CancelledBeforeClose','SupersededByUpgrade') -cnotcontains $Receipt.phase) {
        Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_FACTS_INVALID' 'Lifecycle receipt fact is malformed' $Receipt
    }
    return [pscustomobject][ordered]@{
        kind = [string]$Receipt.kind
        origin = [string]$Receipt.origin
        runtimeId = [string]$Receipt.runtimeId
        runtimeGeneration = [UInt64]$Receipt.runtimeGeneration
        phase = [string]$Receipt.phase
    }
}

function ConvertTo-CcodInstalledLifecycleFacts {
    param($Facts)
    $expected = @('appPresent','activeRuntimeId','activeGeneration','runtimeManifestSha256','supervisor','trayHost','codex','taskState','statusPhase','statusRuntimeId','statusCodex','transitionStage','lifecycleReceipt','aboutVersion','deviceKeyPresent','deviceKeySha256','shortcuts')
    if ($null -eq $Facts -or ($Facts -isnot [pscustomobject] -and $Facts -isnot [Collections.IDictionary])) {
        Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_FACTS_INVALID' 'Machine facts are unavailable' $Facts
    }
    foreach ($name in $expected) {
        $property = if ($Facts -is [Collections.IDictionary]) { $Facts.Contains($name) } else { $null -ne $Facts.PSObject.Properties[$name] }
        if (-not $property) { Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_FACTS_INVALID' "Machine facts omit $name" $Facts }
    }
    if ($Facts.appPresent -isnot [bool] -or $Facts.deviceKeyPresent -isnot [bool] -or
        ($null -ne $Facts.activeRuntimeId -and ($Facts.activeRuntimeId -isnot [string] -or $Facts.activeRuntimeId -cnotmatch '^[A-Za-z0-9._-]{1,96}$')) -or
        ($null -ne $Facts.activeGeneration -and $Facts.activeGeneration -isnot [UInt64]) -or
        ($null -ne $Facts.runtimeManifestSha256 -and ($Facts.runtimeManifestSha256 -isnot [string] -or $Facts.runtimeManifestSha256 -cnotmatch '^[0-9a-f]{64}$')) -or
        ($null -ne $Facts.aboutVersion -and ($Facts.aboutVersion -isnot [string] -or $Facts.aboutVersion -cnotmatch '^\d+\.\d+\.\d+$')) -or
        ($null -ne $Facts.statusRuntimeId -and ($Facts.statusRuntimeId -isnot [string] -or $Facts.statusRuntimeId -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$')) -or
        ($null -ne $Facts.deviceKeySha256 -and ($Facts.deviceKeySha256 -isnot [string] -or $Facts.deviceKeySha256 -cnotmatch '^[0-9a-f]{64}$')) -or
        ($Facts.deviceKeyPresent -and $null -eq $Facts.deviceKeySha256) -or
        (-not $Facts.deviceKeyPresent -and $null -ne $Facts.deviceKeySha256) -or
        $Facts.taskState -isnot [string] -or $Facts.statusPhase -isnot [string] -or $Facts.transitionStage -isnot [string] -or $Facts.statusPhase.Length -gt 64 -or $Facts.transitionStage.Length -gt 64 -or
        $null -eq $Facts.shortcuts -or $Facts.shortcuts.startMenu -isnot [bool] -or $Facts.shortcuts.desktop -isnot [bool]) {
        Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_FACTS_INVALID' 'Machine facts have an invalid public shape' $Facts
    }
    return [pscustomobject][ordered]@{
        appPresent = [bool]$Facts.appPresent
        activeRuntimeId = $Facts.activeRuntimeId
        activeGeneration = $Facts.activeGeneration
        runtimeManifestSha256 = $Facts.runtimeManifestSha256
        supervisor = @(ConvertTo-CcodInstalledLifecycleIdentities -Records $Facts.supervisor -Kind 'Supervisor')
        trayHost = @(ConvertTo-CcodInstalledLifecycleIdentities -Records $Facts.trayHost -Kind 'TrayHost')
        codex = @(ConvertTo-CcodInstalledLifecycleIdentities -Records $Facts.codex -Kind 'Codex')
        taskState = [string]$Facts.taskState
        statusPhase = [string]$Facts.statusPhase
        statusRuntimeId = $Facts.statusRuntimeId
        statusCodex = ConvertTo-CcodInstalledLifecycleNullableIdentity -Identity $Facts.statusCodex -Kind 'Status Codex'
        transitionStage = [string]$Facts.transitionStage
        lifecycleReceipt = ConvertTo-CcodInstalledLifecycleReceiptFact -Receipt $Facts.lifecycleReceipt
        aboutVersion = $Facts.aboutVersion
        deviceKeyPresent = [bool]$Facts.deviceKeyPresent
        deviceKeySha256 = $Facts.deviceKeySha256
        shortcuts = [pscustomobject][ordered]@{ startMenu = [bool]$Facts.shortcuts.startMenu; desktop = [bool]$Facts.shortcuts.desktop }
    }
}

function New-CcodInstalledLifecyclePhase {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Outcome)
    return [pscustomobject][ordered]@{ name = $Name; outcome = $Outcome }
}

function Read-CcodInstalledLifecycleStrictJson {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int]$ExpectedSchema,
        [Parameter(Mandatory)][string]$Kind
    )
    return & $script:CcodInstalledLifecyclePersistenceIoModule {
        param($DocumentPath, $Schema, $DocumentKind)
        Read-CcodStrictJson -Path $DocumentPath -ExpectedSchema $Schema -Kind $DocumentKind
    } $Path $ExpectedSchema $Kind
}

function Read-CcodInstalledLifecycleActiveFact {
    param([Parameter(Mandatory)][string]$InstallRoot)
    $path = Join-Path $InstallRoot 'active.json'
    if (-not [IO.File]::Exists($path)) { return $null }
    $active = Read-CcodInstalledLifecycleStrictJson -Path $path -ExpectedSchema 2 -Kind 'installed active runtime'
    if (-not (Test-CcodInstalledLifecycleExactProperties -Value $active -Expected @('schemaVersion','activeRuntime','previousRuntime','generation','updatedAtUtc')) -or
        $active.schemaVersion -isnot [int] -or $active.schemaVersion -ne 2 -or
        $active.activeRuntime -isnot [string] -or $active.activeRuntime -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$' -or
        ($null -ne $active.previousRuntime -and ($active.previousRuntime -isnot [string] -or $active.previousRuntime -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$')) -or
        -not (Test-CcodInstalledLifecyclePositiveInteger -Value $active.generation) -or
        -not (Test-CcodInstalledLifecycleCanonicalUtc -Value $active.updatedAtUtc)) {
        Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_FACTS_INVALID' 'Active runtime schema 2 is malformed' $path
    }
    return $active
}

function Read-CcodInstalledLifecycleStatusFact {
    param([Parameter(Mandatory)][string]$StateRoot)
    $path = Join-Path $StateRoot 'status.json'
    if (-not [IO.File]::Exists($path)) { return $null }
    $status = Read-CcodInstalledLifecycleStrictJson -Path $path -ExpectedSchema 1 -Kind 'installed status'
    try {
        & $script:CcodInstalledLifecycleStateStoreModule { param($Value) Assert-CcodStatusShape -Status $Value } $status
    } catch {
        Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_FACTS_INVALID' 'Status schema 1 is malformed' $path
    }
    return $status
}

function Read-CcodInstalledLifecycleTransitionFact {
    param([Parameter(Mandatory)][string]$StateRoot)
    $path = Join-Path $StateRoot 'transition.json'
    if (-not [IO.File]::Exists($path)) { return $null }
    $transition = Read-CcodInstalledLifecycleStrictJson -Path $path -ExpectedSchema 1 -Kind 'installed transition'
    try {
        & $script:CcodInstalledLifecycleStateStoreModule { param($Value) Assert-CcodTransitionShape -Transition $Value } $transition
    } catch {
        Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_FACTS_INVALID' 'Transition schema 1 is malformed' $path
    }
    return $transition
}

function Get-CcodInstalledLifecycleReceiptFact {
    param([Parameter(Mandatory)][string]$StateRoot, [AllowNull()][string]$ActiveRuntimeId)
    $directory = Join-Path $StateRoot 'lifecycle\receipts'
    if (-not [IO.Directory]::Exists($directory)) { return $null }
    $directoryItem = Get-Item -LiteralPath $directory -Force -ErrorAction Stop
    if (-not $directoryItem.PSIsContainer -or (($directoryItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_FACTS_INVALID' 'Lifecycle receipt root is malformed' $directory
    }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $candidates = [Collections.Generic.List[object]]::new()
    foreach ($item in @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop | Where-Object { $_.Name -like '*.json' })) {
        if ($item.PSIsContainer -or $item -isnot [IO.FileInfo] -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_FACTS_INVALID' 'Lifecycle receipt entry is malformed' $item.FullName
        }
        $receipt = Read-CcodInstalledLifecycleStrictJson -Path $item.FullName -ExpectedSchema 1 -Kind 'installed lifecycle receipt'
        try {
            & $script:CcodInstalledLifecycleTransactionModule { param($Value) Assert-CcodLifecycleRequest -Request $Value } $receipt
        } catch {
            Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_FACTS_INVALID' 'Lifecycle receipt schema 1 is malformed' $item.FullName
        }
        if ($item.Name -cne ($receipt.transactionId + '.json') -or -not $seen.Add([string]$receipt.transactionId)) {
            Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_FACTS_INVALID' 'Lifecycle receipts have a mismatched or duplicate identity' $item.FullName
        }
        if ($receipt.phase -cnotin @('Completed','CloseFailed','OrdinaryLaunchFailed','OrdinaryObservationTimedOut','LaunchWindowExpired','RepairFailed','VerificationFailed','CancelledBeforeClose','SupersededByUpgrade')) {
            Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_FACTS_INVALID' 'Lifecycle receipt is not terminal' $item.FullName
        }
        if ($null -ne $ActiveRuntimeId -and $receipt.runtimeId -ceq $ActiveRuntimeId -and $receipt.origin -ceq 'Installer' -and $receipt.kind -ceq 'RestartAndRepair') {
            $candidates.Add($receipt)
        }
    }
    if ($candidates.Count -eq 0) { return $null }
    $ordered = @($candidates | Sort-Object updatedAtUtc -Descending)
    if ($ordered.Count -gt 1 -and $ordered[0].updatedAtUtc -ceq $ordered[1].updatedAtUtc) {
        Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_FACTS_INVALID' 'Latest current-runtime installer lifecycle receipt is ambiguous' $directory
    }
    $latest = $ordered[0]
    return [pscustomobject][ordered]@{
        kind = [string]$latest.kind
        origin = [string]$latest.origin
        runtimeId = [string]$latest.runtimeId
        runtimeGeneration = [UInt64]$latest.runtimeGeneration
        phase = [string]$latest.phase
    }
}

function Get-CcodInstalledLifecycleFacts {
    param([Parameter(Mandatory)][string]$InstallRoot)
    $root = [IO.Path]::GetFullPath($InstallRoot)
    $appRoot = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'CodexControlOtherDevices-installer'
    $activeRuntimeId = $null
    [UInt64]$activeGeneration = 0
    $runtimeManifestSha256 = $null
    $statusPhase = 'Unavailable'
    $statusRuntimeId = $null
    $statusCodex = $null
    $transitionStage = 'Unavailable'
    $active = Read-CcodInstalledLifecycleActiveFact -InstallRoot $root
    if ($null -ne $active) {
        $activeRuntimeId = [string]$active.activeRuntime
        $activeGeneration = [UInt64]$active.generation
        $manifest = Join-Path (Join-Path (Join-Path $root 'runtime') $activeRuntimeId) 'manifest.json'
        if ([IO.File]::Exists($manifest)) { $runtimeManifestSha256 = Get-CcodInstalledLifecycleHash -Path $manifest }
    }
    $stateRoot = Join-Path $root 'state'
    $status = Read-CcodInstalledLifecycleStatusFact -StateRoot $stateRoot
    if ($null -ne $status -and $null -ne $status.session) {
        $statusPhase = [string]$status.session.sessionState
        $statusRuntimeId = [string]$status.session.runtimeId
        if ($null -ne $status.session.codex) {
            $statusCodex = [pscustomobject][ordered]@{
                pid = [int]$status.session.codex.pid
                creationTimeUtc = [string]$status.session.codex.creationTimeUtc
            }
        }
    }
    $transition = Read-CcodInstalledLifecycleTransitionFact -StateRoot $stateRoot
    if ($null -ne $transition) {
        $transitionStage = if ($null -eq $transition.activeTransaction) { 'Idle' } else { [string]$transition.activeTransaction.stage }
    }
    $lifecycleReceipt = Get-CcodInstalledLifecycleReceiptFact -StateRoot $stateRoot -ActiveRuntimeId $activeRuntimeId
    $taskState = 'Unknown'
    try {
        $matches = @(Get-ScheduledTask -ErrorAction Stop | Where-Object { $_.TaskName -ceq $script:CcodInstalledLifecycleTaskName })
        if ($matches.Count -eq 0) { $taskState = 'Absent' }
        elseif ($matches.Count -eq 1) { $taskState = [string]$matches[0].State }
    } catch { $taskState = 'Unknown' }
    $makeIdentities = {
        param([string[]]$Names, [scriptblock]$Predicate)
        $records = [Collections.Generic.List[object]]::new()
        foreach ($name in $Names) {
            try {
                foreach ($process in @(Get-CimInstance -ClassName Win32_Process -Filter ("Name = '{0}'" -f $name) -ErrorAction Stop)) {
                    if (-not (& $Predicate $process)) { continue }
                    $created = [Management.ManagementDateTimeConverter]::ToDateTime([string]$process.CreationDate).ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
                    $records.Add([pscustomobject][ordered]@{ Pid = [int]$process.ProcessId; CreationTimeUtc = $created })
                }
            } catch { }
        }
        return @($records)
    }.GetNewClosure()
    $supervisor = & $makeIdentities @('powershell.exe','pwsh.exe') {
        param($Process)
        ([string]$Process.CommandLine).IndexOf('Supervisor.ps1', [StringComparison]::OrdinalIgnoreCase) -ge 0 -and
        ([string]$Process.CommandLine).IndexOf($root, [StringComparison]::OrdinalIgnoreCase) -ge 0
    }
    $trayHostPath = [IO.Path]::GetFullPath((Join-Path $root 'bin\CodexRemote.TrayHost.exe'))
    $trayHost = & $makeIdentities @('CodexRemote.TrayHost.exe') {
        param($Process)
        [string]$Process.ExecutablePath -ieq $trayHostPath
    }
    $codex = & $makeIdentities @('ChatGPT.exe') {
        param($Process)
        ([string]$Process.CommandLine) -cnotmatch '(?i)(?:^|\s)--type='
    }
    $aboutVersion = $null
    $packagePath = Join-Path $appRoot 'package.json'
    if ([IO.File]::Exists($packagePath)) {
        try {
            $package = [IO.File]::ReadAllText($packagePath) | ConvertFrom-Json -ErrorAction Stop
            if ($package.version -is [string] -and $package.version -cmatch '^\d+\.\d+\.\d+$') { $aboutVersion = [string]$package.version }
        } catch { }
    }
    $codexHome = [Environment]::GetEnvironmentVariable('CODEX_HOME', 'Process')
    if ([string]::IsNullOrWhiteSpace($codexHome)) { $codexHome = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)) '.codex' }
    $deviceKey = if ([IO.Path]::IsPathRooted($codexHome)) { Join-Path $codexHome 'remote-control-device-keys.windows.json' } else { $null }
    $deviceKeyPresent = $null -ne $deviceKey -and [IO.File]::Exists($deviceKey)
    $deviceKeySha256 = if ($deviceKeyPresent) { Get-CcodInstalledLifecycleHash -Path $deviceKey } else { $null }
    $startMenu = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::Programs)) 'CodexRemote-fix\CodexRemote-fix.lnk'
    $desktop = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::Desktop)) 'CodexRemote-fix.lnk'
    return [pscustomobject][ordered]@{
        appPresent = [IO.Directory]::Exists($appRoot)
        activeRuntimeId = $activeRuntimeId
        activeGeneration = if ($null -eq $activeRuntimeId) { $null } else { [UInt64]$activeGeneration }
        runtimeManifestSha256 = $runtimeManifestSha256
        supervisor = @($supervisor)
        trayHost = @($trayHost)
        codex = @($codex)
        taskState = $taskState
        statusPhase = $statusPhase
        statusRuntimeId = $statusRuntimeId
        statusCodex = $statusCodex
        transitionStage = $transitionStage
        lifecycleReceipt = $lifecycleReceipt
        aboutVersion = $aboutVersion
        deviceKeyPresent = [bool]$deviceKeyPresent
        deviceKeySha256 = $deviceKeySha256
        shortcuts = [pscustomobject][ordered]@{ startMenu = [IO.File]::Exists($startMenu); desktop = [IO.File]::Exists($desktop) }
    }
}

function Read-CcodInstalledLifecycleOperatorAck {
    param([Parameter(Mandatory)][string]$Scenario, [Parameter(Mandatory)][string]$Instructions)
    Write-Host ''
    Write-Host ("Installed lifecycle scenario: {0}" -f $Scenario) -ForegroundColor Cyan
    Write-Host $Instructions -ForegroundColor Yellow
    $expected = "CCOD_$($Scenario.ToUpperInvariant())_COMPLETED"
    $acknowledgement = Read-Host "After independently verifying the requested action, type $expected"
    if ($acknowledgement -cne $expected) {
        Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_OPERATOR_NOT_CONFIRMED' 'The requested live scenario was not explicitly confirmed' $Scenario
    }
}

function Invoke-CcodInstalledLifecycleOperatorScenario {
    param([Parameter(Mandatory)]$Context)
    $launchInstaller = {
        $process = Start-Process -FilePath $Context.installerPath -PassThru -Wait -ErrorAction Stop
        if ($process.ExitCode -ne 0) {
            Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_INSTALLER_FAILED' 'The operator-visible installer returned a nonzero exit code' $process.ExitCode
        }
    }.GetNewClosure()
    switch ($Context.scenario) {
        'FreshLater' {
            & $launchInstaller
            Read-CcodInstalledLifecycleOperatorAck -Scenario $Context.scenario -Instructions 'Complete the installer and choose Later. Confirm that the pre-existing Codex session was left untouched.'
        }
        'FreshRestart' {
            & $launchInstaller
            Read-CcodInstalledLifecycleOperatorAck -Scenario $Context.scenario -Instructions 'Complete the installer, choose Restart now, and wait for the new controlled Codex session and tray to become ready.'
        }
        'Upgrade' {
            & $launchInstaller
            Read-CcodInstalledLifecycleOperatorAck -Scenario $Context.scenario -Instructions 'Complete the upgrade and observe the requested restart/later behavior before acknowledging it.'
        }
        'SettingsUninstall' {
            Start-Process 'ms-settings:appsfeatures' -ErrorAction Stop | Out-Null
            Read-CcodInstalledLifecycleOperatorAck -Scenario $Context.scenario -Instructions 'Use Windows Settings to uninstall CodexRemote-fix. Wait for the uninstaller to complete successfully.'
        }
        'DirectUninstall' {
            $uninstaller = Assert-CcodInstalledLifecycleRegularFile -Path (Join-Path $Context.installerApplicationRoot 'unins000.exe') -Kind 'Installed uninstaller'
            $process = Start-Process -FilePath $uninstaller -PassThru -Wait -ErrorAction Stop
            if ($process.ExitCode -ne 0) { Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_INSTALLER_FAILED' 'The installed uninstaller returned a nonzero exit code' $process.ExitCode }
            Read-CcodInstalledLifecycleOperatorAck -Scenario $Context.scenario -Instructions 'Confirm that the direct uninstaller completed and did not remove the device-key store.'
        }
        default {
            Read-CcodInstalledLifecycleOperatorAck -Scenario $Context.scenario -Instructions 'Perform the named scenario through the visible CodexRemote-fix UI and wait for its observable state to settle.'
        }
    }
    return [pscustomobject][ordered]@{ code = 'CCOD_INTEGRATION_OPERATOR_COMPLETED' }
}

function Test-CcodInstalledLifecycleSameIdentitySet {
    param($Expected, $Actual)
    $expectedKeys = @($Expected | ForEach-Object { '{0}|{1}' -f $_.pid, $_.creationTimeUtc } | Sort-Object)
    $actualKeys = @($Actual | ForEach-Object { '{0}|{1}' -f $_.pid, $_.creationTimeUtc } | Sort-Object)
    return (($expectedKeys -join ';') -ceq ($actualKeys -join ';'))
}

function Test-CcodInstalledLifecycleScenario {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$BeforeFacts, [Parameter(Mandatory)]$RunResult)
    $afterFacts = ConvertTo-CcodInstalledLifecycleFacts -Facts (Get-CcodInstalledLifecycleFacts -InstallRoot $Context.installRoot)
    $verified = $true
    $code = 'CCOD_INTEGRATION_VERIFIED'
    if ($Context.scenario -in @('SettingsUninstall','DirectUninstall')) {
        $verified = -not $afterFacts.appPresent -and $afterFacts.taskState -ceq 'Absent'
        if ($BeforeFacts.deviceKeyPresent) { $verified = $verified -and $afterFacts.deviceKeyPresent -and $afterFacts.deviceKeySha256 -ceq $BeforeFacts.deviceKeySha256 }
    } elseif ($Context.scenario -eq 'SafeExit') {
        $verified = $afterFacts.appPresent -and $afterFacts.supervisor.Count -eq 0 -and $afterFacts.trayHost.Count -eq 0
    } else {
        $verified = $afterFacts.appPresent -and $afterFacts.aboutVersion -ceq $Context.expectedVersion -and $null -ne $afterFacts.activeRuntimeId -and $afterFacts.taskState -in @('Ready','Running')
        if ($BeforeFacts.deviceKeyPresent) { $verified = $verified -and $afterFacts.deviceKeyPresent -and $afterFacts.deviceKeySha256 -ceq $BeforeFacts.deviceKeySha256 }
        if ($Context.scenario -eq 'FreshLater' -and $BeforeFacts.codex.Count -gt 0) {
            $verified = $verified -and (Test-CcodInstalledLifecycleSameIdentitySet -Expected $BeforeFacts.codex -Actual $afterFacts.codex)
        }
        if ($Context.scenario -eq 'FreshRestart') {
            $verified = $verified -and
                $afterFacts.codex.Count -eq 1 -and
                $afterFacts.statusPhase -ceq 'Active' -and
                $afterFacts.statusRuntimeId -ceq $afterFacts.activeRuntimeId -and
                $null -ne $afterFacts.statusCodex -and
                $afterFacts.statusCodex.pid -eq $afterFacts.codex[0].pid -and
                $afterFacts.statusCodex.creationTimeUtc -ceq $afterFacts.codex[0].creationTimeUtc -and
                $afterFacts.transitionStage -ceq 'Idle' -and
                $null -ne $afterFacts.lifecycleReceipt -and
                $afterFacts.lifecycleReceipt.kind -ceq 'RestartAndRepair' -and
                $afterFacts.lifecycleReceipt.origin -ceq 'Installer' -and
                $afterFacts.lifecycleReceipt.runtimeId -ceq $afterFacts.activeRuntimeId -and
                [UInt64]$afterFacts.lifecycleReceipt.runtimeGeneration -eq [UInt64]$afterFacts.activeGeneration -and
                $afterFacts.lifecycleReceipt.phase -ceq 'Completed'
        }
    }
    if (-not $verified) { $code = 'CCOD_INTEGRATION_OBSERVATION_UNPROVEN' }
    return [pscustomobject][ordered]@{ verified = [bool]$verified; code = $code; facts = $afterFacts }
}

function Invoke-CcodInstalledLifecycleRollback {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Snapshot)
    if (-not [string]::IsNullOrWhiteSpace([string]$Context.previousInstallerPath)) {
        $process = Start-Process -FilePath $Context.previousInstallerPath -PassThru -Wait -ErrorAction Stop
        if ($process.ExitCode -ne 0) { Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_ROLLBACK_FAILED' 'The prior installer did not complete during rollback' $process.ExitCode }
        Read-CcodInstalledLifecycleOperatorAck -Scenario 'ROLLBACK' -Instructions 'Verify that the prior installer restored the pre-test application state.'
        return [pscustomobject][ordered]@{ restored = $true; code = 'CCOD_INTEGRATION_ROLLBACK_COMPLETED' }
    }
    Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_ROLLBACK_UNAVAILABLE' 'No prior installer was supplied for an observable rollback path' $Context.scenario
}

function Invoke-CcodInstalledLifecycleIntegration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$InstallerPath,
        [string]$PreviousInstallerPath,
        [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$ExpectedVersion,
        [Parameter(Mandatory)][string]$EvidenceRoot,
        [switch]$AllowMachineMutation,
        [switch]$AllowCodexRestart,
        [Parameter(Mandatory)][ValidateSet('FreshLater','FreshRestart','Upgrade','SlowLaunch','ManualLaunchResume','LanguageStress','RepairStates','SafeExit','SettingsUninstall','DirectUninstall')][string]$Scenario,
        [hashtable]$Adapters
    )
    if (-not $AllowMachineMutation) {
        Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_MUTATION_NOT_ALLOWED' 'Live installed lifecycle scenarios require -AllowMachineMutation before any candidate, checkout, or machine operation.' $Scenario
    }
    if ($script:CcodInstalledLifecycleRestartScenarios -ccontains $Scenario -and -not $AllowCodexRestart) {
        Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_CODEX_RESTART_NOT_ALLOWED' 'This scenario can stop or restart Codex and requires -AllowCodexRestart before any operation.' $Scenario
    }
    $adapters = Resolve-CcodInstalledLifecycleAdapters -Adapters $Adapters
    $startedAt = & $adapters.GetUtcNow
    if ($startedAt -isnot [datetime]) { Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_CLOCK_INVALID' 'The integration clock did not return a DateTime value' $startedAt }
    $transactionId = [guid]::NewGuid().ToString('D')
    $phases = [Collections.Generic.List[object]]::new()
    $evidenceDirectory = $null
    $snapshot = $null
    $failure = $null
    $failureCode = $null
    $rollback = [pscustomobject][ordered]@{ attempted = $false; completed = $false; code = $null }
    $candidate = $null
    $previousCandidate = $null
    $beforeFacts = $null
    $verification = $null
    try {
        $candidate = Get-CcodInstalledLifecycleCandidate -Path $InstallerPath -ExpectedVersion $ExpectedVersion -Adapters $adapters -Kind 'Installer'
        if ($Scenario -ceq 'Upgrade') {
            if ([string]::IsNullOrWhiteSpace($PreviousInstallerPath)) { Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_PREVIOUS_INSTALLER_REQUIRED' 'Upgrade scenarios require a checksum-bound previous installer for rollback.' $Scenario }
            $previousCandidate = Get-CcodInstalledLifecycleCandidate -Path $PreviousInstallerPath -Adapters $adapters -Kind 'Previous installer' -AllowAnyVersion
            if ([version]$previousCandidate.Version -ge [version]$ExpectedVersion) { Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_PREVIOUS_INSTALLER_INVALID' 'Upgrade rollback installer must be a checksum-bound prior version.' $previousCandidate.Path }
        } elseif (-not [string]::IsNullOrWhiteSpace($PreviousInstallerPath)) {
            Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_PREVIOUS_INSTALLER_UNEXPECTED' 'A previous installer is allowed only for the Upgrade scenario.' $Scenario
        }
        $checkout = @(& $adapters.GetGitStatus (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent))
        if ($checkout.Count -ne 0) { Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_CHECKOUT_DIRTY' 'Live integration refuses a dirty checkout.' $null }
        $phases.Add((New-CcodInstalledLifecyclePhase -Name 'Preflight' -Outcome 'Completed'))
        $evidenceDirectory = & $adapters.NewEvidenceDirectory $EvidenceRoot $transactionId
        if ($evidenceDirectory -isnot [string] -or -not [IO.Path]::IsPathRooted($evidenceDirectory)) { Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_EVIDENCE_ROOT_INVALID' 'Evidence directory adapter returned an invalid path' $evidenceDirectory }
        $installRoot = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'CodexControlOtherDevices'
        $installerApplicationRoot = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'CodexControlOtherDevices-installer'
        $context = [pscustomobject][ordered]@{
            transactionId = $transactionId
            scenario = $Scenario
            installerPath = $candidate.Path
            previousInstallerPath = if ($null -eq $previousCandidate) { $null } else { $previousCandidate.Path }
            expectedVersion = $ExpectedVersion
            installRoot = [IO.Path]::GetFullPath($installRoot)
            installerApplicationRoot = [IO.Path]::GetFullPath($installerApplicationRoot)
        }
        $beforeFacts = ConvertTo-CcodInstalledLifecycleFacts -Facts (& $adapters.CaptureFacts $context.installRoot)
        $snapshot = & $adapters.CreateRollbackSnapshot $context $beforeFacts
        if ($null -eq $snapshot) { Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_SNAPSHOT_FAILED' 'Rollback snapshot adapter returned no snapshot.' $null }
        $phases.Add((New-CcodInstalledLifecyclePhase -Name 'CaptureRollback' -Outcome 'Completed'))
        try {
            $runResult = & $adapters.RunScenario $context
        } catch {
            Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_SCENARIO_FAILED' 'The live scenario failed before verification.' (Get-CcodInstalledLifecycleErrorId $_)
        }
        if ($null -eq $runResult) { Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_SCENARIO_FAILED' 'The live scenario returned no result.' $null }
        $phases.Add((New-CcodInstalledLifecyclePhase -Name 'RunScenario' -Outcome 'Completed'))
        try {
            $verification = & $adapters.VerifyScenario $context $beforeFacts $runResult
        } catch {
            Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_VERIFICATION_FAILED' 'The live scenario could not be verified.' (Get-CcodInstalledLifecycleErrorId $_)
        }
        if ($null -eq $verification -or $verification.verified -isnot [bool] -or -not [bool]$verification.verified -or $verification.code -isnot [string]) {
            Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_VERIFICATION_FAILED' 'The live scenario did not produce a proven verification result.' $verification
        }
        $verification = [pscustomobject][ordered]@{
            verified = $true
            code = [string]$verification.code
            facts = ConvertTo-CcodInstalledLifecycleFacts -Facts $verification.facts
        }
        $phases.Add((New-CcodInstalledLifecyclePhase -Name 'VerifyScenario' -Outcome 'Completed'))
    } catch {
        $failure = $_
        $failureCode = Get-CcodInstalledLifecycleErrorId $_
        if ([string]::IsNullOrWhiteSpace($failureCode) -or $failureCode -notmatch '^CCOD_INTEGRATION_') { $failureCode = 'CCOD_INTEGRATION_FAILED' }
        if ($null -ne $snapshot) {
            $rollback.attempted = $true
            try {
                $rollbackResult = & $adapters.Rollback $context $snapshot
                if ($null -eq $rollbackResult -or $rollbackResult.restored -isnot [bool] -or -not [bool]$rollbackResult.restored -or $rollbackResult.code -isnot [string]) {
                    Throw-CcodInstalledLifecycleError 'CCOD_INTEGRATION_ROLLBACK_FAILED' 'Rollback did not return a proven completion result.' $rollbackResult
                }
                $rollback.completed = $true
                $rollback.code = [string]$rollbackResult.code
            } catch {
                $rollback.completed = $false
                $rollback.code = Get-CcodInstalledLifecycleErrorId $_
                $failureCode = 'CCOD_INTEGRATION_ROLLBACK_FAILED'
            }
        }
        $phases.Add((New-CcodInstalledLifecyclePhase -Name 'Failed' -Outcome $failureCode))
    } finally {
        if ($null -ne $snapshot) {
            try {
                $cleaned = & $adapters.CleanupRollback $context $snapshot
                if ($cleaned -isnot [bool] -or -not $cleaned) {
                    if ($null -eq $failure) { $failureCode = 'CCOD_INTEGRATION_ROLLBACK_CLEANUP_FAILED' }
                    $rollback.completed = $false
                    $rollback.code = 'CCOD_INTEGRATION_ROLLBACK_CLEANUP_FAILED'
                }
            } catch {
                if ($null -eq $failure) { $failureCode = 'CCOD_INTEGRATION_ROLLBACK_CLEANUP_FAILED' }
                $rollback.completed = $false
                $rollback.code = 'CCOD_INTEGRATION_ROLLBACK_CLEANUP_FAILED'
            }
        }
        if ($null -ne $evidenceDirectory) {
            $completedAt = & $adapters.GetUtcNow
            if ($completedAt -isnot [datetime]) { $completedAt = [datetime]::UtcNow }
            $receipt = [pscustomobject][ordered]@{
                schemaVersion = 1
                transactionId = $transactionId
                scenario = $Scenario
                expectedVersion = $ExpectedVersion
                installerSha256 = if ($null -eq $candidate) { $null } else { $candidate.Sha256 }
                previousInstallerSha256 = if ($null -eq $previousCandidate) { $null } else { $previousCandidate.Sha256 }
                startedAtUtc = $startedAt.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
                completedAtUtc = $completedAt.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
                durationMilliseconds = [long][math]::Max(0, ($completedAt.ToUniversalTime() - $startedAt.ToUniversalTime()).TotalMilliseconds)
                outcome = if ($null -eq $failure -and [string]::IsNullOrWhiteSpace($failureCode)) { 'Completed' } else { 'Failed' }
                errorCode = if ($null -eq $failure -and [string]::IsNullOrWhiteSpace($failureCode)) { $null } else { $failureCode }
                phases = @($phases)
                beforeFacts = $beforeFacts
                verification = $verification
                rollback = $rollback
            }
            try { & $adapters.WriteEvidence $evidenceDirectory $receipt | Out-Null }
            catch {
                if ($null -eq $failure) { $failureCode = 'CCOD_INTEGRATION_EVIDENCE_WRITE_FAILED' }
            }
        }
    }
    if ($null -ne $failure -or -not [string]::IsNullOrWhiteSpace($failureCode)) {
        Throw-CcodInstalledLifecycleError $failureCode 'The installed lifecycle scenario did not complete with proven evidence.' $Scenario
    }
    return $receipt
}

if (-not $Library) {
    try {
        $receipt = Invoke-CcodInstalledLifecycleIntegration -InstallerPath $InstallerPath -PreviousInstallerPath $PreviousInstallerPath -ExpectedVersion $ExpectedVersion -EvidenceRoot $EvidenceRoot -AllowMachineMutation:$AllowMachineMutation -AllowCodexRestart:$AllowCodexRestart -Scenario $Scenario
        $receipt | ConvertTo-Json -Depth 16
    } catch {
        Write-Error $_
        exit 1
    }
}
