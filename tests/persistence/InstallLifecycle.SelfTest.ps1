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
        TaskStarted = 0
        AutomationPaused = 0
        TransitionLeaseCalls = 0
        ShutdownSignaled = 0
        WaitSupervisorExit = $true
        TerminateSupervisorCalls = 0
        LastTerminateIdentity = $null
        SupervisorIdentityCurrent = $true
        SupervisorIdentityChecks = 0
        InstallLeaseCalls = 0
        InstallLeaseReleased = 0
        InstallLeaseOutcome = 'Acquired'
        ShutdownGateOpened = 0
        ShutdownGateClosed = 0
        FallbackSupervisor = $null
        FallbackSupervisorLookups = 0
        NormalizeReceipt = New-CcodLifecycleNormalizeReceipt -SpecialPresent $false -Normalized $false
        NormalizeCalls = 0
        KeyPath = $null
        BackupCalls = 0
        RemoveKeyCalls = 0
        LastBackupPath = $null
        LogRecords = [Collections.Generic.List[object]]::new()
        CopyOverride = $null
    }
    $adapters = @{}
    $adapters.ValidateSource = { param($SourceRoot) $world.Calls.Add("Validate:$([IO.Path]::GetFileName($SourceRoot))"); [bool]$world.ValidateSource }.GetNewClosure()
    $adapters.GetProjectVersion = { param($SourceRoot) (Get-Content -LiteralPath (Join-Path $SourceRoot 'package.json') -Raw | ConvertFrom-Json).version }.GetNewClosure()
    $adapters.DiscoverNodeCandidates = { $world.Calls.Add('DiscoverNode'); @($world.NodePath) }.GetNewClosure()
    $adapters.ValidateNodeCandidate = { param($Path) $world.Calls.Add("ValidateNode:$([IO.Path]::GetFileName($Path))"); $Path -ceq $world.NodePath }.GetNewClosure()
    $adapters.GetCurrentIdentity = { $world.Calls.Add('Identity'); $world.Identity }.GetNewClosure()
    $adapters.UtcNow = { $world.Calls.Add('Now'); $world.NowUtc }.GetNewClosure()
    $adapters.InstallSupervisorTask = { param($InstallRoot, $UserSid) $world.Calls.Add("InstallTask:$([IO.Path]::GetFileName($InstallRoot)):$UserSid"); $world.TaskInstalled++ }.GetNewClosure()
    $adapters.RemoveSupervisorTask = { $world.Calls.Add('RemoveTask'); $world.TaskRemoved++ }.GetNewClosure()
    $adapters.StartSupervisorTask = { $world.Calls.Add('StartTask'); $world.TaskStarted++ }.GetNewClosure()
    $adapters.SignalSupervisorShutdown = { param($UserSid, $SessionId) $world.Calls.Add("SignalShutdown:${UserSid}:${SessionId}"); $world.ShutdownSignaled++ }.GetNewClosure()
    $adapters.FindSupervisorFallback = { param($InstallRoot, $Identity) $world.Calls.Add("FindSupervisorFallback:$([IO.Path]::GetFileName($InstallRoot)):$($Identity.UserSid):$($Identity.SessionId)"); $world.FallbackSupervisorLookups++; $world.FallbackSupervisor }.GetNewClosure()
    $adapters.WaitSupervisorExit = { param($SupervisorIdentity, $TimeoutMilliseconds) $world.Calls.Add("WaitSupervisor:$($SupervisorIdentity.Pid):$TimeoutMilliseconds"); [bool]$world.WaitSupervisorExit }.GetNewClosure()
    $adapters.IsSupervisorIdentityCurrent = { param($SupervisorIdentity) $world.Calls.Add("CheckSupervisor:$($SupervisorIdentity.Pid)"); $world.SupervisorIdentityChecks++; [bool]$world.SupervisorIdentityCurrent }.GetNewClosure()
    $adapters.TerminateSupervisor = { param($SupervisorIdentity) $world.Calls.Add("TerminateSupervisor:$($SupervisorIdentity.Pid)"); $world.TerminateSupervisorCalls++; $world.LastTerminateIdentity = $SupervisorIdentity; $true }.GetNewClosure()
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
    $adapters.SetAutomationEnabled = { param($StateRoot, $Enabled) $world.Calls.Add("Automation:$Enabled"); $world.AutomationPaused++ }.GetNewClosure()
    $adapters.EnterTransitionLease = { param($UserSid, $SessionId) $world.Calls.Add("EnterTransitionLease"); $world.TransitionLeaseCalls++; [pscustomobject][ordered]@{ SchemaVersion = 1; Name = "Fake-Transition"; Kind = 'Transition'; Outcome = 'Acquired'; CreatedNew = $false; Abandoned = $false; Handle = [pscustomobject]@{ Kind = 'Mutex' }; OwnerManagedThreadId = [Threading.Thread]::CurrentThread.ManagedThreadId; Released = $false } }.GetNewClosure()
    $adapters.ExitTransitionLease = { param($Lease) $world.Calls.Add('ExitTransitionLease'); $true }.GetNewClosure()
    $adapters.ResolveDeviceKeyStore = { param() $world.Calls.Add('ResolveKey'); [string]$world.KeyPath }.GetNewClosure()
    $adapters.BackupDeviceKeyStore = { param($Path, $BackupPath) $world.Calls.Add("BackupKey:$([IO.Path]::GetFileName($Path))"); $world.BackupCalls++; $world.LastBackupPath = $BackupPath; [IO.File]::Move($Path, $BackupPath); $BackupPath }.GetNewClosure()
    $adapters.RemoveDeviceKeyStore = { param($Path) $world.Calls.Add("RemoveKey:$([IO.Path]::GetFileName($Path))"); $world.RemoveKeyCalls++; [IO.File]::Delete($Path) }.GetNewClosure()
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
    $adapters.WriteLog = { param($InstallRoot, $Record) $world.Calls.Add("Log:$($Record.code)"); $world.LogRecords.Add($Record) }.GetNewClosure()
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

