$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestSupport.ps1')

$repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$installLifecycleModule = Join-Path $repositoryRoot 'src\persistence\modules\InstallLifecycle.psm1'
if (-not (Test-Path -LiteralPath $installLifecycleModule -PathType Leaf)) {
    throw "InstallLifecycle module is missing: $installLifecycleModule"
}
Import-Module $installLifecycleModule -Force
Import-Module (Join-Path $repositoryRoot 'src\persistence\modules\StateStore.psm1') -Force
Import-Module (Join-Path $repositoryRoot 'src\persistence\modules\UiPreferences.psm1') -Force
Import-Module (Join-Path $repositoryRoot 'src\persistence\modules\RuntimeManifest.psm1') -Force
Import-Module (Join-Path $repositoryRoot 'src\persistence\modules\LifecycleEpoch.psm1') -Force

function New-CcodLifecycleTempRoot {
    return (Join-Path ([IO.Path]::GetTempPath()) ("ccod-lifecycle-" + [guid]::NewGuid().ToString('N')))
}

function New-CcodLifecycleSourceFixture {
    param(
        [Parameter(Mandatory)][string]$Root,
        [string]$Version = '2.0.0-test'
    )

    New-Item -ItemType Directory -Path (Join-Path $Root 'src\runtime') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $Root 'src\persistence\modules') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $Root 'src\persistence\resources') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $Root 'bin') -Force | Out-Null
    [IO.File]::WriteAllText(
        (Join-Path $Root 'package.json'),
        (@{ name = 'codexremote-fix'; version = $Version; private = $true } | ConvertTo-Json -Depth 4),
        [Text.UTF8Encoding]::new($false)
    )
    foreach ($leaf in @('Test-CodexControlOtherDevices.ps1', 'Start-CodexControlOtherDevices.ps1', 'Reset-CodexControlOtherDevices.ps1')) {
        [IO.File]::WriteAllText((Join-Path $Root $leaf), "# $leaf`r`nWrite-Output 'fixture'`r`n", [Text.UTF8Encoding]::new($false))
    }
    [IO.File]::WriteAllText((Join-Path $Root 'src\check-package.mjs'), "export default 'fixture';`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $Root 'src\runtime\orchestrator.js'), "module.exports = 'fixture';`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $Root 'src\runtime\main-payload.js'), "module.exports = 'fixture-$Version';`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $Root 'src\runtime\renderer-payload.js'), "module.exports = 'fixture';`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $Root 'src\runtime\cdp.js'), "module.exports = 'fixture';`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $Root 'src\persistence\Supervisor.ps1'), "# Supervisor fixture $Version`r`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $Root 'src\persistence\SessionController.ps1'), "# Controller fixture`r`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $Root 'src\persistence\StaticProbeWorker.ps1'), "# Worker fixture`r`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $Root 'src\persistence\LifecycleWorker.ps1'), "# Lifecycle worker fixture`r`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $Root 'src\persistence\UninstallBootstrap.ps1'), "# Uninstall bootstrap fixture`r`n", [Text.UTF8Encoding]::new($false))
    foreach ($module in @('PersistenceIO.psm1', 'RuntimeManifest.psm1', 'CompatibilityProbe.psm1', 'ProcessControl.psm1', 'StateStore.psm1', 'TransitionJournal.psm1', 'SessionEngine.psm1', 'SupervisorEngine.psm1', 'KernelObjects.psm1', 'TrayUi.psm1', 'UiLocalization.psm1', 'UiPreferences.psm1', 'ScheduledTask.psm1')) {
        [IO.File]::WriteAllText((Join-Path $Root "src\persistence\modules\$module"), "# $module`r`n", [Text.UTF8Encoding]::new($false))
    }
    [IO.File]::WriteAllText((Join-Path $Root 'src\persistence\resources\ui.en-US.json'), '{"schemaVersion":1,"language":"en-US"}', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $Root 'src\persistence\resources\ui.zh-CN.json'), '{"schemaVersion":1,"language":"zh-CN"}', [Text.UTF8Encoding]::new($false))
    foreach ($trayHostFile in @('CodexRemote.TrayHost.exe', 'CodexRemote.TrayHost.exe.config', 'trayhost-build-provenance.json')) {
        [IO.File]::WriteAllText((Join-Path $Root "bin\$trayHostFile"), "fixture $trayHostFile`r`n", [Text.UTF8Encoding]::new($false))
    }
    return $Root
}

function New-CcodLifecycleFakeNode {
    param([Parameter(Mandatory)][string]$Root)
    New-Item -ItemType Directory -Path (Join-Path $Root 'node') -Force | Out-Null
    $nodePath = Join-Path $Root 'node\node.exe'
    [IO.File]::WriteAllText($nodePath, 'fake node', [Text.UTF8Encoding]::new($false))
    return $nodePath
}

function New-CcodLifecycleIdentity {
    return [pscustomobject][ordered]@{
        UserSid = 'S-1-5-21-111-222-333-1001'
        SessionId = [int]1
        Pid = [int]41
        CreationTimeUtc = '2030-02-03T03:00:00.0000000Z'
    }
}

function New-CcodLifecycleNormalizeReceipt {
    param([bool]$SpecialPresent, [bool]$Normalized, [string]$Outcome = 'NoSpecial')
    return [pscustomobject][ordered]@{ SchemaVersion = 1; SpecialPresent = $SpecialPresent; Normalized = $Normalized; Outcome = $Outcome }
}

function New-CcodLifecycleFake {
    param([string]$NodePath)

    $world = [pscustomobject]@{
        Calls = [Collections.Generic.List[string]]::new()
        ValidateSource = $true
        NodePath = $NodePath
        Identity = New-CcodLifecycleIdentity
        NowUtc = [DateTime]::Parse('2030-02-03T03:04:05Z').ToUniversalTime()
        TaskInstalled = 0
        TaskRemoved = 0
        TaskAbsent = $true
        TaskStarted = 0
        TaskIdle = $true
        TaskIdleWaits = 0
        AutomationPaused = 0
        TransitionLeaseCalls = 0
        ShutdownSignaled = 0
        WaitSupervisorExit = $true
        OldSupervisorExitProven = $false
        NewSupervisorReady = $true
        NewTrayReady = $true
        Phases = [Collections.Generic.List[string]]::new()
        ActiveLifecycleRequest = $null
        SetActiveFailure = $null
        StartTaskFailure = $false
        TerminateSupervisorCalls = 0
        LastTerminateIdentity = $null
        SupervisorIdentityCurrent = $true
        SupervisorIdentityChecks = 0
        SupervisorIdentityVerified = $true
        SupervisorIdentityVerifications = 0
        TrayHostIdentities = @()
        ExactProcessExit = $true
        ExactProcessIdentityCurrent = $true
        ExactProcessTerminate = $true
        ExactProcessWaits = 0
        ExactProcessTerminates = 0
        InstallLeaseCalls = 0
        InstallLeaseReleased = 0
        InstallLeaseOutcome = 'Acquired'
        ShutdownGateOpened = 0
        ShutdownGateClosed = 0
        FallbackSupervisor = $null
        FallbackSupervisorLookups = 0
        SupervisorAbsent = $true
        SupervisorAbsenceChecks = 0
        NormalizeReceipt = New-CcodLifecycleNormalizeReceipt -SpecialPresent $false -Normalized $false
        NormalizeCalls = 0
        LegacyCompatibilityReceipt = New-CcodLifecycleNormalizeReceipt -SpecialPresent $false -Normalized $true -Outcome 'LegacyNoSpecialCompatibility'
        LegacyCompatibilityCalls = 0
        LegacyCompatibilityVerifyCalls = 0
        LegacyCompatibilityVerified = $true
        KeyPath = $null
        BackupCalls = 0
        RemoveKeyCalls = 0
        LastBackupPath = $null
        LogRecords = [Collections.Generic.List[object]]::new()
        FailLogCode = $null
        CopyOverride = $null
    }
    $adapters = @{}
    $adapters.ValidateSource = { param($SourceRoot) $world.Calls.Add("Validate:$([IO.Path]::GetFileName($SourceRoot))"); [bool]$world.ValidateSource }.GetNewClosure()
    $adapters.GetProjectVersion = { param($SourceRoot) (Get-Content -LiteralPath (Join-Path $SourceRoot 'package.json') -Raw | ConvertFrom-Json).version }.GetNewClosure()
    $adapters.DiscoverNodeCandidates = { $world.Calls.Add('DiscoverNode'); @($world.NodePath) }.GetNewClosure()
    $adapters.ValidateNodeCandidate = { param($Path) $world.Calls.Add("ValidateNode:$([IO.Path]::GetFileName($Path))"); $Path -ceq $world.NodePath }.GetNewClosure()
    $adapters.GetCurrentIdentity = { $world.Calls.Add('Identity'); $world.Identity }.GetNewClosure()
    $adapters.UtcNow = { $world.Calls.Add('Now'); $world.NowUtc }.GetNewClosure()
    $adapters.NewActivationId = { 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' }.GetNewClosure()
    $adapters.WriteActivationReceipt = {
        param($InstallRoot, $Receipt)
        $world.Phases.Add([string]$Receipt.phase)
        $stateRoot = Join-Path $InstallRoot 'state'
        [IO.Directory]::CreateDirectory($stateRoot) | Out-Null
        [IO.File]::WriteAllText((Join-Path $stateRoot 'post-install-activation.json'), ($Receipt | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    }.GetNewClosure()
    $adapters.ReadActiveLifecycleRequest = { param($StateRoot) $world.Calls.Add('ReadActiveLifecycleRequest');$world.ActiveLifecycleRequest }.GetNewClosure()
    $adapters.WaitNewRuntimeReady = {
        param($InstallRoot, $RuntimeId, $RuntimeGeneration, $Identity, $TaskStartedAtUtc, $TimeoutMilliseconds)
        [pscustomobject][ordered]@{ SupervisorReady = [bool]$world.NewSupervisorReady; TrayReady = [bool]$world.NewTrayReady }
    }.GetNewClosure()
    $adapters.InstallSupervisorTask = { param($InstallRoot, $UserSid) $world.Calls.Add("InstallTask:$([IO.Path]::GetFileName($InstallRoot)):$UserSid"); $world.TaskInstalled++ }.GetNewClosure()
    $adapters.RemoveSupervisorTask = { $world.Calls.Add('RemoveTask'); $world.TaskRemoved++ }.GetNewClosure()
    $adapters.TestSupervisorTaskAbsent = { $world.Calls.Add('TaskAbsent'); [bool]$world.TaskAbsent }.GetNewClosure()
    $adapters.StartSupervisorTask = { $world.Calls.Add('StartTask');if($world.StartTaskFailure){throw 'PRIVATE_TASK_START_SECRET'};$world.TaskStarted++ }.GetNewClosure()
    $adapters.WaitSupervisorTaskIdle = { param($TimeoutMilliseconds) $world.Calls.Add("WaitTaskIdle:$TimeoutMilliseconds"); $world.TaskIdleWaits++; [bool]$world.TaskIdle }.GetNewClosure()
    $adapters.SignalSupervisorShutdown = { param($UserSid, $SessionId) $world.Calls.Add("SignalShutdown:${UserSid}:${SessionId}"); $world.ShutdownSignaled++ }.GetNewClosure()
    $adapters.FindSupervisorFallback = { param($InstallRoot, $Identity) $world.Calls.Add("FindSupervisorFallback:$([IO.Path]::GetFileName($InstallRoot)):$($Identity.UserSid):$($Identity.SessionId)"); $world.FallbackSupervisorLookups++; $world.FallbackSupervisor }.GetNewClosure()
    $adapters.TestSupervisorIdentity = { param($InstallRoot, $SupervisorIdentity, $Identity) $world.Calls.Add(('VerifySupervisor:{0}:{1}' -f [IO.Path]::GetFileName($InstallRoot),$SupervisorIdentity.Pid)); $world.SupervisorIdentityVerifications++; [bool]$world.SupervisorIdentityVerified }.GetNewClosure()
    $adapters.TestSupervisorAbsent = { param($InstallRoot, $Identity) $world.Calls.Add(('SupervisorAbsent:{0}:{1}:{2}' -f [IO.Path]::GetFileName($InstallRoot),$Identity.UserSid,$Identity.SessionId)); $world.SupervisorAbsenceChecks++; [bool]$world.SupervisorAbsent }.GetNewClosure()
    $adapters.FindTrayHostIdentities = { param($InstallRoot, $RuntimeId, $Identity) $world.Calls.Add("FindTray:$RuntimeId"); @($world.TrayHostIdentities) }.GetNewClosure()
    $adapters.WaitSupervisorExit = {
        param($SupervisorIdentity, $TimeoutMilliseconds)
        $world.Calls.Add("WaitSupervisor:$($SupervisorIdentity.Pid):$TimeoutMilliseconds")
        $exited = [bool]$world.WaitSupervisorExit -or $world.TerminateSupervisorCalls -gt 0
        $world.OldSupervisorExitProven = $exited
        $exited
    }.GetNewClosure()
    $adapters.IsSupervisorIdentityCurrent = { param($SupervisorIdentity) $world.Calls.Add("CheckSupervisor:$($SupervisorIdentity.Pid)"); $world.SupervisorIdentityChecks++; [bool]$world.SupervisorIdentityCurrent }.GetNewClosure()
    $adapters.IsExactProcessIdentityCurrent = { param($ProcessIdentity) $world.Calls.Add("CheckExact:$($ProcessIdentity.Pid)"); [bool]$world.ExactProcessIdentityCurrent }.GetNewClosure()
    $adapters.TerminateSupervisor = { param($SupervisorIdentity) $world.Calls.Add("TerminateSupervisor:$($SupervisorIdentity.Pid)"); $world.TerminateSupervisorCalls++; $world.LastTerminateIdentity = $SupervisorIdentity; $true }.GetNewClosure()
    $adapters.TerminateExactProcess = { param($ProcessIdentity) $world.Calls.Add("TerminateExact:$($ProcessIdentity.Pid)"); $world.ExactProcessTerminates++; [bool]$world.ExactProcessTerminate }.GetNewClosure()
    $adapters.WaitExactProcessExit = { param($ProcessIdentity, $TimeoutMilliseconds) $world.Calls.Add("WaitExact:$($ProcessIdentity.Pid):$TimeoutMilliseconds"); $world.ExactProcessWaits++; [bool]$world.ExactProcessExit }.GetNewClosure()
    $adapters.EnterInstallLease = {
        param($UserSid)
        $world.Calls.Add("EnterInstallLease:$UserSid")
        $world.InstallLeaseCalls++
        [pscustomobject][ordered]@{ Outcome = [string]$world.InstallLeaseOutcome }
    }.GetNewClosure()
    $adapters.ExitInstallLease = {
        param($Lease)
        $world.Calls.Add('ExitInstallLease')
        $world.InstallLeaseReleased++
        $true
    }.GetNewClosure()
    $adapters.EnterLifecycleOwnership = {
        param($InstallRoot, $RuntimeId, $RuntimeGeneration, $OwnerIdentity, $UserSid, $SessionId)
        [pscustomobject][ordered]@{
            schemaVersion=1
            lease=[pscustomobject]@{ Released=$false }
            epoch=[UInt64]1
            runtimeId=[string]$RuntimeId
            runtimeGeneration=[UInt64]$RuntimeGeneration
            ownerIdentity=$OwnerIdentity
            released=$false
        }
    }.GetNewClosure()
    $adapters.SetActiveRuntime = {
        param($InstallRoot, $RuntimeId, $Ownership)
        if ($null -ne $world.SetActiveFailure) { & $world.SetActiveFailure $InstallRoot $RuntimeId $Ownership }
        $assertFence = { param($Root, $Receipt, $ExpectActivePointer) if ($Receipt.released) { throw 'released lifecycle owner' }; $true }
        Set-CcodActiveRuntime -InstallRoot $InstallRoot -NewRuntimeId $RuntimeId -Ownership $Ownership -Adapters @{ AssertLifecycleFence=$assertFence }
    }.GetNewClosure()
    $adapters.ExitLifecycleOwnership = {
        param($Ownership)
        $world.Calls.Add('ExitLifecycleOwnership')
        if ($Ownership.released) { return $false }
        $Ownership.released = $true
        $Ownership.lease.Released = $true
        $true
    }.GetNewClosure()
    $adapters.CreateSupervisorShutdownGate = {
        param($UserSid, $SessionId)
        $world.Calls.Add("OpenShutdownGate:${UserSid}:$SessionId")
        $world.ShutdownGateOpened++
        [pscustomobject][ordered]@{ Gate = 'Fake' }
    }.GetNewClosure()
    $adapters.CloseSupervisorShutdownGate = {
        param($Gate)
        $world.Calls.Add('CloseShutdownGate')
        $world.ShutdownGateClosed++
    }.GetNewClosure()
    $adapters.NormalizeSpecialSession = { param($InstallRoot, $RuntimeId, $Identity) $world.Calls.Add("Normalize:$RuntimeId"); $world.NormalizeCalls++; $world.NormalizeReceipt }.GetNewClosure()
    $adapters.NormalizeLegacyControllerCompatibility = { param($InstallRoot, $RuntimeId, $Identity, $Transaction) $world.Calls.Add("LegacyCompatibility:$RuntimeId"); $world.LegacyCompatibilityCalls++; $world.LegacyCompatibilityReceipt }.GetNewClosure()
    $adapters.VerifyLegacyControllerCompatibility = { param($InstallRoot, $RuntimeId, $Identity, $Transaction) $world.Calls.Add("VerifyLegacyCompatibility:$RuntimeId"); $world.LegacyCompatibilityVerifyCalls++; [bool]$world.LegacyCompatibilityVerified }.GetNewClosure()
    $adapters.SetAutomationEnabled = { param($StateRoot, $Enabled) $world.Calls.Add("Automation:$Enabled"); $world.AutomationPaused++ }.GetNewClosure()
    $adapters.EnterTransitionLease = { param($UserSid, $SessionId) $world.Calls.Add("EnterTransitionLease"); $world.TransitionLeaseCalls++; [pscustomobject][ordered]@{ SchemaVersion = 1; Name = "Fake-Transition"; Kind = 'Transition'; Outcome = 'Acquired'; CreatedNew = $false; Abandoned = $false; Handle = [pscustomobject]@{ Kind = 'Mutex' }; OwnerManagedThreadId = [Threading.Thread]::CurrentThread.ManagedThreadId; Released = $false } }.GetNewClosure()
    $adapters.ExitTransitionLease = { param($Lease) $world.Calls.Add('ExitTransitionLease'); $true }.GetNewClosure()
    $adapters.CopyFile = {
        param($Source, $Destination)
        $world.Calls.Add("Copy:$([IO.Path]::GetFileName($Source))")
        if ($null -ne $world.CopyOverride -and $Source -like $world.CopyOverride.Match) {
            & $world.CopyOverride.Action $Source $Destination
            return
        }
        [IO.Directory]::CreateDirectory((Split-Path $Destination -Parent)) | Out-Null
        [IO.File]::Copy($Source, $Destination, $true)
    }.GetNewClosure()
    $adapters.WriteLog = {
        param($InstallRoot, $Record)
        $world.Calls.Add("Log:$($Record.code)")
        if ($null -ne $world.FailLogCode -and [string]$Record.code -ceq [string]$world.FailLogCode) {
            throw 'PRIVATE_POST_READY_LOG_FAILURE'
        }
        $world.LogRecords.Add($Record)
    }.GetNewClosure()
    [pscustomobject]@{ World = $world; Adapters = $adapters }
}

function Read-CcodLifecycleActivePointer {
    param([Parameter(Mandatory)][string]$Root)
    return (Get-Content -LiteralPath (Join-Path $Root 'active.json') -Raw | ConvertFrom-Json)
}

function Set-CcodLifecycleTestStatus {
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$RuntimeId
    )

    $status = [ordered]@{
        schemaVersion = 1
        session = [ordered]@{
            supervisorPid = 41
            supervisorCreationTimeUtc = '2030-02-03T03:00:00.0000000Z'
            sessionId = '1'
            runtimeId = $RuntimeId
            sessionState = 'Ordinary'
            codex = $null
        }
    }
    [IO.File]::WriteAllText(
        (Join-Path $InstallRoot 'state\status.json'),
        ($status | ConvertTo-Json -Depth 6),
        [Text.UTF8Encoding]::new($false)
    )
}

function New-CcodLifecycleUninstallTransaction {
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)]$Fake,
        [ValidateSet('Requested','Recovering','RecoveryProven','StoppingProtection','ProtectionStopped','TaskRemoved','ApplicationStateRemoved','ReadyForInno')][string]$Phase = 'Requested'
    )

    $pointer = Read-CcodLifecycleActivePointer -Root $InstallRoot
    $windowsIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $process = [Diagnostics.Process]::GetCurrentProcess()
    try {
        $ownerIdentity = [pscustomobject][ordered]@{
            pid = [int]$process.Id
            creationTimeUtc = $process.StartTime.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        }
        $ownership = Enter-CcodLifecycleOwnership -InstallRoot $InstallRoot -RuntimeId ([string]$pointer.activeRuntime) -RuntimeGeneration ([uint64]$pointer.generation) -OwnerIdentity $ownerIdentity -UserSid $windowsIdentity.User.Value -SessionId ([int]$process.SessionId)
        try { $epoch = [uint64]$ownership.epoch }
        finally { [void](Exit-CcodLifecycleOwnership -Ownership $ownership) }
    } finally {
        $process.Dispose()
        $windowsIdentity.Dispose()
    }
    $timestamp = $Fake.World.NowUtc.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        transactionId = [guid]::NewGuid().ToString('D')
        runtimeId = [string]$pointer.activeRuntime
        runtimeGeneration = [uint64]$pointer.generation
        leaseEpoch = [uint64]$epoch
        userSid = [string]$Fake.World.Identity.UserSid
        sessionId = [int]$Fake.World.Identity.SessionId
        phase = $Phase
        resumePhase = $Phase
        createdAtUtc = $timestamp
        updatedAtUtc = $timestamp
        errorCode = $null
    }
}

function Invoke-CcodLifecycleUninstallCleanupTest {
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)]$Transaction,
        [Parameter(Mandatory)][hashtable]$Adapters
    )

    $written = [Collections.Generic.List[string]]::new()
    $writer = {
        param($Value)
        $written.Add([string]$Value.phase)
    }.GetNewClosure()
    $module = Get-Module -Name InstallLifecycle -ErrorAction Stop
    $result = & $module {
        param($Root,$Value,$WriteTransaction,$LifecycleAdapters)
        Invoke-CcodUninstallCleanup -InstallRoot $Root -Transaction $Value -WriteTransaction $WriteTransaction -Adapters $LifecycleAdapters
    } $InstallRoot $Transaction $writer $Adapters
    return [pscustomobject][ordered]@{ Result = $result; WrittenPhases = @($written) }
}

$results = @()

$results += Invoke-CcodTest 'waits for the previous IgnoreNew task instance before starting the new supervisor' {
    $module = Get-Module -Name InstallLifecycle -ErrorAction Stop
    $calls = [Collections.Generic.List[string]]::new()
    $adapters = @{
        WaitSupervisorTaskIdle = { param($TimeoutMilliseconds) $calls.Add("wait:$TimeoutMilliseconds"); $true }.GetNewClosure()
        StartSupervisorTask = { $calls.Add('start') }.GetNewClosure()
    }
    & $module { param($LifecycleAdapters) Start-CcodLifecycleTask -Adapters $LifecycleAdapters } $adapters
    Assert-CcodEqual 'wait:10000,start' ($calls -join ',') 'task idle proof precedes the start request'

    $blockedCalls = [Collections.Generic.List[string]]::new()
    $blockedAdapters = @{
        WaitSupervisorTaskIdle = { param($TimeoutMilliseconds) $blockedCalls.Add('wait'); $false }.GetNewClosure()
        StartSupervisorTask = { $blockedCalls.Add('start'); throw 'must not start while the old IgnoreNew instance is running' }.GetNewClosure()
    }
    $threw = $false
    try { & $module { param($LifecycleAdapters) Start-CcodLifecycleTask -Adapters $LifecycleAdapters } $blockedAdapters } catch { $threw = $_.FullyQualifiedErrorId -like 'CCOD_INSTALL_SUPERVISOR_TASK_BUSY*' }
    Assert-CcodTrue $threw 'a task that remains running fails with the stable busy code'
    Assert-CcodEqual 'wait' ($blockedCalls -join ',') 'blocked task never receives a start request'
}

$results += Invoke-CcodTest 'default installer validation uses the structural runtime payload and requires TrayHost files' {
    $source = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source | Out-Null
        $module = Get-Module InstallLifecycle
        $valid = & $module { param($SourceRoot) $adapters = Get-CcodLifecycleAdapters; & $adapters.ValidateSource $SourceRoot } $source
        Assert-CcodEqual $true $valid 'installer payload validates without running the source test suite'
        Remove-Item -LiteralPath (Join-Path $source 'bin') -Recurse -Force
        $missingTrayHost = & $module { param($SourceRoot) $adapters = Get-CcodLifecycleAdapters; & $adapters.ValidateSource $SourceRoot } $source
        Assert-CcodEqual $false $missingTrayHost 'installer payload rejects a missing TrayHost runtime'
    } finally {
        if (Test-Path -LiteralPath $source) { Remove-Item -LiteralPath $source -Recurse -Force }
    }
}

# Production mutation caught: accepting a caller-controlled activation id and persisting it into receipts or logs before canonical validation.
$results += Invoke-CcodTest 'install rejects a noncanonical caller ActivationId before receipt log or task mutation' {
    $source=New-CcodLifecycleTempRoot;$install=New-CcodLifecycleTempRoot;$nodeRoot=New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source -Version '2.5.0-invalid-activation-id'|Out-Null
        $nodePath=New-CcodLifecycleFakeNode -Root $nodeRoot
        $fake=New-CcodLifecycleFake -NodePath $nodePath
        $failure=$null
        try { Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -ActivationId 'ATTACKER_LOG_MARKER' -Adapters $fake.Adapters|Out-Null } catch { $failure=$_ }
        Assert-CcodTrue ($null-ne$failure) 'noncanonical caller ActivationId fails closed'
        Assert-CcodTrue ($failure.FullyQualifiedErrorId-like'CCOD_ACTIVATION_ID_INVALID*') 'invalid ActivationId returns the bounded stable code'
        Assert-CcodEqual 0 $fake.World.Phases.Count 'invalid ActivationId writes no activation receipt'
        Assert-CcodEqual 0 $fake.World.LogRecords.Count 'invalid ActivationId writes no install log'
        Assert-CcodEqual 0 $fake.World.TaskInstalled 'invalid ActivationId performs no scheduled-task mutation'
    } finally {foreach($path in @($source,$install,$nodeRoot)){if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Recurse -Force}}}
}

$results += Invoke-CcodTest 'first install stages verifies activates task and persists consent' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source | Out-Null
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        $fake = New-CcodLifecycleFake -NodePath $nodePath
        $receipt = Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -EnableCandidateCompatibleUpdates -Adapters $fake.Adapters
        Assert-CcodEqual 'Installed' $receipt.Outcome 'first install outcome'
        Assert-CcodEqual $true $receipt.Installed 'first install flag'
        Assert-CcodTrue (Test-Path -LiteralPath (Join-Path $install 'bootstrap.ps1') -PathType Leaf) 'stable bootstrap copied'
        Assert-CcodTrue (Test-Path -LiteralPath (Join-Path $install 'active.json') -PathType Leaf) 'active pointer written'
        Assert-CcodTrue (Test-Path -LiteralPath (Join-Path $install "runtime\$($receipt.RuntimeId)") -PathType Container) 'runtime staged'
        Assert-CcodEqual 1 $fake.World.TaskInstalled 'task installed'
        Assert-CcodEqual 1 $fake.World.TaskStarted 'task started'
        Assert-CcodEqual $null $receipt.PreviousRuntimeId 'first install has no previous runtime'
        $state = Read-CcodState -StateRoot (Join-Path $install 'state')
        Assert-CcodEqual $true $state.Settings.candidateCompatibleOptIn 'explicit consent persisted'
        Assert-CcodEqual $true $state.Settings.automationEnabled 'automation enabled on first install'
        Assert-CcodEqual $nodePath $state.Settings.nodeCandidates[0] 'verified node candidate persisted'
        $stateRoot = Join-Path $install 'state'
        $preference = Read-CcodUiPreference -StateRoot $stateRoot
        Assert-CcodEqual 'System' $preference.LanguageMode 'first install follows Windows'
        Assert-CcodEqual $false $preference.FallbackUsed 'first install persisted preference'
        $runtimeRoot = Join-Path $install "runtime\$($receipt.RuntimeId)"
        Assert-CcodTrue (Test-Path -LiteralPath (Join-Path $runtimeRoot 'src\persistence\resources\ui.en-US.json') -PathType Leaf) 'English catalog staged'
        Assert-CcodTrue (Test-Path -LiteralPath (Join-Path $runtimeRoot 'src\persistence\resources\ui.zh-CN.json') -PathType Leaf) 'Chinese catalog staged'
        $manifest = Test-CcodRuntimeManifest -RuntimeDirectory $runtimeRoot -ExpectedRuntimeId $receipt.RuntimeId
        Assert-CcodEqual $true $manifest.Valid 'runtime manifest validates staged resources'
        $english = @($manifest.Manifest.files | Where-Object { $_.path -ceq 'src/persistence/resources/ui.en-US.json' })
        $chinese = @($manifest.Manifest.files | Where-Object { $_.path -ceq 'src/persistence/resources/ui.zh-CN.json' })
        Assert-CcodEqual 1 $english.Count 'manifest contains English catalog exactly once'
        Assert-CcodEqual 1 $chinese.Count 'manifest contains Chinese catalog exactly once'
        Assert-CcodEqual '662b6067a48cfaeb481ae1a35e02f09fa799fa6386d0f4d2c61c19874a152713' $english[0].sha256 'manifest hashes English catalog'
        Assert-CcodEqual '5770fe0f20f1623648a185cc7a0a99ff37b6aef6c07426ffc8a984493e0f2a2f' $chinese[0].sha256 'manifest hashes Chinese catalog'
    } finally {
        foreach ($path in @($source, $install, $nodeRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

$results += Invoke-CcodTest 'hidden persistence module is staged and manifest-hashed' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source | Out-Null
        $hiddenModule = Join-Path $source 'src\persistence\modules\HiddenRuntime.psm1'
        [IO.File]::WriteAllText($hiddenModule, "Set-StrictMode -Version Latest`r`n# hidden fixture`r`n", [Text.UTF8Encoding]::new($false))
        $hiddenItem = Get-Item -LiteralPath $hiddenModule -Force
        $hiddenItem.Attributes = $hiddenItem.Attributes -bor [IO.FileAttributes]::Hidden
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        $receipt = Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters (New-CcodLifecycleFake -NodePath $nodePath).Adapters
        $runtimeRoot = Join-Path $install "runtime\$($receipt.RuntimeId)"
        $stagedModule = Join-Path $runtimeRoot 'src\persistence\modules\HiddenRuntime.psm1'
        Assert-CcodTrue (Test-Path -LiteralPath $stagedModule -PathType Leaf) 'hidden module is staged'
        $manifest = Test-CcodRuntimeManifest -RuntimeDirectory $runtimeRoot -ExpectedRuntimeId $receipt.RuntimeId
        Assert-CcodEqual $true $manifest.Valid 'hidden module runtime manifest validates'
        $record = @($manifest.Manifest.files | Where-Object { $_.path -ceq 'src/persistence/modules/HiddenRuntime.psm1' })
        Assert-CcodEqual 1 $record.Count 'manifest contains hidden module exactly once'
        Assert-CcodEqual '19fe966336cb8900576716b6518dcddac052405ec6b59eacb9eac149e4ee8f71' $record[0].sha256 'manifest hashes hidden module bytes'
    } finally {
        foreach ($path in @($source, $install, $nodeRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

$results += Invoke-CcodTest 'upgrade retains one previous runtime and starts the new task' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source -Version '2.0.0-a' | Out-Null
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        $fake = New-CcodLifecycleFake -NodePath $nodePath
        $first = Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $fake.Adapters
        Set-CcodLifecycleTestStatus -InstallRoot $install -RuntimeId $first.RuntimeId
        $stateRoot = Join-Path $install 'state'
        Set-CcodUiLanguageMode -StateRoot $stateRoot -LanguageMode 'en-US' -Adapters @{ UtcNow = { [DateTimeOffset]::Parse('2030-02-03T03:04:06.0000000Z') } } | Out-Null
        $preferencePath = Join-Path $stateRoot 'ui-preferences.json'
        $preferenceBytes = [IO.File]::ReadAllBytes($preferencePath)
        [IO.File]::WriteAllText((Join-Path $source 'src\runtime\main-payload.js'), "module.exports = 'fixture-v2';`n", [Text.UTF8Encoding]::new($false))
        $fake2 = New-CcodLifecycleFake -NodePath $nodePath
        $second = Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $fake2.Adapters
        Assert-CcodEqual 'Upgraded' $second.Outcome 'upgrade outcome'
        Assert-CcodEqual $first.RuntimeId $second.PreviousRuntimeId 'upgrade retains previous runtime id'
        Assert-CcodTrue ($second.RuntimeId -cne $first.RuntimeId) 'new runtime id differs'
        Assert-CcodEqual 1 $fake2.World.TaskInstalled 'upgrade reinstalls task'
        Assert-CcodEqual 1 $fake2.World.ShutdownSignaled 'old supervisor shutdown signaled'
        Assert-CcodEqual 1 $fake2.World.WaitSupervisorExit 'old supervisor exit waited'
        Assert-CcodEqual 1 $fake2.World.ShutdownGateOpened 'upgrade opens one shutdown gate before changing the active runtime'
        Assert-CcodEqual 1 $fake2.World.ShutdownGateClosed 'upgrade closes the shutdown gate before its replacement supervisor starts'
        [string[]]$calls = @($fake2.World.Calls)
        $installCall = @($calls | Where-Object { $_ -like 'InstallTask:*' })[0]
        Assert-CcodTrue ([Array]::IndexOf($calls, 'CloseShutdownGate') -lt [Array]::IndexOf($calls, $installCall)) 'shutdown gate closes before task replacement'
        $pointer = Read-CcodLifecycleActivePointer -Root $install
        Assert-CcodEqual $second.RuntimeId $pointer.activeRuntime 'active points at new runtime'
        Assert-CcodEqual $first.RuntimeId $pointer.previousRuntime 'previous points at old runtime'
        Assert-CcodEqual (($preferenceBytes | ForEach-Object { $_.ToString('x2') }) -join '') (([IO.File]::ReadAllBytes($preferencePath) | ForEach-Object { $_.ToString('x2') }) -join '') 'upgrade preserves valid UI preference bytes'
        Assert-CcodEqual 'en-US' (Read-CcodUiPreference -StateRoot $stateRoot).LanguageMode 'upgrade retains selected UI language'
        $runtimeRoot = Join-Path $install 'runtime'
        $ids = @(Get-ChildItem -LiteralPath $runtimeRoot -Directory | ForEach-Object { $_.Name } | Sort-Object)
        Assert-CcodEqual (($ids -join '|')) ((@($first.RuntimeId, $second.RuntimeId) | Sort-Object) -join '|') 'only active and previous runtime remain'
    } finally {
        foreach ($path in @($source, $install, $nodeRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

# Production mutation caught: omitting or reordering an activation phase, emitting Ready before the old owner/pointer/readiness gates, or rewriting device-key bytes during upgrade.
$results += Invoke-CcodTest 'upgrade emits a strict ordered Ready receipt only after all readiness gates' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    $keyRoot = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source -Version '2.5.0-phase-a' | Out-Null
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        $first = Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters (New-CcodLifecycleFake -NodePath $nodePath).Adapters
        Set-CcodLifecycleTestStatus -InstallRoot $install -RuntimeId $first.RuntimeId
        [IO.Directory]::CreateDirectory($keyRoot) | Out-Null
        $deviceKey = Join-Path $keyRoot 'remote-control-device-key.json'
        [IO.File]::WriteAllBytes($deviceKey, [Text.Encoding]::UTF8.GetBytes('{"deviceKey":"preserve-exact-bytes"}'))
        $expectedKeyHash = (Get-FileHash -LiteralPath $deviceKey -Algorithm SHA256).Hash
        [IO.File]::WriteAllText((Join-Path $source 'src\runtime\main-payload.js'), "module.exports = 'fixture-phase-v2';`n", [Text.UTF8Encoding]::new($false))

        $fake = New-CcodLifecycleFake -NodePath $nodePath
        $receipt = Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $fake.Adapters

        Assert-CcodEqual 'StoppingPreviousRuntime,InstallingRuntime,ActivatingRuntime,StartingProtection,Ready' ($fake.World.Phases -join ',') 'activation phases are ordered'
        Assert-CcodTrue $fake.World.OldSupervisorExitProven 'old owner exits before active pointer switch'
        Assert-CcodTrue ($fake.World.NewSupervisorReady -and $fake.World.NewTrayReady) 'new Supervisor signal proves the authenticated TrayHost handshake completed'
        Assert-CcodEqual $expectedKeyHash (Get-FileHash -LiteralPath $deviceKey -Algorithm SHA256).Hash 'upgrade preserves device-key bytes'

        $activationPath = Join-Path $install 'state\post-install-activation.json'
        Assert-CcodTrue (Test-Path -LiteralPath $activationPath -PathType Leaf) 'activation receipt is durable'
        $activation = Get-Content -LiteralPath $activationPath -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-CcodEqual 'schemaVersion,activationId,phase,runtimeId,previousRuntimeId,startedAtUtc,updatedAtUtc,ready,errorCode' (($activation.PSObject.Properties.Name) -join ',') 'activation receipt has exact properties'
        Assert-CcodEqual 'Ready' $activation.phase 'terminal activation phase is Ready'
        Assert-CcodEqual $true $activation.ready 'Ready receipt is the only successful terminal state'
        Assert-CcodEqual $receipt.RuntimeId $activation.runtimeId 'receipt binds the activated manifest runtime'
        Assert-CcodEqual $first.RuntimeId $activation.previousRuntimeId 'receipt binds the retained previous runtime'
        Assert-CcodEqual $null $activation.errorCode 'Ready receipt has no error code'
    } finally {
        foreach ($path in @($source, $install, $nodeRoot, $keyRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

# Production mutation caught: accepting a stale, wrong-user/session, wrong-runtime, malformed, or non-task Supervisor, or exposing its ephemeral ReadyToken in the returned proof.
$results += Invoke-CcodTest 'new-runtime readiness accepts only the exact post-task manifest-bound Supervisor and binds TrayHost readiness to its protected signal' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source -Version '2.5.0-ready-proof' | Out-Null
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        $installed = Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters (New-CcodLifecycleFake -NodePath $nodePath).Adapters
        $identity = New-CcodLifecycleIdentity
        $taskStartedAt = [DateTime]::Parse('2030-02-03T03:04:05Z').ToUniversalTime()
        $bootstrapPath = [IO.Path]::GetFullPath((Join-Path $install 'bootstrap.ps1'))
        $supervisorPath = [IO.Path]::GetFullPath((Join-Path $install "runtime\$($installed.RuntimeId)\src\persistence\Supervisor.ps1"))
        $token = 'a' * 64
        $snapshots = @(
            [pscustomobject][ordered]@{ ProcessId=500;ParentProcessId=1;SessionId=$identity.SessionId;CreationDate=[DateTime]::Parse('2030-02-03T03:04:05.1000000Z').ToUniversalTime();Name='powershell.exe';CommandLine="powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$bootstrapPath`" -InstallRoot `"$install`" -EntryMode Task" },
            [pscustomobject][ordered]@{ ProcessId=501;ParentProcessId=500;SessionId=$identity.SessionId;CreationDate=[DateTime]::Parse('2030-02-03T03:04:06.0000000Z').ToUniversalTime();Name='powershell.exe';CommandLine="powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File `"$supervisorPath`" -ReadyToken $token" }
        )
        $world = [pscustomobject]@{ EventOpened=$false;EventClosed=$false;IdentityChecks=0 }
        $readinessAdapters = @{
            EnumerateProcesses = { $snapshots }.GetNewClosure()
            GetProcessOwnerSid = { param($Process) $identity.UserSid }.GetNewClosure()
            OpenReadyEvent = { param($UserSid,$SessionId,$ReadyToken) if($UserSid-cne$identity.UserSid-or$SessionId-ne$identity.SessionId-or$ReadyToken-cne$token){throw 'wrong protected event identity'};$world.EventOpened=$true;[pscustomobject]@{Handle=[pscustomobject]@{Kind='Ready'}} }.GetNewClosure()
            WaitReadyEvent = { param($Event,$TimeoutMilliseconds) $true }.GetNewClosure()
            IsSupervisorIdentityCurrent = { param($SupervisorIdentity) $world.IdentityChecks++;$SupervisorIdentity.Pid-eq501-and$SupervisorIdentity.CreationTimeUtc-ceq'2030-02-03T03:04:06.0000000Z' }.GetNewClosure()
            CloseReadyEvent = { param($Event) $world.EventClosed=$true }.GetNewClosure()
            StartClock = { [pscustomobject]@{Elapsed=0L} }
            GetElapsedMilliseconds = { param($Clock) [long]$Clock.Elapsed }
            Sleep = { param($Milliseconds) }
        }
        $module = Get-Module InstallLifecycle
        $proof = & $module {
            param($Root,$RuntimeId,$Generation,$CurrentIdentity,$StartedAt,$Adapters)
            Wait-CcodLifecycleNewRuntimeReady -InstallRoot $Root -RuntimeId $RuntimeId -RuntimeGeneration $Generation -Identity $CurrentIdentity -TaskStartedAtUtc $StartedAt -TimeoutMilliseconds 1000 -Adapters $Adapters
        } $install $installed.RuntimeId ([UInt64]1) $identity $taskStartedAt $readinessAdapters

        Assert-CcodEqual 'SupervisorReady,TrayReady' (($proof.PSObject.Properties.Name) -join ',') 'readiness proof exposes no token or process details'
        Assert-CcodEqual $true $proof.SupervisorReady 'exact live Supervisor signals ready'
        Assert-CcodEqual $true $proof.TrayReady 'the same signal proves TrayHost authenticated UI readiness occurred first'
        Assert-CcodTrue ($world.EventOpened -and $world.EventClosed) 'protected event is opened and closed in memory'
        Assert-CcodTrue ($world.IdentityChecks -ge 2) 'exact PID and creation time remain live before and after signal'
    } finally {
        foreach ($path in @($source, $install, $nodeRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

# Production mutation caught: accepting a wrong generation/path/SID/session/start time/parent/command or more than one matching Supervisor candidate.
$results += Invoke-CcodTest 'new-runtime readiness rejects every mismatched or ambiguous Supervisor candidate before opening its token event' {
    $source = New-CcodLifecycleTempRoot;$install = New-CcodLifecycleTempRoot;$nodeRoot = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source -Version '2.5.0-ready-reject' | Out-Null
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        $installed = Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters (New-CcodLifecycleFake -NodePath $nodePath).Adapters
        $identity = New-CcodLifecycleIdentity;$started=[DateTime]::Parse('2030-02-03T03:04:05Z').ToUniversalTime()
        $bootstrap=[IO.Path]::GetFullPath((Join-Path $install 'bootstrap.ps1'));$supervisor=[IO.Path]::GetFullPath((Join-Path $install "runtime\$($installed.RuntimeId)\src\persistence\Supervisor.ps1"));$token='b'*64
        $newSnapshots = {
            $parent=[pscustomobject][ordered]@{ProcessId=600;ParentProcessId=1;SessionId=$identity.SessionId;CreationDate=[DateTime]::Parse('2030-02-03T03:04:05.1000000Z').ToUniversalTime();Name='powershell.exe';CommandLine="powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$bootstrap`" -InstallRoot `"$install`" -EntryMode Task"}
            $child=[pscustomobject][ordered]@{ProcessId=601;ParentProcessId=600;SessionId=$identity.SessionId;CreationDate=[DateTime]::Parse('2030-02-03T03:04:06.0000000Z').ToUniversalTime();Name='powershell.exe';CommandLine="powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File `"$supervisor`" -ReadyToken $token"}
            @($parent,$child)
        }.GetNewClosure()
        $cases=@(
            [pscustomobject]@{Name='generation';Generation=[UInt64]2;Mutate={param($Items)};Owner='current'},
            [pscustomobject]@{Name='runtime path';Generation=[UInt64]1;Mutate={param($Items)$Items[1].CommandLine=$Items[1].CommandLine.Replace($supervisor,'C:\wrong\Supervisor.ps1')};Owner='current'},
            [pscustomobject]@{Name='session';Generation=[UInt64]1;Mutate={param($Items)$Items[1].SessionId=9};Owner='current'},
            [pscustomobject]@{Name='creation time';Generation=[UInt64]1;Mutate={param($Items)$Items[1].CreationDate=[DateTime]::Parse('2030-02-03T03:04:04Z').ToUniversalTime()};Owner='current'},
            [pscustomobject]@{Name='parent entry mode';Generation=[UInt64]1;Mutate={param($Items)$Items[0].CommandLine=$Items[0].CommandLine.Replace('-EntryMode Task','-EntryMode Explicit')};Owner='current'},
            [pscustomobject]@{Name='command line';Generation=[UInt64]1;Mutate={param($Items)$Items[1].CommandLine += ' -ReadyToken '+('c'*64)};Owner='current'},
            [pscustomobject]@{Name='owner SID';Generation=[UInt64]1;Mutate={param($Items)};Owner='wrong'},
            [pscustomobject]@{Name='ambiguous candidates';Generation=[UInt64]1;Mutate={param($Items)$clone=$Items[1].PSObject.Copy();$clone.ProcessId=602;$clone.CreationDate=[DateTime]::Parse('2030-02-03T03:04:06.1000000Z').ToUniversalTime();$script:extraCandidate=$clone};Owner='current'}
        )
        $module=Get-Module InstallLifecycle
        foreach($case in $cases){
            $script:extraCandidate=$null;$items=@(& $newSnapshots);& $case.Mutate $items;if($null-ne$script:extraCandidate){$items+= $script:extraCandidate}
            $world=[pscustomobject]@{Elapsed=0L;Opened=0}
            $ownerMode=$case.Owner
            $adapters=@{
                EnumerateProcesses={$items}.GetNewClosure();GetProcessOwnerSid={param($Process)if($ownerMode-ceq'wrong'){'S-1-5-21-9-9-9-1001'}else{$identity.UserSid}}.GetNewClosure()
                OpenReadyEvent={param($Sid,$Session,$ReadyToken)$world.Opened++;[pscustomobject]@{Handle='event'}}.GetNewClosure();WaitReadyEvent={param($Event,$Milliseconds)$true}
                IsSupervisorIdentityCurrent={param($Candidate)$true};CloseReadyEvent={param($Event)};StartClock={$world}.GetNewClosure();GetElapsedMilliseconds={param($Clock)[long]$Clock.Elapsed};Sleep={param($Milliseconds)$world.Elapsed+=$Milliseconds}.GetNewClosure()
            }
            $proof=& $module {param($Root,$Runtime,$Generation,$Current,$Started,$A)Wait-CcodLifecycleNewRuntimeReady -InstallRoot $Root -RuntimeId $Runtime -RuntimeGeneration $Generation -Identity $Current -TaskStartedAtUtc $Started -TimeoutMilliseconds 40 -Adapters $A} $install $installed.RuntimeId $case.Generation $identity $started $adapters
            Assert-CcodEqual $false $proof.SupervisorReady "$($case.Name) is not Supervisor-ready"
            Assert-CcodEqual $false $proof.TrayReady "$($case.Name) cannot imply TrayHost readiness"
            Assert-CcodEqual 0 $world.Opened "$($case.Name) never opens an unverified token event"
        }
    } finally { foreach($path in @($source,$install,$nodeRoot)){if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Recurse -Force}} }
}

# Production mutation caught: treating candidate discovery as Ready when the protected event is unsignaled/inaccessible or the exact PID/creation identity exits.
$results += Invoke-CcodTest 'new-runtime readiness requires a live exact process through the combined Supervisor and TrayHost signal' {
    $source=New-CcodLifecycleTempRoot;$install=New-CcodLifecycleTempRoot;$nodeRoot=New-CcodLifecycleTempRoot
    try{
        New-CcodLifecycleSourceFixture -Root $source -Version '2.5.0-ready-event'|Out-Null;$nodePath=New-CcodLifecycleFakeNode -Root $nodeRoot
        $installed=Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters (New-CcodLifecycleFake -NodePath $nodePath).Adapters
        $identity=New-CcodLifecycleIdentity;$started=[DateTime]::Parse('2030-02-03T03:04:05Z').ToUniversalTime();$bootstrap=[IO.Path]::GetFullPath((Join-Path $install 'bootstrap.ps1'));$supervisor=[IO.Path]::GetFullPath((Join-Path $install "runtime\$($installed.RuntimeId)\src\persistence\Supervisor.ps1"));$token='d'*64
        $items=@([pscustomobject]@{ProcessId=700;ParentProcessId=1;SessionId=1;CreationDate=[DateTime]::Parse('2030-02-03T03:04:05.1Z').ToUniversalTime();Name='powershell.exe';CommandLine="powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$bootstrap`" -InstallRoot `"$install`" -EntryMode Task"},[pscustomobject]@{ProcessId=701;ParentProcessId=700;SessionId=1;CreationDate=[DateTime]::Parse('2030-02-03T03:04:06Z').ToUniversalTime();Name='powershell.exe';CommandLine="powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File `"$supervisor`" -ReadyToken $token"})
        $cases=@(
            [pscustomobject]@{Name='TrayHost handshake remains unsignaled';OpenThrows=$false;AliveChecks=99;Signal=$false},
            [pscustomobject]@{Name='ready event ACL/open failure';OpenThrows=$true;AliveChecks=99;Signal=$false},
            [pscustomobject]@{Name='Supervisor exits before signal';OpenThrows=$false;AliveChecks=1;Signal=$false}
        )
        $module=Get-Module InstallLifecycle
        foreach($case in $cases){
            $world=[pscustomobject]@{Elapsed=0L;Checks=0;Closed=0};$openThrows=$case.OpenThrows;$aliveChecks=$case.AliveChecks;$signal=$case.Signal
            $adapters=@{EnumerateProcesses={$items}.GetNewClosure();GetProcessOwnerSid={param($P)$identity.UserSid}.GetNewClosure();OpenReadyEvent={param($Sid,$Session,$ReadyToken)if($openThrows){throw 'ACL'};[pscustomobject]@{Handle='event'}}.GetNewClosure();WaitReadyEvent={param($Event,$Milliseconds)$world.Elapsed+=$Milliseconds;[bool]$signal}.GetNewClosure();IsSupervisorIdentityCurrent={param($Candidate)$world.Checks++;$world.Checks-le$aliveChecks}.GetNewClosure();CloseReadyEvent={param($Event)$world.Closed++}.GetNewClosure();StartClock={$world}.GetNewClosure();GetElapsedMilliseconds={param($Clock)[long]$Clock.Elapsed};Sleep={param($Milliseconds)$world.Elapsed+=$Milliseconds}.GetNewClosure()}
            $proof=& $module {param($Root,$Runtime,$Current,$Started,$A)Wait-CcodLifecycleNewRuntimeReady -InstallRoot $Root -RuntimeId $Runtime -RuntimeGeneration 1 -Identity $Current -TaskStartedAtUtc $Started -TimeoutMilliseconds 200 -Adapters $A} $install $installed.RuntimeId $identity $started $adapters
            Assert-CcodEqual $false $proof.SupervisorReady "$($case.Name) fails Supervisor readiness"
            Assert-CcodEqual $false $proof.TrayReady "$($case.Name) fails the dependent TrayHost readiness"
        }
    }finally{foreach($path in @($source,$install,$nodeRoot)){if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Recurse -Force}}}
}

# Production mutation caught: continuing through any protected upgrade boundary after lifecycle/task/fence/start/readiness failure, rolling back a committed generation, or retaining an uncommitted runtime.
$results += Invoke-CcodTest 'upgrade boundaries fail closed with phase receipts and generation-aware rollback' {
    $cases = @(
        [pscustomobject]@{ Name='nonterminal lifecycle';Code='CCOD_INSTALL_LIFECYCLE_BUSY';Committed=$false;Configure={param($Fake)$Fake.World.ActiveLifecycleRequest=[pscustomobject]@{phase='CloseRequested'}} },
        [pscustomobject]@{ Name='old task still running';Code='CCOD_INSTALL_SUPERVISOR_TASK_BUSY';Committed=$false;Configure={param($Fake)$Fake.World.TaskIdle=$false} },
        [pscustomobject]@{ Name='stale lifecycle generation';Code='CCOD_LIFECYCLE_FENCE_STALE';Committed=$false;Configure={param($Fake)$Fake.World.SetActiveFailure={throw [Management.Automation.ErrorRecord]::new([InvalidOperationException]::new('stale'), 'CCOD_LIFECYCLE_FENCE_STALE', [Management.Automation.ErrorCategory]::InvalidData, $null)}} },
        [pscustomobject]@{ Name='active pointer write failure';Code='CCOD_INSTALL_RUNTIME_ACTIVATION_UNPROVEN';Committed=$false;Configure={param($Fake)$Fake.World.SetActiveFailure={throw 'PRIVATE_POINTER_SECRET'}} },
        [pscustomobject]@{ Name='crash after generation commit';Code='CCOD_INSTALL_RUNTIME_ACTIVATION_UNPROVEN';Committed=$true;Configure={param($Fake)$Fake.World.SetActiveFailure={param($Root,$RuntimeId,$Ownership)$fence={param($InstallRoot,$Receipt,$ExpectActivePointer)$true};Set-CcodActiveRuntime -InstallRoot $Root -NewRuntimeId $RuntimeId -Ownership $Ownership -Adapters @{AssertLifecycleFence=$fence}|Out-Null;throw 'PRIVATE_AFTER_COMMIT_SECRET'}} },
        [pscustomobject]@{ Name='new task start failure';Code='CCOD_INSTALL_SUPERVISOR_START_FAILED';Committed=$true;Configure={param($Fake)$Fake.World.StartTaskFailure=$true} },
        [pscustomobject]@{ Name='Supervisor ready timeout';Code='CCOD_INSTALL_NEW_RUNTIME_NOT_READY';Committed=$true;Configure={param($Fake)$Fake.World.NewSupervisorReady=$false} },
        [pscustomobject]@{ Name='TrayHost ready timeout';Code='CCOD_INSTALL_NEW_RUNTIME_NOT_READY';Committed=$true;Configure={param($Fake)$Fake.World.NewTrayReady=$false} }
    )
    foreach ($case in $cases) {
        $source = New-CcodLifecycleTempRoot
        $install = New-CcodLifecycleTempRoot
        $nodeRoot = New-CcodLifecycleTempRoot
        try {
            New-CcodLifecycleSourceFixture -Root $source -Version ('2.5.0-boundary-' + ($case.Name -replace '[^A-Za-z0-9]','-')) | Out-Null
            $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
            $first = Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters (New-CcodLifecycleFake -NodePath $nodePath).Adapters
            Set-CcodLifecycleTestStatus -InstallRoot $install -RuntimeId $first.RuntimeId
            [IO.File]::WriteAllText((Join-Path $source 'src\runtime\main-payload.js'), "module.exports = 'boundary-$($case.Name)';`n", [Text.UTF8Encoding]::new($false))
            $fake = New-CcodLifecycleFake -NodePath $nodePath
            & $case.Configure $fake

            $failure = $null
            try { Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $fake.Adapters | Out-Null } catch { $failure = $_ }
            Assert-CcodTrue ($null -ne $failure) "$($case.Name) fails closed"
            Assert-CcodTrue ($failure.FullyQualifiedErrorId -like "$($case.Code)*") "$($case.Name) returns its stable support code"
            $activation = Get-Content -LiteralPath (Join-Path $install 'state\post-install-activation.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            Assert-CcodEqual 'Failed' $activation.phase "$($case.Name) writes Failed"
            Assert-CcodEqual $false $activation.ready "$($case.Name) never writes Ready"
            Assert-CcodEqual $case.Code $activation.errorCode "$($case.Name) persists the stable code"

            $pointer = Read-CcodLifecycleActivePointer -Root $install
            $runtimeIds = @(Get-ChildItem -LiteralPath (Join-Path $install 'runtime') -Directory | ForEach-Object Name)
            if ($case.Committed) {
                Assert-CcodTrue ($pointer.activeRuntime -cne $first.RuntimeId) "$($case.Name) keeps the committed new generation instead of regressing the pointer"
                Assert-CcodEqual $first.RuntimeId $pointer.previousRuntime "$($case.Name) preserves the previous runtime for recovery"
                Assert-CcodEqual 2 $runtimeIds.Count "$($case.Name) preserves both committed generations"
            } else {
                Assert-CcodEqual $first.RuntimeId $pointer.activeRuntime "$($case.Name) leaves the old pointer active before mutation"
                Assert-CcodEqual 1 $runtimeIds.Count "$($case.Name) removes any uncommitted staged runtime"
                Assert-CcodEqual $first.RuntimeId $runtimeIds[0] "$($case.Name) retains only the previous runtime"
            }
        } finally {
            foreach ($path in @($source, $install, $nodeRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
        }
    }
}

# Production mutation caught: reporting a pre-generation upgrade failure after stopping the old runtime without first restarting and proving the still-active generation.
$results += Invoke-CcodTest 'pre-generation upgrade failure restores and proves previous runtime protection before Failed' {
    $source=New-CcodLifecycleTempRoot;$install=New-CcodLifecycleTempRoot;$nodeRoot=New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source -Version '2.5.0-rollback-a'|Out-Null
        $nodePath=New-CcodLifecycleFakeNode -Root $nodeRoot
        $first=Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters (New-CcodLifecycleFake -NodePath $nodePath).Adapters
        Set-CcodLifecycleTestStatus -InstallRoot $install -RuntimeId $first.RuntimeId
        [IO.File]::WriteAllText((Join-Path $source 'src\runtime\main-payload.js'),"module.exports='rollback-b';`n",[Text.UTF8Encoding]::new($false))
        $fake=New-CcodLifecycleFake -NodePath $nodePath
        $fake.World.CopyOverride=[pscustomobject]@{Match='*Supervisor.ps1';Action={param($SourcePath,$DestinationPath)throw 'PRIVATE_PREGENERATION_COPY_FAILURE'}}
        $originalWriter=$fake.Adapters.WriteActivationReceipt
        $fake.Adapters.WriteActivationReceipt={param($Root,$Receipt)$fake.World.Calls.Add("Receipt:$($Receipt.phase)");&$originalWriter $Root $Receipt}.GetNewClosure()
        $fake.Adapters.WaitNewRuntimeReady={param($Root,$Runtime,$Generation,$Identity,$Started,$Timeout)$fake.World.Calls.Add("WaitRollbackReady:${Runtime}:${Generation}:${Timeout}");[pscustomobject][ordered]@{SupervisorReady=$true;TrayReady=$true}}.GetNewClosure()

        Assert-CcodThrows {Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $fake.Adapters|Out-Null} 'CCOD_INSTALL_STAGING_FAILED'
        [string[]]$calls=@($fake.World.Calls)
        $close=[Array]::IndexOf($calls,'CloseShutdownGate');$lease=[Array]::IndexOf($calls,'ExitInstallLease');$start=[Array]::IndexOf($calls,'StartTask')
        $wait=@($calls|Where-Object{$_-like"WaitRollbackReady:$($first.RuntimeId):1:*"})[0];$waitIndex=[Array]::IndexOf($calls,$wait);$failed=[Array]::IndexOf($calls,'Receipt:Failed')
        Assert-CcodTrue ($close-ge0-and$lease-gt$close-and$start-gt$lease-and$waitIndex-gt$start-and$failed-gt$waitIndex) 'shutdown gate and install ownership release before old task restart, readiness proof, and Failed receipt'
        Assert-CcodEqual 1 $fake.World.TaskStarted 'previous protection is restarted exactly once'
        $pointer=Read-CcodLifecycleActivePointer -Root $install
        Assert-CcodEqual $first.RuntimeId $pointer.activeRuntime 'rollback proof remains bound to the previous active runtime'
        Assert-CcodEqual 1 ([UInt64]$pointer.generation) 'rollback proof remains bound to the previous active generation'
    } finally {foreach($path in @($source,$install,$nodeRoot)){if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Recurse -Force}}}
}

# Production mutation caught: setting previousProtectionStopped only after task-idle proof, which skips rollback when exact Supervisor exit succeeds but IgnoreNew remains busy.
$results += Invoke-CcodTest 'task-idle failure restarts and proves the old active generation before Failed' {
    $source=New-CcodLifecycleTempRoot;$install=New-CcodLifecycleTempRoot;$nodeRoot=New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source -Version '2.5.0-task-idle-rollback-a'|Out-Null
        $nodePath=New-CcodLifecycleFakeNode -Root $nodeRoot
        $first=Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters (New-CcodLifecycleFake -NodePath $nodePath).Adapters
        Set-CcodLifecycleTestStatus -InstallRoot $install -RuntimeId $first.RuntimeId
        [IO.File]::WriteAllText((Join-Path $source 'src\runtime\main-payload.js'),"module.exports='task-idle-rollback-b';`n",[Text.UTF8Encoding]::new($false))
        $fake=New-CcodLifecycleFake -NodePath $nodePath;$fake.World.TaskIdle=$false
        $originalWriter=$fake.Adapters.WriteActivationReceipt
        $fake.Adapters.WriteActivationReceipt={param($Root,$Receipt)$fake.World.Calls.Add("Receipt:$($Receipt.phase)");&$originalWriter $Root $Receipt}.GetNewClosure()
        $fake.Adapters.WaitNewRuntimeReady={param($Root,$Runtime,$Generation,$Identity,$Started,$Timeout)$fake.World.Calls.Add("WaitRollbackReady:${Runtime}:${Generation}:${Timeout}");[pscustomobject][ordered]@{SupervisorReady=$true;TrayReady=$true}}.GetNewClosure()

        Assert-CcodThrows {Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $fake.Adapters|Out-Null} 'CCOD_INSTALL_SUPERVISOR_TASK_BUSY'
        [string[]]$calls=@($fake.World.Calls)
        $oldExit=[Array]::IndexOf($calls,'WaitSupervisor:41:10000');$idle=[Array]::IndexOf($calls,'WaitTaskIdle:10000');$start=[Array]::IndexOf($calls,'StartTask')
        $wait=@($calls|Where-Object{$_-like"WaitRollbackReady:$($first.RuntimeId):1:*"})[0];$waitIndex=[Array]::IndexOf($calls,$wait);$failed=[Array]::IndexOf($calls,'Receipt:Failed')
        Assert-CcodTrue ($oldExit-ge0-and$idle-gt$oldExit-and$start-gt$idle-and$waitIndex-gt$start-and$failed-gt$waitIndex) 'exact old exit is followed by task-idle failure, old task restart, readiness proof, then Failed'
        Assert-CcodEqual 1 $fake.World.TaskStarted 'old protection is restarted exactly once after task-idle failure'
        $pointer=Read-CcodLifecycleActivePointer -Root $install
        Assert-CcodEqual $first.RuntimeId $pointer.activeRuntime 'task-idle rollback remains bound to the old active runtime'
        Assert-CcodEqual 1 ([UInt64]$pointer.generation) 'task-idle rollback remains bound to the old generation'
    } finally {foreach($path in @($source,$install,$nodeRoot)){if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Recurse -Force}}}
}

$results += Invoke-CcodTest 'pre-generation rollback proof failure reports a bounded rollback code and preserves the old generation' {
    $source=New-CcodLifecycleTempRoot;$install=New-CcodLifecycleTempRoot;$nodeRoot=New-CcodLifecycleTempRoot
    try{
        New-CcodLifecycleSourceFixture -Root $source -Version '2.5.0-rollback-proof-a'|Out-Null;$nodePath=New-CcodLifecycleFakeNode -Root $nodeRoot
        $first=Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters (New-CcodLifecycleFake -NodePath $nodePath).Adapters
        Set-CcodLifecycleTestStatus -InstallRoot $install -RuntimeId $first.RuntimeId
        [IO.File]::WriteAllText((Join-Path $source 'src\runtime\main-payload.js'),"module.exports='rollback-proof-b';`n",[Text.UTF8Encoding]::new($false))
        $fake=New-CcodLifecycleFake -NodePath $nodePath;$fake.World.StartTaskFailure=$true
        $fake.World.CopyOverride=[pscustomobject]@{Match='*Supervisor.ps1';Action={param($SourcePath,$DestinationPath)throw 'PRIVATE_PREGENERATION_COPY_FAILURE'}}

        Assert-CcodThrows {Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $fake.Adapters|Out-Null} 'CCOD_INSTALL_ROLLBACK_FAILED'
        $activation=Get-Content -LiteralPath (Join-Path $install 'state\post-install-activation.json') -Raw -Encoding UTF8|ConvertFrom-Json
        Assert-CcodEqual 'Failed' $activation.phase 'unproven rollback remains terminally Failed'
        Assert-CcodEqual 'CCOD_INSTALL_ROLLBACK_FAILED' $activation.errorCode 'unproven rollback exposes only the bounded support code'
        $pointer=Read-CcodLifecycleActivePointer -Root $install
        Assert-CcodEqual $first.RuntimeId $pointer.activeRuntime 'unproven rollback never mutates the previous active pointer'
        Assert-CcodEqual 1 ([UInt64]$pointer.generation) 'unproven rollback never regresses or advances generation'
    }finally{foreach($path in @($source,$install,$nodeRoot)){if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Recurse -Force}}}
}

# Production mutation caught: removing superseded runtime directories before readiness or retaining them after a verified Ready transition.
$results += Invoke-CcodTest 'old runtime cleanup occurs only after combined readiness succeeds' {
    $source=New-CcodLifecycleTempRoot;$install=New-CcodLifecycleTempRoot;$nodeRoot=New-CcodLifecycleTempRoot
    try{
        New-CcodLifecycleSourceFixture -Root $source -Version '2.5.0-cleanup-a'|Out-Null;$nodePath=New-CcodLifecycleFakeNode -Root $nodeRoot
        $first=Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters (New-CcodLifecycleFake -NodePath $nodePath).Adapters
        Set-CcodLifecycleTestStatus -InstallRoot $install -RuntimeId $first.RuntimeId
        $orphan=Join-Path $install 'runtime\superseded-orphan';[IO.Directory]::CreateDirectory($orphan)|Out-Null;[IO.File]::WriteAllText((Join-Path $orphan 'keep.txt'),'old',[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $source 'src\runtime\main-payload.js'),"module.exports='cleanup-ready';`n",[Text.UTF8Encoding]::new($false))
        $readyFake=New-CcodLifecycleFake -NodePath $nodePath;$cleanupWorld=[pscustomobject]@{ObservedBeforeReady=$false}
        $readyFake.Adapters.WaitNewRuntimeReady={param($Root,$Runtime,$Generation,$Identity,$Started,$Timeout)$cleanupWorld.ObservedBeforeReady=Test-Path -LiteralPath $orphan -PathType Container;[pscustomobject][ordered]@{SupervisorReady=$true;TrayReady=$true}}.GetNewClosure()
        $second=Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $readyFake.Adapters
        Assert-CcodTrue $cleanupWorld.ObservedBeforeReady 'superseded runtime still exists while readiness is being proven'
        Assert-CcodTrue (-not(Test-Path -LiteralPath $orphan)) 'superseded runtime is cleaned only after Ready'

        Set-CcodLifecycleTestStatus -InstallRoot $install -RuntimeId $second.RuntimeId
        $orphanAfterFailure=Join-Path $install 'runtime\superseded-after-failure';[IO.Directory]::CreateDirectory($orphanAfterFailure)|Out-Null
        [IO.File]::WriteAllText((Join-Path $source 'src\runtime\main-payload.js'),"module.exports='cleanup-timeout';`n",[Text.UTF8Encoding]::new($false))
        $blocked=New-CcodLifecycleFake -NodePath $nodePath;$blocked.World.NewTrayReady=$false
        Assert-CcodThrows {Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $blocked.Adapters|Out-Null} 'CCOD_INSTALL_NEW_RUNTIME_NOT_READY'
        Assert-CcodTrue (Test-Path -LiteralPath $orphanAfterFailure -PathType Container) 'readiness failure never performs old-runtime cleanup'
    }finally{foreach($path in @($source,$install,$nodeRoot)){if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Recurse -Force}}}
}

# Production mutation caught: allowing a best-effort post-Ready cleanup exception to enter activation failure handling and overwrite the terminal Ready receipt.
$results += Invoke-CcodTest 'post-Ready cleanup failure retains Ready and the undeleted old runtime' {
    $source=New-CcodLifecycleTempRoot;$install=New-CcodLifecycleTempRoot;$nodeRoot=New-CcodLifecycleTempRoot;$lock=$null
    try{
        New-CcodLifecycleSourceFixture -Root $source -Version '2.5.0-cleanup-failure-a'|Out-Null;$nodePath=New-CcodLifecycleFakeNode -Root $nodeRoot
        $first=Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters (New-CcodLifecycleFake -NodePath $nodePath).Adapters
        Set-CcodLifecycleTestStatus -InstallRoot $install -RuntimeId $first.RuntimeId
        $orphan=Join-Path $install 'runtime\superseded-locked';[IO.Directory]::CreateDirectory($orphan)|Out-Null
        $lockedPath=Join-Path $orphan 'locked.bin';$lock=[IO.File]::Open($lockedPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        [IO.File]::WriteAllText((Join-Path $source 'src\runtime\main-payload.js'),"module.exports='cleanup-failure-b';`n",[Text.UTF8Encoding]::new($false))
        $fake=New-CcodLifecycleFake -NodePath $nodePath

        $second=Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $fake.Adapters
        Assert-CcodEqual 'Upgraded' $second.Outcome 'cleanup failure does not invalidate the verified upgrade'
        $activation=Get-Content -LiteralPath (Join-Path $install 'state\post-install-activation.json') -Raw -Encoding UTF8|ConvertFrom-Json
        Assert-CcodEqual 'Ready' $activation.phase 'cleanup failure cannot overwrite Ready with Failed'
        Assert-CcodEqual $true $activation.ready 'terminal readiness remains successful'
        Assert-CcodTrue (Test-Path -LiteralPath $orphan -PathType Container) 'cleanup failure retains the undeleted old runtime'
        Assert-CcodEqual 1 @($fake.World.LogRecords|Where-Object{$_.code-ceq'CCOD_INSTALL_OLD_RUNTIME_CLEANUP_FAILED'}).Count 'cleanup failure leaves one safe diagnostic record'
    }finally{
        if($null-ne$lock){$lock.Dispose()}
        foreach($path in @($source,$install,$nodeRoot)){if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Recurse -Force}}
    }
}

# Production mutation caught: silently losing a completion-log failure or allowing any post-Ready diagnostic path to overwrite Ready.
$results += Invoke-CcodTest 'post-Ready completion-log failure stays Ready retains previous runtime and emits a bounded diagnostic' {
    $source=New-CcodLifecycleTempRoot;$install=New-CcodLifecycleTempRoot;$nodeRoot=New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source -Version '2.5.0-post-ready-log-a'|Out-Null;$nodePath=New-CcodLifecycleFakeNode -Root $nodeRoot
        $first=Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters (New-CcodLifecycleFake -NodePath $nodePath).Adapters
        Set-CcodLifecycleTestStatus -InstallRoot $install -RuntimeId $first.RuntimeId
        [IO.File]::WriteAllText((Join-Path $source 'src\runtime\main-payload.js'),"module.exports='post-ready-log-b';`n",[Text.UTF8Encoding]::new($false))
        $fake=New-CcodLifecycleFake -NodePath $nodePath;$fake.World.FailLogCode='CCOD_INSTALL_COMPLETED'

        $second=Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $fake.Adapters
        Assert-CcodEqual 'Upgraded' $second.Outcome 'post-Ready log failure does not invalidate the verified upgrade'
        $activation=Get-Content -LiteralPath (Join-Path $install 'state\post-install-activation.json') -Raw -Encoding UTF8|ConvertFrom-Json
        Assert-CcodEqual 'Ready' $activation.phase 'post-Ready log failure cannot overwrite Ready'
        Assert-CcodEqual $true $activation.ready 'post-Ready log failure preserves successful readiness'
        Assert-CcodTrue (Test-Path -LiteralPath (Join-Path $install "runtime\$($first.RuntimeId)") -PathType Container) 'post-Ready log failure retains the previous runtime'
        Assert-CcodEqual 1 @($fake.World.LogRecords|Where-Object{$_.code-ceq'CCOD_INSTALL_POST_READY_LOG_FAILED'}).Count 'post-Ready log failure emits one bounded fallback diagnostic'
    } finally {foreach($path in @($source,$install,$nodeRoot)){if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Recurse -Force}}}
}

