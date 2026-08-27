$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestSupport.ps1')

$repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$harnessPath = Join-Path $repositoryRoot 'tests\installed\Invoke-InstalledLifecycleIntegration.ps1'

function New-CcodHarnessFixture {
    $root = Join-Path $env:TEMP ('ccod-installed-harness-' + [guid]::NewGuid().ToString('N'))
    $null = [IO.Directory]::CreateDirectory($root)
    $installer = Join-Path $root 'CodexRemote-fix-2.5.0-setup.exe'
    [IO.File]::WriteAllBytes($installer, [byte[]](1,2,3,4,5,6,7,8))
    $hash = Get-CcodTestFileSha256 -Path $installer
    $checksum = "$installer.sha256.txt"
    [IO.File]::WriteAllText($checksum, ("{0} *{1}`r`n" -f $hash, [IO.Path]::GetFileName($installer)), [Text.UTF8Encoding]::new($false))
    return [pscustomobject]@{
        Root = $root
        Installer = $installer
        EvidenceRoot = Join-Path $root 'evidence'
        InstallerHash = $hash
    }
}

function New-CcodHarnessCandidate {
    param([Parameter(Mandatory)]$Fixture, [Parameter(Mandatory)][string]$Version)
    $installer = Join-Path $Fixture.Root ("CodexRemote-fix-$Version-setup.exe")
    [IO.File]::WriteAllBytes($installer, [byte[]](8,7,6,5,4,3,2,1))
    $hash = Get-CcodTestFileSha256 -Path $installer
    [IO.File]::WriteAllText("$installer.sha256.txt", ("{0} *{1}`r`n" -f $hash, [IO.Path]::GetFileName($installer)), [Text.UTF8Encoding]::new($false))
    return $installer
}

function New-CcodHarnessFacts {
    param(
        [string]$Version = '2.5.0',
        [string]$RuntimeId = 'runtime-1',
        [int]$CodexPid = 102,
        [string]$CodexCreationTimeUtc = '2026-08-24T00:00:02.0000000Z',
        [string]$StatusRuntimeId = $RuntimeId,
        [int]$StatusCodexPid = $CodexPid,
        [string]$StatusCodexCreationTimeUtc = $CodexCreationTimeUtc,
        [string]$ReceiptPhase = 'Completed'
    )
    return [pscustomobject][ordered]@{
        appPresent = $true
        activeRuntimeId = $RuntimeId
        activeGeneration = [UInt64]1
        runtimeManifestSha256 = ('a' * 64)
        supervisor = @([pscustomobject]@{ pid = 100; creationTimeUtc = '2026-08-24T00:00:00.0000000Z' })
        trayHost = @([pscustomobject]@{ pid = 101; creationTimeUtc = '2026-08-24T00:00:01.0000000Z' })
        codex = @([pscustomobject]@{ pid = $CodexPid; creationTimeUtc = $CodexCreationTimeUtc })
        taskState = 'Ready'
        statusPhase = 'Active'
        statusRuntimeId = $StatusRuntimeId
        statusCodex = [pscustomobject][ordered]@{ pid = $StatusCodexPid; creationTimeUtc = $StatusCodexCreationTimeUtc }
        transitionStage = 'Idle'
        lifecycleReceipt = [pscustomobject][ordered]@{
            kind = 'RestartAndRepair'
            origin = 'Installer'
            runtimeId = $RuntimeId
            runtimeGeneration = [UInt64]1
            phase = $ReceiptPhase
        }
        aboutVersion = $Version
        deviceKeyPresent = $true
        deviceKeySha256 = ('b' * 64)
        shortcuts = [pscustomobject]@{ startMenu = $true; desktop = $true }
        privatePath = 'C:\\Users\\Alice\\.codex\\remote-control-device-keys.windows.json'
        token = 'do-not-store-this'
        userName = 'Alice'
        conversation = 'private conversation content must never enter evidence'
    }
}

function Write-CcodHarnessJson {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value)
    $null = [IO.Directory]::CreateDirectory((Split-Path $Path -Parent))
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 16 -Compress), [Text.UTF8Encoding]::new($false))
}

