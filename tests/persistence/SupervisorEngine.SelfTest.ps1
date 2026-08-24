$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestSupport.ps1')

$repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$modulePath = Join-Path $repositoryRoot 'src\persistence\modules\SupervisorEngine.psm1'
Import-Module $modulePath -Force

function Assert-CcodExactEqual($Expected, $Actual, [string]$Message) {
    if (-not [object]::Equals($Expected, $Actual)) {
        throw "ASSERT_EXACT: $Message expected=[$Expected] actual=[$Actual]"
    }
}

function Assert-CcodPropertyOrder($Value, [string[]]$Expected, [string]$Message) {
    $actual = @($Value.PSObject.Properties.Name)
    Assert-CcodExactEqual ($Expected -join '|') ($actual -join '|') $Message
}

function New-CcodSupervisorSnapshot {
    param(
        [int]$ProcessId = 100,
        [string]$CreationTimeUtc = '2030-02-03T04:00:00.0000000Z',
        [int]$SessionId = 1,
        [string]$UserSid = 'S-1-5-21-test',
        [ValidateSet('Ordinary','Special','Unrelated')][string]$Mode = 'Ordinary',
        [AllowNull()][Nullable[int]]$RendererPort = $null,
        [AllowNull()][Nullable[int]]$MainPort = $null,
        [bool]$IsTopLevel = $true
    )
    [pscustomobject][ordered]@{
        Pid=$ProcessId; CreationTimeUtc=$CreationTimeUtc; SessionId=$SessionId; UserSid=$UserSid
        Path='C:\Codex\ChatGPT.exe'; PackageFamilyName='OpenAI.Codex_2p2nqsd0c76g0'
        CommandLine='"C:\Codex\ChatGPT.exe"'; ParentPid=$null; IsTopLevel=$IsTopLevel; Mode=$Mode
        RendererPort=$RendererPort; MainPort=$MainPort
    }
}

function New-CcodSpecialObservation {
    param(
        $Snapshot = (New-CcodSupervisorSnapshot -ProcessId 200 -Mode Special -RendererPort 41001 -MainPort 41002),
        [bool]$IdentityValid = $true,
        [bool]$ProbeValid = $true
    )
    [pscustomobject][ordered]@{ Snapshot=$Snapshot; IdentityValid=$IdentityValid; ProbeValid=$ProbeValid }
}

function New-CcodVerifiedRecord {
    param(
        [string]$PackageFullName = 'OpenAI.Codex_1.0.0.0_x64__2p2nqsd0c76g0',
        [string]$AppAsarSha256 = ('a' * 64),
        [string]$RuntimeId = 'runtime-1',
        [ValidateSet('Succeeded','Failed')][string]$DynamicOutcome = 'Succeeded',
        [ValidateSet('Valid','Invalid','NotRun')][string]$ProbeState = 'Valid'
    )
    [pscustomobject][ordered]@{
        packageFullName=$PackageFullName; packageVersion='1.0.0.0'; appAsarSha256=$AppAsarSha256
        runtimeId=$RuntimeId; staticClassification='CandidateCompatible'; dynamicOutcome=$DynamicOutcome
        probeState=$ProbeState; confirmedAtUtc='2030-02-03T04:05:00.0000000Z'
    }
}

function New-CcodVerifiedStore {
    param([AllowNull()][string]$Key, $Record)
    $packages = [pscustomobject]@{}
    if (-not [string]::IsNullOrWhiteSpace($Key)) { $packages | Add-Member -NotePropertyName $Key -NotePropertyValue $Record }
    [pscustomobject][ordered]@{ schemaVersion=1; packages=$packages }
}

function New-CcodActiveTransition {
    [pscustomobject][ordered]@{
        transactionId='11111111-2222-3333-4444-555555555555'; stage='IntentWritten'
        sourcePid=100; sourceCreationTimeUtc='2030-02-03T04:00:00.0000000Z'
        packageFullName='OpenAI.Codex_1.0.0.0_x64__2p2nqsd0c76g0'; appAsarSha256=('a' * 64); runtimeId='runtime-1'
        mainPort=$null; rendererPort=$null; specialPid=$null; specialCreationTimeUtc=$null
        recoveryPid=$null; recoveryCreationTimeUtc=$null
        createdAtUtc='2030-02-03T04:01:00.0000000Z'; updatedAtUtc='2030-02-03T04:01:00.0000000Z'
    }
}

function New-CcodSupervisorContext {
    param(
        [bool]$AutomationEnabled = $true,
        [bool]$CandidateCompatibleOptIn = $true,
        [bool]$AutomaticCandidateTrialsAllowed = $true,
        [bool]$StateDamageBlocksActions = $false,
        [bool]$ControllerRunning = $false,
        $ActiveTransaction = $null,
        [AllowNull()][string]$Classification = 'CandidateCompatible',
        $VerifiedPackages = (New-CcodVerifiedStore),
        $Ordinary,
        $Special,
        $AttemptKeys = ([ordered]@{}),
        $RecoveryIgnoreKeys = ([ordered]@{}),
        $SuppressionKeys = ([ordered]@{})
    )
    if (-not $PSBoundParameters.ContainsKey('Ordinary')) { $Ordinary = @(New-CcodSupervisorSnapshot) }
    if (-not $PSBoundParameters.ContainsKey('Special')) { $Special = @() }
    $packageFullName = 'OpenAI.Codex_1.0.0.0_x64__2p2nqsd0c76g0'
    $appAsarSha256 = ('a' * 64)
    if ([string]::IsNullOrWhiteSpace($Classification)) {
        $packageFullName = $null
        $appAsarSha256 = $null
    }
    [pscustomobject][ordered]@{
        AutomationEnabled=$AutomationEnabled; CandidateCompatibleOptIn=$CandidateCompatibleOptIn
        AutomaticCandidateTrialsAllowed=$AutomaticCandidateTrialsAllowed
        StateDamageBlocksActions=$StateDamageBlocksActions; ControllerRunning=$ControllerRunning
        ActiveTransaction=$ActiveTransaction; CurrentUserSid='S-1-5-21-test'; CurrentSessionId=1
        RuntimeId='runtime-1'; PackageFullName=$packageFullName
        AppAsarSha256=$appAsarSha256; Classification=$Classification; VerifiedPackages=$VerifiedPackages
        Ordinary=@($Ordinary); Special=@($Special); AttemptKeys=$AttemptKeys
        RecoveryIgnoreKeys=$RecoveryIgnoreKeys; SuppressionKeys=$SuppressionKeys
    }
}

function New-CcodResultSource {
    param([int]$ProcessId=100, [string]$CreationTimeUtc='2030-02-03T04:00:00.0000000Z')
    [pscustomobject][ordered]@{ pid=$ProcessId; creationTimeUtc=$CreationTimeUtc }
}

function New-CcodResultStaleSource {
    param($Expected)
    [pscustomobject][ordered]@{
        pid=[int]$Expected.Pid;creationTimeUtc=[string]$Expected.CreationTimeUtc;sessionId=[int]$Expected.SessionId;userSid=[string]$Expected.UserSid
        path=[string]$Expected.Path;packageFamilyName=[string]$Expected.PackageFamilyName;commandLine=[string]$Expected.CommandLine;parentPid=$Expected.ParentPid
        isTopLevel=[bool]$Expected.IsTopLevel;mode=[string]$Expected.Mode;rendererPort=[int]$Expected.RendererPort;mainPort=[int]$Expected.MainPort
    }
}