# Production mutation caught: waiting for the task-created Supervisor while retaining install/lifecycle mutex ownership that blocks bootstrap launch.
$results += Invoke-CcodTest 'upgrade releases generation ownership before waiting for task-created readiness' {
    $source=New-CcodLifecycleTempRoot;$install=New-CcodLifecycleTempRoot;$nodeRoot=New-CcodLifecycleTempRoot
    try{
        New-CcodLifecycleSourceFixture -Root $source -Version '2.5.0-handoff-a'|Out-Null;$nodePath=New-CcodLifecycleFakeNode -Root $nodeRoot
        $first=Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters (New-CcodLifecycleFake -NodePath $nodePath).Adapters
        Set-CcodLifecycleTestStatus -InstallRoot $install -RuntimeId $first.RuntimeId
        [IO.File]::WriteAllText((Join-Path $source 'src\runtime\main-payload.js'),"module.exports='handoff-b';`n",[Text.UTF8Encoding]::new($false))
        $fake=New-CcodLifecycleFake -NodePath $nodePath
        $fake.Adapters.WaitNewRuntimeReady={param($Root,$Runtime,$Generation,$Identity,$Started,$Timeout)$fake.World.Calls.Add('WaitNewRuntimeReady');[pscustomobject][ordered]@{SupervisorReady=$true;TrayReady=$true}}.GetNewClosure()
        Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $fake.Adapters|Out-Null
        [string[]]$calls=@($fake.World.Calls)
        $startIndex=[Array]::IndexOf($calls,'StartTask');$ownershipExit=[Array]::IndexOf($calls,'ExitLifecycleOwnership');$installExit=[Array]::IndexOf($calls,'ExitInstallLease');$readyIndex=[Array]::IndexOf($calls,'WaitNewRuntimeReady')
        Assert-CcodTrue ($startIndex-ge0-and$ownershipExit-gt$startIndex-and$installExit-gt$ownershipExit-and$readyIndex-gt$installExit) 'task starts, ownership fully releases, then readiness polling begins'
        Assert-CcodEqual 1 $fake.World.InstallLeaseReleased 'install lease releases exactly once before readiness'
    }finally{foreach($path in @($source,$install,$nodeRoot)){if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Recurse -Force}}}
}

