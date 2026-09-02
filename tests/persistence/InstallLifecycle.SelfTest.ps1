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
    [IO.File]::WriteAllText((Join-Path $Root 'src\persistence\bootstrap.ps1'), ("# Stable bootstrap fixture" + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $Root 'src\persistence\PortableUninstallFinalizer.ps1'), ("# Portable finalizer fixture" + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $Root 'src\persistence\InstalledUninstallFinalizer.ps1'), ("# Installed finalizer fixture" + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    foreach ($module in @('PersistenceIO.psm1', 'RuntimeManifest.psm1', 'CompatibilityProbe.psm1', 'ProcessControl.psm1', 'StateStore.psm1', 'TransitionJournal.psm1', 'SessionEngine.psm1', 'SupervisorEngine.psm1', 'KernelObjects.psm1', 'TrayUi.psm1', 'UiLocalization.psm1', 'UiPreferences.psm1', 'ScheduledTask.psm1', 'PortableRelease.psm1')) {
        [IO.File]::WriteAllText((Join-Path $Root "src\persistence\modules\$module"), "# $module`r`n", [Text.UTF8Encoding]::new($false))
    }
    [IO.File]::WriteAllText((Join-Path $Root 'src\persistence\resources\ui.en-US.json'), '{"schemaVersion":1,"language":"en-US"}', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $Root 'src\persistence\resources\ui.zh-CN.json'), '{"schemaVersion":1,"language":"zh-CN"}', [Text.UTF8Encoding]::new($false))
    foreach ($trayHostFile in @('CodexRemote.TrayHost.exe', 'CodexRemote.TrayHost.exe.config', 'trayhost-build-provenance.json')) {
        [IO.File]::WriteAllText((Join-Path $Root "bin\$trayHostFile"), "fixture $trayHostFile`r`n", [Text.UTF8Encoding]::new($false))
    }
    foreach ($portableFile in @('CodexRemote.Portable.exe', 'CodexRemote.Portable.exe.config', 'portable-launcher-provenance.json')) {
        [IO.File]::WriteAllText((Join-Path $Root "bin\$portableFile"), "fixture $portableFile`r`n", [Text.UTF8Encoding]::new($false))
    }
    return $Root
}

function New-CcodLifecyclePayloadManifest {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Version
    )

    $module = Get-Module InstallLifecycle
    $sourceFiles = @(& $module { param($SourceRoot) Get-CcodLifecycleSourceFiles -SourceRoot $SourceRoot -RequireTrayHost } $Root)
    $recordList = [Collections.Generic.List[object]]::new()
    foreach ($sourceFile in $sourceFiles) {
        $recordList.Add([pscustomobject][ordered]@{
            path = ([string]$sourceFile.Relative).Replace('\','/')
            length = [int64](Get-Item -LiteralPath $sourceFile.Source -Force).Length
            sha256 = (Get-FileHash -LiteralPath $sourceFile.Source -Algorithm SHA256).Hash.ToLowerInvariant()
        })
    }
    $comparison = [System.Comparison[object]]{ param($left,$right) [StringComparer]::Ordinal.Compare([string]$left.path,[string]$right.path) }
    $recordList.Sort($comparison)
    $records = @($recordList)
    $manifestPath = Join-Path $Root 'installer-payload.manifest.json'
    [IO.File]::WriteAllText(
        $manifestPath,
        ([ordered]@{ schemaVersion = 1; projectVersion = $Version; files = $records } | ConvertTo-Json -Depth 8),
        [Text.UTF8Encoding]::new($false)
    )
    return $manifestPath
}

function Get-CcodLifecyclePayloadBinding {
    param(
        [Parameter(Mandatory)][string]$ManifestPath,
        [Parameter(Mandatory)][string]$ExpectedVersion
    )
    $bytes = [IO.File]::ReadAllBytes($ManifestPath)
    return @{
        ExpectedVersion = $ExpectedVersion
        PayloadManifestPath = $ManifestPath
        ExpectedPayloadManifestSha256 = Get-CcodTestFileSha256 -Path $ManifestPath
        PayloadManifestBytesBase64 = [Convert]::ToBase64String($bytes)
    }
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
        TaskRuntimeIds = [Collections.Generic.List[string]]::new()
        ProductRegistrationCalls = 0
        ProductRegistrationFailure = $false
        ProductRegistrationReadyObserved = $false
    }
    $adapters = @{}
    $adapters.ValidateSource = { param($SourceRoot) $world.Calls.Add("Validate:$([IO.Path]::GetFileName($SourceRoot))"); [bool]$world.ValidateSource }.GetNewClosure()
    $adapters.GetProjectVersion = { param($SourceRoot) (Get-Content -LiteralPath (Join-Path $SourceRoot 'package.json') -Raw | ConvertFrom-Json).version }.GetNewClosure()
    $adapters.DiscoverNodeCandidates = { $world.Calls.Add('DiscoverNode'); @($world.NodePath) }.GetNewClosure()
    $adapters.ValidateNodeCandidate = { param($Path) $world.Calls.Add("ValidateNode:$([IO.Path]::GetFileName($Path))"); $Path -ceq $world.NodePath }.GetNewClosure()
    $adapters.GetCurrentIdentity = { $world.Calls.Add('Identity'); $world.Identity }.GetNewClosure()
    $adapters.UtcNow = { $world.Calls.Add('Now'); $world.NowUtc }.GetNewClosure()
    $adapters.NewActivationId = { [guid]::NewGuid().ToString('D') }.GetNewClosure()
    $adapters.WriteActivationReceipt = {
        param($InstallRoot, $Receipt, $FileTransaction)
        $world.Phases.Add([string]$Receipt.phase)
        if ($null -ne $FileTransaction) {
            $module = Get-Module -Name InstallLifecycle -ErrorAction Stop
            & $module { param($Root,$Value,$Transaction) Write-CcodActivationReceiptFile -InstallRoot $Root -Receipt $Value -FileTransaction $Transaction } $InstallRoot $Receipt $FileTransaction
        } else {
            $stateRoot = Join-Path $InstallRoot 'state'
            [IO.Directory]::CreateDirectory($stateRoot) | Out-Null
            [IO.File]::WriteAllText((Join-Path $stateRoot 'post-install-activation.json'), ($Receipt | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
        }
    }.GetNewClosure()
    $adapters.ReadActiveLifecycleRequest = { param($StateRoot) $world.Calls.Add('ReadActiveLifecycleRequest');$world.ActiveLifecycleRequest }.GetNewClosure()
    $adapters.WaitNewRuntimeReady = {
        param($InstallRoot, $RuntimeId, $RuntimeGeneration, $Identity, $TaskStartedAtUtc, $TimeoutMilliseconds)
        [pscustomobject][ordered]@{ SupervisorReady = [bool]$world.NewSupervisorReady; TrayReady = [bool]$world.NewTrayReady }
    }.GetNewClosure()
    $adapters.InstallSupervisorTask = { param($InstallRoot, $UserSid, $RuntimeId) $world.Calls.Add("InstallTask:$([IO.Path]::GetFileName($InstallRoot)):${UserSid}:$RuntimeId"); $world.TaskRuntimeIds.Add([string]$RuntimeId); $world.TaskInstalled++ }.GetNewClosure()
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
        param($InstallRoot, $RuntimeId, $Ownership, $TargetGeneration, $FileTransaction)
        if ($null -ne $world.SetActiveFailure) { & $world.SetActiveFailure $InstallRoot $RuntimeId $Ownership $TargetGeneration $FileTransaction }
        $assertFence = { param($Root, $Receipt, $ExpectActivePointer,$TargetRuntimeId) if ($Receipt.released) { throw 'released lifecycle owner' }; $true }
        Set-CcodActiveRuntime -InstallRoot $InstallRoot -NewRuntimeId $RuntimeId -TargetGeneration $TargetGeneration -FileTransaction $FileTransaction -Ownership $Ownership -Adapters @{ AssertLifecycleFence=$assertFence }
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
    $adapters.RegisterProduct = {
        param($InstallRoot,$RuntimeId,$Version,$PackageSha256,$FileTransaction,$TransactionRecord)
        $world.Calls.Add("RegisterProduct:$RuntimeId")
        $world.ProductRegistrationCalls++
        $world.ProductRegistrationReadyObserved = $null -ne $TransactionRecord -and $TransactionRecord.phase -ceq 'Ready'
        if ($world.ProductRegistrationFailure) { throw [Management.Automation.ErrorRecord]::new([InvalidOperationException]::new('fixture registration failed'),'CCOD_PRODUCT_REGISTRATION_FAILED',[Management.Automation.ErrorCategory]::InvalidData,$RuntimeId) }
        [pscustomobject]@{ verified=$true; legacyRemoved=$true }
    }.GetNewClosure()
    $adapters.AddProductShortcutCandidates = { param($Files) [pscustomobject]@{Files=@($Files);TemporaryRoot=$null} }
    [pscustomobject]@{ World = $world; Adapters = $adapters }
}

function New-CcodLifecycleProductSideEffectAdapters {
    param([Parameter(Mandatory)][hashtable]$State)
    @{
        WriteProductRegistration={param($Registration,$ReadyEvidence)if($State.FailWrites){throw 'TEST_PRODUCT_WRITE_FAILURE'};$State.Registration=$Registration;$State.ReadyEvidence=$ReadyEvidence;$State.Writes++}.GetNewClosure()
        ReadProductRegistration={param($Registration)$State.Registration}.GetNewClosure()
        WriteShortcut={
            param($Kind,$Shortcut,$FileTransaction,$ReadyEvidence)
            $relative='registration/'+$(if($Kind-ceq'StartMenu'){'StartMenu.CodexRemote-fix.lnk'}else{'Desktop.CodexRemote-fix.lnk'})
            try{$fileModule=Get-Module -All|Where-Object{$null-ne$_.Path-and[IO.Path]::GetFileName($_.Path)-ceq'InstallFileTransaction.psm1'}|Select-Object -First 1;if($null-eq$fileModule){throw 'install file transaction module unavailable'};$source=&$fileModule {param($Generation,$Path,$Record)Open-CcodInstallRetainedFile -Generation $Generation -RelativePath $Path -ReadyTransaction $Record} $FileTransaction $relative $ReadyEvidence.transactionRecord}catch{$State.RetainedError=([string]$_.FullyQualifiedErrorId-split',')[0];throw}
            if($null-eq$source){throw 'retained shortcut capability missing'}
            $State.ProductOnlyObserved=$true;$State.Shortcuts[$Kind]=$Shortcut;$State.ShortcutWrites++
        }.GetNewClosure()
        ReadShortcut={param($Kind,$Shortcut)$State.Shortcuts[$Kind]}.GetNewClosure()
        ReadVerifiedRegistration={ [pscustomobject]@{verified=$true} }
        ReadLegacyRegistration={param($ExpectedAppId)$null}
    }
}

function Set-CcodLifecycleDefaultProductRegistrationFixture {
    param([Parameter(Mandatory)]$Fake,[Parameter(Mandatory)][hashtable]$ProductState)
    [void]$Fake.Adapters.Remove('RegisterProduct')
    $sideEffects=New-CcodLifecycleProductSideEffectAdapters -State $ProductState
    $Fake.Adapters.GetProductRegistrationAdapters={$sideEffects}.GetNewClosure()
    $Fake.Adapters.AddProductShortcutCandidates={
        param($Files)
        $temporaryRoot=Join-Path ([IO.Path]::GetTempPath()) ('ccod-lifecycle-product-'+[guid]::NewGuid().ToString('N'));[IO.Directory]::CreateDirectory($temporaryRoot)|Out-Null
        $records=[Collections.Generic.List[object]]::new()
        foreach($leaf in @('StartMenu.CodexRemote-fix.lnk','Desktop.CodexRemote-fix.lnk')){$path=Join-Path $temporaryRoot $leaf;[IO.File]::WriteAllText($path,"sealed $leaf",[Text.UTF8Encoding]::new($false));$item=Get-Item -LiteralPath $path;$sha=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant();$records.Add([pscustomobject]@{Relative=('registration/'+$leaf);Source=$path;ExpectedLength=[int64]$item.Length;ExpectedSha256=$sha})}
        [pscustomobject]@{Files=@($Files)+@($records);TemporaryRoot=$temporaryRoot}
    }
}

function Set-CcodLifecycleProductCloseFailureFixture {
    param([Parameter(Mandatory)]$Fake,[Parameter(Mandatory)][hashtable]$State)
    $State.CloseAttempts=0
    if(-not$State.ContainsKey('CloseFailuresRemaining')){$State.CloseFailuresRemaining=1}
    $Fake.Adapters.CloseProductTransaction={
        param($Transaction,$DefaultClose)
        $State.CloseAttempts++
        if($State.CloseAttempts-le[int]$State.CloseFailuresRemaining){throw [Management.Automation.ErrorRecord]::new([InvalidOperationException]::new('fixture owned product close failed'),'CCOD_INSTALL_CLOSE_FAILED',[Management.Automation.ErrorCategory]::CloseError,$Transaction)}
        &$DefaultClose $Transaction
    }.GetNewClosure()
}

function Set-CcodLifecycleLowerProductCloseFixture {
    param([Parameter(Mandatory)][hashtable]$State)
    $modulePath=Join-Path $repositoryRoot 'src\persistence\modules\InstallFileTransaction.psm1'
    $fileModule=(Get-Command Close-CcodInstallFileTransaction -ErrorAction SilentlyContinue).Module
    if($null-ne$fileModule-and($null-eq$fileModule.Path-or[IO.Path]::GetFullPath($fileModule.Path)-cne[IO.Path]::GetFullPath($modulePath))){$fileModule=$null}
    if($null-eq$fileModule){$fileModule=Import-Module $modulePath -PassThru -DisableNameChecking -ErrorAction Stop}
    $State.Attempts=0
    $lowerClose={
        param($TransactionState,$DefaultClose)
        if(-not[bool]$TransactionState.ProductOnly){&$DefaultClose $TransactionState;return}
        $State.Attempts++
        if([int]$State.FailuresRemaining-gt0){$State.FailuresRemaining=[int]$State.FailuresRemaining-1;throw [IO.IOException]::new('injected lower native close failure')}
        &$DefaultClose $TransactionState
    }.GetNewClosure()
    &$fileModule {param($Close)$script:CcodInstallFileTransactionLowerCloseForTest=$Close} $lowerClose
    return $fileModule
}

function Clear-CcodLifecycleLowerProductCloseFixture {
    param($FileModule)
    if($null-ne$FileModule){&$FileModule {$script:CcodInstallFileTransactionLowerCloseForTest=$null}}
}

function Set-CcodLifecycleProductOpenFailureFixture {
    param([Parameter(Mandatory)][hashtable]$State)
    $modulePath=Join-Path $repositoryRoot 'src\persistence\modules\InstallFileTransaction.psm1'
    $fileModule=(Get-Command Close-CcodInstallFileTransaction -ErrorAction SilentlyContinue).Module
    if($null-ne$fileModule-and($null-eq$fileModule.Path-or[IO.Path]::GetFullPath($fileModule.Path)-cne[IO.Path]::GetFullPath($modulePath))){$fileModule=$null}
    if($null-eq$fileModule){$fileModule=Import-Module $modulePath -PassThru -DisableNameChecking -ErrorAction Stop}
    $State.Attempts=0
    $original=&$fileModule {(Get-Command Invoke-CcodRuntimeStatic -CommandType Function -ErrorAction Stop).ScriptBlock}
    $replacement={
        param([string]$Name,[object[]]$Arguments)
        if($Name-ceq'OpenProduct'){
            $State.Attempts++
            if([int]$State.FailuresRemaining-gt0){$State.FailuresRemaining=[int]$State.FailuresRemaining-1;throw [IO.IOException]::new('injected strict product open failure')}
        }
        &$original $Name $Arguments
    }.GetNewClosure()
    &$fileModule {param($Invoke)Set-Item -LiteralPath Function:\script:Invoke-CcodRuntimeStatic -Value $Invoke} $replacement
    return [pscustomobject]@{Module=$fileModule;Original=$original}
}

function Clear-CcodLifecycleProductOpenFailureFixture {
    param($Fixture)
    if($null-ne$Fixture){&$Fixture.Module {param($Invoke)Set-Item -LiteralPath Function:\script:Invoke-CcodRuntimeStatic -Value $Invoke} $Fixture.Original}
}

function Get-CcodLifecycleProductCleanupTestRecords {
    param([Parameter(Mandatory)][string]$InstallRoot)
    $directory=Join-Path $InstallRoot 'state\product-cleanup-fences'
    if(-not[IO.Directory]::Exists($directory)){return @()}
    $records=[Collections.Generic.List[object]]::new()
    foreach($file in @(Get-ChildItem -LiteralPath $directory -File -Force|Sort-Object Name)){
        if($file.Name-cnotmatch'^(?<attempt>\d{20})\.(?<state>Pending|Completed)\.(?<transaction>[0-9a-f-]{36})\.json$'){throw "unexpected cleanup fence leaf $($file.Name)"}
        $records.Add([pscustomobject]@{Attempt=[uint64]$Matches.attempt;State=[string]$Matches.state;Leaf=$file.Name;Record=((Get-Content -LiteralPath $file.FullName -Raw)|ConvertFrom-Json)})
    }
    return @($records|Sort-Object Attempt,@{Expression={if($_.State-ceq'Pending'){0}else{1}}})
}

function Get-CcodLifecycleCurrentProductCleanupTestIdentity {
    $process=[Diagnostics.Process]::GetCurrentProcess();$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    try{return [pscustomobject][ordered]@{pid=[int]$process.Id;creationTimeUtc=$process.StartTime.ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture);userSid=[string]$identity.User.Value}}
    finally{$process.Dispose();$identity.Dispose()}
}

function Assert-CcodLifecycleProductCleanupTestRecord {
    param([Parameter(Mandatory)]$Actual,[Parameter(Mandatory)]$Ready,[Parameter(Mandatory)]$Owner,[Parameter(Mandatory)][ValidateSet('Pending','Completed')][string]$State)
    $fields=@('schemaVersion','transactionId','runtimeId','runtimeGeneration','manifestSha256','packageSha256','ownerPid','ownerCreationTimeUtc','ownerSid','state')
    Assert-CcodEqual ($fields-join '|') (@($Actual.PSObject.Properties.Name)-join '|') 'cleanup fence contains only the ordered contract fields'
    Assert-CcodEqual 1 $Actual.schemaVersion 'cleanup fence schema is exact'
    Assert-CcodEqual $Ready.transactionId $Actual.transactionId 'cleanup fence binds the Ready transaction id'
    Assert-CcodEqual $Ready.newRuntimeId $Actual.runtimeId 'cleanup fence binds the selected runtime id'
    Assert-CcodEqual ([uint64]$Ready.newGeneration) ([uint64]$Actual.runtimeGeneration) 'cleanup fence binds the selected generation'
    Assert-CcodEqual $Ready.newManifestSha256 $Actual.manifestSha256 'cleanup fence binds the manifest hash'
    Assert-CcodEqual $Ready.sealedPackageSha256 $Actual.packageSha256 'cleanup fence binds the package hash'
    Assert-CcodEqual ([int]$Owner.pid) ([int]$Actual.ownerPid) 'cleanup fence binds the owner pid'
    Assert-CcodEqual $Owner.creationTimeUtc $Actual.ownerCreationTimeUtc 'cleanup fence binds the owner creation time'
    Assert-CcodEqual $Owner.userSid $Actual.ownerSid 'cleanup fence binds the owner SID'
    Assert-CcodEqual $State $Actual.state 'cleanup fence state is exact'
}

function Invoke-CcodLifecycleOtherProcessProductReconciliation {
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$NodePath,
        [Parameter(Mandatory)][string]$PackageSha256,
        [Parameter(Mandatory)][string]$MarkerRoot
    )
    [IO.Directory]::CreateDirectory($MarkerRoot)|Out-Null
    $payload=[ordered]@{
        lifecycleModule=$installLifecycleModule
        kernelModule=(Join-Path $repositoryRoot 'src\persistence\modules\KernelObjects.psm1')
        sourceRoot=$SourceRoot
        installRoot=$InstallRoot
        nodePath=$NodePath
        packageSha256=$PackageSha256
        markerRoot=$MarkerRoot
    }
    $payloadBase64=[Convert]::ToBase64String([Text.UTF8Encoding]::new($false).GetBytes(($payload|ConvertTo-Json -Compress)))
    $childScript=@'
$ErrorActionPreference='Stop'
$payloadJson=[Text.UTF8Encoding]::new($false,$true).GetString([Convert]::FromBase64String('__PAYLOAD__'))
$payload=$payloadJson|ConvertFrom-Json -ErrorAction Stop
Import-Module $payload.lifecycleModule -Force -DisableNameChecking -ErrorAction Stop
$kernelModule=Import-Module $payload.kernelModule -PassThru -DisableNameChecking -ErrorAction Stop
$childState=@{Registration=$null;Shortcuts=@{}}
$productAdapters=@{
    WriteProductRegistration={param($Registration,$ReadyEvidence)$childState.Registration=$Registration;[IO.File]::WriteAllText((Join-Path $payload.markerRoot 'product-write.txt'),'registration')}.GetNewClosure()
    ReadProductRegistration={param($Registration)$childState.Registration}.GetNewClosure()
    WriteShortcut={param($Kind,$Shortcut,$FileTransaction,$ReadyEvidence)$childState.Shortcuts[$Kind]=$Shortcut;[IO.File]::WriteAllText((Join-Path $payload.markerRoot 'shortcut-write.txt'),[string]$Kind)}.GetNewClosure()
    ReadShortcut={param($Kind,$Shortcut)$childState.Shortcuts[$Kind]}.GetNewClosure()
    ReadVerifiedRegistration={[pscustomobject]@{verified=$true}}
    ReadLegacyRegistration={param($ExpectedAppId)$null}
}
$process=[Diagnostics.Process]::GetCurrentProcess();$windowsIdentity=[Security.Principal.WindowsIdentity]::GetCurrent()
try{$childIdentity=[pscustomobject][ordered]@{UserSid=[string]$windowsIdentity.User.Value;SessionId=[int]$process.SessionId;Pid=[int]$process.Id;CreationTimeUtc=$process.StartTime.ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture)}}finally{$process.Dispose();$windowsIdentity.Dispose()}
$adapters=@{
    ValidateSource={param($Root)$true}
    GetProjectVersion={param($Root)'2.5.22'}
    DiscoverNodeCandidates={@([string]$payload.nodePath)}.GetNewClosure()
    ValidateNodeCandidate={param($Path)$true}
    GetCurrentIdentity={$childIdentity}.GetNewClosure()
    AddProductShortcutCandidates={param($Files)[pscustomobject]@{Files=@($Files);TemporaryRoot=$null}}
    GetProductRegistrationAdapters={$productAdapters}.GetNewClosure()
    CloseProductTransaction={param($Transaction,$DefaultClose)[IO.File]::WriteAllText((Join-Path $payload.markerRoot 'authority-opened.txt'),'close reached');&$DefaultClose $Transaction}.GetNewClosure()
}
$lease=$null;$exitCode=24
try{
    $lease=&$kernelModule {param($Sid)Enter-CcodMutex -Kind AccountTransition -UserSid $Sid -TimeoutMilliseconds 15000} $childIdentity.UserSid
    if($null-eq$lease-or$lease.Outcome-cne'Acquired'){throw 'child account mutex was not acquired'}
    [IO.File]::WriteAllText((Join-Path $payload.markerRoot 'mutex-acquired.txt'),'acquired')
    try{
        $result=Invoke-CcodInstall -SourceRoot ([string]$payload.sourceRoot) -InstallRoot ([string]$payload.installRoot) -SealedPackageSha256 ([string]$payload.packageSha256) -Adapters $adapters
        if($null-ne$result-and$result.ProductRegistrationVerified){[IO.File]::WriteAllText((Join-Path $payload.markerRoot 'verified.txt'),'verified')}
        $exitCode=0
    }catch{
        $errorId=([string]$_.FullyQualifiedErrorId-split',')[0]
        [IO.File]::WriteAllText((Join-Path $payload.markerRoot 'error-id.txt'),$errorId)
        $exitCode=if($errorId-ceq'CCOD_PRODUCT_REGISTRATION_FAILED'){23}else{24}
    }
}catch{
    [IO.File]::WriteAllText((Join-Path $payload.markerRoot 'child-failure.txt'),[string]$_)
    $exitCode=25
}finally{
    if($null-ne$lease-and$lease.Outcome-ceq'Acquired'-and-not$lease.Released){try{&$kernelModule {param($Value)Exit-CcodMutex -Lease $Value} $lease|Out-Null}catch{$exitCode=26}}
}
exit $exitCode
'@.Replace('__PAYLOAD__',$payloadBase64)
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childScript))
    $process=Start-Process -FilePath powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded) -PassThru -WindowStyle Hidden
    try{
        if(-not$process.WaitForExit(45000)){try{$process.Kill()}catch{};$process.WaitForExit();throw 'other-process product reconciliation timed out'}
        $exitCode=$process.ExitCode
    }finally{$process.Dispose()}
    $errorPath=Join-Path $MarkerRoot 'error-id.txt'
    return [pscustomobject]@{
        ExitCode=[int]$exitCode
        ErrorId=$(if([IO.File]::Exists($errorPath)){[IO.File]::ReadAllText($errorPath)}else{$null})
        MutexAcquired=[IO.File]::Exists((Join-Path $MarkerRoot 'mutex-acquired.txt'))
        AuthorityOpened=[IO.File]::Exists((Join-Path $MarkerRoot 'authority-opened.txt'))
        ProductWritten=[IO.File]::Exists((Join-Path $MarkerRoot 'product-write.txt'))-or[IO.File]::Exists((Join-Path $MarkerRoot 'shortcut-write.txt'))
        Verified=[IO.File]::Exists((Join-Path $MarkerRoot 'verified.txt'))
        ChildFailure=$(if([IO.File]::Exists((Join-Path $MarkerRoot 'child-failure.txt'))){[IO.File]::ReadAllText((Join-Path $MarkerRoot 'child-failure.txt'))}else{$null})
    }
}