function New-CcodResultSpecial {
    [pscustomobject][ordered]@{
        pid=200; creationTimeUtc='2030-02-03T04:02:00.0000000Z'; rendererPort=41001; mainPort=41002
    }
}

function New-CcodResultPackage {
    param(
        [string]$FullName='OpenAI.Codex_1.0.0.0_x64__2p2nqsd0c76g0',
        [string]$AppAsarSha256=('a' * 64)
    )
    [pscustomobject][ordered]@{
        fullName=$FullName; familyName='OpenAI.Codex_2p2nqsd0c76g0'; version='1.0.0.0'; appAsarSha256=$AppAsarSha256
    }
}

function New-CcodRecoveryEvidence {
    param(
        [string]$TransactionId='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
        [int]$ProcessId=300,
        [string]$CreationTimeUtc='2030-02-03T04:03:00.0000000Z'
    )
    [pscustomobject][ordered]@{
        pid=$ProcessId; creationTimeUtc=$CreationTimeUtc
        ignoreKey=('{0}|{1}|{2}' -f $ProcessId,$CreationTimeUtc,$TransactionId)
        suppressionKey=('OpenAI.Codex_1.0.0.0_x64__2p2nqsd0c76g0|{0}|runtime-1' -f ('a' * 64))
        portsClosed=$true; disposition='LaunchedOnce'; priorTransactionId=$TransactionId
    }
}

function New-CcodControllerResult {
    param(
        [ValidateSet('Inspect','Apply','RepairStale','RepairRenderer','Recover')][string]$Action='Apply',
        [bool]$Ok=$true,
        [string]$Outcome='Activated',
        [string]$SafeState='SpecialValidated',
        [string]$Stage='Completed',
        [string]$TransactionId='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
        $Package=$null,
        $Source=$null,
        $Special=(New-CcodResultSpecial),
        $Recovery=$null,
        $Error=$null
    )
    [pscustomobject][ordered]@{
        schemaVersion=1; action=$Action; ok=$Ok; outcome=$Outcome; safeState=$SafeState; stage=$Stage
        transactionId=$TransactionId; package=$Package; source=$Source; special=$Special; probes=$null
        recovery=$Recovery; error=$Error; logFile=$null
    }
}

$results = @()

$results += Invoke-CcodTest 'exports only the four pure supervisor functions' {
    $names = @(Get-Command -Module SupervisorEngine -CommandType Function | Sort-Object Name | ForEach-Object Name)
    Assert-CcodExactEqual 'Add-CcodObservedEvent|Complete-CcodControllerRun|Get-CcodSupervisorDecision|Get-CcodTrayPresentation' ($names -join '|') 'public surface stays exact'
}

$results += Invoke-CcodTest 'waits when no current-session Codex exists' {
    $decision = Get-CcodSupervisorDecision -Context (New-CcodSupervisorContext -Ordinary @())
    Assert-CcodPropertyOrder $decision @('Action','Reason','Target','AttemptKey','SuppressionKey','EffectiveClassification','RequiresController') 'decision schema order'
    Assert-CcodExactEqual 'Wait' $decision.Action 'no process never launches Codex'
    Assert-CcodExactEqual 'NoCodex' $decision.Reason 'no process reason is stable'
    Assert-CcodTrue ($null -eq $decision.Target) 'no process has no target'
    Assert-CcodExactEqual $false $decision.RequiresController 'waiting reserves no worker'
}

$results += Invoke-CcodTest 'adopts a validated special and repairs a broken renderer even while automation is paused' {
    $validated = New-CcodSpecialObservation
    $adopt = Get-CcodSupervisorDecision -Context (New-CcodSupervisorContext -AutomationEnabled $false -Ordinary @() -Special @($validated))
    Assert-CcodExactEqual 'AdoptSpecial' $adopt.Action 'validated special is adopted before automation pause'
    Assert-CcodTrue ([object]::ReferenceEquals($validated.Snapshot,$adopt.Target)) 'adoption returns exact snapshot'
    Assert-CcodExactEqual $false $adopt.RequiresController 'adoption is a pure state update'

    $brokenSnapshot = New-CcodSupervisorSnapshot -ProcessId 201 -Mode Unrelated -RendererPort 41001 -MainPort 41002
    $broken = New-CcodSpecialObservation -Snapshot $brokenSnapshot -ProbeValid $false
    $repair = Get-CcodSupervisorDecision -Context (New-CcodSupervisorContext -AutomationEnabled $false -Ordinary @() -Special @($broken))
    Assert-CcodExactEqual 'RepairRenderer' $repair.Action 'renderer replacement is repaired before automation pause'
    Assert-CcodExactEqual 'RendererTargetChanged' $repair.Reason 'repair reason is stable'
    Assert-CcodTrue ([object]::ReferenceEquals($brokenSnapshot,$repair.Target)) 'repair uses immutable wrapper target'
    Assert-CcodExactEqual $true $repair.RequiresController 'repair reserves the serialized worker'
}

$results += Invoke-CcodTest 'fails closed on same-session root ambiguity or invalid immutable special identity' {
    $ordinary = New-CcodSupervisorSnapshot
    $secondOrdinary = New-CcodSupervisorSnapshot -ProcessId 101 -CreationTimeUtc '2030-02-03T04:00:01.0000000Z'
    $special = New-CcodSpecialObservation
    $invalidSpecial = New-CcodSpecialObservation -IdentityValid $false
    $contexts = @(
        (New-CcodSupervisorContext -Ordinary @($ordinary,$secondOrdinary)),
        (New-CcodSupervisorContext -Ordinary @() -Special @($special,(New-CcodSpecialObservation -Snapshot (New-CcodSupervisorSnapshot -ProcessId 202 -Mode Unrelated)))),
        (New-CcodSupervisorContext -Ordinary @($ordinary) -Special @($special)),
        (New-CcodSupervisorContext -Ordinary @() -Special @($invalidSpecial))
    )
    foreach ($context in $contexts) {
        $decision = Get-CcodSupervisorDecision -Context $context
        Assert-CcodExactEqual 'ShowError' $decision.Action 'ambiguous identity never selects a root'
        Assert-CcodExactEqual 'IdentityUncertain' $decision.Reason 'identity error is stable'
        Assert-CcodTrue ($null -eq $decision.Target) 'ambiguous identity has no target'
    }
}

$results += Invoke-CcodTest 'ignores foreign user and Session snapshots without targeting them' {
    $foreignOrdinary = New-CcodSupervisorSnapshot -ProcessId 901 -SessionId 2
    $foreignSpecial = New-CcodSpecialObservation -Snapshot (New-CcodSupervisorSnapshot -ProcessId 902 -UserSid 'S-1-5-21-foreign' -Mode Special -RendererPort 41001 -MainPort 41002)
    $none = Get-CcodSupervisorDecision -Context (New-CcodSupervisorContext -Ordinary @($foreignOrdinary) -Special @($foreignSpecial))
    Assert-CcodExactEqual 'Wait' $none.Action 'foreign roots are ignored'
    Assert-CcodTrue ($null -eq $none.Target) 'foreign roots are never targets'

    $local = New-CcodSupervisorSnapshot -ProcessId 102
    $one = Get-CcodSupervisorDecision -Context (New-CcodSupervisorContext -Ordinary @($foreignOrdinary,$local))
    Assert-CcodExactEqual 'ApplyOrdinary' $one.Action 'one local root remains eligible'
    Assert-CcodTrue ([object]::ReferenceEquals($local,$one.Target)) 'only local snapshot is targeted'
}