function New-CcodHarnessLifecycleReceipt {
    param(
        [Parameter(Mandatory)][string]$RuntimeId,
        [Parameter(Mandatory)][UInt64]$RuntimeGeneration,
        [Parameter(Mandatory)][string]$Phase,
        [string]$TransactionId = '11111111-2222-3333-4444-555555555555',
        [string]$UpdatedAtUtc = '2026-08-24T00:00:05.0000000Z'
    )
    return [ordered]@{
        schemaVersion = 1
        transactionId = $TransactionId
        kind = 'RestartAndRepair'
        origin = 'Installer'
        runtimeId = $RuntimeId
        runtimeGeneration = $RuntimeGeneration
        leaseEpoch = [UInt64]9
        ownerIdentity = [ordered]@{ pid = 700; creationTimeUtc = '2026-08-24T00:00:00.0000000Z' }
        logonIdentity = [ordered]@{ authenticationId = '00000000:000003E7'; userSid = 'S-1-5-21-1-2-3-1001'; sessionId = 2 }
        phase = $Phase
        createdAtUtc = '2026-08-24T00:00:01.0000000Z'
        updatedAtUtc = $UpdatedAtUtc
        launchRequestedAtUtc = '2026-08-24T00:00:02.0000000Z'
        manualLaunchExpiresAtUtc = $null
        automaticLaunchAttempts = 1
        error = if ($Phase -ceq 'Completed') { $null } else { 'CCOD_CLOSE_FAILED' }
    }
}

function New-CcodHarnessInstalledStateFixture {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ActiveRuntimeId,
        [Parameter(Mandatory)][UInt64]$ActiveGeneration,
        [Parameter(Mandatory)][string]$StatusRuntimeId,
        [Parameter(Mandatory)][int]$StatusCodexPid,
        [Parameter(Mandatory)][string]$StatusCodexCreationTimeUtc,
        [Parameter(Mandatory)][string]$ReceiptPhase
    )
    $active = [ordered]@{
        schemaVersion = 2
        activeRuntime = $ActiveRuntimeId
        previousRuntime = '2.5.19-old'
        generation = $ActiveGeneration
        updatedAtUtc = '2026-08-24T00:00:03.0000000Z'
    }
    $status = [ordered]@{
        schemaVersion = 1
        session = [ordered]@{
            supervisorPid = 700
            supervisorCreationTimeUtc = '2026-08-24T00:00:00.0000000Z'
            sessionId = 'session-1'
            runtimeId = $StatusRuntimeId
            sessionState = 'Active'
            codex = [ordered]@{
                pid = $StatusCodexPid
                creationTimeUtc = $StatusCodexCreationTimeUtc
                packageFullName = 'OpenAI.Codex_1.0.0.0_x64__test'
                packageVersion = '1.0.0.0'
                appAsarSha256 = ('c' * 64)
                mainPort = 41001
                rendererPort = 41002
                mainProbe = 'Closed'
                rendererProbe = 'BridgeValid'
            }
        }
    }
    $transition = [ordered]@{ schemaVersion = 1; activeTransaction = $null }
    $receipt = New-CcodHarnessLifecycleReceipt -RuntimeId $ActiveRuntimeId -RuntimeGeneration $ActiveGeneration -Phase $ReceiptPhase
    Write-CcodHarnessJson -Path (Join-Path $Root 'active.json') -Value $active
    $manifestPath = Join-Path (Join-Path (Join-Path $Root 'runtime') $ActiveRuntimeId) 'manifest.json'
    Write-CcodHarnessJson -Path $manifestPath -Value ([ordered]@{ schemaVersion = 1; runtimeId = $ActiveRuntimeId })
    Write-CcodHarnessJson -Path (Join-Path $Root 'state\status.json') -Value $status
    Write-CcodHarnessJson -Path (Join-Path $Root 'state\transition.json') -Value $transition
    Write-CcodHarnessJson -Path (Join-Path $Root ("state\lifecycle\receipts\{0}.json" -f $receipt.transactionId)) -Value $receipt
}

function Set-CcodHarnessProcessFixture {
    param([object[]]$ChatGPT, [object[]]$Codex = @())
    $script:CcodHarnessProcessFixture = [pscustomobject]@{ ChatGPT = @($ChatGPT); Codex = @($Codex) }
    function global:Get-CimInstance {
        param($ClassName, $Filter, $ErrorAction)
        if ([string]$Filter -cmatch "Name = 'ChatGPT.exe'") { return @($script:CcodHarnessProcessFixture.ChatGPT) }
        if ([string]$Filter -cmatch "Name = 'Codex.exe'") { return @($script:CcodHarnessProcessFixture.Codex) }
        return @()
    }
    function global:Get-ScheduledTask {
        param($ErrorAction)
        return @([pscustomobject]@{ TaskName = 'Codex Control Other Devices Supervisor'; State = 'Ready' })
    }
}

function Clear-CcodHarnessProcessFixture {
    Remove-Item -LiteralPath Function:\Get-CimInstance -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath Function:\Get-ScheduledTask -Force -ErrorAction SilentlyContinue
    $script:CcodHarnessProcessFixture = $null
}