function Invoke-CcodLifecycleDeadOwnerCleanupTest {
    $source=New-CcodLifecycleTempRoot;$install=New-CcodLifecycleTempRoot;$nodeRoot=New-CcodLifecycleTempRoot
    $fileModule=$null;$fake=$null
    try{
        New-CcodLifecycleSourceFixture -Root $source -Version '2.5.22'|Out-Null;$node=New-CcodLifecycleFakeNode -Root $nodeRoot;$fake=New-CcodLifecycleFake -NodePath $node
        $productState=@{FailWrites=$false;Registration=$null;ReadyEvidence=$null;RetainedError=$null;Writes=0;ShortcutWrites=0;ProductOnlyObserved=$false;Shortcuts=@{}};Set-CcodLifecycleDefaultProductRegistrationFixture -Fake $fake -ProductState $productState
        $fake.Adapters.RegisterProduct={param($InstallRoot,$RuntimeId,$Version,$PackageSha256,$FileTransaction,$TransactionRecord)[pscustomobject]@{verified=$true;legacyRemoved=$true}}
        $null=Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -SealedPackageSha256 ('b'*64) -Adapters $fake.Adapters
        $module=Get-Module InstallLifecycle -ErrorAction Stop;$ready=&$module {param($Root)Read-CcodInstallTransactionRecord -InstallRoot $Root} $install;$current=Get-CcodLifecycleCurrentProductCleanupTestIdentity
        $deadOwner=[pscustomobject][ordered]@{pid=[int]2147483647;creationTimeUtc='2000-01-01T00:00:00.0000000Z';userSid=$current.userSid}
        $outer=&$module {Enter-CcodLifecycleProductCleanupLease}
        try{&$module {param($Root,$Record,$Owner)[void](New-CcodLifecycleProductCleanupFence -InstallRoot $Root -ReadyTransaction $Record -OwnerIdentity $Owner)} $install $ready $deadOwner}
        finally{&$module {param($Context)[void](Exit-CcodLifecycleProductCleanupLease -Context $Context)} $outer}
        [void]$fake.Adapters.Remove('RegisterProduct')
        $lowerState=@{FailuresRemaining=0};$fileModule=Set-CcodLifecycleLowerProductCloseFixture -State $lowerState
        $result=Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -SealedPackageSha256 ('b'*64) -Adapters $fake.Adapters
        Assert-CcodEqual 'AlreadyInstalled' $result.Outcome 'dead-owner reconciliation resumes only the exact same-package Ready install'
        Assert-CcodTrue $result.ProductRegistrationVerified 'dead-owner reconciliation permits verified success only after cleanup'
        Assert-CcodEqual 2 $lowerState.Attempts 'dead owner requires a fresh strict cleanup close before the new verification close'
        $records=@(Get-CcodLifecycleProductCleanupTestRecords -InstallRoot $install)
        Assert-CcodEqual '1:Pending|1:Completed|2:Pending|2:Completed' (($records|ForEach-Object{"$($_.Attempt):$($_.State)"})-join '|') 'dead-owner recovery completes the old fence before a new verification fence'
        Assert-CcodEqual 0 @(Get-ChildItem -LiteralPath (Join-Path $install 'state\install-transactions') -Filter '*.Failed.*.json' -File).Count 'dead-owner cleanup appends no lifecycle Failed snapshot'
    }finally{
        Clear-CcodLifecycleLowerProductCloseFixture -FileModule $fileModule
        foreach($path in @($source,$install,$nodeRoot)){if(Test-Path $path){Remove-Item $path -Recurse -Force}}
    }
}

function New-CcodReadyFinalizationGapFixture {
    $source=New-CcodLifecycleTempRoot
    $install=New-CcodLifecycleTempRoot
    $nodeRoot=New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source -Version '2.5.22' | Out-Null
        $node=New-CcodLifecycleFakeNode -Root $nodeRoot
        $fake=New-CcodLifecycleFake -NodePath $node
        $fake.Adapters.CommitReadyTransaction={throw 'PRIVATE_FINAL_SNAPSHOT_FAILURE'}
        $failure=$null
        try { Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $fake.Adapters | Out-Null } catch { $failure=$_ }
        Assert-CcodTrue ($null-ne$failure-and$failure.FullyQualifiedErrorId-like'CCOD_INSTALL_READY_FINALIZATION_PENDING*') 'fixture reaches the exact Ready-finalization gap'
        $module=Get-Module InstallLifecycle -ErrorAction Stop
        $head=&$module {param($Root)Read-CcodInstallTransactionRecord -InstallRoot $Root} $install
        Assert-CcodEqual 'ProtectionReady' $head.phase 'fixture transaction is recoverable at ProtectionReady'
        return [pscustomobject]@{Source=$source;Install=$install;NodeRoot=$nodeRoot;Node=$node;Transaction=$head}
    } catch {
        foreach($path in @($source,$install,$nodeRoot)){if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Recurse -Force}}
        throw
    }
}

function Remove-CcodReadyFinalizationGapFixture {
    param([Parameter(Mandatory)]$Fixture)
    foreach($path in @($Fixture.Source,$Fixture.Install,$Fixture.NodeRoot)){if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Recurse -Force}}
}

function Read-CcodLifecycleActivePointer {
    param([Parameter(Mandatory)][string]$Root)
    return Read-CcodActiveRuntime -InstallRoot $Root
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

$results += Invoke-CcodTest 'immutable install records advance only through canonical create-only phase snapshots' {
    $install = New-CcodLifecycleTempRoot
    [IO.Directory]::CreateDirectory($install) | Out-Null
    $transactionId = '11111111-2222-3333-4444-555555555555'
    $packageSha256 = ('a' * 64)
    $module = Get-Module -Name InstallLifecycle -ErrorAction Stop
    $fileTransaction = & $module { param($Root) Open-CcodLifecycleInstallGeneration -InstallRoot $Root -RuntimeId 'runtime-new' } $install
    try {
        $record = & $module {
            param($Id,$PackageHash)
            New-CcodInstallTransactionRecord -TransactionId $Id -OldRuntimeId 'runtime-old' -OldGeneration ([uint64]7) -OldManifestSha256 ('1'*64) -NewRuntimeId 'runtime-new' -NewGeneration ([uint64]8) -NewManifestSha256 ('2'*64) -SealedPackageSha256 $PackageHash -OwnedObjectNames @('runtime-new','bootstrap.ps1','Uninstall-CodexControlOtherDevices.ps1')
        } $transactionId $packageSha256
        Assert-CcodEqual 'Prepared' $record.phase 'new immutable transaction begins Prepared'
        Assert-CcodEqual $null $record.errorCode 'nonterminal immutable transaction has no error code'
        & $module { param($Root,$Value,$Tx) Write-CcodInstallTransactionRecord -InstallRoot $Root -TransactionRecord $Value -FileTransaction $Tx } $install $record $fileTransaction
        foreach ($phase in @('PackageVerified','RuntimeStaged','PreviousProtectionStopped','RuntimePromoted','PointerCommitted','StableShellCommitted','ProtectionReady','Ready')) {
            $previous = [string]$record.phase
            $record = & $module { param($Root,$Id,$Expected,$Next,$Tx) Set-CcodInstallTransactionPhase -InstallRoot $Root -TransactionId $Id -ExpectedPhase $Expected -NewPhase $Next -FileTransaction $Tx } $install $transactionId $previous $phase $fileTransaction
            Assert-CcodEqual $phase $record.phase "immutable transaction advances to $phase"
        }
        $read = & $module { param($Root,$Id) Read-CcodInstallTransactionRecord -InstallRoot $Root -TransactionId $Id } $install $transactionId
        Assert-CcodEqual 'Ready' $read.phase 'reader selects the terminal canonical snapshot'
        Assert-CcodEqual $packageSha256 $read.sealedPackageSha256 'phase snapshots retain the sealed package identity'
        Assert-CcodThrows { & $module { param($Root,$Id,$Tx) Set-CcodInstallTransactionPhase -InstallRoot $Root -TransactionId $Id -ExpectedPhase 'RuntimeStaged' -NewPhase 'Ready' -FileTransaction $Tx } $install $transactionId $fileTransaction } 'CCOD_INSTALL_TRANSACTION_PHASE_INVALID'
    } finally {
        & $module { param($Tx) Close-CcodInstallFileTransaction -Transaction $Tx -Disposition Failed } $fileTransaction
        if (Test-Path -LiteralPath $install) { Remove-Item -LiteralPath $install -Recurse -Force }
    }
}

$results += Invoke-CcodTest 'same-version immutable install identity is idempotent only for the same sealed package hash' {
    $module = Get-Module -Name InstallLifecycle -ErrorAction Stop
    $existing = [pscustomobject][ordered]@{
        schemaVersion=1;transactionId='11111111-2222-3333-4444-555555555555';oldRuntimeId='runtime-old';oldGeneration=[uint64]7
        oldManifestSha256=('1'*64);newRuntimeId='runtime-new';newGeneration=[uint64]8;newManifestSha256=('2'*64);sealedPackageSha256=('b'*64);ownedObjectNames=@('runtime-new');phase='Ready';errorCode=$null
    }
    $same = & $module { param($Record,$Hash) Test-CcodInstallPackageIdentity -TransactionRecord $Record -ProjectVersion '2.5.22' -ActiveProjectVersion '2.5.22' -SealedPackageSha256 $Hash -ActiveRuntimeId 'runtime-new' -ActiveGeneration 8 } $existing ('b'*64)
    Assert-CcodEqual $true $same 'same version and same package hash is idempotent'
    Assert-CcodThrows { & $module { param($Record,$Hash) Test-CcodInstallPackageIdentity -TransactionRecord $Record -ProjectVersion '2.5.22' -ActiveProjectVersion '2.5.22' -SealedPackageSha256 $Hash -ActiveRuntimeId 'runtime-new' -ActiveGeneration 8 } $existing ('c'*64) } 'CCOD_INSTALL_PACKAGE_CONFLICT'
    $drift = & $module { param($Record) Test-CcodInstallPackageIdentity -TransactionRecord $Record -ProjectVersion '2.5.22' -ActiveProjectVersion '2.5.22' -SealedPackageSha256 ('b'*64) -ActiveRuntimeId 'runtime-other' -ActiveGeneration 9 } $existing
    Assert-CcodEqual $false $drift 'idempotence is bound to the active runtime and pointer generation'
    $legacy = & $module { Test-CcodInstallPackageIdentity -TransactionRecord $null -ProjectVersion '2.5.22' -ActiveProjectVersion '2.5.21' -SealedPackageSha256 ('d'*64) -ActiveRuntimeId 'legacy' -ActiveGeneration 1 }
    Assert-CcodEqual $false $legacy 'legacy install without transaction record is treated as non-idempotent Idle'
}

$results += Invoke-CcodTest 'Invoke-CcodInstall is idempotent only for the active Ready runtime and exact sealed package identity' {
    $source=New-CcodLifecycleTempRoot;$install=New-CcodLifecycleTempRoot;$nodeRoot=New-CcodLifecycleTempRoot
    try{
        New-CcodLifecycleSourceFixture -Root $source -Version '2.5.22'|Out-Null
        $nodePath=New-CcodLifecycleFakeNode -Root $nodeRoot
        $firstFake=New-CcodLifecycleFake -NodePath $nodePath
        $first=Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -SealedPackageSha256 ('a'*64) -Adapters $firstFake.Adapters
        $firstPointer=Read-CcodActiveRuntime -InstallRoot $install
        $sameFake=New-CcodLifecycleFake -NodePath $nodePath
        $same=Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -SealedPackageSha256 ('a'*64) -Adapters $sameFake.Adapters
        $samePointer=Read-CcodActiveRuntime -InstallRoot $install
        Assert-CcodEqual 'AlreadyInstalled' $same.Outcome 'same version and package identity returns an idempotent outcome'
        Assert-CcodEqual $first.RuntimeId $same.RuntimeId 'idempotence remains bound to the active runtime'
        Assert-CcodEqual $firstPointer.generation $samePointer.generation 'idempotence does not append a pointer generation'
        Assert-CcodEqual 1 @(Get-ChildItem -LiteralPath (Join-Path $install 'runtime') -Directory).Count 'idempotence creates no generation'
        Assert-CcodEqual 0 $sameFake.World.TaskInstalled 'idempotence performs no task mutation'
        Assert-CcodEqual 0 $sameFake.World.TaskStarted 'idempotence starts no process'
        Assert-CcodEqual 1 $sameFake.World.ProductRegistrationCalls 'AlreadyInstalled reconciles product registration after revalidating exact Ready identity'
        Assert-CcodTrue $same.ProductRegistrationVerified 'AlreadyInstalled reports a fresh verified registration reconciliation'
        $conflictFake=New-CcodLifecycleFake -NodePath $nodePath
        Assert-CcodThrows {Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -SealedPackageSha256 ('b'*64) -Adapters $conflictFake.Adapters|Out-Null} 'CCOD_INSTALL_PACKAGE_CONFLICT'
        $conflictPointer=Read-CcodActiveRuntime -InstallRoot $install
        Assert-CcodEqual $firstPointer.generation $conflictPointer.generation 'package conflict leaves the active pointer unchanged'
        Assert-CcodEqual $first.RuntimeId $conflictPointer.activeRuntime 'package conflict remains bound to the old active runtime'
        Assert-CcodEqual 1 @(Get-ChildItem -LiteralPath (Join-Path $install 'runtime') -Directory).Count 'package conflict creates no generation'
        Assert-CcodEqual 0 $conflictFake.World.TaskInstalled 'package conflict performs no task mutation'
    }finally{foreach($path in @($source,$install,$nodeRoot)){if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Recurse -Force}}}
}

$results += Invoke-CcodTest 'missing sealed package identity never enables idempotence or package-conflict decisions' {
    $source=New-CcodLifecycleTempRoot;$install=New-CcodLifecycleTempRoot;$nodeRoot=New-CcodLifecycleTempRoot
    try{
        New-CcodLifecycleSourceFixture -Root $source -Version '2.5.22-no-identity'|Out-Null;$nodePath=New-CcodLifecycleFakeNode -Root $nodeRoot
        $first=Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -SealedPackageSha256 ('a'*64) -Adapters (New-CcodLifecycleFake -NodePath $nodePath).Adapters
        $second=Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters (New-CcodLifecycleFake -NodePath $nodePath).Adapters
        Assert-CcodEqual 'Upgraded' $second.Outcome 'legacy direct call without canonical package identity is not treated as idempotent'
        Assert-CcodTrue ($second.RuntimeId-cne$first.RuntimeId) 'missing package identity creates a fresh unique generation'
        Assert-CcodEqual 2 (Read-CcodActiveRuntime -InstallRoot $install).generation 'missing package identity follows the normal monotonic upgrade path'
    }finally{foreach($path in @($source,$install,$nodeRoot)){if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Recurse -Force}}}
}

$results += Invoke-CcodTest 'unique immutable runtime ids bind project and manifest file identity while preserving per-attempt uniqueness' {
    $module=Get-Module InstallLifecycle -ErrorAction Stop
    $filesA=@([pscustomobject]@{Relative='a.txt';ExpectedLength=[int64]1;ExpectedSha256=('a'*64);Source='unused'})
    $filesB=@([pscustomobject]@{Relative='a.txt';ExpectedLength=[int64]1;ExpectedSha256=('b'*64);Source='unused'})
    $first=&$module {param($Files)New-CcodUniqueRuntimeId -ProjectVersion '2.5.22' -Files $Files -NewNonce { '1'*32 }} $filesA
    $second=&$module {param($Files)New-CcodUniqueRuntimeId -ProjectVersion '2.5.22' -Files $Files -NewNonce { '2'*32 }} $filesA
    $differentContent=&$module {param($Files)New-CcodUniqueRuntimeId -ProjectVersion '2.5.22' -Files $Files -NewNonce { '1'*32 }} $filesB
    $differentVersion=&$module {param($Files)New-CcodUniqueRuntimeId -ProjectVersion '2.5.23' -Files $Files -NewNonce { '1'*32 }} $filesA
    Assert-CcodEqual '2.5.22-a1c6387570c23404-11111111111111111111111111111111' $first 'runtime id contains project version, manifest file digest, and canonical nonce'
    Assert-CcodTrue ($first.Length-le96) 'runtime id remains within the manifest identity bound'
    Assert-CcodTrue ($first-cne$second) 'identical package content receives a unique generation id per attempt'
    Assert-CcodTrue ($first-cne$differentContent) 'manifest file content changes the deterministic runtime identity'
    Assert-CcodTrue ($first-cne$differentVersion) 'project version changes the deterministic runtime identity'
    Assert-CcodThrows { &$module {param($Files)New-CcodUniqueRuntimeId -ProjectVersion '2.5.22' -Files $Files -NewNonce { 'not-a-guid' }} $filesA } 'CCOD_INSTALL_RUNTIME_ID_INVALID'
}

$results += Invoke-CcodTest 'immutable record helpers reject a cross-root transaction before creating state' {
    $a=New-CcodLifecycleTempRoot;$b=New-CcodLifecycleTempRoot;[IO.Directory]::CreateDirectory($a)|Out-Null;[IO.Directory]::CreateDirectory($b)|Out-Null
    $module=Get-Module InstallLifecycle -ErrorAction Stop;$tx=&$module {param($Root)Open-CcodLifecycleInstallGeneration -InstallRoot $Root -RuntimeId 'scope-runtime'} $a
    try {
        $record=&$module {New-CcodInstallTransactionRecord -TransactionId '22222222-3333-4444-5555-666666666666' -OldRuntimeId $null -OldGeneration $null -OldManifestSha256 $null -NewRuntimeId 'scope-runtime' -NewGeneration 1 -NewManifestSha256 ('2'*64) -SealedPackageSha256 ('e'*64) -OwnedObjectNames @('scope-runtime')}
        Assert-CcodThrows { &$module {param($Root,$Record,$Tx)Write-CcodInstallTransactionRecord -InstallRoot $Root -TransactionRecord $Record -FileTransaction $Tx} $b $record $tx } 'CCOD_INSTALL_TRANSACTION_SCOPE'
        Assert-CcodEqual $false (Test-Path -LiteralPath (Join-Path $b 'state')) 'cross-root call creates no state'
    } finally { &$module {param($Tx)Close-CcodInstallFileTransaction -Transaction $Tx -Disposition Failed} $tx;if(Test-Path $a){Remove-Item $a -Recurse -Force};if(Test-Path $b){Remove-Item $b -Recurse -Force} }
}

$results += Invoke-CcodTest 'state and UI initialization reject a cross-root transaction before either state plane is written' {
    $a=New-CcodLifecycleTempRoot;$b=New-CcodLifecycleTempRoot;[IO.Directory]::CreateDirectory($a)|Out-Null;[IO.Directory]::CreateDirectory($b)|Out-Null
    $module=Get-Module InstallLifecycle -ErrorAction Stop;$runtimeId='2.5.22-1111111111111111-22222222222222222222222222222222';$tx=&$module {param($Root,$Id)Open-CcodLifecycleInstallGeneration -InstallRoot $Root -RuntimeId $Id} $a $runtimeId
    try{Assert-CcodThrows {&$module {param($Root,$Id,$Transaction)Initialize-CcodInstallStatePlanes -InstallRoot $Root -RuntimeId $Id -FileTransaction $Transaction -NodeCandidates @() -CandidateCompatibleOptIn $false} $b $runtimeId $tx} 'CCOD_INSTALL_TRANSACTION_SCOPE';Assert-CcodEqual $false (Test-Path -LiteralPath (Join-Path $a 'state')) 'root A receives no baseline on cross-root rejection';Assert-CcodEqual $false (Test-Path -LiteralPath (Join-Path $b 'state')) 'root B receives no operational or UI state on cross-root rejection'}finally{&$module {param($Transaction)Close-CcodInstallFileTransaction -Transaction $Transaction -Disposition Failed} $tx;if(Test-Path $a){Remove-Item $a -Recurse -Force};if(Test-Path $b){Remove-Item $b -Recurse -Force}}
}

$results += Invoke-CcodTest 'partial operational state fails closed without overwrite or activation' {
    $source=New-CcodLifecycleTempRoot;$install=New-CcodLifecycleTempRoot;$nodeRoot=New-CcodLifecycleTempRoot
    try{
        New-CcodLifecycleSourceFixture -Root $source|Out-Null;$stateRoot=Join-Path $install 'state';[IO.Directory]::CreateDirectory($stateRoot)|Out-Null
        $settingsPath=Join-Path $stateRoot 'settings.json';[IO.File]::WriteAllText($settingsPath,'{"schemaVersion":1,"sentinel":"partial"}',[Text.UTF8Encoding]::new($false));$before=Get-CcodTestFileSha256 $settingsPath
        $node=New-CcodLifecycleFakeNode -Root $nodeRoot;Assert-CcodThrows {Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters (New-CcodLifecycleFake -NodePath $node).Adapters|Out-Null} 'CCOD_STATE_ALREADY_INITIALIZED'
        Assert-CcodEqual $before (Get-CcodTestFileSha256 $settingsPath) 'partial operational state is not overwritten';Assert-CcodEqual 1 @(Get-ChildItem -LiteralPath $stateRoot -File).Count 'no other operational state leaf is materialized';Assert-CcodEqual $false (Test-Path -LiteralPath (Join-Path $stateRoot 'active-generation')) 'partial state cannot activate a generation'
    }finally{foreach($p in @($source,$install,$nodeRoot)){if(Test-Path $p){Remove-Item $p -Recurse -Force}}}
}