$results += Invoke-CcodTest 'enforces state-damage controller-busy and active-transaction precedence' {
    $damaged = New-CcodSupervisorContext -StateDamageBlocksActions $true -ControllerRunning $true -ActiveTransaction (New-CcodActiveTransition) -VerifiedPackages $null
    $decision = Get-CcodSupervisorDecision -Context $damaged
    Assert-CcodExactEqual 'ShowError' $decision.Action 'state damage dominates all work'
    Assert-CcodExactEqual 'StateDamaged' $decision.Reason 'damage reason is stable'

    $busy = Get-CcodSupervisorDecision -Context (New-CcodSupervisorContext -ControllerRunning $true -ActiveTransaction (New-CcodActiveTransition))
    Assert-CcodExactEqual 'Wait' $busy.Action 'busy worker dominates replay'
    Assert-CcodExactEqual 'ControllerBusy' $busy.Reason 'worker busy reason is stable'

    $replay = Get-CcodSupervisorDecision -Context (New-CcodSupervisorContext -ActiveTransaction (New-CcodActiveTransition))
    Assert-CcodExactEqual 'ReplayTransition' $replay.Action 'durable work replays before new process work'
    Assert-CcodExactEqual $true $replay.RequiresController 'replay reserves the serialized worker'
}

$results += Invoke-CcodTest 'rejects impossible durable crash stages before replay' {
    $missingLaunchPorts=New-CcodActiveTransition
    $missingLaunchPorts.stage='SpecialLaunchRequested'
    Assert-CcodThrows { Get-CcodSupervisorDecision -Context (New-CcodSupervisorContext -ActiveTransaction $missingLaunchPorts) | Out-Null } 'CCOD_SUPERVISOR_CONTEXT_INVALID'

    $specialWithoutPorts=New-CcodActiveTransition
    $specialWithoutPorts.stage='RecoveryLaunchRequested'
    $specialWithoutPorts.specialPid=200
    $specialWithoutPorts.specialCreationTimeUtc='2030-02-03T04:02:00.0000000Z'
    Assert-CcodThrows { Get-CcodSupervisorDecision -Context (New-CcodSupervisorContext -ActiveTransaction $specialWithoutPorts) | Out-Null } 'CCOD_SUPERVISOR_CONTEXT_INVALID'
}

$results += Invoke-CcodTest 'replays representative valid durable crash stages' {
    $manualIntent=New-CcodActiveTransition
    $manualIntent.sourcePid=$null
    $manualIntent.sourceCreationTimeUtc=$null

    $specialLaunch=New-CcodActiveTransition
    $specialLaunch.stage='SpecialLaunchRequested'
    $specialLaunch.mainPort=41002
    $specialLaunch.rendererPort=41001

    $recoveryLaunch=New-CcodActiveTransition
    $recoveryLaunch.stage='RecoveryLaunchRequested'
    $recoveryLaunch.mainPort=41002
    $recoveryLaunch.rendererPort=41001
    $recoveryLaunch.specialPid=200
    $recoveryLaunch.specialCreationTimeUtc='2030-02-03T04:02:00.0000000Z'

    $recovered=New-CcodActiveTransition
    $recovered.stage='Recovered'
    $recovered.mainPort=41002
    $recovered.rendererPort=41001
    $recovered.specialPid=200
    $recovered.specialCreationTimeUtc='2030-02-03T04:02:00.0000000Z'
    $recovered.recoveryPid=300
    $recovered.recoveryCreationTimeUtc='2030-02-03T04:03:00.0000000Z'

    $ordinaryClose=New-CcodActiveTransition
    $ordinaryClose.stage='CloseRequested'

    $specialClosed=New-CcodActiveTransition
    $specialClosed.stage='Closed'
    $specialClosed.sourcePid=$null
    $specialClosed.sourceCreationTimeUtc=$null
    $specialClosed.mainPort=41002
    $specialClosed.rendererPort=41001
    $specialClosed.specialPid=200
    $specialClosed.specialCreationTimeUtc='2030-02-03T04:02:00.0000000Z'

    foreach($transition in @($manualIntent,$specialLaunch,$recoveryLaunch,$recovered,$ordinaryClose,$specialClosed)){
        $decision=Get-CcodSupervisorDecision -Context (New-CcodSupervisorContext -ActiveTransaction $transition)
        Assert-CcodExactEqual 'ReplayTransition' $decision.Action ("valid {0} remains replayable" -f $transition.stage)
    }
}

$results += Invoke-CcodTest 'keeps recovery ignored suppressed and already-attempted ordinary lifecycles while ignoring the legacy automation preference' {
    $target = New-CcodSupervisorSnapshot
    $attempt = '{0}|{1}' -f $target.Pid,$target.CreationTimeUtc
    $tuple = 'OpenAI.Codex_1.0.0.0_x64__2p2nqsd0c76g0|{0}|runtime-1' -f ('a' * 64)

    $ignore = [ordered]@{}; $ignore[($attempt + '|aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee')] = $true
    Assert-CcodExactEqual 'RecoveryIgnored' (Get-CcodSupervisorDecision -Context (New-CcodSupervisorContext -RecoveryIgnoreKeys $ignore)).Reason 'recovery lifecycle is not immediately retaken'
    $legacyPaused=Get-CcodSupervisorDecision -Context (New-CcodSupervisorContext -AutomationEnabled $false)
    Assert-CcodExactEqual 'ApplyOrdinary' $legacyPaused.Action 'legacy automation preference is migration data and cannot pause protection'
    Assert-CcodExactEqual 'Compatible' $legacyPaused.Reason 'legacy preference does not alter the internal compatibility decision'

    $suppressed = [ordered]@{}; $suppressed[$tuple] = $true
    Assert-CcodExactEqual 'DynamicSuppressed' (Get-CcodSupervisorDecision -Context (New-CcodSupervisorContext -SuppressionKeys $suppressed)).Reason 'exact tuple suppression keeps ordinary'

    $attempts = [ordered]@{}; $attempts[$attempt] = $true
    Assert-CcodExactEqual 'AlreadyAttempted' (Get-CcodSupervisorDecision -Context (New-CcodSupervisorContext -AttemptKeys $attempts)).Reason 'same lifecycle is attempted once'
}