$results = @()

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

$results += Invoke-CcodTest 'ordinary uninstall removes task runtime state and logs and preserves keys' {
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
        $receipt = Invoke-CcodUninstall -InstallRoot $install -Adapters $fake2.Adapters
        Assert-CcodEqual 'Uninstalled' $receipt.Outcome 'uninstall outcome'
        Assert-CcodEqual 1 $fake2.World.TaskRemoved 'task removed'
        Assert-CcodEqual 1 $fake2.World.NormalizeCalls 'session normalization checked'
        Assert-CcodEqual 1 $fake2.World.ShutdownSignaled 'supervisor shutdown signaled'
        Assert-CcodTrue (-not (Test-Path -LiteralPath $install)) 'install root removed'
        Assert-CcodEqual $true $receipt.KeptDeviceKeyStore 'key store kept by default'
        Assert-CcodTrue (Test-Path -LiteralPath $keyPath -PathType Leaf) 'key file still present'
        Assert-CcodEqual 0 $fake2.World.BackupCalls 'default uninstall does not back up keys'
        Assert-CcodEqual 0 $fake2.World.RemoveKeyCalls 'default uninstall does not remove keys'
    } finally {
        foreach ($path in @($source, $install, $nodeRoot, $keyRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

$results += Invoke-CcodTest 'uninstall normalizes a special session by default' {
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
        $fake2.World.NormalizeReceipt = New-CcodLifecycleNormalizeReceipt -SpecialPresent $true -Normalized $true -Outcome 'Recovered'
        $receipt = Invoke-CcodUninstall -InstallRoot $install -Adapters $fake2.Adapters
        Assert-CcodEqual 'Uninstalled' $receipt.Outcome 'normalized special uninstall succeeds'
        Assert-CcodEqual 1 $fake2.World.NormalizeCalls 'special normalization invoked'
    } finally {
        foreach ($path in @($source, $install, $nodeRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

$results += Invoke-CcodTest 'uninstall fails closed when special normalization fails' {
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
        $fake2.World.NormalizeReceipt = New-CcodLifecycleNormalizeReceipt -SpecialPresent $true -Normalized $false -Outcome 'Failed'
        Assert-CcodThrows { Invoke-CcodUninstall -InstallRoot $install -Adapters $fake2.Adapters } 'CCOD_UNINSTALL_NORMALIZATION_FAILED'
        Assert-CcodEqual 0 $fake2.World.TaskRemoved 'failed normalization does not remove task'
        Assert-CcodTrue (Test-Path -LiteralPath (Join-Path $install 'bootstrap.ps1')) 'failed normalization keeps install intact'
    } finally {
        foreach ($path in @($source, $install, $nodeRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

$results += Invoke-CcodTest 'keep current special session skips normalization and records the CDP warning' {
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
        $fake2.World.NormalizeReceipt = New-CcodLifecycleNormalizeReceipt -SpecialPresent $true -Normalized $false -Outcome 'NoSpecial'
        $receipt = Invoke-CcodUninstall -InstallRoot $install -KeepCurrentSpecialSession -Adapters $fake2.Adapters
        Assert-CcodEqual 'Uninstalled' $receipt.Outcome 'explicit keep uninstalls'
        Assert-CcodEqual 0 $fake2.World.NormalizeCalls 'keep skips session normalization'
        Assert-CcodTrue (@($fake2.World.LogRecords | Where-Object { $_.code -eq 'CCOD_UNINSTALL_UNMONITORED_CDP' }).Count -eq 1) 'unmonitored CDP warning recorded'
    } finally {
        foreach ($path in @($source, $install, $nodeRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

$results += Invoke-CcodTest 'explicit backup moves the key store after normalization' {
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
        $receipt = Invoke-CcodUninstall -InstallRoot $install -BackupDeviceKeyStore -Adapters $fake2.Adapters
        Assert-CcodEqual 1 $fake2.World.BackupCalls 'backup invoked once'
        Assert-CcodEqual 1 $fake2.World.NormalizeCalls 'normalization precedes backup'
        Assert-CcodTrue (@($fake2.World.Calls | Where-Object { $_ -like 'Normalize:*' }).Count -eq 1) 'normalization call recorded'
        Assert-CcodTrue (-not (Test-Path -LiteralPath $keyPath)) 'key moved away'
        Assert-CcodTrue (Test-Path -LiteralPath $receipt.BackupPath -PathType Leaf) 'backup file exists'
        Assert-CcodTrue ($receipt.BackupPath -like "$keyPath.backup.*") 'backup name carries UTC timestamp suffix'
    } finally {
        foreach ($path in @($source, $install, $nodeRoot, $keyRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

$results += Invoke-CcodTest 'explicit removal deletes keys and prints the server revocation reminder' {
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
        $receipt = Invoke-CcodUninstall -InstallRoot $install -RemoveDeviceKeyStore -Adapters $fake2.Adapters
        Assert-CcodEqual 1 $fake2.World.RemoveKeyCalls 'key removal invoked once'
        Assert-CcodTrue (-not (Test-Path -LiteralPath $keyPath)) 'key file deleted'
        Assert-CcodTrue (@($fake2.World.LogRecords | Where-Object { $_.code -eq 'CCOD_UNINSTALL_REVOKE_REMINDER' }).Count -eq 1) 'revocation reminder recorded'
    } finally {
        foreach ($path in @($source, $install, $nodeRoot, $keyRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

$results += Invoke-CcodTest 'simultaneous backup and removal is rejected' {
    $source = New-CcodLifecycleTempRoot
    $install = New-CcodLifecycleTempRoot
    $nodeRoot = New-CcodLifecycleTempRoot
    try {
        New-CcodLifecycleSourceFixture -Root $source | Out-Null
        $nodePath = New-CcodLifecycleFakeNode -Root $nodeRoot
        $fake = New-CcodLifecycleFake -NodePath $nodePath
        Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -Adapters $fake.Adapters | Out-Null
        Assert-CcodThrows { Invoke-CcodUninstall -InstallRoot $install -BackupDeviceKeyStore -RemoveDeviceKeyStore -Adapters $fake.Adapters } 'CCOD_UNINSTALL_KEY_CONFLICT'
        Assert-CcodTrue (Test-Path -LiteralPath (Join-Path $install 'bootstrap.ps1')) 'conflict leaves install intact'
    } finally {
        foreach ($path in @($source, $install, $nodeRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

$results += Invoke-CcodTest 'whatif uninstall removes nothing and preserves keys' {
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
        Invoke-CcodUninstall -InstallRoot $install -BackupDeviceKeyStore -Adapters $fake2.Adapters -WhatIf
        Assert-CcodEqual 0 $fake2.World.TaskRemoved 'whatif removes no task'
        Assert-CcodEqual 0 $fake2.World.BackupCalls 'whatif backs up no keys'
        Assert-CcodTrue (Test-Path -LiteralPath $install) 'whatif keeps install'
        Assert-CcodTrue (Test-Path -LiteralPath $keyPath) 'whatif keeps keys'
    } finally {
        foreach ($path in @($source, $install, $nodeRoot, $keyRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
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

$results += Invoke-CcodTest 'installer publishes the exact CodexRemote-fix 2.4.21 release artifacts' {
    $package = Get-Content -LiteralPath (Join-Path $repositoryRoot 'package.json') -Raw | ConvertFrom-Json
    Assert-CcodEqual '2.4.21' ([string]$package.version) 'package version is exactly 2.4.21'

    $installerScript = Get-Content -LiteralPath (Join-Path $repositoryRoot 'build\CodexControlOtherDevices.iss') -Raw
    $outputBase = [regex]::Match($installerScript, '(?m)^OutputBaseFilename=(.+)$').Groups[1].Value.Trim()
    $setupName = ($outputBase -replace '\{#ProjectVersion\}', [string]$package.version) + '.exe'
    Assert-CcodEqual 'CodexRemote-fix-2.4.21-setup.exe' $setupName 'Inno output resolves to the exact public setup filename'

    $buildScript = Get-Content -LiteralPath (Join-Path $repositoryRoot 'build\build.ps1') -Raw
    $checksumTemplate = [regex]::Match($buildScript, 'Join-Path \$dist \("([^"]+\.sha256\.txt)"\)').Groups[1].Value
    $checksumName = $checksumTemplate.Replace('$Version', [string]$package.version)
    Assert-CcodEqual 'CodexRemote-fix-2.4.21-setup.exe.sha256.txt' $checksumName 'build script resolves to the exact public checksum filename'
}

$results += Invoke-CcodTest 'installer stops the running supervisor before replacing the installed version' {
    $installerScript = Get-Content -LiteralPath (Join-Path $repositoryRoot 'build\CodexControlOtherDevices.iss') -Raw -Encoding UTF8
    $activationScript = Join-Path $repositoryRoot 'Activate-CcodRemoteFix.ps1'
    $promptScript = Join-Path $repositoryRoot 'Prompt-CcodRestart.ps1'
    Assert-CcodTrue (Test-Path -LiteralPath $activationScript -PathType Leaf) 'post-install activation worker exists'
    Assert-CcodTrue (Test-Path -LiteralPath $promptScript -PathType Leaf) 'post-install Codex restart prompt exists'
    Assert-CcodTrue ($installerScript -cmatch '(?m)^CloseApplications=no\r?$') 'installer never lets Restart Manager close Codex'
    Assert-CcodTrue ($installerScript -cmatch 'Activate-CcodRemoteFix\.ps1') 'installer bundles the activation worker'
    Assert-CcodTrue ($installerScript -cmatch '(?s)CurStepChanged.*Activate-CcodRemoteFix\.ps1.*ewNoWait') 'installer launches activation asynchronously so the setup window stays responsive'
    Assert-CcodTrue ($installerScript -cnotmatch 'Prepare-CcodRemoteUpgrade\.ps1') 'installer does not pre-stop the supervisor outside the gated runtime activation transaction'
    Assert-CcodTrue ($installerScript -cnotmatch '(?ms)^\[Run\]\s*\r?\nFilename: "powershell\.exe"; Parameters: ".*Install-CodexControlOtherDevices\.ps1') 'installer does not silently ignore its runtime installer exit code through a Run entry'
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
        [IO.Directory]::CreateDirectory($root) | Out-Null
        $marker = Join-Path $root 'marker.txt'
        $installScript = Join-Path $root 'Install-CodexControlOtherDevices.ps1'
        $promptScript = Join-Path $root 'Prompt-CcodRestart.ps1'
        [IO.File]::WriteAllText($installScript, "[IO.File]::AppendAllText('$marker','install,',[Text.UTF8Encoding]::new(`$false)); exit 0", [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($promptScript, "param([string]`$AppRoot,[string]`$InstallRoot);[IO.File]::AppendAllText('$marker','prompt',[Text.UTF8Encoding]::new(`$false)); exit 0", [Text.UTF8Encoding]::new($false))
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
        [IO.Directory]::CreateDirectory($root) | Out-Null
        $marker = Join-Path $root 'marker.txt'
        $installScript = Join-Path $root 'Install-CodexControlOtherDevices.ps1'
        $promptScript = Join-Path $root 'Prompt-CcodRestart.ps1'
        [IO.File]::WriteAllText($installScript, "[IO.File]::AppendAllText('$marker','install,',[Text.UTF8Encoding]::new(`$false)); exit 0", [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($promptScript, "param([string]`$AppRoot,[string]`$InstallRoot);[IO.File]::AppendAllText('$marker','prompt',[Text.UTF8Encoding]::new(`$false)); exit 1", [Text.UTF8Encoding]::new($false))
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

$results += Invoke-CcodTest 'post-install restart prompt requests an explicit controlled Codex restart after Yes' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-restart-prompt-yes-' + [guid]::NewGuid().ToString('N'))
    try {
        [IO.Directory]::CreateDirectory($root) | Out-Null
        $marker = Join-Path $root 'restart-marker.txt'
        $startScript = Join-Path $root 'Start-CodexControlOtherDevices.ps1'
        $source = @"
param([switch]`$RestartCodex)
[IO.File]::WriteAllText('$marker', [string]`$RestartCodex, [Text.UTF8Encoding]::new(`$false))
exit 0
"@
        [IO.File]::WriteAllText($startScript, $source, [Text.UTF8Encoding]::new($false))
        $output = @(& (Join-Path $repositoryRoot 'Prompt-CcodRestart.ps1') -AppRoot $root -InstallRoot $root -Choice Restart 2>&1)
        Assert-CcodEqual 0 $LASTEXITCODE 'restart choice exits successfully when the verified wrapper succeeds'
        Assert-CcodTrue (Test-Path -LiteralPath $marker -PathType Leaf) 'restart choice invokes the wrapper'
        Assert-CcodEqual 'True' ([IO.File]::ReadAllText($marker, [Text.UTF8Encoding]::new($false))) 'restart choice passes the explicit RestartCodex switch'
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
    Assert-CcodTrue ($quickStart -cmatch 'CodexRemote-fix-2\.4\.21-setup\.exe') 'English Quick Start names the exact setup artifact'
    Assert-CcodTrue ($quickStart -cmatch 'CodexRemote-fix-2\.4\.21-setup\.exe\.sha256\.txt') 'English Quick Start names the exact checksum artifact'
    Assert-CcodTrue ($quickStart -cnotmatch '(?i)powershell|Install-CodexControlOtherDevices') 'English Quick Start does not teach PowerShell installation'
    Assert-CcodTrue ($quickStart -cmatch '\*\*CodexRemote-fix\*\*') 'English Quick Start names the public desktop shortcut'

    $quickStartChineseMatch = [regex]::Match($readmeChinese, '(?ms)^## [^\r\n]+\r?\n(?:\r?\n)?(?=1\.[^\r\n]*\[Releases\])(.*?)(?=^## |\z)')
    Assert-CcodTrue $quickStartChineseMatch.Success 'Chinese README exposes a Quick Start section'
    $quickStartChinese = $quickStartChineseMatch.Groups[1].Value
    Assert-CcodTrue ($quickStartChinese -cmatch 'CodexRemote-fix-2\.4\.21-setup\.exe') 'Chinese Quick Start names the exact setup artifact'
    Assert-CcodTrue ($quickStartChinese -cmatch 'CodexRemote-fix-2\.4\.21-setup\.exe\.sha256\.txt') 'Chinese Quick Start names the exact checksum artifact'
    Assert-CcodTrue ($quickStartChinese -cnotmatch '(?i)powershell|Install-CodexControlOtherDevices') 'Chinese Quick Start does not teach PowerShell installation'
    Assert-CcodTrue ($quickStartChinese -cmatch '\*\*CodexRemote-fix\*\*') 'Chinese Quick Start names the public desktop shortcut'

    Assert-CcodTrue ($readme -cmatch 'uninstall \*\*CodexRemote-fix\*\* from') 'English uninstall instructions use the public product name'
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