$results += Invoke-CcodTest 'transaction reader rejects immutable identity drift across a contiguous snapshot chain' {
    $install=New-CcodLifecycleTempRoot;$transactionId='33333333-4444-5555-6666-777777777777'
    try{
        $store=Join-Path $install 'state\install-transactions';[IO.Directory]::CreateDirectory($store)|Out-Null
        $prepared=[pscustomobject][ordered]@{schemaVersion=1;transactionId=$transactionId;oldRuntimeId='runtime-old-a';oldGeneration=1;oldManifestSha256=('1'*64);newRuntimeId='runtime-new';newGeneration=2;newManifestSha256=('2'*64);sealedPackageSha256=('f'*64);ownedObjectNames=@('runtime-new');phase='Prepared';errorCode=$null}
        $verified=[pscustomobject][ordered]@{schemaVersion=1;transactionId=$transactionId;oldRuntimeId='runtime-old-b';oldGeneration=1;oldManifestSha256=('1'*64);newRuntimeId='runtime-new';newGeneration=2;newManifestSha256=('2'*64);sealedPackageSha256=('f'*64);ownedObjectNames=@('runtime-new');phase='PackageVerified';errorCode=$null}
        [IO.File]::WriteAllText((Join-Path $store "00000000000000000002.00.Prepared.$transactionId.json"),($prepared|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $store "00000000000000000002.01.PackageVerified.$transactionId.json"),($verified|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
        $module=Get-Module InstallLifecycle -ErrorAction Stop
        Assert-CcodThrows {&$module {param($Root,$Id)Read-CcodInstallTransactionRecord -InstallRoot $Root -TransactionId $Id|Out-Null} $install $transactionId} 'CCOD_INSTALL_TRANSACTION_INVALID'
    }finally{if(Test-Path -LiteralPath $install){Remove-Item -LiteralPath $install -Recurse -Force}}
}

$results += Invoke-CcodTest 'transaction store rejects unknown reparse ADS multilink and ambiguous chains' {
    $module=Get-Module InstallLifecycle -ErrorAction Stop
    $newRecord={param($Id,[uint64]$Generation)[pscustomobject][ordered]@{schemaVersion=1;transactionId=$Id;oldRuntimeId='runtime-old';oldGeneration=[uint64]1;oldManifestSha256=('1'*64);newRuntimeId=("runtime-new-$Generation");newGeneration=$Generation;newManifestSha256=('2'*64);sealedPackageSha256=('a'*64);ownedObjectNames=@("runtime-new-$Generation");phase='Prepared';errorCode=$null}}
    foreach($kind in @('unknown','reparse','ads','multilink','ambiguous')){
        $install=New-CcodLifecycleTempRoot;$outside=New-CcodLifecycleTempRoot
        try{
            $store=Join-Path $install 'state\install-transactions';[IO.Directory]::CreateDirectory($store)|Out-Null;[IO.Directory]::CreateDirectory($outside)|Out-Null
            if($kind-ceq'unknown'){[IO.File]::WriteAllText((Join-Path $store 'unknown.bin'),'x',[Text.UTF8Encoding]::new($false))}
            elseif($kind-ceq'reparse'){New-Item -ItemType Junction -Path (Join-Path $store '00000000000000000002.00.Prepared.44444444-5555-6666-7777-888888888888.json') -Target $outside|Out-Null}
            elseif($kind-ceq'ads'){$id='44444444-5555-6666-7777-888888888888';$path=Join-Path $store "00000000000000000002.00.Prepared.$id.json";[IO.File]::WriteAllText($path,((&$newRecord $id 2)|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false));Set-Content -LiteralPath $path -Stream 'evidence' -Value 'x' -NoNewline}
            elseif($kind-ceq'multilink'){$id='44444444-5555-6666-7777-888888888888';$outsideFile=Join-Path $outside 'record.json';[IO.File]::WriteAllText($outsideFile,((&$newRecord $id 2)|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false));New-Item -ItemType HardLink -Path (Join-Path $store "00000000000000000002.00.Prepared.$id.json") -Target $outsideFile|Out-Null}
            else{foreach($pair in @(@('44444444-5555-6666-7777-888888888888',[uint64]2),@('55555555-6666-7777-8888-999999999999',[uint64]3))){$id=[string]$pair[0];$generation=[uint64]$pair[1];[IO.File]::WriteAllText((Join-Path $store ('{0:D20}.00.Prepared.{1}.json'-f$generation,$id)),((&$newRecord $id $generation)|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))}}
            $expected=if($kind-ceq'ambiguous'){'CCOD_INSTALL_TRANSACTION_AMBIGUOUS'}else{'CCOD_INSTALL_TRANSACTION_INVALID'}
            Assert-CcodThrows {&$module {param($Root)Read-CcodInstallTransactionRecord -InstallRoot $Root|Out-Null} $install} $expected
        }finally{if(Test-Path -LiteralPath $install){Remove-Item -LiteralPath $install -Recurse -Force -ErrorAction SilentlyContinue};if(Test-Path -LiteralPath $outside){Remove-Item -LiteralPath $outside -Recurse -Force -ErrorAction SilentlyContinue}}
    }
}

$results += Invoke-CcodTest 'transaction reader rejects ambiguous Ready and latest Failed terminal heads' {
    $module=Get-Module InstallLifecycle -ErrorAction Stop
    foreach($terminalKind in @('Ready','Failed')){
        $install=New-CcodLifecycleTempRoot
        try{
            $store=Join-Path $install 'state\install-transactions';[IO.Directory]::CreateDirectory($store)|Out-Null
            $runtimeId='runtime-terminal';$generation=if($terminalKind-ceq'Ready'){[uint64]1}else{[uint64]2}
            foreach($id in @('66666666-7777-8888-9999-aaaaaaaaaaaa','77777777-8888-9999-aaaa-bbbbbbbbbbbb')){
                $phases=if($terminalKind-ceq'Ready'){@('Prepared','PackageVerified','RuntimeStaged','PreviousProtectionStopped','RuntimePromoted','PointerCommitted','StableShellCommitted','ProtectionReady','Ready')}else{@('Prepared','Failed')}
                foreach($phase in $phases){$index=if($phase-ceq'Failed'){99}else{[Array]::IndexOf(@('Prepared','PackageVerified','RuntimeStaged','PreviousProtectionStopped','RuntimePromoted','PointerCommitted','StableShellCommitted','ProtectionReady','Ready'),$phase)};$record=[pscustomobject][ordered]@{schemaVersion=1;transactionId=$id;oldRuntimeId=$null;oldGeneration=$null;oldManifestSha256=$null;newRuntimeId=$runtimeId;newGeneration=$generation;newManifestSha256=('2'*64);sealedPackageSha256=('b'*64);ownedObjectNames=@($runtimeId);phase=$phase;errorCode=if($phase-ceq'Failed'){'CCOD_INSTALL_FAILED'}else{$null}};[IO.File]::WriteAllText((Join-Path $store ('{0:D20}.{1:D2}.{2}.{3}.json'-f$generation,$index,$phase,$id)),($record|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))}
            }
            if($terminalKind-ceq'Ready'){$pointerRoot=Join-Path $install 'state\active-generation';[IO.Directory]::CreateDirectory($pointerRoot)|Out-Null;[IO.File]::WriteAllText((Join-Path $pointerRoot '00000000000000000001.json'),('{"schemaVersion":1,"generation":1,"activeRuntime":"'+$runtimeId+'","previousGeneration":0}'),[Text.UTF8Encoding]::new($false))}
            Assert-CcodThrows {&$module {param($Root)Read-CcodInstallTransactionRecord -InstallRoot $Root|Out-Null} $install} 'CCOD_INSTALL_TRANSACTION_AMBIGUOUS'
        }finally{if(Test-Path -LiteralPath $install){Remove-Item -LiteralPath $install -Recurse -Force}}
    }
}

$results += Invoke-CcodTest 'real install entry rejects pointerless and ambiguous nonterminal transaction state before generation creation' {
    foreach($count in @(1,2)){
        $source=New-CcodLifecycleTempRoot;$install=New-CcodLifecycleTempRoot;$nodeRoot=New-CcodLifecycleTempRoot
        try{
            New-CcodLifecycleSourceFixture -Root $source|Out-Null;$store=Join-Path $install 'state\install-transactions';[IO.Directory]::CreateDirectory($store)|Out-Null
            for($i=1;$i-le$count;$i++){$id=if($i-eq1){'88888888-9999-aaaa-bbbb-cccccccccccc'}else{'99999999-aaaa-bbbb-cccc-dddddddddddd'};$runtime="pending-$i";$record=[pscustomobject][ordered]@{schemaVersion=1;transactionId=$id;oldRuntimeId=$null;oldGeneration=$null;oldManifestSha256=$null;newRuntimeId=$runtime;newGeneration=[uint64]$i;newManifestSha256=('2'*64);sealedPackageSha256=('3'*64);ownedObjectNames=@($runtime);phase='Prepared';errorCode=$null};[IO.File]::WriteAllText((Join-Path $store ('{0:D20}.00.Prepared.{1}.json'-f$i,$id)),($record|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))}
            $node=New-CcodLifecycleFakeNode -Root $nodeRoot;$expected=if($count-eq1){'CCOD_INSTALL_TRANSACTION_BUSY'}else{'CCOD_INSTALL_TRANSACTION_AMBIGUOUS'}
            Assert-CcodThrows {Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters (New-CcodLifecycleFake -NodePath $node).Adapters|Out-Null} $expected
            Assert-CcodEqual $false (Test-Path -LiteralPath (Join-Path $install 'runtime')) "global transaction gate creates no generation for $count head(s)"
        }finally{foreach($p in @($source,$install,$nodeRoot)){if(Test-Path $p){Remove-Item $p -Recurse -Force}}}
    }
}

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

<# Superseded: Setup no longer parses mutable JSON progress or owns an app payload tree.
# Production mutation caught: recognizing JSON members only when the colon has zero or one following space.
$results += Invoke-CcodTest 'Inno activation progress parser accepts every legal JSON whitespace form' {
    $installerPath = Join-Path $repositoryRoot 'build\CodexControlOtherDevices.iss'
    $installerScript = Get-Content -LiteralPath $installerPath -Raw -Encoding UTF8
    $valueFunctionOffset = $installerScript.IndexOf('function HasJsonStringValue', [StringComparison]::Ordinal)
    $helperFunctionOffset = $installerScript.IndexOf('function IsJsonWhitespace', [StringComparison]::Ordinal)
    $parserOffset = if ($helperFunctionOffset -ge 0 -and $helperFunctionOffset -lt $valueFunctionOffset) { $helperFunctionOffset } else { $valueFunctionOffset }
    $parserEnd = $installerScript.IndexOf('function DetectActivationPhase', [StringComparison]::Ordinal)
    Assert-CcodTrue ($parserOffset -ge 0 -and $parserEnd -gt $parserOffset) 'the production Inno JSON progress parser can be isolated for execution'

    $isccCandidates = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
        (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe')
    )
    $iscc = @($isccCandidates | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and [IO.File]::Exists($_) }) | Select-Object -First 1
    if ($null -eq $iscc) {
        Write-Output 'Inno activation parser execution skipped because ISCC.exe is unavailable.'
        return
    }

    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-inno-parser-' + [guid]::NewGuid().ToString('N'))
    try {
        [IO.Directory]::CreateDirectory($root) | Out-Null
        $parserSource = $installerScript.Substring($parserOffset,$parserEnd-$parserOffset)
        $harnessPath = Join-Path $root 'ActivationParser.iss'
        $resultPath = Join-Path $root 'parser-result.txt'
        $outputRoot = Join-Path $root 'out'
        [IO.Directory]::CreateDirectory($outputRoot) | Out-Null
        $harness = @"
[Setup]
AppName=CodexRemote-fix activation parser self-test
AppVersion=1.0
DefaultDirName={tmp}\CcodActivationParserSelfTest
CreateAppDir=no
Uninstallable=no
PrivilegesRequired=lowest
OutputDir=$outputRoot
OutputBaseFilename=ActivationParserSelfTest
Compression=none

[Code]
$parserSource
function InitializeSetup(): Boolean;
begin
  if not HasJsonStringValue('{"phase":"StartingProtection"}', 'phase', 'StartingProtection') then
  begin SaveStringToFile('$resultPath', 'compact JSON was rejected', False); Result := False; Exit; end;
  if not HasJsonStringValue('{"phase":  "StartingProtection"}', 'phase', 'StartingProtection') then
  begin SaveStringToFile('$resultPath', 'two spaces were rejected', False); Result := False; Exit; end;
  if not HasJsonStringValue('{"phase"' + #9 + ':' + #13 + #10 + ' "StartingProtection"}', 'phase', 'StartingProtection') then
  begin SaveStringToFile('$resultPath', 'tab or newline JSON whitespace was rejected', False); Result := False; Exit; end;
  if not HasJsonStringValue('{"activationId" :  "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"}', 'activationId', 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee') then
  begin SaveStringToFile('$resultPath', 'correlation JSON whitespace was rejected', False); Result := False; Exit; end;
  if HasJsonStringValue('{"phase": "StartingProtection-extra"}', 'phase', 'StartingProtection') then
  begin SaveStringToFile('$resultPath', 'a non-exact JSON string value was accepted', False); Result := False; Exit; end;
  SaveStringToFile('$resultPath', 'pass', False);
  Result := False;
end;
"@
        [IO.File]::WriteAllText($harnessPath,$harness,[Text.UTF8Encoding]::new($false))
        $compileOutput = @(& $iscc $harnessPath 2>&1)
        Assert-CcodEqual 0 $LASTEXITCODE "production Inno parser compiles in an executable harness: $($compileOutput -join ' ')"
        $executable = Join-Path $outputRoot 'ActivationParserSelfTest.exe'
        Assert-CcodTrue (Test-Path -LiteralPath $executable -PathType Leaf) 'compiled parser harness exists'
        $process = Start-Process -FilePath $executable -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-') -WindowStyle Hidden -Wait -PassThru
        try { $runExitCode = [int]$process.ExitCode } finally { $process.Dispose() }
        Assert-CcodTrue (Test-Path -LiteralPath $resultPath -PathType Leaf) "production Inno parser harness executed with exit code $runExitCode"
        Assert-CcodEqual 'pass' ([IO.File]::ReadAllText($resultPath,[Text.UTF8Encoding]::new($false))) 'production Inno parser accepts legal JSON whitespace and exact string values at runtime'
    } finally {
        if (Test-Path -LiteralPath $root) {
            $cleanupDeadline = [DateTime]::UtcNow.AddSeconds(5)
            while (Test-Path -LiteralPath $root) {
                try { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop }
                catch {
                    if ([DateTime]::UtcNow -ge $cleanupDeadline) { throw }
                    Start-Sleep -Milliseconds 50
                }
            }
        }
    }
}

# Production mutation caught: launching activation without a process owner or returning from Setup before that owner exits.
$results += Invoke-CcodTest 'Inno visibly starts and synchronously owns the bounded activation worker' {
    $installerScript = Get-Content -LiteralPath (Join-Path $repositoryRoot 'build\CodexControlOtherDevices.iss') -Raw -Encoding UTF8
    $activationWorker = Get-Content -LiteralPath (Join-Path $repositoryRoot 'Activate-CcodRemoteFix.ps1') -Raw -Encoding UTF8
    $firstReceiptTimeout = [regex]::Match($installerScript,'(?m)^\s*FIRST_ACTIVATION_RECEIPT_TIMEOUT_MILLISECONDS\s*=\s*(?<milliseconds>[0-9]+);\r?$')
    Assert-CcodTrue $firstReceiptTimeout.Success 'installer declares a dedicated first-receipt timeout'
    Assert-CcodEqual 90000 ([int]$firstReceiptTimeout.Groups['milliseconds'].Value) 'a worker that emits no receipt cannot hold Setup for five minutes'

    $postInstall = [regex]::Match($installerScript,'(?s)procedure CurStepChanged\(CurStep: TSetupStep\);.*?\nbegin(?<body>.*?)\nend;')
    Assert-CcodTrue $postInstall.Success 'post-install activation route exists'
    $body = $postInstall.Groups['body'].Value
    $startingOffset = $body.IndexOf('UpdateActivationStartingPresentation();',[StringComparison]::Ordinal)
    $launchOffset = $body.IndexOf('ewWaitUntilTerminated, ActivationResultCode',[StringComparison]::Ordinal)
    Assert-CcodTrue ($startingOffset -ge 0 -and $launchOffset -gt $startingOffset) 'visible startup is rendered before synchronously waiting for the activation owner'
    Assert-CcodTrue ($body -cmatch '(?s)-FirstReceiptTimeoutMilliseconds\s+.*?FIRST_ACTIVATION_RECEIPT_TIMEOUT_MILLISECONDS' -and
        $body -cmatch '(?s)-ActivationTimeoutMilliseconds\s+.*?ACTIVATION_TIMEOUT_MILLISECONDS') 'Inno passes both fixed deadlines to the process owner'
    Assert-CcodTrue ($body -cnotmatch 'ewNoWait') 'Setup never releases an unowned activation worker'
    Assert-CcodTrue ($activationWorker -cmatch '(?s)function Stop-CcodOwnedInstallProcess.*?\.Kill\(\).*?WaitForExit\(5000\).*?\.HasExited' -and
        $activationWorker -cmatch '(?s)function Invoke-CcodOwnedInstallWorker.*?finally\s*\{.*?if \(\$null -ne \$process\).*?if \(-not \$process\.HasExited\)\s*\{\s*Stop-CcodOwnedInstallProcess.*?\$process\.Dispose\(\)') 'every abnormal owner path kills and proves the exact child exit before disposal'
    Assert-CcodTrue ($activationWorker -cmatch '(?s)function Stop-CcodOwnedInstallProcess.*?WaitForExit\(5000\).*?while \(\$true\).*?\.Kill\(\).*?\.WaitForExit\(\).*?\.HasExited.*?return') 'an unproven bounded stop escalates to waiting until exact child exit instead of returning to Setup'
}

#>

$results += Invoke-CcodTest 'sealed Setup delegates strict append-only receipt validation to the locked bootstrap' {
    $installerScript = Get-Content -LiteralPath (Join-Path $repositoryRoot 'build\CodexControlOtherDevices.iss') -Raw -Encoding UTF8
    $activationWorker = Get-Content -LiteralPath (Join-Path $repositoryRoot 'Activate-CcodRemoteFix.ps1') -Raw -Encoding UTF8
    Assert-CcodTrue ($installerScript -cmatch '(?s)function PrepareToInstall.*ExtractAndLockCcodInputs.*procedure CurStepChanged.*GetArrayLength\(CcodInputHandles\) <> 3.*GetCcodBootstrapParameters.*ewWaitUntilTerminated, ActivationResultCode.*GetCcodBootstrapParameters\(ActivationId, True\).*ewWaitUntilTerminated, ValidationResultCode') 'Setup retains one pre-install locked bootstrap across activation and strict validation'
    Assert-CcodTrue ($installerScript -cmatch '-PackagePath' -and $installerScript -cmatch '-ExpectedPackageSha256' -and $installerScript -cnotmatch 'post-install-activation\.json') 'Setup passes the compile-bound sealed package and owns no mutable receipt path'
    Assert-CcodTrue ($activationWorker -cmatch 'state\\activation-receipts' -and $activationWorker -cmatch '\$ExpectedActivationId\.\$phase\.json' -and $activationWorker -cnotmatch "Join-Path \`$Root 'state\\post-install-activation\.json'") 'bootstrap validates only append-only activation receipts'
}

$results += Invoke-CcodTest 'activation owner kills and proves exit before a timed-out child can change the receipt' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-activation-owned-timeout-' + [guid]::NewGuid().ToString('N'))
    try {
        [IO.Directory]::CreateDirectory((Join-Path $root 'state\activation-receipts')) | Out-Null
        $lateMarker = Join-Path $root 'late-write.txt'
        $installScript = Join-Path $root 'Install-CodexControlOtherDevices.ps1'
        $installSource = @"
param([string]`$InstallRoot,[string]`$ActivationId,[switch]`$EnableCandidateCompatibleUpdates)
Start-Sleep -Milliseconds 1200
`$receipt=[ordered]@{schemaVersion=1;activationId=`$ActivationId;phase='Ready';runtimeId='late-runtime';previousRuntimeId=`$null;startedAtUtc='2030-02-03T04:05:06.0000000Z';updatedAtUtc='2030-02-03T04:05:07.0000000Z';ready=`$true;errorCode=`$null}
[IO.File]::WriteAllText((Join-Path `$InstallRoot "state\activation-receipts\`$ActivationId.Ready.json"),(`$receipt|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new(`$false))
[IO.File]::WriteAllText('$lateMarker','late',[Text.UTF8Encoding]::new(`$false))
exit 0
"@
        [IO.File]::WriteAllText($installScript,$installSource,[Text.UTF8Encoding]::new($false))
        $activationId = '77777777-6666-5555-4444-333333333333'
        $output = @(& (Join-Path $repositoryRoot 'Activate-CcodRemoteFix.ps1') -AppRoot $root -InstallRoot $root -ActivationId $activationId -FirstReceiptTimeoutMilliseconds 200 -ActivationTimeoutMilliseconds 3000 2>&1)
        Assert-CcodEqual 1 $LASTEXITCODE 'missing first receipt makes the owned activation fail'
        Start-Sleep -Milliseconds 1400
        Assert-CcodTrue (-not (Test-Path -LiteralPath $lateMarker)) 'the exact install child cannot write after the activation owner returns'
        Assert-CcodTrue (-not (Test-Path -LiteralPath (Join-Path $root "state\activation-receipts\$activationId.Ready.json"))) 'the killed child cannot later publish Ready'
        $log = Get-Content -LiteralPath (Join-Path $root 'logs\post-install-activation.log') -Raw -Encoding UTF8
        Assert-CcodTrue ($log -cmatch 'CCOD_ACTIVATION_FIRST_RECEIPT_TIMEOUT') 'the owner records the stable first-receipt timeout code'
        Assert-CcodTrue (($output -join "`n") -cmatch 'CCOD_ACTIVATION_FIRST_RECEIPT_TIMEOUT') 'the owner reports the bounded timeout without a safe terminal receipt'
    } finally {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

$results += Invoke-CcodTest 'activation owner freezes a correlated progress receipt at the total deadline' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-activation-owned-total-timeout-' + [guid]::NewGuid().ToString('N'))
    try {
        [IO.Directory]::CreateDirectory((Join-Path $root 'state\activation-receipts')) | Out-Null
        $lateMarker = Join-Path $root 'late-total-write.txt'
        $installScript = Join-Path $root 'Install-CodexControlOtherDevices.ps1'
        $installSource = @"
param([string]`$InstallRoot,[string]`$ActivationId,[switch]`$EnableCandidateCompatibleUpdates)
`$receipt=[ordered]@{schemaVersion=1;activationId=`$ActivationId;phase='StartingProtection';runtimeId='pending-runtime';previousRuntimeId=`$null;startedAtUtc='2030-02-03T04:05:06.0000000Z';updatedAtUtc='2030-02-03T04:05:07.0000000Z';ready=`$false;errorCode=`$null}
[IO.File]::WriteAllText((Join-Path `$InstallRoot "state\activation-receipts\`$ActivationId.StartingProtection.json"),(`$receipt|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new(`$false))
Start-Sleep -Milliseconds 3000
`$receipt.phase='Ready';`$receipt.ready=`$true;`$receipt.updatedAtUtc='2030-02-03T04:05:08.0000000Z'
[IO.File]::WriteAllText((Join-Path `$InstallRoot "state\activation-receipts\`$ActivationId.Ready.json"),(`$receipt|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new(`$false))
[IO.File]::WriteAllText('$lateMarker','late',[Text.UTF8Encoding]::new(`$false))
exit 0
"@
        [IO.File]::WriteAllText($installScript,$installSource,[Text.UTF8Encoding]::new($false))
        $activationId = '77777777-6666-5555-4444-333333333333'
        $output = @(& (Join-Path $repositoryRoot 'Activate-CcodRemoteFix.ps1') -AppRoot $root -InstallRoot $root -ActivationId $activationId -FirstReceiptTimeoutMilliseconds 1000 -ActivationTimeoutMilliseconds 1200 2>&1)
        Assert-CcodEqual 1 $LASTEXITCODE 'total deadline makes the owned activation fail after correlated progress'
        Start-Sleep -Milliseconds 3200
        Assert-CcodTrue (-not (Test-Path -LiteralPath $lateMarker)) 'the exact install child cannot write after the total deadline owner return'
        $receipt = Get-Content -LiteralPath (Join-Path $root "state\activation-receipts\$activationId.StartingProtection.json") -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-CcodEqual 'StartingProtection' $receipt.phase 'the killed child cannot change progress into Ready after Setup regains control'
        $log = Get-Content -LiteralPath (Join-Path $root 'logs\post-install-activation.log') -Raw -Encoding UTF8
        Assert-CcodTrue ($log -cmatch 'CCOD_ACTIVATION_TIMEOUT') 'the owner records the stable total timeout code'
        Assert-CcodTrue (($output -join "`n") -cmatch 'CCOD_ACTIVATION_TIMEOUT') 'the owner reports the bounded total timeout without a safe Ready result'
    } finally {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# Production mutation caught: reducing a strict correlated Failed receipt to the generic activation-worker exit code.
$results += Invoke-CcodTest 'activation worker reports the strict Failed receipt support code without prompting' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-activation-failed-report-' + [guid]::NewGuid().ToString('N'))
    try {
        [IO.Directory]::CreateDirectory((Join-Path $root 'state\activation-receipts')) | Out-Null
        $promptMarker = Join-Path $root 'prompt-marker.txt'
        $installScript = Join-Path $root 'Install-CodexControlOtherDevices.ps1'
        $promptScript = Join-Path $root 'Prompt-CcodRestart.ps1'
        $installSource = @"
param([string]`$InstallRoot,[string]`$ActivationId,[switch]`$EnableCandidateCompatibleUpdates)
`$receipt=[ordered]@{schemaVersion=1;activationId=`$ActivationId;phase='Failed';runtimeId='runtime-new';previousRuntimeId='runtime-old';startedAtUtc='2030-02-03T04:05:06.0000000Z';updatedAtUtc='2030-02-03T04:05:07.0000000Z';ready=`$false;errorCode='CCOD_INSTALL_NEW_RUNTIME_NOT_READY'}
[IO.File]::WriteAllText((Join-Path `$InstallRoot "state\activation-receipts\`$ActivationId.Failed.json"),(`$receipt|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new(`$false))
exit 1
"@
        [IO.File]::WriteAllText($installScript,$installSource,[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($promptScript,"[IO.File]::WriteAllText('$promptMarker','prompted');exit 0",[Text.UTF8Encoding]::new($false))
        $activationId = '77777777-6666-5555-4444-333333333333'
        $output = @(& (Join-Path $repositoryRoot 'Activate-CcodRemoteFix.ps1') -AppRoot $root -InstallRoot $root -ActivationId $activationId -Prompt -NoUi 2>&1)

        Assert-CcodEqual 1 $LASTEXITCODE 'strict Failed receipt keeps the activation worker unsuccessful'
        Assert-CcodTrue (-not (Test-Path -LiteralPath $promptMarker)) 'failed activation never reaches the restart prompt'
        $log = Get-Content -LiteralPath (Join-Path $root 'logs\post-install-activation.log') -Raw -Encoding UTF8
        Assert-CcodTrue ($log -cmatch '"code":"CCOD_INSTALL_NEW_RUNTIME_NOT_READY"') 'activation log retains the strict bounded installer support code'
        Assert-CcodTrue ($log -cnotmatch '"code":"CCOD_ACTIVATION_RUNTIME_FAILED"') 'strict Failed receipt is not hidden behind the generic child exit code'
    } finally {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
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
        $runtimeRoot = Join-Path $install "runtime\$($receipt.RuntimeId)"
        Assert-CcodTrue (Test-Path -LiteralPath (Join-Path $runtimeRoot 'src\persistence\bootstrap.ps1') -PathType Leaf) 'generation-specific bootstrap is sealed with the runtime'
        Assert-CcodEqual $false (Test-Path -LiteralPath (Join-Path $install 'bootstrap.ps1')) 'first install does not create a mutable root bootstrap'
        Assert-CcodEqual $false (Test-Path -LiteralPath (Join-Path $install 'active.json')) 'new install never writes the legacy active pointer'
        Assert-CcodEqual $false (Test-Path -LiteralPath (Join-Path $install 'state\post-install-activation.json')) 'new install never writes the mutable legacy activation receipt'
        Assert-CcodTrue (Test-Path -LiteralPath (Join-Path $install 'state\active-generation\00000000000000000001.json') -PathType Leaf) 'append-only active generation pointer written'
        Assert-CcodTrue (Test-Path -LiteralPath $runtimeRoot -PathType Container) 'runtime staged'
        Assert-CcodEqual 1 $fake.World.TaskInstalled 'task installed'
        Assert-CcodEqual $receipt.RuntimeId $fake.World.TaskRuntimeIds[0] 'scheduled task selects the committed generation bootstrap'
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
        $baselineRoot = Join-Path $stateRoot "install-initializations\$($receipt.RuntimeId)"
        foreach ($leaf in @('settings.json','status.json','verified-packages.json','transition.json','ui-preferences.json')) {
            $baselinePath = Join-Path $baselineRoot $leaf
            Assert-CcodTrue (Test-Path -LiteralPath $baselinePath -PathType Leaf) "immutable initialization baseline contains $leaf"
            Assert-CcodTrue (((Get-Item -LiteralPath $baselinePath -Force).Attributes -band [IO.FileAttributes]::ReadOnly) -ne 0) "immutable initialization baseline seals $leaf"
        }
        foreach ($leaf in @('settings.json','status.json','verified-packages.json','transition.json','ui-preferences.json')) {
            Assert-CcodEqual 0 ((Get-Item -LiteralPath (Join-Path $stateRoot $leaf) -Force).Attributes -band [IO.FileAttributes]::ReadOnly) "operational $leaf remains writable"
        }
        Set-CcodAutomationEnabled -StateRoot $stateRoot -Enabled $false
        Assert-CcodEqual $false (Read-CcodSettings -StateRoot $stateRoot).automationEnabled 'StateStore can update and read operational state after immutable initialization'
        Set-CcodUiLanguageMode -StateRoot $stateRoot -LanguageMode 'zh-CN' | Out-Null
        Assert-CcodEqual 'zh-CN' (Read-CcodUiPreference -StateRoot $stateRoot).LanguageMode 'UI preferences can update and read operational state after immutable initialization'
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

# Production mutation caught: accepting an old setup payload for a newer expected setup version and stopping the active runtime before rejecting it.
$results += Invoke-CcodTest 'upgrade rejects a payload version mismatch before active-pointer or protection mutation' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source -Version '2.5.13' | Out-Null
        $manifestPath = New-CcodLifecyclePayloadManifest -Root $source -Version '2.5.13'
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        $first = Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters (New-CcodLifecycleFake -NodePath $nodePath).Adapters
        $oldRuntime = [string]$first.RuntimeId
        $before = Read-CcodActiveRuntime -InstallRoot $install
        $fake = New-CcodLifecycleFake -NodePath $nodePath

        $payloadBinding = Get-CcodLifecyclePayloadBinding -ManifestPath $manifestPath -ExpectedVersion '2.5.22'
        Assert-CcodThrows {
            Invoke-CcodInstall -SourceRoot $source -InstallRoot $install @payloadBinding -Adapters $fake.Adapters | Out-Null
        } 'CCOD_INSTALL_PAYLOAD_VERSION_MISMATCH'

        $after = Read-CcodActiveRuntime -InstallRoot $install
        Assert-CcodEqual $oldRuntime $after.activeRuntime 'old payload cannot replace the active runtime'
        Assert-CcodEqual $before.generation $after.generation 'version mismatch cannot advance the active generation'
        Assert-CcodEqual 0 $fake.World.ShutdownSignaled 'version mismatch cannot stop the existing protection'
        Assert-CcodEqual 0 $fake.World.TaskInstalled 'version mismatch performs no task mutation'
    } finally {
        foreach ($path in @($source,$install,$nodeRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

# Production mutation caught: rediscovering the payload directory after manifest validation and copying an unlisted leftover into the runtime.
$results += Invoke-CcodTest 'matching payload stages only immutable manifest-listed records' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source -Version '2.5.22' | Out-Null
        $manifestPath = New-CcodLifecyclePayloadManifest -Root $source -Version '2.5.22'
        $stalePath = Join-Path $source 'src\runtime\stale-old-payload.js'
        [IO.File]::WriteAllText($stalePath,"module.exports = 'stale';`n",[Text.UTF8Encoding]::new($false))
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot

        $payloadBinding = Get-CcodLifecyclePayloadBinding -ManifestPath $manifestPath -ExpectedVersion '2.5.22'
        $receipt = Invoke-CcodInstall -SourceRoot $source -InstallRoot $install @payloadBinding -Adapters (New-CcodLifecycleFake -NodePath $nodePath).Adapters

        $runtimeRoot = Join-Path $install "runtime\$($receipt.RuntimeId)"
        Assert-CcodTrue (-not (Test-Path -LiteralPath (Join-Path $runtimeRoot 'src\runtime\stale-old-payload.js'))) 'unlisted stale source file is absent from the runtime'
        $runtimeManifest = Test-CcodRuntimeManifest -RuntimeDirectory $runtimeRoot -ExpectedRuntimeId $receipt.RuntimeId
        Assert-CcodEqual $true $runtimeManifest.Valid 'manifest-filtered runtime remains valid'
        Assert-CcodEqual 0 @($runtimeManifest.Manifest.files | Where-Object { $_.path -ceq 'src/runtime/stale-old-payload.js' }).Count 'runtime manifest contains no unlisted stale record'
    } finally {
        foreach ($path in @($source,$install,$nodeRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

# Production mutation caught: trusting readiness without rereading the active pointer and selected runtime manifest before the terminal Ready receipt.
$results += Invoke-CcodTest 'payload-bound install rereads the active pointer after readiness before reporting Ready' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source -Version '2.5.21' | Out-Null
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        $first = Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -SealedPackageSha256 ('a'*64) -Adapters (New-CcodLifecycleFake -NodePath $nodePath).Adapters
        $oldPointer = Read-CcodActiveRuntime -InstallRoot $install
        [IO.File]::WriteAllText((Join-Path $source 'package.json'),(@{name='codexremote-fix';version='2.5.22';private=$true}|ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $source 'src\runtime\main-payload.js'),"module.exports = 'fixture-2.5.22';`n",[Text.UTF8Encoding]::new($false))
        $manifestPath = New-CcodLifecyclePayloadManifest -Root $source -Version '2.5.22'
        $fake = New-CcodLifecycleFake -NodePath $nodePath
        $fake.Adapters.NewActivationId = { 'bbbbbbbb-cccc-dddd-eeee-ffffffffffff' }
        $fake.Adapters.WaitNewRuntimeReady = {
            param($InstallRoot,$RuntimeId,$RuntimeGeneration,$Identity,$TaskStartedAtUtc,$TimeoutMilliseconds)
            $pointerRoot = Join-Path $InstallRoot 'state\active-generation'
            $drift = [pscustomobject][ordered]@{ schemaVersion=1; generation=[uint64]3; activeRuntime=[string]$oldPointer.activeRuntime; previousGeneration=[uint64]2 }
            [IO.File]::WriteAllText((Join-Path $pointerRoot '00000000000000000003.json'),($drift | ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
            [pscustomobject][ordered]@{ SupervisorReady = $true; TrayReady = $true }
        }.GetNewClosure()

        $payloadBinding = Get-CcodLifecyclePayloadBinding -ManifestPath $manifestPath -ExpectedVersion '2.5.22'
        Assert-CcodThrows {
            Invoke-CcodInstall -SourceRoot $source -InstallRoot $install @payloadBinding -Adapters $fake.Adapters | Out-Null
        } 'CCOD_INSTALL_RUNTIME_ACTIVATION_UNPROVEN'
        Assert-CcodTrue ($fake.World.Phases -notcontains 'Ready') 'pointer drift after readiness cannot produce a Ready receipt'
    } finally {
        foreach ($path in @($source,$install,$nodeRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

# Production mutation caught: copying stable bootstrap/uninstaller from mutable source paths after their manifest-verified staging copies already exist.
$results += Invoke-CcodTest 'stable bootstrap and uninstaller come from manifest-verified staging bytes' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source -Version '2.5.22' | Out-Null
        $uninstallerSource = Join-Path $source 'Uninstall-CodexControlOtherDevices.ps1'
        [IO.File]::WriteAllText($uninstallerSource,"# verified uninstaller`r`n",[Text.UTF8Encoding]::new($false))
        [IO.Directory]::CreateDirectory($install) | Out-Null
        $legacyBootstrap = Join-Path $install 'bootstrap.ps1'
        $legacyUninstaller = Join-Path $install 'Uninstall-CodexControlOtherDevices.ps1'
        [IO.File]::WriteAllText($legacyBootstrap,"# legacy bootstrap sentinel`r`n",[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($legacyUninstaller,"# legacy uninstaller sentinel`r`n",[Text.UTF8Encoding]::new($false))
        $legacyBootstrapHash = Get-CcodTestFileSha256 -Path $legacyBootstrap
        $legacyUninstallerHash = Get-CcodTestFileSha256 -Path $legacyUninstaller
        $manifestPath = New-CcodLifecyclePayloadManifest -Root $source -Version '2.5.22'
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        $fake = New-CcodLifecycleFake -NodePath $nodePath

        $payloadBinding = Get-CcodLifecyclePayloadBinding -ManifestPath $manifestPath -ExpectedVersion '2.5.22'
        $receipt = Invoke-CcodInstall -SourceRoot $source -InstallRoot $install @payloadBinding -Adapters $fake.Adapters

        $runtimeRoot = Join-Path $install "runtime\$($receipt.RuntimeId)"
        Assert-CcodEqual (Get-CcodTestFileSha256 -Path (Join-Path $source 'src\persistence\bootstrap.ps1')) (Get-CcodTestFileSha256 -Path (Join-Path $runtimeRoot 'src\persistence\bootstrap.ps1')) 'generation bootstrap equals the manifest-verified sealed source bytes'
        Assert-CcodEqual (Get-CcodTestFileSha256 -Path $uninstallerSource) (Get-CcodTestFileSha256 -Path (Join-Path $runtimeRoot 'Uninstall-CodexControlOtherDevices.ps1')) 'generation uninstaller equals the manifest-verified sealed source bytes'
        Assert-CcodEqual $legacyBootstrapHash (Get-CcodTestFileSha256 -Path $legacyBootstrap) 'legacy root bootstrap bytes remain unchanged'
        Assert-CcodEqual $legacyUninstallerHash (Get-CcodTestFileSha256 -Path $legacyUninstaller) 'legacy root uninstaller bytes remain unchanged'
    } finally {
        foreach ($path in @($source,$install,$nodeRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

$results += Invoke-CcodTest 'install root junction is rejected before staging writes' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $target = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source | Out-Null
        [IO.Directory]::CreateDirectory($target) | Out-Null
        New-Item -ItemType Junction -Path $install -Target $target | Out-Null
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        Assert-CcodThrows { Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters (New-CcodLifecycleFake -NodePath $nodePath).Adapters | Out-Null } 'CCOD_INSTALL_REPARSE_PATH'
        Assert-CcodTrue (-not (Test-Path -LiteralPath (Join-Path $target 'active.json'))) 'install-root junction target receives no active pointer'
        Assert-CcodTrue (-not (Test-Path -LiteralPath (Join-Path $target '.staging'))) 'install-root junction target receives no staging directory'
    } finally {
        if (Test-Path -LiteralPath $install) { [IO.Directory]::Delete($install) }
        foreach ($path in @($source,$target,$nodeRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

$results += Invoke-CcodTest 'runtime junction is rejected before staging promotion' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $target = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source | Out-Null
        [IO.Directory]::CreateDirectory($install) | Out-Null
        [IO.Directory]::CreateDirectory($target) | Out-Null
        New-Item -ItemType Junction -Path (Join-Path $install 'runtime') -Target $target | Out-Null
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        Assert-CcodThrows { Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters (New-CcodLifecycleFake -NodePath $nodePath).Adapters | Out-Null } 'CCOD_INSTALL_FAILED'
        Assert-CcodEqual 0 @(Get-ChildItem -LiteralPath $target -Force).Count 'runtime junction target receives no promoted runtime'
        Assert-CcodTrue (-not (Test-Path -LiteralPath (Join-Path $install 'active.json'))) 'runtime junction cannot reach active pointer mutation'
    } finally {
        $junction = Join-Path $install 'runtime'
        if (Test-Path -LiteralPath $junction) { [IO.Directory]::Delete($junction) }
        foreach ($path in @($source,$install,$target,$nodeRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

# Production mutation caught: recursive whole-install deletion bypassing the strict per-leaf hard-link contract.
$results += Invoke-CcodTest 'whole-install deletion rejects a nested hard-link before removing any in-tree leaf' {
    $install = New-CcodLifecycleTempRoot
    $outside = New-CcodLifecycleTempRoot
    try {
        $nested = Join-Path $install 'runtime\nested'
        [IO.Directory]::CreateDirectory($nested) | Out-Null
        [IO.Directory]::CreateDirectory($outside) | Out-Null
        $sentinel = Join-Path $outside 'outside-sentinel.txt'
        $linkedLeaf = Join-Path $nested 'linked-state.json'
        $ordinaryLeaf = Join-Path $install 'ordinary-state.json'
        [IO.File]::WriteAllText($sentinel,'outside-original',[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($ordinaryLeaf,'ordinary-original',[Text.UTF8Encoding]::new($false))
        New-Item -ItemType HardLink -Path $linkedLeaf -Target $sentinel | Out-Null

        $caughtId = $null
        try {
            $module = Get-Module InstallLifecycle
            & $module { param($Root) Remove-CcodLifecycleInstallTree -InstallRoot $Root -Adapters @{} } $install
        } catch { $caughtId = ([string]$_.FullyQualifiedErrorId -split ',')[0] }

        Assert-CcodEqual 'CCOD_INSTALL_UNSAFE_LEAF' $caughtId 'whole-install deletion rejects the nested hard-link before recursive removal'
        Assert-CcodTrue ([IO.File]::Exists($linkedLeaf)) 'rejected delete retains the in-tree hard-link'
        Assert-CcodEqual 'ordinary-original' ([IO.File]::ReadAllText($ordinaryLeaf,[Text.UTF8Encoding]::new($false))) 'preflight rejection retains other in-tree leaves'
        Assert-CcodEqual 'outside-original' ([IO.File]::ReadAllText($sentinel,[Text.UTF8Encoding]::new($false))) 'preflight rejection retains outside sentinel bytes'
    } finally {
        foreach ($path in @($install,$outside)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue } }
    }
}

$results += Invoke-CcodTest 'payload manifest ancestry treats Windows root equality case-insensitively' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source -Version '2.5.22' | Out-Null
        $manifestPath = New-CcodLifecyclePayloadManifest -Root $source -Version '2.5.22'
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        $payloadBinding = Get-CcodLifecyclePayloadBinding -ManifestPath $manifestPath -ExpectedVersion '2.5.22'
        $receipt = Invoke-CcodInstall -SourceRoot $source.ToUpperInvariant() -InstallRoot $install @payloadBinding -Adapters (New-CcodLifecycleFake -NodePath $nodePath).Adapters
        Assert-CcodEqual 'Installed' $receipt.Outcome 'case-only source-root difference preserves valid Windows payload ancestry'
    } finally {
        foreach ($path in @($source,$install,$nodeRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

$results += Invoke-CcodTest 'payload-bound install rejects a changed runtime manifest after readiness' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source -Version '2.5.22' | Out-Null
        $manifestPath = New-CcodLifecyclePayloadManifest -Root $source -Version '2.5.22'
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        $fake = New-CcodLifecycleFake -NodePath $nodePath
        $fake.Adapters.WaitNewRuntimeReady = {
            param($InstallRoot,$RuntimeId,$RuntimeGeneration,$Identity,$TaskStartedAtUtc,$TimeoutMilliseconds)
            $runtimeManifestPath = Join-Path $InstallRoot "runtime\$RuntimeId\manifest.json"
            $runtimeManifest = Get-Content -LiteralPath $runtimeManifestPath -Raw | ConvertFrom-Json
            $runtimeManifest.projectVersion = '2.5.13'
            [IO.File]::WriteAllText($runtimeManifestPath,($runtimeManifest|ConvertTo-Json -Depth 16),[Text.UTF8Encoding]::new($false))
            [pscustomobject][ordered]@{SupervisorReady=$true;TrayReady=$true}
        }.GetNewClosure()
        $payloadBinding = Get-CcodLifecyclePayloadBinding -ManifestPath $manifestPath -ExpectedVersion '2.5.22'
        Assert-CcodThrows {
            Invoke-CcodInstall -SourceRoot $source -InstallRoot $install @payloadBinding -Adapters $fake.Adapters | Out-Null
        } 'CCOD_INSTALL_NEW_RUNTIME_NOT_READY'
        Assert-CcodTrue ($fake.World.Phases -notcontains 'Ready') 'changed selected runtime manifest cannot produce Ready'
    } finally {
        foreach ($path in @($source,$install,$nodeRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

# Production mutation caught: routing the activation progress receipt through the generic pretty-printed JSON writer.
$results += Invoke-CcodTest 'activation progress receipt uses one compact JSON line for PowerShell 5.1 and Inno' {
    $install = New-CcodLifecycleTempRoot
    try {
        $activationId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
        $receipt = [pscustomobject][ordered]@{
            schemaVersion = 1
            activationId = $activationId
            phase = 'StartingProtection'
            runtimeId = 'runtime-new'
            previousRuntimeId = 'runtime-old'
            startedAtUtc = '2030-02-03T03:04:05.0000000Z'
            updatedAtUtc = '2030-02-03T03:04:06.0000000Z'
            ready = $false
            errorCode = $null
        }
        $module = Get-Module InstallLifecycle
        & $module { param($Root,$Value) Write-CcodActivationReceiptFile -InstallRoot $Root -Receipt $Value } $install $receipt

        $raw = [IO.File]::ReadAllText((Join-Path $install 'state\post-install-activation.json'),[Text.UTF8Encoding]::new($false))
        $expected = '{"schemaVersion":1,"activationId":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","phase":"StartingProtection","runtimeId":"runtime-new","previousRuntimeId":"runtime-old","startedAtUtc":"2030-02-03T03:04:05.0000000Z","updatedAtUtc":"2030-02-03T03:04:06.0000000Z","ready":false,"errorCode":null}' + "`n"
        Assert-CcodEqual $expected $raw 'activation progress is a compact JSON object with only one trailing newline'
        Assert-CcodEqual 'StartingProtection' (($raw | ConvertFrom-Json).phase) 'compact progress remains valid JSON for the strict terminal reader'
    } finally {
        if (Test-Path -LiteralPath $install) { Remove-Item -LiteralPath $install -Recurse -Force }
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
        Assert-CcodTrue (Test-Path -LiteralPath $stagedModule -PathType Leaf) 'hidden module is staged into the sealed generation'
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
        $operationalHashes=@{};foreach($leaf in @('settings.json','status.json','verified-packages.json','transition.json','ui-preferences.json')){$operationalHashes[$leaf]=Get-CcodTestFileSha256 -Path (Join-Path $stateRoot $leaf)}
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
        $upgradeBaseline=Join-Path $stateRoot "install-initializations\$($second.RuntimeId)"
        foreach($leaf in @('settings.json','status.json','verified-packages.json','transition.json','ui-preferences.json')){Assert-CcodTrue (Test-Path -LiteralPath (Join-Path $upgradeBaseline $leaf) -PathType Leaf) "upgrade baseline contains $leaf";Assert-CcodEqual $operationalHashes[$leaf] (Get-CcodTestFileSha256 -Path (Join-Path $stateRoot $leaf)) "upgrade does not overwrite operational $leaf"}
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

        $activationRoot = Join-Path $install 'state\activation-receipts'
        $matching = @(Get-ChildItem -LiteralPath $activationRoot -Filter '*.Ready.json' -File | ForEach-Object {
            $value = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            if ([string]$value.runtimeId -ceq [string]$receipt.RuntimeId) { [pscustomobject]@{ Path=$_.FullName; Value=$value } }
        })
        Assert-CcodEqual 1 $matching.Count 'exactly one create-only Ready activation receipt binds the upgraded runtime'
        $activationPath = $matching[0].Path
        $activation = $matching[0].Value
        Assert-CcodTrue ([IO.Path]::GetFileName($activationPath) -ceq ("$($activation.activationId).Ready.json")) 'activation receipt filename binds its canonical activation id and phase'
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
        $bootstrapPath = [IO.Path]::GetFullPath((Join-Path $install "runtime\$($installed.RuntimeId)\src\persistence\bootstrap.ps1"))
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

# Production mutation caught: treating a just-started Supervisor's not-yet-created Ready event as a terminal readiness failure.
$results += Invoke-CcodTest 'new-runtime readiness retries a temporary Ready event open failure until the same Supervisor signals' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source -Version '2.5.20-ready-open-retry' | Out-Null
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        $installed = Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters (New-CcodLifecycleFake -NodePath $nodePath).Adapters
        $identity = New-CcodLifecycleIdentity
        $started = [DateTime]::Parse('2030-02-03T03:04:05Z').ToUniversalTime()
        $bootstrap = [IO.Path]::GetFullPath((Join-Path $install "runtime\$($installed.RuntimeId)\src\persistence\bootstrap.ps1"))
        $supervisor = [IO.Path]::GetFullPath((Join-Path $install "runtime\$($installed.RuntimeId)\src\persistence\Supervisor.ps1"))
        $token = 'e' * 64
        $items = @(
            [pscustomobject]@{ProcessId=800;ParentProcessId=1;SessionId=1;CreationDate=[DateTime]::Parse('2030-02-03T03:04:05.1Z').ToUniversalTime();Name='powershell.exe';CommandLine="powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$bootstrap`" -InstallRoot `"$install`" -EntryMode Task"},
            [pscustomobject]@{ProcessId=801;ParentProcessId=800;SessionId=1;CreationDate=[DateTime]::Parse('2030-02-03T03:04:06Z').ToUniversalTime();Name='powershell.exe';CommandLine="powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File `"$supervisor`" -ReadyToken $token"}
        )
        $world = [pscustomobject]@{Elapsed=0L;OpenAttempts=0;Closed=0}
        $adapters = @{
            EnumerateProcesses = { $items }.GetNewClosure()
            GetProcessOwnerSid = { param($Process) $identity.UserSid }.GetNewClosure()
            OpenReadyEvent = { param($Sid,$Session,$ReadyToken) $world.OpenAttempts++; if($world.OpenAttempts -eq 1){throw 'event not created yet'};[pscustomobject]@{Handle='event'} }.GetNewClosure()
            WaitReadyEvent = { param($Event,$Milliseconds) $true }
            IsSupervisorIdentityCurrent = { param($Candidate) $true }
            CloseReadyEvent = { param($Event) $world.Closed++ }.GetNewClosure()
            StartClock = { $world }.GetNewClosure()
            GetElapsedMilliseconds = { param($Clock) [long]$Clock.Elapsed }
            Sleep = { param($Milliseconds) $world.Elapsed += $Milliseconds }.GetNewClosure()
        }
        $module = Get-Module InstallLifecycle
        $proof = & $module {param($Root,$Runtime,$Current,$Started,$A) Wait-CcodLifecycleNewRuntimeReady -InstallRoot $Root -RuntimeId $Runtime -RuntimeGeneration 1 -Identity $Current -TaskStartedAtUtc $Started -TimeoutMilliseconds 200 -Adapters $A} $install $installed.RuntimeId $identity $started $adapters

        Assert-CcodEqual $true $proof.SupervisorReady 'temporary Ready event absence does not discard the live exact Supervisor'
        Assert-CcodEqual $true $proof.TrayReady 'a later signal from the same token proves the TrayHost handshake'
        Assert-CcodEqual 2 $world.OpenAttempts 'Ready event is reopened after one startup race'
        Assert-CcodEqual 1 $world.Closed 'the successfully opened Ready event is closed exactly once'
    } finally {
        foreach($path in @($source,$install,$nodeRoot)){if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Recurse -Force}}
    }
}

# Production mutation caught: comparing CIM's microsecond process timestamp to Get-Process's 100ns timestamp as exact text.
$results += Invoke-CcodTest 'readiness identity accepts only the same CIM-truncated process creation instant' {
    $module = Get-Module InstallLifecycle -ErrorAction Stop
    $actual = [DateTime]::ParseExact('2030-02-03T03:04:05.1234569Z','o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
    $exact = '2030-02-03T03:04:05.1234569Z'
    $cimTruncated = '2030-02-03T03:04:05.1234560Z'
    $differentMicrosecond = '2030-02-03T03:04:05.1234550Z'
    $nextMicrosecond = [DateTime]::ParseExact('2030-02-03T03:04:05.1234570Z','o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
    $futureTick = '2030-02-03T03:04:05.1234570Z'

    Assert-CcodEqual $true (& $module {param($Expected,$Observed) Test-CcodLifecycleCimCreationTime -ExpectedUtc $Expected -ActualUtc $Observed} $exact $actual) 'exact creation time remains current'
    Assert-CcodEqual $true (& $module {param($Expected,$Observed) Test-CcodLifecycleCimCreationTime -ExpectedUtc $Expected -ActualUtc $Observed} $cimTruncated $actual) 'CIM precision loss of at most nine 100ns ticks remains the same process'
    Assert-CcodEqual $false (& $module {param($Expected,$Observed) Test-CcodLifecycleCimCreationTime -ExpectedUtc $Expected -ActualUtc $Observed} $cimTruncated $nextMicrosecond) 'ten 100ns ticks cross the microsecond identity boundary'
    Assert-CcodEqual $false (& $module {param($Expected,$Observed) Test-CcodLifecycleCimCreationTime -ExpectedUtc $Expected -ActualUtc $Observed} $differentMicrosecond $actual) 'a different microsecond remains a different process identity'
    Assert-CcodEqual $false (& $module {param($Expected,$Observed) Test-CcodLifecycleCimCreationTime -ExpectedUtc $Expected -ActualUtc $Observed} $futureTick $actual) 'a future expected timestamp is never normalized backward'
    Assert-CcodEqual $false (& $module {param($Expected,$Observed) Test-CcodLifecycleCimCreationTime -ExpectedUtc $Expected -ActualUtc $Observed} 'not-a-time' $actual) 'malformed identity timestamps fail closed'
}

# Production mutation caught: accepting a wrong generation/path/SID/session/start time/parent/command or more than one matching Supervisor candidate.
$results += Invoke-CcodTest 'new-runtime readiness rejects every mismatched or ambiguous Supervisor candidate before opening its token event' {
    $source = New-CcodLifecycleTempRoot;$install = New-CcodLifecycleTempRoot;$nodeRoot = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source -Version '2.5.0-ready-reject' | Out-Null
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        $installed = Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters (New-CcodLifecycleFake -NodePath $nodePath).Adapters
        $identity = New-CcodLifecycleIdentity;$started=[DateTime]::Parse('2030-02-03T03:04:05Z').ToUniversalTime()
        $bootstrap=[IO.Path]::GetFullPath((Join-Path $install "runtime\$($installed.RuntimeId)\src\persistence\bootstrap.ps1"));$supervisor=[IO.Path]::GetFullPath((Join-Path $install "runtime\$($installed.RuntimeId)\src\persistence\Supervisor.ps1"));$token='b'*64
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
        $identity=New-CcodLifecycleIdentity;$started=[DateTime]::Parse('2030-02-03T03:04:05Z').ToUniversalTime();$bootstrap=[IO.Path]::GetFullPath((Join-Path $install "runtime\$($installed.RuntimeId)\src\persistence\bootstrap.ps1"));$supervisor=[IO.Path]::GetFullPath((Join-Path $install "runtime\$($installed.RuntimeId)\src\persistence\Supervisor.ps1"));$token='d'*64
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
        [pscustomobject]@{ Name='crash after generation commit';Code='CCOD_INSTALL_RUNTIME_ACTIVATION_UNPROVEN';Committed=$true;Configure={param($Fake,$OldRuntime)$gate=[pscustomobject]@{Remaining=1};$Fake.World.SetActiveFailure={param($Root,$RuntimeId,$Ownership,$TargetGeneration,$FileTransaction)if($gate.Remaining-gt0){$gate.Remaining--;$fence={param($InstallRoot,$Receipt,$ExpectActivePointer)$true};Set-CcodActiveRuntime -InstallRoot $Root -TargetGeneration $TargetGeneration -FileTransaction $FileTransaction -Ownership $Ownership -Adapters @{AssertLifecycleFence=$fence}|Out-Null;throw 'PRIVATE_AFTER_COMMIT_SECRET'}}.GetNewClosure()} },
        [pscustomobject]@{ Name='new task start failure';Code='CCOD_INSTALL_SUPERVISOR_START_FAILED';Committed=$true;Configure={param($Fake,$OldRuntime)$gate=[pscustomobject]@{Remaining=1};$Fake.Adapters.StartSupervisorTask={if($gate.Remaining-gt0){$gate.Remaining--;throw 'PRIVATE_TASK_START_SECRET'};$Fake.World.TaskStarted++}.GetNewClosure()} },
        [pscustomobject]@{ Name='Supervisor ready timeout';Code='CCOD_INSTALL_NEW_RUNTIME_NOT_READY';Committed=$true;Configure={param($Fake,$OldRuntime)$Fake.Adapters.WaitNewRuntimeReady={param($Root,$RuntimeId,$Generation,$Identity,$Started,$Timeout)[pscustomobject]@{SupervisorReady=([string]$RuntimeId-ceq[string]$OldRuntime);TrayReady=$true}}.GetNewClosure()} },
        [pscustomobject]@{ Name='TrayHost ready timeout';Code='CCOD_INSTALL_NEW_RUNTIME_NOT_READY';Committed=$true;Configure={param($Fake,$OldRuntime)$Fake.Adapters.WaitNewRuntimeReady={param($Root,$RuntimeId,$Generation,$Identity,$Started,$Timeout)[pscustomobject]@{SupervisorReady=$true;TrayReady=([string]$RuntimeId-ceq[string]$OldRuntime)}}.GetNewClosure()} },
        [pscustomobject]@{ Name='rollback readiness failure';Code='CCOD_INSTALL_ROLLBACK_FAILED';Committed=$true;Configure={param($Fake,$OldRuntime)$Fake.World.NewSupervisorReady=$false} }
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
            & $case.Configure $fake $first.RuntimeId

            $failure = $null
            try { Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $fake.Adapters | Out-Null } catch { $failure = $_ }
            Assert-CcodTrue ($null -ne $failure) "$($case.Name) fails closed"
            Assert-CcodTrue ($failure.FullyQualifiedErrorId -like "$($case.Code)*") "$($case.Name) returns its stable support code (actual=$($failure.FullyQualifiedErrorId); calls=$($fake.World.Calls -join ','))"
            $failedReceipts = @(Get-ChildItem -LiteralPath (Join-Path $install 'state\activation-receipts') -Filter '*.Failed.json' -File | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json })
            Assert-CcodEqual 1 $failedReceipts.Count "$($case.Name) writes one create-only Failed receipt"
            $activation = $failedReceipts[0]
            Assert-CcodEqual 'Failed' $activation.phase "$($case.Name) writes Failed"
            Assert-CcodEqual $false $activation.ready "$($case.Name) never writes Ready"
            Assert-CcodEqual $case.Code $activation.errorCode "$($case.Name) persists the stable code"
            $failedTransactions = @(Get-ChildItem -LiteralPath (Join-Path $install 'state\install-transactions') -Filter '*.Failed.*.json' -File | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } | Where-Object { [string]$_.newRuntimeId -cne [string]$first.RuntimeId })
            Assert-CcodEqual 1 $failedTransactions.Count "$($case.Name) writes one terminal transaction snapshot"
            Assert-CcodEqual $case.Code $failedTransactions[0].errorCode "$($case.Name) binds the transaction head to the stable code"

            $pointer = Read-CcodLifecycleActivePointer -Root $install
            $runtimeIds = @(Get-ChildItem -LiteralPath (Join-Path $install 'runtime') -Directory | ForEach-Object Name)
            Assert-CcodEqual 2 $runtimeIds.Count "$($case.Name) retains old and failed generations"
            if ($case.Committed) {
                Assert-CcodEqual $first.RuntimeId $pointer.activeRuntime "$($case.Name) appends a compensating pointer to the retained old runtime"
                Assert-CcodTrue ([uint64]$pointer.generation -ge 3) "$($case.Name) compensation advances rather than regresses the generation"
            } else {
                Assert-CcodEqual $first.RuntimeId $pointer.activeRuntime "$($case.Name) leaves the old pointer active before mutation"
                Assert-CcodEqual 1 ([uint64]$pointer.generation) "$($case.Name) does not append a pre-pointer compensation"
            }
        } finally {
            foreach ($path in @($source, $install, $nodeRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
        }
    }
}

$results += Invoke-CcodTest 'compensation refuses a replaced old manifest using the transaction-recorded hash' {
    $source=New-CcodLifecycleTempRoot;$install=New-CcodLifecycleTempRoot;$nodeRoot=New-CcodLifecycleTempRoot
    try{New-CcodLifecycleSourceFixture -Root $source -Version '2.5.22-old-manifest'|Out-Null;$node=New-CcodLifecycleFakeNode -Root $nodeRoot;$first=Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters (New-CcodLifecycleFake -NodePath $node).Adapters;Set-CcodLifecycleTestStatus -InstallRoot $install -RuntimeId $first.RuntimeId;[IO.File]::WriteAllText((Join-Path $source 'src\runtime\main-payload.js'),"module.exports='upgrade';`n",[Text.UTF8Encoding]::new($false));$oldManifest=Join-Path $install "runtime\$($first.RuntimeId)\manifest.json";$fake=New-CcodLifecycleFake -NodePath $node;$changed=[pscustomobject]@{Done=$false};$fake.Adapters.WaitNewRuntimeReady={param($Root,$Runtime,$Generation,$Identity,$Started,$Timeout)if(-not$changed.Done){$changed.Done=$true;[IO.File]::SetAttributes($oldManifest,[IO.FileAttributes]::Normal);[IO.File]::AppendAllText($oldManifest,' ',[Text.UTF8Encoding]::new($false))};[pscustomobject]@{SupervisorReady=$false;TrayReady=$false}}.GetNewClosure();Assert-CcodThrows {Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $fake.Adapters|Out-Null} 'CCOD_INSTALL_ROLLBACK_FAILED';$pointer=Read-CcodActiveRuntime -InstallRoot $install;Assert-CcodTrue ($pointer.activeRuntime-cne$first.RuntimeId) 'replaced old manifest cannot receive a compensating pointer';Assert-CcodEqual 2 $pointer.generation 'failed old-manifest proof leaves the committed new pointer generation';Assert-CcodEqual 2 @(Get-ChildItem -LiteralPath (Join-Path $install 'runtime') -Directory).Count 'both generations remain retained'}finally{foreach($p in @($source,$install,$nodeRoot)){if(Test-Path $p){Remove-Item $p -Recurse -Force}}}
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
        $fake.Adapters.WriteActivationReceipt={param($Root,$Receipt,$FileTransaction)$fake.World.Calls.Add("Receipt:$($Receipt.phase)");&$originalWriter $Root $Receipt $FileTransaction}.GetNewClosure()
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

# Production mutation caught: physically deleting retained generations after readiness.
$results += Invoke-CcodTest 'old and unknown runtime generations remain retained after Ready and failure' {
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
        Assert-CcodTrue (Test-Path -LiteralPath $orphan -PathType Container) 'Ready retains unknown runtime directories for separate maintenance'

        Set-CcodLifecycleTestStatus -InstallRoot $install -RuntimeId $second.RuntimeId
        $orphanAfterFailure=Join-Path $install 'runtime\superseded-after-failure';[IO.Directory]::CreateDirectory($orphanAfterFailure)|Out-Null
        [IO.File]::WriteAllText((Join-Path $source 'src\runtime\main-payload.js'),"module.exports='cleanup-timeout';`n",[Text.UTF8Encoding]::new($false))
        $blocked=New-CcodLifecycleFake -NodePath $nodePath;$blocked.World.NewTrayReady=$false
        Assert-CcodThrows {Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $blocked.Adapters|Out-Null} 'CCOD_INSTALL_ROLLBACK_FAILED'
        Assert-CcodTrue (Test-Path -LiteralPath $orphanAfterFailure -PathType Container) 'readiness failure never performs old-runtime cleanup'
    }finally{foreach($path in @($source,$install,$nodeRoot)){if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Recurse -Force}}}
}

# Production mutation caught: allowing a best-effort post-Ready cleanup exception to enter activation failure handling and overwrite the terminal Ready receipt.
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
        $activation=@(Get-ChildItem -LiteralPath (Join-Path $install 'state\activation-receipts') -Filter '*.Ready.json' -File|ForEach-Object{Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8|ConvertFrom-Json}|Where-Object{$_.runtimeId-ceq$second.RuntimeId})[0]
        Assert-CcodEqual 'Ready' $activation.phase 'post-Ready log failure cannot overwrite Ready'
        Assert-CcodEqual $true $activation.ready 'post-Ready log failure preserves successful readiness'
        Assert-CcodTrue (Test-Path -LiteralPath (Join-Path $install "runtime\$($first.RuntimeId)") -PathType Container) 'post-Ready log failure retains the previous runtime'
        Assert-CcodEqual 1 @($fake.World.LogRecords|Where-Object{$_.code-ceq'CCOD_INSTALL_POST_READY_LOG_FAILED'}).Count 'post-Ready log failure emits one bounded fallback diagnostic'
    } finally {foreach($path in @($source,$install,$nodeRoot)){if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Recurse -Force}}}
}

# Production mutation caught: starting the task or waiting for its Supervisor while retaining install/lifecycle mutex ownership that blocks bootstrap launch.
$results += Invoke-CcodTest 'upgrade releases generation ownership before starting and waiting for task-created readiness' {
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
        Assert-CcodTrue ($ownershipExit-ge0-and$installExit-gt$ownershipExit-and$startIndex-gt$installExit-and$readyIndex-gt$startIndex) 'ownership fully releases before task starts, then readiness polling begins'
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

$results += Invoke-CcodTest 'sealed-source copy failure retains the candidate and leaves pointer and legacy shells unchanged' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    $lockHolder = [pscustomobject]@{Stream=$null}
    try {
        New-CcodLifecycleSourceFixture -Root $source -Version '2.5.22' | Out-Null
        $manifestPath=New-CcodLifecyclePayloadManifest -Root $source -Version '2.5.22';$payloadBinding=Get-CcodLifecyclePayloadBinding -ManifestPath $manifestPath -ExpectedVersion '2.5.22'
        [IO.Directory]::CreateDirectory($install) | Out-Null
        $legacyBootstrap=Join-Path $install 'bootstrap.ps1';$legacyUninstaller=Join-Path $install 'Uninstall-CodexControlOtherDevices.ps1'
        [IO.File]::WriteAllText($legacyBootstrap,'legacy-bootstrap',[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText($legacyUninstaller,'legacy-uninstaller',[Text.UTF8Encoding]::new($false))
        $bootstrapHash=Get-CcodTestFileSha256 $legacyBootstrap;$uninstallerHash=Get-CcodTestFileSha256 $legacyUninstaller
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        $fake = New-CcodLifecycleFake -NodePath $nodePath
        $fake.Adapters.ValidateSource={param($Root)$lockHolder.Stream=[IO.File]::Open((Join-Path $Root 'src\persistence\Supervisor.ps1'),[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None);$true}.GetNewClosure()
        $failure=$null;try{Invoke-CcodInstall -SourceRoot $source -InstallRoot $install @payloadBinding -Adapters $fake.Adapters|Out-Null}catch{$failure=$_}
        Assert-CcodTrue ($null-ne$failure) 'sealed source lock fails the immutable copy'
        Assert-CcodTrue ($failure.FullyQualifiedErrorId-like'CCOD_INSTALL_*') 'sealed source copy failure is bounded'
        Assert-CcodEqual $false (Test-Path -LiteralPath (Join-Path $install 'active.json')) 'sealed source failure never writes legacy active pointer'
        Assert-CcodEqual $false (Test-Path -LiteralPath (Join-Path $install 'state\active-generation')) 'sealed source failure occurs before append-only pointer commit'
        Assert-CcodEqual $bootstrapHash (Get-CcodTestFileSha256 $legacyBootstrap) 'sealed source failure leaves legacy bootstrap bytes unchanged'
        Assert-CcodEqual $uninstallerHash (Get-CcodTestFileSha256 $legacyUninstaller) 'sealed source failure leaves legacy uninstaller bytes unchanged'
        Assert-CcodEqual 1 @(Get-ChildItem -LiteralPath (Join-Path $install 'runtime') -Directory -ErrorAction SilentlyContinue).Count 'failed immutable candidate is retained for diagnosis'
    } finally {
        if($null-ne$lockHolder.Stream){$lockHolder.Stream.Dispose()}
        foreach ($path in @($source, $install, $nodeRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

$results += Invoke-CcodTest 'final transaction snapshot failure leaves Ready receipt and recoverable nonterminal without Failed ambiguity' {
    $source=New-CcodLifecycleTempRoot;$install=New-CcodLifecycleTempRoot;$nodeRoot=New-CcodLifecycleTempRoot
    try{New-CcodLifecycleSourceFixture -Root $source -Version '2.5.22-final-gap'|Out-Null;$node=New-CcodLifecycleFakeNode -Root $nodeRoot;$fake=New-CcodLifecycleFake -NodePath $node;$fake.Adapters.CommitReadyTransaction={throw 'PRIVATE_FINAL_SNAPSHOT_FAILURE'};$failure=$null;try{Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $fake.Adapters|Out-Null}catch{$failure=$_};Assert-CcodTrue ($failure.FullyQualifiedErrorId-like'CCOD_INSTALL_READY_FINALIZATION_PENDING*') 'final snapshot failure reports recoverable pending status';$ready=@(Get-ChildItem -LiteralPath (Join-Path $install 'state\activation-receipts') -Filter '*.Ready.json' -File);$failed=@(Get-ChildItem -LiteralPath (Join-Path $install 'state\activation-receipts') -Filter '*.Failed.json' -File);Assert-CcodEqual 1 $ready.Count 'Ready activation receipt remains visible exactly once';Assert-CcodEqual 0 $failed.Count 'no contradictory Failed activation receipt is appended';$transactionFailed=@(Get-ChildItem -LiteralPath (Join-Path $install 'state\install-transactions') -Filter '*.Failed.*.json' -File);$transactionReady=@(Get-ChildItem -LiteralPath (Join-Path $install 'state\install-transactions') -Filter '*.Ready.*.json' -File);Assert-CcodEqual 0 $transactionFailed.Count 'no Failed transaction snapshot follows Ready receipt';Assert-CcodEqual 0 $transactionReady.Count 'missing final transaction snapshot remains absent for recovery';$module=Get-Module InstallLifecycle;$head=&$module {param($Root)Read-CcodInstallTransactionRecord -InstallRoot $Root} $install;Assert-CcodEqual 'ProtectionReady' $head.phase 'transaction remains recoverable at ProtectionReady'}finally{foreach($p in @($source,$install,$nodeRoot)){if(Test-Path $p){Remove-Item $p -Recurse -Force}}}
}

# Production mutation caught: treating every nonterminal transaction as permanently busy instead of finalizing an already-proven Ready activation.
$results += Invoke-CcodTest 'a later invocation recovers one missing Ready transaction snapshot without another install mutation' {
    $fixture=New-CcodReadyFinalizationGapFixture
    try {
        $runtimeCount=@(Get-ChildItem -LiteralPath (Join-Path $fixture.Install 'runtime') -Directory -Force).Count
        $pointerCount=@(Get-ChildItem -LiteralPath (Join-Path $fixture.Install 'state\active-generation') -File -Force).Count
        Remove-Item -LiteralPath $fixture.Source -Recurse -Force
        $recoveryFake=New-CcodLifecycleFake -NodePath $fixture.Node
        $result=Invoke-CcodInstall -SourceRoot $fixture.Source -InstallRoot $fixture.Install -Adapters $recoveryFake.Adapters
        Assert-CcodEqual 'Recovered' $result.Outcome 'finalization recovery reports a bounded recovered outcome'
        Assert-CcodEqual 1 $recoveryFake.World.ProductRegistrationCalls 'Ready-finalization recovery completes post-Ready product registration exactly once'
        Assert-CcodEqual $fixture.Transaction.newRuntimeId $result.RuntimeId 'recovery result binds the pending transaction runtime'
        Assert-CcodEqual $runtimeCount @(Get-ChildItem -LiteralPath (Join-Path $fixture.Install 'runtime') -Directory -Force).Count 'recovery creates no runtime generation'
        Assert-CcodEqual $pointerCount @(Get-ChildItem -LiteralPath (Join-Path $fixture.Install 'state\active-generation') -File -Force).Count 'recovery appends no active pointer'
        Assert-CcodEqual 1 @(Get-ChildItem -LiteralPath (Join-Path $fixture.Install 'state\install-transactions') -Filter '*.Ready.*.json' -File -Force).Count 'recovery appends exactly one Ready transaction snapshot'
        Assert-CcodEqual 0 @(Get-ChildItem -LiteralPath (Join-Path $fixture.Install 'state\install-transactions') -Filter '*.Failed.*.json' -File -Force).Count 'recovery appends no Failed transaction snapshot'
        Assert-CcodEqual 0 @(Get-ChildItem -LiteralPath (Join-Path $fixture.Install 'state\activation-receipts') -Filter '*.Failed.json' -File -Force).Count 'recovery appends no Failed activation receipt'
        $module=Get-Module InstallLifecycle -ErrorAction Stop
        $head=&$module {param($Root,$Id)Read-CcodInstallTransactionRecord -InstallRoot $Root -TransactionId $Id} $fixture.Install $fixture.Transaction.transactionId
        Assert-CcodEqual 'Ready' $head.phase 'the original transaction alone becomes terminal Ready'
        Assert-CcodEqual 0 $recoveryFake.World.TaskInstalled 'recovery does not reinstall the scheduled task'
        Assert-CcodEqual 0 $recoveryFake.World.TaskStarted 'recovery does not restart the product'
        Assert-CcodEqual 0 @($recoveryFake.World.Calls|Where-Object{$_-like'Validate:*'}).Count 'state-only recovery does not depend on the vanished source checkout'
    } finally { Remove-CcodReadyFinalizationGapFixture $fixture }
}

$results += Invoke-CcodTest 'registration failure during Ready-finalization recovery is retried by a later same-package invocation' {
    $fixture=New-CcodReadyFinalizationGapFixture
    try{
        Remove-Item -LiteralPath $fixture.Source -Recurse -Force
        $failed=New-CcodLifecycleFake -NodePath $fixture.Node;$failed.World.ProductRegistrationFailure=$true
        Assert-CcodThrows {Invoke-CcodInstall -SourceRoot $fixture.Source -InstallRoot $fixture.Install -Adapters $failed.Adapters|Out-Null} 'CCOD_PRODUCT_REGISTRATION_FAILED'
        $module=Get-Module InstallLifecycle;$ready=&$module {param($Root,$Id)Read-CcodInstallTransactionRecord -InstallRoot $Root -TransactionId $Id} $fixture.Install $fixture.Transaction.transactionId
        Assert-CcodEqual 'Ready' $ready.phase 'recovery registration failure leaves the recovered transaction Ready'
        New-CcodLifecycleSourceFixture -Root $fixture.Source -Version '2.5.22'|Out-Null
        $retry=New-CcodLifecycleFake -NodePath $fixture.Node
        $result=Invoke-CcodInstall -SourceRoot $fixture.Source -InstallRoot $fixture.Install -SealedPackageSha256 ([string]$ready.sealedPackageSha256) -Adapters $retry.Adapters
        Assert-CcodEqual 'AlreadyInstalled' $result.Outcome 'same-package invocation reconciles registration after recovery failure'
        Assert-CcodEqual 1 $retry.World.ProductRegistrationCalls 'recovery registration retry occurs exactly once'
    }finally{foreach($path in @($fixture.Source,$fixture.Install,$fixture.NodeRoot)){if(Test-Path $path){Remove-Item $path -Recurse -Force}}}
}

# Production mutation caught: finalizing ProtectionReady when any receipt, selected pointer, or recorded manifest proof no longer matches.
$results += Invoke-CcodTest 'invalid Ready receipt pointer or manifest leaves ProtectionReady without runtime pointer or Failed writes' {
    $fixture=New-CcodReadyFinalizationGapFixture
    $caseRoots=[Collections.Generic.List[string]]::new()
    try {
        Remove-Item -LiteralPath $fixture.Source -Recurse -Force
        foreach($case in @(
            @{Name='receipt';Mutate={param($Root,$Transaction)$path=@(Get-ChildItem -LiteralPath (Join-Path $Root 'state\activation-receipts') -Filter '*.Ready.json' -File)[0].FullName;[IO.File]::SetAttributes($path,[IO.FileAttributes]::Normal);[IO.File]::WriteAllText($path,'{',[Text.UTF8Encoding]::new($false))}},
            @{Name='pointer';Mutate={param($Root,$Transaction)$path=@(Get-ChildItem -LiteralPath (Join-Path $Root 'state\active-generation') -Filter '*.json' -File|Sort-Object Name)[-1].FullName;$record=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json;$replacement=if($record.activeRuntime.EndsWith('0')){'1'}else{'0'};$record.activeRuntime=$record.activeRuntime.Substring(0,$record.activeRuntime.Length-1)+$replacement;[IO.File]::SetAttributes($path,[IO.FileAttributes]::Normal);[IO.File]::WriteAllText($path,($record|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))}},
            @{Name='manifest';Mutate={param($Root,$Transaction)$path=Join-Path $Root "runtime\$($Transaction.newRuntimeId)\manifest.json";[IO.File]::SetAttributes($path,[IO.FileAttributes]::Normal);[IO.File]::AppendAllText($path,"`n",[Text.UTF8Encoding]::new($false))}}
        )) {
            $caseRoot=New-CcodLifecycleTempRoot
            $caseRoots.Add($caseRoot)
            Copy-Item -LiteralPath $fixture.Install -Destination $caseRoot -Recurse -Force
            $runtimeCount=@(Get-ChildItem -LiteralPath (Join-Path $caseRoot 'runtime') -Directory -Force).Count
            $pointerCount=@(Get-ChildItem -LiteralPath (Join-Path $caseRoot 'state\active-generation') -File -Force).Count
            & $case.Mutate $caseRoot $fixture.Transaction
            $failure=$null
            try { Invoke-CcodInstall -SourceRoot $fixture.Source -InstallRoot $caseRoot -Adapters (New-CcodLifecycleFake -NodePath $fixture.Node).Adapters | Out-Null } catch { $failure=$_ }
            Assert-CcodTrue ($null-ne$failure-and$failure.FullyQualifiedErrorId-like'CCOD_INSTALL_READY_RECOVERY_INVALID*') "$($case.Name) mismatch fails the bounded recovery contract"
            Assert-CcodEqual $runtimeCount @(Get-ChildItem -LiteralPath (Join-Path $caseRoot 'runtime') -Directory -Force).Count "$($case.Name) mismatch creates no runtime generation"
            Assert-CcodEqual $pointerCount @(Get-ChildItem -LiteralPath (Join-Path $caseRoot 'state\active-generation') -File -Force).Count "$($case.Name) mismatch appends no active pointer"
            Assert-CcodEqual 0 @(Get-ChildItem -LiteralPath (Join-Path $caseRoot 'state\install-transactions') -Filter '*.Ready.*.json' -File -Force).Count "$($case.Name) mismatch appends no Ready transaction snapshot"
            Assert-CcodEqual 0 @(Get-ChildItem -LiteralPath (Join-Path $caseRoot 'state\install-transactions') -Filter '*.Failed.*.json' -File -Force).Count "$($case.Name) mismatch appends no Failed transaction snapshot"
            Assert-CcodEqual 0 @(Get-ChildItem -LiteralPath (Join-Path $caseRoot 'state\activation-receipts') -Filter '*.Failed.json' -File -Force).Count "$($case.Name) mismatch appends no Failed activation receipt"
            $module=Get-Module InstallLifecycle -ErrorAction Stop
            $head=&$module {param($Root,$Id)Read-CcodInstallTransactionRecord -InstallRoot $Root -TransactionId $Id} $caseRoot $fixture.Transaction.transactionId
            Assert-CcodEqual 'ProtectionReady' $head.phase "$($case.Name) mismatch remains recoverable and nonterminal"
        }
    } finally {
        foreach($caseRoot in $caseRoots){if(Test-Path -LiteralPath $caseRoot){Remove-Item -LiteralPath $caseRoot -Recurse -Force}}
        Remove-CcodReadyFinalizationGapFixture $fixture
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
        [IO.File]::WriteAllText((Join-Path $install 'state\active-generation\00000000000000000002.json'), '{"schemaVersion":9,"generation":2,"activeRuntime":"x","previousGeneration":1}', [Text.UTF8Encoding]::new($false))
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

$results += Invoke-CcodTest 'upgrade fails closed on malformed UI baseline while repair preserves its bytes' {
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
        Assert-CcodThrows {Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters (New-CcodLifecycleFake -NodePath $nodePath).Adapters|Out-Null} 'CCOD_STATE_MALFORMED'
        Assert-CcodEqual $first.RuntimeId (Read-CcodActiveRuntime -InstallRoot $install).activeRuntime 'malformed UI baseline cannot advance the active pointer'
        Assert-CcodEqual '007bff130a' (([IO.File]::ReadAllBytes($preferencePath) | ForEach-Object { $_.ToString('x2') }) -join '') 'failed upgrade preserves malformed UI preference bytes'
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

$results += Invoke-CcodTest 'legacy missing UI preference is safely materialized during upgrade' {
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
        Assert-CcodTrue (Test-Path -LiteralPath $preferencePath -PathType Leaf) 'legacy missing preference is materialized from the upgrade baseline'
        $preference = Read-CcodUiPreference -StateRoot $stateRoot
        Assert-CcodEqual 'System' $preference.LanguageMode 'legacy missing preference follows Windows'
        Assert-CcodEqual $false $preference.FallbackUsed 'materialized preference no longer requires fallback'
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

$results += Invoke-CcodTest 'portable release keeps the fail-closed bootstrap handoff outside the installer root' {
    $innoPath = Join-Path $repositoryRoot 'build\CodexControlOtherDevices.iss'
    $wrapperPath = Join-Path $repositoryRoot 'Uninstall-CodexControlOtherDevices.ps1'
    $finalizerPath = Join-Path $repositoryRoot 'src\persistence\PortableUninstallFinalizer.ps1'
    $portableModulePath = Join-Path $repositoryRoot 'src\persistence\modules\PortableRelease.psm1'
    $inno = Get-Content -LiteralPath $innoPath -Raw
    $wrapper = Get-Content -LiteralPath $wrapperPath -Raw
    Assert-CcodTrue ($inno -notmatch '(?m)^\s*\[UninstallRun\]') 'Inno has no legacy pre-delete UninstallRun route'
    Assert-CcodTrue ($inno -match '(?m)^Uninstallable=no\s*$' -and $inno -notmatch 'InitializeUninstall|CurUninstallStepChanged|UninstallBootstrap\.ps1') 'sealed Setup creates no pre-Ready Inno uninstall surface'
    Assert-CcodTrue ($inno -notmatch 'BackupDeviceKeyStore|RemoveDeviceKeyStore|KeepCurrentSpecialSession') 'Inno exposes no key or special-session uninstall options'
    Assert-CcodTrue (Test-Path -LiteralPath $finalizerPath -PathType Leaf) 'portable release includes an external finalizer'
    Assert-CcodTrue (Test-Path -LiteralPath $portableModulePath -PathType Leaf) 'portable release includes a marker-bound removal module'
    Assert-CcodTrue ($wrapper -match 'PortableUninstallFinalizer\.ps1' -and $wrapper -match '-Mode\s+Prepare') 'public wrapper prepares protected cleanup before launching the external portable finalizer'
    Assert-CcodTrue ($wrapper -match 'Start-Process' -and $wrapper -match 'portable-finalizer\.stderr\.log') 'public wrapper delegates final deletion to a detached external process with auditable output'
    Assert-CcodTrue ($wrapper -notmatch 'Remove-Item') 'public wrapper cannot delete the portable installer root directly'
    Assert-CcodTrue ((Get-Content -LiteralPath $finalizerPath -Raw) -match 'Remove-CcodPortableInstallerRoot') 'external finalizer owns the bound portable root deletion'
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

$results += Invoke-CcodTest 'fallback accepts generation parent and rejects root parent when append-only selector exists' {
    $install=New-CcodLifecycleTempRoot
    try{$identity=New-CcodLifecycleIdentity;[IO.Directory]::CreateDirectory($install)|Out-Null;$runtimeId='2.5.22-1111111111111111-22222222222222222222222222222222';$runtimeRoot=Join-Path $install "runtime\$runtimeId";$supervisor=Join-Path $runtimeRoot 'src\persistence\Supervisor.ps1';$generationBootstrap=Join-Path $runtimeRoot 'src\persistence\bootstrap.ps1';[IO.Directory]::CreateDirectory((Split-Path $supervisor -Parent))|Out-Null;[IO.File]::WriteAllText($generationBootstrap,'# generation',[Text.UTF8Encoding]::new($false));$pointerRoot=Join-Path $install 'state\active-generation';[IO.Directory]::CreateDirectory($pointerRoot)|Out-Null;[IO.File]::WriteAllText((Join-Path $pointerRoot '00000000000000000001.json'),('{"schemaVersion":1,"generation":1,"activeRuntime":"'+$runtimeId+'","previousGeneration":0}'),[Text.UTF8Encoding]::new($false));$parent=[pscustomobject]@{ProcessId=96;ParentProcessId=1;SessionId=$identity.SessionId;CreationDate=[DateTime]::Parse('2030-02-03T02:59:59Z').ToUniversalTime();CommandLine="powershell.exe -File `"$generationBootstrap`" -InstallRoot `"$install`""};$child=[pscustomobject]@{ProcessId=97;ParentProcessId=96;SessionId=$identity.SessionId;CreationDate=[DateTime]::Parse('2030-02-03T03:00:00Z').ToUniversalTime();CommandLine="powershell.exe -File `"$supervisor`" -ReadyToken $('a'*64)"};$module=Get-Module InstallLifecycle;$accepted=&$module {param($Root,$Current,$Items)Get-CcodLifecycleVerifiedSupervisorFallback -InstallRoot $Root -Identity $Current -ProcessEnumerator {param($Ignored)$Items} -OwnerSidResolver {param($P)[pscustomobject]@{ReturnValue=0;Sid=$Current.UserSid}}} $install $identity @($parent,$child);Assert-CcodEqual 97 $accepted.Pid 'append-only task accepts exact same-generation bootstrap parent';$rootBootstrap=Join-Path $install 'bootstrap.ps1';[IO.File]::WriteAllText($rootBootstrap,'# legacy',[Text.UTF8Encoding]::new($false));$parent.CommandLine="powershell.exe -File `"$rootBootstrap`" -InstallRoot `"$install`"";$rejected=&$module {param($Root,$Current,$Items)Get-CcodLifecycleVerifiedSupervisorFallback -InstallRoot $Root -Identity $Current -ProcessEnumerator {param($Ignored)$Items} -OwnerSidResolver {param($P)[pscustomobject]@{ReturnValue=0;Sid=$Current.UserSid}}} $install $identity @($parent,$child);Assert-CcodTrue ($null-eq$rejected) 'append-only selector rejects legacy root bootstrap parent'}finally{if(Test-Path $install){Remove-Item $install -Recurse -Force}}
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

$results += Invoke-CcodTest 'sealed installer defers every desktop and Start menu entry until post-Ready registration' {
    $installerScript = Join-Path $repositoryRoot 'build\CodexControlOtherDevices.iss'
    $content = Get-Content -LiteralPath $installerScript -Raw
    Assert-CcodEqual 0 @(Get-Content -LiteralPath $installerScript | Where-Object { $_ -cmatch '^Name: "\{(userdesktop|group)\}\\' }).Count 'Task 3 defines no user-visible shortcut entry'
    Assert-CcodTrue ($content -cnotmatch '(?m)^\[Icons\]\s*$|\{userdesktop\}|\{group\}') 'no shortcut destination is reachable before strict Ready'
}

$results += Invoke-CcodTest 'installer exposes CodexRemote-fix as the searchable primary bootstrap entry' {
    $installerScript = Join-Path $repositoryRoot 'build\CodexControlOtherDevices.iss'
    $content = Get-Content -LiteralPath $installerScript -Raw
    $lines = @(Get-Content -LiteralPath $installerScript)

    Assert-CcodTrue ($lines -ccontains 'AppId={{2B9E9F2E-7A32-4A7E-9C1D-9F5B5C6D7E8F}') 'installer retains the v2.1.6 AppId for in-place upgrades'
    Assert-CcodTrue ($lines -ccontains 'AppName=CodexRemote-fix') 'installed app has the public CodexRemote-fix name'
    Assert-CcodTrue ($lines -ccontains 'AppVerName=CodexRemote-fix {#ProjectVersion}') 'installed app version has the public CodexRemote-fix name'
    Assert-CcodTrue ($lines -ccontains 'SetupIconFile=..\assets\codexremote-fix\codexremote-fix.ico') 'setup uses the CodexRemote-fix icon'
    Assert-CcodTrue ($lines -ccontains 'OutputBaseFilename=CodexRemote-fix-{#ProjectVersion}-setup') 'build output uses the public release name'
    Assert-CcodTrue ($lines -ccontains 'CreateAppDir=no' -and $lines -ccontains 'Uninstallable=no') 'Task 3 Setup has no product registration surface before Ready'
    Assert-CcodTrue ($content -cnotmatch '(?m)^\[(Icons|Registry|UninstallRun)\]\s*$|DefaultGroupName=|UninstallDisplayIcon=') 'shortcuts registry and uninstall registration remain deferred to Task 4'
    Assert-CcodEqual 4 @($lines | Where-Object { $_ -cmatch '^Source: .*Flags: dontcopy$' }).Count 'Setup carries only four sealed temporary inputs'

    $buildScript = Get-Content -LiteralPath (Join-Path $repositoryRoot 'build\build.ps1') -Raw
    Assert-CcodTrue ($buildScript -cmatch 'CodexRemote-fix-\$Version-windows-x64\.zip') 'build script locates the public portable ZIP filename'
    Assert-CcodTrue ($buildScript -cmatch '\$bundle\.sha256\.txt') 'build script writes a hash beside the public portable ZIP filename'
}

$results += Invoke-CcodTest 'portable builder publishes the exact CodexRemote-fix 2.5.22 release artifact contract' {
    $package = Get-Content -LiteralPath (Join-Path $repositoryRoot 'package.json') -Raw | ConvertFrom-Json
    Assert-CcodEqual '2.5.22' ([string]$package.version) 'package version is exactly 2.5.22'

    $buildScript = Get-Content -LiteralPath (Join-Path $repositoryRoot 'build\build.ps1') -Raw
    Assert-CcodTrue ($buildScript -cmatch 'CodexRemote-fix-\$Version-windows-x64\.zip') 'portable build resolves the exact public ZIP filename'
    Assert-CcodTrue ($buildScript -cmatch 'CodexRemote-fix-\$Version-payload-manifest\.json') 'portable build publishes a separately bound payload manifest'
    Assert-CcodTrue ($buildScript -cmatch 'schemaVersion = 2') 'portable build writes a schema-two release manifest'
    Assert-CcodTrue ($buildScript -cmatch "distribution = 'portable-zip'") 'portable build labels the release distribution explicitly'
}

# Production mutation caught: trusting the activation owner exit without a separate strict receipt validation.
$results += Invoke-CcodTest 'installer accepts success only from the exited owner plus a bounded strict validator child' {
    $installerScript = Get-Content -LiteralPath (Join-Path $repositoryRoot 'build\CodexControlOtherDevices.iss') -Raw -Encoding UTF8
    $activationWorker = Get-Content -LiteralPath (Join-Path $repositoryRoot 'Activate-CcodRemoteFix.ps1') -Raw -Encoding UTF8
    $activationScript = Join-Path $repositoryRoot 'Activate-CcodRemoteFix.ps1'
    Assert-CcodTrue (Test-Path -LiteralPath $activationScript -PathType Leaf) 'post-install activation worker exists'
    Assert-CcodTrue ($installerScript -cmatch '(?m)^CloseApplications=no\r?$') 'installer never lets Restart Manager close Codex'
    Assert-CcodTrue ($installerScript -cmatch 'ActivationBootstrapPath' -and $installerScript -cmatch 'Flags: dontcopy') 'installer embeds the activation worker only as a temporary sealed input'
    Assert-CcodTrue ($installerScript -cmatch '(?s)function PrepareToInstall.*ExtractAndLockCcodInputs\(\).*procedure CurStepChanged.*GetArrayLength\(CcodInputHandles\) <> 3.*GetCcodBootstrapParameters\(ActivationId, False\).*ewWaitUntilTerminated, ActivationResultCode') 'installer locks inputs before waiting for the exact owner to exit'
    Assert-CcodTrue ($installerScript -cmatch '(?s)ActivationResultCode <> 0.*RaiseException.*GetCcodBootstrapParameters\(ActivationId, True\).*ewWaitUntilTerminated, ValidationResultCode') 'only a normal owner exit reaches the strict one-shot validator'
    Assert-CcodTrue ($installerScript -cmatch 'ProgressGauge\.Position := 100' -and $installerScript -cnotmatch 'Prompt-CcodRestart\.ps1') 'strict validation alone reaches completion while Task 4 registration and prompting stay absent'
    Assert-CcodTrue ($installerScript -cmatch '\(ValidationResultCode <> 0\) then RaiseException\(.CCOD_SETUP_READY_VALIDATION_FAILED.' ) 'every nonzero validator result fails closed'
    Assert-CcodTrue ($installerScript -cnotmatch '(?s)Activate-CcodRemoteFix\.ps1[^;]*-Prompt') 'background activation worker never owns the prompt'
    Assert-CcodTrue ($activationWorker -cmatch '(?s)if \(\$ValidateReceiptOnly\).*Read-CcodTerminalActivationReceipt.*phase -ceq .Ready.*exit 0.*phase -ceq .Failed.*exit 2' -and $activationWorker -cnotmatch 'ValidationResultPath|ValidationId|Start-Sleep') 'inner validator is a one-shot strict receipt reader with only direct terminal exit codes'
    Assert-CcodTrue ($installerScript -cnotmatch 'ValidationResultPath|ReadValidationResultState|post-install-activation\.validation') 'Inno never accepts a file sidecar as validator authority'
    Assert-CcodTrue ($installerScript -cnotmatch 'Prepare-CcodRemoteUpgrade\.ps1') 'installer does not pre-stop the supervisor outside the gated runtime activation transaction'
    Assert-CcodTrue ($installerScript -cnotmatch '(?ms)^\[Run\]\s*\r?\nFilename: "powershell\.exe"; Parameters: ".*Install-CodexControlOtherDevices\.ps1') 'installer does not silently ignore its runtime installer exit code through a Run entry'
}

# Production mutation caught: releasing an unowned worker, reopening a PID, or accepting an unauthenticated sidecar.
$results += Invoke-CcodTest 'installer waits for its process owner and accepts terminal status only from its strict validator child' {
    $installerScript = Get-Content -LiteralPath (Join-Path $repositoryRoot 'build\CodexControlOtherDevices.iss') -Raw -Encoding UTF8
    Assert-CcodTrue ($installerScript -cmatch 'CoCreateGuid@ole32\.dll' -and $installerScript -cmatch 'StringFromGUID2@ole32\.dll') 'installer generates a canonical activation GUID before worker launch'
    Assert-CcodTrue ($installerScript -cmatch '(?s)ActivationId\s*:=\s*NewActivationId\(\).*GetCcodBootstrapParameters\(ActivationId, False\).*GetCcodBootstrapParameters\(ActivationId, True\)' ) 'installer passes one fresh activation id to owner and validator without deleting append-only receipts'
    Assert-CcodTrue ($installerScript -cmatch 'ewWaitUntilTerminated, ActivationResultCode' -and $installerScript -cmatch 'ewWaitUntilTerminated, ValidationResultCode' -and $installerScript -cmatch '-ValidateReceiptOnly') 'Inno waits for both owner and strict validator exit codes'
    Assert-CcodTrue ($installerScript -cnotmatch 'ewNoWait') 'Inno never releases an unowned activation worker'
    foreach($forbidden in @('OpenProcess@kernel32.dll','WaitForSingleObject@kernel32.dll','GetExitCodeProcess@kernel32.dll','PROCESS_QUERY_INFORMATION','ProcessHandle := OpenProcess')){Assert-CcodTrue ($installerScript -cnotmatch [regex]::Escape($forbidden)) "installer never uses $forbidden to infer worker identity"}
    Assert-CcodTrue ($installerScript -cmatch '(?s)ActivationResultCode <> 0.*RaiseException.*GetCcodBootstrapParameters\(ActivationId, True\).*ValidationResultCode <> 0.*RaiseException') 'owner failure cannot reach validation and every nonzero validator result fails closed'
    Assert-CcodTrue ($installerScript -cnotmatch 'ReadActivationProgressPhase|LoadBoundedActivationReceipt') 'Inno delegates all receipt authority to the locked bootstrap'
    Assert-CcodTrue ($installerScript -cnotmatch 'ValidationResultPath|ReadValidationResultState|post-install-activation\.validation') 'no writable sidecar can impersonate the strict validator'
    Assert-CcodTrue ($installerScript -cnotmatch 'Prompt-CcodRestart\.ps1') 'Task 3 does not create a post-Ready product prompt or registration path'
}

# Production mutation caught: compiling a script with an unrecognized built-in identifier, or leaving the bounded validator route uncompiled.
$results += Invoke-CcodTest 'release builder creates a manifest-bound ZIP and an Inno setup installer' {
    $buildScript = Get-Content -LiteralPath (Join-Path $repositoryRoot 'build\build.ps1') -Raw
    Assert-CcodTrue ($buildScript -cmatch 'ZipFile\]::CreateFromDirectory') 'portable builder creates a ZIP through the platform archive API'
    Assert-CcodTrue ($buildScript -cmatch 'Test-CcodReleaseAssetManifest') 'portable builder validates its complete release contract before reporting success'
    Assert-CcodTrue ($buildScript -cmatch 'ISCC\.exe|Inno Setup|innosetup') 'release builder uses Inno Setup for the installer'
<#
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
#>
}

$results += Invoke-CcodTest 'activation terminal validator enforces the complete bounded correlated receipt contract' {
    # Production mutation caught: accepting reordered/extra fields, truthy booleans, stale ids, malformed runtime/error semantics, noncanonical times, or oversized JSON.
    $root=Join-Path ([IO.Path]::GetTempPath()) ('ccod-activation-validator-'+[guid]::NewGuid().ToString('N'))
    $reparseTarget=Join-Path ([IO.Path]::GetTempPath()) ('ccod-activation-validator-target-'+[guid]::NewGuid().ToString('N'))
    try{
        $receiptDirectory=Join-Path $root 'state\activation-receipts';[IO.Directory]::CreateDirectory($receiptDirectory)|Out-Null
        $activationId='77777777-6666-5555-4444-333333333333'
        $activationScript=Join-Path $repositoryRoot 'Activate-CcodRemoteFix.ps1';$powershellExecutable=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $invokeValidator={param([string]$ErrorPath)
            $outputPath="$ErrorPath.stdout"
            $argumentLine='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -AppRoot "{1}" -InstallRoot "{2}" -ActivationId "{3}" -ValidateReceiptOnly' -f $activationScript,$repositoryRoot,$root,$activationId
            $process=Start-Process -FilePath $powershellExecutable -ArgumentList $argumentLine -WindowStyle Hidden -RedirectStandardOutput $outputPath -RedirectStandardError $ErrorPath -Wait -PassThru
            try{$exitCode=[int]$process.ExitCode}finally{$process.Dispose()}
            $output=@();if((Test-Path -LiteralPath $outputPath)-and (Get-Item -LiteralPath $outputPath).Length-gt0){$output=@(Get-Content -LiteralPath $outputPath)}
            [pscustomobject]@{ExitCode=$exitCode;Stdout=$output}
        }
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
            Get-ChildItem -LiteralPath $receiptDirectory -File -Force -ErrorAction SilentlyContinue|Remove-Item -Force
            $receiptPath=Join-Path $receiptDirectory ("$activationId.$($receipt.phase).json")
            [IO.File]::WriteAllText($receiptPath,($receipt|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
            $stderrPath=Join-Path $root (('validator-{0}.err' -f ($case.Name-replace'[^A-Za-z0-9]','-')))
            $invocation=&$invokeValidator $stderrPath
            Assert-CcodEqual $case.Exit $invocation.ExitCode "$($case.Name) maps to the strict validator exit contract"
            Assert-CcodEqual 0 $invocation.Stdout.Count "$($case.Name) emits no receipt data to stdout"
            if($case.Exit-ne0-and$case.Exit-ne2){Assert-CcodTrue ((Get-Content -LiteralPath $stderrPath -Raw)-cmatch'CCOD_ACTIVATION_RECEIPT_') "$($case.Name) retains a bounded support code on stderr"}
        }
        $receiptPath=Join-Path $receiptDirectory "$activationId.Ready.json"
        [IO.File]::WriteAllText($receiptPath,'{"schemaVersion":1,"activationId":"77777777-6666-5555-4444-333333333333","phase":"Ready","runtimeId":"runtime-new"',[Text.UTF8Encoding]::new($false))
        $stderrPath=Join-Path $root 'validator-truncated.err';$invocation=&$invokeValidator $stderrPath
        Assert-CcodEqual 3 $invocation.ExitCode 'truncated Ready JSON is rejected by the executable validator'
        Assert-CcodEqual 0 $invocation.Stdout.Count 'truncated Ready JSON emits no receipt data to stdout'
        [IO.File]::WriteAllText($receiptPath,('{'+'"padding":"'+('x'*17000)+'"}'),[Text.UTF8Encoding]::new($false))
        $stderrPath=Join-Path $root 'validator-oversized.err';$invocation=&$invokeValidator $stderrPath
        Assert-CcodEqual 3 $invocation.ExitCode 'oversized receipt is refused before JSON parsing'
        Assert-CcodEqual 0 $invocation.Stdout.Count 'oversized receipt emits no data to stdout'
        Remove-Item -LiteralPath (Join-Path $root 'state') -Recurse -Force
        [IO.Directory]::CreateDirectory((Join-Path $reparseTarget 'activation-receipts'))|Out-Null
        [IO.File]::WriteAllText((Join-Path $reparseTarget "activation-receipts\$activationId.Ready.json"),($valid|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
        New-Item -ItemType Junction -Path (Join-Path $root 'state') -Target $reparseTarget|Out-Null
        $stderrPath=Join-Path $root 'validator-reparse.err';$invocation=&$invokeValidator $stderrPath
        Assert-CcodEqual 3 $invocation.ExitCode 'receipt beneath a reparse-point parent is refused before parsing'
        Assert-CcodEqual 0 $invocation.Stdout.Count 'reparse-parent refusal emits no receipt data to stdout'
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
        [IO.Directory]::CreateDirectory((Join-Path $root 'state\activation-receipts')) | Out-Null
        $activationId = '88888888-7777-6666-5555-444444444444'
        $readyPath = Join-Path $root "state\activation-receipts\$activationId.Ready.json"
        $failedPath = Join-Path $root "state\activation-receipts\$activationId.Failed.json"
        $stderrPath = Join-Path $root 'watchdog.err'
        $activationScript = Join-Path $repositoryRoot 'Activate-CcodRemoteFix.ps1'
        $ready = [ordered]@{schemaVersion=1;activationId=$activationId;phase='Ready';runtimeId='runtime-watchdog';previousRuntimeId=$null;startedAtUtc='2030-02-03T04:05:06.0000000Z';updatedAtUtc='2030-02-03T04:05:07.0000000Z';ready=$true;errorCode=$null}
        [IO.File]::WriteAllText($readyPath,($ready | ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))

        $stdout = @(& $activationScript -AppRoot $repositoryRoot -InstallRoot $root -ActivationId $activationId -ValidateReceiptWithTimeout -ValidationTimeoutMilliseconds 10000 2>$stderrPath)
        Assert-CcodEqual 0 $LASTEXITCODE 'watchdog returns the strict Ready child exit directly'
        Assert-CcodEqual 0 $stdout.Count 'watchdog Ready path emits no receipt data to stdout'

        $failed = [ordered]@{}; foreach ($key in $ready.Keys) { $failed[$key] = $ready[$key] }; $failed.phase = 'Failed'; $failed.ready = $false; $failed.errorCode = 'CCOD_INSTALL_FAILED'
        Remove-Item -LiteralPath $readyPath -Force
        [IO.File]::WriteAllText($failedPath,($failed | ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
        $stdout = @(& $activationScript -AppRoot $repositoryRoot -InstallRoot $root -ActivationId $activationId -ValidateReceiptWithTimeout -ValidationTimeoutMilliseconds 10000 2>$stderrPath)
        Assert-CcodEqual 2 $LASTEXITCODE 'watchdog returns the strict Failed child exit directly'
        Assert-CcodEqual 0 $stdout.Count 'watchdog Failed path emits no receipt data to stdout'

        Remove-Item -LiteralPath $failedPath -Force
        [IO.File]::WriteAllText($readyPath,($ready | ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
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
        [IO.Directory]::CreateDirectory((Join-Path $root 'state\activation-receipts')) | Out-Null
        $marker = Join-Path $root 'marker.txt'
        $installScript = Join-Path $root 'Install-CodexControlOtherDevices.ps1'
        $promptScript = Join-Path $root 'Prompt-CcodRestart.ps1'
        $installSource = "param([string]`$InstallRoot,[string]`$ActivationId,[switch]`$EnableCandidateCompatibleUpdates);[IO.File]::AppendAllText('$marker','install,',[Text.UTF8Encoding]::new(`$false));`$r=[ordered]@{schemaVersion=1;activationId=`$ActivationId;phase='Ready';runtimeId='runtime-new';previousRuntimeId=`$null;startedAtUtc='2030-02-03T04:05:06.0000000Z';updatedAtUtc='2030-02-03T04:05:07.0000000Z';ready=`$true;errorCode=`$null};[IO.File]::WriteAllText((Join-Path `$InstallRoot `"state\activation-receipts\`$ActivationId.Ready.json`"),(`$r|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new(`$false));exit 0"
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
        [IO.Directory]::CreateDirectory((Join-Path $root 'state\activation-receipts')) | Out-Null
        $marker = Join-Path $root 'marker.txt'
        $installScript = Join-Path $root 'Install-CodexControlOtherDevices.ps1'
        $promptScript = Join-Path $root 'Prompt-CcodRestart.ps1'
        $installSource = "param([string]`$InstallRoot,[string]`$ActivationId,[switch]`$EnableCandidateCompatibleUpdates);[IO.File]::AppendAllText('$marker','install,',[Text.UTF8Encoding]::new(`$false));`$r=[ordered]@{schemaVersion=1;activationId=`$ActivationId;phase='Ready';runtimeId='runtime-new';previousRuntimeId=`$null;startedAtUtc='2030-02-03T04:05:06.0000000Z';updatedAtUtc='2030-02-03T04:05:07.0000000Z';ready=`$true;errorCode=`$null};[IO.File]::WriteAllText((Join-Path `$InstallRoot `"state\activation-receipts\`$ActivationId.Ready.json`"),(`$r|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new(`$false));exit 0"
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
        [IO.Directory]::CreateDirectory((Join-Path $root 'state\activation-receipts')) | Out-Null
        $marker = Join-Path $root 'prompt-marker.txt'
        $installScript = Join-Path $root 'Install-CodexControlOtherDevices.ps1'
        $promptScript = Join-Path $root 'Prompt-CcodRestart.ps1'
        $installSource = @"
param([string]`$InstallRoot,[string]`$ActivationId,[switch]`$EnableCandidateCompatibleUpdates)
`$receipt=[ordered]@{schemaVersion=1;activationId=`$ActivationId;phase='StartingProtection';runtimeId='runtime-new';previousRuntimeId='runtime-old';startedAtUtc='2030-02-03T04:05:06.0000000Z';updatedAtUtc='2030-02-03T04:05:07.0000000Z';ready=`$false;errorCode=`$null}
[IO.File]::WriteAllText((Join-Path `$InstallRoot "state\activation-receipts\`$ActivationId.StartingProtection.json"),(`$receipt|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new(`$false))
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

$results += Invoke-CcodTest 'sealed Setup uses its wizard icon without installing product icons or shortcuts' {
    $installerScript = Join-Path $repositoryRoot 'build\CodexControlOtherDevices.iss'
    $lines = @(Get-Content -LiteralPath $installerScript)
    Assert-CcodTrue ($lines -ccontains 'SetupIconFile=..\assets\codexremote-fix\codexremote-fix.ico') 'setup uses the source product icon'
    Assert-CcodTrue (($lines -join "`n") -cnotmatch 'UninstallDisplayIcon=|DestDir:\s*"\{app\}|^Name:\s*"\{(group|userdesktop)\}') 'Task 3 installs no product icon registration workflow or shortcut before Ready'
}

$results += Invoke-CcodTest 'README and release workflow publish current portable-release branding' {
    $readme = Get-Content -LiteralPath (Join-Path $repositoryRoot 'README.md') -Raw -Encoding UTF8
    $readmeChinese = Get-Content -LiteralPath (Join-Path $repositoryRoot 'README.zh-CN.md') -Raw -Encoding UTF8
    Assert-CcodTrue ($readme -cmatch '\A(?s:<div align="center">.*?<h1>CodexRemote-fix</h1>)') 'default README uses the centered public English product heading'
    Assert-CcodTrue ($readmeChinese -cmatch '\A(?s:<div align="center">.*?<h1>CodexRemote-fix</h1>)') 'Chinese README uses the centered public product heading'

    $quickStart = [regex]::Match($readme, '(?ms)^## Quick start[^\r\n]*\r?\n(.*?)(?=^## )').Groups[1].Value
    Assert-CcodTrue ($quickStart -cmatch 'CodexRemote-fix-2\.5\.22-setup\.exe') 'English Quick Start names the setup installer'
    Assert-CcodTrue ($quickStart -cmatch 'CodexRemote-fix-2\.5\.22-windows-x64\.zip') 'English Quick Start names the exact portable artifact'
    Assert-CcodTrue ($quickStart -cmatch 'CodexRemote-fix\.exe') 'English Quick Start names the portable double-click entrypoint'
    Assert-CcodTrue ($quickStart -cmatch '\.sha256\.txt') 'English Quick Start names the checksum artifact'

    $quickStartChineseMatch = [regex]::Match($readmeChinese, '(?ms)^## [^\r\n]+\r?\n(?:\r?\n)?(?=1\.[^\r\n]*\[Releases\])(.*?)(?=^## |\z)')
    Assert-CcodTrue $quickStartChineseMatch.Success 'Chinese README exposes a Quick Start section'
    $quickStartChinese = $quickStartChineseMatch.Groups[1].Value
    Assert-CcodTrue ($quickStartChinese -cmatch 'CodexRemote-fix-2\.5\.22-setup\.exe') 'Chinese Quick Start names the setup installer'
    Assert-CcodTrue ($quickStartChinese -cmatch 'CodexRemote-fix-2\.5\.22-windows-x64\.zip') 'Chinese Quick Start names the exact portable artifact'
    Assert-CcodTrue ($quickStartChinese -cmatch 'CodexRemote-fix\.exe') 'Chinese Quick Start names the portable double-click entrypoint'
    Assert-CcodTrue ($quickStartChinese -cmatch '\.sha256\.txt') 'Chinese Quick Start names the checksum artifact'

    Assert-CcodTrue ($readme -cmatch 'Uninstall-CodexControlOtherDevices\.ps1') 'English uninstall instructions use the protected portable entrypoint'
    Assert-CcodTrue ($readmeChinese -cmatch 'Uninstall-CodexControlOtherDevices\.ps1') 'Chinese uninstall instructions use the protected portable entrypoint'
    Assert-CcodTrue ($readme -cmatch 'Each release appends a short English change summary to the GitHub release body') 'README documents English-only GitHub release notes'
    Assert-CcodTrue ($readme -cnotmatch 'bilingual change summary to this README and to the GitHub release body') 'README does not promise bilingual GitHub release notes'

    $workflow = Get-Content -LiteralPath (Join-Path $repositoryRoot '.github\workflows\release.yml') -Raw -Encoding UTF8
    Assert-CcodTrue ($workflow -cmatch '(?m)^name: CodexRemote-fix release\r?$') 'release workflow uses public product branding'
    Assert-CcodTrue ($workflow -cmatch '(?m)^\s+name: CodexRemote-fix portable bundle\r?$') 'uploaded artifact uses public portable bundle branding'
    Assert-CcodTrue ($workflow -cmatch '--title "CodexRemote-fix \$version"') 'GitHub release title uses public product branding'
    Assert-CcodTrue ($workflow -cmatch 'tools\\New-GitHubReleaseNotes\.ps1''\) -ChangelogPath .*? -Tag \$tag -OutputPath \$notesPath') 'GitHub release notes use the behavior-tested target-English extractor'
    Assert-CcodTrue ($workflow -cnotmatch 'englishSection\s*=\s*\[regex\]::Match') 'release workflow does not retain a second inline English extractor'
    $notesTool = Join-Path $repositoryRoot 'tools\New-GitHubReleaseNotes.ps1'
    Assert-CcodTrue (Test-Path -LiteralPath $notesTool -PathType Leaf) 'behavior-tested GitHub release notes extractor exists'
    $notesFixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('ccod-install-release-notes-' + [guid]::NewGuid().ToString('N'))
    try {
        [IO.Directory]::CreateDirectory($notesFixtureRoot) | Out-Null
        $missingEnglishChangelog = Join-Path $notesFixtureRoot 'CHANGELOG.md'
        $notesOutput = Join-Path $notesFixtureRoot 'notes.md'
        [IO.File]::WriteAllText($missingEnglishChangelog,"## v2.5.22`r`n`r`n### Simplified Chinese`r`n`r`n- fixture`r`n",[Text.UTF8Encoding]::new($false))
        Assert-CcodThrows { & $notesTool -ChangelogPath $missingEnglishChangelog -Tag 'v2.5.22' -OutputPath $notesOutput | Out-Null } 'CCOD_RELEASE_NOTES_ENGLISH_SECTION_INVALID'
        Assert-CcodTrue (-not (Test-Path -LiteralPath $notesOutput)) 'missing English notes cannot create a GitHub release body'
    } finally {
        if (Test-Path -LiteralPath $notesFixtureRoot) { Remove-Item -LiteralPath $notesFixtureRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

<# Superseded by Task 3 sealed package and Task 4 post-Ready registration.
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
#>

$results += Invoke-CcodTest 'sealed Setup carries no mutable validation or legacy shortcut migration payload' {
    $installerScript = Get-Content -LiteralPath (Join-Path $repositoryRoot 'build\CodexControlOtherDevices.iss') -Raw -Encoding UTF8
    Assert-CcodTrue ($installerScript -cnotmatch 'DestDir:\s*"\{app\}|\[InstallDelete\]|CodexControlOtherDevices\.iss"; DestDir|build\.ps1"; DestDir') 'Task 3 leaves installed validation and legacy registration migration to immutable payload and Task 4'
    Assert-CcodTrue ($installerScript -cmatch '(?m)^CreateAppDir=no\s*$' -and $installerScript -cmatch '(?m)^Uninstallable=no\s*$') 'Setup cannot create the old mutable validation root'
}

# Production mutation caught: product state written from ProtectionReady or before the terminal transaction snapshot.
$results += Invoke-CcodTest 'product registration runs exactly once only after the Task 2 Ready transaction is durable' {
    $source=New-CcodLifecycleTempRoot;$install=New-CcodLifecycleTempRoot;$nodeRoot=New-CcodLifecycleTempRoot
    try{
        New-CcodLifecycleSourceFixture -Root $source -Version '2.5.22'|Out-Null
        $node=New-CcodLifecycleFakeNode -Root $nodeRoot;$fake=New-CcodLifecycleFake -NodePath $node
        $result=Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -SealedPackageSha256 ('3'*64) -Adapters $fake.Adapters
        Assert-CcodEqual 1 $fake.World.ProductRegistrationCalls 'successful install commits product registration exactly once'
        Assert-CcodTrue $fake.World.ProductRegistrationReadyObserved 'registration adapter receives only the durable Ready transaction'
        Assert-CcodTrue $result.ProductRegistrationVerified 'install result reports verified post-Ready registration'
    }finally{foreach($path in @($source,$install,$nodeRoot)){if(Test-Path $path){Remove-Item $path -Recurse -Force}}}
}

# Production mutation caught: treating post-Ready registration failure as an install rollback or Failed lifecycle snapshot.
$results += Invoke-CcodTest 'registration failure preserves durable Ready without rollback or Failed transaction' {
    $source=New-CcodLifecycleTempRoot;$install=New-CcodLifecycleTempRoot;$nodeRoot=New-CcodLifecycleTempRoot
    try{
        New-CcodLifecycleSourceFixture -Root $source -Version '2.5.22'|Out-Null
        $node=New-CcodLifecycleFakeNode -Root $nodeRoot;$fake=New-CcodLifecycleFake -NodePath $node;$fake.World.ProductRegistrationFailure=$true
        Assert-CcodThrows { Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -SealedPackageSha256 ('3'*64) -Adapters $fake.Adapters|Out-Null } 'CCOD_PRODUCT_REGISTRATION_FAILED'
        $module=Get-Module InstallLifecycle;$head=&$module {param($Root)Read-CcodInstallTransactionRecord -InstallRoot $Root} $install
        Assert-CcodEqual 'Ready' $head.phase 'post-Ready registration failure cannot downgrade the lifecycle transaction'
        Assert-CcodEqual 0 @(Get-ChildItem -LiteralPath (Join-Path $install 'state\install-transactions') -Filter '*.Failed.*.json' -File).Count 'registration failure appends no Failed transaction snapshot'
        $retry=New-CcodLifecycleFake -NodePath $node
        $result=Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -SealedPackageSha256 ('3'*64) -Adapters $retry.Adapters
        Assert-CcodEqual 'AlreadyInstalled' $result.Outcome 'later same-package invocation retries after post-Ready registration failure'
        Assert-CcodEqual 1 $retry.World.ProductRegistrationCalls 'normal Ready registration retry occurs exactly once'
    }finally{foreach($path in @($source,$install,$nodeRoot)){if(Test-Path $path){Remove-Item $path -Recurse -Force}}}
}

# Production mutation caught: normal first install passed its writable generation transaction to the default product path instead of reopening strict Ready authority.
$results += Invoke-CcodTest 'normal first install reaches the default registration path with only a strict product capability' {
    $source=New-CcodLifecycleTempRoot;$install=New-CcodLifecycleTempRoot;$nodeRoot=New-CcodLifecycleTempRoot
    try{
        New-CcodLifecycleSourceFixture -Root $source -Version '2.5.22'|Out-Null;$node=New-CcodLifecycleFakeNode -Root $nodeRoot;$fake=New-CcodLifecycleFake -NodePath $node
        $productState=@{FailWrites=$false;Registration=$null;ReadyEvidence=$null;RetainedError=$null;Writes=0;ShortcutWrites=0;ProductOnlyObserved=$false;Shortcuts=@{}}
        Set-CcodLifecycleDefaultProductRegistrationFixture -Fake $fake -ProductState $productState
        $result=Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -SealedPackageSha256 ('6'*64) -Adapters $fake.Adapters
        Assert-CcodEqual 'Installed' $result.Outcome 'normal first install completes through the real default registration adapter'
        Assert-CcodTrue $result.ProductRegistrationVerified 'normal first install reports verified product registration'
        Assert-CcodTrue $productState.ProductOnlyObserved 'lower shortcut side effect receives a product-only retained capability'
        Assert-CcodEqual 1 $productState.Writes 'registry side effect boundary is invoked once'
        Assert-CcodEqual 2 $productState.ShortcutWrites 'both shortcut side effect boundaries are invoked once'
    }finally{foreach($path in @($source,$install,$nodeRoot)){if(Test-Path $path){Remove-Item $path -Recurse -Force}}}
}

# Production mutation caught: default registration failure after durable Ready must remain outside lifecycle failure and reconcile through AlreadyInstalled.
$results += Invoke-CcodTest 'default first-install registration failure leaves Ready and retries with strict product authority' {
    $source=New-CcodLifecycleTempRoot;$install=New-CcodLifecycleTempRoot;$nodeRoot=New-CcodLifecycleTempRoot
    try{
        New-CcodLifecycleSourceFixture -Root $source -Version '2.5.22'|Out-Null;$node=New-CcodLifecycleFakeNode -Root $nodeRoot;$first=New-CcodLifecycleFake -NodePath $node
        $failedState=@{FailWrites=$true;Registration=$null;ReadyEvidence=$null;RetainedError=$null;Writes=0;ShortcutWrites=0;ProductOnlyObserved=$false;Shortcuts=@{}};Set-CcodLifecycleDefaultProductRegistrationFixture -Fake $first -ProductState $failedState
        Assert-CcodThrows {Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -SealedPackageSha256 ('7'*64) -Adapters $first.Adapters|Out-Null} 'CCOD_PRODUCT_REGISTRATION_FAILED'
        $module=Get-Module InstallLifecycle -ErrorAction Stop;$head=&$module {param($Root)Read-CcodInstallTransactionRecord -InstallRoot $Root} $install
        Assert-CcodEqual 'Ready' $head.phase 'default registration failure leaves the lifecycle transaction durably Ready'
        Assert-CcodEqual 0 @(Get-ChildItem -LiteralPath (Join-Path $install 'state\install-transactions') -Filter '*.Failed.*.json' -File).Count 'default registration failure appends no Failed lifecycle snapshot'
        $retry=New-CcodLifecycleFake -NodePath $node;$retryState=@{FailWrites=$false;Registration=$null;ReadyEvidence=$null;RetainedError=$null;Writes=0;ShortcutWrites=0;ProductOnlyObserved=$false;Shortcuts=@{}};Set-CcodLifecycleDefaultProductRegistrationFixture -Fake $retry -ProductState $retryState
        $result=Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -SealedPackageSha256 ('7'*64) -Adapters $retry.Adapters
        Assert-CcodEqual 'AlreadyInstalled' $result.Outcome 'later same-package invocation retries default product registration'
        Assert-CcodTrue $retryState.ProductOnlyObserved 'recovery retry receives only strict product authority'
        Assert-CcodEqual 2 $retryState.ShortcutWrites 'recovery retry publishes both shortcut records through lower side effects'
    }finally{foreach($path in @($source,$install,$nodeRoot)){if(Test-Path $path){Remove-Item $path -Recurse -Force}}}
}

# Production mutation caught: failure to close the writable generation at the post-Ready handoff must not enter lifecycle rollback or prevent reconciliation.
$results += Invoke-CcodTest 'post-Ready writable close failure preserves Ready and retries before product side effects' {
    $source=New-CcodLifecycleTempRoot;$install=New-CcodLifecycleTempRoot;$nodeRoot=New-CcodLifecycleTempRoot
    try{
        New-CcodLifecycleSourceFixture -Root $source -Version '2.5.22'|Out-Null;$node=New-CcodLifecycleFakeNode -Root $nodeRoot;$first=New-CcodLifecycleFake -NodePath $node
        $failedState=@{FailWrites=$false;Registration=$null;ReadyEvidence=$null;RetainedError=$null;Writes=0;ShortcutWrites=0;ProductOnlyObserved=$false;Shortcuts=@{}};Set-CcodLifecycleDefaultProductRegistrationFixture -Fake $first -ProductState $failedState
        $first.Adapters.CloseReadyGeneration={param($Transaction)throw [Management.Automation.ErrorRecord]::new([InvalidOperationException]::new('fixture Ready close failed'),'CCOD_INSTALL_CLOSE_FAILED',[Management.Automation.ErrorCategory]::InvalidData,$null)}
        Assert-CcodThrows {Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -SealedPackageSha256 ('8'*64) -Adapters $first.Adapters|Out-Null} 'CCOD_PRODUCT_REGISTRATION_FAILED'
        $module=Get-Module InstallLifecycle -ErrorAction Stop;$head=&$module {param($Root)Read-CcodInstallTransactionRecord -InstallRoot $Root} $install
        Assert-CcodEqual 'Ready' $head.phase 'post-Ready writable close failure leaves the lifecycle transaction Ready'
        Assert-CcodEqual 0 @(Get-ChildItem -LiteralPath (Join-Path $install 'state\install-transactions') -Filter '*.Failed.*.json' -File).Count 'post-Ready writable close failure appends no Failed snapshot'
        Assert-CcodEqual 0 $failedState.Writes 'no product side effect begins before the writable generation closes'
        $retry=New-CcodLifecycleFake -NodePath $node;$retryState=@{FailWrites=$false;Registration=$null;ReadyEvidence=$null;RetainedError=$null;Writes=0;ShortcutWrites=0;ProductOnlyObserved=$false;Shortcuts=@{}};Set-CcodLifecycleDefaultProductRegistrationFixture -Fake $retry -ProductState $retryState
        $result=Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -SealedPackageSha256 ('8'*64) -Adapters $retry.Adapters
        Assert-CcodEqual 'AlreadyInstalled' $result.Outcome 'same-package retry reconciles after post-Ready writable close failure'
        Assert-CcodTrue $retryState.ProductOnlyObserved 'retry uses strict product authority after cleanup succeeds'
        Assert-CcodEqual 2 $retryState.ShortcutWrites 'retry completes both lower shortcut side effects'
    }finally{foreach($path in @($source,$install,$nodeRoot)){if(Test-Path $path){Remove-Item $path -Recurse -Force}}}
}

# Production mutation caught: marking a dead owner's Pending fence Completed without opening and closing fresh strict authority skips the required cleanup proof.
$results += Invoke-CcodTest 'dead-owner Pending fence requires fresh strict cleanup before registration' {
    Invoke-CcodLifecycleDeadOwnerCleanupTest
}

# Production mutation caught: initializing cleanup as complete before strict OpenProduct lets an open failure append a false Completed fence.
$results += Invoke-CcodTest 'strict product open failure retains Pending and later reconciles before verified success' {
    $source=New-CcodLifecycleTempRoot;$install=New-CcodLifecycleTempRoot;$nodeRoot=New-CcodLifecycleTempRoot
    $openFixture=$null
    try{
        New-CcodLifecycleSourceFixture -Root $source -Version '2.5.22'|Out-Null;$node=New-CcodLifecycleFakeNode -Root $nodeRoot;$fake=New-CcodLifecycleFake -NodePath $node
        $productState=@{FailWrites=$false;Registration=$null;ReadyEvidence=$null;RetainedError=$null;Writes=0;ShortcutWrites=0;ProductOnlyObserved=$false;Shortcuts=@{}};Set-CcodLifecycleDefaultProductRegistrationFixture -Fake $fake -ProductState $productState
        $fake.Adapters.RegisterProduct={param($InstallRoot,$RuntimeId,$Version,$PackageSha256,$FileTransaction,$TransactionRecord)[pscustomobject]@{verified=$true;legacyRemoved=$true}}
        $null=Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -SealedPackageSha256 ('c'*64) -Adapters $fake.Adapters
        [void]$fake.Adapters.Remove('RegisterProduct')
        $openState=@{FailuresRemaining=1};$openFixture=Set-CcodLifecycleProductOpenFailureFixture -State $openState
        $unexpectedReceipt=$null;$failure=$null
        try{$unexpectedReceipt=Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -SealedPackageSha256 ('c'*64) -Adapters $fake.Adapters}catch{$failure=$_}
        Assert-CcodEqual $null $unexpectedReceipt 'strict product open failure emits no verified registration receipt'
        $records=@(Get-CcodLifecycleProductCleanupTestRecords -InstallRoot $install)
        Assert-CcodEqual 1 $records.Count 'strict product open failure leaves only its durable Pending record'
        Assert-CcodEqual 'Pending' $records[0].State 'strict product open failure never appends Completed without an opened transaction'
        Assert-CcodEqual 'CCOD_PRODUCT_REGISTRATION_FAILED' (([string]$failure.FullyQualifiedErrorId-split',')[0]) 'strict product open failure is normalized to the stable product registration error'
        Assert-CcodEqual 1 $openState.Attempts 'failed registration makes exactly one strict product open attempt'
        Assert-CcodEqual 0 $productState.Writes 'strict product open failure performs no product write'
        Assert-CcodEqual 0 $productState.ShortcutWrites 'strict product open failure performs no shortcut write'
        Assert-CcodEqual 0 @(Get-ChildItem -LiteralPath (Join-Path $install 'state\install-transactions') -Filter '*.Failed.*.json' -File).Count 'strict product open failure appends no lifecycle Failed snapshot'

        $retry=Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -SealedPackageSha256 ('c'*64) -Adapters $fake.Adapters
        Assert-CcodEqual 'AlreadyInstalled' $retry.Outcome 'same-package retry reconciles the open-failure Pending fence'
        Assert-CcodTrue $retry.ProductRegistrationVerified 'same-package retry verifies only after exact strict cleanup and new registration close'
        Assert-CcodEqual 3 $openState.Attempts 'retry opens once to reconcile the old Pending fence and once for new verification'
        $records=@(Get-CcodLifecycleProductCleanupTestRecords -InstallRoot $install)
        Assert-CcodEqual '1:Pending|1:Completed|2:Pending|2:Completed' (($records|ForEach-Object{"$($_.Attempt):$($_.State)"})-join '|') 'open-failure recovery preserves append-only exact cleanup history'
    }finally{
        Clear-CcodLifecycleProductOpenFailureFixture -Fixture $openFixture
        foreach($path in @($source,$install,$nodeRoot)){if(Test-Path $path){Remove-Item $path -Recurse -Force}}
    }
}

# Production mutation caught: validating every historical record against the latest Ready transaction makes any completed prior version poison an upgrade.
$results += Invoke-CcodTest 'completed cleanup history from an older Ready transaction permits new upgrade registration' {
    $source=New-CcodLifecycleTempRoot;$install=New-CcodLifecycleTempRoot;$nodeRoot=New-CcodLifecycleTempRoot
    try{
        New-CcodLifecycleSourceFixture -Root $source -Version '2.5.22'|Out-Null;$node=New-CcodLifecycleFakeNode -Root $nodeRoot;$firstFake=New-CcodLifecycleFake -NodePath $node
        $firstProduct=@{FailWrites=$false;Registration=$null;ReadyEvidence=$null;RetainedError=$null;Writes=0;ShortcutWrites=0;ProductOnlyObserved=$false;Shortcuts=@{}};Set-CcodLifecycleDefaultProductRegistrationFixture -Fake $firstFake -ProductState $firstProduct
        $first=Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $firstFake.Adapters
        $module=Get-Module InstallLifecycle -ErrorAction Stop;$oldReady=&$module {param($Root)Read-CcodInstallTransactionRecord -InstallRoot $Root} $install
        Assert-CcodEqual 'Installed' $first.Outcome 'first product version reaches Ready registration'
        Assert-CcodEqual '1:Pending|1:Completed' ((@(Get-CcodLifecycleProductCleanupTestRecords -InstallRoot $install)|ForEach-Object{"$($_.Attempt):$($_.State)"})-join '|') 'first Ready transaction owns one complete cleanup attempt'
        Set-CcodLifecycleTestStatus -InstallRoot $install -RuntimeId $first.RuntimeId
        [IO.File]::WriteAllText((Join-Path $source 'src\runtime\main-payload.js'),"module.exports = 'fixture-upgrade-cleanup-history';`n",[Text.UTF8Encoding]::new($false))
        $upgradeFake=New-CcodLifecycleFake -NodePath $node;$upgradeProduct=@{FailWrites=$false;Registration=$null;ReadyEvidence=$null;RetainedError=$null;Writes=0;ShortcutWrites=0;ProductOnlyObserved=$false;Shortcuts=@{}};Set-CcodLifecycleDefaultProductRegistrationFixture -Fake $upgradeFake -ProductState $upgradeProduct
        $upgrade=$null;$upgradeFailure=$null
        try{$upgrade=Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $upgradeFake.Adapters}catch{$upgradeFailure=$_}
        $upgradeErrorId=if($null-eq$upgradeFailure){$null}else{([string]$upgradeFailure.FullyQualifiedErrorId-split',')[0]}
        Assert-CcodEqual $null $upgradeErrorId 'older completed cleanup history is ignored for the new Ready attempt sequence'
        Assert-CcodEqual 'Upgraded' $upgrade.Outcome 'new Ready transaction completes upgrade registration'
        Assert-CcodTrue $upgrade.ProductRegistrationVerified 'new upgrade reports verified only after its own cleanup completion'
        $newReady=&$module {param($Root)Read-CcodInstallTransactionRecord -InstallRoot $Root} $install
        Assert-CcodTrue ($newReady.transactionId-cne$oldReady.transactionId) 'upgrade commits a distinct Ready transaction identity'
        $records=@(Get-CcodLifecycleProductCleanupTestRecords -InstallRoot $install)
        Assert-CcodEqual 4 $records.Count 'append-only history retains both transaction cleanup pairs'
        $oldRecords=@($records|Where-Object{$_.Record.transactionId-ceq$oldReady.transactionId});$newRecords=@($records|Where-Object{$_.Record.transactionId-ceq$newReady.transactionId})
        Assert-CcodEqual '1:Pending|1:Completed' (($oldRecords|ForEach-Object{"$($_.Attempt):$($_.State)"})-join '|') 'older transaction retains its independent attempt sequence'
        Assert-CcodEqual '1:Pending|1:Completed' (($newRecords|ForEach-Object{"$($_.Attempt):$($_.State)"})-join '|') 'new transaction starts and completes its own attempt sequence'
        Assert-CcodEqual 1 $upgradeProduct.Writes 'upgrade reaches the product write boundary once'
        Assert-CcodEqual 2 $upgradeProduct.ShortcutWrites 'upgrade reaches both shortcut write boundaries'
    }finally{foreach($path in @($source,$install,$nodeRoot)){if(Test-Path $path){Remove-Item $path -Recurse -Force}}}
}

# Production mutation caught: filtering history solely to the new Ready identity would silently ignore an unresolved cleanup from the prior transaction.
$results += Invoke-CcodTest 'unresolved Pending from an older transaction blocks new Ready registration fail closed' {
    $source=New-CcodLifecycleTempRoot;$install=New-CcodLifecycleTempRoot;$nodeRoot=New-CcodLifecycleTempRoot
    try{
        New-CcodLifecycleSourceFixture -Root $source -Version '2.5.22'|Out-Null;$node=New-CcodLifecycleFakeNode -Root $nodeRoot;$firstFake=New-CcodLifecycleFake -NodePath $node
        $first=Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $firstFake.Adapters
        $module=Get-Module InstallLifecycle -ErrorAction Stop;$oldReady=&$module {param($Root)Read-CcodInstallTransactionRecord -InstallRoot $Root} $install;$owner=Get-CcodLifecycleCurrentProductCleanupTestIdentity
        $outer=&$module {Enter-CcodLifecycleProductCleanupLease}
        try{&$module {param($Root,$Ready,$Identity)[void](New-CcodLifecycleProductCleanupFence -InstallRoot $Root -ReadyTransaction $Ready -OwnerIdentity $Identity)} $install $oldReady $owner}
        finally{&$module {param($Context)[void](Exit-CcodLifecycleProductCleanupLease -Context $Context)} $outer}
        Set-CcodLifecycleTestStatus -InstallRoot $install -RuntimeId $first.RuntimeId
        [IO.File]::WriteAllText((Join-Path $source 'src\runtime\main-payload.js'),"module.exports = 'fixture-upgrade-prior-pending';`n",[Text.UTF8Encoding]::new($false))
        $upgradeFake=New-CcodLifecycleFake -NodePath $node;$upgradeProduct=@{FailWrites=$false;Registration=$null;ReadyEvidence=$null;RetainedError=$null;Writes=0;ShortcutWrites=0;ProductOnlyObserved=$false;Shortcuts=@{}};Set-CcodLifecycleDefaultProductRegistrationFixture -Fake $upgradeFake -ProductState $upgradeProduct
        $unexpectedReceipt=$null;$failure=$null
        try{$unexpectedReceipt=Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $upgradeFake.Adapters}catch{$failure=$_}
        Assert-CcodEqual $null $unexpectedReceipt 'prior-transaction Pending emits no verified upgrade receipt'
        Assert-CcodEqual 'CCOD_PRODUCT_REGISTRATION_FAILED' (([string]$failure.FullyQualifiedErrorId-split',')[0]) 'prior-transaction Pending blocks with the stable product registration error'
        Assert-CcodEqual 0 $upgradeProduct.Writes 'prior-transaction Pending blocks before product writes'
        Assert-CcodEqual 0 $upgradeProduct.ShortcutWrites 'prior-transaction Pending blocks before shortcut writes'
        $newReady=&$module {param($Root)Read-CcodInstallTransactionRecord -InstallRoot $Root} $install
        Assert-CcodTrue ($newReady.transactionId-cne$oldReady.transactionId) 'upgrade lifecycle remains durably Ready under a distinct transaction'
        $records=@(Get-CcodLifecycleProductCleanupTestRecords -InstallRoot $install)
        Assert-CcodEqual 1 $records.Count 'unresolved older Pending remains intact and no new fence is appended'
        Assert-CcodEqual $oldReady.transactionId $records[0].Record.transactionId 'blocking Pending retains its original transaction identity'
        Assert-CcodEqual 'Pending' $records[0].State 'blocking prior fence remains unresolved'
        Assert-CcodEqual 0 @(Get-ChildItem -LiteralPath (Join-Path $install 'state\install-transactions') -Filter '*.Failed.*.json' -File).Count 'prior Pending does not fabricate a lifecycle Failed snapshot'
    }finally{foreach($path in @($source,$install,$nodeRoot)){if(Test-Path $path){Remove-Item $path -Recurse -Force}}}
}

# Production mutation caught: accepting an extra cleanup member weakens the exact ten-field durable authority contract.
$results += Invoke-CcodTest 'cleanup history rejects an unknown record field before product authority opens' {
    $source=New-CcodLifecycleTempRoot;$install=New-CcodLifecycleTempRoot;$nodeRoot=New-CcodLifecycleTempRoot
    try{
        New-CcodLifecycleSourceFixture -Root $source -Version '2.5.22'|Out-Null;$node=New-CcodLifecycleFakeNode -Root $nodeRoot;$fake=New-CcodLifecycleFake -NodePath $node
        $productState=@{FailWrites=$false;Registration=$null;ReadyEvidence=$null;RetainedError=$null;Writes=0;ShortcutWrites=0;ProductOnlyObserved=$false;Shortcuts=@{}};Set-CcodLifecycleDefaultProductRegistrationFixture -Fake $fake -ProductState $productState
        $null=Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -SealedPackageSha256 ('2'*64) -Adapters $fake.Adapters
        $completed=@(Get-ChildItem -LiteralPath (Join-Path $install 'state\product-cleanup-fences') -Filter '*.Completed.*.json' -File)
        Assert-CcodEqual 1 $completed.Count 'fixture starts from one valid completed cleanup record'
        $record=(Get-Content -LiteralPath $completed[0].FullName -Raw)|ConvertFrom-Json
        $mutated=[ordered]@{};foreach($property in $record.PSObject.Properties){$mutated[$property.Name]=$property.Value};$mutated['unknownFenceField']='rejected'
        $completed[0].IsReadOnly=$false
        [IO.File]::WriteAllText($completed[0].FullName,(($mutated|ConvertTo-Json -Depth 8 -Compress)+"`n"),[Text.UTF8Encoding]::new($false))
        $completed[0].Refresh();$completed[0].IsReadOnly=$true
        $productState.Writes=0;$productState.ShortcutWrites=0
        $unexpectedReceipt=$null;$failure=$null
        try{$unexpectedReceipt=Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -SealedPackageSha256 ('2'*64) -Adapters $fake.Adapters}catch{$failure=$_}
        Assert-CcodEqual $null $unexpectedReceipt 'unknown cleanup field emits no verified receipt'
        Assert-CcodEqual 'CCOD_PRODUCT_REGISTRATION_FAILED' (([string]$failure.FullyQualifiedErrorId-split',')[0]) 'unknown cleanup field fails closed with the stable error'
        Assert-CcodEqual 0 $productState.Writes 'unknown cleanup field blocks before product writes'
        Assert-CcodEqual 0 $productState.ShortcutWrites 'unknown cleanup field blocks before shortcut writes'
    }finally{foreach($path in @($source,$install,$nodeRoot)){if(Test-Path $path){Remove-Item $path -Recurse -Force}}}
}

# Production mutation caught: releasing strict product authority after a lower close failure without a durable fence lets another process report verified registration.
$results += Invoke-CcodTest 'live-owner durable product cleanup blocks another real process after mutex acquisition' {
    $source=New-CcodLifecycleTempRoot;$install=New-CcodLifecycleTempRoot;$nodeRoot=New-CcodLifecycleTempRoot;$markerRoot=New-CcodLifecycleTempRoot
    $fileModule=$null;$first=$null
    try{
        New-CcodLifecycleSourceFixture -Root $source -Version '2.5.22'|Out-Null;$node=New-CcodLifecycleFakeNode -Root $nodeRoot;$first=New-CcodLifecycleFake -NodePath $node
        $productState=@{FailWrites=$false;Registration=$null;ReadyEvidence=$null;RetainedError=$null;Writes=0;ShortcutWrites=0;ProductOnlyObserved=$false;Shortcuts=@{}};Set-CcodLifecycleDefaultProductRegistrationFixture -Fake $first -ProductState $productState
        $lowerState=@{FailuresRemaining=1};$fileModule=Set-CcodLifecycleLowerProductCloseFixture -State $lowerState
        $unexpectedReceipt=$null;$failure=$null
        try{$unexpectedReceipt=Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -SealedPackageSha256 ('a'*64) -Adapters $first.Adapters}catch{$failure=$_}
        Assert-CcodEqual $null $unexpectedReceipt 'lower native close failure returns no verified receipt to the first process'
        Assert-CcodEqual 'CCOD_PRODUCT_REGISTRATION_FAILED' (([string]$failure.FullyQualifiedErrorId-split',')[0]) 'lower native close failure surfaces as product registration failure'
        $module=Get-Module InstallLifecycle -ErrorAction Stop;$ready=&$module {param($Root)Read-CcodInstallTransactionRecord -InstallRoot $Root} $install
        Assert-CcodEqual 'Ready' $ready.phase 'first process lower close failure leaves lifecycle Ready'
        Assert-CcodEqual 0 @(Get-ChildItem -LiteralPath (Join-Path $install 'state\install-transactions') -Filter '*.Failed.*.json' -File).Count 'first process lower close failure appends no Failed lifecycle snapshot'

        $child=Invoke-CcodLifecycleOtherProcessProductReconciliation -SourceRoot $source -InstallRoot $install -NodePath $node -PackageSha256 ('a'*64) -MarkerRoot $markerRoot
        [Console]::Error.WriteLine(('CCOD_CROSS_PROCESS_OBSERVED exit={0} mutex={1} authority={2} product={3} verified={4} error={5}'-f$child.ExitCode,$child.MutexAcquired,$child.AuthorityOpened,$child.ProductWritten,$child.Verified,$child.ErrorId))
        Assert-CcodTrue $child.MutexAcquired 'fresh process acquires the real AccountTransition mutex after the first failure'
        Assert-CcodEqual 23 $child.ExitCode 'fresh process fails closed on the durable pending fence'
        Assert-CcodEqual 'CCOD_PRODUCT_REGISTRATION_FAILED' $child.ErrorId 'fresh process reports the stable product registration failure'
        Assert-CcodEqual $false $child.AuthorityOpened 'fresh process opens no strict product authority while the live owner is pending'
        Assert-CcodEqual $false $child.ProductWritten 'fresh process writes no product registration or shortcut'
        Assert-CcodEqual $false $child.Verified 'fresh process emits no verified success'
        Assert-CcodEqual $null $child.ChildFailure 'fresh process has no setup or adapter failure'
        $records=@(Get-CcodLifecycleProductCleanupTestRecords -InstallRoot $install);$owner=Get-CcodLifecycleCurrentProductCleanupTestIdentity
        Assert-CcodEqual 1 $records.Count 'other process observes one on-disk Pending fence rather than parent memory'
        Assert-CcodLifecycleProductCleanupTestRecord -Actual $records[0].Record -Ready $ready -Owner $owner -State Pending
        Assert-CcodEqual 1 $lowerState.Attempts 'first process performs exactly one lower product close attempt'
    }finally{
        Clear-CcodLifecycleLowerProductCloseFixture -FileModule $fileModule
        if($null-ne$first-and(Test-Path -LiteralPath $install)){try{Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -SealedPackageSha256 ('a'*64) -Adapters $first.Adapters|Out-Null}catch{}}
        foreach($path in @($source,$install,$nodeRoot,$markerRoot)){if(Test-Path $path){Remove-Item $path -Recurse -Force}}
    }
}

# Production mutation caught: dropping the retained same-thread capability or completing its fence before exact close permits false verified success after Ready.
$results += Invoke-CcodTest 'same-thread AlreadyInstalled drains durable product cleanup before verified success' {
    $source=New-CcodLifecycleTempRoot;$install=New-CcodLifecycleTempRoot;$nodeRoot=New-CcodLifecycleTempRoot
    $fileModule=$null;$cleanupNeeded=$true
    try{
        New-CcodLifecycleSourceFixture -Root $source -Version '2.5.22'|Out-Null;$node=New-CcodLifecycleFakeNode -Root $nodeRoot;$first=New-CcodLifecycleFake -NodePath $node
        $productState=@{FailWrites=$false;Registration=$null;ReadyEvidence=$null;RetainedError=$null;Writes=0;ShortcutWrites=0;ProductOnlyObserved=$false;Shortcuts=@{}};Set-CcodLifecycleDefaultProductRegistrationFixture -Fake $first -ProductState $productState
        $lowerState=@{FailuresRemaining=2};$fileModule=Set-CcodLifecycleLowerProductCloseFixture -State $lowerState
        $firstReceipt=$null;$firstFailure=$null
        try{$firstReceipt=Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -SealedPackageSha256 ('9'*64) -Adapters $first.Adapters}catch{$firstFailure=$_}
        Assert-CcodEqual $null $firstReceipt 'first lower close failure emits no successful install or registration receipt'
        Assert-CcodEqual 'CCOD_PRODUCT_REGISTRATION_FAILED' (([string]$firstFailure.FullyQualifiedErrorId-split',')[0]) 'first lower close failure is a stable product registration failure'
        $module=Get-Module InstallLifecycle -ErrorAction Stop;$ready=&$module {param($Root)Read-CcodInstallTransactionRecord -InstallRoot $Root} $install;$owner=Get-CcodLifecycleCurrentProductCleanupTestIdentity
        Assert-CcodEqual 'Ready' $ready.phase 'first lower close failure retains lifecycle Ready'
        Assert-CcodEqual 0 @(Get-ChildItem -LiteralPath (Join-Path $install 'state\install-transactions') -Filter '*.Failed.*.json' -File).Count 'first lower close failure appends no lifecycle Failed snapshot'
        $records=@(Get-CcodLifecycleProductCleanupTestRecords -InstallRoot $install)
        Assert-CcodEqual 1 $records.Count 'first lower close failure leaves exactly one durable Pending record'
        Assert-CcodLifecycleProductCleanupTestRecord -Actual $records[0].Record -Ready $ready -Owner $owner -State Pending
        Assert-CcodEqual 1 $lowerState.Attempts 'one Invoke call performs one lower close attempt'

        $secondReceipt=$null;$secondFailure=$null
        try{$secondReceipt=Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -SealedPackageSha256 ('9'*64) -Adapters $first.Adapters}catch{$secondFailure=$_}
        Assert-CcodEqual $null $secondReceipt 'second retained-capability close failure emits no verified receipt'
        Assert-CcodEqual 'CCOD_PRODUCT_REGISTRATION_FAILED' (([string]$secondFailure.FullyQualifiedErrorId-split',')[0]) 'second retained-capability close failure remains retryable'
        Assert-CcodEqual 2 $lowerState.Attempts 'second same-thread invocation retries the original lower close exactly once'
        Assert-CcodEqual 'Ready' (&$module {param($Root)(Read-CcodInstallTransactionRecord -InstallRoot $Root).phase} $install) 'two close failures leave lifecycle Ready'
        Assert-CcodEqual 0 @(Get-ChildItem -LiteralPath (Join-Path $install 'state\install-transactions') -Filter '*.Failed.*.json' -File).Count 'two close failures append no lifecycle Failed snapshot'
        Assert-CcodEqual 1 @(Get-CcodLifecycleProductCleanupTestRecords -InstallRoot $install).Count 'failed retained retry appends no false Completed record'

        $result=Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -SealedPackageSha256 ('9'*64) -Adapters $first.Adapters
        Assert-CcodEqual 'AlreadyInstalled' $result.Outcome 'exact same-package invocation returns only after original cleanup drains'
        Assert-CcodTrue $result.ProductRegistrationVerified 'exact same-package invocation verifies only after durable completion'
        Assert-CcodEqual 4 $lowerState.Attempts 'successful retry closes the retained original and the new strict verification transaction'
        $records=@(Get-CcodLifecycleProductCleanupTestRecords -InstallRoot $install)
        Assert-CcodEqual 4 $records.Count 'successful retry appends original completion and a complete verification pair'
        Assert-CcodEqual '1:Pending|1:Completed|2:Pending|2:Completed' (($records|ForEach-Object{"$($_.Attempt):$($_.State)"})-join '|') 'cleanup history is append-only and ordered'
        Assert-CcodLifecycleProductCleanupTestRecord -Actual $records[1].Record -Ready $ready -Owner $owner -State Completed
        $cleanupNeeded=$false
    }finally{
        Clear-CcodLifecycleLowerProductCloseFixture -FileModule $fileModule
        if($cleanupNeeded-and(Test-Path -LiteralPath $install)){try{Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -SealedPackageSha256 ('9'*64) -Adapters $first.Adapters|Out-Null}catch{}}
        foreach($path in @($source,$install,$nodeRoot)){if(Test-Path $path){Remove-Item $path -Recurse -Force}}
    }
}

Write-Output "Install lifecycle self-tests passed: $($results.Count)"