$results += Invoke-CcodTest 'treats a new PID or creation time as a new eligible lifecycle' {
    $old = New-CcodSupervisorSnapshot
    $attempts = [ordered]@{}
    $attempts[('{0}|{1}' -f $old.Pid,$old.CreationTimeUtc)] = $true
    $new = New-CcodSupervisorSnapshot -ProcessId 101 -CreationTimeUtc '2030-02-03T04:00:01.0000000Z'
    $decision = Get-CcodSupervisorDecision -Context (New-CcodSupervisorContext -Ordinary @($new) -AttemptKeys $attempts)
    Assert-CcodExactEqual 'ApplyOrdinary' $decision.Action 'new lifecycle can be considered once'
    Assert-CcodExactEqual ('101|{0}' -f $new.CreationTimeUtc) $decision.AttemptKey 'attempt key binds PID and creation time'
}

$results += Invoke-CcodTest 'reserves a static-probe worker for blank classification and keeps static incompatibilities' {
    $inspect = Get-CcodSupervisorDecision -Context (New-CcodSupervisorContext -Classification $null)
    Assert-CcodExactEqual 'InspectOrdinary' $inspect.Action 'missing static evidence requests Task 4 probe'
    Assert-CcodExactEqual 'StaticProbeRequired' $inspect.Reason 'static probe reason is stable'
    Assert-CcodExactEqual $true $inspect.RequiresController 'static worker shares serialized worker gate'
    foreach ($classification in @('NativeModulePresent','UnknownOrIncompatible')) {
        $keep = Get-CcodSupervisorDecision -Context (New-CcodSupervisorContext -Classification $classification)
        Assert-CcodExactEqual 'KeepOrdinary' $keep.Action 'static incompatible class is never overridden'
        Assert-CcodExactEqual $classification $keep.Reason 'static reason is retained as stable enum'
    }
}

$results += Invoke-CcodTest 'keeps candidate compatibility internal and requires healthy state for a first candidate trial' {
    $legacyCandidate = Get-CcodSupervisorDecision -Context (New-CcodSupervisorContext -CandidateCompatibleOptIn $false)
    Assert-CcodExactEqual 'ApplyOrdinary' $legacyCandidate.Action 'legacy candidate preference is migration data and cannot command protection'
    Assert-CcodExactEqual 'Compatible' $legacyCandidate.Reason 'candidate compatibility remains an internal decision'
    $health = Get-CcodSupervisorDecision -Context (New-CcodSupervisorContext -AutomationEnabled $false -CandidateCompatibleOptIn $false -AutomaticCandidateTrialsAllowed $false)
    Assert-CcodExactEqual 'ApplyOrdinary' $health.Action 'all legacy false values remain migration data rather than guardian authority'
    Assert-CcodExactEqual 'Compatible' $health.Reason 'internal compatible classification alone authorizes the guardian lifecycle'
    $authorized = Get-CcodSupervisorDecision -Context (New-CcodSupervisorContext)
    Assert-CcodExactEqual 'ApplyOrdinary' $authorized.Action 'authorized candidate applies'
    Assert-CcodExactEqual 'CandidateCompatible' $authorized.EffectiveClassification 'first trial remains candidate classified'
}

$results += Invoke-CcodTest 'promotes only the exact successful package hash runtime record and honors exact failed history' {
    $tuple = 'OpenAI.Codex_1.0.0.0_x64__2p2nqsd0c76g0|{0}|runtime-1' -f ('a' * 64)
    $succeeded = New-CcodVerifiedStore -Key $tuple -Record (New-CcodVerifiedRecord)
    $promoted = Get-CcodSupervisorDecision -Context (New-CcodSupervisorContext -CandidateCompatibleOptIn $false -AutomaticCandidateTrialsAllowed $false -VerifiedPackages $succeeded)
    Assert-CcodExactEqual 'VerifiedCompatible' $promoted.EffectiveClassification 'exact dynamic proof promotes candidate'
    Assert-CcodExactEqual 'ApplyOrdinary' $promoted.Action 'verified tuple does not require first-trial gates'
    Assert-CcodExactEqual $tuple $promoted.SuppressionKey 'decision returns only exact available tuple key'

    $otherTuple = 'OpenAI.Codex_2.0.0.0_x64__2p2nqsd0c76g0|{0}|runtime-1' -f ('b' * 64)
    $mismatch = New-CcodVerifiedStore -Key $otherTuple -Record (New-CcodVerifiedRecord -PackageFullName 'OpenAI.Codex_2.0.0.0_x64__2p2nqsd0c76g0' -AppAsarSha256 ('b' * 64))
    $notPromoted = Get-CcodSupervisorDecision -Context (New-CcodSupervisorContext -CandidateCompatibleOptIn $false -VerifiedPackages $mismatch)
    Assert-CcodExactEqual 'CandidateCompatible' $notPromoted.EffectiveClassification 'other tuple history has no effect'

    $failed = New-CcodVerifiedStore -Key $tuple -Record (New-CcodVerifiedRecord -DynamicOutcome Failed -ProbeState NotRun)
    $suppressed = Get-CcodSupervisorDecision -Context (New-CcodSupervisorContext -VerifiedPackages $failed)
    Assert-CcodExactEqual 'DynamicSuppressed' $suppressed.Reason 'exact failed history suppresses tuple'
}

$results += Invoke-CcodTest 'rejects missing extra case-variant coercive and malformed context facts' {
    $cases = [Collections.Generic.List[object]]::new()
    $missing = New-CcodSupervisorContext; $missing.PSObject.Properties.Remove('RuntimeId'); $cases.Add($missing)
    $extra = New-CcodSupervisorContext; $extra | Add-Member -NotePropertyName Surprise -NotePropertyValue $true; $cases.Add($extra)
    $caseVariant = New-CcodSupervisorContext; $value=$caseVariant.AutomationEnabled; $caseVariant.PSObject.Properties.Remove('AutomationEnabled'); $caseVariant | Add-Member -NotePropertyName automationEnabled -NotePropertyValue $value; $cases.Add($caseVariant)
    $coerciveBool = New-CcodSupervisorContext; $coerciveBool.AutomaticCandidateTrialsAllowed='true'; $cases.Add($coerciveBool)
    $coerciveSession = New-CcodSupervisorContext; $coerciveSession.CurrentSessionId=[long]1; $cases.Add($coerciveSession)
    $badClass = New-CcodSupervisorContext; $badClass.Classification='VerifiedCompatible'; $cases.Add($badClass)
    $scalarArray = New-CcodSupervisorContext; $scalarArray.Ordinary=New-CcodSupervisorSnapshot; $cases.Add($scalarArray)
    $wrongMode = New-CcodSupervisorContext; $wrongMode.Ordinary=@(New-CcodSupervisorSnapshot -Mode Unrelated); $cases.Add($wrongMode)
    $missingStore = New-CcodSupervisorContext; $missingStore.VerifiedPackages=$null; $cases.Add($missingStore)
    $badStore = New-CcodSupervisorContext; $badStore.VerifiedPackages=[pscustomobject]@{schemaVersion='1';packages=[pscustomobject]@{}}; $cases.Add($badStore)
    $halfTuple = New-CcodSupervisorContext; $halfTuple.AppAsarSha256=$null; $cases.Add($halfTuple)
    foreach ($context in $cases) {
        Assert-CcodThrows { Get-CcodSupervisorDecision -Context $context | Out-Null } 'CCOD_SUPERVISOR_CONTEXT_INVALID'
    }
}