# Production mutation caught: acquiring AccountTransition while the old Supervisor still owns it, deadlocking every live upgrade before shutdown.
$results += Invoke-CcodTest 'upgrade stops the old owner and task before acquiring install ownership' {
    $source=New-CcodLifecycleTempRoot;$install=New-CcodLifecycleTempRoot;$nodeRoot=New-CcodLifecycleTempRoot
    try{
        New-CcodLifecycleSourceFixture -Root $source -Version '2.5.0-stop-order-a'|Out-Null;$nodePath=New-CcodLifecycleFakeNode -Root $nodeRoot
        $first=Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters (New-CcodLifecycleFake -NodePath $nodePath).Adapters
        Set-CcodLifecycleTestStatus -InstallRoot $install -RuntimeId $first.RuntimeId
        [IO.File]::WriteAllText((Join-Path $source 'src\runtime\main-payload.js'),"module.exports='stop-order-b';`n",[Text.UTF8Encoding]::new($false))
        $fake=New-CcodLifecycleFake -NodePath $nodePath
        Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $fake.Adapters|Out-Null
        [string[]]$calls=@($fake.World.Calls);$stop=[Array]::IndexOf($calls,'WaitSupervisor:41:10000');$idle=[Array]::IndexOf($calls,'WaitTaskIdle:10000');$lease=@($calls|Where-Object{$_-like'EnterInstallLease:*'})[0];$leaseIndex=[Array]::IndexOf($calls,$lease)
        Assert-CcodTrue ($stop-ge0-and$idle-gt$stop-and$leaseIndex-gt$idle) 'exact old exit and task idle proof precede AccountTransition acquisition'
        Assert-CcodTrue (@($calls|Where-Object{$_-ceq'ReadActiveLifecycleRequest'}).Count-ge2) 'pending lifecycle state is checked before shutdown and again under acquired ownership'
    }finally{foreach($path in @($source,$install,$nodeRoot)){if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Recurse -Force}}}
}