function New-CcodHarnessCimProcess {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int]$ProcessId,
        [Parameter(Mandatory)][string]$CreationTimeUtc,
        [Parameter(Mandatory)][string]$CommandLine,
        [int]$ParentProcessId = 0
    )
    $created = [datetime]::ParseExact($CreationTimeUtc, 'o', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
    return [pscustomobject][ordered]@{
        Name = $Name
        ProcessId = $ProcessId
        ParentProcessId = $ParentProcessId
        CreationDate = [Management.ManagementDateTimeConverter]::ToDmtfDateTime($created)
        CommandLine = $CommandLine
        ExecutablePath = "C:\Program Files\WindowsApps\OpenAI.Codex\$Name"
    }
}

function Invoke-CcodHarnessWithCapturedFacts {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$BeforeFacts, [Parameter(Mandatory)]$AfterFacts)
    $original = ${function:Get-CcodInstalledLifecycleFacts}
    try {
        Set-Item -LiteralPath Function:\Get-CcodInstalledLifecycleFacts -Value ({ param($InstallRoot) return $AfterFacts }.GetNewClosure())
        return Test-CcodInstalledLifecycleScenario -Context $Context -BeforeFacts $BeforeFacts -RunResult ([pscustomobject]@{ code = 'CCOD_INTEGRATION_OPERATOR_COMPLETED' })
    } finally {
        Set-Item -LiteralPath Function:\Get-CcodInstalledLifecycleFacts -Value $original
    }
}

function New-CcodHarnessAdapters {
    param(
        [Parameter(Mandatory)]$Fixture,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[string]]$Calls,
        [switch]$FailScenario,
        [switch]$DirtyCheckout,
        [ref]$CapturedReceipt
    )

    $before = New-CcodHarnessFacts
    $after = New-CcodHarnessFacts
    return @{
        GetGitStatus = {
            param($RepositoryRoot)
            $Calls.Add('GetGitStatus')
            if ($DirtyCheckout) { return @(' M src\\unsafe.ps1') }
            return @()
        }.GetNewClosure()
        GetFileSha256 = {
            param($Path)
            $Calls.Add('GetFileSha256')
            return Get-CcodTestFileSha256 -Path $Path
        }.GetNewClosure()
        ReadText = {
            param($Path)
            $Calls.Add('ReadText')
            return [IO.File]::ReadAllText($Path)
        }.GetNewClosure()
        NewEvidenceDirectory = {
            param($EvidenceRoot, $TransactionId)
            $Calls.Add('NewEvidenceDirectory')
            return [IO.Path]::GetFullPath((Join-Path $Fixture.Root ('evidence-' + $TransactionId)))
        }.GetNewClosure()
        WriteEvidence = {
            param($EvidenceDirectory, $Receipt)
            $Calls.Add('WriteEvidence')
            $CapturedReceipt.Value = $Receipt
            return [IO.Path]::GetFullPath((Join-Path $EvidenceDirectory 'receipt.json'))
        }.GetNewClosure()
        CaptureFacts = {
            param($InstallRoot)
            $Calls.Add('CaptureFacts')
            if (($Calls | Where-Object { $_ -eq 'RunScenario' }).Count -eq 0) { return $before }
            return $after
        }.GetNewClosure()
        CreateRollbackSnapshot = {
            param($Context, $Facts)
            $Calls.Add('CreateRollbackSnapshot')
            return [pscustomobject]@{ id = 'rollback-1'; internalPath = 'C:\\private\\rollback' }
        }.GetNewClosure()
        RunScenario = {
            param($Context)
            $Calls.Add('RunScenario')
            if ($FailScenario) { throw [InvalidOperationException]::new('operator scenario failed') }
            return [pscustomobject]@{ code = 'CCOD_OPERATOR_COMPLETED'; operatorAttestation = 'accepted'; privatePath = 'C:\\private\\operator' }
        }.GetNewClosure()
        VerifyScenario = {
            param($Context, $BeforeFacts, $RunResult)
            $Calls.Add('VerifyScenario')
            return [pscustomobject]@{ verified = $true; code = 'CCOD_INTEGRATION_VERIFIED'; facts = $after; token = 'never-persist' }
        }.GetNewClosure()
        Rollback = {
            param($Context, $Snapshot)
            $Calls.Add('Rollback')
            return [pscustomobject]@{ restored = $true; code = 'CCOD_INTEGRATION_ROLLBACK_COMPLETED' }
        }.GetNewClosure()
        CleanupRollback = {
            param($Context, $Snapshot)
            $Calls.Add('CleanupRollback')
            return $true
        }.GetNewClosure()
        GetUtcNow = {
            $Calls.Add('GetUtcNow')
            return [datetime]::Parse('2026-08-24T00:00:00Z').ToUniversalTime()
        }.GetNewClosure()
    }
}