$results += Invoke-CcodTest 'does not mutate decision inputs or membership dictionaries' {
    $attempts=[ordered]@{'100|2030-02-03T03:59:59.0000000Z'='kept'}
    $ignore=[ordered]@{}
    $suppression=[ordered]@{}
    $context=New-CcodSupervisorContext -AttemptKeys $attempts -RecoveryIgnoreKeys $ignore -SuppressionKeys $suppression
    $before=$context | ConvertTo-Json -Depth 20 -Compress
    Get-CcodSupervisorDecision -Context $context | Out-Null
    $after=$context | ConvertTo-Json -Depth 20 -Compress
    Assert-CcodExactEqual $before $after 'decision is side-effect free'
    Assert-CcodExactEqual 'kept' $attempts['100|2030-02-03T03:59:59.0000000Z'] 'existing dictionary value is unchanged'
}

$results += Invoke-CcodTest 'deduplicates only exact canonical process lifecycles in caller memory' {
    $keys=[ordered]@{}
    $first=Add-CcodObservedEvent -ObservedKeys $keys -ProcessId 123 -CreationTimeUtc '2030-02-03T04:00:00.0000000Z'
    $second=Add-CcodObservedEvent -ObservedKeys $keys -ProcessId 123 -CreationTimeUtc '2030-02-03T04:00:00.0000000Z'
    Assert-CcodExactEqual $true $first 'first event is accepted as exact Boolean'
    Assert-CcodExactEqual $false $second 'duplicate event is exact false'
    Assert-CcodExactEqual 1 $keys.Count 'duplicate changes no count'
    Assert-CcodExactEqual $true $keys['123|2030-02-03T04:00:00.0000000Z'] 'stored value is non-secret truth'
    Assert-CcodThrows { Add-CcodObservedEvent -ObservedKeys $keys -ProcessId ([long]124) -CreationTimeUtc '2030-02-03T04:00:01.0000000Z' | Out-Null } 'CCOD_OBSERVED_EVENT_INVALID'
    Assert-CcodThrows { Add-CcodObservedEvent -ObservedKeys $keys -ProcessId 124 -CreationTimeUtc '2030-02-03T04:00:01Z' | Out-Null } 'CCOD_OBSERVED_EVENT_INVALID'
    Assert-CcodExactEqual 1 $keys.Count 'invalid events never mutate keys'
}

$results += Invoke-CcodTest 'reduces every allowed controller success tuple from proven safe state' {
    $source=New-CcodResultSource
    $special=New-CcodResultSpecial
    $package=New-CcodResultPackage
    $recovery=New-CcodRecoveryEvidence
    $recoverySource=New-CcodResultSource -ProcessId 300 -CreationTimeUtc '2030-02-03T04:03:00.0000000Z'
    $staleExpected=New-CcodSupervisorSnapshot -ProcessId 4596 -CreationTimeUtc '2030-02-03T04:00:00.0000000Z' -Mode Unrelated -RendererPort 41001 -MainPort 41002
    $staleExpected.Path='C:\Old\ChatGPT.exe';$staleExpected.CommandLine='"C:\Old\ChatGPT.exe" --remote-debugging-address=127.0.0.1 --remote-debugging-port=41001 --inspect=127.0.0.1:41002'
    $staleSource=New-CcodResultStaleSource $staleExpected
    $cases=@(
        @{Action='Apply';Outcome='Activated';Safe='SpecialValidated';Stage='Completed';Source=$null;Special=$special;Recovery=$null;State='Active'},
        @{Action='RepairStale';Outcome='Activated';Safe='SpecialValidated';Stage='Completed';Source=$staleSource;ExpectedSource=$staleExpected;Special=$special;Recovery=$null;State='Active'},
        @{Action='Inspect';Outcome='Inspected';Safe='SpecialValidated';Stage='Inspected';Source=$null;Special=$special;Recovery=$null;State='Active'},
        @{Action='Inspect';Outcome='Inspected';Safe='RendererRepairRequired';Stage='Inspected';Source=$null;Special=$special;Recovery=$null;State='Inspecting'},
        @{Action='Inspect';Outcome='Inspected';Safe='OrdinaryRunning';Stage='Inspected';Source=$source;Special=$null;Recovery=$null;State='Waiting'},
        @{Action='Inspect';Outcome='Inspected';Safe='NoCodex';Stage='Inspected';Source=$null;Special=$null;Recovery=$null;State='Waiting'},
        @{Action='Apply';Outcome='NoAction';Safe='NoCodex';Stage='Cancelled';Source=$source;Special=$null;Recovery=$null;State='Waiting'},
        @{Action='RepairRenderer';Outcome='NoAction';Safe='SpecialValidated';Stage='RendererRepaired';Source=$null;Special=$special;Recovery=$null;State='Active'},
        @{Action='Recover';Outcome='NoAction';Safe='SpecialValidated';Stage='Activated';Source=$null;Special=$special;Recovery=$null;State='Active'},
        @{Action='Recover';Outcome='NoAction';Safe='OrdinaryRunning';Stage='OrdinaryKept';Source=$source;Special=$null;Recovery=$null;State='Waiting'},
        @{Action='Recover';Outcome='NoAction';Safe='OrdinaryRunning';Stage='Cancelled';Source=$source;Special=$null;Recovery=$null;State='Waiting'},
        @{Action='Recover';Outcome='NoAction';Safe='NoCodex';Stage='Cancelled';Source=$null;Special=$null;Recovery=$null;State='Waiting'},
        @{Action='Apply';Outcome='Recovered';Safe='OrdinaryRunning';Stage='Recovered';Package=$package;Source=$recoverySource;Special=$null;Recovery=$recovery;State='Recovered'},
        @{Action='RepairStale';Outcome='Recovered';Safe='OrdinaryRunning';Stage='Recovered';Package=$package;Source=$recoverySource;ExpectedSource=$staleExpected;Special=$null;Recovery=$recovery;State='Recovered'},
        @{Action='RepairRenderer';Outcome='Recovered';Safe='OrdinaryRunning';Stage='Recovered';Package=$package;Source=$recoverySource;Special=$null;Recovery=$recovery;State='Recovered'},
        @{Action='Recover';Outcome='Recovered';Safe='OrdinaryRunning';Stage='Recovered';Package=$package;Source=$recoverySource;Special=$null;Recovery=$recovery;State='Recovered'},
        @{Action='Recover';Outcome='Closed';Safe='Closed';Stage='Closed';Source=$null;Special=$null;Recovery=$null;State='Waiting'}
    )
    foreach($case in $cases){
        $packageValue=$null
        if ($case.ContainsKey('Package')) { $packageValue=$case.Package }
        $expectedSource=$null;if($case.ContainsKey('ExpectedSource')){$expectedSource=$case.ExpectedSource}
        $result=New-CcodControllerResult -Action $case.Action -Outcome $case.Outcome -SafeState $case.Safe -Stage $case.Stage -Package $packageValue -Source $case.Source -Special $case.Special -Recovery $case.Recovery
        $reduced=Complete-CcodControllerRun -Result $result -ExpectedTransactionId $result.transactionId -ExpectedAction $case.Action -ExpectedRuntimeId 'runtime-1' -ExpectedSource $expectedSource
        Assert-CcodPropertyOrder $reduced @('SessionState','BlockAutomaticActions','AttemptKey','RecoveryIgnoreKey','SuppressionKey','ErrorCode','Reason') 'completion schema order'
        Assert-CcodExactEqual $case.State $reduced.SessionState ("{0}/{1}/{2} maps from safe tuple" -f $case.Action,$case.Outcome,$case.Safe)
        Assert-CcodExactEqual $false $reduced.BlockAutomaticActions 'proven success does not globally block'
    }
}