$results += Invoke-CcodTest 'staging copy failure fails closed before activation' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source | Out-Null
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        $fake = New-CcodLifecycleFake -NodePath $nodePath
        $fake.World.CopyOverride = [pscustomobject]@{ Match = '*Supervisor.ps1'; Action = { param($Source, $Destination) throw 'PRIVATE_COPY_SECRET' } }
        Assert-CcodThrows { Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $fake.Adapters } 'CCOD_INSTALL_STAGING_FAILED'
        Assert-CcodTrue (-not (Test-Path -LiteralPath (Join-Path $install 'active.json'))) 'staging failure never writes active pointer'
        Assert-CcodTrue (-not (Test-Path -LiteralPath (Join-Path $install 'bootstrap.ps1'))) 'staging failure never writes bootstrap'
        Assert-CcodEqual 0 (Get-ChildItem -LiteralPath $install -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq '.staging' }).Count 'staging directory cleaned'
    } finally {
        foreach ($path in @($source, $install, $nodeRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

$results += Invoke-CcodTest 'manifest hash mismatch fails closed and cleans staging' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source | Out-Null
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        $fake = New-CcodLifecycleFake -NodePath $nodePath
        $fake.World.CopyOverride = [pscustomobject]@{ Match = '*SessionController.ps1'; Action = { param($Source, $Destination) [IO.Directory]::CreateDirectory((Split-Path $Destination -Parent)) | Out-Null; [IO.File]::WriteAllText($Destination, 'tampered', [Text.UTF8Encoding]::new($false)) } }
        Assert-CcodThrows { Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $fake.Adapters } 'CCOD_INSTALL_FILE_HASH_MISMATCH'
        Assert-CcodTrue (-not (Test-Path -LiteralPath (Join-Path $install 'active.json'))) 'hash mismatch never activates'
        Assert-CcodEqual 0 (Get-ChildItem -LiteralPath $install -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq '.staging' }).Count 'hash mismatch cleans staging'
    } finally {
        foreach ($path in @($source, $install, $nodeRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

$results += Invoke-CcodTest 'selected UI catalog mutation after inventory fails hash verification before activation' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source | Out-Null
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        $fake = New-CcodLifecycleFake -NodePath $nodePath
        $fake.World.CopyOverride = [pscustomobject]@{
            Match = '*ui.en-US.json'
            Action = {
                param($Source, $Destination)
                [IO.Directory]::CreateDirectory((Split-Path $Destination -Parent)) | Out-Null
                [IO.File]::Copy($Source, $Destination, $true)
                [IO.File]::WriteAllText($Source, '{"schemaVersion":1,"language":"tampered-after-inventory"}', [Text.UTF8Encoding]::new($false))
            }
        }
        Assert-CcodThrows { Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $fake.Adapters } 'CCOD_INSTALL_FILE_HASH_MISMATCH'
        Assert-CcodTrue (-not (Test-Path -LiteralPath (Join-Path $install 'active.json'))) 'post-inventory catalog mutation never activates'
    } finally {
        foreach ($path in @($source, $install, $nodeRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

$results += Invoke-CcodTest 'source reparse point fails closed before staging' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    $junctionTarget = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $source 'outside-target') -Force | Out-Null
        New-Item -ItemType Directory -Path $junctionTarget -Force | Out-Null
        $junction = Join-Path $source 'src\runtime\escape'
        cmd /c mklink /J "`"$junction`"" "`"$junctionTarget`"" | Out-Null
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        $fake = New-CcodLifecycleFake -NodePath $nodePath
        Assert-CcodThrows { Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $fake.Adapters } 'CCOD_INSTALL_SOURCE_REPARSE'
        Assert-CcodTrue (-not (Test-Path -LiteralPath (Join-Path $install 'active.json'))) 'source reparse never activates'
    } finally {
        foreach ($path in @($source, $install, $nodeRoot, $junctionTarget)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

$results += Invoke-CcodTest 'missing UI catalog fails closed before activation' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source | Out-Null
        [IO.File]::Delete((Join-Path $source 'src\persistence\resources\ui.zh-CN.json'))
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        $fake = New-CcodLifecycleFake -NodePath $nodePath
        Assert-CcodThrows { Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $fake.Adapters } 'CCOD_INSTALL_SOURCE_INCOMPLETE'
        Assert-CcodTrue (-not (Test-Path -LiteralPath (Join-Path $install 'active.json'))) 'missing catalog never activates'
    } finally {
        foreach ($path in @($source, $install, $nodeRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

$results += Invoke-CcodTest 'unknown UI catalog fails closed before activation' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source | Out-Null
        [IO.File]::WriteAllText((Join-Path $source 'src\persistence\resources\ui.fr-FR.json'), '{"schemaVersion":1,"language":"fr-FR"}', [Text.UTF8Encoding]::new($false))
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        $fake = New-CcodLifecycleFake -NodePath $nodePath
        Assert-CcodThrows { Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $fake.Adapters } 'CCOD_INSTALL_SOURCE_INCOMPLETE'
        Assert-CcodTrue (-not (Test-Path -LiteralPath (Join-Path $install 'active.json'))) 'unknown catalog never activates'
    } finally {
        foreach ($path in @($source, $install, $nodeRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

$results += Invoke-CcodTest 'case-variant UI catalog fails closed before activation' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source | Out-Null
        $catalog = Join-Path $source 'src\persistence\resources\ui.en-US.json'
        $temporary = Join-Path $source 'src\persistence\resources\catalog-temporary.json'
        [IO.File]::Move($catalog, $temporary)
        [IO.File]::Move($temporary, (Join-Path $source 'src\persistence\resources\ui.EN-us.json'))
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        $fake = New-CcodLifecycleFake -NodePath $nodePath
        Assert-CcodThrows { Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $fake.Adapters } 'CCOD_INSTALL_SOURCE_INCOMPLETE'
        Assert-CcodTrue (-not (Test-Path -LiteralPath (Join-Path $install 'active.json'))) 'case-variant catalog never activates'
    } finally {
        foreach ($path in @($source, $install, $nodeRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

$results += Invoke-CcodTest 'named UI catalog alternate data stream fails closed before activation' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source | Out-Null
        $catalog = Join-Path $source 'src\persistence\resources\ui.en-US.json'
        Set-Content -LiteralPath $catalog -Stream 'ccod-test' -Value 'unmanifested stream' -NoNewline
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        $fake = New-CcodLifecycleFake -NodePath $nodePath
        Assert-CcodThrows { Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $fake.Adapters } 'CCOD_INSTALL_SOURCE_INCOMPLETE'
        Assert-CcodTrue (-not (Test-Path -LiteralPath (Join-Path $install 'active.json'))) 'named catalog stream never activates'
    } finally {
        foreach ($path in @($source, $install, $nodeRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

$results += Invoke-CcodTest 'named UI resource directory alternate data stream fails closed before activation' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source | Out-Null
        $resources = Join-Path $source 'src\persistence\resources'
        Set-Content -LiteralPath ($resources + ':ccod-test') -Value 'unmanifested directory stream' -NoNewline
        Assert-CcodEqual 'unmanifested directory stream' (Get-Content -LiteralPath ($resources + ':ccod-test') -Raw) 'provider creates resource directory alternate data stream'
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        $fake = New-CcodLifecycleFake -NodePath $nodePath
        Assert-CcodThrows { Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $fake.Adapters } 'CCOD_INSTALL_SOURCE_INCOMPLETE'
        Assert-CcodTrue (-not (Test-Path -LiteralPath (Join-Path $install 'active.json'))) 'named resource directory stream never activates'
    } finally {
        foreach ($path in @($source, $install, $nodeRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

$results += Invoke-CcodTest 'non-catalog resource file fails closed before activation' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source | Out-Null
        [IO.File]::WriteAllText((Join-Path $source 'src\persistence\resources\README.txt'), 'not a catalog', [Text.UTF8Encoding]::new($false))
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        $fake = New-CcodLifecycleFake -NodePath $nodePath
        Assert-CcodThrows { Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $fake.Adapters } 'CCOD_INSTALL_SOURCE_INCOMPLETE'
        Assert-CcodTrue (-not (Test-Path -LiteralPath (Join-Path $install 'active.json'))) 'non-catalog resource file never activates'
    } finally {
        foreach ($path in @($source, $install, $nodeRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

$results += Invoke-CcodTest 'ordinary resource subdirectory fails closed before activation' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $source 'src\persistence\resources\locales') -Force | Out-Null
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        $fake = New-CcodLifecycleFake -NodePath $nodePath
        Assert-CcodThrows { Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $fake.Adapters } 'CCOD_INSTALL_SOURCE_INCOMPLETE'
        Assert-CcodTrue (-not (Test-Path -LiteralPath (Join-Path $install 'active.json'))) 'ordinary resource subdirectory never activates'
    } finally {
        foreach ($path in @($source, $install, $nodeRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

$results += Invoke-CcodTest 'UI resource directory reparse fails closed before activation' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    $target = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source | Out-Null
        $resources = Join-Path $source 'src\persistence\resources'
        [IO.Directory]::Move($resources, $target)
        cmd /c mklink /J "`"$resources`"" "`"$target`"" | Out-Null
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        $fake = New-CcodLifecycleFake -NodePath $nodePath
        Assert-CcodThrows { Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $fake.Adapters } 'CCOD_INSTALL_SOURCE_REPARSE'
        Assert-CcodTrue (-not (Test-Path -LiteralPath (Join-Path $install 'active.json'))) 'resource directory reparse never activates'
    } finally {
        foreach ($path in @($source, $install, $nodeRoot, $target)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

$results += Invoke-CcodTest 'UI resource file reparse fails closed before activation' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    $target = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source | Out-Null
        $resource = Join-Path $source 'src\persistence\resources\ui.en-US.json'
        [IO.Directory]::CreateDirectory($target) | Out-Null
        [IO.File]::Delete($resource)
        cmd /c mklink /J "`"$resource`"" "`"$target`"" | Out-Null
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        $fake = New-CcodLifecycleFake -NodePath $nodePath
        Assert-CcodThrows { Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $fake.Adapters } 'CCOD_INSTALL_SOURCE_REPARSE'
        Assert-CcodTrue (-not (Test-Path -LiteralPath (Join-Path $install 'active.json'))) 'resource file reparse never activates'
    } finally {
        foreach ($path in @($source, $install, $nodeRoot, $target)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

$results += Invoke-CcodTest 'invalid active pointer fails closed before upgrade' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source -Version '2.0.0-a' | Out-Null
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        $fake = New-CcodLifecycleFake -NodePath $nodePath
        Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $fake.Adapters | Out-Null
        [IO.File]::WriteAllText((Join-Path $install 'active.json'), '{"schemaVersion":9,"activeRuntime":"x","previousRuntime":null,"updatedAtUtc":"2030-02-03T03:04:05.0000000Z"}', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $source 'src\runtime\main-payload.js'), "module.exports = 'fixture-v2';`n", [Text.UTF8Encoding]::new($false))
        Assert-CcodThrows { Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $fake.Adapters } 'CCOD_SCHEMA_UNSUPPORTED'
    } finally {
        foreach ($path in @($source, $install, $nodeRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

$results += Invoke-CcodTest 'old supervisor shutdown timeout terminates only the verified identity' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source -Version '2.0.0-a' | Out-Null
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        $fake = New-CcodLifecycleFake -NodePath $nodePath
        $first = Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $fake.Adapters
        Set-CcodLifecycleTestStatus -InstallRoot $install -RuntimeId $first.RuntimeId
        [IO.File]::WriteAllText((Join-Path $source 'src\runtime\main-payload.js'), "module.exports = 'fixture-v2';`n", [Text.UTF8Encoding]::new($false))
        $fake2 = New-CcodLifecycleFake -NodePath $nodePath
        $fake2.World.WaitSupervisorExit = $false
        $second = Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $fake2.Adapters
        Assert-CcodEqual 'Upgraded' $second.Outcome 'timeout still completes upgrade'
        Assert-CcodEqual 1 $fake2.World.TerminateSupervisorCalls 'timeout terminates exactly one supervisor'
        Assert-CcodEqual $fake2.World.Identity.Pid $fake2.World.LastTerminateIdentity.Pid 'termination uses the current supervisor identity'
        Assert-CcodTrue (($fake2.World.Calls -contains 'TerminateSupervisor:41')) 'termination targets the verified pid only'
    } finally {
        foreach ($path in @($source, $install, $nodeRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

$results += Invoke-CcodTest 'repair state quarantines damage and resets consent with preserved valid node candidates' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source | Out-Null
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        $fake = New-CcodLifecycleFake -NodePath $nodePath
        Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -EnableCandidateCompatibleUpdates -Adapters $fake.Adapters | Out-Null
        [IO.File]::WriteAllText((Join-Path $install 'state\settings.json'), '{broken', [Text.UTF8Encoding]::new($false))
        $fake2 = New-CcodLifecycleFake -NodePath $nodePath
        $receipt = Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -RepairState -Adapters $fake2.Adapters
        Assert-CcodEqual 'Repaired' $receipt.Outcome 'repair outcome'
        Assert-CcodEqual $true $receipt.RepairCompleted 'repair completed flag'
        Assert-CcodEqual 0 $fake2.World.TaskInstalled 'repair does not reinstall task'
        Assert-CcodEqual 0 $fake2.World.TaskStarted 'repair does not start task'
        $state = Read-CcodState -StateRoot (Join-Path $install 'state')
        Assert-CcodEqual $false $state.Settings.automationEnabled 'repair resets automation'
        Assert-CcodEqual $false $state.Settings.candidateCompatibleOptIn 'repair resets consent'
        Assert-CcodEqual $nodePath $state.Settings.nodeCandidates[0] 'repair preserves revalidated node candidate'
        Assert-CcodTrue (@(Get-ChildItem -LiteralPath (Join-Path $install 'state') -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '*.corrupt.*' }).Count -ge 1) 'damaged settings quarantined'
    } finally {
        foreach ($path in @($source, $install, $nodeRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

$results += Invoke-CcodTest 'upgrade and repair preserve malformed UI preference without safety damage' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source -Version '2.0.0-ui-malformed' | Out-Null
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        $fake = New-CcodLifecycleFake -NodePath $nodePath
        $first = Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $fake.Adapters
        Set-CcodLifecycleTestStatus -InstallRoot $install -RuntimeId $first.RuntimeId
        $stateRoot = Join-Path $install 'state'
        $preferencePath = Join-Path $stateRoot 'ui-preferences.json'
        [byte[]]$malformed = 0x00,0x7b,0xff,0x13,0x0a
        [IO.File]::WriteAllBytes($preferencePath, $malformed)
        [IO.File]::WriteAllText((Join-Path $source 'src\runtime\main-payload.js'), "module.exports = 'fixture-ui-malformed-v2';`n", [Text.UTF8Encoding]::new($false))
        $upgrade = Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters (New-CcodLifecycleFake -NodePath $nodePath).Adapters
        Assert-CcodEqual 'Upgraded' $upgrade.Outcome 'malformed preference does not block ordinary upgrade'
        Assert-CcodEqual '007bff130a' (([IO.File]::ReadAllBytes($preferencePath) | ForEach-Object { $_.ToString('x2') }) -join '') 'ordinary upgrade preserves malformed UI preference bytes'
        $repairFake = New-CcodLifecycleFake -NodePath $nodePath
        $repair = Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -RepairState -Adapters $repairFake.Adapters
        Assert-CcodEqual 'Repaired' $repair.Outcome 'malformed preference does not block repair'
        Assert-CcodEqual '007bff130a' (([IO.File]::ReadAllBytes($preferencePath) | ForEach-Object { $_.ToString('x2') }) -join '') 'repair preserves malformed UI preference bytes'
        $state = Read-CcodState -StateRoot $stateRoot
        Assert-CcodEqual $false $state.Settings.automationEnabled 'repair applies its ordinary safety reset'
        Assert-CcodEqual 4 (@(Get-ChildItem -LiteralPath $stateRoot -File -ErrorAction Stop | Where-Object { $_.Name -like '*.corrupt.*' })).Count 'repair quarantines only its four safety-state files'
        Assert-CcodEqual 0 (@(Get-ChildItem -LiteralPath $stateRoot -File -ErrorAction Stop | Where-Object { $_.Name -like 'ui-preferences.json.corrupt.*' })).Count 'repair does not quarantine malformed UI preference'
        Assert-CcodEqual 0 $repairFake.World.TaskInstalled 'repair does not reinstall task for malformed preference'
    } finally {
        foreach ($path in @($source, $install, $nodeRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

$results += Invoke-CcodTest 'legacy missing UI preference remains absent across upgrade and follows Windows' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source -Version '2.0.0-ui-legacy' | Out-Null
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        $fake = New-CcodLifecycleFake -NodePath $nodePath
        $first = Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $fake.Adapters
        Set-CcodLifecycleTestStatus -InstallRoot $install -RuntimeId $first.RuntimeId
        $stateRoot = Join-Path $install 'state'
        $preferencePath = Join-Path $stateRoot 'ui-preferences.json'
        [IO.File]::Delete($preferencePath)
        [IO.File]::WriteAllText((Join-Path $source 'src\runtime\main-payload.js'), "module.exports = 'fixture-ui-legacy-v2';`n", [Text.UTF8Encoding]::new($false))
        $upgrade = Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters (New-CcodLifecycleFake -NodePath $nodePath).Adapters
        Assert-CcodEqual 'Upgraded' $upgrade.Outcome 'legacy preference absence does not block upgrade'
        Assert-CcodTrue (-not (Test-Path -LiteralPath $preferencePath)) 'legacy missing preference remains absent after upgrade'
        $preference = Read-CcodUiPreference -StateRoot $stateRoot
        Assert-CcodEqual 'System' $preference.LanguageMode 'legacy missing preference follows Windows'
        Assert-CcodEqual $true $preference.FallbackUsed 'legacy missing preference uses safe fallback'
    } finally {
        foreach ($path in @($source, $install, $nodeRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

$results += Invoke-CcodTest 'whatif install performs no task process or install mutation' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source | Out-Null
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        $fake = New-CcodLifecycleFake -NodePath $nodePath
        Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -EnableCandidateCompatibleUpdates -Adapters $fake.Adapters -WhatIf
        Assert-CcodTrue (-not (Test-Path -LiteralPath $install)) 'whatif creates no install root'
        Assert-CcodEqual 0 $fake.World.TaskInstalled 'whatif installs no task'
        Assert-CcodEqual 0 $fake.World.TaskStarted 'whatif starts no task'
        Assert-CcodEqual 0 $fake.World.ShutdownSignaled 'whatif signals no shutdown'
        Assert-CcodEqual 0 $fake.World.NormalizeCalls 'whatif normalizes no session'
    } finally {
        foreach ($path in @($source, $install, $nodeRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

$results += Invoke-CcodTest 'transactional uninstall reaches ReadyForInno only after recovery protection stop task proof and application removal' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    $keyRoot = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source | Out-Null
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        $fake = New-CcodLifecycleFake -NodePath $nodePath
        Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $fake.Adapters | Out-Null
        Set-CcodLifecycleTestStatus -InstallRoot $install -RuntimeId (Read-CcodLifecycleActivePointer -Root $install).activeRuntime
        $keyPath = Join-Path $keyRoot 'remote-control-device-keys.windows.json'
        New-Item -ItemType Directory -Path $keyRoot -Force | Out-Null
        [IO.File]::WriteAllText($keyPath, '{}', [Text.UTF8Encoding]::new($false))
        $fake2 = New-CcodLifecycleFake -NodePath $nodePath
        $fake2.World.KeyPath = $keyPath
        $transaction = New-CcodLifecycleUninstallTransaction -InstallRoot $install -Fake $fake2
        $receipt = Invoke-CcodLifecycleUninstallCleanupTest -InstallRoot $install -Transaction $transaction -Adapters $fake2.Adapters
        Assert-CcodEqual 'ReadyForInno' $receipt.Result.phase 'only the external transaction can authorize Inno deletion'
        Assert-CcodEqual 'Recovering,RecoveryProven,StoppingProtection,ProtectionStopped,TaskRemoved,ApplicationStateRemoved,ReadyForInno' ($receipt.WrittenPhases -join ',') 'uninstall phases are persisted in fail-closed order'
        Assert-CcodEqual 1 $fake2.World.TaskRemoved 'task removed'
        Assert-CcodEqual 1 $fake2.World.NormalizeCalls 'session normalization checked'
        Assert-CcodEqual 1 $fake2.World.ShutdownSignaled 'supervisor shutdown signaled'
        Assert-CcodTrue (-not (Test-Path -LiteralPath $install)) 'install root removed'
        Assert-CcodTrue (Test-Path -LiteralPath $keyPath -PathType Leaf) 'key file still present'
        Assert-CcodEqual 0 $fake2.World.BackupCalls 'transaction cleanup has no device-key backup path'
        Assert-CcodEqual 0 $fake2.World.RemoveKeyCalls 'transaction cleanup has no device-key removal path'
        Assert-CcodEqual 0 (@($fake2.World.Calls | Where-Object { $_ -eq 'ResolveKey' })).Count 'transaction cleanup never even resolves the device key store'
    } finally {
        foreach ($path in @($source, $install, $nodeRoot, $keyRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

$results += Invoke-CcodTest 'legacy controller compatibility recognizes only the sealed missing-ProcessControl input-validation signature' {
    $controller = Join-Path (New-CcodLifecycleTempRoot) 'SessionController.ps1'
    try {
        [IO.Directory]::CreateDirectory((Split-Path $controller -Parent)) | Out-Null
        [IO.File]::WriteAllText($controller, @'
$module = Get-Module ProcessControl -ErrorAction Stop
'@, [Text.UTF8Encoding]::new($false))
        $request = [pscustomobject][ordered]@{
            schemaVersion = 1; action = 'Recover'; transactionId = '33333333-4444-4555-8666-777777777777'; runtimeId = 'runtime-legacy'
        }
        $result = [pscustomobject][ordered]@{
            schemaVersion = 1; action = 'Recover'; ok = $false; outcome = 'Error'; safeState = 'Error'; stage = 'InputValidation'
            transactionId = $request.transactionId; package = $null; source = $null; special = $null; probes = $null; recovery = $null
            error = [pscustomobject][ordered]@{ code = 'CCOD_REQUEST_INVALID'; stage = 'InputValidation'; message = 'The session controller failed safely. See the session log for details.' }
            logFile = $null
        }
        $module = Get-Module InstallLifecycle -ErrorAction Stop
        $recognized = & $module { param($Value,$RequestValue,$Path) Test-CcodLifecycleLegacyControllerProcessControlFailure -Result $Value -Request $RequestValue -ExitCode 1 -ControllerPath $Path } $result $request $controller
        Assert-CcodEqual $true $recognized 'only the known sealed missing-import controller shape enters compatibility'
        Add-Content -LiteralPath $controller -Value "Import-Module (Join-Path `$controllerModuleRoot 'ProcessControl.psm1') -Force -Global" -Encoding utf8
        $recognizedWithImport = & $module { param($Value,$RequestValue,$Path) Test-CcodLifecycleLegacyControllerProcessControlFailure -Result $Value -Request $RequestValue -ExitCode 1 -ControllerPath $Path } $result $request $controller
        Assert-CcodEqual $false $recognizedWithImport 'a controller that imports ProcessControl cannot take the compatibility branch'
        $result.error.code = 'CCOD_CONTROLLER_ENGINE_RESULT_INVALID'
        $wrongError = & $module { param($Value,$RequestValue,$Path) Test-CcodLifecycleLegacyControllerProcessControlFailure -Result $Value -Request $RequestValue -ExitCode 1 -ControllerPath $Path } $result $request $controller
        Assert-CcodEqual $false $wrongError 'other controller failures cannot masquerade as legacy compatibility'
    } finally {
        $root = Split-Path $controller -Parent
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

$results += Invoke-CcodTest 'legacy controller compatibility keeps strict recovery, supervisor, tray, and task proofs before deletion' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source | Out-Null
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters (New-CcodLifecycleFake -NodePath $nodePath).Adapters | Out-Null
        $fake = New-CcodLifecycleFake -NodePath $nodePath
        $fake.Adapters.NormalizeSpecialSession = {
            param($InstallRoot,$RuntimeId,$Identity)
            $exception = [InvalidOperationException]::new('legacy ProcessControl import is absent')
            throw [Management.Automation.ErrorRecord]::new($exception, 'CCOD_UNINSTALL_LEGACY_CONTROLLER_PROCESSCONTROL_COMPATIBILITY', [Management.Automation.ErrorCategory]::InvalidData, $RuntimeId)
        }
        $transaction = New-CcodLifecycleUninstallTransaction -InstallRoot $install -Fake $fake
        $receipt = Invoke-CcodLifecycleUninstallCleanupTest -InstallRoot $install -Transaction $transaction -Adapters $fake.Adapters
        Assert-CcodEqual 'ReadyForInno' $receipt.Result.phase 'the independently inspected ordinary state may reach the native Inno handoff'
        Assert-CcodEqual 1 $fake.World.LegacyCompatibilityCalls 'compatibility inspection is entered only after the exact legacy failure'
        Assert-CcodEqual 2 $fake.World.LegacyCompatibilityVerifyCalls 'ordinary state is rechecked before both protected deletion boundaries'
        Assert-CcodEqual 2 $fake.World.SupervisorAbsenceChecks 'compatibility never bypasses the strict Supervisor-absence proof'
        Assert-CcodEqual 1 $fake.World.TaskRemoved 'task deletion still follows the compatibility verification'
        Assert-CcodTrue (-not (Test-Path -LiteralPath $install)) 'application deletion remains downstream of every proof'
    } finally {
        foreach ($path in @($source,$install,$nodeRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

$results += Invoke-CcodTest 'legacy compatibility fails closed for every non-matching controller error or changed ordinary-state proof' {
    foreach ($case in @(
        [pscustomobject]@{ Name='nonmatching controller failure'; Code='CCOD_UNINSTALL_NORMALIZATION_FAILED'; Verify=$true; Expected='CCOD_UNINSTALL_RECOVERY_FAILED'; CompatibilityCalls=0; VerifyCalls=0 },
        [pscustomobject]@{ Name='pre-task ordinary-state proof changed'; Code='CCOD_UNINSTALL_LEGACY_CONTROLLER_PROCESSCONTROL_COMPATIBILITY'; Verify=$false; Expected='CCOD_UNINSTALL_TASK_REMOVAL_FAILED'; CompatibilityCalls=1; VerifyCalls=1 }
    )) {
        $source = New-CcodLifecycleTempRoot
        $install = New-CcodLifecycleTempRoot
        $nodeRoot = New-CcodLifecycleTempRoot
        try {
            New-CcodLifecycleSourceFixture -Root $source | Out-Null
            $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
            Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters (New-CcodLifecycleFake -NodePath $nodePath).Adapters | Out-Null
            $fake = New-CcodLifecycleFake -NodePath $nodePath
            $fake.World.LegacyCompatibilityVerified = [bool]$case.Verify
            $fake.Adapters.NormalizeSpecialSession = {
                param($InstallRoot,$RuntimeId,$Identity)
                $exception = [InvalidOperationException]::new('controller recovery failed')
                throw [Management.Automation.ErrorRecord]::new($exception, $case.Code, [Management.Automation.ErrorCategory]::InvalidData, $RuntimeId)
            }.GetNewClosure()
            $transaction = New-CcodLifecycleUninstallTransaction -InstallRoot $install -Fake $fake
            Assert-CcodThrows { Invoke-CcodLifecycleUninstallCleanupTest -InstallRoot $install -Transaction $transaction -Adapters $fake.Adapters } $case.Expected
            Assert-CcodEqual $case.CompatibilityCalls $fake.World.LegacyCompatibilityCalls "$($case.Name) has the exact compatibility entry count"
            Assert-CcodEqual $case.VerifyCalls $fake.World.LegacyCompatibilityVerifyCalls "$($case.Name) has the exact compatibility recheck count"
            Assert-CcodEqual 0 $fake.World.TaskRemoved "$($case.Name) cannot delete the scheduled task"
            Assert-CcodTrue (Test-Path -LiteralPath $install) "$($case.Name) keeps the application tree intact"
        } finally {
            foreach ($path in @($source,$install,$nodeRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
        }
    }
}

$results += Invoke-CcodTest 'legacy compatibility rechecks a resumed transaction before every remaining deletion boundary' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source | Out-Null
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters (New-CcodLifecycleFake -NodePath $nodePath).Adapters | Out-Null
        $fake = New-CcodLifecycleFake -NodePath $nodePath
        $fake.Adapters.NormalizeSpecialSession = {
            param($InstallRoot,$RuntimeId,$Identity)
            $exception = [InvalidOperationException]::new('legacy ProcessControl import is absent')
            throw [Management.Automation.ErrorRecord]::new($exception, 'CCOD_UNINSTALL_LEGACY_CONTROLLER_PROCESSCONTROL_COMPATIBILITY', [Management.Automation.ErrorCategory]::InvalidData, $RuntimeId)
        }
        $proof = [pscustomobject]@{ Calls = 0 }
        $fake.Adapters.VerifyLegacyControllerCompatibility = {
            param($InstallRoot,$RuntimeId,$Identity,$Transaction)
            $proof.Calls++
            $fake.World.LegacyCompatibilityVerifyCalls++
            return ($proof.Calls -gt 1)
        }.GetNewClosure()
        $transaction = New-CcodLifecycleUninstallTransaction -InstallRoot $install -Fake $fake
        Assert-CcodThrows { Invoke-CcodLifecycleUninstallCleanupTest -InstallRoot $install -Transaction $transaction -Adapters $fake.Adapters } 'CCOD_UNINSTALL_TASK_REMOVAL_FAILED'
        Assert-CcodEqual 'ProtectionStopped' $transaction.phase 'failed pre-task proof leaves the transaction before task deletion'
        Assert-CcodEqual 0 $fake.World.TaskRemoved 'failed pre-task proof does not remove the scheduled task'
        $transaction.phase = 'Failed'
        $transaction.resumePhase = 'ProtectionStopped'
        $transaction.errorCode = 'CCOD_UNINSTALL_TASK_REMOVAL_FAILED'
        $receipt = Invoke-CcodLifecycleUninstallCleanupTest -InstallRoot $install -Transaction $transaction -Adapters $fake.Adapters
        Assert-CcodEqual 'ReadyForInno' $receipt.Result.phase 'the resumed transaction reaches the native Inno handoff only after fresh proofs'
        Assert-CcodEqual 1 $fake.World.LegacyCompatibilityCalls 'resume does not rerun the legacy fallback normalization'
        Assert-CcodEqual 3 $fake.World.LegacyCompatibilityVerifyCalls 'failed then resumed cleanup proves state before both remaining deletion boundaries'
        Assert-CcodEqual 1 $fake.World.TaskRemoved 'the task is removed only after the resumed fresh proof'
        Assert-CcodTrue (-not (Test-Path -LiteralPath $install)) 'the application tree is removed only after the resumed fresh proof'
    } finally {
        foreach ($path in @($source,$install,$nodeRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

$results += Invoke-CcodTest 'transactional uninstall fails closed before recovery when the transition lease is unavailable' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source | Out-Null
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        $fake = New-CcodLifecycleFake -NodePath $nodePath
        Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $fake.Adapters | Out-Null
        Set-CcodLifecycleTestStatus -InstallRoot $install -RuntimeId (Read-CcodLifecycleActivePointer -Root $install).activeRuntime
        $fake2 = New-CcodLifecycleFake -NodePath $nodePath
        $fake2.Adapters.EnterTransitionLease = { param($UserSid,$SessionId) [pscustomobject][ordered]@{ Outcome='TimedOut'; Released=$false; Handle=$null } }
        $transaction = New-CcodLifecycleUninstallTransaction -InstallRoot $install -Fake $fake2
        Assert-CcodThrows { Invoke-CcodLifecycleUninstallCleanupTest -InstallRoot $install -Transaction $transaction -Adapters $fake2.Adapters } 'CCOD_UNINSTALL_BUSY'
        Assert-CcodEqual 0 $fake2.World.NormalizeCalls 'busy transition does not attempt session recovery'
        Assert-CcodEqual 0 $fake2.World.TaskRemoved 'busy transition does not remove the scheduled task'
        Assert-CcodTrue (Test-Path -LiteralPath $install) 'busy transition leaves application state intact'
    } finally {
        foreach ($path in @($source, $install, $nodeRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

$results += Invoke-CcodTest 'transactional uninstall fails closed when exact Supervisor exit cannot be proven' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source | Out-Null
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        $fake = New-CcodLifecycleFake -NodePath $nodePath
        Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $fake.Adapters | Out-Null
        Set-CcodLifecycleTestStatus -InstallRoot $install -RuntimeId (Read-CcodLifecycleActivePointer -Root $install).activeRuntime
        $fake2 = New-CcodLifecycleFake -NodePath $nodePath
        $fake2.Adapters.WaitSupervisorExit = { param($SupervisorIdentity,$TimeoutMilliseconds) $false }
        $transaction = New-CcodLifecycleUninstallTransaction -InstallRoot $install -Fake $fake2
        Assert-CcodThrows { Invoke-CcodLifecycleUninstallCleanupTest -InstallRoot $install -Transaction $transaction -Adapters $fake2.Adapters } 'CCOD_UNINSTALL_PROTECTION_STOP_FAILED'
        Assert-CcodEqual 0 $fake2.World.TaskRemoved 'unproven supervisor exit does not remove the task'
        Assert-CcodTrue (Test-Path -LiteralPath $install) 'unproven supervisor exit keeps the application tree intact'
    } finally {
        foreach ($path in @($source, $install, $nodeRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

$results += Invoke-CcodTest 'transactional uninstall requires a positive Supervisor-absence proof when no status identity exists' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source | Out-Null
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        $fake = New-CcodLifecycleFake -NodePath $nodePath
        Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $fake.Adapters | Out-Null
        Remove-Item -LiteralPath (Join-Path $install 'state\status.json') -Force
        $fake2 = New-CcodLifecycleFake -NodePath $nodePath
        $fake2.World.SupervisorAbsent = $false
        $transaction = New-CcodLifecycleUninstallTransaction -InstallRoot $install -Fake $fake2
        Assert-CcodThrows { Invoke-CcodLifecycleUninstallCleanupTest -InstallRoot $install -Transaction $transaction -Adapters $fake2.Adapters } 'CCOD_UNINSTALL_PROTECTION_STOP_FAILED'
        Assert-CcodEqual 1 $fake2.World.SupervisorAbsenceChecks 'missing status cannot bypass the explicit Supervisor-absence proof'
        Assert-CcodEqual 0 $fake2.World.TaskRemoved 'unproven Supervisor absence does not remove the task'
        Assert-CcodTrue (Test-Path -LiteralPath $install) 'unproven Supervisor absence keeps the application tree intact'
    } finally {
        foreach ($path in @($source, $install, $nodeRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

$results += Invoke-CcodTest 'transactional uninstall never trusts an unverified status Supervisor identity' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source | Out-Null
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        $fake = New-CcodLifecycleFake -NodePath $nodePath
        Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $fake.Adapters | Out-Null
        Set-CcodLifecycleTestStatus -InstallRoot $install -RuntimeId (Read-CcodLifecycleActivePointer -Root $install).activeRuntime
        $fake2 = New-CcodLifecycleFake -NodePath $nodePath
        $fake2.World.SupervisorIdentityVerified = $false
        $fake2.World.SupervisorAbsent = $false
        $transaction = New-CcodLifecycleUninstallTransaction -InstallRoot $install -Fake $fake2
        Assert-CcodThrows { Invoke-CcodLifecycleUninstallCleanupTest -InstallRoot $install -Transaction $transaction -Adapters $fake2.Adapters } 'CCOD_UNINSTALL_PROTECTION_STOP_FAILED'
        Assert-CcodEqual 1 $fake2.World.SupervisorIdentityVerifications 'status identity is verified before any Supervisor shutdown action'
        Assert-CcodEqual 0 $fake2.World.ShutdownSignaled 'an unverified status PID is never signaled or terminated'
        Assert-CcodEqual 0 $fake2.World.TaskRemoved 'an unverified status identity cannot authorize task removal'
        Assert-CcodTrue (Test-Path -LiteralPath $install) 'unverified status identity keeps the application tree intact'
    } finally {
        foreach ($path in @($source, $install, $nodeRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

$results += Invoke-CcodTest 'Supervisor absence proof rejects a current-session runtime Supervisor and malformed process evidence' {
    $install = New-CcodLifecycleTempRoot
    try {
        $runtimeId = 'uninstall-absence-test'
        $supervisorPath = Join-Path $install ('runtime\' + $runtimeId + '\src\persistence\Supervisor.ps1')
        [IO.Directory]::CreateDirectory((Split-Path $supervisorPath -Parent)) | Out-Null
        [IO.File]::WriteAllText($supervisorPath, '# test fixture', [Text.UTF8Encoding]::new($false))
        $identity = [pscustomobject][ordered]@{ UserSid='S-1-5-21-111-222-333-1001'; SessionId=[int]1 }
        $candidate = [pscustomobject][ordered]@{ ProcessId=[int]41; SessionId=[int]1; CommandLine=('-File "' + $supervisorPath + '" -ReadyToken ' + ('a' * 64)) }
        $module = Get-Module InstallLifecycle -ErrorAction Stop
        $foundEnumerator = { @($candidate) }.GetNewClosure()
        $absentWithSupervisor = & $module { param($Root,$Identity,$Enumerator) Test-CcodLifecycleVerifiedSupervisorAbsent -InstallRoot $Root -Identity $Identity -ProcessEnumerator $Enumerator } $install $identity $foundEnumerator
        Assert-CcodEqual $false $absentWithSupervisor 'a current-session Supervisor below the exact runtime root is never treated as absent'
        $malformedEnumerator = { @([pscustomobject]@{ ProcessId=[int]42; SessionId=[int]1; CommandLine=$null }) }
        $absentWithMalformedEvidence = & $module { param($Root,$Identity,$Enumerator) Test-CcodLifecycleVerifiedSupervisorAbsent -InstallRoot $Root -Identity $Identity -ProcessEnumerator $Enumerator } $install $identity $malformedEnumerator
        Assert-CcodEqual $false $absentWithMalformedEvidence 'incomplete process inspection cannot prove Supervisor absence'
        $emptyEnumerator = { @() }
        $absentWithEmptySnapshot = & $module { param($Root,$Identity,$Enumerator) Test-CcodLifecycleVerifiedSupervisorAbsent -InstallRoot $Root -Identity $Identity -ProcessEnumerator $Enumerator } $install $identity $emptyEnumerator
        Assert-CcodEqual $true $absentWithEmptySnapshot 'a complete empty current-process snapshot proves Supervisor absence'
    } finally {
        if (Test-Path -LiteralPath $install) { Remove-Item -LiteralPath $install -Recurse -Force }
    }
}

$results += Invoke-CcodTest 'verified Supervisor fallback binds the exact bootstrap parent runtime path and ready token' {
    $install = New-CcodLifecycleTempRoot
    try {
        $runtimeId = 'uninstall-fallback-test'
        $bootstrapPath = Join-Path $install 'bootstrap.ps1'
        $supervisorPath = Join-Path $install ('runtime\' + $runtimeId + '\src\persistence\Supervisor.ps1')
        [IO.Directory]::CreateDirectory((Split-Path $supervisorPath -Parent)) | Out-Null
        [IO.File]::WriteAllText($bootstrapPath, '# test fixture', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($supervisorPath, '# test fixture', [Text.UTF8Encoding]::new($false))
        $identity = [pscustomobject][ordered]@{ UserSid='S-1-5-21-111-222-333-1001'; SessionId=[int]1 }
        $parent = [pscustomobject][ordered]@{
            ProcessId=[int]40; ParentProcessId=[int]1; SessionId=[int]1
            CommandLine=('-File "' + $bootstrapPath + '" -InstallRoot "' + $install + '"')
            CreationDate=[DateTime]::Parse('2030-02-03T03:00:00Z').ToUniversalTime()
        }
        $child = [pscustomobject][ordered]@{
            ProcessId=[int]41; ParentProcessId=[int]40; SessionId=[int]1
            CommandLine=('-File "' + $supervisorPath + '" -ReadyToken ' + ('a' * 64))
            CreationDate=[DateTime]::Parse('2030-02-03T03:00:01Z').ToUniversalTime()
        }
        $enumerator = { @($parent,$child) }.GetNewClosure()
        $ownerResolver = { param($Process) [pscustomobject][ordered]@{ ReturnValue=[int]0; Sid=[string]$identity.UserSid } }.GetNewClosure()
        $module = Get-Module InstallLifecycle -ErrorAction Stop
        $fallback = & $module { param($Root,$CurrentIdentity,$Enumerator,$OwnerResolver) Get-CcodLifecycleVerifiedSupervisorFallback -InstallRoot $Root -Identity $CurrentIdentity -ProcessEnumerator $Enumerator -OwnerSidResolver $OwnerResolver } $install $identity $enumerator $ownerResolver
        Assert-CcodEqual 41 $fallback.Pid 'fallback recognizes only the exact current-session Supervisor child'
        Assert-CcodEqual '2030-02-03T03:00:01.0000000Z' $fallback.CreationTimeUtc 'fallback retains the canonical child creation identity'
        Assert-CcodEqual $identity.UserSid $fallback.UserSid 'fallback retains the verified current-user owner'
    } finally {
        if (Test-Path -LiteralPath $install) { Remove-Item -LiteralPath $install -Recurse -Force }
    }
}

$results += Invoke-CcodTest 'transactional uninstall stops a proven TrayHost by PID creation-time identity before task removal' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source | Out-Null
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        $fake = New-CcodLifecycleFake -NodePath $nodePath
        Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $fake.Adapters | Out-Null
        Set-CcodLifecycleTestStatus -InstallRoot $install -RuntimeId (Read-CcodLifecycleActivePointer -Root $install).activeRuntime
        $fake2 = New-CcodLifecycleFake -NodePath $nodePath
        $tray = [pscustomobject][ordered]@{ Pid=[int]73; CreationTimeUtc='2030-02-03T03:00:00.0000000Z'; SessionId=[int]$fake2.World.Identity.SessionId; UserSid=[string]$fake2.World.Identity.UserSid }
        $trayState = [pscustomobject]@{ Enumerations = 0 }
        $fake2.Adapters.FindTrayHostIdentities = {
            param($InstallRoot,$RuntimeId,$Identity)
            $trayState.Enumerations++
            if ($trayState.Enumerations -eq 1) { return @($tray) }
            return @()
        }.GetNewClosure()
        $transaction = New-CcodLifecycleUninstallTransaction -InstallRoot $install -Fake $fake2
        $receipt = Invoke-CcodLifecycleUninstallCleanupTest -InstallRoot $install -Transaction $transaction -Adapters $fake2.Adapters
        Assert-CcodEqual 'ReadyForInno' $receipt.Result.phase 'exact TrayHost proof permits the next phase'
        Assert-CcodEqual 1 $fake2.World.ExactProcessWaits 'TrayHost exit is observed before task removal'
        Assert-CcodEqual 0 $fake2.World.ExactProcessTerminates 'an already-exited exact TrayHost is not terminated'
        Assert-CcodEqual 1 $fake2.World.TaskRemoved 'task removal happens only after TrayHost proof'
    } finally {
        foreach ($path in @($source, $install, $nodeRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

$results += Invoke-CcodTest 'transactional uninstall refuses application deletion until scheduled-task absence is proven' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source | Out-Null
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        $fake = New-CcodLifecycleFake -NodePath $nodePath
        Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $fake.Adapters | Out-Null
        Set-CcodLifecycleTestStatus -InstallRoot $install -RuntimeId (Read-CcodLifecycleActivePointer -Root $install).activeRuntime
        $fake2 = New-CcodLifecycleFake -NodePath $nodePath
        $fake2.World.TaskAbsent = $false
        $transaction = New-CcodLifecycleUninstallTransaction -InstallRoot $install -Fake $fake2
        Assert-CcodThrows { Invoke-CcodLifecycleUninstallCleanupTest -InstallRoot $install -Transaction $transaction -Adapters $fake2.Adapters } 'CCOD_UNINSTALL_TASK_REMOVAL_FAILED'
        Assert-CcodEqual 1 $fake2.World.TaskRemoved 'task deletion is attempted once'
        Assert-CcodTrue (Test-Path -LiteralPath $install) 'unproven task absence blocks application deletion'
        Assert-CcodEqual 0 $fake2.World.BackupCalls 'there is no legacy key backup behavior'
    } finally {
        foreach ($path in @($source, $install, $nodeRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

$results += Invoke-CcodTest 'transactional uninstall refuses partial application deletion when the active pointer is already gone' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source | Out-Null
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        $fake = New-CcodLifecycleFake -NodePath $nodePath
        Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $fake.Adapters | Out-Null
        Set-CcodLifecycleTestStatus -InstallRoot $install -RuntimeId (Read-CcodLifecycleActivePointer -Root $install).activeRuntime
        $fake2 = New-CcodLifecycleFake -NodePath $nodePath
        $transaction = New-CcodLifecycleUninstallTransaction -InstallRoot $install -Fake $fake2 -Phase 'TaskRemoved'
        [IO.File]::Delete((Join-Path $install 'active.json'))
        $fake2.World.LegacyCompatibilityVerified = $false
        Assert-CcodThrows { Invoke-CcodLifecycleUninstallCleanupTest -InstallRoot $install -Transaction $transaction -Adapters $fake2.Adapters } 'CCOD_UNINSTALL_APPLICATION_STATE_REMOVAL_FAILED'
        Assert-CcodEqual 0 $fake2.World.TaskRemoved 'partial deletion retry never repeats task removal'
        Assert-CcodEqual 0 $fake2.World.AutomationPaused 'partial deletion retry does not touch deleted state files'
        Assert-CcodEqual 1 $fake2.World.LegacyCompatibilityVerifyCalls 'partial deletion retry requires a fresh ordinary-state proof'
        Assert-CcodTrue (Test-Path -LiteralPath $install) 'missing active-runtime evidence blocks further application deletion'
    } finally {
        foreach ($path in @($source, $install, $nodeRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

$results += Invoke-CcodTest 'application-state completion phases refuse to authorize Inno while the install root still exists' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source | Out-Null
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        $fake = New-CcodLifecycleFake -NodePath $nodePath
        Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $fake.Adapters | Out-Null
        Set-CcodLifecycleTestStatus -InstallRoot $install -RuntimeId (Read-CcodLifecycleActivePointer -Root $install).activeRuntime
        $fake2 = New-CcodLifecycleFake -NodePath $nodePath
        $applicationRemoved = New-CcodLifecycleUninstallTransaction -InstallRoot $install -Fake $fake2 -Phase 'ApplicationStateRemoved'
        Assert-CcodThrows { Invoke-CcodLifecycleUninstallCleanupTest -InstallRoot $install -Transaction $applicationRemoved -Adapters $fake2.Adapters } 'CCOD_UNINSTALL_APPLICATION_STATE_REMOVAL_FAILED'
        $readyForInno = New-CcodLifecycleUninstallTransaction -InstallRoot $install -Fake $fake2 -Phase 'ReadyForInno'
        Assert-CcodThrows { Invoke-CcodLifecycleUninstallCleanupTest -InstallRoot $install -Transaction $readyForInno -Adapters $fake2.Adapters } 'CCOD_UNINSTALL_APPLICATION_STATE_REMOVAL_FAILED'
        Assert-CcodTrue (Test-Path -LiteralPath $install) 'invalid completion phases cannot delete or authorize deletion of a surviving application tree'
    } finally {
        foreach ($path in @($source, $install, $nodeRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

$results += Invoke-CcodTest 'the legacy direct uninstall command and key-management switches are absent from the module surface' {
    $module = Get-Module -Name InstallLifecycle -ErrorAction Stop
    Assert-CcodTrue (-not $module.ExportedCommands.ContainsKey('Invoke-CcodUninstall')) 'legacy direct uninstall is not exported'
    Assert-CcodTrue ($null -eq (Get-Command Invoke-CcodUninstall -ErrorAction SilentlyContinue)) 'callers cannot resolve the retired direct uninstall command'
    $source = Get-Content -LiteralPath $installLifecycleModule -Raw
    Assert-CcodTrue ($source -notmatch '(?m)^function\s+Invoke-CcodUninstall\s*\{') 'legacy direct uninstall implementation is removed'
    foreach ($switchName in @('KeepCurrentSpecialSession','BackupDeviceKeyStore','RemoveDeviceKeyStore')) {
        Assert-CcodTrue ($source -notmatch [regex]::Escape($switchName)) "legacy key-management switch $switchName is absent"
    }
}

$results += Invoke-CcodTest 'Inno owns the fail-closed bootstrap handoff and the public wrapper only delegates to Inno' {
    $innoPath = Join-Path $repositoryRoot 'build\CodexControlOtherDevices.iss'
    $wrapperPath = Join-Path $repositoryRoot 'Uninstall-CodexControlOtherDevices.ps1'
    $inno = Get-Content -LiteralPath $innoPath -Raw
    $wrapper = Get-Content -LiteralPath $wrapperPath -Raw
    Assert-CcodTrue ($inno -notmatch '(?m)^\s*\[UninstallRun\]') 'Inno has no legacy pre-delete UninstallRun route'
    Assert-CcodTrue ($inno -match 'function\s+InitializeUninstall\s*\(\)\s*:\s*Boolean') 'Inno has a pre-delete uninstall gate'
    Assert-CcodTrue ($inno -match 'UninstallBootstrap\.ps1' -and $inno -match '-Mode\s+Prepare') 'Inno invokes the staged bootstrap prepare phase'
    Assert-CcodTrue ($inno -match 'CurUninstallStepChanged' -and $inno -match '-Mode\s+FinalizeReceipt') 'Inno writes completion only after its file deletion phase'
    Assert-CcodTrue ($inno -match 'CCOD_UNINSTALL_FINALIZATION_MISSING' -and $inno -match 'CCOD_UNINSTALL_FINALIZATION_FAILED') 'Inno propagates a missing or failed post-delete completion receipt instead of reporting a false successful uninstall'
    Assert-CcodTrue ($inno -notmatch 'BackupDeviceKeyStore|RemoveDeviceKeyStore|KeepCurrentSpecialSession') 'Inno exposes no key or special-session uninstall options'
    Assert-CcodTrue ($wrapper -match 'unins000\.exe') 'public PowerShell wrapper delegates to the generated Inno uninstaller'
    Assert-CcodTrue ($wrapper -notmatch 'Import-Module|Invoke-CcodUninstall') 'public PowerShell wrapper cannot perform direct lifecycle cleanup'
    Assert-CcodTrue ($wrapper -match 'CCOD_UNINSTALL_OPTION_REMOVED') 'deprecated wrapper switches fail closed instead of changing key behavior'
}

$results += Invoke-CcodTest 'remove path validation refuses out-of-root and reparse targets' {
    $install = New-CcodLifecycleTempRoot
    $outside = New-CcodLifecycleTempRoot
    try {
        New-Item -ItemType Directory -Path $install -Force | Out-Null
        New-Item -ItemType Directory -Path $outside -Force | Out-Null
        Assert-CcodThrows { Test-CcodLifecycleRemovePath -Root $install -Path (Join-Path $outside 'file.json') } 'CCOD_INSTALL_PATH_OUTSIDE_ROOT'
        Assert-CcodEqual $true (Test-CcodLifecycleRemovePath -Root $install -Path (Join-Path $install 'state')) 'contained path is accepted'
    } finally {
        foreach ($path in @($install, $outside)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}


$results += Invoke-CcodTest 'default adapters keep module session state for private helpers' {
    $mod = Get-Module InstallLifecycle
    Assert-CcodTrue ($null -ne $mod) 'InstallLifecycle module is loaded'
    $adapters = & $mod { Get-CcodLifecycleAdapters }
    Assert-CcodTrue ($adapters.ContainsKey('GetProjectVersion')) 'GetProjectVersion adapter exists'
    Assert-CcodTrue ($adapters.ContainsKey('NormalizeSpecialSession')) 'NormalizeSpecialSession adapter exists'

    $source = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source -Version '2.0.0-default-adapters' | Out-Null
        $version = & $adapters.GetProjectVersion $source
        Assert-CcodEqual '2.0.0-default-adapters' $version 'default GetProjectVersion resolves package.json through module-private helper'
    } finally {
        if (Test-Path -LiteralPath $source) { Remove-Item -LiteralPath $source -Recurse -Force }
    }

    $commandNames = @($adapters.GetProjectVersion.Ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() })
    Assert-CcodTrue ($commandNames -contains 'Get-CcodLifecycleProjectVersion') 'default GetProjectVersion still targets the private helper'
}

$results += Invoke-CcodTest 'uninstall recovery preclaims a durable nonempty controller result before launching a legacy runtime controller' {
    $source = Get-Content -LiteralPath $installLifecycleModule -Raw -Encoding UTF8
    $recover = [regex]::Match($source, '(?ms)^function Invoke-CcodLifecycleControllerRecover\s*\{(?<body>.*?)(?=^function Get-CcodLifecycleAdapters\s*\{)')
    Assert-CcodTrue $recover.Success 'controller recovery implementation exists as one bounded function'
    $body = $recover.Groups['body'].Value
    $open = $body.IndexOf('$resultPlaceholder = [IO.File]::Open($resultPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)')
    $bytes = $body.IndexOf('$resultPlaceholderBytes = [Text.UTF8Encoding]::new($false).GetBytes("{}`n")')
    $write = $body.IndexOf('$resultPlaceholder.Write($resultPlaceholderBytes, 0, $resultPlaceholderBytes.Length)')
    $flush = $body.IndexOf('$resultPlaceholder.Flush($true)')
    $dispose = $body.IndexOf('$resultPlaceholder.Dispose()')
    $launch = $body.IndexOf('$powershell = (Get-Command powershell.exe -ErrorAction Stop).Source')
    Assert-CcodTrue ($open -ge 0 -and $bytes -gt $open -and $write -gt $bytes -and $flush -gt $write -and $dispose -gt $flush -and $launch -gt $dispose) 'owned nonempty result placeholder is written and flushed before the controller launch'
}

$results += Invoke-CcodTest 'timed out supervisor shutdown never terminates a reused PID' {
    $fake = New-CcodLifecycleFake
    $fake.World.WaitSupervisorExit = $false
    $fake.World.SupervisorIdentityCurrent = $false
    $identity = [pscustomobject][ordered]@{
        Pid = 97
        CreationTimeUtc = '2030-02-03T03:00:00.0000000Z'
        SessionId = $fake.World.Identity.SessionId
        UserSid = $fake.World.Identity.UserSid
    }
    $module = Get-Module InstallLifecycle
    $stopped = & $module { param($Adapters, $SupervisorIdentity) Stop-CcodLifecycleSupervisor -InstallRoot 'C:\ccod-test' -Adapters $Adapters -Identity $SupervisorIdentity } $fake.Adapters $identity
    Assert-CcodEqual $true $stopped 'a changed process identity means the verified supervisor already exited'
    Assert-CcodEqual 1 $fake.World.SupervisorIdentityChecks 'shutdown timeout rechecks the process identity before termination'
    Assert-CcodEqual 0 $fake.World.TerminateSupervisorCalls 'a reused PID is never terminated'
}

# Production mutation caught: treating a successful terminate request as exact old-Supervisor exit without observing that PID/creation-time identity disappear.
$results += Invoke-CcodTest 'forced previous Supervisor termination still requires exact exit proof' {
    $identity = [pscustomobject][ordered]@{ Pid=97;CreationTimeUtc='2030-02-03T03:00:00.0000000Z';SessionId=1;UserSid='S-1-5-21-111-222-333-1001' }
    $world = [pscustomobject]@{ Waits=0;Terminates=0;Calls=[Collections.Generic.List[string]]::new() }
    $adapters = @{
        SignalSupervisorShutdown = { param($UserSid,$SessionId) $world.Calls.Add('signal') }.GetNewClosure()
        WaitSupervisorExit = { param($SupervisorIdentity,$TimeoutMilliseconds) $world.Waits++;$world.Calls.Add("wait:$TimeoutMilliseconds");$world.Waits-ge2 }.GetNewClosure()
        IsSupervisorIdentityCurrent = { param($SupervisorIdentity) $true }
        TerminateSupervisor = { param($SupervisorIdentity) $world.Terminates++;$world.Calls.Add('terminate');$true }.GetNewClosure()
    }
    $module = Get-Module InstallLifecycle
    $stopped = & $module { param($LifecycleAdapters,$SupervisorIdentity) Stop-CcodLifecycleSupervisor -InstallRoot 'C:\ccod-test' -Adapters $LifecycleAdapters -Identity $SupervisorIdentity } $adapters $identity
    Assert-CcodEqual $true $stopped 'forced stop succeeds only after exact exit is observed'
    Assert-CcodEqual 'signal,wait:10000,terminate,wait:5000' ($world.Calls -join ',') 'termination is followed by a bounded exact-exit wait'
    Assert-CcodEqual 2 $world.Waits 'old identity disappearance is observed after terminate'
}

$results += Invoke-CcodTest 'ambiguous legacy supervisor fallback aborts upgrade before pointer activation' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source -Version '2.0.0-ambiguous' | Out-Null
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        $first = Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters (New-CcodLifecycleFake -NodePath $nodePath).Adapters
        [IO.File]::WriteAllText((Join-Path $source 'src\runtime\main-payload.js'), "module.exports = 'fixture-ambiguous-v2';`n", [Text.UTF8Encoding]::new($false))
        $fake = New-CcodLifecycleFake -NodePath $nodePath
        $fake.Adapters.FindSupervisorFallback = {
            throw [Management.Automation.ErrorRecord]::new(
                [InvalidOperationException]::new('Two verified legacy supervisors are present.'),
                'CCOD_INSTALL_SUPERVISOR_AMBIGUOUS',
                [Management.Automation.ErrorCategory]::ResourceBusy,
                $null
            )
        }
        Assert-CcodThrows { Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $fake.Adapters } 'CCOD_INSTALL_SUPERVISOR_AMBIGUOUS'
        $pointer = Read-CcodLifecycleActivePointer -Root $install
        Assert-CcodEqual $first.RuntimeId $pointer.activeRuntime 'ambiguous fallback leaves the active runtime pointer unchanged'
        Assert-CcodEqual 0 $fake.World.TaskInstalled 'ambiguous fallback does not replace the task'
    } finally {
        foreach ($path in @($source, $install, $nodeRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

$results += Invoke-CcodTest 'upgrade stops a verified fallback supervisor when status has no session identity' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source -Version '2.0.0-fallback' | Out-Null
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        $first = Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters (New-CcodLifecycleFake -NodePath $nodePath).Adapters
        $status = Read-CcodStatus -StateRoot (Join-Path $install 'state')
        Assert-CcodTrue ($null -eq $status.session) 'fixture reproduces the legacy status without a supervisor identity'
        [IO.File]::WriteAllText((Join-Path $source 'src\runtime\main-payload.js'), "module.exports = 'fixture-fallback-v2';`n", [Text.UTF8Encoding]::new($false))
        $fake = New-CcodLifecycleFake -NodePath $nodePath
        $fake.World.FallbackSupervisor = [pscustomobject][ordered]@{
            Pid = 97
            CreationTimeUtc = '2030-02-03T03:00:00.0000000Z'
            SessionId = $fake.World.Identity.SessionId
            UserSid = $fake.World.Identity.UserSid
        }
        $upgrade = Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $fake.Adapters
        Assert-CcodEqual 'Upgraded' $upgrade.Outcome 'fallback upgrade outcome'
        Assert-CcodEqual 1 $fake.World.FallbackSupervisorLookups 'legacy status triggers one verified fallback lookup'
        Assert-CcodEqual 1 $fake.World.ShutdownSignaled 'verified fallback supervisor receives shutdown signal'
        Assert-CcodTrue ($fake.World.Calls -contains 'WaitSupervisor:97:10000') 'upgrade waits for the verified fallback pid'
    } finally {
        foreach ($path in @($source, $install, $nodeRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

$results += Invoke-CcodTest 'fallback accepts a deleted legacy runtime only through the exact stable bootstrap parent' {
    $install = New-CcodLifecycleTempRoot
    try {
        $identity = New-CcodLifecycleIdentity
        New-Item -ItemType Directory -Path $install -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $install 'bootstrap.ps1'), '# fixture bootstrap', [Text.UTF8Encoding]::new($false))
        $oldSupervisor = Join-Path $install 'runtime\2.1.1-deleted\src\persistence\Supervisor.ps1'
        $bootstrap = Join-Path $install 'bootstrap.ps1'
        $processes = @(
            [pscustomobject][ordered]@{
                ProcessId = 97
                ParentProcessId = 96
                SessionId = $identity.SessionId
                CreationDate = [DateTime]::Parse('2030-02-03T03:00:00Z').ToUniversalTime()
                CommandLine = "powershell.exe -File `"$oldSupervisor`" -ReadyToken $('a' * 64)"
            },
            [pscustomobject][ordered]@{
                ProcessId = 96
                ParentProcessId = 1
                SessionId = $identity.SessionId
                CreationDate = [DateTime]::Parse('2030-02-03T02:59:59Z').ToUniversalTime()
                CommandLine = "powershell.exe -File `"$bootstrap`" -InstallRoot `"$install`""
            }
        )
        $module = Get-Module InstallLifecycle
        $fallback = & $module {
            param($Root, $CurrentIdentity, $Snapshots)
            Get-CcodLifecycleVerifiedSupervisorFallback -InstallRoot $Root -Identity $CurrentIdentity -ProcessEnumerator { param($Ignored) $Snapshots } -OwnerSidResolver { param($Process) [pscustomobject]@{ ReturnValue = 0; Sid = $CurrentIdentity.UserSid } }
        } $install $identity $processes
        Assert-CcodEqual 97 $fallback.Pid 'legacy runtime process is accepted only with the exact bootstrap parent'
        Assert-CcodEqual $identity.UserSid $fallback.UserSid 'fallback carries the verified owner SID'
    } finally {
        if (Test-Path -LiteralPath $install) { Remove-Item -LiteralPath $install -Recurse -Force }
    }
}

$results += Invoke-CcodTest 'fallback rejects a legacy runtime whose parent is not the stable bootstrap' {
    $install = New-CcodLifecycleTempRoot
    try {
        $identity = New-CcodLifecycleIdentity
        New-Item -ItemType Directory -Path $install -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $install 'bootstrap.ps1'), '# fixture bootstrap', [Text.UTF8Encoding]::new($false))
        $oldSupervisor = Join-Path $install 'runtime\2.1.1-deleted\src\persistence\Supervisor.ps1'
        $processes = @(
            [pscustomobject][ordered]@{
                ProcessId = 97
                ParentProcessId = 96
                SessionId = $identity.SessionId
                CreationDate = [DateTime]::Parse('2030-02-03T03:00:00Z').ToUniversalTime()
                CommandLine = "powershell.exe -File `"$oldSupervisor`" -ReadyToken $('a' * 64)"
            },
            [pscustomobject][ordered]@{
                ProcessId = 96
                ParentProcessId = 1
                SessionId = $identity.SessionId
                CreationDate = [DateTime]::Parse('2030-02-03T02:59:59Z').ToUniversalTime()
                CommandLine = "powershell.exe -File `"C:\unrelated\bootstrap.ps1`" -InstallRoot `"$install`""
            }
        )
        $module = Get-Module InstallLifecycle
        $fallback = & $module {
            param($Root, $CurrentIdentity, $Snapshots)
            Get-CcodLifecycleVerifiedSupervisorFallback -InstallRoot $Root -Identity $CurrentIdentity -ProcessEnumerator { param($Ignored) $Snapshots } -OwnerSidResolver { param($Process) [pscustomobject]@{ ReturnValue = 0; Sid = $CurrentIdentity.UserSid } }
        } $install $identity $processes
        Assert-CcodTrue ($null -eq $fallback) 'lookalike parent does not authorize fallback termination'
    } finally {
        if (Test-Path -LiteralPath $install) { Remove-Item -LiteralPath $install -Recurse -Force }
    }
}

$results += Invoke-CcodTest 'fallback rejects two verified supervisor children as ambiguous' {
    $install = New-CcodLifecycleTempRoot
    try {
        $identity = New-CcodLifecycleIdentity
        New-Item -ItemType Directory -Path $install -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $install 'bootstrap.ps1'), '# fixture bootstrap', [Text.UTF8Encoding]::new($false))
        $bootstrap = Join-Path $install 'bootstrap.ps1'
        $runtimeRoot = Join-Path $install 'runtime'
        $processes = @(
            [pscustomobject]@{ ProcessId = 96; ParentProcessId = 1; SessionId = $identity.SessionId; CreationDate = [DateTime]::Parse('2030-02-03T02:59:59Z').ToUniversalTime(); CommandLine = "powershell.exe -File `"$bootstrap`" -InstallRoot `"$install`"" },
            [pscustomobject]@{ ProcessId = 97; ParentProcessId = 96; SessionId = $identity.SessionId; CreationDate = [DateTime]::Parse('2030-02-03T03:00:00Z').ToUniversalTime(); CommandLine = "powershell.exe -File `"$runtimeRoot\2.1.1\src\persistence\Supervisor.ps1`" -ReadyToken $('a' * 64)" },
            [pscustomobject]@{ ProcessId = 98; ParentProcessId = 96; SessionId = $identity.SessionId; CreationDate = [DateTime]::Parse('2030-02-03T03:00:01Z').ToUniversalTime(); CommandLine = "powershell.exe -File `"$runtimeRoot\2.1.2\src\persistence\Supervisor.ps1`" -ReadyToken $('b' * 64)" }
        )
        $module = Get-Module InstallLifecycle
        Assert-CcodThrows {
            & $module {
                param($Root, $CurrentIdentity, $Snapshots)
                Get-CcodLifecycleVerifiedSupervisorFallback -InstallRoot $Root -Identity $CurrentIdentity -ProcessEnumerator { param($Ignored) $Snapshots } -OwnerSidResolver { param($Process) [pscustomobject]@{ ReturnValue = 0; Sid = $CurrentIdentity.UserSid } }
            } $install $identity $processes
        } 'CCOD_INSTALL_SUPERVISOR_AMBIGUOUS'
    } finally {
        if (Test-Path -LiteralPath $install) { Remove-Item -LiteralPath $install -Recurse -Force }
    }
}

$results += Invoke-CcodTest 'installer exposes a CodexRemote-fix desktop entry that only starts the stable tray bootstrap' {
    $installerScript = Join-Path $repositoryRoot 'build\CodexControlOtherDevices.iss'
    $entries = @(Get-Content -LiteralPath $installerScript | Where-Object { $_ -cmatch '^Name: "\{userdesktop\}\\' })
    Assert-CcodEqual 1 $entries.Count 'installer defines exactly one desktop entry'
    $entry = [string]$entries[0]
    Assert-CcodTrue ($entry -cmatch 'Name: "\{userdesktop\}\\CodexRemote-fix"') 'desktop entry has the public product name'
    Assert-CcodTrue ($entry -cmatch 'Filename: "\{sys\}\\WindowsPowerShell\\v1\.0\\powershell\.exe"') 'desktop entry uses the Windows PowerShell host'
    Assert-CcodTrue ($entry -cmatch '-WindowStyle Hidden') 'desktop entry hides the bootstrap host window'
    Assert-CcodTrue ($entry -cmatch '\{localappdata\}\\CodexControlOtherDevices\\bootstrap\.ps1') 'desktop entry targets the stable bootstrap'
    Assert-CcodTrue ($entry -cmatch '-InstallRoot ""\{localappdata\}\\CodexControlOtherDevices""') 'desktop entry supplies the stable install root'
    Assert-CcodTrue ($entry -cmatch 'IconFilename: "\{app\}\\assets\\CodexRemote-fix\.ico"') 'desktop entry uses the public product icon'
    Assert-CcodTrue ($entry -cnotmatch 'Start-CodexControlOtherDevices\.ps1') 'desktop entry never invokes a direct repair session'
}

$results += Invoke-CcodTest 'installer exposes CodexRemote-fix as the searchable primary bootstrap entry' {
    $installerScript = Join-Path $repositoryRoot 'build\CodexControlOtherDevices.iss'
    $content = Get-Content -LiteralPath $installerScript -Raw
    $lines = @(Get-Content -LiteralPath $installerScript)

    Assert-CcodTrue ($lines -ccontains 'AppId={{2B9E9F2E-7A32-4A7E-9C1D-9F5B5C6D7E8F}') 'installer retains the v2.1.6 AppId for in-place upgrades'
    Assert-CcodTrue ($lines -ccontains 'AppName=CodexRemote-fix') 'installed app has the public CodexRemote-fix name'
    Assert-CcodTrue ($lines -ccontains 'AppVerName=CodexRemote-fix {#ProjectVersion}') 'installed app version has the public CodexRemote-fix name'
    Assert-CcodTrue ($lines -ccontains 'DefaultGroupName=CodexRemote-fix') 'current-user Start menu group has the public CodexRemote-fix name'
    Assert-CcodTrue ($lines -ccontains 'SetupIconFile=..\assets\codexremote-fix\codexremote-fix.ico') 'setup uses the CodexRemote-fix icon'
    Assert-CcodTrue ($lines -ccontains 'UninstallDisplayIcon={app}\assets\CodexRemote-fix.ico') 'Apps and Features uses the installed CodexRemote-fix icon'
    Assert-CcodTrue ($lines -ccontains 'OutputBaseFilename=CodexRemote-fix-{#ProjectVersion}-setup') 'build output uses the public release name'
    Assert-CcodEqual 2 @($lines | Where-Object { $_ -match '^Name: "\{(group|userdesktop)\}\\CodexRemote-fix";.*bootstrap\.ps1"".*-EntryMode Explicit' }).Count 'Start menu and desktop shortcuts enter bootstrap Explicit mode'
    Assert-CcodTrue ($content -cmatch 'Activate-CcodRemoteFix\.ps1') 'installer delegates upgrades to the durable activation worker instead of relying on uninstall metadata'

    $primaryEntries = @($content -split "`r?`n" | Where-Object { $_ -cmatch '^Name: "\{(group|userdesktop)\}\\CodexRemote-fix";' })
    Assert-CcodEqual 2 $primaryEntries.Count 'Start menu and desktop each expose one primary CodexRemote-fix entry'
    foreach ($entry in $primaryEntries) {
        Assert-CcodTrue ($entry -cmatch 'Filename: "\{sys\}\\WindowsPowerShell\\v1\.0\\powershell\.exe"') 'primary entry uses the PowerShell host'
        Assert-CcodTrue ($entry -cmatch '\{localappdata\}\\CodexControlOtherDevices\\bootstrap\.ps1') 'primary entry invokes the verified stable bootstrap'
        Assert-CcodTrue ($entry -cmatch '-InstallRoot ""\{localappdata\}\\CodexControlOtherDevices""') 'primary entry supplies the stable legacy install root'
        Assert-CcodTrue ($entry -cmatch 'IconFilename: "\{app\}\\assets\\CodexRemote-fix\.ico"') 'primary entry uses the public product icon'
        Assert-CcodTrue ($entry -cnotmatch 'README\.md') 'primary entry never opens documentation'
    }

    $buildScript = Get-Content -LiteralPath (Join-Path $repositoryRoot 'build\build.ps1') -Raw
    Assert-CcodTrue ($buildScript -cmatch 'CodexRemote-fix-\$Version-setup\.exe') 'build script locates the public setup filename'
    Assert-CcodTrue ($buildScript -cmatch 'CodexRemote-fix-\$Version-setup\.exe\.sha256\.txt') 'build script writes a hash beside the public setup filename'
}

$results += Invoke-CcodTest 'installer publishes the exact CodexRemote-fix 2.5.5 release artifacts' {
    $package = Get-Content -LiteralPath (Join-Path $repositoryRoot 'package.json') -Raw | ConvertFrom-Json
    Assert-CcodEqual '2.5.5' ([string]$package.version) 'package version is exactly 2.5.5'

    $installerScript = Get-Content -LiteralPath (Join-Path $repositoryRoot 'build\CodexControlOtherDevices.iss') -Raw
    $outputBase = [regex]::Match($installerScript, '(?m)^OutputBaseFilename=(.+)$').Groups[1].Value.Trim()
    $setupName = ($outputBase -replace '\{#ProjectVersion\}', [string]$package.version) + '.exe'
    Assert-CcodEqual 'CodexRemote-fix-2.5.5-setup.exe' $setupName 'Inno output resolves to the exact public setup filename'

    $buildScript = Get-Content -LiteralPath (Join-Path $repositoryRoot 'build\build.ps1') -Raw
    $checksumTemplate = [regex]::Match($buildScript, 'Join-Path \$dist \("([^"]+\.sha256\.txt)"\)').Groups[1].Value
    $checksumName = $checksumTemplate.Replace('$Version', [string]$package.version)
    Assert-CcodEqual 'CodexRemote-fix-2.5.5-setup.exe.sha256.txt' $checksumName 'build script resolves to the exact public checksum filename'
}

# Production mutation caught: allowing raw activation JSON to authorize Ready/Failed, checking the deadline after terminal processing, prompting without a strict validator child exit, or synchronously waiting on an unbounded validator.
$results += Invoke-CcodTest 'installer treats raw activation receipts as progress and prompts only from a bounded strict validator child exit' {
    $installerScript = Get-Content -LiteralPath (Join-Path $repositoryRoot 'build\CodexControlOtherDevices.iss') -Raw -Encoding UTF8
    $activationWorker = Get-Content -LiteralPath (Join-Path $repositoryRoot 'Activate-CcodRemoteFix.ps1') -Raw -Encoding UTF8
    $activationScript = Join-Path $repositoryRoot 'Activate-CcodRemoteFix.ps1'
    $promptScript = Join-Path $repositoryRoot 'Prompt-CcodRestart.ps1'
    Assert-CcodTrue (Test-Path -LiteralPath $activationScript -PathType Leaf) 'post-install activation worker exists'
    Assert-CcodTrue (Test-Path -LiteralPath $promptScript -PathType Leaf) 'post-install Codex restart prompt exists'
    Assert-CcodTrue ($installerScript -cmatch '(?m)^CloseApplications=no\r?$') 'installer never lets Restart Manager close Codex'
    Assert-CcodTrue ($installerScript -cmatch 'Activate-CcodRemoteFix\.ps1') 'installer bundles the activation worker'
    Assert-CcodTrue ($installerScript -cmatch 'GetTickCount64@kernel32\.dll stdcall' -and $installerScript -cmatch 'ACTIVATION_TIMEOUT_MILLISECONDS\s*=\s*[1-9][0-9]*') 'installer uses a fixed monotonic activation deadline'
    Assert-CcodTrue ($installerScript -cmatch '(?s)RefuseStaleActivationReceipt\(ReceiptPath\).*DeadlineTick\s*:=\s*GetTickCount64\(\)\s*\+\s*ACTIVATION_TIMEOUT_MILLISECONDS.*Activate-CcodRemoteFix\.ps1.*ewNoWait') 'installer clears the stale receipt and fixes the deadline before activation launch'
    $pollLoop = [regex]::Match($installerScript, '(?s)while True do\s*begin(.*?)Sleep\(ACTIVATION_POLL_MILLISECONDS\);\s*end;')
    Assert-CcodTrue $pollLoop.Success 'installer has one bounded activation polling loop'
    $deadlineOffset = $pollLoop.Groups[1].Value.IndexOf('if GetTickCount64() >= DeadlineTick')
    $progressOffset = $pollLoop.Groups[1].Value.IndexOf('ReadActivationProgressPhase(ReceiptPath, ActivationId)')
    $validationOffset = $pollLoop.Groups[1].Value.IndexOf('-ValidateReceiptWithTimeout')
    Assert-CcodTrue ($deadlineOffset -ge 0 -and $progressOffset -gt $deadlineOffset -and $validationOffset -gt $deadlineOffset) 'deadline is checked before raw or validated terminal state can be processed'
    Assert-CcodTrue ($installerScript -cmatch '(?s)if \(Phase in \[apReady, apFailed\]\).*?-ValidateReceiptWithTimeout.*-ValidationTimeoutMilliseconds.*ewWaitUntilTerminated, ValidationResultCode.*case ValidationResultCode of') 'a possible raw terminal invokes one bounded strict validator and interprets only its direct exit code'
    Assert-CcodTrue ($installerScript -cmatch 'UpdateActivationPresentation' -and $installerScript -cmatch 'ProgressGauge\.Position') 'installer maps durable phases to visible status and progress'
    $progressReader=[regex]::Match($installerScript,'(?s)function ReadActivationProgressPhase\(.*?\nend;')
    Assert-CcodTrue ($progressReader.Success -and $progressReader.Groups[0].Value-cnotmatch 'ProgressGauge\.Position\s*:=\s*100|Prompt-CcodRestart|ewWaitUntilTerminated') 'raw activation receipt parsing is progress-only and has no terminal authority'
    $readyBranch=[regex]::Match($installerScript,'(?s)\s+0:\s*begin(.*?)\s+end;\s+2:')
    $failedBranch=[regex]::Match($installerScript,'(?s)\s+2:\s*begin(.*?)\s+end;\s+else')
    $retryBranch=[regex]::Match($installerScript,'(?s)\s+else\s+begin(.*?)\s+end;\s+end;\s+end;\s+WizardForm\.Update')
    Assert-CcodTrue ($readyBranch.Success -and $readyBranch.Groups[1].Value-cmatch'ProgressGauge\.Position\s*:=\s*100' -and $readyBranch.Groups[1].Value-cmatch'Prompt-CcodRestart\.ps1') 'only strict validator exit zero reaches completion and prompting'
    Assert-CcodTrue ($failedBranch.Success -and $failedBranch.Groups[1].Value-cmatch'RaiseException' -and $installerScript-cmatch'CodexRemote-fix activation timed out') 'strict Failed and timeout states fail closed'
    Assert-CcodTrue ($installerScript -cnotmatch '(?s)Activate-CcodRemoteFix\.ps1[^;]*-Prompt') 'background activation worker never owns the prompt'
    Assert-CcodTrue ($failedBranch.Groups[1].Value-cnotmatch'ProgressGauge\.Position\s*:=\s*100|Prompt-CcodRestart' -and $retryBranch.Success -and $retryBranch.Groups[1].Value-cmatch'NextValidationAttemptTick') 'no non-Ready validator result displays completed progress or prompts and invalid reads retry'
    Assert-CcodTrue ($activationWorker -cmatch '(?s)if \(\$ValidateReceiptOnly\).*Read-CcodTerminalActivationReceipt.*phase -ceq .Ready.*exit 0.*phase -ceq .Failed.*exit 2' -and $activationWorker -cnotmatch 'ValidationResultPath|ValidationId|Start-Sleep') 'inner validator is a one-shot strict receipt reader with only direct terminal exit codes'
    Assert-CcodTrue ($activationWorker -cmatch '(?s)function Invoke-CcodBoundedReceiptValidator.*WaitForExit\(\$TimeoutMilliseconds\).*\.Kill\(\).*return 3' -and $activationWorker -cmatch '(?s)if \(\$ValidateReceiptWithTimeout\).*Invoke-CcodBoundedReceiptValidator.*exit \$validationResult') 'outer validator owns a finite child wait and reduces timeout to a fail-closed direct exit'
    Assert-CcodTrue ($installerScript -cnotmatch 'ValidationResultPath|ReadValidationResultState|post-install-activation\.validation') 'Inno never accepts a file sidecar as validator authority'
    Assert-CcodTrue ($installerScript -cnotmatch 'Prepare-CcodRemoteUpgrade\.ps1') 'installer does not pre-stop the supervisor outside the gated runtime activation transaction'
    Assert-CcodTrue ($installerScript -cnotmatch '(?ms)^\[Run\]\s*\r?\nFilename: "powershell\.exe"; Parameters: ".*Install-CodexControlOtherDevices\.ps1') 'installer does not silently ignore its runtime installer exit code through a Run entry'
}

# Production mutation caught: treating ewNoWait ResultCode as a PID, reopening an unrelated process, accepting a raw receipt or unauthenticated sidecar as a terminal result, or blocking indefinitely on validator completion.
$results += Invoke-CcodTest 'installer uses launch-only ewNoWait and accepts terminal status only from its bounded strict validator child' {
    $installerScript = Get-Content -LiteralPath (Join-Path $repositoryRoot 'build\CodexControlOtherDevices.iss') -Raw -Encoding UTF8
    Assert-CcodTrue ($installerScript -cmatch 'CoCreateGuid@ole32\.dll' -and $installerScript -cmatch 'StringFromGUID2@ole32\.dll') 'installer generates a canonical activation GUID before worker launch'
    Assert-CcodTrue ($installerScript -cmatch '(?s)ActivationId\s*:=\s*NewActivationId\(\).*ReceiptPath\s*:=.*RefuseStaleActivationReceipt\(ReceiptPath\).*Activate-CcodRemoteFix\.ps1.*-ActivationId\s+"' ) 'installer removes or refuses the stale receipt and passes its own activation id to the worker'
    Assert-CcodTrue ($installerScript -cmatch 'ewNoWait, LaunchResultCode' -and $installerScript -cmatch 'SysErrorMessage\(LaunchResultCode\)' -and $installerScript -cmatch 'ewWaitUntilTerminated, ValidationResultCode' -and $installerScript -cmatch '-ValidateReceiptWithTimeout' -and $installerScript -cmatch 'VALIDATION_TIMEOUT_MILLISECONDS') 'ewNoWait ResultCode is used only as a launch diagnostic while the bounded validator exit code is read only after wait'
    foreach($forbidden in @('OpenProcess@kernel32.dll','WaitForSingleObject@kernel32.dll','GetExitCodeProcess@kernel32.dll','PROCESS_QUERY_INFORMATION','ProcessHandle := OpenProcess')){Assert-CcodTrue ($installerScript -cnotmatch [regex]::Escape($forbidden)) "installer never uses $forbidden to infer worker identity"}
    Assert-CcodTrue ($installerScript -cmatch '(?s)if \(Phase in \[apReady, apFailed\]\).*?VALIDATION_LAUNCH_BUDGET_MILLISECONDS.*?-ValidateReceiptWithTimeout.*-ValidationTimeoutMilliseconds.*ewWaitUntilTerminated, ValidationResultCode.*if GetTickCount64\(\) >= DeadlineTick.*case ValidationResultCode of') 'Inno reserves a finite validator budget, checks the deadline again, and branches on the bounded direct exit code'
    Assert-CcodTrue ($installerScript -cmatch 'VALIDATION_RETRY_MILLISECONDS' -and $installerScript -cmatch 'NextValidationAttemptTick\s*:=\s*GetTickCount64\(\)\s*\+\s*VALIDATION_RETRY_MILLISECONDS') 'nonterminal validator outcomes yield to the UI before a bounded retry'
    Assert-CcodTrue ($installerScript -cmatch '(?s)function IsSafeActivationFile.*ExtractFileDir.*DirectoryAttributes.*RootAttributes.*FILE_ATTRIBUTE_REPARSE_POINT') 'Inno rejects reparse-point state ancestors even for raw presentation reads'
    Assert-CcodTrue ($installerScript -cnotmatch 'ValidationResultPath|ReadValidationResultState|post-install-activation\.validation') 'no writable sidecar can impersonate the strict validator'
    $readyBranch=[regex]::Match($installerScript,'(?s)\s+0:\s*begin(.*?)\s+end;\s+2:')
    $failedBranch=[regex]::Match($installerScript,'(?s)\s+2:\s*begin(.*?)\s+end;\s+else')
    Assert-CcodTrue ($readyBranch.Groups[1].Value-cmatch'Prompt-CcodRestart\.ps1' -and $failedBranch.Groups[1].Value-cnotmatch'Prompt-CcodRestart\.ps1') 'only strict Ready exit zero reaches the restart prompt'
}

# Production mutation caught: compiling a script with an unrecognized built-in identifier, or leaving the bounded validator route uncompiled.
$results += Invoke-CcodTest 'installer compiles the bounded activation route with the configured Inno Setup compiler' {
    $isccCandidates = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
        (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe')
    )
    $iscc = @($isccCandidates | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and [IO.File]::Exists($_) }) | Select-Object -First 1
    Assert-CcodTrue ($null -ne $iscc) 'Inno Setup 6 compiler is required for the installer contract gate'
    $outputRoot = Join-Path ([IO.Path]::GetTempPath()) ('ccod-inno-contract-' + [guid]::NewGuid().ToString('N'))
    try {
        [IO.Directory]::CreateDirectory($outputRoot) | Out-Null
        $package = Get-Content -LiteralPath (Join-Path $repositoryRoot 'package.json') -Raw | ConvertFrom-Json
        $trayHostRoot = Join-Path $outputRoot 'trayhost-fixture'
        [IO.Directory]::CreateDirectory($trayHostRoot) | Out-Null
        foreach ($leaf in @('CodexRemote.TrayHost.exe','CodexRemote.TrayHost.exe.config','trayhost-build-provenance.json')) {
            [IO.File]::WriteAllText((Join-Path $trayHostRoot $leaf), "Inno compile fixture: $leaf`n", [Text.UTF8Encoding]::new($false))
        }
        $compileOutput = @(& $iscc "/DProjectVersion=$([string]$package.version)" "/DTrayHostArtifactDirectory=$trayHostRoot" "/O$outputRoot\" (Join-Path $repositoryRoot 'build\CodexControlOtherDevices.iss') 2>&1)
        Assert-CcodEqual 0 $LASTEXITCODE "Inno compiles the bounded activation route: $($compileOutput -join ' ')"
        Assert-CcodTrue (Test-Path -LiteralPath (Join-Path $outputRoot "CodexRemote-fix-$([string]$package.version)-setup.exe") -PathType Leaf) 'Inno contract compilation produces the expected installer artifact'
    } finally {
        if (Test-Path -LiteralPath $outputRoot) { Remove-Item -LiteralPath $outputRoot -Recurse -Force }
    }
}

$results += Invoke-CcodTest 'activation terminal validator enforces the complete bounded correlated receipt contract' {
    # Production mutation caught: accepting reordered/extra fields, truthy booleans, stale ids, malformed runtime/error semantics, noncanonical times, or oversized JSON.
    $root=Join-Path ([IO.Path]::GetTempPath()) ('ccod-activation-validator-'+[guid]::NewGuid().ToString('N'))
    $reparseTarget=Join-Path ([IO.Path]::GetTempPath()) ('ccod-activation-validator-target-'+[guid]::NewGuid().ToString('N'))
    try{
        [IO.Directory]::CreateDirectory((Join-Path $root 'state'))|Out-Null
        $activationId='77777777-6666-5555-4444-333333333333';$receiptPath=Join-Path $root 'state\post-install-activation.json';$stderrPath=Join-Path $root 'validator.err'
        $valid=[ordered]@{schemaVersion=1;activationId=$activationId;phase='Ready';runtimeId='runtime-new';previousRuntimeId='runtime-old';startedAtUtc='2030-02-03T04:05:06.0000000Z';updatedAtUtc='2030-02-03T04:05:07.0000000Z';ready=$true;errorCode=$null}
        $cases=@(
            [pscustomobject]@{Name='Ready';Exit=0;Mutate={param($r)}},
            [pscustomobject]@{Name='Failed';Exit=2;Mutate={param($r)$r.phase='Failed';$r.ready=$false;$r.errorCode='CCOD_INSTALL_FAILED'}},
            [pscustomobject]@{Name='stale id';Exit=3;Mutate={param($r)$r.activationId='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'}},
            [pscustomobject]@{Name='truthy ready';Exit=3;Mutate={param($r)$r.ready='true'}},
            [pscustomobject]@{Name='invalid runtime';Exit=3;Mutate={param($r)$r.runtimeId='..\ATTACKER_STDOUT_MARKER'}},
            [pscustomobject]@{Name='Ready with error';Exit=3;Mutate={param($r)$r.errorCode='CCOD_ATTACKER_STDOUT_MARKER'}},
            [pscustomobject]@{Name='nonterminal phase';Exit=3;Mutate={param($r)$r.phase='StartingProtection';$r.ready=$false}},
            [pscustomobject]@{Name='noncanonical time';Exit=3;Mutate={param($r)$r.updatedAtUtc='2030-02-03T04:05:07Z'}},
            [pscustomobject]@{Name='extra field';Exit=3;Mutate={param($r)$r.attacker='ATTACKER_STDOUT_MARKER'}}
        )
        foreach($case in $cases){
            $receipt=[ordered]@{};foreach($key in $valid.Keys){$receipt[$key]=$valid[$key]};&$case.Mutate $receipt
            [IO.File]::WriteAllText($receiptPath,($receipt|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
            if(Test-Path -LiteralPath $stderrPath){Remove-Item -LiteralPath $stderrPath -Force}
            $stdout=@(& (Join-Path $repositoryRoot 'Activate-CcodRemoteFix.ps1') -AppRoot $repositoryRoot -InstallRoot $root -ActivationId $activationId -ValidateReceiptOnly 2>$stderrPath)
            Assert-CcodEqual $case.Exit $LASTEXITCODE "$($case.Name) maps to the strict validator exit contract"
            Assert-CcodEqual 0 $stdout.Count "$($case.Name) emits no receipt data to stdout"
            if($case.Exit-ne0-and$case.Exit-ne2){Assert-CcodTrue ((Get-Content -LiteralPath $stderrPath -Raw)-cmatch'CCOD_ACTIVATION_RECEIPT_') "$($case.Name) retains a bounded support code on stderr"}
        }
        [IO.File]::WriteAllText($receiptPath,'{"schemaVersion":1,"activationId":"77777777-6666-5555-4444-333333333333","phase":"Ready","runtimeId":"runtime-new"',[Text.UTF8Encoding]::new($false))
        $stdout=@(& (Join-Path $repositoryRoot 'Activate-CcodRemoteFix.ps1') -AppRoot $repositoryRoot -InstallRoot $root -ActivationId $activationId -ValidateReceiptOnly 2>$stderrPath)
        Assert-CcodEqual 3 $LASTEXITCODE 'truncated Ready JSON is rejected by the executable validator'
        Assert-CcodEqual 0 $stdout.Count 'truncated Ready JSON emits no receipt data to stdout'
        [IO.File]::WriteAllText($receiptPath,('{'+'"padding":"'+('x'*17000)+'"}'),[Text.UTF8Encoding]::new($false))
        $stdout=@(& (Join-Path $repositoryRoot 'Activate-CcodRemoteFix.ps1') -AppRoot $repositoryRoot -InstallRoot $root -ActivationId $activationId -ValidateReceiptOnly 2>$stderrPath)
        Assert-CcodEqual 3 $LASTEXITCODE 'oversized receipt is refused before JSON parsing'
        Assert-CcodEqual 0 $stdout.Count 'oversized receipt emits no data to stdout'
        Remove-Item -LiteralPath (Join-Path $root 'state') -Recurse -Force
        [IO.Directory]::CreateDirectory($reparseTarget)|Out-Null
        [IO.File]::WriteAllText((Join-Path $reparseTarget 'post-install-activation.json'),($valid|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
        New-Item -ItemType Junction -Path (Join-Path $root 'state') -Target $reparseTarget|Out-Null
        $stdout=@(& (Join-Path $repositoryRoot 'Activate-CcodRemoteFix.ps1') -AppRoot $repositoryRoot -InstallRoot $root -ActivationId $activationId -ValidateReceiptOnly 2>$stderrPath)
        Assert-CcodEqual 3 $LASTEXITCODE 'receipt beneath a reparse-point parent is refused before parsing'
        Assert-CcodEqual 0 $stdout.Count 'reparse-parent refusal emits no receipt data to stdout'
        Assert-CcodTrue ((Get-Content -LiteralPath $stderrPath -Raw)-cmatch'CCOD_ACTIVATION_RECEIPT_') 'reparse-parent refusal retains a bounded receipt support code'
    }finally{
        $statePath=Join-Path $root 'state'
        if(Test-Path -LiteralPath $statePath){$stateItem=Get-Item -LiteralPath $statePath -Force;if(($stateItem.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){[IO.Directory]::Delete($statePath)}}
        if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}
        if(Test-Path -LiteralPath $reparseTarget){Remove-Item -LiteralPath $reparseTarget -Recurse -Force}
    }
}

# Production mutation caught: letting a hung strict-validator child extend installer activation indefinitely, or translating a bounded direct child result through a writable side channel.
$results += Invoke-CcodTest 'activation validator watchdog preserves direct terminal exits and bounds a slow child' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-activation-watchdog-' + [guid]::NewGuid().ToString('N'))
    try {
        [IO.Directory]::CreateDirectory((Join-Path $root 'state')) | Out-Null
        $activationId = '88888888-7777-6666-5555-444444444444'
        $receiptPath = Join-Path $root 'state\post-install-activation.json'
        $stderrPath = Join-Path $root 'watchdog.err'
        $activationScript = Join-Path $repositoryRoot 'Activate-CcodRemoteFix.ps1'
        $ready = [ordered]@{schemaVersion=1;activationId=$activationId;phase='Ready';runtimeId='runtime-watchdog';previousRuntimeId=$null;startedAtUtc='2030-02-03T04:05:06.0000000Z';updatedAtUtc='2030-02-03T04:05:07.0000000Z';ready=$true;errorCode=$null}
        [IO.File]::WriteAllText($receiptPath,($ready | ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))

        $stdout = @(& $activationScript -AppRoot $repositoryRoot -InstallRoot $root -ActivationId $activationId -ValidateReceiptWithTimeout -ValidationTimeoutMilliseconds 10000 2>$stderrPath)
        Assert-CcodEqual 0 $LASTEXITCODE 'watchdog returns the strict Ready child exit directly'
        Assert-CcodEqual 0 $stdout.Count 'watchdog Ready path emits no receipt data to stdout'

        $failed = [ordered]@{}; foreach ($key in $ready.Keys) { $failed[$key] = $ready[$key] }; $failed.phase = 'Failed'; $failed.ready = $false; $failed.errorCode = 'CCOD_INSTALL_FAILED'
        [IO.File]::WriteAllText($receiptPath,($failed | ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
        $stdout = @(& $activationScript -AppRoot $repositoryRoot -InstallRoot $root -ActivationId $activationId -ValidateReceiptWithTimeout -ValidationTimeoutMilliseconds 10000 2>$stderrPath)
        Assert-CcodEqual 2 $LASTEXITCODE 'watchdog returns the strict Failed child exit directly'
        Assert-CcodEqual 0 $stdout.Count 'watchdog Failed path emits no receipt data to stdout'

        [IO.File]::WriteAllText($receiptPath,($ready | ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
        $stopwatch = [Diagnostics.Stopwatch]::StartNew()
        try {
            $stdout = @(& $activationScript -AppRoot $repositoryRoot -InstallRoot $root -ActivationId $activationId -ValidateReceiptWithTimeout -ValidationTimeoutMilliseconds 1 2>$stderrPath)
            $elapsedMilliseconds = [long]$stopwatch.ElapsedMilliseconds
        } finally {
            $stopwatch.Stop()
        }
        Assert-CcodEqual 3 $LASTEXITCODE 'watchdog fails closed when its strict child cannot finish before the finite deadline'
        Assert-CcodEqual 0 $stdout.Count 'watchdog timeout emits no receipt data to stdout'
        Assert-CcodTrue ($elapsedMilliseconds -lt 5000) 'watchdog returns within a bounded launch-and-kill interval instead of inheriting a stuck child wait'
        Assert-CcodTrue ((Get-Content -LiteralPath $stderrPath -Raw) -cmatch 'CCOD_ACTIVATION_VALIDATOR_TIMEOUT') 'watchdog timeout retains a stable fail-closed support code'
    } finally {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

$results += Invoke-CcodTest 'pre-upgrade supervisor stopper exits cleanly when no old runtime is present' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-upgrade-no-old-' + [guid]::NewGuid().ToString('N'))
    try {
        $output = @(& (Join-Path $repositoryRoot 'Prepare-CcodRemoteUpgrade.ps1') -InstallRoot $root 2>&1)
        Assert-CcodEqual 0 $LASTEXITCODE 'pre-upgrade helper no-op exits successfully without an installed supervisor'
    } finally {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

$results += Invoke-CcodTest 'post-install restart prompt does nothing when the user chooses later' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-restart-prompt-later-' + [guid]::NewGuid().ToString('N'))
    try {
        $output = @(& (Join-Path $repositoryRoot 'Prompt-CcodRestart.ps1') -AppRoot $repositoryRoot -InstallRoot $root -Choice Later 2>&1)
        Assert-CcodEqual 0 $LASTEXITCODE 'later choice exits successfully'
        Assert-CcodTrue (($output -join "`n") -notmatch '(?i)Start-CodexControlOtherDevices') 'later choice does not launch the restart wrapper'
    } finally {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

$results += Invoke-CcodTest 'activation worker installs first and prompts only after a successful runtime activation' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-activation-worker-' + [guid]::NewGuid().ToString('N'))
    try {
        [IO.Directory]::CreateDirectory((Join-Path $root 'state')) | Out-Null
        $marker = Join-Path $root 'marker.txt'
        $installScript = Join-Path $root 'Install-CodexControlOtherDevices.ps1'
        $promptScript = Join-Path $root 'Prompt-CcodRestart.ps1'
        $installSource = "param([string]`$InstallRoot,[string]`$ActivationId,[switch]`$EnableCandidateCompatibleUpdates);[IO.File]::AppendAllText('$marker','install,',[Text.UTF8Encoding]::new(`$false));`$r=[ordered]@{schemaVersion=1;activationId=`$ActivationId;phase='Ready';runtimeId='runtime-new';previousRuntimeId=`$null;startedAtUtc='2030-02-03T04:05:06.0000000Z';updatedAtUtc='2030-02-03T04:05:07.0000000Z';ready=`$true;errorCode=`$null};[IO.File]::WriteAllText((Join-Path `$InstallRoot 'state\post-install-activation.json'),(`$r|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new(`$false));exit 0"
        [IO.File]::WriteAllText($installScript, $installSource, [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($promptScript, "param([string]`$AppRoot,[string]`$InstallRoot,[string]`$ActivationId,[switch]`$NoUi);[IO.File]::AppendAllText('$marker','prompt',[Text.UTF8Encoding]::new(`$false)); exit 0", [Text.UTF8Encoding]::new($false))
        $output = @(& (Join-Path $repositoryRoot 'Activate-CcodRemoteFix.ps1') -AppRoot $root -InstallRoot $root -Prompt 2>&1)
        Assert-CcodEqual 0 $LASTEXITCODE 'activation worker exits successfully after the runtime activation and prompt complete'
        Assert-CcodEqual 'install,prompt' ([IO.File]::ReadAllText($marker, [Text.UTF8Encoding]::new($false))) 'activation worker prompts only after the installer succeeds'
        Assert-CcodTrue (Test-Path -LiteralPath (Join-Path $root 'logs\post-install-activation.log') -PathType Leaf) 'activation worker writes a durable activation result'
    } finally {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

$results += Invoke-CcodTest 'activation worker preserves an activated runtime when optional restart confirmation fails' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-activation-restart-warning-' + [guid]::NewGuid().ToString('N'))
    try {
        [IO.Directory]::CreateDirectory((Join-Path $root 'state')) | Out-Null
        $marker = Join-Path $root 'marker.txt'
        $installScript = Join-Path $root 'Install-CodexControlOtherDevices.ps1'
        $promptScript = Join-Path $root 'Prompt-CcodRestart.ps1'
        $installSource = "param([string]`$InstallRoot,[string]`$ActivationId,[switch]`$EnableCandidateCompatibleUpdates);[IO.File]::AppendAllText('$marker','install,',[Text.UTF8Encoding]::new(`$false));`$r=[ordered]@{schemaVersion=1;activationId=`$ActivationId;phase='Ready';runtimeId='runtime-new';previousRuntimeId=`$null;startedAtUtc='2030-02-03T04:05:06.0000000Z';updatedAtUtc='2030-02-03T04:05:07.0000000Z';ready=`$true;errorCode=`$null};[IO.File]::WriteAllText((Join-Path `$InstallRoot 'state\post-install-activation.json'),(`$r|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new(`$false));exit 0"
        [IO.File]::WriteAllText($installScript, $installSource, [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($promptScript, "param([string]`$AppRoot,[string]`$InstallRoot,[string]`$ActivationId,[switch]`$NoUi);[IO.File]::AppendAllText('$marker','prompt',[Text.UTF8Encoding]::new(`$false)); exit 1", [Text.UTF8Encoding]::new($false))
        $output = @(& (Join-Path $repositoryRoot 'Activate-CcodRemoteFix.ps1') -AppRoot $root -InstallRoot $root -Prompt -NoUi 2>&1)
        Assert-CcodEqual 0 $LASTEXITCODE 'restart confirmation failure does not invalidate a completed runtime activation'
        Assert-CcodEqual 'install,prompt' ([IO.File]::ReadAllText($marker, [Text.UTF8Encoding]::new($false))) 'restart is attempted only after activation succeeds'
        $activationLog = Get-Content -LiteralPath (Join-Path $root 'logs\post-install-activation.log') -Raw
        Assert-CcodTrue ($activationLog -match '"code":"RUNTIME_ACTIVATED"') 'activation log preserves the completed runtime activation record'
        Assert-CcodTrue ($activationLog -match '"code":"RESTART_UNCONFIRMED"') 'activation log records restart confirmation separately'
        Assert-CcodTrue ($activationLog -notmatch '"code":"FAILED"') 'restart confirmation failure is not mislabeled as runtime activation failure'
    } finally {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# Production mutation caught: treating installer exit zero or any nonterminal receipt as completed activation and prompting before strict Ready.
$results += Invoke-CcodTest 'activation worker requires a strict Ready receipt before prompting' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-activation-nonterminal-' + [guid]::NewGuid().ToString('N'))
    try {
        [IO.Directory]::CreateDirectory((Join-Path $root 'state')) | Out-Null
        $marker = Join-Path $root 'prompt-marker.txt'
        $installScript = Join-Path $root 'Install-CodexControlOtherDevices.ps1'
        $promptScript = Join-Path $root 'Prompt-CcodRestart.ps1'
        $installSource = @"
param([string]`$InstallRoot,[string]`$ActivationId,[switch]`$EnableCandidateCompatibleUpdates)
`$receipt=[ordered]@{schemaVersion=1;activationId=`$ActivationId;phase='StartingProtection';runtimeId='runtime-new';previousRuntimeId='runtime-old';startedAtUtc='2030-02-03T04:05:06.0000000Z';updatedAtUtc='2030-02-03T04:05:07.0000000Z';ready=`$false;errorCode=`$null}
[IO.File]::WriteAllText((Join-Path `$InstallRoot 'state\post-install-activation.json'),(`$receipt|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new(`$false))
exit 0
"@
        [IO.File]::WriteAllText($installScript,$installSource,[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($promptScript,"[IO.File]::WriteAllText('$marker','prompted');exit 0",[Text.UTF8Encoding]::new($false))
        $activationId='77777777-6666-5555-4444-333333333333'
        $output=@(& (Join-Path $repositoryRoot 'Activate-CcodRemoteFix.ps1') -AppRoot $root -InstallRoot $root -ActivationId $activationId -Prompt -NoUi 2>&1)
        Assert-CcodEqual 1 $LASTEXITCODE 'nonterminal activation receipt fails closed'
        Assert-CcodTrue (-not(Test-Path -LiteralPath $marker)) 'restart prompt never runs before Ready'
        $log=Get-Content -LiteralPath (Join-Path $root 'logs\post-install-activation.log') -Raw
        Assert-CcodTrue ($log-cmatch'CCOD_ACTIVATION_RECEIPT_NOT_READY') 'activation log retains the stable non-ready code'
        Assert-CcodTrue ($log-cmatch[regex]::Escape($activationId)) 'activation log correlates the activation id'
    } finally {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

$results += Invoke-CcodTest 'post-install restart prompt is always English' {
    $output = @(& (Join-Path $repositoryRoot 'Prompt-CcodRestart.ps1') -AppRoot $repositoryRoot -Preview 2>&1)
    Assert-CcodEqual 0 $LASTEXITCODE 'English prompt preview exits successfully'
    $text = $output -join "`n"
    Assert-CcodTrue ($text -notmatch '\\u[0-9a-fA-F]{4}') 'English prompt never exposes Unicode escape literals'
    Assert-CcodTrue ($text -match '(?i)Codex must be restarted' -and $text -match '(?i)Restart Codex now') 'prompt contains English restart text'
    Assert-CcodTrue ($text -notmatch '[\p{IsCJKUnifiedIdeographs}]') 'installer prompt contains no CJK text'
}

$results += Invoke-CcodTest 'CodexRemote-fix icon is a bounded multi-resolution PNG ICO' {
    $iconPath = Join-Path $repositoryRoot 'assets\codexremote-fix\codexremote-fix.ico'
    Assert-CcodTrue (Test-Path -LiteralPath $iconPath -PathType Leaf) 'public product ICO exists'
    $bytes = [IO.File]::ReadAllBytes($iconPath)
    Assert-CcodTrue ($bytes.Length -ge 22) 'ICO contains a header, directory, and image bytes'
    Assert-CcodEqual 0 ([BitConverter]::ToUInt16($bytes, 0)) 'ICO reserved header is zero'
    Assert-CcodEqual 1 ([BitConverter]::ToUInt16($bytes, 2)) 'ICO header identifies an icon'

    $imageCount = [int][BitConverter]::ToUInt16($bytes, 4)
    Assert-CcodTrue ($imageCount -ge 1 -and $imageCount -le 256) 'ICO directory count is nonzero and bounded'
    $directoryEnd = 6 + (16 * $imageCount)
    Assert-CcodTrue ($directoryEnd -le $bytes.Length) 'ICO directory fits inside the file'

    $sizes = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $ranges = [Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $imageCount; $index++) {
        $entry = 6 + (16 * $index)
        $width = if ($bytes[$entry] -eq 0) { 256 } else { [int]$bytes[$entry] }
        $height = if ($bytes[$entry + 1] -eq 0) { 256 } else { [int]$bytes[$entry + 1] }
        $imageBytes = [uint64][BitConverter]::ToUInt32($bytes, $entry + 8)
        $imageOffset = [uint64][BitConverter]::ToUInt32($bytes, $entry + 12)
        $imageEnd = $imageOffset + $imageBytes

        Assert-CcodEqual 0 ([int]$bytes[$entry + 3]) "ICO entry $index reserved byte is zero"
        Assert-CcodEqual 1 ([int][BitConverter]::ToUInt16($bytes, $entry + 4)) "ICO entry $index has one image plane"
        Assert-CcodEqual 32 ([int][BitConverter]::ToUInt16($bytes, $entry + 6)) "ICO entry $index is 32-bit"
        Assert-CcodTrue ($width -ge 1 -and $width -le 256 -and $height -ge 1 -and $height -le 256) "ICO entry $index dimensions are in range"
        Assert-CcodTrue ($imageBytes -gt 24) "ICO entry $index has a usable image payload"
        Assert-CcodTrue ($imageOffset -ge $directoryEnd -and $imageEnd -le $bytes.Length) "ICO entry $index image range is inside the file"

        $pngSignature = @(137, 80, 78, 71, 13, 10, 26, 10)
        $isPng = $true
        for ($signatureIndex = 0; $signatureIndex -lt $pngSignature.Count; $signatureIndex++) {
            if ($bytes[[int]$imageOffset + $signatureIndex] -ne $pngSignature[$signatureIndex]) {
                $isPng = $false
                break
            }
        }
        Assert-CcodTrue $isPng "ICO entry $index is a PNG image"

        $pngWidth = ([uint32]$bytes[[int]$imageOffset + 16] * 16777216) + ([uint32]$bytes[[int]$imageOffset + 17] * 65536) + ([uint32]$bytes[[int]$imageOffset + 18] * 256) + [uint32]$bytes[[int]$imageOffset + 19]
        $pngHeight = ([uint32]$bytes[[int]$imageOffset + 20] * 16777216) + ([uint32]$bytes[[int]$imageOffset + 21] * 65536) + ([uint32]$bytes[[int]$imageOffset + 22] * 256) + [uint32]$bytes[[int]$imageOffset + 23]
        Assert-CcodEqual $width ([int]$pngWidth) "ICO entry $index directory width matches PNG IHDR"
        Assert-CcodEqual $height ([int]$pngHeight) "ICO entry $index directory height matches PNG IHDR"
        $null = $sizes.Add("${width}x${height}")
        $ranges.Add([pscustomobject]@{ Start = $imageOffset; End = $imageEnd })
    }

    $orderedRanges = @($ranges | Sort-Object Start, End)
    for ($index = 1; $index -lt $orderedRanges.Count; $index++) {
        Assert-CcodTrue ($orderedRanges[$index - 1].End -le $orderedRanges[$index].Start) "ICO image range $index does not overlap its predecessor"
    }
    foreach ($requiredSize in @('16x16', '32x32', '48x48', '256x256')) {
        Assert-CcodTrue ($sizes.Contains($requiredSize)) "ICO contains required $requiredSize image"
    }
}

$results += Invoke-CcodTest 'setup uninstall Start menu and desktop use one installed CodexRemote-fix icon' {
    $installerScript = Join-Path $repositoryRoot 'build\CodexControlOtherDevices.iss'
    $lines = @(Get-Content -LiteralPath $installerScript)
    $installedIcon = '{app}\assets\CodexRemote-fix.ico'
    Assert-CcodTrue ($lines -ccontains 'SetupIconFile=..\assets\codexremote-fix\codexremote-fix.ico') 'setup uses the source product icon'
    Assert-CcodTrue ($lines -ccontains "UninstallDisplayIcon=$installedIcon") 'uninstall registration uses the installed product icon'
    Assert-CcodTrue ($lines -ccontains 'Source: "..\assets\codexremote-fix\codexremote-fix.ico"; DestDir: "{app}\assets"; DestName: "CodexRemote-fix.ico"; Flags: ignoreversion') 'installer carries the source icon to the common installed icon path'
    Assert-CcodTrue ($lines -ccontains 'Source: "..\assets\codexremote-fix\codexremote-fix.ico"; DestDir: "{app}\assets\codexremote-fix"; Flags: ignoreversion') 'installer preserves the hermetic source icon path for installed validation'
    Assert-CcodTrue ($lines -ccontains 'Source: "..\.github\workflows\release.yml"; DestDir: "{app}\.github\workflows"; Flags: ignoreversion') 'installer carries the release workflow required by installed validation'

    $shortcutEntries = @($lines | Where-Object { $_ -cmatch '^Name: "\{(group|userdesktop)\}\\' })
    Assert-CcodTrue ($shortcutEntries.Count -ge 3) 'installer exposes Start menu and desktop shortcuts'
    foreach ($entry in $shortcutEntries) {
        Assert-CcodTrue ($entry -cmatch ('IconFilename: "' + [regex]::Escape($installedIcon) + '"')) 'every Start menu and desktop shortcut uses the common installed icon'
    }
}

$results += Invoke-CcodTest 'README and release workflow publish current installer-first branding' {
    $readme = Get-Content -LiteralPath (Join-Path $repositoryRoot 'README.md') -Raw -Encoding UTF8
    $readmeChinese = Get-Content -LiteralPath (Join-Path $repositoryRoot 'README.zh-CN.md') -Raw -Encoding UTF8
    Assert-CcodTrue ($readme -cmatch '\A(?s:<div align="center">.*?<h1>CodexRemote-fix</h1>)') 'default README uses the centered public English product heading'
    Assert-CcodTrue ($readmeChinese -cmatch '\A(?s:<div align="center">.*?<h1>CodexRemote-fix</h1>)') 'Chinese README uses the centered public product heading'

    $quickStart = [regex]::Match($readme, '(?ms)^## Quick start[^\r\n]*\r?\n(.*?)(?=^## )').Groups[1].Value
    Assert-CcodTrue ($quickStart -cmatch 'CodexRemote-fix-2\.5\.5-setup\.exe') 'English Quick Start names the exact setup artifact'
    Assert-CcodTrue ($quickStart -cmatch 'CodexRemote-fix-2\.5\.5-setup\.exe\.sha256\.txt') 'English Quick Start names the exact checksum artifact'
    Assert-CcodTrue ($quickStart -cnotmatch '(?i)powershell|Install-CodexControlOtherDevices') 'English Quick Start does not teach PowerShell installation'
    Assert-CcodTrue ($quickStart -cmatch '\*\*CodexRemote-fix\*\*') 'English Quick Start names the public desktop shortcut'

    $quickStartChineseMatch = [regex]::Match($readmeChinese, '(?ms)^## [^\r\n]+\r?\n(?:\r?\n)?(?=1\.[^\r\n]*\[Releases\])(.*?)(?=^## |\z)')
    Assert-CcodTrue $quickStartChineseMatch.Success 'Chinese README exposes a Quick Start section'
    $quickStartChinese = $quickStartChineseMatch.Groups[1].Value
    Assert-CcodTrue ($quickStartChinese -cmatch 'CodexRemote-fix-2\.5\.5-setup\.exe') 'Chinese Quick Start names the exact setup artifact'
    Assert-CcodTrue ($quickStartChinese -cmatch 'CodexRemote-fix-2\.5\.5-setup\.exe\.sha256\.txt') 'Chinese Quick Start names the exact checksum artifact'
    Assert-CcodTrue ($quickStartChinese -cnotmatch '(?i)powershell|Install-CodexControlOtherDevices') 'Chinese Quick Start does not teach PowerShell installation'
    Assert-CcodTrue ($quickStartChinese -cmatch '\*\*CodexRemote-fix\*\*') 'Chinese Quick Start names the public desktop shortcut'

    Assert-CcodTrue ($readme -cmatch '(?s)Windows Settings.{0,160}\*\*CodexRemote-fix\*\*') 'English uninstall instructions use the public product name'
    Assert-CcodTrue ($readmeChinese -cmatch '(?s)Windows .{0,100}\*\*CodexRemote-fix\*\*') 'Chinese uninstall instructions use the public product name'
    Assert-CcodTrue ($readme -cmatch 'Each release appends a short English change summary to the GitHub release body') 'README documents English-only GitHub release notes'
    Assert-CcodTrue ($readme -cnotmatch 'bilingual change summary to this README and to the GitHub release body') 'README does not promise bilingual GitHub release notes'

    $workflow = Get-Content -LiteralPath (Join-Path $repositoryRoot '.github\workflows\release.yml') -Raw -Encoding UTF8
    Assert-CcodTrue ($workflow -cmatch '(?m)^name: CodexRemote-fix release\r?$') 'release workflow uses public product branding'
    Assert-CcodTrue ($workflow -cmatch '(?m)^\s+name: CodexRemote-fix installer\r?$') 'uploaded artifact uses public product branding'
    Assert-CcodTrue ($workflow -cmatch '--title "CodexRemote-fix \$version"') 'GitHub release title uses public product branding'
    Assert-CcodTrue ($workflow -cmatch 'englishSection = \[regex\]::Match') 'GitHub release notes extract the English changelog section only'
    Assert-CcodTrue ($workflow -cmatch 'has no English release section') 'release fails clearly when the English changelog section is missing'
}

$results += Invoke-CcodTest 'installer carries the Inno contract needed by its self-validation' {
    $installerScript = Join-Path $repositoryRoot 'build\CodexControlOtherDevices.iss'
    $sourceEntries = @(Get-Content -LiteralPath $installerScript | Where-Object { $_ -cmatch '^Source: "\.\.\\build\\CodexControlOtherDevices\.iss"; DestDir: "\{app\}\\build";' })
    Assert-CcodEqual 1 $sourceEntries.Count 'installer carries the build contract used by Validate.ps1'
}

$results += Invoke-CcodTest 'installer migrates only its exact legacy shortcuts to the public Start menu group' {
    $installerScript = Join-Path $repositoryRoot 'build\CodexControlOtherDevices.iss'
    $lines = @(Get-Content -LiteralPath $installerScript -Encoding UTF8)
    $content = Get-Content -LiteralPath $installerScript -Raw -Encoding UTF8
    Assert-CcodTrue ($lines -ccontains 'UsePreviousGroup=no') 'upgrade ignores the stored legacy Inno icon group'

    $sectionMatch = [regex]::Match($content, '(?ms)^\[InstallDelete\]\r?\n(.*?)(?=^\[|\z)')
    Assert-CcodTrue $sectionMatch.Success 'installer defines an exact legacy-shortcut cleanup section'
    $deleteLines = @($sectionMatch.Groups[1].Value -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $legacyGroup = '{userprograms}\Codex Control other devices'
    foreach ($shortcut in @(
        'Codex Control other devices for Windows.lnk',
        'Open the tray supervisor.lnk',
        'Compatibility check.lnk',
        'Uninstall Codex Control other devices.lnk',
        'CodexRemote-fix.lnk',
        'CodexRemote-fix compatibility check.lnk',
        'Uninstall CodexRemote-fix.lnk'
    )) {
        Assert-CcodTrue ($deleteLines -ccontains "Type: files; Name: `"$legacyGroup\$shortcut`"") "upgrade deletes only the exact legacy Start menu shortcut $shortcut"
    }
    Assert-CcodTrue ($deleteLines -ccontains "Type: dirifempty; Name: `"$legacyGroup`"") 'upgrade removes the legacy Start menu group only when empty'

    $legacyDesktopShortcut = 'Codex ' + [char]0x8BBE + [char]0x5907 + [char]0x8FDE + [char]0x63A5 + ' (Device Connection).lnk'
    Assert-CcodTrue ($deleteLines -ccontains "Type: files; Name: `"{userdesktop}\$legacyDesktopShortcut`"") 'upgrade deletes the exact legacy desktop shortcut'
    Assert-CcodTrue ($sectionMatch.Groups[1].Value -cnotmatch '(?im)^\s*Type:\s*filesandordirs') 'migration never recursively deletes the legacy group'
    Assert-CcodTrue ($sectionMatch.Groups[1].Value -cnotmatch '[*?]') 'migration never uses wildcard deletion'
}

$results += Invoke-CcodTest 'installer carries build.ps1 so installed self-validation is hermetic' {
    $installerScript = Join-Path $repositoryRoot 'build\CodexControlOtherDevices.iss'
    $sourceEntries = @(Get-Content -LiteralPath $installerScript | Where-Object { $_ -cmatch '^Source: "\.\.\\build\\build\.ps1"; DestDir: "\{app\}\\build";' })
    Assert-CcodEqual 1 $sourceEntries.Count 'installer carries build.ps1 required by Validate.ps1'
}

Write-Output "Install lifecycle self-tests passed: $($results.Count)"