Invoke-CcodTest 'installed lifecycle harness exposes the guarded library interface' {
    Assert-CcodTrue (Test-Path -LiteralPath $harnessPath -PathType Leaf) 'installed lifecycle harness exists'
    . $harnessPath -Library
    Assert-CcodTrue ($null -ne (Get-Command Invoke-CcodInstalledLifecycleIntegration -ErrorAction SilentlyContinue)) 'harness exports its invocation function when loaded as a library'
}

# Production mutation caught: FreshRestart ignores stale status and a current-runtime CloseFailed receipt.
Invoke-CcodTest 'rejects FreshRestart when current active runtime has stale status and a CloseFailed installer receipt' {
    . $harnessPath -Library
    $before = New-CcodHarnessFacts -RuntimeId '2.5.19-old' -CodexPid 10664
    $after = New-CcodHarnessFacts -RuntimeId '2.5.21-new' -CodexPid 13948 `
        -StatusRuntimeId '2.5.19-old' -StatusCodexPid 10664 -ReceiptPhase 'CloseFailed'
    $context = [pscustomobject]@{ scenario = 'FreshRestart'; expectedVersion = '2.5.0'; installRoot = 'C:\fixture' }
    $verification = Invoke-CcodHarnessWithCapturedFacts -Context $context -BeforeFacts $before -AfterFacts $after
    Assert-CcodEqual $false $verification.verified 'stale status and CloseFailed terminal state leave FreshRestart unverified'
    Assert-CcodEqual 'CCOD_INTEGRATION_OBSERVATION_UNPROVEN' $verification.code 'rejection uses the stable observation code'
}

# Production mutation caught: querying Codex.exe instead of the Windows app root ChatGPT.exe.
Invoke-CcodTest 'captures exactly the top-level ChatGPT root and excludes Electron type children' {
    . $harnessPath -Library
    $root = Join-Path $env:TEMP ('ccod-installed-capture-' + [guid]::NewGuid().ToString('N'))
    try {
        $null = [IO.Directory]::CreateDirectory($root)
        $created = '2026-08-24T00:00:04.0000000Z'
        Set-CcodHarnessProcessFixture -ChatGPT @(
            (New-CcodHarnessCimProcess -Name 'ChatGPT.exe' -ProcessId 13948 -CreationTimeUtc $created -CommandLine '"C:\Program Files\WindowsApps\OpenAI.Codex\ChatGPT.exe"'),
            (New-CcodHarnessCimProcess -Name 'ChatGPT.exe' -ProcessId 13949 -CreationTimeUtc '2026-08-24T00:00:04.1000000Z' -CommandLine '"C:\Program Files\WindowsApps\OpenAI.Codex\ChatGPT.exe" --type=renderer' -ParentProcessId 13948),
            (New-CcodHarnessCimProcess -Name 'ChatGPT.exe' -ProcessId 13950 -CreationTimeUtc '2026-08-24T00:00:04.2000000Z' -CommandLine '"C:\Program Files\WindowsApps\OpenAI.Codex\ChatGPT.exe" --type=utility' -ParentProcessId 13948)
        )
        $facts = Get-CcodInstalledLifecycleFacts -InstallRoot $root
        Assert-CcodEqual 1 $facts.codex.Count 'only one ordinary ChatGPT root is retained'
        Assert-CcodEqual 13948 $facts.codex[0].pid 'the ordinary ChatGPT root identity is captured'
        Assert-CcodEqual $created $facts.codex[0].creationTimeUtc 'the root creation time is canonical and retained'
    } finally {
        Clear-CcodHarnessProcessFixture
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

Invoke-CcodTest 'captures bounded current-runtime status transition and latest installer receipt facts from complete schemas' {
    . $harnessPath -Library
    $root = Join-Path $env:TEMP ('ccod-installed-state-' + [guid]::NewGuid().ToString('N'))
    try {
        $null = [IO.Directory]::CreateDirectory($root)
        New-CcodHarnessInstalledStateFixture -Root $root -ActiveRuntimeId '2.5.21-new' -ActiveGeneration ([UInt64]8) `
            -StatusRuntimeId '2.5.19-old' -StatusCodexPid 10664 -StatusCodexCreationTimeUtc '2026-08-24T00:00:02.0000000Z' -ReceiptPhase 'CloseFailed'
        Set-CcodHarnessProcessFixture -ChatGPT @(
            (New-CcodHarnessCimProcess -Name 'ChatGPT.exe' -ProcessId 13948 -CreationTimeUtc '2026-08-24T00:00:04.0000000Z' -CommandLine '"C:\Program Files\WindowsApps\OpenAI.Codex\ChatGPT.exe"'),
            (New-CcodHarnessCimProcess -Name 'ChatGPT.exe' -ProcessId 13949 -CreationTimeUtc '2026-08-24T00:00:04.1000000Z' -CommandLine '"C:\Program Files\WindowsApps\OpenAI.Codex\ChatGPT.exe" --type=renderer' -ParentProcessId 13948)
        )
        $facts = Get-CcodInstalledLifecycleFacts -InstallRoot $root
        Assert-CcodEqual '2.5.21-new' $facts.activeRuntimeId 'active schema 2 supplies the current runtime'
        Assert-CcodEqual 8 ([UInt64]$facts.activeGeneration) 'active schema 2 supplies the current generation'
        Assert-CcodEqual 'Active' $facts.statusPhase 'complete status schema 1 supplies the session state'
        Assert-CcodEqual '2.5.19-old' $facts.statusRuntimeId 'stale status runtime remains visible for correlation rejection'
        Assert-CcodEqual 10664 $facts.statusCodex.pid 'stale status Codex identity remains visible for correlation rejection'
        Assert-CcodEqual 'Idle' $facts.transitionStage 'null active transaction is captured as idle'
        Assert-CcodEqual 'RestartAndRepair' $facts.lifecycleReceipt.kind 'receipt kind is bounded and retained'
        Assert-CcodEqual 'Installer' $facts.lifecycleReceipt.origin 'receipt origin is bounded and retained'
        Assert-CcodEqual '2.5.21-new' $facts.lifecycleReceipt.runtimeId 'latest receipt is bound to the active runtime'
        Assert-CcodEqual 'CloseFailed' $facts.lifecycleReceipt.phase 'terminal receipt failure remains visible'
        $serialized = $facts | ConvertTo-Json -Depth 16 -Compress
        foreach ($forbidden in @('00000000:000003E7','S-1-5-21-1-2-3-1001','OpenAI.Codex_1.0.0.0_x64__test','41001','--type=renderer','C:\Program Files\WindowsApps')) {
            Assert-CcodTrue (-not $serialized.Contains($forbidden)) "captured facts omit private receipt status and command-line data: $forbidden"
        }
    } finally {
        Clear-CcodHarnessProcessFixture
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

Invoke-CcodTest 'selects only an unambiguous latest current-runtime installer restart receipt' {
    . $harnessPath -Library
    $root = Join-Path $env:TEMP ('ccod-installed-receipts-' + [guid]::NewGuid().ToString('N'))
    try {
        $null = [IO.Directory]::CreateDirectory($root)
        New-CcodHarnessInstalledStateFixture -Root $root -ActiveRuntimeId '2.5.21-new' -ActiveGeneration ([UInt64]8) `
            -StatusRuntimeId '2.5.21-new' -StatusCodexPid 13948 -StatusCodexCreationTimeUtc '2026-08-24T00:00:04.0000000Z' -ReceiptPhase 'CloseFailed'
        $completed = New-CcodHarnessLifecycleReceipt -RuntimeId '2.5.21-new' -RuntimeGeneration ([UInt64]8) -Phase 'Completed' `
            -TransactionId '22222222-3333-4444-5555-666666666666' -UpdatedAtUtc '2026-08-24T00:00:06.0000000Z'
        Write-CcodHarnessJson -Path (Join-Path $root ("state\lifecycle\receipts\{0}.json" -f $completed.transactionId)) -Value $completed
        Set-CcodHarnessProcessFixture -ChatGPT @(
            (New-CcodHarnessCimProcess -Name 'ChatGPT.exe' -ProcessId 13948 -CreationTimeUtc '2026-08-24T00:00:04.0000000Z' -CommandLine '"C:\Program Files\WindowsApps\OpenAI.Codex\ChatGPT.exe"')
        )
        $facts = Get-CcodInstalledLifecycleFacts -InstallRoot $root
        Assert-CcodEqual 'Completed' $facts.lifecycleReceipt.phase 'strict receipt selection uses the unique latest updatedAtUtc'

        $ambiguous = New-CcodHarnessLifecycleReceipt -RuntimeId '2.5.21-new' -RuntimeGeneration ([UInt64]8) -Phase 'CloseFailed' `
            -TransactionId '33333333-4444-5555-6666-777777777777' -UpdatedAtUtc '2026-08-24T00:00:06.0000000Z'
        Write-CcodHarnessJson -Path (Join-Path $root ("state\lifecycle\receipts\{0}.json" -f $ambiguous.transactionId)) -Value $ambiguous
        Assert-CcodThrows { Get-CcodInstalledLifecycleFacts -InstallRoot $root } 'CCOD_INTEGRATION_FACTS_INVALID'
    } finally {
        Clear-CcodHarnessProcessFixture
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

# Production mutation caught: treating a Codex.exe-only observation as installed app process evidence.
Invoke-CcodTest 'does not accept a Codex.exe-only fixture as Codex process evidence' {
    . $harnessPath -Library
    $root = Join-Path $env:TEMP ('ccod-installed-capture-' + [guid]::NewGuid().ToString('N'))
    try {
        $null = [IO.Directory]::CreateDirectory($root)
        Set-CcodHarnessProcessFixture -ChatGPT @() -Codex @(
            (New-CcodHarnessCimProcess -Name 'Codex.exe' -ProcessId 10664 -CreationTimeUtc '2026-08-24T00:00:02.0000000Z' -CommandLine '"C:\Program Files\Codex.exe"')
        )
        $facts = Get-CcodInstalledLifecycleFacts -InstallRoot $root
        Assert-CcodEqual 0 $facts.codex.Count 'Codex.exe is not the Windows app root and cannot satisfy process evidence'
    } finally {
        Clear-CcodHarnessProcessFixture
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

Invoke-CcodTest 'verifies FreshRestart only with one correlated ChatGPT root and Completed current-runtime installer receipt' {
    . $harnessPath -Library
    $root = Join-Path $env:TEMP ('ccod-installed-success-' + [guid]::NewGuid().ToString('N'))
    try {
        $null = [IO.Directory]::CreateDirectory($root)
        New-CcodHarnessInstalledStateFixture -Root $root -ActiveRuntimeId '2.5.21-new' -ActiveGeneration ([UInt64]8) `
            -StatusRuntimeId '2.5.21-new' -StatusCodexPid 13948 -StatusCodexCreationTimeUtc '2026-08-24T00:00:04.0000000Z' -ReceiptPhase 'Completed'
        Set-CcodHarnessProcessFixture -ChatGPT @(
            (New-CcodHarnessCimProcess -Name 'ChatGPT.exe' -ProcessId 13948 -CreationTimeUtc '2026-08-24T00:00:04.0000000Z' -CommandLine '"C:\Program Files\WindowsApps\OpenAI.Codex\ChatGPT.exe"'),
            (New-CcodHarnessCimProcess -Name 'ChatGPT.exe' -ProcessId 13949 -CreationTimeUtc '2026-08-24T00:00:04.1000000Z' -CommandLine '"C:\Program Files\WindowsApps\OpenAI.Codex\ChatGPT.exe" --type=renderer' -ParentProcessId 13948)
        )
        $after = Get-CcodInstalledLifecycleFacts -InstallRoot $root
        $after.appPresent = $true
        $after.aboutVersion = '2.5.0'
        $after.deviceKeyPresent = $true
        $after.deviceKeySha256 = ('b' * 64)
        $before = New-CcodHarnessFacts -RuntimeId '2.5.19-old' -CodexPid 10664
        $context = [pscustomobject]@{ scenario = 'FreshRestart'; expectedVersion = '2.5.0'; installRoot = $root }
        $verification = Invoke-CcodHarnessWithCapturedFacts -Context $context -BeforeFacts $before -AfterFacts $after
        Assert-CcodEqual $true $verification.verified 'fully correlated current runtime verifies FreshRestart'
        Assert-CcodEqual 'CCOD_INTEGRATION_VERIFIED' $verification.code 'success retains the stable verification code'
    } finally {
        Clear-CcodHarnessProcessFixture
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

Invoke-CcodTest 'requires mutation and Codex-restart consent before any adapter or filesystem action' {
    . $harnessPath -Library
    $fixture = New-CcodHarnessFixture
    try {
        $calls = [Collections.Generic.List[string]]::new()
        $captured = $null
        $adapters = New-CcodHarnessAdapters -Fixture $fixture -Calls $calls -CapturedReceipt ([ref]$captured)
        Assert-CcodThrows {
            Invoke-CcodInstalledLifecycleIntegration -InstallerPath $fixture.Installer -ExpectedVersion '2.5.0' -EvidenceRoot $fixture.EvidenceRoot -Scenario FreshRestart -Adapters $adapters
        } 'CCOD_INTEGRATION_MUTATION_NOT_ALLOWED'
        Assert-CcodEqual 0 $calls.Count 'mutation rejection precedes every adapter action'
        Assert-CcodThrows {
            Invoke-CcodInstalledLifecycleIntegration -InstallerPath $fixture.Installer -ExpectedVersion '2.5.0' -EvidenceRoot $fixture.EvidenceRoot -Scenario FreshRestart -AllowMachineMutation -Adapters $adapters
        } 'CCOD_INTEGRATION_CODEX_RESTART_NOT_ALLOWED'
        Assert-CcodEqual 0 $calls.Count 'restart rejection also precedes every adapter action'
    } finally {
        if (Test-Path -LiteralPath $fixture.Root) { Remove-Item -LiteralPath $fixture.Root -Recurse -Force }
    }
}

Invoke-CcodTest 'blocks a dirty checkout before snapshot or scenario execution' {
    . $harnessPath -Library
    $fixture = New-CcodHarnessFixture
    try {
        $calls = [Collections.Generic.List[string]]::new()
        $captured = $null
        $adapters = New-CcodHarnessAdapters -Fixture $fixture -Calls $calls -DirtyCheckout -CapturedReceipt ([ref]$captured)
        Assert-CcodThrows {
            Invoke-CcodInstalledLifecycleIntegration -InstallerPath $fixture.Installer -ExpectedVersion '2.5.0' -EvidenceRoot $fixture.EvidenceRoot -Scenario FreshLater -AllowMachineMutation -Adapters $adapters
        } 'CCOD_INTEGRATION_CHECKOUT_DIRTY'
        Assert-CcodTrue ($calls -contains 'GetGitStatus') 'checkout is queried after consent'
        Assert-CcodTrue (-not ($calls -contains 'CreateRollbackSnapshot')) 'dirty checkout cannot create a rollback snapshot'
        Assert-CcodTrue (-not ($calls -contains 'RunScenario')) 'dirty checkout cannot enter a scenario'
    } finally {
        if (Test-Path -LiteralPath $fixture.Root) { Remove-Item -LiteralPath $fixture.Root -Recurse -Force }
    }
}

Invoke-CcodTest 'writes only redacted evidence after a proven fake scenario and cleans its rollback snapshot' {
    . $harnessPath -Library
    $fixture = New-CcodHarnessFixture
    try {
        $calls = [Collections.Generic.List[string]]::new()
        $captured = $null
        $adapters = New-CcodHarnessAdapters -Fixture $fixture -Calls $calls -CapturedReceipt ([ref]$captured)
        $receipt = Invoke-CcodInstalledLifecycleIntegration -InstallerPath $fixture.Installer -ExpectedVersion '2.5.0' -EvidenceRoot $fixture.EvidenceRoot -Scenario FreshLater -AllowMachineMutation -Adapters $adapters
        Assert-CcodEqual 'Completed' ([string]$receipt.outcome) 'valid fake scenario completes'
        Assert-CcodEqual 'FreshLater' ([string]$receipt.scenario) 'receipt preserves the exact scenario'
        Assert-CcodEqual $fixture.InstallerHash ([string]$receipt.installerSha256) 'receipt records the verified installer hash'
        Assert-CcodTrue ($calls -contains 'CreateRollbackSnapshot') 'snapshot occurs before the scenario'
        Assert-CcodTrue ($calls -contains 'RunScenario') 'scenario executes through the injected adapter'
        Assert-CcodTrue ($calls -contains 'VerifyScenario') 'scenario is independently verified'
        Assert-CcodTrue ($calls -contains 'CleanupRollback') 'successful scenario cleans the snapshot'
        Assert-CcodTrue ($calls -contains 'WriteEvidence') 'result is persisted once'
        $serialized = $captured | ConvertTo-Json -Depth 16 -Compress
        foreach ($forbidden in @('Alice', 'C:\\Users\\Alice', 'do-not-store-this', 'never-persist', 'C:\\private', 'private conversation content')) {
            Assert-CcodTrue (-not $serialized.Contains($forbidden)) "evidence redacts $forbidden"
        }
        Assert-CcodTrue ($serialized.Contains('deviceKeySha256')) 'evidence retains the permitted device-key hash'
    } finally {
        if (Test-Path -LiteralPath $fixture.Root) { Remove-Item -LiteralPath $fixture.Root -Recurse -Force }
    }
}

Invoke-CcodTest 'rolls back, records a redacted failure receipt, and raises a stable scenario code' {
    . $harnessPath -Library
    $fixture = New-CcodHarnessFixture
    try {
        $calls = [Collections.Generic.List[string]]::new()
        $captured = $null
        $adapters = New-CcodHarnessAdapters -Fixture $fixture -Calls $calls -FailScenario -CapturedReceipt ([ref]$captured)
        Assert-CcodThrows {
            Invoke-CcodInstalledLifecycleIntegration -InstallerPath $fixture.Installer -ExpectedVersion '2.5.0' -EvidenceRoot $fixture.EvidenceRoot -Scenario FreshLater -AllowMachineMutation -Adapters $adapters
        } 'CCOD_INTEGRATION_SCENARIO_FAILED'
        Assert-CcodTrue ($calls -contains 'Rollback') 'failed scenario restores the captured snapshot before returning'
        Assert-CcodTrue ($calls -contains 'CleanupRollback') 'failed scenario cleans the rollback material'
        Assert-CcodTrue ($calls -contains 'WriteEvidence') 'failed scenario writes a durable failure receipt'
        Assert-CcodEqual 'Failed' ([string]$captured.outcome) 'failure receipt is explicit'
        $serialized = $captured | ConvertTo-Json -Depth 16 -Compress
        Assert-CcodTrue (-not $serialized.Contains('C:\\private')) 'failure evidence also redacts internal paths'
    } finally {
        if (Test-Path -LiteralPath $fixture.Root) { Remove-Item -LiteralPath $fixture.Root -Recurse -Force }
    }
}

Invoke-CcodTest 'accepts only a distinct checksum-bound prior installer for an upgrade rollback path' {
    . $harnessPath -Library
    $fixture = New-CcodHarnessFixture
    try {
        $previous = New-CcodHarnessCandidate -Fixture $fixture -Version '2.4.24'
        $calls = [Collections.Generic.List[string]]::new()
        $captured = $null
        $adapters = New-CcodHarnessAdapters -Fixture $fixture -Calls $calls -CapturedReceipt ([ref]$captured)
        $receipt = Invoke-CcodInstalledLifecycleIntegration -InstallerPath $fixture.Installer -PreviousInstallerPath $previous -ExpectedVersion '2.5.0' -EvidenceRoot $fixture.EvidenceRoot -Scenario Upgrade -AllowMachineMutation -AllowCodexRestart -Adapters $adapters
        Assert-CcodEqual 'Completed' ([string]$receipt.outcome) 'distinct prior installer can support a checked upgrade run'
        Assert-CcodThrows {
            Invoke-CcodInstalledLifecycleIntegration -InstallerPath $fixture.Installer -PreviousInstallerPath $fixture.Installer -ExpectedVersion '2.5.0' -EvidenceRoot $fixture.EvidenceRoot -Scenario Upgrade -AllowMachineMutation -AllowCodexRestart -Adapters $adapters
        } 'CCOD_INTEGRATION_PREVIOUS_INSTALLER_INVALID'
        $future = New-CcodHarnessCandidate -Fixture $fixture -Version '2.5.1'
        Assert-CcodThrows {
            Invoke-CcodInstalledLifecycleIntegration -InstallerPath $fixture.Installer -PreviousInstallerPath $future -ExpectedVersion '2.5.0' -EvidenceRoot $fixture.EvidenceRoot -Scenario Upgrade -AllowMachineMutation -AllowCodexRestart -Adapters $adapters
        } 'CCOD_INTEGRATION_PREVIOUS_INSTALLER_INVALID'
    } finally {
        if (Test-Path -LiteralPath $fixture.Root) { Remove-Item -LiteralPath $fixture.Root -Recurse -Force }
    }
}

Invoke-CcodTest 'rejects an installer checksum mismatch before snapshot or scenario work' {
    . $harnessPath -Library
    $fixture = New-CcodHarnessFixture
    try {
        [IO.File]::WriteAllText("$($fixture.Installer).sha256.txt", ("{0} *{1}`r`n" -f ('0' * 64), [IO.Path]::GetFileName($fixture.Installer)), [Text.UTF8Encoding]::new($false))
        $calls = [Collections.Generic.List[string]]::new()
        $captured = $null
        $adapters = New-CcodHarnessAdapters -Fixture $fixture -Calls $calls -CapturedReceipt ([ref]$captured)
        Assert-CcodThrows {
            Invoke-CcodInstalledLifecycleIntegration -InstallerPath $fixture.Installer -ExpectedVersion '2.5.0' -EvidenceRoot $fixture.EvidenceRoot -Scenario FreshLater -AllowMachineMutation -Adapters $adapters
        } 'CCOD_INTEGRATION_CHECKSUM_INVALID'
        Assert-CcodTrue (-not ($calls -contains 'CreateRollbackSnapshot')) 'mismatched candidate cannot snapshot the machine'
        Assert-CcodTrue (-not ($calls -contains 'RunScenario')) 'mismatched candidate cannot run'
    } finally {
        if (Test-Path -LiteralPath $fixture.Root) { Remove-Item -LiteralPath $fixture.Root -Recurse -Force }
    }
}

Write-Host 'Installed lifecycle harness self-tests passed.'