$results += Invoke-CcodTest 'copies only validated attempt recovery and suppression keys from proven recovery' {
    $source=New-CcodResultSource -ProcessId 300 -CreationTimeUtc '2030-02-03T04:03:00.0000000Z'
    $recovery=New-CcodRecoveryEvidence
    $result=New-CcodControllerResult -Action Apply -Outcome Recovered -SafeState OrdinaryRunning -Stage Recovered -Package (New-CcodResultPackage) -Source $source -Special $null -Recovery $recovery
    $before=$result|ConvertTo-Json -Depth 20 -Compress
    $reduced=Complete-CcodControllerRun -Result $result -ExpectedTransactionId $result.transactionId -ExpectedAction Apply -ExpectedRuntimeId 'runtime-1'
    Assert-CcodExactEqual '300|2030-02-03T04:03:00.0000000Z' $reduced.AttemptKey 'attempt derives only from source identity'
    Assert-CcodExactEqual $recovery.ignoreKey $reduced.RecoveryIgnoreKey 'validated recovery ignore key is copied'
    Assert-CcodExactEqual $recovery.suppressionKey $reduced.SuppressionKey 'validated suppression key is copied'
    Assert-CcodExactEqual $before ($result|ConvertTo-Json -Depth 20 -Compress) 'completion reducer does not mutate input'
}

$results += Invoke-CcodTest 'binds recovered suppression to exact package hash and expected safe runtime' {
    $priorId='11111111-2222-3333-4444-555555555555'
    $source=New-CcodResultSource -ProcessId 300 -CreationTimeUtc '2030-02-03T04:03:00.0000000Z'
    $recovery=New-CcodRecoveryEvidence -TransactionId $priorId
    $package=New-CcodResultPackage
    $valid=New-CcodControllerResult -Action Recover -Outcome Recovered -SafeState OrdinaryRunning -Stage Recovered -Package $package -Source $source -Special $null -Recovery $recovery
    $accepted=Complete-CcodControllerRun -Result $valid -ExpectedTransactionId $valid.transactionId -ExpectedAction Recover -ExpectedRuntimeId 'runtime-1'
    Assert-CcodExactEqual 'Recovered' $accepted.SessionState 'older replay prior ID remains independently valid'
    Assert-CcodExactEqual $recovery.ignoreKey $accepted.RecoveryIgnoreKey 'ignore key remains bound to prior transaction ID'

    $missingPackage=New-CcodControllerResult -Action Recover -Outcome Recovered -SafeState OrdinaryRunning -Stage Recovered -Package $null -Source $source -Special $null -Recovery $recovery
    Assert-CcodExactEqual 'CCOD_CONTROLLER_RESULT_INVALID' (Complete-CcodControllerRun -Result $missingPackage -ExpectedTransactionId $missingPackage.transactionId -ExpectedAction Recover -ExpectedRuntimeId 'runtime-1').ErrorCode 'recovery requires package identity'

    $wrongName=New-CcodControllerResult -Action Recover -Outcome Recovered -SafeState OrdinaryRunning -Stage Recovered -Package (New-CcodResultPackage -FullName 'OpenAI.Codex_2.0.0.0_x64__2p2nqsd0c76g0') -Source $source -Special $null -Recovery $recovery
    Assert-CcodExactEqual 'CCOD_CONTROLLER_RESULT_INVALID' (Complete-CcodControllerRun -Result $wrongName -ExpectedTransactionId $wrongName.transactionId -ExpectedAction Recover -ExpectedRuntimeId 'runtime-1').ErrorCode 'suppression package name must match result package'

    $wrongHash=New-CcodControllerResult -Action Recover -Outcome Recovered -SafeState OrdinaryRunning -Stage Recovered -Package (New-CcodResultPackage -AppAsarSha256 ('b' * 64)) -Source $source -Special $null -Recovery $recovery
    Assert-CcodExactEqual 'CCOD_CONTROLLER_RESULT_INVALID' (Complete-CcodControllerRun -Result $wrongHash -ExpectedTransactionId $wrongHash.transactionId -ExpectedAction Recover -ExpectedRuntimeId 'runtime-1').ErrorCode 'suppression hash must match result package'

    Assert-CcodExactEqual 'CCOD_CONTROLLER_RESULT_INVALID' (Complete-CcodControllerRun -Result $valid -ExpectedTransactionId $valid.transactionId -ExpectedAction Recover -ExpectedRuntimeId 'runtime-2').ErrorCode 'suppression runtime must match safe active runtime'
}

$results += Invoke-CcodTest 'fails closed for every exact controller failure and preserves only allowlisted stable code' {
    $error=[pscustomobject][ordered]@{code='CCOD_STATE_BLOCKED';stage='StaticProbe';message='The session operation failed safely. See the session log for details.'}
    $result=New-CcodControllerResult -Action Apply -Ok $false -Outcome Error -SafeState Error -Source (New-CcodResultSource) -Special $null -Error $error
    $reduced=Complete-CcodControllerRun -Result $result -ExpectedTransactionId $result.transactionId -ExpectedAction Apply -ExpectedRuntimeId 'runtime-1'
    Assert-CcodExactEqual 'Error' $reduced.SessionState 'false result never infers recovery'
    Assert-CcodExactEqual $true $reduced.BlockAutomaticActions 'false result blocks automatic actions'
    Assert-CcodExactEqual 'CCOD_STATE_BLOCKED' $reduced.ErrorCode 'already-sanitized stable code is preserved'
    Assert-CcodTrue ($null -eq $reduced.RecoveryIgnoreKey -and $null -eq $reduced.SuppressionKey) 'false result copies no recovery claims'
}

$results += Invoke-CcodTest 'reduces stale persisted-package evidence to one sanitized bounded reconciliation reason' {
    $error=[pscustomobject][ordered]@{code='CCOD_STATE_STALE_PACKAGE';stage='InspectState';message='The session operation failed safely. See the session log for details.'}
    $result=New-CcodControllerResult -Action Inspect -Ok $false -Outcome Error -SafeState Error -Special $null -Error $error
    $reduced=Complete-CcodControllerRun -Result $result -ExpectedTransactionId $result.transactionId -ExpectedAction Inspect -ExpectedRuntimeId 'runtime-1'
    Assert-CcodExactEqual 'Error' $reduced.SessionState 'stale persisted package stays fail closed'
    Assert-CcodExactEqual $true $reduced.BlockAutomaticActions 'stale persisted package blocks repeated automatic work'
    Assert-CcodExactEqual 'CCOD_STATE_STALE_PACKAGE' $reduced.ErrorCode 'stale package code remains in the closed controller allowlist'
    Assert-CcodExactEqual 'StalePackageStatus' $reduced.Reason 'stale package has one fixed presentation-safe reason'
    Assert-CcodTrue ($null -eq $reduced.AttemptKey -and $null -eq $reduced.RecoveryIgnoreKey -and $null -eq $reduced.SuppressionKey) 'stale evidence clears no state or key membership'
}

$results += Invoke-CcodTest 'preserves fail-closed stale remote-server closure codes for an actionable controller result' {
    foreach($code in @('CCOD_STALE_PACKAGE_AMBIGUOUS','CCOD_STALE_PACKAGE_UNPROVEN')){
        $error=[pscustomobject][ordered]@{code=$code;stage='OrdinaryStopped';message='The session operation failed safely. See the session log for details.'}
        $expected=New-CcodSupervisorSnapshot -ProcessId 4596 -CreationTimeUtc '2030-02-03T04:00:00.0000000Z' -Mode Unrelated -RendererPort 41001 -MainPort 41002
        $expected.Path='C:\Old\ChatGPT.exe';$expected.CommandLine='"C:\Old\ChatGPT.exe" --remote-debugging-address=127.0.0.1 --remote-debugging-port=41001 --inspect=127.0.0.1:41002'
        $source=New-CcodResultStaleSource $expected
        $result=New-CcodControllerResult -Action RepairStale -Ok $false -Outcome Error -SafeState Error -Source $source -Special $null -Error $error
        $reduced=Complete-CcodControllerRun -Result $result -ExpectedTransactionId $result.transactionId -ExpectedAction RepairStale -ExpectedRuntimeId 'runtime-1' -ExpectedSource $expected
        Assert-CcodExactEqual 'Error' $reduced.SessionState "$code remains fail closed"
        Assert-CcodExactEqual $true $reduced.BlockAutomaticActions "$code blocks another automatic special launch"
        Assert-CcodExactEqual $code $reduced.ErrorCode "$code survives controller validation"
        Assert-CcodExactEqual '4596|2030-02-03T04:00:00.0000000Z' $reduced.AttemptKey "$code remains bound to the consumed stale lifecycle"
    }
}

$results += Invoke-CcodTest 'correlates every RepairStale result source field to the dispatched request before Active' {
    $expected=New-CcodSupervisorSnapshot -ProcessId 4596 -CreationTimeUtc '2030-02-03T04:00:00.0000000Z' -Mode Unrelated -RendererPort 41001 -MainPort 41002
    $expected.Path='C:\Old\ChatGPT.exe';$expected.CommandLine='"C:\Old\ChatGPT.exe" --remote-debugging-address=127.0.0.1 --remote-debugging-port=41001 --inspect=127.0.0.1:41002'
    $source=New-CcodResultStaleSource $expected
    $valid=New-CcodControllerResult -Action RepairStale -Outcome Activated -SafeState SpecialValidated -Stage Completed -Source $source
    $accepted=Complete-CcodControllerRun -Result $valid -ExpectedTransactionId $valid.transactionId -ExpectedAction RepairStale -ExpectedRuntimeId 'runtime-1' -ExpectedSource $expected
    Assert-CcodExactEqual 'Active' $accepted.SessionState 'only the exact full stale source reaches Active'

    foreach($mutation in @(
        @{Name='pid';Value=[int]4597},
        @{Name='creationTimeUtc';Value='2030-02-03T04:00:01.0000000Z'},
        @{Name='path';Value='C:\Other\ChatGPT.exe'},
        @{Name='rendererPort';Value=[int]42001},
        @{Name='mainPort';Value=[int]42002}
    )){
        $fabricated=New-CcodResultStaleSource $expected;$fabricated.($mutation.Name)=$mutation.Value
        $result=New-CcodControllerResult -Action RepairStale -Outcome Activated -SafeState SpecialValidated -Stage Completed -Source $fabricated
        $reduced=Complete-CcodControllerRun -Result $result -ExpectedTransactionId $result.transactionId -ExpectedAction RepairStale -ExpectedRuntimeId 'runtime-1' -ExpectedSource $expected
        Assert-CcodExactEqual 'Error' $reduced.SessionState "$($mutation.Name) fabrication cannot reach Active"
        Assert-CcodExactEqual 'CCOD_CONTROLLER_RESULT_INVALID' $reduced.ErrorCode "$($mutation.Name) fabrication is an invalid correlated result"
    }
}

$results += Invoke-CcodTest 'fails closed on malformed contradictory or correlation-mismatched controller results' {
    $valid=New-CcodControllerResult
    $mismatch=Complete-CcodControllerRun -Result $valid -ExpectedTransactionId 'bbbbbbbb-cccc-dddd-eeee-ffffffffffff' -ExpectedAction Apply -ExpectedRuntimeId 'runtime-1'
    Assert-CcodExactEqual 'CCOD_CONTROLLER_RESULT_MISMATCH' $mismatch.ErrorCode 'transaction mismatch is distinct'

    $actionMismatch=Complete-CcodControllerRun -Result $valid -ExpectedTransactionId $valid.transactionId -ExpectedAction Inspect -ExpectedRuntimeId 'runtime-1'
    Assert-CcodExactEqual 'CCOD_CONTROLLER_RESULT_MISMATCH' $actionMismatch.ErrorCode 'action mismatch is distinct'

    $changed=New-CcodControllerResult -Action Inspect -Outcome Activated -SafeState SpecialValidated
    $unsafe=Complete-CcodControllerRun -Result $changed -ExpectedTransactionId $changed.transactionId -ExpectedAction Inspect -ExpectedRuntimeId 'runtime-1'
    Assert-CcodExactEqual 'Error' $unsafe.SessionState 'changing action cannot turn forbidden tuple active'
    Assert-CcodExactEqual 'CCOD_CONTROLLER_RESULT_INVALID' $unsafe.ErrorCode 'forbidden action tuple is invalid'

    $extra=New-CcodControllerResult; $extra|Add-Member -NotePropertyName stderr -NotePropertyValue 'secret'
    Assert-CcodExactEqual 'CCOD_CONTROLLER_RESULT_INVALID' (Complete-CcodControllerRun -Result $extra -ExpectedTransactionId $extra.transactionId -ExpectedAction Apply -ExpectedRuntimeId 'runtime-1').ErrorCode 'extra top-level data is rejected'

    $coercive=New-CcodControllerResult; $coercive.ok='true'
    Assert-CcodExactEqual 'CCOD_CONTROLLER_RESULT_INVALID' (Complete-CcodControllerRun -Result $coercive -ExpectedTransactionId $coercive.transactionId -ExpectedAction Apply -ExpectedRuntimeId 'runtime-1').ErrorCode 'coercive Boolean is rejected'

    $badRecovery=New-CcodRecoveryEvidence; $badRecovery|Add-Member -NotePropertyName commandLine -NotePropertyValue 'secret'
    $badRecoveryResult=New-CcodControllerResult -Action Recover -Outcome Recovered -SafeState OrdinaryRunning -Source (New-CcodResultSource -ProcessId 300 -CreationTimeUtc '2030-02-03T04:03:00.0000000Z') -Special $null -Recovery $badRecovery
    Assert-CcodExactEqual 'CCOD_CONTROLLER_RESULT_INVALID' (Complete-CcodControllerRun -Result $badRecoveryResult -ExpectedTransactionId $badRecoveryResult.transactionId -ExpectedAction Recover -ExpectedRuntimeId 'runtime-1').ErrorCode 'arbitrary recovery properties are rejected'

    $raw=[pscustomobject][ordered]@{code='CCOD_TOKEN_secret';stage='Failure';message='raw token'}
    $rawResult=New-CcodControllerResult -Action Apply -Ok $false -Outcome Error -SafeState Error -Special $null -Error $raw
    Assert-CcodExactEqual 'CCOD_CONTROLLER_RESULT_INVALID' (Complete-CcodControllerRun -Result $rawResult -ExpectedTransactionId $rawResult.transactionId -ExpectedAction Apply -ExpectedRuntimeId 'runtime-1').ErrorCode 'untrusted error identifiers are not copied'
}

$results += Invoke-CcodTest 'rejects a success tuple reported from an impossible controller stage' {
    $impossible=New-CcodControllerResult -Action Apply -Outcome Activated -SafeState SpecialValidated -Stage InputValidation
    $reduced=Complete-CcodControllerRun -Result $impossible -ExpectedTransactionId $impossible.transactionId -ExpectedAction Apply -ExpectedRuntimeId 'runtime-1'
    Assert-CcodExactEqual 'Error' $reduced.SessionState 'InputValidation can never prove activation'
    Assert-CcodExactEqual 'CCOD_CONTROLLER_RESULT_INVALID' $reduced.ErrorCode 'impossible success stage is invalid'
}

$results += Invoke-CcodTest 'reduces explicit null and empty completion inputs without binder exceptions' {
    $valid=New-CcodControllerResult
    $cases=@(
        @{Result=$null;Id=$valid.transactionId;Action='Apply';Runtime='runtime-1'},
        @{Result='';Id=$valid.transactionId;Action='Apply';Runtime='runtime-1'},
        @{Result=$valid;Id=$null;Action='Apply';Runtime='runtime-1'},
        @{Result=$valid;Id='';Action='Apply';Runtime='runtime-1'},
        @{Result=$valid;Id=$valid.transactionId;Action=$null;Runtime='runtime-1'},
        @{Result=$valid;Id=$valid.transactionId;Action='';Runtime='runtime-1'},
        @{Result=$valid;Id=$valid.transactionId;Action='Apply';Runtime=$null},
        @{Result=$valid;Id=$valid.transactionId;Action='Apply';Runtime=''}
    )
    foreach($case in $cases){
        $reduced=Complete-CcodControllerRun -Result $case.Result -ExpectedTransactionId $case.Id -ExpectedAction $case.Action -ExpectedRuntimeId $case.Runtime
        Assert-CcodPropertyOrder $reduced @('SessionState','BlockAutomaticActions','AttemptKey','RecoveryIgnoreKey','SuppressionKey','ErrorCode','Reason') 'invalid completion still returns exact schema'
        Assert-CcodExactEqual 'Error' $reduced.SessionState 'invalid completion is fail closed'
        Assert-CcodExactEqual $true $reduced.BlockAutomaticActions 'invalid completion blocks actions'
        Assert-CcodExactEqual 'CCOD_CONTROLLER_RESULT_INVALID' $reduced.ErrorCode 'invalid completion uses stable code'
    }
}

$results += Invoke-CcodTest 'projects the truthful v2 connection and protection truth table' {
    $fields=@('Color','ConnectionState','ProtectionState','RepairEnabled','LanguageEnabled','OpenLogsEnabled','AboutEnabled','ExitEnabled','Busy')
    $matrix=@(
        @{Connection='WaitingForCodex';Color='Gray';Repair=$false},
        @{Connection='Checking';Color='Yellow';Repair=$false},
        @{Connection='Connected';Color='Green';Repair=$false},
        @{Connection='RepairNeeded';Color='Yellow';Repair=$true},
        @{Connection='Error';Color='Red';Repair=$false}
    )
    foreach($case in $matrix){
        $view=Get-CcodTrayPresentation -ConnectionState $case.Connection -ProtectionState Running -Busy:$false -StateDamageBlocksActions:$false
        Assert-CcodPropertyOrder $view $fields "$($case.Connection) v2 presentation has the exact ordered contract"
        Assert-CcodExactEqual $case.Connection $view.ConnectionState "$($case.Connection) remains a direct current-evidence projection"
        Assert-CcodExactEqual 'Running' $view.ProtectionState "$($case.Connection) preserves current protection state"
        Assert-CcodExactEqual $case.Color $view.Color "$($case.Connection) color"
        Assert-CcodExactEqual $case.Repair $view.RepairEnabled "$($case.Connection) repair eligibility"
        Assert-CcodExactEqual $true $view.OpenLogsEnabled "$($case.Connection) retains logs"
        Assert-CcodExactEqual $true $view.AboutEnabled "$($case.Connection) retains About"
    }
    foreach($protection in @('Running','Reconnecting','Stopping')){
        $view=Get-CcodTrayPresentation -ConnectionState RepairNeeded -ProtectionState $protection -Busy:$false -StateDamageBlocksActions:$false
        Assert-CcodExactEqual $protection $view.ProtectionState "$protection is independently truthful"
    }
    $busy=Get-CcodTrayPresentation -ConnectionState RepairNeeded -ProtectionState Reconnecting -Busy:$true -StateDamageBlocksActions:$false
    Assert-CcodExactEqual $false $busy.RepairEnabled 'busy lifecycle disables repair'
    Assert-CcodExactEqual $false $busy.LanguageEnabled 'busy lifecycle disables language changes'
    Assert-CcodExactEqual $false $busy.ExitEnabled 'busy lifecycle disables exit'
    $damaged=Get-CcodTrayPresentation -ConnectionState RepairNeeded -ProtectionState Running -Busy:$false -StateDamageBlocksActions:$true
    Assert-CcodExactEqual $false $damaged.RepairEnabled 'state damage disables repair'
    Assert-CcodExactEqual $false $damaged.LanguageEnabled 'state damage disables language changes'
    Assert-CcodExactEqual $false $damaged.ExitEnabled 'state damage disables exit'
}

$results += Invoke-CcodTest 'contains no reachable process package registry WMI task UI port Node or file command' {
    $tokens=$null; $parseErrors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($modulePath,[ref]$tokens,[ref]$parseErrors)
    Assert-CcodExactEqual 0 @($parseErrors).Count 'module parses before command audit'
    $dangerous=@(
        'Get-Process','Start-Process','Stop-Process','Get-AppxPackage','Get-CimInstance','Get-WmiObject',
        'Register-WmiEvent','Register-ObjectEvent','Register-ScheduledTask','schtasks','New-Object','Add-Type',
        'Test-NetConnection','Invoke-WebRequest','Invoke-RestMethod','node','Set-Content','Add-Content','Out-File',
        'Remove-Item','Move-Item','Copy-Item','New-Item','Get-Content','Import-Module'
    )
    $commands=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst]},$true) | ForEach-Object {$_.GetCommandName()} | Where-Object {$null -ne $_})
    foreach($name in $commands){Assert-CcodTrue ($dangerous -cnotcontains $name) "pure module cannot reach $name"}
}

$results | Format-Table -AutoSize
Write-Host ("Supervisor engine self-test passed: {0}" -f $results.Count)
