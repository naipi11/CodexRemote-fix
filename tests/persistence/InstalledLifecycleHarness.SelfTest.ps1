$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestSupport.ps1')
Restore-CcodTestDesktopModulePath

$repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$harnessPath = Join-Path $repositoryRoot 'tests\installed\Invoke-InstalledLifecycleIntegration.ps1'

function New-CcodHarnessFixture {
    $root = Join-Path (Get-CcodTestCanonicalTempRoot) ('ccod-installed-harness-' + [guid]::NewGuid().ToString('N'))
    $null = [IO.Directory]::CreateDirectory($root)
    $installer = Join-Path $root 'CodexRemote-fix-2.5.0-setup.exe'
    [IO.File]::WriteAllBytes($installer, [byte[]](1,2,3,4,5,6,7,8))
    $hash = Get-CcodTestFileSha256 -Path $installer
    $checksum = "$installer.sha256.txt"
    [IO.File]::WriteAllText($checksum, ("{0} *{1}`r`n" -f $hash, [IO.Path]::GetFileName($installer)), [Text.UTF8Encoding]::new($false))
    $payload = [ordered]@{ schemaVersion = 1; projectVersion = '2.5.0'; files = @([ordered]@{ path = 'package.json'; length = [int64]1; sha256 = ('e' * 64) }) }
    [IO.File]::WriteAllText((Join-Path $root 'CodexRemote-fix-2.5.0-setup-payload-manifest.json'), ($payload | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    return [pscustomobject]@{
        Root = $root
        Installer = $installer
        EvidenceRoot = Join-Path $root 'evidence'
        InstallerHash = $hash
    }
}

function New-CcodHarnessSealedFixture {
    $source=Join-Path $repositoryRoot 'tests/persistence/ReleaseWorkflow.SelfTest.ps1'
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
    Assert-CcodEqual 0 @($errors).Count 'shared sealed fixture source parses'
    foreach($name in @('Get-CcodTask5ExpectedAssetNames','Write-CcodTask5Json','New-CcodTask5ExactAssetFixture')){
        $definitions=@($ast.EndBlock.Statements|Where-Object {$_-is[Management.Automation.Language.FunctionDefinitionAst]-and$_.Name-ceq$name})
        Assert-CcodEqual 1 $definitions.Count 'one shared fixture definition is loaded without executing release tests'
        . ([scriptblock]::Create($definitions[0].Extent.Text))
    }
    return New-CcodTask5ExactAssetFixture
}

function New-CcodHarnessCandidate {
    param(
        [Parameter(Mandatory)]$Fixture,
        [Parameter(Mandatory)][string]$Version,
        [byte[]]$Bytes = [byte[]](8,7,6,5,4,3,2,1)
    )
    $installer = Join-Path $Fixture.Root ("CodexRemote-fix-$Version-setup.exe")
    [IO.File]::WriteAllBytes($installer, $Bytes)
    $hash = Get-CcodTestFileSha256 -Path $installer
    [IO.File]::WriteAllText("$installer.sha256.txt", ("{0} *{1}`r`n" -f $hash, [IO.Path]::GetFileName($installer)), [Text.UTF8Encoding]::new($false))
    $payload = [ordered]@{ schemaVersion = 1; projectVersion = $Version; files = @([ordered]@{ path = 'package.json'; length = [int64]1; sha256 = ('e' * 64) }) }
    [IO.File]::WriteAllText((Join-Path $Fixture.Root ("CodexRemote-fix-$Version-setup-payload-manifest.json")), ($payload | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
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
        installRootPresent = $true
        appPresent = $true
        runtimeRootPresent = $true
        activePointerPresent = $true
        installReady = $true
        activeRuntimeId = $RuntimeId
        activeGeneration = [UInt64]1
        runtimeManifestSha256 = ('a' * 64)
        runtimeManifestFiles = @([pscustomobject][ordered]@{ path = 'package.json'; length = [int64]1; sha256 = ('e' * 64) })
        supervisor = @([pscustomobject]@{ pid = 100; creationTimeUtc = '2026-08-24T00:00:00.0000000Z' })
        trayHost = @([pscustomobject]@{ pid = 101; creationTimeUtc = '2026-08-24T00:00:01.0000000Z' })
        trayHostIdentity = [pscustomobject][ordered]@{ pid = 101; creationTimeUtc = '2026-08-24T00:00:01.0000000Z' }
        trayAuthenticated = $true
        codex = @([pscustomobject]@{ pid = $CodexPid; creationTimeUtc = $CodexCreationTimeUtc })
        taskState = 'Ready'
        statusPhase = 'Active'
        statusRuntimeId = $StatusRuntimeId
        statusCodex = [pscustomobject][ordered]@{ pid = $StatusCodexPid; creationTimeUtc = $StatusCodexCreationTimeUtc }
        transitionStage = 'Idle'
        protectionReady = $true
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
        debugEndpoints = @(
            [pscustomobject][ordered]@{ localAddress = '127.0.0.1'; localPort = 9229; owningProcess = $CodexPid; owningProcessCreationTimeUtc = $CodexCreationTimeUtc }
            [pscustomobject][ordered]@{ localAddress = '127.0.0.1'; localPort = 9230; owningProcess = $CodexPid; owningProcessCreationTimeUtc = $CodexCreationTimeUtc }
        )
        debugPorts = @(9229,9230)
        privatePath = 'fixture-private-key.json'
        token = 'do-not-store-this'
        userName = 'Alice'
        conversation = 'private conversation content must never enter evidence'
    }
}

function New-CcodHarnessAbsentFacts {
    param([switch]$WithoutDeviceKey)
    $facts = New-CcodHarnessFacts
    foreach ($name in @('installRootPresent','appPresent','runtimeRootPresent','activePointerPresent','installReady','trayAuthenticated','protectionReady')) { $facts.$name = $false }
    foreach ($name in @('activeRuntimeId','activeGeneration','runtimeManifestSha256','trayHostIdentity','statusRuntimeId','statusCodex','lifecycleReceipt','aboutVersion')) { $facts.$name = $null }
    foreach ($name in @('runtimeManifestFiles','supervisor','trayHost','codex','debugPorts','debugEndpoints')) { $facts.$name = @() }
    $facts.taskState = 'Absent'; $facts.statusPhase = 'Unavailable'; $facts.transitionStage = 'Unavailable'
    $facts.shortcuts = [pscustomobject][ordered]@{ startMenu = $false; desktop = $false }
    if ($WithoutDeviceKey) { $facts.deviceKeyPresent = $false; $facts.deviceKeySha256 = $null }
    return $facts
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
        [Parameter(Mandatory)][string]$ReceiptPhase,
        [int]$StatusMainPort = 41001,
        [int]$StatusRendererPort = 41002
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
                mainPort = $StatusMainPort
                rendererPort = $StatusRendererPort
                mainProbe = 'Closed'
                rendererProbe = 'BridgeValid'
            }
        }
    }
    $transition = [ordered]@{ schemaVersion = 1; activeTransaction = $null }
    $receipt = New-CcodHarnessLifecycleReceipt -RuntimeId $ActiveRuntimeId -RuntimeGeneration $ActiveGeneration -Phase $ReceiptPhase
    Write-CcodHarnessJson -Path (Join-Path $Root 'active.json') -Value $active
    $manifestPath = Join-Path (Join-Path (Join-Path $Root 'runtime') $ActiveRuntimeId) 'manifest.json'
    Write-CcodHarnessJson -Path $manifestPath -Value ([ordered]@{ schemaVersion = 1; projectVersion = '2.5.21'; runtimeId = $ActiveRuntimeId; files = @() })
    Write-CcodHarnessJson -Path (Join-Path $Root 'state\status.json') -Value $status
    Write-CcodHarnessJson -Path (Join-Path $Root 'state\transition.json') -Value $transition
    Write-CcodHarnessJson -Path (Join-Path $Root ("state\lifecycle\receipts\{0}.json" -f $receipt.transactionId)) -Value $receipt
}

function Set-CcodHarnessProcessFixture {
    param([object[]]$ChatGPT, [object[]]$Codex = @())
    $script:CcodHarnessProcessFixture = [pscustomobject]@{ ChatGPT = @($ChatGPT); Codex = @($Codex) }
    function global:Get-Process {
        param($Id,$ErrorAction)
        if(-not$script:CcodHarnessNativeCreation.ContainsKey([int]$Id)){throw 'unknown fixture native process'}
        $value=[pscustomobject]@{Id=[int]$Id;StartTime=[datetime]::ParseExact($script:CcodHarnessNativeCreation[[int]$Id],'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind);HasExited=$false}
        $value|Add-Member ScriptMethod Dispose {};return $value
    }
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
    Remove-Item -LiteralPath Function:\Get-Process -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath Function:\Get-CimInstance -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath Function:\Get-ScheduledTask -Force -ErrorAction SilentlyContinue
    $script:CcodHarnessProcessFixture = $null
}

function New-CcodHarnessCimProcess {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int]$ProcessId,
        [Parameter(Mandatory)][string]$CreationTimeUtc,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$CommandLine,
        [int]$ParentProcessId = 0
    )
    $created = [datetime]::ParseExact($CreationTimeUtc, 'o', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
    if($null-eq(Get-Variable CcodHarnessNativeCreation -Scope Script -ErrorAction SilentlyContinue)){$script:CcodHarnessNativeCreation=@{}}
    $script:CcodHarnessNativeCreation[$ProcessId]=$CreationTimeUtc
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
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$BeforeFacts, [Parameter(Mandatory)]$AfterFacts, [ref]$ObservedExpectedDebugPorts, $RunResult,
        [object[]]$PostUninstallListeners = @(), [switch]$FailUninstallEnumeration, [ref]$ObservedUninstallEnumeration)
    if ($null -eq $Context.PSObject.Properties['transactionId']) { $Context | Add-Member -NotePropertyName transactionId -NotePropertyValue '11111111-2222-3333-4444-555555555555' }
    if ($null -eq $Context.PSObject.Properties['installerSha256']) { $Context | Add-Member -NotePropertyName installerSha256 -NotePropertyValue ('a' * 64) }
    if ($null -eq $Context.PSObject.Properties['candidatePayloadFiles']) { $Context | Add-Member -NotePropertyName candidatePayloadFiles -NotePropertyValue @($AfterFacts.runtimeManifestFiles) }
    $original = ${function:Get-CcodInstalledLifecycleFacts}
    $originalNetTcp = ${function:Get-NetTCPConnection}
    $uninstallFixture = $Context.scenario -in @('SettingsUninstall','DirectUninstall')
    try {
        if ($uninstallFixture) {
            Set-Item -LiteralPath Function:\global:Get-NetTCPConnection -Value ({
                param($State,$ErrorAction)
                if ($null -ne $ObservedUninstallEnumeration) { $ObservedUninstallEnumeration.Value = [int]$ObservedUninstallEnumeration.Value + 1 }
                if ($FailUninstallEnumeration) { throw [IO.IOException]::new('fixture listener enumeration unavailable') }
                return @($PostUninstallListeners)
            }.GetNewClosure())
        }
        Set-Item -LiteralPath Function:\Get-CcodInstalledLifecycleFacts -Value ({
            param($InstallRoot,$ExpectedVersion,$ExpectedDebugPorts)
            if ($null -ne $ObservedExpectedDebugPorts) {
                $ObservedExpectedDebugPorts.Value = if ($null -eq $ExpectedDebugPorts) { 'none' } else { (@($ExpectedDebugPorts) -join ',') }
            }
            return $AfterFacts
        }.GetNewClosure())
        $effectiveRunResult = if ($null -eq $RunResult) {
            $runtimeManifest = if ($Context.scenario -in @('FreshInstall','FreshLater','FreshRestart','Upgrade','SlowLaunch','ManualLaunchResume','LanguageStress','RepairStates')) { [string]$AfterFacts.runtimeManifestSha256 } else { $null }
            [pscustomobject][ordered]@{ code = 'CCOD_INTEGRATION_OPERATOR_COMPLETED'; scenario = [string]$Context.scenario; transactionId = [string]$Context.transactionId; completed = $true; operatorAttestation = 'OperatorConfirmed'; installerSha256 = [string]$Context.installerSha256; runtimeManifestSha256 = $runtimeManifest }
        } else { $RunResult }
        return Test-CcodInstalledLifecycleScenario -Context $Context -BeforeFacts $BeforeFacts -RunResult $effectiveRunResult
    } finally {
        Set-Item -LiteralPath Function:\Get-CcodInstalledLifecycleFacts -Value $original
        if ($uninstallFixture) {
            if ($null -eq $originalNetTcp) { Remove-Item -LiteralPath Function:\global:Get-NetTCPConnection -Force -ErrorAction SilentlyContinue }
            else { Set-Item -LiteralPath Function:\global:Get-NetTCPConnection -Value $originalNetTcp }
        }
    }
}

function New-CcodHarnessAdapters {
    param(
        [Parameter(Mandatory)]$Fixture,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[string]]$Calls,
        [switch]$FailScenario,
        [switch]$DirtyCheckout,
        [string]$ReplacePreviousAfterValidation,
        [switch]$RecordRollbackIdentity,
        [string]$BeforeVersion = '2.5.0',
        [string]$AfterVersion,
        [ref]$CapturedReceipt
    )

    $resolvedAfterVersion = if ([string]::IsNullOrWhiteSpace($AfterVersion)) { $BeforeVersion } else { $AfterVersion }
    $before = New-CcodHarnessFacts -Version $BeforeVersion
    $after = New-CcodHarnessFacts -Version $resolvedAfterVersion
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
            $directory = [IO.Directory]::CreateDirectory($EvidenceDirectory).FullName
            $path = [IO.Path]::GetFullPath((Join-Path $directory 'receipt.json'))
            $json = ($Receipt | ConvertTo-Json -Depth 16)
            $stream = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try { $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json); $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
            $readback = [IO.File]::ReadAllText($path, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json -ErrorAction Stop
            if ($null -eq $readback) { throw 'fixture evidence readback failed' }
            $CapturedReceipt.Value = $readback
            return $path
        }.GetNewClosure()
        CaptureFacts = {
            param($InstallRoot,$ExpectedVersion)
            $Calls.Add('CaptureFacts:' + [string]$ExpectedVersion)
            if (-not [string]::IsNullOrWhiteSpace($ReplacePreviousAfterValidation) -and -not ($Calls -contains 'ReplacePreviousAfterValidation')) {
                $Calls.Add('ReplacePreviousAfterValidation')
                [IO.File]::WriteAllBytes($ReplacePreviousAfterValidation, [byte[]](31,29,27,25,23,21,19,17))
                $replacementHash = Get-CcodTestFileSha256 -Path $ReplacePreviousAfterValidation
                [IO.File]::WriteAllText("$ReplacePreviousAfterValidation.sha256.txt", ("{0} *{1}`r`n" -f $replacementHash, [IO.Path]::GetFileName($ReplacePreviousAfterValidation)), [Text.UTF8Encoding]::new($false))
            }
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
            $runtimeManifest = if ($Context.scenario -in @('FreshInstall','FreshLater','FreshRestart','Upgrade','SlowLaunch','ManualLaunchResume','LanguageStress','RepairStates')) { [string]$after.runtimeManifestSha256 } else { $null }
            return [pscustomobject][ordered]@{ code = 'CCOD_INTEGRATION_OPERATOR_COMPLETED'; scenario = [string]$Context.scenario; transactionId = [string]$Context.transactionId; completed = $true; operatorAttestation = 'OperatorConfirmed'; installerSha256 = [string]$Context.installerSha256; runtimeManifestSha256 = $runtimeManifest }
        }.GetNewClosure()
        VerifyScenario = {
            param($Context, $BeforeFacts, $RunResult)
            $Calls.Add('VerifyScenario')
            return [pscustomobject]@{ verified = $true; code = 'CCOD_INTEGRATION_VERIFIED'; facts = $after; token = 'never-persist' }
        }.GetNewClosure()
        Rollback = {
            param($Context, $Snapshot)
            $Calls.Add('Rollback')
            if ($RecordRollbackIdentity) {
                $Calls.Add('RollbackPath:' + [string]$Context.previousInstallerPath)
                $Calls.Add('RollbackHash:' + (Get-CcodTestFileSha256 -Path ([string]$Context.previousInstallerPath)))
            }
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

Invoke-CcodTest 'installed lifecycle active facts prefer the append-only selector over legacy active json' {
    . $harnessPath -Library
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-selector-authority-' + [guid]::NewGuid().ToString('N'))
    try {
        $null = [IO.Directory]::CreateDirectory($root)
        $selector = Join-Path (Join-Path $root 'state') 'active-generation'
        $null = [IO.Directory]::CreateDirectory($selector)
        $id = '2.5.22-e3b0c44298fc1c14-22222222222222222222222222222222'
        $runtime = Join-Path (Join-Path $root 'runtime') $id
        $null = [IO.Directory]::CreateDirectory($runtime)
        [IO.File]::WriteAllText((Join-Path $runtime 'manifest.json'), (([ordered]@{ schemaVersion = 1; projectVersion = '2.5.22'; runtimeId = $id; files = @() } | ConvertTo-Json -Compress)), [Text.UTF8Encoding]::new($false))
        $record = [ordered]@{ schemaVersion = 1; generation = [UInt64]1; activeRuntime = $id; previousGeneration = [UInt64]0 }
        [IO.File]::WriteAllText((Join-Path $selector '00000000000000000001.json'), ($record | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
        $legacy = [ordered]@{ schemaVersion = 2; activeRuntime = 'legacy-runtime'; previousRuntime = $null; generation = [UInt64]99; updatedAtUtc = '2030-02-03T04:05:06.0000000Z' }
        [IO.File]::WriteAllText((Join-Path $root 'active.json'), ($legacy | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
        $actual = Read-CcodInstalledLifecycleActiveFact -InstallRoot $root
        Assert-CcodEqual $id ([string]$actual.activeRuntime) 'append-only selector is authoritative over legacy active json'
        Assert-CcodEqual ([UInt64]1) ([UInt64]$actual.generation) 'selector generation is returned'
        Add-Content -LiteralPath (Join-Path $selector '00000000000000000001.json') -Stream 'tampered' -Value 'alternate' -NoNewline
        Assert-CcodThrows { Read-CcodInstalledLifecycleActiveFact -InstallRoot $root | Out-Null } 'CCOD_INTEGRATION_FACTS_INVALID'
    } finally { if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force } }
}

    Invoke-CcodTest 'installed lifecycle selector rejects a file state ancestor before legacy fallback' {
        . $harnessPath -Library
        $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-selector-state-file-' + [guid]::NewGuid().ToString('N'))
        try {
            $null = [IO.Directory]::CreateDirectory($root)
            [IO.File]::WriteAllText((Join-Path $root 'state'), 'not-a-directory', [Text.UTF8Encoding]::new($false))
            $legacy = [ordered]@{ schemaVersion = 2; activeRuntime = 'legacy-runtime'; previousRuntime = $null; generation = [UInt64]1; updatedAtUtc = '2030-02-03T04:05:06.0000000Z' }
            [IO.File]::WriteAllText((Join-Path $root 'active.json'), ($legacy | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
            Assert-CcodThrows { Read-CcodInstalledLifecycleActiveFact -InstallRoot $root | Out-Null } 'CCOD_INTEGRATION_OBSERVATION_UNAVAILABLE'
        } finally { if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force } }
    }

Invoke-CcodTest 'installed lifecycle selector rejects a dot-leading active runtime before path construction' {
    . $harnessPath -Library
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-selector-dot-leading-' + [guid]::NewGuid().ToString('N'))
    try {
        $selector = Join-Path (Join-Path $root 'state') 'active-generation'
        [IO.Directory]::CreateDirectory($selector) | Out-Null
        $record = [ordered]@{ schemaVersion = 1; generation = [UInt64]1; activeRuntime = '..'; previousGeneration = [UInt64]0 }
        [IO.File]::WriteAllText((Join-Path $selector '00000000000000000001.json'), ($record | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
        Assert-CcodThrows { Read-CcodInstalledLifecycleActiveFact -InstallRoot $root | Out-Null } 'CCOD_INTEGRATION_FACTS_INVALID'
    } finally {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

Invoke-CcodTest 'installed lifecycle harness exposes the guarded library interface' {
    Assert-CcodTrue (Test-Path -LiteralPath $harnessPath -PathType Leaf) 'installed lifecycle harness exists'
    . $harnessPath -Library
    Assert-CcodTrue ($null -ne (Get-Command Invoke-CcodInstalledLifecycleIntegration -ErrorAction SilentlyContinue)) 'harness exports its invocation function when loaded as a library'
}

Invoke-CcodTest 'FreshInstall is a distinct guarded integration scenario' {
    . $harnessPath -Library
    Assert-CcodThrows {
        Invoke-CcodInstalledLifecycleIntegration -InstallerPath 'C:\fixture\CodexRemote-fix-2.5.22-setup.exe' -ExpectedVersion '2.5.22' -EvidenceRoot 'C:\fixture\evidence' -Scenario FreshInstall
    } 'CCOD_INTEGRATION_MUTATION_NOT_ALLOWED'
}

# Production mutation caught: FreshRestart ignores stale status and a current-runtime CloseFailed receipt.
Invoke-CcodTest 'direct uninstall verification rejects partial owned-state residue' {
    . $harnessPath -Library
    $before = New-CcodHarnessFacts
    $after = New-CcodHarnessFacts
    $after.installRootPresent = $false; $after.appPresent = $false; $after.runtimeRootPresent = $true; $after.activePointerPresent = $true; $after.taskState = 'Absent'
    $context = [pscustomobject]@{ scenario = 'DirectUninstall'; expectedVersion = '2.5.0'; installRoot = 'C:\fixture' }
    $result = Invoke-CcodHarnessWithCapturedFacts -Context $context -BeforeFacts $before -AfterFacts $after
    Assert-CcodTrue (-not $result.verified -and [string]$result.code -eq 'CCOD_INTEGRATION_OBSERVATION_UNPROVEN') 'direct uninstall rejects runtime and pointer residue'
}

Invoke-CcodTest 'direct uninstall rejects a newly created device key when none existed before' {
    . $harnessPath -Library
    $before = New-CcodHarnessFacts
    $before.deviceKeyPresent = $false
    $before.deviceKeySha256 = $null
    $after = New-CcodHarnessAbsentFacts -WithoutDeviceKey
    $context = [pscustomobject]@{ scenario = 'DirectUninstall'; expectedVersion = '2.5.0'; installRoot = 'C:\fixture' }
    $positive = Invoke-CcodHarnessWithCapturedFacts -Context $context -BeforeFacts $before -AfterFacts $after
    Assert-CcodTrue $positive.verified 'the absent-key uninstall baseline is independently valid'
    $after.deviceKeyPresent = $true; $after.deviceKeySha256 = ('b' * 64)
    $result = Invoke-CcodHarnessWithCapturedFacts -Context $context -BeforeFacts $before -AfterFacts $after
    Assert-CcodTrue (-not $result.verified -and [string]$result.code -eq 'CCOD_INTEGRATION_OBSERVATION_UNPROVEN') 'uninstall rejects device-key creation after an absent baseline'
}

Invoke-CcodTest 'uninstall rejects persisted runtime status residue after owned state is gone' {
    . $harnessPath -Library
    $before = New-CcodHarnessFacts
    $before.deviceKeyPresent = $false; $before.deviceKeySha256 = $null
    $after = New-CcodHarnessFacts
    $after.installRootPresent = $false; $after.appPresent = $false; $after.runtimeRootPresent = $false; $after.activePointerPresent = $false; $after.taskState = 'Absent'
    $after.supervisor = @(); $after.trayHost = @(); $after.trayHostIdentity = $null; $after.trayAuthenticated = $false; $after.installReady = $false; $after.protectionReady = $false; $after.codex = @(); $after.deviceKeyPresent = $false; $after.deviceKeySha256 = $null
    $after.shortcuts = [pscustomobject]@{ startMenu = $false; desktop = $false }; $after.debugEndpoints = @(); $after.lifecycleReceipt = $null
    $context = [pscustomobject]@{ scenario = 'DirectUninstall'; expectedVersion = '2.5.0'; installRoot = 'C:\fixture' }
    $result = Invoke-CcodHarnessWithCapturedFacts -Context $context -BeforeFacts $before -AfterFacts $after
    Assert-CcodTrue (-not $result.verified -and [string]$result.code -eq 'CCOD_INTEGRATION_OBSERVATION_UNPROVEN') 'uninstall rejects persisted status and transition residue'
}

Invoke-CcodTest 'rejects FreshRestart when current active runtime has stale status and a CloseFailed installer receipt' {
    . $harnessPath -Library
    $before = New-CcodHarnessFacts -RuntimeId '2.5.19-old' -CodexPid 10664
    $after = New-CcodHarnessFacts -RuntimeId '2.5.21-e3b0c44298fc1c14-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' -CodexPid 13948 `
        -StatusRuntimeId '2.5.19-old' -StatusCodexPid 10664 -ReceiptPhase 'CloseFailed'
    $context = [pscustomobject]@{ scenario = 'FreshRestart'; expectedVersion = '2.5.0'; installRoot = 'C:\fixture' }
    $verification = Invoke-CcodHarnessWithCapturedFacts -Context $context -BeforeFacts $before -AfterFacts $after
    Assert-CcodEqual $false $verification.verified 'stale status and CloseFailed terminal state leave FreshRestart unverified'
    Assert-CcodEqual 'CCOD_INTEGRATION_OBSERVATION_UNPROVEN' $verification.code 'rejection uses the stable observation code'
}

Invoke-CcodTest 'FreshInstall requires the same current-runtime Ready and Complete proof as later phases' {
    . $harnessPath -Library
    $before = New-CcodHarnessAbsentFacts
    $after = New-CcodHarnessFacts
    $context = [pscustomobject]@{ scenario = 'FreshInstall'; expectedVersion = '2.5.0'; expectedDebugPorts = @(9229,9230); installRoot = 'C:\fixture' }
    $positive = Invoke-CcodHarnessWithCapturedFacts -Context $context -BeforeFacts $before -AfterFacts $after
    Assert-CcodTrue $positive.verified 'clean pre-install state and complete candidate proof form a valid FreshInstall baseline'
    $after.lifecycleReceipt = $null
    $verification = Invoke-CcodHarnessWithCapturedFacts -Context $context -BeforeFacts $before -AfterFacts $after
    Assert-CcodEqual $false $verification.verified 'FreshInstall cannot use the generic installed success branch'
    Assert-CcodEqual 'CCOD_INTEGRATION_OBSERVATION_UNPROVEN' $verification.code 'FreshInstall missing proof uses the stable observation code'
}

Invoke-CcodTest 'rejects FreshRestart without current Active status Idle transition or Completed receipt' {
    . $harnessPath -Library
    $before = New-CcodHarnessFacts -RuntimeId '2.5.21-before' -CodexPid 10664
    $after = New-CcodHarnessFacts -RuntimeId '2.5.22-after' -CodexPid 13948
    $after.statusPhase = 'Unknown'; $after.statusRuntimeId = $null; $after.statusCodex = $null; $after.transitionStage = 'Unknown'; $after.lifecycleReceipt = $null
    $context = [pscustomobject]@{ scenario = 'FreshRestart'; expectedVersion = '2.5.0'; installRoot = 'C:\fixture' }
    $verification = Invoke-CcodHarnessWithCapturedFacts -Context $context -BeforeFacts $before -AfterFacts $after
    Assert-CcodEqual $false $verification.verified 'FreshRestart requires current-runtime Ready/Complete evidence'
    Assert-CcodEqual 'CCOD_INTEGRATION_OBSERVATION_UNPROVEN' $verification.code 'missing Ready/Complete evidence uses the stable observation code'
}

# Production mutation caught: querying Codex.exe instead of the Windows app root ChatGPT.exe.
Invoke-CcodTest 'captures exactly the top-level ChatGPT root and excludes Electron type children' {
    . $harnessPath -Library
    $root = Join-Path (Get-CcodTestCanonicalTempRoot) ('ccod-installed-capture-' + [guid]::NewGuid().ToString('N'))
    try {
        $null = [IO.Directory]::CreateDirectory($root)
        $created = '2026-08-24T00:00:04.0000006Z'
        Set-CcodHarnessProcessFixture -ChatGPT @(
            (New-CcodHarnessCimProcess -Name 'ChatGPT.exe' -ProcessId 13948 -CreationTimeUtc $created -CommandLine '"C:\Program Files\WindowsApps\OpenAI.Codex\ChatGPT.exe"'),
            (New-CcodHarnessCimProcess -Name 'ChatGPT.exe' -ProcessId 13949 -CreationTimeUtc '2026-08-24T00:00:04.1000000Z' -CommandLine '"C:\Program Files\WindowsApps\OpenAI.Codex\ChatGPT.exe" --type=renderer' -ParentProcessId 13948),
            (New-CcodHarnessCimProcess -Name 'ChatGPT.exe' -ProcessId 13950 -CreationTimeUtc '2026-08-24T00:00:04.2000000Z' -CommandLine '"C:\Program Files\WindowsApps\OpenAI.Codex\ChatGPT.exe" --TYPE=utility' -ParentProcessId 13948),
            (New-CcodHarnessCimProcess -Name 'ChatGPT.exe' -ProcessId 13953 -CreationTimeUtc '2026-08-24T00:00:04.5000000Z' -CommandLine '"C:\Program Files\WindowsApps\OpenAI.Codex\ChatGPT.exe" "--type=renderer"' -ParentProcessId 13948)
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

Invoke-CcodTest 'normalizes only supported CIM creation-time evidence for complete ChatGPT roots' {
    . $harnessPath -Library
    $root = Join-Path (Get-CcodTestCanonicalTempRoot) ('ccod-installed-cim-creation-' + [guid]::NewGuid().ToString('N'))
    try {
        $null = [IO.Directory]::CreateDirectory($root)
        $commandLine = '"C:\Program Files\WindowsApps\OpenAI.Codex\ChatGPT.exe"'
        $local = [DateTime]::SpecifyKind([DateTime]'2030-02-03T12:05:06', [DateTimeKind]::Local)
        $utc = [DateTime]::SpecifyKind([DateTime]'2030-02-03T12:05:06', [DateTimeKind]::Utc)
        $dmtf = [Management.ManagementDateTimeConverter]::ToDmtfDateTime($utc)
        $successCases = @(
            [pscustomobject]@{ Name = 'Local DateTime'; Value = $local; Expected = $local.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture) },
            [pscustomobject]@{ Name = 'Utc DateTime'; Value = $utc; Expected = $utc.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture) },
            [pscustomobject]@{ Name = 'complete DMTF string'; Value = $dmtf; Expected = $utc.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture) }
        )
        foreach ($case in $successCases) {
            $process = New-CcodHarnessCimProcess -Name 'ChatGPT.exe' -ProcessId 13948 -CreationTimeUtc '2026-08-24T00:00:04.0000000Z' -CommandLine $commandLine
            $process.CreationDate = $case.Value
            $script:CcodHarnessNativeCreation[13948]=$case.Expected
            Set-CcodHarnessProcessFixture -ChatGPT @($process)
            $facts = Get-CcodInstalledLifecycleFacts -InstallRoot $root
            Assert-CcodEqual 1 $facts.codex.Count ("{0} keeps one root" -f $case.Name)
            Assert-CcodEqual 13948 $facts.codex[0].pid ("{0} retains the root PID" -f $case.Name)
            Assert-CcodEqual $case.Expected $facts.codex[0].creationTimeUtc ("{0} becomes canonical UTC" -f $case.Name)
        }
        foreach ($case in @(
            [pscustomobject]@{ Name = 'null'; Value = $null },
            [pscustomobject]@{ Name = 'Unspecified DateTime'; Value = [DateTime]::SpecifyKind([DateTime]'2030-02-03T12:05:06', [DateTimeKind]::Unspecified) },
            [pscustomobject]@{ Name = 'malformed DMTF'; Value = '20300203120506.000000+08' },
            [pscustomobject]@{ Name = 'lexically complete invalid DMTF'; Value = '20301303120506.000000+000' },
            [pscustomobject]@{ Name = 'integer'; Value = 1 },
            [pscustomobject]@{ Name = 'arbitrary string'; Value = 'not-a-dmtf-time' }
        )) {
            $process = New-CcodHarnessCimProcess -Name 'ChatGPT.exe' -ProcessId 13948 -CreationTimeUtc '2026-08-24T00:00:04.0000000Z' -CommandLine $commandLine
            $process.CreationDate = $case.Value
            Set-CcodHarnessProcessFixture -ChatGPT @($process)
            Assert-CcodThrows { Get-CcodInstalledLifecycleFacts -InstallRoot $root } 'CCOD_INTEGRATION_FACTS_INVALID'
        }
    } finally {
        Clear-CcodHarnessProcessFixture
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

Invoke-CcodTest 'fails closed when any enumerated ChatGPT process cannot be proven root or Electron child' {
    . $harnessPath -Library
    foreach($case in @('null command line','empty command line','unparsable command line','invalid creation time','zero PID','string PID','nonstring command line','missing command line')){
        $root=Join-Path (Get-CcodTestCanonicalTempRoot) ("ccod-installed-indeterminate-$($case.Replace(' ','-'))-"+[guid]::NewGuid().ToString('N'))
        try{
            $null=[IO.Directory]::CreateDirectory($root)
            $valid=New-CcodHarnessCimProcess -Name 'ChatGPT.exe' -ProcessId 13948 -CreationTimeUtc '2026-08-24T00:00:04.0000000Z' -CommandLine '"C:\Program Files\WindowsApps\OpenAI.Codex\ChatGPT.exe"'
            $indeterminate=New-CcodHarnessCimProcess -Name 'ChatGPT.exe' -ProcessId 13949 -CreationTimeUtc '2026-08-24T00:00:04.1000000Z' -CommandLine '"C:\Program Files\WindowsApps\OpenAI.Codex\ChatGPT.exe" --type=renderer' -ParentProcessId 13948
            switch($case){
                'null command line'{$indeterminate.CommandLine=$null}
                'empty command line'{$indeterminate.CommandLine=''}
                'unparsable command line'{$indeterminate.CommandLine='   '}
                'invalid creation time'{$indeterminate.CreationDate='not-a-dmtf-time'}
                'zero PID'{$indeterminate.ProcessId=0}
                'string PID'{$indeterminate.ProcessId='13949'}
                'nonstring command line'{$indeterminate.CommandLine=42}
                'missing command line'{$indeterminate.PSObject.Properties.Remove('CommandLine')}
            }
            Set-CcodHarnessProcessFixture -ChatGPT @($valid,$indeterminate)
            Assert-CcodThrows {Get-CcodInstalledLifecycleFacts -InstallRoot $root} 'CCOD_INTEGRATION_FACTS_INVALID'
        }finally{
            Clear-CcodHarnessProcessFixture
            if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}
        }
    }
}

Invoke-CcodTest 'captures bounded current-runtime status transition and latest installer receipt facts from complete schemas' {
    . $harnessPath -Library
    $root = Join-Path (Get-CcodTestCanonicalTempRoot) ('ccod-installed-state-' + [guid]::NewGuid().ToString('N'))
    try {
        $null = [IO.Directory]::CreateDirectory($root)
        New-CcodHarnessInstalledStateFixture -Root $root -ActiveRuntimeId '2.5.21-e3b0c44298fc1c14-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' -ActiveGeneration ([UInt64]8) `
            -StatusRuntimeId '2.5.19-old' -StatusCodexPid 10664 -StatusCodexCreationTimeUtc '2026-08-24T00:00:02.0000000Z' -ReceiptPhase 'CloseFailed'
        Set-CcodHarnessProcessFixture -ChatGPT @(
            (New-CcodHarnessCimProcess -Name 'ChatGPT.exe' -ProcessId 13948 -CreationTimeUtc '2026-08-24T00:00:04.0000000Z' -CommandLine '"C:\Program Files\WindowsApps\OpenAI.Codex\ChatGPT.exe"'),
            (New-CcodHarnessCimProcess -Name 'ChatGPT.exe' -ProcessId 13949 -CreationTimeUtc '2026-08-24T00:00:04.1000000Z' -CommandLine '"C:\Program Files\WindowsApps\OpenAI.Codex\ChatGPT.exe" --type=renderer' -ParentProcessId 13948)
        )
        $facts = Get-CcodInstalledLifecycleFacts -InstallRoot $root
        Assert-CcodEqual '2.5.21-e3b0c44298fc1c14-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' $facts.activeRuntimeId 'active schema 2 supplies the current runtime'
        Assert-CcodEqual 8 ([UInt64]$facts.activeGeneration) 'active schema 2 supplies the current generation'
        Assert-CcodEqual 'Active' $facts.statusPhase 'complete status schema 1 supplies the session state'
        Assert-CcodEqual '2.5.19-old' $facts.statusRuntimeId 'stale status runtime remains visible for correlation rejection'
        Assert-CcodEqual 10664 $facts.statusCodex.pid 'stale status Codex identity remains visible for correlation rejection'
        Assert-CcodEqual 'Idle' $facts.transitionStage 'null active transaction is captured as idle'
        Assert-CcodEqual 'RestartAndRepair' $facts.lifecycleReceipt.kind 'receipt kind is bounded and retained'
        Assert-CcodEqual 'Installer' $facts.lifecycleReceipt.origin 'receipt origin is bounded and retained'
        Assert-CcodEqual '2.5.21-e3b0c44298fc1c14-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' $facts.lifecycleReceipt.runtimeId 'latest receipt is bound to the active runtime'
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
    $root = Join-Path (Get-CcodTestCanonicalTempRoot) ('ccod-installed-receipts-' + [guid]::NewGuid().ToString('N'))
    try {
        $null = [IO.Directory]::CreateDirectory($root)
        New-CcodHarnessInstalledStateFixture -Root $root -ActiveRuntimeId '2.5.21-e3b0c44298fc1c14-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' -ActiveGeneration ([UInt64]8) `
            -StatusRuntimeId '2.5.21-e3b0c44298fc1c14-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' -StatusCodexPid 13948 -StatusCodexCreationTimeUtc '2026-08-24T00:00:04.0000000Z' -ReceiptPhase 'CloseFailed'
        $completed = New-CcodHarnessLifecycleReceipt -RuntimeId '2.5.21-e3b0c44298fc1c14-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' -RuntimeGeneration ([UInt64]8) -Phase 'Completed' `
            -TransactionId '22222222-3333-4444-5555-666666666666' -UpdatedAtUtc '2026-08-24T00:00:06.0000000Z'
        Write-CcodHarnessJson -Path (Join-Path $root ("state\lifecycle\receipts\{0}.json" -f $completed.transactionId)) -Value $completed
        Set-CcodHarnessProcessFixture -ChatGPT @(
            (New-CcodHarnessCimProcess -Name 'ChatGPT.exe' -ProcessId 13948 -CreationTimeUtc '2026-08-24T00:00:04.0000000Z' -CommandLine '"C:\Program Files\WindowsApps\OpenAI.Codex\ChatGPT.exe"')
        )
        $facts = Get-CcodInstalledLifecycleFacts -InstallRoot $root
        Assert-CcodEqual 'Completed' $facts.lifecycleReceipt.phase 'strict receipt selection uses the unique latest updatedAtUtc'

        $ambiguous = New-CcodHarnessLifecycleReceipt -RuntimeId '2.5.21-e3b0c44298fc1c14-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' -RuntimeGeneration ([UInt64]8) -Phase 'CloseFailed' `
            -TransactionId '33333333-4444-5555-6666-777777777777' -UpdatedAtUtc '2026-08-24T00:00:06.0000000Z'
        Write-CcodHarnessJson -Path (Join-Path $root ("state\lifecycle\receipts\{0}.json" -f $ambiguous.transactionId)) -Value $ambiguous
        Assert-CcodThrows { Get-CcodInstalledLifecycleFacts -InstallRoot $root } 'CCOD_INTEGRATION_FACTS_INVALID'
    } finally {
        Clear-CcodHarnessProcessFixture
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

# Production mutation caught: choosing latest by runtime before filtering the active generation.
Invoke-CcodTest 'ignores a newer wrong-generation receipt when selecting the current-generation terminal result' {
    . $harnessPath -Library
    $root = Join-Path (Get-CcodTestCanonicalTempRoot) ('ccod-installed-receipt-generation-' + [guid]::NewGuid().ToString('N'))
    try {
        $null = [IO.Directory]::CreateDirectory($root)
        New-CcodHarnessInstalledStateFixture -Root $root -ActiveRuntimeId '2.5.21-e3b0c44298fc1c14-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' -ActiveGeneration ([UInt64]8) `
            -StatusRuntimeId '2.5.21-e3b0c44298fc1c14-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' -StatusCodexPid 13948 -StatusCodexCreationTimeUtc '2026-08-24T00:00:04.0000000Z' -ReceiptPhase 'Completed'
        $wrongGeneration = New-CcodHarnessLifecycleReceipt -RuntimeId '2.5.21-e3b0c44298fc1c14-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' -RuntimeGeneration ([UInt64]7) -Phase 'CloseFailed' `
            -TransactionId '44444444-5555-6666-7777-888888888888' -UpdatedAtUtc '2026-08-24T00:00:07.0000000Z'
        Write-CcodHarnessJson -Path (Join-Path $root ("state\lifecycle\receipts\{0}.json" -f $wrongGeneration.transactionId)) -Value $wrongGeneration
        Set-CcodHarnessProcessFixture -ChatGPT @()
        $facts = Get-CcodInstalledLifecycleFacts -InstallRoot $root
        Assert-CcodEqual 8 ([UInt64]$facts.lifecycleReceipt.runtimeGeneration) 'receipt selection stays bound to the active generation'
        Assert-CcodEqual 'Completed' $facts.lifecycleReceipt.phase 'newer stale-generation failure cannot mask current-generation completion'
    } finally {
        Clear-CcodHarnessProcessFixture
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

Invoke-CcodTest 'does not treat tied wrong-generation receipts as current-generation ambiguity' {
    . $harnessPath -Library
    $root = Join-Path (Get-CcodTestCanonicalTempRoot) ('ccod-installed-receipt-generation-tie-' + [guid]::NewGuid().ToString('N'))
    try {
        $null = [IO.Directory]::CreateDirectory($root)
        New-CcodHarnessInstalledStateFixture -Root $root -ActiveRuntimeId '2.5.21-e3b0c44298fc1c14-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' -ActiveGeneration ([UInt64]8) `
            -StatusRuntimeId '2.5.21-e3b0c44298fc1c14-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' -StatusCodexPid 13948 -StatusCodexCreationTimeUtc '2026-08-24T00:00:04.0000000Z' -ReceiptPhase 'Completed'
        foreach ($record in @(
            (New-CcodHarnessLifecycleReceipt -RuntimeId '2.5.21-e3b0c44298fc1c14-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' -RuntimeGeneration ([UInt64]7) -Phase 'CloseFailed' -TransactionId '55555555-6666-7777-8888-999999999999' -UpdatedAtUtc '2026-08-24T00:00:07.0000000Z'),
            (New-CcodHarnessLifecycleReceipt -RuntimeId '2.5.21-e3b0c44298fc1c14-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' -RuntimeGeneration ([UInt64]7) -Phase 'RepairFailed' -TransactionId '66666666-7777-8888-9999-aaaaaaaaaaaa' -UpdatedAtUtc '2026-08-24T00:00:07.0000000Z')
        )) {
            Write-CcodHarnessJson -Path (Join-Path $root ("state\lifecycle\receipts\{0}.json" -f $record.transactionId)) -Value $record
        }
        Set-CcodHarnessProcessFixture -ChatGPT @()
        $facts = Get-CcodInstalledLifecycleFacts -InstallRoot $root
        Assert-CcodEqual 'Completed' $facts.lifecycleReceipt.phase 'only current-generation timestamps participate in ambiguity detection'
    } finally {
        Clear-CcodHarnessProcessFixture
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

Invoke-CcodTest 'fails closed on receipt filename duplicate-property and nonterminal boundaries' {
    . $harnessPath -Library
    foreach ($case in @('filename','duplicate-json','nonterminal')) {
        $root = Join-Path (Get-CcodTestCanonicalTempRoot) ("ccod-installed-receipt-$case-" + [guid]::NewGuid().ToString('N'))
        try {
            $null = [IO.Directory]::CreateDirectory($root)
            New-CcodHarnessInstalledStateFixture -Root $root -ActiveRuntimeId '2.5.21-e3b0c44298fc1c14-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' -ActiveGeneration ([UInt64]8) `
                -StatusRuntimeId '2.5.21-e3b0c44298fc1c14-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' -StatusCodexPid 13948 -StatusCodexCreationTimeUtc '2026-08-24T00:00:04.0000000Z' -ReceiptPhase 'Completed'
            switch ($case) {
                'filename' {
                    $receipt = New-CcodHarnessLifecycleReceipt -RuntimeId '2.5.21-e3b0c44298fc1c14-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' -RuntimeGeneration ([UInt64]8) -Phase 'Completed' `
                        -TransactionId '77777777-8888-9999-aaaa-bbbbbbbbbbbb'
                    Write-CcodHarnessJson -Path (Join-Path $root 'state\lifecycle\receipts\88888888-9999-aaaa-bbbb-cccccccccccc.json') -Value $receipt
                    Assert-CcodThrows { Get-CcodInstalledLifecycleFacts -InstallRoot $root } 'CCOD_INTEGRATION_FACTS_INVALID'
                }
                'duplicate-json' {
                    $path = Join-Path $root 'state\lifecycle\receipts\11111111-2222-3333-4444-555555555555.json'
                    $json = [IO.File]::ReadAllText($path).Replace('"schemaVersion":1', '"schemaVersion":1,"schemaVersion":1')
                    [IO.File]::WriteAllText($path, $json, [Text.UTF8Encoding]::new($false))
                    Assert-CcodThrows { Get-CcodInstalledLifecycleFacts -InstallRoot $root } 'CCOD_STATE_MALFORMED'
                }
                'nonterminal' {
                    $receipt = New-CcodHarnessLifecycleReceipt -RuntimeId '2.5.21-e3b0c44298fc1c14-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' -RuntimeGeneration ([UInt64]8) -Phase 'Completed' `
                        -TransactionId '99999999-aaaa-bbbb-cccc-dddddddddddd'
                    $receipt.phase = 'Requested'
                    Write-CcodHarnessJson -Path (Join-Path $root ("state\lifecycle\receipts\{0}.json" -f $receipt.transactionId)) -Value $receipt
                    Assert-CcodThrows { Get-CcodInstalledLifecycleFacts -InstallRoot $root } 'CCOD_INTEGRATION_FACTS_INVALID'
                }
            }
        } finally {
            if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
        }
    }
}

Invoke-CcodTest 'lifecycle receipt inspection rejects non-json residue and non-plain receipt links' {
    . $harnessPath -Library
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-receipt-authority-' + [guid]::NewGuid().ToString('N'))
    $outside = Join-Path ([IO.Path]::GetTempPath()) ('ccod-receipt-hardlink-' + [guid]::NewGuid().ToString('N') + '.json')
    try {
        [IO.Directory]::CreateDirectory($root) | Out-Null
        New-CcodHarnessInstalledStateFixture -Root $root -ActiveRuntimeId '2.5.21-e3b0c44298fc1c14' -ActiveGeneration ([UInt64]8) `
            -StatusRuntimeId '2.5.21-e3b0c44298fc1c14' -StatusCodexPid 13948 -StatusCodexCreationTimeUtc '2026-08-24T00:00:04.0000000Z' -ReceiptPhase 'Completed'
        Set-CcodHarnessProcessFixture -ChatGPT @(
            (New-CcodHarnessCimProcess -Name 'ChatGPT.exe' -ProcessId 13948 -CreationTimeUtc '2026-08-24T00:00:04.0000000Z' -CommandLine '"C:\Program Files\WindowsApps\OpenAI.Codex\ChatGPT.exe"')
        )
        $receiptDirectory = Join-Path $root 'state/lifecycle/receipts'
        [IO.File]::WriteAllText((Join-Path $receiptDirectory 'unexpected.tmp'), 'residue', [Text.UTF8Encoding]::new($false))
        Assert-CcodThrows { Get-CcodInstalledLifecycleFacts -InstallRoot $root | Out-Null } 'CCOD_INTEGRATION_FACTS_INVALID'
        Remove-Item -LiteralPath (Join-Path $receiptDirectory 'unexpected.tmp') -Force
        New-Item -ItemType HardLink -Path $outside -Target (Get-ChildItem -LiteralPath $receiptDirectory -Filter '*.json' | Select-Object -First 1 -ExpandProperty FullName) | Out-Null
        Assert-CcodThrows { Get-CcodInstalledLifecycleFacts -InstallRoot $root | Out-Null } 'CCOD_INTEGRATION_FACTS_INVALID'
    } finally {
        Clear-CcodHarnessProcessFixture
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
        if (Test-Path -LiteralPath $outside) { Remove-Item -LiteralPath $outside -Force }
    }
}

Invoke-CcodTest 'fails closed on malformed active status and transition schemas' {
    . $harnessPath -Library
    foreach ($case in @('active','status','transition')) {
        $root = Join-Path (Get-CcodTestCanonicalTempRoot) ("ccod-installed-state-$case-" + [guid]::NewGuid().ToString('N'))
        try {
            $null = [IO.Directory]::CreateDirectory($root)
            New-CcodHarnessInstalledStateFixture -Root $root -ActiveRuntimeId '2.5.21-e3b0c44298fc1c14-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' -ActiveGeneration ([UInt64]8) `
                -StatusRuntimeId '2.5.21-e3b0c44298fc1c14-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' -StatusCodexPid 13948 -StatusCodexCreationTimeUtc '2026-08-24T00:00:04.0000000Z' -ReceiptPhase 'Completed'
            switch ($case) {
                'active' {
                    $path = Join-Path $root 'active.json'
                    $value = [IO.File]::ReadAllText($path) | ConvertFrom-Json
                    $value.generation = 'eight'
                    Write-CcodHarnessJson -Path $path -Value $value
                }
                'status' {
                    $path = Join-Path $root 'state\status.json'
                    $value = [IO.File]::ReadAllText($path) | ConvertFrom-Json
                    $value.session.codex.rendererProbe = 'Open'
                    Write-CcodHarnessJson -Path $path -Value $value
                }
                'transition' {
                    $path = Join-Path $root 'state\transition.json'
                    $value = [IO.File]::ReadAllText($path) | ConvertFrom-Json
                    $value.activeTransaction = [pscustomobject][ordered]@{}
                    Write-CcodHarnessJson -Path $path -Value $value
                }
            }
            Assert-CcodThrows { Get-CcodInstalledLifecycleFacts -InstallRoot $root } 'CCOD_INTEGRATION_FACTS_INVALID'
        } finally {
            if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
        }
    }
}

# Production mutation caught: treating a Codex.exe-only observation as installed app process evidence.
Invoke-CcodTest 'does not accept a Codex.exe-only fixture as Codex process evidence' {
    . $harnessPath -Library
    $root = Join-Path (Get-CcodTestCanonicalTempRoot) ('ccod-installed-capture-' + [guid]::NewGuid().ToString('N'))
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

Invoke-CcodTest 'sealed direct uninstall launches the active public uninstaller rather than removed Inno executable' {
    . $harnessPath -Library
    $root=Join-Path (Get-CcodTestCanonicalTempRoot) ('ccod-modern-uninstall-'+[guid]::NewGuid().ToString('N'))
    $originalStart=${function:Start-Process};$originalAck=${function:Read-CcodInstalledLifecycleOperatorAck}
    $originalCommand=${function:Get-CcodInstalledLifecycleUninstallCommand}
    $originalLaunch=${function:Start-CcodInstalledLifecycleVerifiedUninstall}
    $state=[pscustomobject]@{Launch=$null;Ack=0;Resolved=0}
    try {
        [IO.Directory]::CreateDirectory($root)|Out-Null
        $runtimeId='2.5.22-'+('a'*16)+'-'+('b'*32);$runtime=Join-Path $root ('runtime\'+$runtimeId)
        [IO.Directory]::CreateDirectory($runtime)|Out-Null
        $uninstaller=Join-Path $runtime 'Uninstall-CodexControlOtherDevices.ps1';[IO.File]::WriteAllText($uninstaller,'# inert uninstall test')
        $installer=Join-Path $root 'candidate.exe';[IO.File]::WriteAllText($installer,'inert candidate')
        $context=[pscustomobject]@{scenario='DirectUninstall';expectedVersion='2.5.22';installRoot=$root;installerApplicationRoot=(Join-Path $root 'obsolete-inno');installerPath=$installer;candidatePayloadFiles=@([pscustomobject]@{path='payload';length=1;sha256=('a'*64)});transactionId='11111111-2222-3333-4444-555555555555'}
        function Get-CcodInstalledLifecycleUninstallCommand {param($InstallRoot,$ExpectedVersion,$ExpectedPayloadFiles)$state.Resolved++;Assert-CcodEqual '2.5.22' $ExpectedVersion 'resolver gets the bound version';Assert-CcodEqual 1 @($ExpectedPayloadFiles).Count 'resolver gets the actual candidate records';[pscustomobject]@{Spec=[pscustomobject]@{installRoot=$InstallRoot;runtimeId=$runtimeId;candidatePayloadFiles=$ExpectedPayloadFiles}}}
        function Start-Process {throw 'unverified direct native launch must not occur'}
        function Start-CcodInstalledLifecycleVerifiedUninstall {param($Spec)$state.Launch=$Spec;[pscustomobject]@{ExitCode=0}}
        function Read-CcodInstalledLifecycleOperatorAck {param($Scenario,$Instructions)$state.Ack++}
        $result=Invoke-CcodInstalledLifecycleOperatorScenario -Context $context
        Assert-CcodEqual 1 $state.Resolved 'actual scenario resolves the sealed uninstaller contract'
        Assert-CcodEqual $root $state.Launch.installRoot 'verified launcher receives the selected install root'
        Assert-CcodEqual $runtimeId $state.Launch.runtimeId 'launcher receives the original runtime identity rather than command text'
        Assert-CcodEqual 1 @($state.Launch.candidatePayloadFiles).Count 'launcher retains original candidate records'
        Assert-CcodEqual 1 $state.Ack 'operator acknowledgement remains mandatory'
        Assert-CcodTrue $result.completed 'only scenario initiation is reported; final absence is verified separately'
    } finally {
        foreach($pair in @(@('Start-Process',$originalStart),@('Read-CcodInstalledLifecycleOperatorAck',$originalAck),@('Get-CcodInstalledLifecycleUninstallCommand',$originalCommand),@('Start-CcodInstalledLifecycleVerifiedUninstall',$originalLaunch))){if($null-ne$pair[1]){Set-Item ('Function:'+$pair[0]) $pair[1]}else{Remove-Item ('Function:'+$pair[0]) -ErrorAction SilentlyContinue}}
        if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}
    }
}

Invoke-CcodTest 'public finalizer launch arguments round trip through native parser and inert child' {
    . $harnessPath -Library
    Initialize-CcodInstalledLifecycleCommandLineParser
    $publicPath=Join-Path $repositoryRoot 'Uninstall-CodexControlOtherDevices.ps1'
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($publicPath,[ref]$tokens,[ref]$errors)
    Assert-CcodEqual 0 @($errors).Count 'public wrapper parses before extracting inert argument boundary'
    $converters=@($ast.FindAll({param($node)$node-is[Management.Automation.Language.FunctionDefinitionAst]-and$node.Name-in@('ConvertTo-CcodInstalledUninstallLiteral','ConvertTo-CcodPublicUninstallPowerShellLiteral')},$true))
    Assert-CcodEqual 2 $converters.Count 'both current native launch converters are covered'
    foreach($converter in $converters){. ([scriptblock]::Create($converter.Extent.Text))}
    $launchArguments=@($ast.FindAll({param($node)$node-is[Management.Automation.Language.AssignmentStatementAst]-and$node.Left-is[Management.Automation.Language.VariableExpressionAst]-and$node.Left.VariablePath.UserPath-ceq'arguments'},$true))
    Assert-CcodEqual 2 $launchArguments.Count 'installed and portable native argument builders are uniquely identified'
    $root=Join-Path (Get-CcodTestCanonicalTempRoot) ('ccod native args '+[char]0x6d4b+[char]0x8bd5+" O'Brien "+[guid]::NewGuid().ToString('N'))
    $powershellPath=Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::System)) 'WindowsPowerShell/v1.0/powershell.exe'
    $oldPolicy=[Environment]::GetEnvironmentVariable('PSExecutionPolicyPreference','Process')
    try {
        [IO.Directory]::CreateDirectory($root)|Out-Null
        $finalizer=Join-Path $root 'inert finalizer.ps1';$finalizerPath=$finalizer
        $probe=@'
param([switch]$WrapperResume,[string]$TransactionId,[string]$RuntimeRoot,[string]$InstallerRoot,[string]$InstallRoot,[int]$WrapperProcessId,[string]$WrapperCreationTimeUtc)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
[Console]::Out.WriteLine(([pscustomobject][ordered]@{transactionId=$TransactionId;runtimeRoot=$RuntimeRoot;installerRoot=$InstallerRoot;installRoot=$InstallRoot;wrapperPid=$WrapperProcessId;wrapperCreated=$WrapperCreationTimeUtc;resume=[bool]$WrapperResume}|ConvertTo-Json -Compress))
'@
        [IO.File]::WriteAllText($finalizer,$probe,[Text.UTF8Encoding]::new($true))
        $installerRoot=Join-Path $root 'runtime selected';$expectedInstallRoot=(Join-Path $root 'install root')+'\'
        $wrapperId=[int]417;$wrapperCreated='2030-02-03T04:05:01.0000006Z'
        $prepared=[pscustomobject]@{transactionId='11111111-2222-3333-4444-555555555555'}
        foreach($mode in @('Installed','Resume','Portable')){
            $resumeExisting=$mode-ceq'Resume';$arguments=$null
            $builder=$launchArguments[$(if($mode-ceq'Portable'){1}else{0})]
            . ([scriptblock]::Create($builder.Extent.Text))
            $argv=@([CcodInstalledLifecycleCommandLine]::Parse(('"'+$powershellPath+'" '+$arguments)))
            $fileIndex=[Array]::IndexOf($argv,'-File')
            Assert-CcodTrue ($fileIndex-gt0) 'actual builder supplies native File switch'
            Assert-CcodEqual $finalizer $argv[$fileIndex+1] ($mode+' preserves finalizer filename before any process starts')
            $expected=@('-TransactionId',$prepared.transactionId)
            if($mode-ceq'Portable'){$expected+=@('-InstallerRoot',$installerRoot,'-InstallRoot',$expectedInstallRoot)}
            else{$expected+=@('-RuntimeRoot',$installerRoot,'-InstallRoot',$expectedInstallRoot,'-WrapperProcessId',[string]$wrapperId,'-WrapperCreationTimeUtc',$wrapperCreated)}
            if($resumeExisting){$expected=@('-WrapperResume')+$expected}
            $actual=@($argv|Select-Object -Skip ($fileIndex+2))
            Assert-CcodEqual ($expected-join'|') ($actual-join'|') ($mode+' exact native arguments have no quotes or split paths')
            # Argument fidelity probe only: omit the existing production policy override.
            # The unmodified argv above is tested separately; no new Bypass child is run.
            $normalArguments=$arguments.Replace('-ExecutionPolicy Bypass ','')
            Assert-CcodTrue ($normalArguments-notmatch'(?i)-ExecutionPolicy') 'normal-policy smoke has no override argument'
            [Environment]::SetEnvironmentVariable('PSExecutionPolicyPreference',$null,'Process')
            $stdout=Join-Path $root ($mode+'.stdout');$stderr=Join-Path $root ($mode+'.stderr')
            $child=Start-Process -FilePath $powershellPath -ArgumentList $normalArguments -RedirectStandardOutput $stdout -RedirectStandardError $stderr -NoNewWindow -PassThru -Wait -ErrorAction Stop
            try{Assert-CcodEqual 0 $child.ExitCode ($mode+' inert child actually executes')}finally{$child.Dispose()}
            Assert-CcodEqual '' ([IO.File]::ReadAllText($stderr)) ($mode+' inert child produces no error')
            $value=[IO.File]::ReadAllText($stdout)|ConvertFrom-Json
            Assert-CcodEqual $prepared.transactionId $value.transactionId 'actual child retains transaction'
            Assert-CcodEqual $expectedInstallRoot $value.installRoot 'actual child retains spaced trailing-slash path'
            Assert-CcodEqual $resumeExisting $value.resume 'actual child retains resume distinction'
            if($mode-ceq'Portable'){Assert-CcodEqual $installerRoot $value.installerRoot 'portable child receives its root'}else{Assert-CcodEqual $installerRoot $value.runtimeRoot 'installed child receives its root';Assert-CcodEqual $wrapperCreated $value.wrapperCreated 'installed child preserves precise wrapper identity';Assert-CcodEqual $wrapperId $value.wrapperPid 'installed child preserves wrapper PID'}
        }
    } finally {
        [Environment]::SetEnvironmentVariable('PSExecutionPolicyPreference',$oldPolicy,'Process')
        if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}
    }
}

Invoke-CcodTest 'public uninstall bootstrap invocation returns the actual function receipt instead of CLI exit' {
    $publicPath=Join-Path $repositoryRoot 'Uninstall-CodexControlOtherDevices.ps1'
    $bootstrapSource=Join-Path $repositoryRoot 'src/persistence/UninstallBootstrap.ps1'
    $tokens=$null;$errors=$null;$publicAst=[Management.Automation.Language.Parser]::ParseFile($publicPath,[ref]$tokens,[ref]$errors)
    Assert-CcodEqual 0 @($errors).Count 'public wrapper parses'
    $bootstrapAst=[Management.Automation.Language.Parser]::ParseFile($bootstrapSource,[ref]$tokens,[ref]$errors)
    Assert-CcodEqual 0 @($errors).Count 'bootstrap source parses'
    $tail=@($bootstrapAst.EndBlock.Statements|Where-Object {$_-is[Management.Automation.Language.IfStatementAst]-and$_.Extent.Text.StartsWith('if ($MyInvocation.InvocationName')})
    Assert-CcodEqual 1 $tail.Count 'actual CLI-only entry is unambiguous'
    $calls=@($publicAst.FindAll({param($Node)$Node-is[Management.Automation.Language.AssignmentStatementAst]-and$Node.Left-is[Management.Automation.Language.VariableExpressionAst]-and$Node.Left.VariablePath.UserPath-ceq'prepared'},$true))
    Assert-CcodEqual 2 $calls.Count 'installed and portable actual caller expressions are exercised'
    $root=Join-Path (Get-CcodTestCanonicalTempRoot) ('ccod-bootstrap-receipt-'+[guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($root)|Out-Null
    try {
        $bootstrapPath=Join-Path $root 'bootstrap.ps1';$installerRoot=$root;$expectedInstallRoot=Join-Path $root 'install'
        $wrapperIdentity=[pscustomobject]@{pid=7}
        $stub=@'
function Invoke-CcodUninstallBootstrap {
 param($InstallerRoot,$InstallRoot,$Mode,$WrapperIdentity)
 [pscustomobject]@{transactionId='11111111-2222-3333-4444-555555555555';phase=$(if($Mode-ceq'PrepareInstalled'){'TaskRemoved'}else{'ReadyForInno'});installerRoot=$InstallerRoot;installRoot=$InstallRoot;mode=$Mode;wrapper=$WrapperIdentity}
}
'@
        [IO.File]::WriteAllText($bootstrapPath,$bootstrapAst.ParamBlock.Extent.Text+"`n"+$stub+"`n"+$tail[0].Extent.Text,[Text.UTF8Encoding]::new($false))
        foreach($definition in @($publicAst.EndBlock.Statements|Where-Object {$_-is[Management.Automation.Language.FunctionDefinitionAst]})){. ([scriptblock]::Create($definition.Extent.Text))}
        foreach($index in @(0,1)) {
            $prepared=$null
            . ([scriptblock]::Create($calls[$index].Extent.Text))
            Assert-CcodTrue ($null-ne$prepared) 'the real public caller obtains the bootstrap function receipt'
            Assert-CcodEqual '11111111-2222-3333-4444-555555555555' $prepared.transactionId 'producer receipt is not synthesized by the wrapper'
            Assert-CcodEqual $root $prepared.installerRoot 'caller runtime root reaches the function unchanged'
            Assert-CcodEqual $expectedInstallRoot $prepared.installRoot 'target root reaches the function unchanged'
            Assert-CcodEqual @('TaskRemoved','ReadyForInno')[$index] $prepared.phase 'both public modes preserve their terminal boundary'
        }
    } finally {if(Test-Path $root){Remove-Item $root -Recurse -Force}}
}

Invoke-CcodTest 'direct uninstall never consumes a substituted dependency after resolution' {
    . $harnessPath -Library
    $root=Join-Path (Get-CcodTestCanonicalTempRoot) ('ccod-uninstall-consumption-'+[guid]::NewGuid().ToString('N'))
    $originalFacts=${function:Get-CcodInstalledLifecycleFacts};$originalActive=${function:Read-CcodInstalledLifecycleActiveFact}
    $originalStart=${function:Start-Process};$originalAck=${function:Read-CcodInstalledLifecycleOperatorAck}
    $originalLaunch=${function:Start-CcodInstalledLifecycleVerifiedUninstall}
    try {
        $runtimeId='2.5.22-'+('a'*16)+'-'+('b'*32);$runtime=Join-Path $root ('runtime\'+$runtimeId)
        [IO.Directory]::CreateDirectory((Join-Path $runtime 'src/persistence'))|Out-Null
        $uninstaller=Join-Path $runtime 'Uninstall-CodexControlOtherDevices.ps1';$dependency=Join-Path $runtime 'src/persistence/UninstallBootstrap.ps1'
        $body='[CmdletBinding(SupportsShouldProcess=$true)]param(); $global:CcodUninstallRaceConsumed++; . (Join-Path $PSScriptRoot ''src/persistence/UninstallBootstrap.ps1''); [pscustomobject]@{Outcome=''InstalledFinalizationStarted'';TransactionId=''11111111-2222-3333-4444-555555555555'';FinalizerProcessId=1;KeptDeviceKeyStore=$true}'
        [IO.File]::WriteAllText($uninstaller,$body);[IO.File]::WriteAllText($dependency,'$global:CcodUninstallRaceValue=''original''')
        $records=@('Uninstall-CodexControlOtherDevices.ps1','src/persistence/UninstallBootstrap.ps1'|ForEach-Object {$path=Join-Path $runtime $_;[pscustomobject][ordered]@{path=$_;length=[long](Get-Item $path).Length;sha256=Get-CcodTestFileSha256 $path}})
        $manifestPath=Join-Path $runtime 'manifest.json';[IO.File]::WriteAllText($manifestPath,'inert manifest captured by independent facts seam')
        $facts=New-CcodHarnessFacts -Version '2.5.22' -RuntimeId $runtimeId;$facts.runtimeManifestFiles=$records;$facts.runtimeManifestSha256=Get-CcodTestFileSha256 $manifestPath
        $installer=Join-Path $root 'candidate.exe';[IO.File]::WriteAllText($installer,'inert candidate')
        $context=[pscustomobject]@{scenario='DirectUninstall';expectedVersion='2.5.22';installRoot=$root;installerApplicationRoot=(Join-Path $root 'obsolete');installerPath=$installer;candidatePayloadFiles=$records;transactionId='11111111-2222-3333-4444-555555555555'}
        $probe=[pscustomobject]@{Attack=$false;Seam=0;Ack=0;Facts=$facts}
        function Get-CcodInstalledLifecycleFacts {param($InstallRoot,$ExpectedVersion,$ExpectedPayloadFiles)return $probe.Facts}
        function Read-CcodInstalledLifecycleActiveFact {param($InstallRoot)[pscustomobject]@{activeRuntime=$runtimeId;generation=[uint64]1}}
        function Start-Process {param($FilePath,$ArgumentList,[switch]$PassThru,[switch]$Wait,$ErrorAction)
            $probe.Seam++;if($probe.Attack){[IO.File]::WriteAllText($dependency,'$global:CcodUninstallRaceValue=''substituted''')}
            & $uninstaller -Confirm:$false|Out-Null
            [pscustomobject]@{ExitCode=0}
        }
        function Start-CcodInstalledLifecycleVerifiedUninstall {param($Spec)
            $probe.Seam++;if($probe.Attack){[IO.File]::WriteAllText($dependency,'$global:CcodUninstallRaceValue=''substituted''')}
            Invoke-CcodInstalledLifecycleVerifiedUninstall -Spec $Spec|Out-Null
            [pscustomobject]@{ExitCode=0}
        }
        function Read-CcodInstalledLifecycleOperatorAck {param($Scenario,$Instructions)$probe.Ack++}
        $global:CcodUninstallRaceConsumed=0;$global:CcodUninstallRaceValue=$null
        $control=Invoke-CcodInstalledLifecycleOperatorScenario -Context $context
        Assert-CcodTrue $control.completed 'unchanged actual resolver and consumer path succeeds'
        Assert-CcodEqual 1 $global:CcodUninstallRaceConsumed 'positive control actually loads inert wrapper and dependency'
        Assert-CcodEqual 'original' $global:CcodUninstallRaceValue 'positive control observes original dependency bytes'
        $probe.Attack=$true;$probe.Seam=0;$probe.Ack=0;$global:CcodUninstallRaceConsumed=0;$global:CcodUninstallRaceValue=$null
        $failure=$null;try{Invoke-CcodInstalledLifecycleOperatorScenario -Context $context|Out-Null}catch{$failure=$_.FullyQualifiedErrorId}
        Assert-CcodEqual 1 $probe.Seam 'replacement occurs at the real parent-to-consumer boundary'
        Assert-CcodEqual 0 $global:CcodUninstallRaceConsumed 'substitution cannot execute even the inert wrapper'
        Assert-CcodTrue ($failure-like'CCOD_INTEGRATION_*') 'changed dependency fails closed before operation success'
        Assert-CcodEqual 0 $probe.Ack 'no success acknowledgement occurs after rejected consumption'
    } finally {
        foreach($pair in @(@('Get-CcodInstalledLifecycleFacts',$originalFacts),@('Read-CcodInstalledLifecycleActiveFact',$originalActive),@('Start-Process',$originalStart),@('Read-CcodInstalledLifecycleOperatorAck',$originalAck),@('Start-CcodInstalledLifecycleVerifiedUninstall',$originalLaunch))){if($null-ne$pair[1]){Set-Item ('Function:'+$pair[0]) $pair[1]}else{Remove-Item ('Function:'+$pair[0]) -ErrorAction SilentlyContinue}}
        Remove-Variable CcodUninstallRaceConsumed,CcodUninstallRaceValue -Scope Global -ErrorAction SilentlyContinue
        if(Test-Path $root){Remove-Item $root -Recurse -Force}
    }
}

Invoke-CcodTest 'verified uninstall launcher uses normal-policy native process and exact completion framing' {
    . $harnessPath -Library
    $root=Join-Path (Get-CcodTestCanonicalTempRoot) ('ccod child '+[char]0x6d4b+[char]0x8bd5+" O'Brien "+[guid]::NewGuid().ToString('N'))
    $oldRoot=$script:CcodInstalledLifecycleRepositoryRoot
    try {
        foreach($relative in @('tests/installed','tools','src/persistence/modules')){[IO.Directory]::CreateDirectory((Join-Path $root $relative))|Out-Null}
        Copy-Item (Join-Path $repositoryRoot 'tools/ReleaseAssetContract.psm1') (Join-Path $root 'tools/ReleaseAssetContract.psm1')
        foreach($leaf in @('PersistenceIO.psm1','StateStore.psm1','TrustedLogonIdentity.psm1','LifecycleTransaction.psm1','KernelObjects.psm1','ProductRegistration.psm1')){[IO.File]::WriteAllText((Join-Path $root ('src/persistence/modules/'+$leaf)),'# inert source held by real launcher')}
        $entry=Join-Path $root 'tests/installed/Invoke-InstalledLifecycleIntegration.ps1'
        $child=@'
param([switch]$VerifiedUninstallChild,[switch]$AllowMachineMutation,[switch]$AllowCodexRestart)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$reader=[IO.StreamReader]::new([Console]::OpenStandardInput(),[Text.UTF8Encoding]::new($false),$true)
$raw=$reader.ReadToEnd();$reader.Dispose()
$spec=$raw|ConvertFrom-Json
if(-not$VerifiedUninstallChild){throw 'child mode missing'}
if(-not[string]::IsNullOrEmpty($env:PSExecutionPolicyPreference)){throw 'inherited policy override'}
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$blocked=0
foreach($path in @($PSCommandPath,(Join-Path $root 'src/persistence/modules/KernelObjects.psm1'))){try{[IO.File]::WriteAllText($path,'wrong')}catch [IO.IOException]{$blocked++}}
try{[IO.Directory]::Move($root,$root+'-moved')}catch [IO.IOException]{$blocked++}
if($blocked-ne3){throw 'parent source authority absent'}
if($spec.text-cne('inert-'+[char]0x6d4b+[char]0x8bd5+" O'Brien")){throw 'stdin unicode drift'}
if($spec.mode-ceq'Error'){[Console]::Error.WriteLine('inert child failure');exit 1}
if($spec.mode-ceq'Empty'){exit 0}
if($spec.mode-ceq'Polluted'){[Console]::Out.WriteLine('unexpected output')}
[Console]::Out.WriteLine('CCOD_UNINSTALL_WRAPPER_COMPLETED')
'@
        [IO.File]::WriteAllText($entry,$child,[Text.UTF8Encoding]::new($true))
        $script:CcodInstalledLifecycleRepositoryRoot=$root
        $spec=[pscustomobject]@{mode='Normal';text=('inert-'+[char]0x6d4b+[char]0x8bd5+" O'Brien")}
        $control=Start-CcodInstalledLifecycleVerifiedUninstall -Spec $spec
        Assert-CcodEqual 0 $control.ExitCode 'normal-policy child consumes original source and exact Unicode input'
        foreach($mode in @('Error','Empty','Polluted')){$spec.mode=$mode;Assert-CcodThrows {Start-CcodInstalledLifecycleVerifiedUninstall -Spec $spec|Out-Null} 'CCOD_INTEGRATION_INSTALLER_FAILED'}
        $spec.mode='Normal';Assert-CcodEqual 0 (Start-CcodInstalledLifecycleVerifiedUninstall -Spec $spec).ExitCode 'failed child runs release all source holds for retry'
        [IO.File]::WriteAllText($entry,'# writable after child completion')
    } finally {$script:CcodInstalledLifecycleRepositoryRoot=$oldRoot;if(Test-Path $root){Remove-Item $root -Recurse -Force}}
}

Invoke-CcodTest 'native uninstall child requires both machine and host restart authorizations before consumption' {
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($harnessPath,[ref]$tokens,[ref]$errors)
    Assert-CcodEqual 0 @($errors).Count 'real child entry parses'
    $tail=@($ast.EndBlock.Statements|Where-Object {$_-is[Management.Automation.Language.IfStatementAst]-and$_.Extent.Text.StartsWith('if ($VerifiedUninstallChild)')})
    Assert-CcodEqual 1 $tail.Count 'one actual native child dispatch is selected'
    $root=Join-Path (Get-CcodTestCanonicalTempRoot) ('ccod-child-consent-'+[guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($root)|Out-Null
    try {
        $probe=Join-Path $root 'child.ps1'
        $stub=@'
$ErrorActionPreference='Stop'
$script:CcodInstalledLifecyclePersistenceIoModule=New-Module {function Test-CcodJsonHasNoDuplicateProperties {param($Json)return $true}}
function Throw-CcodInstalledLifecycleError {param($Id,$Message,$Target)throw $Id}
function Invoke-CcodInstalledLifecycleVerifiedUninstall {param($Spec)[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'consumed.txt'),'inert consumer reached')}
'@
        [IO.File]::WriteAllText($probe,$ast.ParamBlock.Extent.Text+"`n"+$stub+"`n"+$tail[0].Extent.Text,[Text.UTF8Encoding]::new($true))
        $spec=[pscustomobject]@{installRoot=[IO.Path]::GetFullPath((Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'CodexControlOtherDevices'))}
        foreach($arguments in @('',' -AllowMachineMutation',' -AllowCodexRestart',' -AllowMachineMutation -AllowCodexRestart')) {
            $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=Join-Path $PSHOME 'powershell.exe'
            $start.Arguments='-NoLogo -NoProfile -NonInteractive -File "'+$probe+'" -VerifiedUninstallChild'+$arguments
            $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
            [void]$start.EnvironmentVariables.Remove('PSExecutionPolicyPreference')
            $child=[Diagnostics.Process]::Start($start)
            try {
                $output=$child.StandardOutput.ReadToEndAsync();$errorOutput=$child.StandardError.ReadToEndAsync()
                Write-CcodTestProcessInput -Process $child -Text ($spec|ConvertTo-Json -Compress);$child.StandardInput.Close()
                Assert-CcodTrue ($child.WaitForExit(15000)) 'inert child gate completes'
                $authorized=$arguments-ceq' -AllowMachineMutation -AllowCodexRestart'
                Assert-CcodEqual $authorized ([IO.File]::Exists((Join-Path $root 'consumed.txt'))) 'only both explicit consents allow reaching the consumer'
                if($authorized){Assert-CcodEqual 0 $child.ExitCode 'authorized inert child reaches valid dispatch';Assert-CcodEqual ('CCOD_UNINSTALL_WRAPPER_COMPLETED'+[Environment]::NewLine) $output.Result 'authorized dispatch returns exact marker'}
                else{Assert-CcodTrue ($child.ExitCode-ne0) 'missing consent cannot report success'}
            } finally {if(-not$child.HasExited){$child.Kill();$child.WaitForExit()};$child.Dispose()}
        }
    } finally {if(Test-Path $root){Remove-Item $root -Recurse -Force}}
}

Invoke-CcodTest 'native verified consumer retains dependencies until wrapper return and releases before process exit' {
    . $harnessPath -Library
    $root=Join-Path (Get-CcodTestCanonicalTempRoot) ('ccod-consumer-native-'+[guid]::NewGuid().ToString('N'))
    $child=$null
    try {
        $runtimeId='2.5.22-'+('a'*16)+'-'+('b'*32);$runtime=Join-Path $root ('runtime\'+$runtimeId)
        [IO.Directory]::CreateDirectory((Join-Path $runtime 'src/persistence'))|Out-Null
        $wrapper=Join-Path $runtime 'Uninstall-CodexControlOtherDevices.ps1';$dependency=Join-Path $runtime 'src/persistence/UninstallBootstrap.ps1'
        $body=@'
[CmdletBinding(SupportsShouldProcess=$true)]param()
$blocked=0
foreach($path in @($PSCommandPath,(Join-Path $PSScriptRoot 'src/persistence/UninstallBootstrap.ps1'))){try{[IO.File]::WriteAllText($path,'not allowed')}catch [IO.IOException]{$blocked++}}
try{[IO.Directory]::Move($PSScriptRoot,$PSScriptRoot+'-moved')}catch [IO.IOException]{$blocked++}
. (Join-Path $PSScriptRoot 'src/persistence/UninstallBootstrap.ps1')
if($bootstrapProof-cne'original-bootstrap'){throw 'changed bootstrap consumed'}
[Console]::Out.WriteLine('CCOD_HELD='+$blocked);[Console]::Out.Flush()
$reader=[IO.StreamReader]::new([Console]::OpenStandardInput(),[Text.UTF8Encoding]::new($false),$true)
if($reader.ReadLine()-cne'continue'){throw 'handshake failed'}
[pscustomobject][ordered]@{Outcome='InstalledFinalizationStarted';TransactionId='11111111-2222-3333-4444-555555555555';FinalizerProcessId=[int]$PID;KeptDeviceKeyStore=$true}
'@
        [IO.File]::WriteAllText($wrapper,$body,[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText($dependency,'$bootstrapProof=''original-bootstrap''')
        $manifest=Join-Path $runtime 'manifest.json';[IO.File]::WriteAllText($manifest,'inert manifest bound by captured facts')
        $records=@('Uninstall-CodexControlOtherDevices.ps1','src/persistence/UninstallBootstrap.ps1'|ForEach-Object {$path=Join-Path $runtime $_;[pscustomobject][ordered]@{path=$_;length=[long](Get-Item $path).Length;sha256=Get-CcodTestFileSha256 $path}})
        $facts=New-CcodHarnessFacts -Version '2.5.22' -RuntimeId $runtimeId;$facts.runtimeManifestFiles=$records;$facts.runtimeManifestSha256=Get-CcodTestFileSha256 $manifest
        $spec=[pscustomobject][ordered]@{schemaVersion=1;installRoot=$root;expectedVersion='2.5.22';runtimeId=$runtimeId;generation=1;manifestSha256=$facts.runtimeManifestSha256;runtimeFiles=$records;candidatePayloadFiles=$records}
        [IO.File]::WriteAllText((Join-Path $root 'facts.json'),($facts|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $root 'spec.json'),($spec|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
        $driver=Join-Path $root 'driver.ps1'
        $text=@'
param([string]$IntegrationPath)
$ErrorActionPreference='Stop';$WarningPreference='SilentlyContinue'
. $IntegrationPath -Library
$script:FixtureFacts=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'facts.json'))|ConvertFrom-Json
$spec=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'spec.json'))|ConvertFrom-Json
function Get-CcodInstalledLifecycleFacts {param($InstallRoot,$ExpectedVersion,$ExpectedPayloadFiles)return $script:FixtureFacts}
function Read-CcodInstalledLifecycleActiveFact {param($InstallRoot)[pscustomobject]@{activeRuntime=$script:FixtureFacts.activeRuntimeId;generation=1}}
$result=Invoke-CcodInstalledLifecycleVerifiedUninstall -Spec $spec
$runtime=Join-Path (Join-Path $spec.installRoot 'runtime') $spec.runtimeId
[IO.Directory]::Move($runtime,$runtime+'-released')
[IO.Directory]::Move($runtime+'-released',$runtime)
if($result.Outcome-cne'InstalledFinalizationStarted'){throw 'wrong completion'}
[Console]::Out.WriteLine('CCOD_RELEASED_BEFORE_EXIT')
'@
        [IO.File]::WriteAllText($driver,$text,[Text.UTF8Encoding]::new($false))
        $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=Join-Path $PSHOME 'powershell.exe';$start.Arguments='-NoLogo -NoProfile -NonInteractive -File "'+$driver+'" -IntegrationPath "'+$harnessPath+'"'
        $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
        [void]$start.EnvironmentVariables.Remove('PSExecutionPolicyPreference')
        $child=[Diagnostics.Process]::Start($start);$errors=$child.StandardError.ReadToEndAsync();$line=$child.StandardOutput.ReadLineAsync()
        Assert-CcodTrue ($line.Wait(20000)) 'real consumer reaches the explicit held checkpoint'
        Assert-CcodEqual 'CCOD_HELD=3' $line.Result 'actual child cannot rewrite wrapper dependency or ancestor while executing'
        $blocked=$false;try{[IO.File]::WriteAllText($dependency,'outside writer')}catch [IO.IOException]{$blocked=$true};Assert-CcodTrue $blocked 'parent also cannot alter held dependency'
        Write-CcodTestProcessInput -Process $child -Text 'continue' -AddNewLine;$child.StandardInput.Close();$rest=$child.StandardOutput.ReadToEndAsync()
        Assert-CcodTrue ($child.WaitForExit(20000)) 'actual consumer exits after dependency handoff'
        Assert-CcodEqual 0 $child.ExitCode ('real consumer failure: '+$errors.Result)
        Assert-CcodEqual ('CCOD_RELEASED_BEFORE_EXIT'+[Environment]::NewLine) $rest.Result 'directory authority is released before wrapper process exit'
        Assert-CcodEqual '' $errors.Result 'child has no hidden errors'
        [IO.Directory]::Move($runtime,$runtime+'-reclaimed')
    } finally {if($null-ne$child){if(-not$child.HasExited){$child.StandardInput.Close();if(-not$child.WaitForExit(15000)){$child.Kill();$child.WaitForExit()}};$child.Dispose()};if(Test-Path $root){Remove-Item $root -Recurse -Force}}
}

Invoke-CcodTest 'staged uninstall dependency cannot change at its real module import boundary' {
    $root=Join-Path (Get-CcodTestCanonicalTempRoot) ('ccod-stage-load-'+[guid]::NewGuid().ToString('N'))
    $module=$null;$loaded=$null
    try {
        $payload=Join-Path $root 'payload';$modules=Join-Path $payload 'src/persistence/modules'
        [IO.Directory]::CreateDirectory($modules)|Out-Null
        $target=Join-Path $modules 'InstallLifecycle.psm1'
        [IO.File]::WriteAllText($target,'function Invoke-CcodUninstallCleanup { param($InstallRoot,$Transaction,$WriteTransaction,$StopAfterTaskRemoval) $Transaction }; Export-ModuleMember -Function Invoke-CcodUninstallCleanup')
        $records=@([pscustomobject][ordered]@{path='src/persistence/modules/InstallLifecycle.psm1';length=[long](Get-Item $target).Length;sha256=Get-CcodTestFileSha256 $target})
        $transaction=[pscustomobject]@{installedBinding=[pscustomobject]@{payloadRecords=$records}}
        $bootstrap=Join-Path $repositoryRoot 'src/persistence/UninstallBootstrap.ps1'
        $module=New-Module -ArgumentList $bootstrap -ScriptBlock {param($Source). $Source}
        $probe=[pscustomobject]@{Target=$target;Attack=$false;Reached=0;Denied=0;Loaded=$null}
        &$module {
            param($State)
            $script:BoundaryProbe=$State
            function script:Import-Module {
                [CmdletBinding()]param([string]$Name,[switch]$Force,[switch]$PassThru,[switch]$DisableNameChecking)
                $state=$script:BoundaryProbe
                if($Name-ceq$state.Target){$state.Reached++;if($state.Attack){try{[IO.File]::AppendAllText($Name,"`nthrow 'substituted module initializer'")}catch [IO.IOException]{$state.Denied++}}}
                $state.Loaded=Microsoft.PowerShell.Core\Import-Module -Name $Name -Force -PassThru -DisableNameChecking
                if($PassThru){return $state.Loaded}
            }
        } $probe
        $run=&$module {(Get-CcodUninstallBootstrapAdapters).RunCleanup}
        $control=&$module {param($Run,$Root,$Transaction)&$Run $Root $Root $Root $Transaction {param($Value)} 'PrepareInstalled'} $run $root $transaction
        Assert-CcodTrue ($null-ne$control) 'valid staged module reaches its actual cleanup function'
        $probe.Attack=$true;$probe.Reached=0;$failure=$null
        try{&$module {param($Run,$Root,$Transaction)&$Run $Root $Root $Root $Transaction {param($Value)} 'PrepareInstalled'} $run $root $transaction|Out-Null}catch{$failure=$_}
        Assert-CcodEqual 1 $probe.Reached 'attack reaches the real import seam'
        Assert-CcodEqual 1 $probe.Denied 'held staged dependency refuses modification through actual loader'
        Assert-CcodEqual $null $failure 'valid original cleanup is not poisoned by a denied writer'
        [IO.File]::AppendAllText($target,"`n# writable after consumption")
    } finally {if($null-ne$probe-and$null-ne$probe.Loaded){Remove-Module $probe.Loaded -Force -ErrorAction SilentlyContinue};if($null-ne$module){Remove-Module $module -Force -ErrorAction SilentlyContinue};if(Test-Path $root){Remove-Item $root -Recurse -Force}}
}

Invoke-CcodTest 'public installed finalizer retains staged bytes through native child acquisition' {
    $root=Join-Path (Get-CcodTestCanonicalTempRoot) ('ccod-finalizer-launch-'+[guid]::NewGuid().ToString('N'))
    $originalStart=${function:Start-Process};$process=$null
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repositoryRoot 'Uninstall-CodexControlOtherDevices.ps1'),[ref]$tokens,[ref]$errors)
    Assert-CcodEqual 0 @($errors).Count 'public wrapper parses'
    foreach($definition in @($ast.EndBlock.Statements|Where-Object {$_-is[Management.Automation.Language.FunctionDefinitionAst]})){. ([scriptblock]::Create($definition.Extent.Text))}
    $launch=@($ast.FindAll({param($Node)$Node-is[Management.Automation.Language.TryStatementAst]-and$Node.Body.Extent.Text.StartsWith('{$process=')},$true))
    Assert-CcodEqual 1 $launch.Count 'actual installed finalizer launch is unique'
    try {
        $transactionDirectory=$root;$payloadRoot=Join-Path $root 'payload';$bootstrapPath=Join-Path $repositoryRoot 'src/persistence/UninstallBootstrap.ps1'
        [IO.Directory]::CreateDirectory((Join-Path $payloadRoot 'src/persistence'))|Out-Null
        $finalizer=Join-Path $payloadRoot 'src/persistence/InstalledUninstallFinalizer.ps1'
        $child=@'
param([string]$AuthorityReadyHandle)
$ErrorActionPreference='Stop'
. '__BOOTSTRAP__'
$records=[IO.File]::ReadAllText('__RECORDS__')|ConvertFrom-Json
$lease=Open-CcodUninstallBootstrapPayloadAuthority -PayloadRoot '__PAYLOAD__' -Records @($records)
try {
 if(-not[string]::IsNullOrEmpty($AuthorityReadyHandle)){
  $pipe=[IO.Pipes.AnonymousPipeClientStream]::new([IO.Pipes.PipeDirection]::Out,$AuthorityReadyHandle)
  try{$bytes=[BitConverter]::GetBytes([int]$PID);$pipe.Write($bytes,0,$bytes.Length);$pipe.Flush()}finally{$pipe.Dispose()}
 }
}finally{$lease.Dispose()}
'@
        $recordsPath=Join-Path $root 'records.json'
        $child=$child.Replace('__BOOTSTRAP__',$bootstrapPath.Replace("'","''")).Replace('__RECORDS__',$recordsPath.Replace("'","''")).Replace('__PAYLOAD__',$payloadRoot.Replace("'","''"))
        [IO.File]::WriteAllText($finalizer,$child,[Text.UTF8Encoding]::new($false))
        $records=@([pscustomobject][ordered]@{path='src/persistence/InstalledUninstallFinalizer.ps1';length=[long](Get-Item $finalizer).Length;sha256=Get-CcodTestFileSha256 $finalizer})
        [IO.File]::WriteAllText($recordsPath,(ConvertTo-Json -InputObject $records -Depth 4),[Text.UTF8Encoding]::new($false))
        $prepared=[pscustomobject]@{installedBinding=[pscustomobject]@{payloadRecords=$records}}
        $powershellPath=Join-Path $PSHOME 'powershell.exe';$arguments='-NoLogo -NoProfile -NonInteractive -File "'+$finalizer+'"'
        $probe=[pscustomobject]@{Attack=$false;Reached=0;Denied=0}
        function Start-Process {
            [CmdletBinding()]param($FilePath,$ArgumentList,$WindowStyle,$RedirectStandardOutput,$RedirectStandardError,[switch]$PassThru)
            $probe.Reached++
            if($probe.Attack){try{[IO.File]::AppendAllText($finalizer,"`nthrow 'substituted finalizer initializer'")}catch [IO.IOException]{$probe.Denied++}}
            $child=Microsoft.PowerShell.Management\Start-Process @PSBoundParameters
            [void]$child.Handle
            return $child
        }
        foreach($attack in @($false,$true)) {
            $probe.Attack=$attack;$probe.Reached=0;$probe.Denied=0;$failure=$null
            try{. ([scriptblock]::Create($launch[0].Extent.Text))}catch{$failure=$_}
            Assert-CcodEqual 1 $probe.Reached 'real parent launch boundary is exercised'
            if($attack){Assert-CcodEqual 1 $probe.Denied 'staged script replacement is denied before the native child reads it'}
            Assert-CcodEqual $null $failure 'original finalizer acquisition is not poisoned by a denied replacement'
            Assert-CcodTrue ($process.WaitForExit(15000)) 'owned inert finalizer finishes'
            Assert-CcodEqual 0 $process.ExitCode ('inert child failed: '+[IO.File]::ReadAllText((Join-Path $root 'installed-finalizer.stderr.log')))
            $process.Dispose();$process=$null
        }
        [IO.File]::AppendAllText($finalizer,"`n# released after native acquisition")
    } finally {if($null-ne$process){if(-not$process.HasExited){$process.Kill();$process.WaitForExit()};$process.Dispose()};if($null-ne$originalStart){Set-Item Function:Start-Process $originalStart}else{Remove-Item Function:Start-Process -ErrorAction SilentlyContinue};if(Test-Path $root){Remove-Item $root -Recurse -Force}}
}

Invoke-CcodTest 'default finalizer pins its staged closure before validating the envelope' {
    $root=Join-Path (Get-CcodTestCanonicalTempRoot) ('ccod-finalizer-c-'+[guid]::NewGuid().ToString('N'))
    $previous=[Environment]::GetEnvironmentVariable('LOCALAPPDATA','Process');$module=$null
    try {
        [Environment]::SetEnvironmentVariable('LOCALAPPDATA',$root,'Process')
        $id='11111111-2222-3333-4444-555555555555';$payload=Join-Path $root ('CodexRemote-fix-uninstall/'+$id+'/payload')
        $source=Join-Path $repositoryRoot 'src/persistence/InstalledUninstallFinalizer.ps1'
        $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
        Assert-CcodEqual 0 @($errors).Count 'actual finalizer parses'
        $entries=@($ast.FindAll({param($Node)$Node-is[Management.Automation.Language.AssignmentStatementAst]-and$Node.Left.Extent.Text-ceq'$script:CcodInstalledFinalizerPayloadEntries'},$true))
        Assert-CcodEqual 1 $entries.Count 'one complete production payload allowlist'
        $leaves=@($entries[0].Right.FindAll({param($Node)$Node-is[Management.Automation.Language.StringConstantExpressionAst]},$true)|ForEach-Object Value)
        foreach($relative in $leaves){$path=Join-Path $payload $relative;[IO.Directory]::CreateDirectory((Split-Path $path -Parent))|Out-Null;[IO.File]::WriteAllText($path,'# inert staged payload')}
        $entry=Join-Path $payload 'src/persistence/InstalledUninstallFinalizer.ps1';Copy-Item $source $entry -Force
        $module=New-Module -ArgumentList $entry -ScriptBlock {param($Path). $Path}
        $probe=[pscustomobject]@{Target=(Join-Path $payload 'src/persistence/UninstallBootstrap.ps1');Root=$payload;Reached=0;Denied=0}
        &$module {
            param($Probe)
            $script:AuthorityProbe=$Probe
            function script:Read-CcodInstalledFinalizerEnvelope {
                param($TransactionRoot,$TransactionId,$PayloadRoot,$RuntimeRoot,$InstallRoot)
                $script:AuthorityProbe.Reached++
                try{[IO.File]::AppendAllText($script:AuthorityProbe.Target,'# must not change')}catch [IO.IOException]{$script:AuthorityProbe.Denied++}
                try{[IO.Directory]::Move($script:AuthorityProbe.Root,$script:AuthorityProbe.Root+'-moved');[IO.Directory]::Move($script:AuthorityProbe.Root+'-moved',$script:AuthorityProbe.Root)}catch [IO.IOException]{$script:AuthorityProbe.Denied++}
                return [pscustomobject]@{validated=$true}
            }
            function script:Get-CcodInstalledFinalizerAdapters {param($Adapters,$TransactionRoot,$PayloadRoot,$RuntimeRoot,$InstallRoot)throw 'INERT_STOP_BEFORE_ANY_MACHINE_OPERATION'}
        } $probe
        $install=Join-Path $root 'CodexControlOtherDevices';$runtime=Join-Path $install ('runtime/2.5.22-'+('a'*16)+'-'+('b'*32))
        $failure=$null;try{&$module {param($Id,$Runtime,$Install)Invoke-CcodInstalledUninstallFinalizer -TransactionId $Id -RuntimeRoot $Runtime -InstallRoot $Install -WrapperIdentity $null -Resume} $id $runtime $install|Out-Null}catch{$failure=$_}
        Assert-CcodEqual 1 $probe.Reached 'actual default path reaches envelope validation'
        Assert-CcodEqual 2 $probe.Denied 'complete staged closure and ancestry remain immutable before envelope checks'
        Assert-CcodTrue ($failure.Exception.Message-like'*INERT_STOP_BEFORE_ANY_MACHINE_OPERATION*') 'test stops before any machine adapter can operate'
        [IO.File]::WriteAllText($probe.Target,'released after rejected operation')
        [IO.Directory]::Move($payload,$payload+'-released')
    } finally {if($null-ne$module){Remove-Module $module -Force -ErrorAction SilentlyContinue};[Environment]::SetEnvironmentVariable('LOCALAPPDATA',$previous,'Process');if(Test-Path $root){Remove-Item $root -Recurse -Force}}
}

Invoke-CcodTest 'default finalizer never treats an unavailable wrapper observation as process exit' {
    $source=Join-Path $repositoryRoot 'src/persistence/InstalledUninstallFinalizer.ps1'
    $module=New-Module -ArgumentList $source -ScriptBlock {param($Path). $Path}
    $current=[Diagnostics.Process]::GetCurrentProcess();$windowsIdentity=[Security.Principal.WindowsIdentity]::GetCurrent();$child=$null
    try {
        $identity=[pscustomobject]@{pid=[int]$current.Id;creationTimeUtc=$current.StartTime.ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture);sessionId=[int]$current.SessionId;userSid=[string]$windowsIdentity.User.Value}
        $control=&$module {
            param($Identity)
            $adapters=Get-CcodInstalledFinalizerAdapters -TransactionRoot (Get-CcodTestCanonicalTempRoot) -PayloadRoot (Get-CcodTestCanonicalTempRoot) -RuntimeRoot (Get-CcodTestCanonicalTempRoot) -InstallRoot (Get-CcodTestCanonicalTempRoot)
            &$adapters.WaitWrapperExit $Identity 0
        } $identity
        Assert-CcodTrue $control.verifiedAtStart 'real current wrapper identity is observable'
        Assert-CcodTrue (-not $control.exited) 'a live wrapper does not authorize deletion'
        $start=[Diagnostics.ProcessStartInfo]::new()
        $start.FileName=Join-Path $PSHOME 'powershell.exe';$start.Arguments='-NoLogo -NoProfile -NonInteractive -Command "Start-Sleep -Milliseconds 800"'
        $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.EnvironmentVariables.Remove('PSExecutionPolicyPreference')
        $child=[Diagnostics.Process]::Start($start)
        $exitedIdentity=[pscustomobject]@{pid=[int]$child.Id;creationTimeUtc=$child.StartTime.ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture);sessionId=[int]$child.SessionId;userSid=$identity.userSid}
        Assert-CcodTrue ($child.WaitForExit(10000)) 'owned inert wrapper actually exits'
        Assert-CcodEqual 0 $child.ExitCode 'owned inert wrapper exits successfully'
        $child.Dispose();$child=$null
        $exited=&$module {
            param($Identity)
            $adapters=Get-CcodInstalledFinalizerAdapters -TransactionRoot (Get-CcodTestCanonicalTempRoot) -PayloadRoot (Get-CcodTestCanonicalTempRoot) -RuntimeRoot (Get-CcodTestCanonicalTempRoot) -InstallRoot (Get-CcodTestCanonicalTempRoot)
            &$adapters.WaitWrapperExit $Identity 1000
        } $exitedIdentity
        Assert-CcodTrue ($exited.verifiedAtStart-and$exited.exited) 'exact native process-not-found proves the already exited wrapper is absent'
        foreach($failurePoint in @('Initial','Polling')) {
            foreach($category in @('PermissionDenied','ReadError','ObjectNotFound','Empty')) {
                $probe=[pscustomobject]@{Calls=0;FailurePoint=$failurePoint;Category=$category}
                &$module {
                    param($Probe)
                    $script:WrapperObservationProbe=$Probe
                    function script:Get-Process {
                        [CmdletBinding()]param([int]$Id)
                        $script:WrapperObservationProbe.Calls++
                        if($script:WrapperObservationProbe.FailurePoint-ceq'Polling'-and$script:WrapperObservationProbe.Calls-eq1){return Microsoft.PowerShell.Management\Get-Process -Id $Id -ErrorAction Stop}
                        if($script:WrapperObservationProbe.Category-ceq'Empty'){return}
                        Write-Error -Message 'INERT_WRAPPER_OBSERVATION_FAILURE' -Category $script:WrapperObservationProbe.Category -ErrorId 'CcodWrapperObservationFailure'
                    }
                } $probe
                $result=$null;$failure=$null
                try {
                    $result=&$module {
                        param($Identity)
                        $adapters=Get-CcodInstalledFinalizerAdapters -TransactionRoot (Get-CcodTestCanonicalTempRoot) -PayloadRoot (Get-CcodTestCanonicalTempRoot) -RuntimeRoot (Get-CcodTestCanonicalTempRoot) -InstallRoot (Get-CcodTestCanonicalTempRoot)
                        &$adapters.WaitWrapperExit $Identity 1000
                    } $identity
                } catch {$failure=$_}
                Assert-CcodTrue ($probe.Calls-gt0) "$failurePoint/$category reaches the real process observation seam"
                Assert-CcodTrue ($null-ne$failure) "$failurePoint/$category must fail closed rather than authorize deletion"
                Assert-CcodEqual $null $result "$failurePoint/$category returns no successful exit proof"
            }
        }
    } finally {if($null-ne$child){if(-not$child.HasExited){$child.Kill();$child.WaitForExit()};$child.Dispose()};$current.Dispose();$windowsIdentity.Dispose();Remove-Module $module -Force -ErrorAction SilentlyContinue}
}

Invoke-CcodTest 'uninstall and finalizer independently embed the same native payload lease' {
    $definitions=@()
    foreach($relative in @('src/persistence/UninstallBootstrap.ps1','src/persistence/InstalledUninstallFinalizer.ps1')) {
        $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repositoryRoot $relative),[ref]$tokens,[ref]$errors)
        Assert-CcodEqual 0 @($errors).Count 'native lease entry parses'
        $function=@($ast.EndBlock.Statements|Where-Object {$_-is[Management.Automation.Language.FunctionDefinitionAst]-and$_.Name-ceq'Initialize-CcodUninstallPayloadAuthority'})
        Assert-CcodEqual 1 $function.Count 'each independent entry has its own bootstrap before any unheld import'
        $definitions+=($function[0].Extent.Text-replace"`r`n","`n")
    }
    Assert-CcodEqual $definitions[0] $definitions[1] 'the shared native type cannot drift depending on who initializes first'
}

Invoke-CcodTest 'actual product module naming warning does not pollute the verified uninstall result' {
    . $harnessPath -Library
    $originalImport=${function:Import-Module};$probe=[pscustomobject]@{Module=$null;Calls=0}
    try {
        function Import-Module {
            [CmdletBinding()]param([Parameter(Position=0)][string]$Name,[switch]$PassThru,[switch]$DisableNameChecking)
            $probe.Calls++
            $probe.Module=Microsoft.PowerShell.Core\Import-Module -Name $Name -Force -PassThru -DisableNameChecking:$DisableNameChecking
            &$probe.Module {function script:Read-CcodCurrentProductState {param($ExpectedRuntimeId)[pscustomobject]@{valid=$true;runtimeId=$ExpectedRuntimeId}}}
            if($PassThru){return $probe.Module}
        }
        $values=@(& {Get-CcodInstalledLifecycleProductState -RuntimeId ('2.5.22-'+('a'*16)+'-'+('b'*32))} 3>&1)
        Assert-CcodEqual 1 $probe.Calls 'actual production import is reached once'
        Assert-CcodEqual 0 @($values|Where-Object {$_-is[Management.Automation.WarningRecord]}).Count 'actual ProductRegistration import must not add name-check prose to native stdout'
        Assert-CcodEqual 1 $values.Count 'the product observation remains exactly one object'
        Assert-CcodTrue $values[0].valid 'positive observation is consumed without registry mutation'
    } finally {if($null-ne$probe.Module){Remove-Module $probe.Module -Force -ErrorAction SilentlyContinue};if($null-ne$originalImport){Set-Item Function:Import-Module $originalImport}else{Remove-Item Function:Import-Module -ErrorAction SilentlyContinue}}
}

Invoke-CcodTest 'sealed uninstall resolver requires active manifest file identity' {
    . $harnessPath -Library
    $root=Join-Path (Get-CcodTestCanonicalTempRoot) ('ccod-uninstall-resolver-'+[guid]::NewGuid().ToString('N'))
    $originalFacts=${function:Get-CcodInstalledLifecycleFacts};$originalActive=${function:Read-CcodInstalledLifecycleActiveFact}
    try {
        $runtimeId='2.5.22-'+('a'*16)+'-'+('b'*32);$runtime=Join-Path $root ('runtime\'+$runtimeId)
        [IO.Directory]::CreateDirectory($runtime)|Out-Null
        $path=Join-Path $runtime 'Uninstall-CodexControlOtherDevices.ps1';[IO.File]::WriteAllText($path,'# inert test uninstaller')
        $records=@([pscustomobject][ordered]@{path='Uninstall-CodexControlOtherDevices.ps1';length=[long](Get-Item $path).Length;sha256=Get-CcodTestFileSha256 $path})
        $facts=New-CcodHarnessFacts -Version '2.5.22' -RuntimeId $runtimeId;$facts.runtimeManifestFiles=$records
        $state=[pscustomobject]@{Facts=$facts;Reads=0;Drift=$false}
        function Get-CcodInstalledLifecycleFacts {param($InstallRoot,$ExpectedVersion,$ExpectedPayloadFiles)$state.Reads++;return $state.Facts}
        function Read-CcodInstalledLifecycleActiveFact {param($InstallRoot)[pscustomobject]@{activeRuntime=$(if($state.Drift){'wrong'}else{$state.Facts.activeRuntimeId});generation=[uint64]1}}
        $result=Get-CcodInstalledLifecycleUninstallCommand -InstallRoot $root -ExpectedVersion '2.5.22' -ExpectedPayloadFiles $records
        Assert-CcodEqual $root $result.Spec.installRoot 'typed specification binds the current root'
        Assert-CcodEqual $runtimeId $result.Spec.runtimeId 'typed specification binds the selected runtime'
        Assert-CcodEqual $records[0].sha256 $result.Spec.runtimeFiles[0].sha256 'typed specification retains the validated script hash'
        Assert-CcodEqual $null $result.PSObject.Properties['Arguments'] 'resolver does not expose a mutable executable command'
        [IO.File]::WriteAllText($path,'# changed uninstaller')
        Assert-CcodThrows {Get-CcodInstalledLifecycleUninstallCommand -InstallRoot $root -ExpectedVersion '2.5.22' -ExpectedPayloadFiles $records|Out-Null} 'CCOD_INTEGRATION_OBSERVATION_UNAVAILABLE'
        [IO.File]::WriteAllText($path,'# inert test uninstaller');$state.Drift=$true
        Assert-CcodThrows {Get-CcodInstalledLifecycleUninstallCommand -InstallRoot $root -ExpectedVersion '2.5.22' -ExpectedPayloadFiles $records|Out-Null} 'CCOD_INTEGRATION_OBSERVATION_UNAVAILABLE'
        $state.Drift=$false;$state.Facts.protectionReady=$false
        Assert-CcodThrows {Get-CcodInstalledLifecycleUninstallCommand -InstallRoot $root -ExpectedVersion '2.5.22' -ExpectedPayloadFiles $records|Out-Null} 'CCOD_INTEGRATION_OBSERVATION_UNAVAILABLE'
    } finally {
        Set-Item Function:Get-CcodInstalledLifecycleFacts $originalFacts;Set-Item Function:Read-CcodInstalledLifecycleActiveFact $originalActive
        if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}
    }
}

Invoke-CcodTest 'sealed payload comparison validates generated shortcuts rather than ignoring extras' {
    . $harnessPath -Library
    $root=Join-Path (Get-CcodTestCanonicalTempRoot) ('ccod-product-proof-'+[guid]::NewGuid().ToString('N'))
    $original=${function:Get-CcodInstalledLifecycleProductState}
    try {
        $payload=@([pscustomobject][ordered]@{path='package.json';length=[long]25;sha256=('a'*64)})
        $records=@($payload)+@([pscustomobject][ordered]@{path='registration/Desktop.CodexRemote-fix.lnk';length=[long]40;sha256=('b'*64)},[pscustomobject][ordered]@{path='registration/StartMenu.CodexRemote-fix.lnk';length=[long]41;sha256=('c'*64)})
        $runtimeId='2.5.22-'+('d'*16)+'-'+('e'*32)
        $proof=[pscustomobject][ordered]@{phase='Ready';installRoot=$root;runtimeId=$runtimeId;runtimeGeneration=[uint64]8;packageSha256=('f'*64);manifestSha256=('9'*64);startMenuSha256=('c'*64);desktopSha256=('b'*64);targetPath=[IO.Path]::GetFullPath((Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::System)) 'schtasks.exe'));arguments='/Run /TN "Codex Control Other Devices Supervisor"'}
        $state=[pscustomobject]@{valid=$true;readyEvidence=$proof;entries=@([pscustomobject]@{kind='StartMenu';path='test';sha256=('c'*64)},[pscustomobject]@{kind='Desktop';path='test';sha256=('b'*64)},[pscustomobject]@{kind='Registry';path='test'})}
        function Get-CcodInstalledLifecycleProductState {param($RuntimeId)return $state}
        Assert-CcodTrue (Test-CcodInstalledLifecycleCandidateFileSet -Actual $records -Expected $payload -InstallRoot $root -RuntimeId $runtimeId -Generation 8 -ManifestSha256 ('9'*64)) 'candidate comparison accepts shipped payload plus independently bound generated shortcuts'
        $state.readyEvidence.desktopSha256='f'*64
        Assert-CcodEqual $false (Test-CcodInstalledLifecycleCandidateFileSet -Actual $records -Expected $payload -InstallRoot $root -RuntimeId $runtimeId -Generation 8 -ManifestSha256 ('9'*64)) 'mismatched registered shortcut hash is rejected'
        $state.readyEvidence.desktopSha256='b'*64
        $records+=@([pscustomobject][ordered]@{path='unexpected.txt';length=[long]1;sha256=('1'*64)})
        Assert-CcodEqual $false (Test-CcodInstalledLifecycleCandidateFileSet -Actual $records -Expected $payload -InstallRoot $root -RuntimeId $runtimeId -Generation 8 -ManifestSha256 ('9'*64)) 'unknown extra payload file is never ignored'
    } finally {if($null-ne$original){Set-Item Function:Get-CcodInstalledLifecycleProductState $original}else{Remove-Item Function:Get-CcodInstalledLifecycleProductState -ErrorAction SilentlyContinue}}
}

Invoke-CcodTest 'installed runtime validator agrees with the actual manifest producer digest' {
    . $harnessPath -Library
    $module=Import-Module (Join-Path $repositoryRoot 'src/persistence/modules/RuntimeManifest.psm1') -PassThru -Force
    $root=Join-Path (Get-CcodTestCanonicalTempRoot) ('ccod-producer-digest-'+[guid]::NewGuid().ToString('N'))
    try {
        [IO.Directory]::CreateDirectory($root)|Out-Null
        [IO.File]::WriteAllText((Join-Path $root 'payload.txt'),'actual producer fixture')
        $manifest=&$module {param($Root)New-CcodRuntimeManifest -RuntimeDirectory $Root -ProjectVersion '2.5.22'} $root
        $actual=Assert-CcodInstalledLifecycleRuntimeManifest -Manifest $manifest -ExpectedVersion '2.5.22' -ExpectedRuntimeId $manifest.runtimeId -RuntimeRoot $root
        Assert-CcodEqual $manifest.runtimeId $actual.runtimeId 'real producer and installed validator agree on nonempty records'
        $legacyCanonical=@($manifest.files|ForEach-Object {'{0}`t{1}`t{2}' -f [string]$_.path,[int64]$_.length,[string]$_.sha256})-join "`n"
        $legacySha=[Security.Cryptography.SHA256]::Create();try{$legacyDigest=[BitConverter]::ToString($legacySha.ComputeHash([Text.Encoding]::UTF8.GetBytes($legacyCanonical))).Replace('-','').ToLowerInvariant()}finally{$legacySha.Dispose()}
        $legacy=[pscustomobject][ordered]@{schemaVersion=1;projectVersion='2.5.21';runtimeId=('2.5.21-'+$legacyDigest.Substring(0,16));files=@($manifest.files)}
        Assert-CcodEqual $legacy.runtimeId (Assert-CcodInstalledLifecycleRuntimeManifest -Manifest $legacy -ExpectedVersion '2.5.21' -ExpectedRuntimeId $legacy.runtimeId -RuntimeRoot $root).runtimeId 'historical digest grammar stays identical without the nonce'
        [IO.File]::WriteAllText((Join-Path $root 'payload.txt'),'changed producer fixture')
        Assert-CcodThrows {Assert-CcodInstalledLifecycleRuntimeManifest -Manifest $manifest -ExpectedVersion '2.5.22' -ExpectedRuntimeId $manifest.runtimeId -RuntimeRoot $root|Out-Null} 'CCOD_INTEGRATION_OBSERVATION_UNAVAILABLE'
    } finally {if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}}
}

Invoke-CcodTest 'installed runtime ordering matches mixed-case producer paths across cultures' {
    . $harnessPath -Library
    $module=Import-Module (Join-Path $repositoryRoot 'src/persistence/modules/RuntimeManifest.psm1') -PassThru -Force
    $root=Join-Path (Get-CcodTestCanonicalTempRoot) ('ccod-producer-order-'+[guid]::NewGuid().ToString('N'))
    $originalCulture=[Threading.Thread]::CurrentThread.CurrentCulture
    try {
        [IO.Directory]::CreateDirectory((Join-Path $root 'bin'))|Out-Null
        foreach($relative in @('Uninstall-CodexControlOtherDevices.ps1','package.json','bin/CodexRemote.txt')){
            [IO.File]::WriteAllText((Join-Path $root $relative),'inert producer ordering fixture')
        }
        foreach($culture in @('en-US','zh-CN','tr-TR')){
            [Threading.Thread]::CurrentThread.CurrentCulture=[Globalization.CultureInfo]::GetCultureInfo($culture)
            $manifest=&$module {param($Root)New-CcodRuntimeManifest -RuntimeDirectory $Root -ProjectVersion '2.5.22'} $root
            Assert-CcodEqual 'Uninstall-CodexControlOtherDevices.ps1|bin/CodexRemote.txt|package.json' (@($manifest.files|ForEach-Object{$_.path})-join'|') 'producer uses ordinal path order'
            $actual=Assert-CcodInstalledLifecycleRuntimeManifest -Manifest $manifest -ExpectedVersion '2.5.22' -ExpectedRuntimeId $manifest.runtimeId -RuntimeRoot $root
            Assert-CcodEqual $manifest.runtimeId $actual.runtimeId ('current mixed-case producer accepts under '+$culture)
            $legacyCanonical=@($manifest.files|ForEach-Object {'{0}`t{1}`t{2}' -f [string]$_.path,[int64]$_.length,[string]$_.sha256})-join "`n"
            $legacySha=[Security.Cryptography.SHA256]::Create();try{$legacyDigest=[BitConverter]::ToString($legacySha.ComputeHash([Text.Encoding]::UTF8.GetBytes($legacyCanonical))).Replace('-','').ToLowerInvariant()}finally{$legacySha.Dispose()}
            $legacy=[pscustomobject][ordered]@{schemaVersion=1;projectVersion='2.5.21';runtimeId=('2.5.21-'+$legacyDigest.Substring(0,16));files=@($manifest.files)}
            Assert-CcodEqual $legacy.runtimeId (Assert-CcodInstalledLifecycleRuntimeManifest -Manifest $legacy -ExpectedVersion '2.5.21' -ExpectedRuntimeId $legacy.runtimeId -RuntimeRoot $root).runtimeId ('legacy mixed-case producer accepts under '+$culture)
        }
        $reordered=$manifest.PSObject.Copy();$reordered.files=@($manifest.files[2],$manifest.files[1],$manifest.files[0])
        Assert-CcodThrows {Assert-CcodInstalledLifecycleRuntimeManifest -Manifest $reordered -ExpectedVersion '2.5.22' -ExpectedRuntimeId $manifest.runtimeId -RuntimeRoot $root|Out-Null} 'CCOD_INTEGRATION_OBSERVATION_UNAVAILABLE'
        [IO.File]::WriteAllText((Join-Path $root 'extra.txt'),'undeclared')
        Assert-CcodThrows {Assert-CcodInstalledLifecycleRuntimeManifest -Manifest $manifest -ExpectedVersion '2.5.22' -ExpectedRuntimeId $manifest.runtimeId -RuntimeRoot $root|Out-Null} 'CCOD_INTEGRATION_OBSERVATION_UNAVAILABLE'
    } finally {
        [Threading.Thread]::CurrentThread.CurrentCulture=$originalCulture
        if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}
    }
}

Invoke-CcodTest 'sealed runtime metadata does not depend on the obsolete Inno directory' {
    . $harnessPath -Library
    $root=Join-Path (Get-CcodTestCanonicalTempRoot) ('ccod-modern-app-'+[guid]::NewGuid().ToString('N'))
    $originalManifest=${function:Assert-CcodInstalledLifecycleRuntimeManifest}
    $originalOptional=${function:Get-CcodInstalledLifecycleOptionalDirectoryState};$previousHome=$env:CODEX_HOME
    try {
        [IO.Directory]::CreateDirectory($root)|Out-Null;$env:CODEX_HOME=Join-Path $root 'keys'
        $runtimeId='2.5.22-e3b0c44298fc1c14-'+('a'*32)
        New-CcodHarnessInstalledStateFixture -Root $root -ActiveRuntimeId $runtimeId -ActiveGeneration 8 -StatusRuntimeId $runtimeId -StatusCodexPid 702 -StatusCodexCreationTimeUtc '2026-08-24T00:00:02.0000000Z' -ReceiptPhase Completed
        $runtime=Join-Path $root ('runtime\'+$runtimeId)
        [IO.File]::WriteAllText((Join-Path $runtime 'package.json'),'{"version":"2.5.22"}')
        $manifest=[IO.File]::ReadAllText((Join-Path $runtime 'manifest.json'))|ConvertFrom-Json;$manifest.projectVersion='2.5.22'
        $manifest.files=@([pscustomobject][ordered]@{path='package.json';length=[long](Get-Item (Join-Path $runtime 'package.json')).Length;sha256=Get-CcodTestFileSha256 (Join-Path $runtime 'package.json')})
        Write-CcodHarnessJson (Join-Path $runtime 'manifest.json') $manifest
        Set-CcodHarnessProcessFixture -ChatGPT @()
        function Get-CcodInstalledLifecycleOptionalDirectoryState {param($Path,$GetItem)if($Path.EndsWith('CodexControlOtherDevices-installer')){return $false};return &$originalOptional -Path $Path -GetItem $GetItem}
        function Assert-CcodInstalledLifecycleRuntimeManifest {param($Manifest,$ExpectedVersion,$ExpectedRuntimeId,$RuntimeRoot)return $Manifest}
        $facts=Get-CcodInstalledLifecycleFacts -InstallRoot $root -ExpectedVersion '2.5.22'
        Assert-CcodTrue $facts.appPresent 'sealed runtime is the installed application'
        Assert-CcodEqual '2.5.22' $facts.aboutVersion 'version comes from the active runtime package'
        Assert-CcodTrue $facts.installReady 'absence of the obsolete Inno directory does not reject sealed metadata'
        Assert-CcodTrue (-not$facts.protectionReady) 'metadata alone does not prove protection readiness'
    } finally {
        Set-Item Function:Assert-CcodInstalledLifecycleRuntimeManifest $originalManifest
        Set-Item Function:Get-CcodInstalledLifecycleOptionalDirectoryState $originalOptional
        Clear-CcodHarnessProcessFixture
        if($null-eq$previousHome){Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue}else{$env:CODEX_HOME=$previousHome}
        if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}
    }
}

Invoke-CcodTest 'native CIM timestamps are preserved for installed supervisor and tray' {
    . $harnessPath -Library
    $root = Join-Path (Get-CcodTestCanonicalTempRoot) ('ccod-installed-native-cim-' + [guid]::NewGuid().ToString('N'))
    $hadCodexHome = Test-Path -LiteralPath Env:CODEX_HOME
    $previousCodexHome = $env:CODEX_HOME
    try {
        [IO.Directory]::CreateDirectory($root) | Out-Null
        $env:CODEX_HOME = Join-Path $root 'keys'
        $created = [datetime]::ParseExact('2026-08-24T00:00:00.0000000Z', 'o', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
        $supervisorProcess = New-CcodHarnessCimProcess -Name 'powershell.exe' -ProcessId 700 -CreationTimeUtc $created.ToString('o') -CommandLine ('powershell.exe -File "{0}"' -f (Join-Path $root 'Supervisor.ps1'))
        $trayProcess = New-CcodHarnessCimProcess -Name 'CodexRemote.TrayHost.exe' -ProcessId 701 -CreationTimeUtc $created.AddSeconds(1).ToString('o') -CommandLine 'CodexRemote.TrayHost.exe'
        $trayProcess.ExecutablePath = Join-Path $root 'bin\CodexRemote.TrayHost.exe'
        Set-CcodHarnessProcessFixture -ChatGPT @()
        $global:CcodInstalledLifecycleNativeCimFixture = @($supervisorProcess,$trayProcess)
        function global:Get-CimInstance {
            param($ClassName,$Filter,$ErrorAction)
            return @($global:CcodInstalledLifecycleNativeCimFixture | Where-Object { $Filter -ceq ("Name = '{0}'" -f $_.Name) })
        }
        $legacy = Get-CcodInstalledLifecycleFacts -InstallRoot $root
        Assert-CcodEqual 1 $legacy.supervisor.Count 'DMTF supervisor baseline is observed'
        Assert-CcodEqual 1 $legacy.trayHost.Count 'DMTF tray baseline is observed'
        Assert-CcodEqual $created.ToString('o') $legacy.supervisor[0].CreationTimeUtc 'DMTF supervisor time is canonical UTC'
        Assert-CcodEqual $created.AddSeconds(1).ToString('o') $legacy.trayHost[0].CreationTimeUtc 'DMTF tray time is canonical UTC'
        $supervisorProcess.CreationDate = $created
        $trayProcess.CreationDate = $created.AddSeconds(1)
        Assert-CcodTrue ($supervisorProcess.CreationDate -is [datetime] -and $trayProcess.CreationDate -is [datetime]) 'native CIM DateTime values reach the real collector'
        $native = Get-CcodInstalledLifecycleFacts -InstallRoot $root
        Assert-CcodEqual 1 $native.supervisor.Count 'native supervisor is observed'
        Assert-CcodEqual 1 $native.trayHost.Count 'native tray is observed'
        Assert-CcodEqual $created.ToString('o') $native.supervisor[0].CreationTimeUtc 'native supervisor creation identity is preserved'
        Assert-CcodEqual $created.AddSeconds(1).ToString('o') $native.trayHost[0].CreationTimeUtc 'native tray creation identity is preserved'
        $supervisorProcess.CreationDate = 'not-a-cim-timestamp'
        Assert-CcodThrows { Get-CcodInstalledLifecycleFacts -InstallRoot $root } 'CCOD_INTEGRATION_OBSERVATION_UNAVAILABLE'
    } finally {
        Clear-CcodHarnessProcessFixture
        Remove-Variable -Name CcodInstalledLifecycleNativeCimFixture -Scope Global -ErrorAction SilentlyContinue
        if ($hadCodexHome) { $env:CODEX_HOME = $previousCodexHome } else { Remove-Item -LiteralPath Env:CODEX_HOME -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

Invoke-CcodTest 'process precision correlation retains exact native time and rejects cross-microsecond identity' {
    . $harnessPath -Library
    $original=${function:Get-CcodInstalledLifecycleNativeProcessCreationTimeUtc}
    try {
        $cim=[datetime]::ParseExact('2026-08-24T00:00:04.0000000Z','o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
        $process=[pscustomobject]@{ProcessId=[uint32]13948;CreationDate=$cim}
        $state=[pscustomobject]@{Native=$cim.ToString('o');Fail=$false;Calls=0}
        function Get-CcodInstalledLifecycleNativeProcessCreationTimeUtc {param($ProcessId)$state.Calls++;if($state.Fail){throw 'native query denied'};return $state.Native}
        foreach($delta in @(0,6,9)){
            $state.Native=$cim.AddTicks($delta).ToString('o')
            Assert-CcodEqual $state.Native (Get-CcodInstalledLifecycleCorrelatedCreationTimeUtc -Process $process) 'only CIM precision is correlated; full native ticks remain exact'
        }
        foreach($delta in @(-1,10)){
            $state.Native=$cim.AddTicks($delta).ToString('o')
            Assert-CcodThrows {Get-CcodInstalledLifecycleCorrelatedCreationTimeUtc -Process $process|Out-Null} 'CCOD_INTEGRATION_OBSERVATION_UNAVAILABLE'
        }
        $process.CreationDate=$cim.AddTicks(6);$state.Native=$process.CreationDate.ToString('o')
        Assert-CcodEqual $state.Native (Get-CcodInstalledLifecycleCorrelatedCreationTimeUtc -Process $process) 'already precise observation must equal native identity'
        $state.Native=$cim.AddTicks(7).ToString('o')
        Assert-CcodThrows {Get-CcodInstalledLifecycleCorrelatedCreationTimeUtc -Process $process|Out-Null} 'CCOD_INTEGRATION_OBSERVATION_UNAVAILABLE'
        $state.Fail=$true
        Assert-CcodThrows {Get-CcodInstalledLifecycleCorrelatedCreationTimeUtc -Process $process|Out-Null} 'CCOD_INTEGRATION_OBSERVATION_UNAVAILABLE'
        $state.Fail=$false;$state.Native=$null
        Assert-CcodThrows {Get-CcodInstalledLifecycleCorrelatedCreationTimeUtc -Process $process|Out-Null} 'CCOD_INTEGRATION_OBSERVATION_UNAVAILABLE'
        Assert-CcodTrue ($state.Calls-ge9) 'each boundary reaches native observation'
    } finally {Set-Item Function:Get-CcodInstalledLifecycleNativeProcessCreationTimeUtc $original}
}

Invoke-CcodTest 'actual local process retains native precision through CIM correlation' {
    . $harnessPath -Library
    $current=[Diagnostics.Process]::GetCurrentProcess()
    try {
        $cim=CimCmdlets\Get-CimInstance -ClassName Win32_Process -Filter ('ProcessId = '+$current.Id) -ErrorAction Stop
        $exact=$current.StartTime.ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture)
        Assert-CcodEqual $exact (Get-CcodInstalledLifecycleNativeProcessCreationTimeUtc -ProcessId $current.Id) 'real native read retains all ticks'
        Assert-CcodEqual $exact (Get-CcodInstalledLifecycleCorrelatedCreationTimeUtc -Process $cim) 'real current process correlates without replacing exact native identity'
    } finally {$current.Dispose()}
}

Invoke-CcodTest 'installed tray observation selects active runtime bin rather than top-level decoy' {
    . $harnessPath -Library
    $root=Join-Path (Get-CcodTestCanonicalTempRoot) ('ccod-tray-runtime-path-'+[guid]::NewGuid().ToString('N'))
    $previousHome=$env:CODEX_HOME
    try {
        [IO.Directory]::CreateDirectory($root)|Out-Null
        $env:CODEX_HOME=Join-Path $root 'keys'
        $runtimeId='2.5.21-e3b0c44298fc1c14'
        New-CcodHarnessInstalledStateFixture -Root $root -ActiveRuntimeId $runtimeId -ActiveGeneration 8 -StatusRuntimeId $runtimeId -StatusCodexPid 702 -StatusCodexCreationTimeUtc '2026-08-24T00:00:02.0000000Z' -ReceiptPhase Completed
        $actual=New-CcodHarnessCimProcess -Name 'CodexRemote.TrayHost.exe' -ProcessId 701 -CreationTimeUtc '2026-08-24T00:00:01.0000000Z' -CommandLine 'CodexRemote.TrayHost.exe'
        $actual.ExecutablePath=Join-Path $root ('runtime\'+$runtimeId+'\bin\CodexRemote.TrayHost.exe')
        $decoy=New-CcodHarnessCimProcess -Name 'CodexRemote.TrayHost.exe' -ProcessId 799 -CreationTimeUtc '2026-08-24T00:00:01.0000000Z' -CommandLine 'CodexRemote.TrayHost.exe'
        $decoy.ExecutablePath=Join-Path $root 'bin\CodexRemote.TrayHost.exe'
        Set-CcodHarnessProcessFixture -ChatGPT @()
        $global:CcodRuntimePathProcesses=@($actual,$decoy)
        function global:Get-CimInstance {param($ClassName,$Filter,$ErrorAction)return @($global:CcodRuntimePathProcesses|Where-Object {$Filter-ceq("Name = '{0}'"-f$_.Name)})}
        $originalReady=${function:Get-CcodInstalledLifecycleTrayHostReadyProof}
        function Get-CcodInstalledLifecycleTrayHostReadyProof {param($InstallRoot,$RuntimeId,$TrayHost)return $false}
        $facts=Get-CcodInstalledLifecycleFacts -InstallRoot $root
        Assert-CcodEqual 1 $facts.trayHost.Count 'only the current runtime tray is selected'
        Assert-CcodEqual 701 $facts.trayHost[0].Pid 'top-level executable is not the active TrayHost'
    } finally {
        if($null-ne$originalReady){Set-Item Function:Get-CcodInstalledLifecycleTrayHostReadyProof $originalReady}
        Clear-CcodHarnessProcessFixture
        Remove-Variable CcodRuntimePathProcesses -Scope Global -ErrorAction SilentlyContinue
        if($null-eq$previousHome){Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue}else{$env:CODEX_HOME=$previousHome}
        if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}
    }
}

Invoke-CcodTest 'legacy readiness uses protected event and exact current process identities without new logs' {
    . $harnessPath -Library
    $root=Join-Path (Get-CcodTestCanonicalTempRoot) ('ccod-legacy-ready-'+[guid]::NewGuid().ToString('N'))
    $kernel=Import-Module (Join-Path $repositoryRoot 'src/persistence/modules/KernelObjects.psm1') -PassThru -Force
    $event=$null
    $originalNative=${function:Get-CcodInstalledLifecycleNativeProcessCreationTimeUtc}
    try {
        function Get-CcodInstalledLifecycleNativeProcessCreationTimeUtc {param($ProcessId)return $script:CcodHarnessNativeCreation[[int]$ProcessId]}
        $utf8=[Text.UTF8Encoding]::new($false)
        $records=[Collections.Generic.List[object]]::new()
        foreach($relative in @('bin/CodexRemote.TrayHost.exe','src/persistence/Supervisor.ps1')){
            $bytes=$utf8.GetBytes('inert legacy '+$relative);$sha=[Security.Cryptography.SHA256]::Create()
            try{$hash=[BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
            $records.Add([pscustomobject][ordered]@{path=$relative;length=[long]$bytes.Length;sha256=$hash})
        }
        $canonical=(@($records|ForEach-Object {'{0}`t{1}`t{2}' -f $_.path,$_.length,$_.sha256})-join"`n")
        $sha=[Security.Cryptography.SHA256]::Create();try{$digest=[BitConverter]::ToString($sha.ComputeHash($utf8.GetBytes($canonical))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
        $runtimeId='2.5.21-'+$digest.Substring(0,16)
        New-CcodHarnessInstalledStateFixture -Root $root -ActiveRuntimeId $runtimeId -ActiveGeneration 8 -StatusRuntimeId $runtimeId -StatusCodexPid 702 -StatusCodexCreationTimeUtc '2026-08-24T00:00:02.0000000Z' -ReceiptPhase Completed
        $runtime=Join-Path $root ('runtime\'+$runtimeId)
        foreach($record in $records){$path=Join-Path $runtime $record.path;[IO.Directory]::CreateDirectory((Split-Path $path -Parent))|Out-Null;[IO.File]::WriteAllText($path,('inert legacy '+$record.path),$utf8)}
        Write-CcodHarnessJson -Path (Join-Path $runtime 'manifest.json') -Value ([ordered]@{schemaVersion=1;projectVersion='2.5.21';runtimeId=$runtimeId;files=@($records)})
        $current=[Diagnostics.Process]::GetCurrentProcess();try{$session=$current.SessionId}finally{$current.Dispose()}
        $windowsIdentity=[Security.Principal.WindowsIdentity]::GetCurrent();try{$sid=$windowsIdentity.User.Value}finally{$windowsIdentity.Dispose()}
        $token=[guid]::NewGuid().ToString('N')+[guid]::NewGuid().ToString('N')
        $event=&$kernel {param($Sid,$Session,$Token)New-CcodEvent -Kind Ready -UserSid $Sid -SessionId $Session -ReadyToken $Token} $sid $session $token
        $powershell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $created=[datetime]::ParseExact('2026-08-24T00:00:00.0000006Z','o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
        $supervisor=New-CcodHarnessCimProcess -Name 'powershell.exe' -ProcessId 700 -CreationTimeUtc $created.ToString('o') -CommandLine ('"{0}" -NoProfile -ExecutionPolicy Bypass -STA -File "{1}" -ReadyToken {2}'-f$powershell,(Join-Path $runtime 'src/persistence/Supervisor.ps1'),$token)
        $supervisor.ExecutablePath=$powershell;$supervisor|Add-Member SessionId $session
        $trayPath=Join-Path $runtime 'bin/CodexRemote.TrayHost.exe'
        $tray=New-CcodHarnessCimProcess -Name 'CodexRemote.TrayHost.exe' -ProcessId 701 -ParentProcessId 700 -CreationTimeUtc $created.AddSeconds(1).ToString('o') -CommandLine ('"{0}" --child --parent-pid 700 --parent-created {1} --runtime-id {2}'-f$trayPath,$created.ToFileTimeUtc(),$runtimeId)
        $tray.ExecutablePath=$trayPath;$tray|Add-Member SessionId $session
        $statusPath=Join-Path $root 'state/status.json';$status=[IO.File]::ReadAllText($statusPath)|ConvertFrom-Json;$status.session.supervisorCreationTimeUtc=$created.ToString('o');$status.session.sessionId=$session.ToString([Globalization.CultureInfo]::InvariantCulture);Write-CcodHarnessJson $statusPath $status
        $supervisorIdentity=@([pscustomobject]@{Pid=700;CreationTimeUtc=$created.ToString('o')});$trayIdentity=@([pscustomobject]@{Pid=701;CreationTimeUtc=$created.AddSeconds(1).ToString('o')})
        $global:CcodLegacyReadyFixture=[pscustomobject]@{Processes=@($supervisor,$tray);Calls=0;Drift=$false}
        function global:Get-CimInstance {param($ClassName,$Filter,$ErrorAction)$global:CcodLegacyReadyFixture.Calls++;$items=@($global:CcodLegacyReadyFixture.Processes|Where-Object {$Filter-ceq('ProcessId = '+$_.ProcessId)});if($global:CcodLegacyReadyFixture.Drift-and$global:CcodLegacyReadyFixture.Calls-ge3){return @()};return $items}
        Assert-CcodEqual $false (Get-CcodInstalledLifecycleTrayHostReadyProof -InstallRoot $root -RuntimeId $runtimeId -TrayHost $trayIdentity) 'absent newer log does not prove old readiness'
        [void]$event.Handle.Set()
        Assert-CcodTrue (Get-CcodInstalledLifecycleTrayHostReadyProof -InstallRoot $root -RuntimeId $runtimeId -TrayHost $trayIdentity) 'protected legacy startup event proves the current parent and host without a log'
        [void]$event.Handle.Reset()
        Assert-CcodEqual $false (Get-CcodInstalledLifecycleLegacyTrayReadyProof -InstallRoot $root -RuntimeId $runtimeId -Supervisor $supervisorIdentity -TrayHost $trayIdentity) 'unsignaled event does not prove readiness'
        [void]$event.Handle.Set()
        Assert-CcodTrue (-not(Test-Path -LiteralPath (Join-Path $root 'logs/supervisor.log'))) 'no fabricated newer Ready log is written'
        $tray.ParentProcessId=799
        Assert-CcodThrows {Get-CcodInstalledLifecycleLegacyTrayReadyProof -InstallRoot $root -RuntimeId $runtimeId -Supervisor $supervisorIdentity -TrayHost $trayIdentity|Out-Null} 'CCOD_INTEGRATION_OBSERVATION_UNAVAILABLE'
        $tray.ParentProcessId=700
        $status.session.supervisorCreationTimeUtc=$created.AddSeconds(-1).ToString('o');Write-CcodHarnessJson $statusPath $status
        Assert-CcodThrows {Get-CcodInstalledLifecycleLegacyTrayReadyProof -InstallRoot $root -RuntimeId $runtimeId -Supervisor $supervisorIdentity -TrayHost $trayIdentity|Out-Null} 'CCOD_INTEGRATION_OBSERVATION_UNAVAILABLE'
        $status.session.supervisorCreationTimeUtc=$created.ToString('o');Write-CcodHarnessJson $statusPath $status
        $global:CcodLegacyReadyFixture.Calls=0;$global:CcodLegacyReadyFixture.Drift=$true
        Assert-CcodThrows {Get-CcodInstalledLifecycleLegacyTrayReadyProof -InstallRoot $root -RuntimeId $runtimeId -Supervisor $supervisorIdentity -TrayHost $trayIdentity|Out-Null} 'CCOD_INTEGRATION_OBSERVATION_UNAVAILABLE'
        $global:CcodLegacyReadyFixture.Drift=$false
        Assert-CcodThrows {Get-CcodInstalledLifecycleLegacyTrayReadyProof -InstallRoot $root -RuntimeId ($runtimeId+'-'+('a'*32)) -Supervisor $supervisorIdentity -TrayHost $trayIdentity|Out-Null} 'CCOD_INTEGRATION_OBSERVATION_UNAVAILABLE'
        Assert-CcodTrue (Get-CcodInstalledLifecycleLegacyTrayReadyProof -InstallRoot $root -RuntimeId $runtimeId -Supervisor $supervisorIdentity -TrayHost $trayIdentity) 'failure releases event and module leases for retry'
    } finally {
        if($null-ne$event){$event.Handle.Dispose()}
        Set-Item Function:Get-CcodInstalledLifecycleNativeProcessCreationTimeUtc $originalNative
        Remove-Item Function:\Get-CimInstance -ErrorAction SilentlyContinue
        Remove-Variable CcodLegacyReadyFixture -Scope Global -ErrorAction SilentlyContinue
        if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}
    }
}

Invoke-CcodTest 'installed readiness selects current Ready across valid supervisor history' {
    . $harnessPath -Library
    $root = Join-Path (Get-CcodTestCanonicalTempRoot) ('ccod-installed-ready-history-' + [guid]::NewGuid().ToString('N'))
    try {
        [IO.Directory]::CreateDirectory((Join-Path $root 'logs')) | Out-Null
        $log = Join-Path $root 'logs\supervisor.log'
        $current = [ordered]@{ schemaVersion = 1; timestampUtc = '2030-02-03T04:05:07.0000000Z'; component = 'Supervisor'; stage = 'TrayHostReady'; code = 'CCOD_TRAYHOST_READY'; outcome = 'Completed'; runtimeId = 'runtime-2.5.22'; hostPid = 201; hostCreationTimeUtc = '2030-02-03T04:05:01.0000000Z'; protocolMajor = 2; capabilities = 7 }
        $hosts = @([pscustomobject][ordered]@{ Pid = 201; CreationTimeUtc = $current.hostCreationTimeUtc })
        [IO.File]::WriteAllText($log, (($current | ConvertTo-Json -Compress) + [Environment]::NewLine))
        Assert-CcodTrue (Get-CcodInstalledLifecycleTrayHostReadyProof -InstallRoot $root -RuntimeId 'runtime-2.5.22' -TrayHost $hosts) 'a current Ready record proves the baseline'
        $historical = [ordered]@{}
        foreach ($key in $current.Keys) { $historical[$key] = $current[$key] }
        $historical.runtimeId = 'runtime-2.5.21'
        $action = [ordered]@{ schemaVersion = 1; timestampUtc = $current.timestampUtc; component = 'Supervisor'; stage = 'TrayAction'; code = 'CCOD_TRAY_ACTION_COMPLETED'; outcome = 'Completed'; command = 'ShowAbout'; revision = 1; status = 'Completed' }
        $warning = [ordered]@{ schemaVersion = 1; timestampUtc = $current.timestampUtc; component = 'Supervisor'; stage = 'LeaseAcquire'; code = 'CCOD_SUPERVISOR_LEASE_ABANDONED'; outcome = 'Warning' }
        $history = @($action,$historical,$warning)
        [IO.File]::WriteAllText($log, ((@($history + @($current) | ForEach-Object { $_ | ConvertTo-Json -Compress }) -join [Environment]::NewLine) + [Environment]::NewLine))
        Assert-CcodTrue (Get-CcodInstalledLifecycleTrayHostReadyProof -InstallRoot $root -RuntimeId 'runtime-2.5.22' -TrayHost $hosts) 'well-formed action and old runtime records do not invalidate current Ready'
        [IO.File]::WriteAllText($log, ((@($history | ForEach-Object { $_ | ConvertTo-Json -Compress }) -join [Environment]::NewLine) + [Environment]::NewLine))
        Assert-CcodEqual $false (Get-CcodInstalledLifecycleTrayHostReadyProof -InstallRoot $root -RuntimeId 'runtime-2.5.22' -TrayHost $hosts) 'historical runtime cannot prove readiness even with matching process identity'
        $current.hostPid = '201'
        [IO.File]::WriteAllText($log, ((@($history + @($current) | ForEach-Object { $_ | ConvertTo-Json -Compress }) -join [Environment]::NewLine) + [Environment]::NewLine))
        Assert-CcodThrows { Get-CcodInstalledLifecycleTrayHostReadyProof -InstallRoot $root -RuntimeId 'runtime-2.5.22' -TrayHost $hosts } 'CCOD_INTEGRATION_OBSERVATION_UNAVAILABLE'
        $current.hostPid = 201
        $action.status = @('Completed')
        [IO.File]::WriteAllText($log, ((@($action,$current | ForEach-Object { $_ | ConvertTo-Json -Depth 4 -Compress }) -join [Environment]::NewLine) + [Environment]::NewLine))
        Assert-CcodThrows { Get-CcodInstalledLifecycleTrayHostReadyProof -InstallRoot $root -RuntimeId 'runtime-2.5.22' -TrayHost $hosts } 'CCOD_INTEGRATION_OBSERVATION_UNAVAILABLE'
    } finally {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

Invoke-CcodTest 'expected debug ports survive the installed lifecycle facts boundary' {
    . $harnessPath -Library
    $root = Join-Path (Get-CcodTestCanonicalTempRoot) ('ccod-installed-expected-ports-' + [guid]::NewGuid().ToString('N'))
    $originalNetTcp = ${function:Get-NetTCPConnection}
    $originalDirectoryProbe = ${function:Get-CcodInstalledLifecycleOptionalDirectoryState}
    $originalFileProbe = ${function:Get-CcodInstalledLifecycleOptionalRegularFileState}
    $fixtureAbsentApplicationRoot = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'CodexControlOtherDevices-installer'
    $fixtureApplicationProbes = [pscustomobject]@{ Directory = 0; Metadata = 0 }
    try {
        function Get-CcodInstalledLifecycleOptionalDirectoryState {
            param($Path,$GetItem)
            if ($Path -ieq $fixtureAbsentApplicationRoot) { $fixtureApplicationProbes.Directory++; return $false }
            & $originalDirectoryProbe -Path $Path -GetItem $GetItem
        }
        function Get-CcodInstalledLifecycleOptionalRegularFileState {
            param($Path,$GetItem)
            if ($Path -ieq (Join-Path $fixtureAbsentApplicationRoot 'package.json')) { $fixtureApplicationProbes.Metadata++; return $null }
            & $originalFileProbe -Path $Path -GetItem $GetItem
        }
        [IO.Directory]::CreateDirectory($root) | Out-Null
        New-CcodHarnessInstalledStateFixture -Root $root -ActiveRuntimeId '2.5.21-e3b0c44298fc1c14' -ActiveGeneration ([UInt64]8) `
            -StatusRuntimeId '2.5.21-e3b0c44298fc1c14' -StatusCodexPid 13948 -StatusCodexCreationTimeUtc '2026-08-24T00:00:02.0000000Z' -ReceiptPhase 'Completed' -StatusMainPort 9229 -StatusRendererPort 9230
        Set-CcodHarnessProcessFixture -ChatGPT @(
            (New-CcodHarnessCimProcess -Name 'ChatGPT.exe' -ProcessId 13948 -CreationTimeUtc '2026-08-24T00:00:02.0000000Z' -CommandLine '"C:\Program Files\WindowsApps\OpenAI.Codex\ChatGPT.exe"')
        )
        function global:Get-NetTCPConnection {
            param($State,$ErrorAction)
            return @(
                [pscustomobject]@{ LocalAddress = '127.0.0.1'; LocalPort = 9229; OwningProcess = 13948 }
                [pscustomobject]@{ LocalAddress = '127.0.0.1'; LocalPort = 9230; OwningProcess = 13948 }
            )
        }
        $facts = Get-CcodInstalledLifecycleFacts -InstallRoot $root -ExpectedDebugPorts @(9229,9230)
        Assert-CcodEqual '9229,9230' ($facts.debugPorts -join ',') 'expected debug ports are preserved for listener verification'
        Assert-CcodEqual $false $facts.appPresent 'port observation does not depend on a machine installation'
        Assert-CcodEqual $null $facts.aboutVersion 'port fixture has no installed application metadata'
        Assert-CcodTrue ($fixtureApplicationProbes.Directory -gt 0 -and $fixtureApplicationProbes.Metadata -gt 0) 'real application path lookups are isolated by the fixture'
        $legacyFacts = Get-CcodInstalledLifecycleFacts -InstallRoot $root
        Assert-CcodTrue ($null -ne $legacyFacts -and $legacyFacts.activeRuntimeId -is [string]) 'legacy two-part runtime identity can be observed without an expected version'
    } finally {
        Set-Item -LiteralPath Function:\Get-CcodInstalledLifecycleOptionalDirectoryState -Value $originalDirectoryProbe
        Set-Item -LiteralPath Function:\Get-CcodInstalledLifecycleOptionalRegularFileState -Value $originalFileProbe
        Clear-CcodHarnessProcessFixture
        if ($null -eq $originalNetTcp) { Remove-Item -LiteralPath Function:\Get-NetTCPConnection -Force -ErrorAction SilentlyContinue }
        else { Set-Item -LiteralPath Function:\Get-NetTCPConnection -Value $originalNetTcp }
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

Invoke-CcodTest 'rejects non-integer debug port facts before endpoint observation' {
    . $harnessPath -Library
    $root = Join-Path (Get-CcodTestCanonicalTempRoot) ('ccod-installed-noninteger-port-' + [guid]::NewGuid().ToString('N'))
    $originalNetTcp = ${function:Get-NetTCPConnection}
    $originalStatusReader = ${function:Read-CcodInstalledLifecycleStatusFact}
    try {
        [IO.Directory]::CreateDirectory($root) | Out-Null
        New-CcodHarnessInstalledStateFixture -Root $root -ActiveRuntimeId '2.5.21-e3b0c44298fc1c14' -ActiveGeneration ([UInt64]8) `
            -StatusRuntimeId '2.5.21-e3b0c44298fc1c14' -StatusCodexPid 13948 -StatusCodexCreationTimeUtc '2026-08-24T00:00:02.0000000Z' -ReceiptPhase 'Completed' -StatusMainPort 9229 -StatusRendererPort 9230
        $statusOverride = Get-Content -LiteralPath (Join-Path $root 'state\status.json') -Raw | ConvertFrom-Json
        $global:CcodInstalledLifecycleNonIntegerStatusOverride = $statusOverride
        Set-Item -LiteralPath Function:\Read-CcodInstalledLifecycleStatusFact -Value { param($StateRoot) return $global:CcodInstalledLifecycleNonIntegerStatusOverride }
        Set-CcodHarnessProcessFixture -ChatGPT @(
            (New-CcodHarnessCimProcess -Name 'ChatGPT.exe' -ProcessId 13948 -CreationTimeUtc '2026-08-24T00:00:02.0000000Z' -CommandLine '"C:\Program Files\WindowsApps\OpenAI.Codex\ChatGPT.exe"')
        )
        function global:Get-NetTCPConnection {
            param($State,$ErrorAction)
            return @(
                [pscustomobject]@{ LocalAddress = '127.0.0.1'; LocalPort = 9229; OwningProcess = 13948 }
                [pscustomobject]@{ LocalAddress = '127.0.0.1'; LocalPort = 9230; OwningProcess = 13948 }
            )
        }
        $positive = Get-CcodInstalledLifecycleFacts -InstallRoot $root -ExpectedDebugPorts @(9229,9230)
        Assert-CcodEqual 2 $positive.debugEndpoints.Count 'complete integer status fixture reaches endpoint observation'
        $statusOverride.session.codex.mainPort = [decimal]9229.25
        Assert-CcodTrue ($statusOverride.session.codex.mainPort -is [decimal]) 'fixture retains a non-integer status port value'
        Assert-CcodEqual 9229 ([int]$statusOverride.session.codex.mainPort) 'rounding would otherwise preserve the declared port binding'
        Assert-CcodThrows {
            Get-CcodInstalledLifecycleFacts -InstallRoot $root -ExpectedDebugPorts @(9229,9230)
        } 'CCOD_INTEGRATION_OBSERVATION_UNAVAILABLE'
    } finally {
        Clear-CcodHarnessProcessFixture
        if ($null -eq $originalNetTcp) { Remove-Item -LiteralPath Function:\Get-NetTCPConnection -Force -ErrorAction SilentlyContinue }
        else { Set-Item -LiteralPath Function:\Get-NetTCPConnection -Value $originalNetTcp }
        Set-Item -LiteralPath Function:\Read-CcodInstalledLifecycleStatusFact -Value $originalStatusReader
        Remove-Variable -Name CcodInstalledLifecycleNonIntegerStatusOverride -Scope Global -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

Invoke-CcodTest 'uses absolute end anchors for lifecycle candidate and version validation' {
    . $harnessPath -Library
    $source = [IO.File]::ReadAllText($harnessPath, [Text.UTF8Encoding]::new($false))
    Assert-CcodTrue ($source.Contains('[regex]::Match($leaf, ''^CodexRemote-fix-(\d+\.\d+\.\d+)-setup\.exe\z''')) 'candidate filename validation uses an absolute end anchor'
    Assert-CcodTrue ($source.Contains('[Parameter(Mandatory)][ValidatePattern(''^\d+\.\d+\.\d+\z'')][string]$ExpectedVersion,')) 'public expected-version validation uses an absolute end anchor'
    Assert-CcodTrue (-not $source.Contains("'^[0-9a-f]{64}$'")) 'lifecycle hash validation uses an absolute end anchor'
}

Invoke-CcodTest 'rejects expected debug ports detached from the current runtime declaration' {
    . $harnessPath -Library
    $root = Join-Path (Get-CcodTestCanonicalTempRoot) ('ccod-installed-port-binding-' + [guid]::NewGuid().ToString('N'))
    $originalStatusReader = ${function:Read-CcodInstalledLifecycleStatusFact}
    $originalNetTcp = ${function:Get-NetTCPConnection}
    try {
        $null = [IO.Directory]::CreateDirectory($root)
        New-CcodHarnessInstalledStateFixture -Root $root -ActiveRuntimeId '2.5.21-e3b0c44298fc1c14-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' -ActiveGeneration ([UInt64]8) `
            -StatusRuntimeId '2.5.21-e3b0c44298fc1c14-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' -StatusCodexPid 13948 -StatusCodexCreationTimeUtc '2026-08-24T00:00:04.0000000Z' -ReceiptPhase 'Completed'
        Set-CcodHarnessProcessFixture -ChatGPT @(
            (New-CcodHarnessCimProcess -Name 'ChatGPT.exe' -ProcessId 13948 -CreationTimeUtc '2026-08-24T00:00:04.0000000Z' -CommandLine '"C:\Program Files\WindowsApps\OpenAI.Codex\ChatGPT.exe"')
        )
        $status = Get-Content -LiteralPath (Join-Path $root 'state\status.json') -Raw | ConvertFrom-Json
        $status.session.codex.mainPort = 9229
        $status.session.codex.rendererPort = 9230
        $global:InstalledLifecycleHarnessStatusOverride = $status
        Set-Item -LiteralPath Function:\Read-CcodInstalledLifecycleStatusFact -Value { param($StateRoot) return $global:InstalledLifecycleHarnessStatusOverride }
        function global:Get-NetTCPConnection { param($State,$ErrorAction) return @() }
        $positive = Get-CcodInstalledLifecycleFacts -InstallRoot $root -ExpectedDebugPorts @(9229,9230)
        Assert-CcodEqual '9229,9230' ($positive.debugPorts -join ',') 'matching declared port baseline succeeds independently of application version'
        Assert-CcodThrows {
            Get-CcodInstalledLifecycleFacts -InstallRoot $root -ExpectedDebugPorts @(9331,9332)
        } 'CCOD_INTEGRATION_OBSERVATION_UNAVAILABLE'
    } finally {
        if ($null -eq $originalNetTcp) { Remove-Item -LiteralPath Function:\Get-NetTCPConnection -Force -ErrorAction SilentlyContinue }
        else { Set-Item -LiteralPath Function:\Get-NetTCPConnection -Value $originalNetTcp }
        Set-Item -LiteralPath Function:\Read-CcodInstalledLifecycleStatusFact -Value $originalStatusReader
        Remove-Variable -Name InstalledLifecycleHarnessStatusOverride -Scope Global -ErrorAction SilentlyContinue
        Clear-CcodHarnessProcessFixture
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

Invoke-CcodTest 'rejects fractional expected debug ports before endpoint observation' {
    . $harnessPath -Library
    $root = Join-Path (Get-CcodTestCanonicalTempRoot) ('ccod-installed-port-type-' + [guid]::NewGuid().ToString('N'))
    $originalNetTcp = ${function:Get-NetTCPConnection}
    try {
        $null = [IO.Directory]::CreateDirectory($root)
        New-CcodHarnessInstalledStateFixture -Root $root -ActiveRuntimeId '2.5.21-e3b0c44298fc1c14-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' -ActiveGeneration ([UInt64]8) `
            -StatusRuntimeId '2.5.21-e3b0c44298fc1c14-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' -StatusCodexPid 13948 -StatusCodexCreationTimeUtc '2026-08-24T00:00:04.0000000Z' -ReceiptPhase 'Completed' -StatusMainPort 9229 -StatusRendererPort 9230
        Set-CcodHarnessProcessFixture -ChatGPT @()
        function global:Get-NetTCPConnection { param($State,$ErrorAction) return @() }
        $positive = Get-CcodInstalledLifecycleFacts -InstallRoot $root -ExpectedDebugPorts @(9229,9230)
        Assert-CcodEqual '9229,9230' ($positive.debugPorts -join ',') 'integer expected-port baseline succeeds before the scalar mutation'
        Assert-CcodEqual 9229 ([int][decimal]9229.25) 'fractional fixture cannot be rejected only by downstream port mismatch'
        Assert-CcodThrows {
            Get-CcodInstalledLifecycleFacts -InstallRoot $root -ExpectedDebugPorts @([decimal]9229.25, 9230)
        } 'CCOD_INTEGRATION_OBSERVATION_UNAVAILABLE'
    } finally {
        if ($null -eq $originalNetTcp) { Remove-Item -LiteralPath Function:\Get-NetTCPConnection -Force -ErrorAction SilentlyContinue }
        else { Set-Item -LiteralPath Function:\Get-NetTCPConnection -Value $originalNetTcp }
        Clear-CcodHarnessProcessFixture
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

Invoke-CcodTest 'rejects listener endpoint fields whose scalar types are not exact integers' {
    . $harnessPath -Library
    $root = Join-Path (Get-CcodTestCanonicalTempRoot) ('ccod-installed-listener-type-' + [guid]::NewGuid().ToString('N'))
    $originalNetTcp = ${function:Get-NetTCPConnection}
    $global:InstalledLifecycleListenerObserved = 0
    try {
        [IO.Directory]::CreateDirectory($root) | Out-Null
        New-CcodHarnessInstalledStateFixture -Root $root -ActiveRuntimeId '2.5.21-e3b0c44298fc1c14-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' -ActiveGeneration ([UInt64]8) `
            -StatusRuntimeId '2.5.21-e3b0c44298fc1c14-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' -StatusCodexPid 13948 -StatusCodexCreationTimeUtc '2026-08-24T00:00:04.0000000Z' -ReceiptPhase 'Completed' -StatusMainPort 9229 -StatusRendererPort 9230
        Set-CcodHarnessProcessFixture -ChatGPT @(
            (New-CcodHarnessCimProcess -Name 'ChatGPT.exe' -ProcessId 13948 -CreationTimeUtc '2026-08-24T00:00:04.0000000Z' -CommandLine '"C:\Program Files\WindowsApps\OpenAI.Codex\ChatGPT.exe"')
        )
        function global:Get-NetTCPConnection {
            param($State,$ErrorAction)
            $global:InstalledLifecycleListenerObserved = [int]$global:InstalledLifecycleListenerObserved + 1
            return @(
                [pscustomobject]@{ LocalAddress = '127.0.0.1'; LocalPort = 9229; OwningProcess = 13948 }
                [pscustomobject]@{ LocalAddress = '127.0.0.1'; LocalPort = 9230; OwningProcess = 13948 }
            )
        }
        $valid = Get-CcodInstalledLifecycleFacts -InstallRoot $root -ExpectedDebugPorts @(9229,9230)
        Assert-CcodEqual '9229,9230' ($valid.debugPorts -join ',') 'integer listener fixture reaches a valid endpoint observation'
        $global:CcodInstalledLifecycleMixedListeners = @(
            [pscustomobject]@{ LocalAddress = '127.0.0.1'; LocalPort = [uint16]9229; OwningProcess = [uint32]13948 }
            [pscustomobject]@{ LocalAddress = '127.0.0.1'; LocalPort = [uint16]9230; OwningProcess = [uint32]13948 }
            [pscustomobject]@{ LocalAddress = '0.0.0.0'; LocalPort = [uint16]80; OwningProcess = [uint32]4 }
            [pscustomobject]@{ LocalAddress = '::'; LocalPort = [uint16]135; OwningProcess = [uint32]4 }
            [pscustomobject]@{ LocalAddress = '192.0.2.1'; LocalPort = [uint16]445; OwningProcess = [uint32]4 }
        )
        function global:Get-NetTCPConnection {
            param($State,$ErrorAction)
            $global:InstalledLifecycleListenerObserved = [int]$global:InstalledLifecycleListenerObserved + 1
            return @($global:CcodInstalledLifecycleMixedListeners)
        }
        $mixed = Get-CcodInstalledLifecycleFacts -InstallRoot $root -ExpectedDebugPorts @(9229,9230)
        Assert-CcodEqual 2 $mixed.debugEndpoints.Count 'unrelated wildcard IPv6 and LAN listeners are excluded from debug evidence'
        Assert-CcodEqual '9229,9230' (($mixed.debugEndpoints | ForEach-Object { $_.localPort }) -join ',') 'only declared debug listeners are retained'
        foreach ($unsafeAddress in @('0.0.0.0','::')) {
            $global:CcodInstalledLifecycleMixedListeners[0].LocalAddress = $unsafeAddress
            Assert-CcodThrows { Get-CcodInstalledLifecycleFacts -InstallRoot $root -ExpectedDebugPorts @(9229,9230) } 'CCOD_INTEGRATION_OBSERVATION_UNAVAILABLE'
        }
        $global:CcodInstalledLifecycleMixedListeners[0].LocalAddress = '127.0.0.1'
        $global:CcodInstalledLifecycleMixedListeners[0].OwningProcess = [uint32]13949
        Assert-CcodThrows { Get-CcodInstalledLifecycleFacts -InstallRoot $root -ExpectedDebugPorts @(9229,9230) } 'CCOD_INTEGRATION_OBSERVATION_UNAVAILABLE'
        Remove-Item -LiteralPath Function:\Get-NetTCPConnection -Force
        function global:Get-NetTCPConnection {
            param($State,$ErrorAction)
            $global:InstalledLifecycleListenerObserved = [int]$global:InstalledLifecycleListenerObserved + 1
            return @(
                [pscustomobject]@{ LocalAddress = '127.0.0.1'; LocalPort = '9229'; OwningProcess = '13948' }
                [pscustomobject]@{ LocalAddress = '127.0.0.1'; LocalPort = '9230'; OwningProcess = '13948' }
            )
        }
        Assert-CcodThrows {
            Get-CcodInstalledLifecycleFacts -InstallRoot $root -ExpectedDebugPorts @(9229,9230)
        } 'CCOD_INTEGRATION_OBSERVATION_UNAVAILABLE'
        Assert-CcodTrue ($global:InstalledLifecycleListenerObserved -ge 2) 'both valid and malformed listener fixtures were observed'
    } finally {
        Remove-Variable -Name CcodInstalledLifecycleMixedListeners -Scope Global -ErrorAction SilentlyContinue
        Clear-CcodHarnessProcessFixture
        if ($null -eq $originalNetTcp) { Remove-Item -LiteralPath Function:\Get-NetTCPConnection -Force -ErrorAction SilentlyContinue }
        else { Set-Item -LiteralPath Function:\Get-NetTCPConnection -Value $originalNetTcp }
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

Invoke-CcodTest 'verifies FreshRestart only with one correlated ChatGPT root and Completed current-runtime installer receipt' {
    . $harnessPath -Library
    $root = Join-Path (Get-CcodTestCanonicalTempRoot) ('ccod-installed-success-' + [guid]::NewGuid().ToString('N'))
    try {
        $null = [IO.Directory]::CreateDirectory($root)
        New-CcodHarnessInstalledStateFixture -Root $root -ActiveRuntimeId '2.5.21-e3b0c44298fc1c14-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' -ActiveGeneration ([UInt64]8) `
            -StatusRuntimeId '2.5.21-e3b0c44298fc1c14-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' -StatusCodexPid 13948 -StatusCodexCreationTimeUtc '2026-08-24T00:00:04.0000000Z' -ReceiptPhase 'Completed'
        Set-CcodHarnessProcessFixture -ChatGPT @(
            (New-CcodHarnessCimProcess -Name 'ChatGPT.exe' -ProcessId 13948 -CreationTimeUtc '2026-08-24T00:00:04.0000000Z' -CommandLine '"C:\Program Files\WindowsApps\OpenAI.Codex\ChatGPT.exe"'),
            (New-CcodHarnessCimProcess -Name 'ChatGPT.exe' -ProcessId 13949 -CreationTimeUtc '2026-08-24T00:00:04.1000000Z' -CommandLine '"C:\Program Files\WindowsApps\OpenAI.Codex\ChatGPT.exe" --type=renderer' -ParentProcessId 13948)
        )
        $after = Get-CcodInstalledLifecycleFacts -InstallRoot $root
        $after.installRootPresent = $true; $after.appPresent = $true
        $after.installReady = $true; $after.protectionReady = $true; $after.trayAuthenticated = $true
        $after.trayHost = @([pscustomobject][ordered]@{ Pid = 101; CreationTimeUtc = '2026-08-24T00:00:01.0000000Z' })
        $after.trayHostIdentity = [pscustomobject][ordered]@{ pid = 101; creationTimeUtc = '2026-08-24T00:00:01.0000000Z' }
        $after.aboutVersion = '2.5.0'
        $after.deviceKeyPresent = $true
        $after.deviceKeySha256 = ('b' * 64)
        $after.debugPorts = @(9229,9230)
        $after.debugEndpoints = @(
            [pscustomobject][ordered]@{ localAddress = '127.0.0.1'; localPort = 9229; owningProcess = $after.codex[0].Pid; owningProcessCreationTimeUtc = $after.codex[0].CreationTimeUtc }
            [pscustomobject][ordered]@{ localAddress = '127.0.0.1'; localPort = 9230; owningProcess = $after.codex[0].Pid; owningProcessCreationTimeUtc = $after.codex[0].CreationTimeUtc }
        )
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

Invoke-CcodTest 'rejects installed verification without an authenticated ready-state proof' {
    . $harnessPath -Library
    $context = [pscustomobject]@{ scenario = 'FreshLater'; expectedVersion = '2.5.0'; installRoot = 'C:\fixture' }
    $before = New-CcodHarnessFacts
    $after = New-CcodHarnessFacts
    $after.installReady = $false
    $after.protectionReady = $false
    $after.trayAuthenticated = $false
    $verification = Invoke-CcodHarnessWithCapturedFacts -Context $context -BeforeFacts $before -AfterFacts $after
    Assert-CcodEqual $false $verification.verified 'installed verification requires durable readiness and authenticated TrayHost identity'
    Assert-CcodEqual 'CCOD_INTEGRATION_OBSERVATION_UNPROVEN' $verification.code 'missing readiness proof uses the stable observation code'
}

Invoke-CcodTest 'rejects an incomplete installed operator run result before verification' {
    . $harnessPath -Library
    $context = [pscustomobject]@{ scenario = 'FreshLater'; expectedVersion = '2.5.0'; installRoot = 'C:\fixture' }
    $facts = New-CcodHarnessFacts
    $verification = Invoke-CcodHarnessWithCapturedFacts -Context $context -BeforeFacts $facts -AfterFacts $facts -RunResult ([pscustomobject]@{ code = 'CCOD_INTEGRATION_OPERATOR_COMPLETED' })
    Assert-CcodEqual $false $verification.verified 'an incomplete operator run result cannot report success'
    Assert-CcodEqual 'CCOD_INTEGRATION_OBSERVATION_UNPROVEN' $verification.code 'incomplete operator attestation uses the stable observation code'
}

Invoke-CcodTest 'rejects a FreshLater verification without complete owner-bound debug endpoints' {
    . $harnessPath -Library
    $before = New-CcodHarnessFacts
    $after = New-CcodHarnessFacts
    $after.debugEndpoints = @()
    $context = [pscustomobject]@{ scenario = 'FreshLater'; expectedVersion = '2.5.0'; expectedDebugPorts = @(9229,9230); installRoot = 'C:\Fake\Install' }
    $verification = Invoke-CcodHarnessWithCapturedFacts -Context $context -BeforeFacts $before -AfterFacts $after
    Assert-CcodEqual $false $verification.verified 'FreshLater requires both expected debug endpoints'
    Assert-CcodEqual 'CCOD_INTEGRATION_OBSERVATION_UNPROVEN' $verification.code 'missing debug endpoint proof uses the stable observation code'
}

Invoke-CcodTest 'rejects FreshLater verification without current status and terminal lifecycle identity' {
    . $harnessPath -Library
    $before = New-CcodHarnessFacts
    $after = New-CcodHarnessFacts
    $after.statusPhase = 'Unavailable'
    $after.statusRuntimeId = $null
    $after.statusCodex = $null
    $after.transitionStage = 'Unknown'
    $after.trayAuthenticated = $false
    $after.lifecycleReceipt = $null
    $context = [pscustomobject]@{ scenario = 'FreshLater'; expectedVersion = '2.5.0'; expectedDebugPorts = @(9229,9230); installRoot = 'C:\Fake\Install' }
    $verification = Invoke-CcodHarnessWithCapturedFacts -Context $context -BeforeFacts $before -AfterFacts $after
    Assert-CcodEqual $false $verification.verified 'FreshLater requires current status, transition, tray, and lifecycle receipt identity'
    Assert-CcodEqual 'CCOD_INTEGRATION_OBSERVATION_UNPROVEN' $verification.code 'detached FreshLater status uses the stable observation code'
}

Invoke-CcodTest 'FreshInstall requires a clean pre-install product baseline beyond zero Codex roots' {
    . $harnessPath -Library
    $before = New-CcodHarnessFacts
    $before.codex = @()
    $after = New-CcodHarnessFacts
    $context = [pscustomobject]@{ scenario = 'FreshInstall'; expectedVersion = '2.5.0'; expectedDebugPorts = @(9229,9230); installRoot = 'C:\Fake\Install' }
    $verification = Invoke-CcodHarnessWithCapturedFacts -Context $context -BeforeFacts $before -AfterFacts $after
    Assert-CcodEqual $false $verification.verified 'FreshInstall rejects an already-present install baseline even when Codex is absent'
}

Invoke-CcodTest 'FreshLater requires a pre-existing Codex identity even when the baseline is empty' {
    . $harnessPath -Library
    $before = New-CcodHarnessFacts
    $before.codex = @()
    $after = New-CcodHarnessFacts
    $context = [pscustomobject]@{ scenario = 'FreshLater'; expectedVersion = '2.5.0'; expectedDebugPorts = @(9229,9230); installRoot = 'C:\Fake\Install' }
    $verification = Invoke-CcodHarnessWithCapturedFacts -Context $context -BeforeFacts $before -AfterFacts $after
    Assert-CcodEqual $false $verification.verified 'FreshLater cannot claim a preserved pre-existing session from an empty baseline'
}

Invoke-CcodTest 'uninstall verification probes captured ports independently of deleted status' {
    . $harnessPath -Library
    $before = New-CcodHarnessFacts
    $after = New-CcodHarnessFacts
    $after.installRootPresent = $false
    $after.appPresent = $false
    $after.runtimeRootPresent = $false
    $after.activePointerPresent = $false
    $after.activeRuntimeId = $null
    $after.activeGeneration = $null
    $after.runtimeManifestSha256 = $null
    $after.runtimeManifestFiles = @()
    $after.supervisor = @()
    $after.trayHost = @()
    $after.trayHostIdentity = $null
    $after.trayAuthenticated = $false
    $after.installReady = $false
    $after.protectionReady = $false
    $after.codex = @()
    $after.taskState = 'Absent'
    $after.statusPhase = 'Unavailable'
    $after.statusRuntimeId = $null
    $after.statusCodex = $null
    $after.transitionStage = 'Unavailable'
    $after.lifecycleReceipt = $null
    $after.aboutVersion = $null
    $after.shortcuts = [pscustomobject]@{ startMenu = $false; desktop = $false }
    $after.debugPorts = @()
    $after.debugEndpoints = @()
    $afterKey = $after.deviceKeySha256
    $observedArgument = 'unset'
    $listenerProbes = 0
    $context = [pscustomobject]@{ scenario = 'DirectUninstall'; expectedVersion = '2.5.0'; expectedDebugPorts = @(9229,9230); installRoot = 'C:\Fake\Install' }
    $verification = Invoke-CcodHarnessWithCapturedFacts -Context $context -BeforeFacts $before -AfterFacts $after -ObservedExpectedDebugPorts ([ref]$observedArgument) -ObservedUninstallEnumeration ([ref]$listenerProbes)
    Assert-CcodEqual 'none' $observedArgument 'removed status is not treated as a current runtime port declaration'
    Assert-CcodTrue $verification.verified 'empty uninstall state is a valid terminal observation'
    Assert-CcodEqual $afterKey $verification.facts.deviceKeySha256 'uninstall preserves the existing device-key identity'
    Assert-CcodEqual 1 $listenerProbes 'terminal verification independently enumerates the captured ports'
    foreach ($port in @(9229,9230)) { foreach ($address in @('127.0.0.1','0.0.0.0','::','192.0.2.1')) {
        $listener = [pscustomobject]@{ LocalAddress = $address; LocalPort = [uint16]$port; OwningProcess = [uint32]4 }
        $residual = Invoke-CcodHarnessWithCapturedFacts -Context $context -BeforeFacts $before -AfterFacts $after -PostUninstallListeners @($listener)
        Assert-CcodEqual $false $residual.verified 'any remaining listener on a captured port blocks uninstall verification'
        Assert-CcodEqual 'CCOD_INTEGRATION_OBSERVATION_UNPROVEN' $residual.code 'remaining listener is not a completed uninstall'
    } }
    $context.expectedDebugPorts = @()
    $cannotSuppress = Invoke-CcodHarnessWithCapturedFacts -Context $context -BeforeFacts $before -AfterFacts $after -PostUninstallListeners @([pscustomobject]@{ LocalPort = [uint16]9230 })
    Assert-CcodEqual $false $cannotSuppress.verified 'empty caller hints cannot suppress the pre-uninstall observation'
    $context.expectedDebugPorts = @(9229,9230)
    foreach ($invalidPorts in @(@('9229',9230),@([double]9229,9230),@(9229,9229))) {
        $invalidBefore = $before.PSObject.Copy()
        $invalidBefore.debugPorts = $invalidPorts
        Assert-CcodThrows { Invoke-CcodHarnessWithCapturedFacts -Context $context -BeforeFacts $invalidBefore -AfterFacts $after } 'CCOD_INTEGRATION_OBSERVATION_UNAVAILABLE'
    }
    $unrelated = Invoke-CcodHarnessWithCapturedFacts -Context $context -BeforeFacts $before -AfterFacts $after -PostUninstallListeners @([pscustomobject]@{ LocalAddress = '::'; LocalPort = [uint16]443; OwningProcess = [uint32]4 })
    Assert-CcodTrue $unrelated.verified 'unrelated listeners do not prevent proof that captured ports are closed'
    Assert-CcodThrows { Invoke-CcodHarnessWithCapturedFacts -Context $context -BeforeFacts $before -AfterFacts $after -FailUninstallEnumeration } 'CCOD_INTEGRATION_OBSERVATION_UNAVAILABLE'
}

Invoke-CcodTest 'accepts a FreshRestart verification with ports discovered only after a clean uninstall' {
    . $harnessPath -Library
    $before = New-CcodHarnessFacts -CodexPid 10664
    $before.debugPorts = @()
    $before.debugEndpoints = @()
    $after = New-CcodHarnessFacts
    $context = [pscustomobject]@{ scenario = 'FreshRestart'; expectedVersion = '2.5.0'; installRoot = 'C:\Fake\Install' }
    $verification = Invoke-CcodHarnessWithCapturedFacts -Context $context -BeforeFacts $before -AfterFacts $after
    Assert-CcodEqual $true $verification.verified 'FreshInstall can establish its new debug-port set after uninstall'
}

Invoke-CcodTest 'rejects an active runtime with a zero generation' {
    . $harnessPath -Library
    $facts = New-CcodHarnessFacts
    $facts.activeGeneration = [UInt64]0
    Assert-CcodThrows { ConvertTo-CcodInstalledLifecycleFacts -Facts $facts } 'CCOD_INTEGRATION_FACTS_INVALID'
}

Invoke-CcodTest 'rejects non-boolean runtime-root and active-pointer presence facts' {
    . $harnessPath -Library
    $facts = New-CcodHarnessFacts
    $facts.runtimeRootPresent = 'true'
    Assert-CcodThrows { ConvertTo-CcodInstalledLifecycleFacts -Facts $facts } 'CCOD_INTEGRATION_FACTS_INVALID'
    $facts = New-CcodHarnessFacts
    $facts.activePointerPresent = 1
    Assert-CcodThrows { ConvertTo-CcodInstalledLifecycleFacts -Facts $facts } 'CCOD_INTEGRATION_FACTS_INVALID'
}

Invoke-CcodTest 'rejects dot-only active runtime IDs at the facts boundary' {
    . $harnessPath -Library
    $facts = New-CcodHarnessFacts
    $facts.activeRuntimeId = '..'
    Assert-CcodThrows { ConvertTo-CcodInstalledLifecycleFacts -Facts $facts } 'CCOD_INTEGRATION_FACTS_INVALID'
}

Invoke-CcodTest 'rejects FreshRestart when the fully correlated after root is unchanged from before' {
    . $harnessPath -Library
    $after=New-CcodHarnessFacts -RuntimeId '2.5.22-after' -CodexPid 13948 -CodexCreationTimeUtc '2026-08-24T00:00:04.0000006Z'
    $before=New-CcodHarnessFacts -RuntimeId '2.5.21-before' -CodexPid 10664 -CodexCreationTimeUtc '2026-08-24T00:00:00.0000000Z'
    $context=[pscustomobject]@{scenario='FreshRestart';expectedVersion='2.5.0';installRoot='C:\fixture'}
    $positive=Invoke-CcodHarnessWithCapturedFacts -Context $context -BeforeFacts $before -AfterFacts $after
    Assert-CcodTrue $positive.verified 'fully valid new-root baseline passes before the single identity mutation'
    $before.codex=@($after.codex)
    $negative=Invoke-CcodHarnessWithCapturedFacts -Context $context -BeforeFacts $before -AfterFacts $after
    Assert-CcodEqual $false $negative.verified 'only unchanged root makes the complete baseline invalid'
    Assert-CcodEqual 'CCOD_INTEGRATION_OBSERVATION_UNPROVEN' $negative.code 'unchanged root uses stable rejection'
    $original=${function:Test-CcodInstalledLifecycleScenario}
    try {
        $source=$original.ToString();$needle='$rootIdentityReplaced -and'
        Assert-CcodEqual 1 ([regex]::Matches($source,[regex]::Escape($needle))).Count 'one identity guard is mutated in memory only'
        Set-Item Function:Test-CcodInstalledLifecycleScenario ([scriptblock]::Create($source.Replace($needle,'$true -and')))
        $mutant=Invoke-CcodHarnessWithCapturedFacts -Context $context -BeforeFacts $before -AfterFacts $after
        Assert-CcodTrue $mutant.verified 'removing only root replacement enforcement admits the unchanged-root negative'
    } finally {Set-Item Function:Test-CcodInstalledLifecycleScenario $original}
    $before.codex=@([pscustomobject]@{pid=13948;creationTimeUtc='2026-08-24T00:00:04.0000005Z'})
    Assert-CcodTrue ((Invoke-CcodHarnessWithCapturedFacts -Context $context -BeforeFacts $before -AfterFacts $after).verified) 'reused PID with different exact creation time is a replacement root'
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
        Assert-CcodThrows {
            Invoke-CcodInstalledLifecycleIntegration -InstallerPath $fixture.Installer -ExpectedVersion '2.5.0' -EvidenceRoot $fixture.EvidenceRoot -Scenario FreshInstall -AllowMachineMutation -Adapters $adapters
        } 'CCOD_INTEGRATION_CODEX_RESTART_NOT_ALLOWED'
        Assert-CcodEqual 0 $calls.Count 'FreshInstall restart rejection also precedes every adapter action'
    } finally {
        if (Test-Path -LiteralPath $fixture.Root) { Remove-Item -LiteralPath $fixture.Root -Recurse -Force }
    }
}

Invoke-CcodTest 'integration keeps candidate bytes immutable through scenario execution' {
    . $harnessPath -Library
    $fixture=New-CcodHarnessFixture
    $calls=[Collections.Generic.List[string]]::new();$captured=$null
    try {
        $adapters=New-CcodHarnessAdapters -Fixture $fixture -Calls $calls -CapturedReceipt ([ref]$captured)
        $original=$adapters.RunScenario
        $probe=[pscustomobject]@{Attempted=0;Blocked=0;Consumed=$null}
        $adapters.RunScenario={param($Context)
            $probe.Attempted++
            try{[IO.File]::WriteAllText($Context.installerPath,'changed-at-execution')}catch [IO.IOException]{$probe.Blocked++}
            $probe.Consumed=Get-CcodTestFileSha256 $Context.installerPath
            & $original $Context
        }
        $result=Invoke-CcodInstalledLifecycleIntegration -InstallerPath $fixture.Installer -ExpectedVersion '2.5.0' -EvidenceRoot $fixture.EvidenceRoot -Scenario FreshLater -AllowMachineMutation -Adapters $adapters
        Assert-CcodEqual 1 $probe.Attempted 'test reaches real scenario execution after validation'
        Assert-CcodEqual $fixture.InstallerHash $probe.Consumed 'scenario consumes the original candidate bytes'
        Assert-CcodEqual 1 $probe.Blocked 'candidate overwrite is denied throughout consumption'
        Assert-CcodEqual 'Completed' $result.outcome 'unchanged consumption remains valid'
        [IO.File]::WriteAllText($fixture.Installer,'writable-after-execution')
    } finally {if(Test-Path $fixture.Root){Remove-Item -LiteralPath $fixture.Root -Recurse -Force}}
}

Invoke-CcodTest 'default official phase binds its original candidate before actual integration mutation' {
    $fixture=New-CcodHarnessFixture;$sealed=$null;$official=$null;$integration=$null
    try {
        $sealed=New-CcodHarnessSealedFixture
        $official=Import-Module (Join-Path $repositoryRoot 'tests/installed/OfficialDraftAcceptance.psm1') -Force -PassThru -DisableNameChecking
        $integration=&$official {Get-CcodOfficialDraftIntegrationModule}
        $calls=[Collections.Generic.List[string]]::new();$captured=$null
        $adapters=New-CcodHarnessAdapters -Fixture $fixture -Calls $calls -BeforeVersion '2.5.22' -AfterVersion '2.5.22' -CapturedReceipt ([ref]$captured)
        $after=New-CcodHarnessFacts -Version '2.5.22'
        $after.runtimeManifestFiles=@(([IO.File]::ReadAllText((Join-Path $sealed.Root $sealed.Names[8]))|ConvertFrom-Json).files)
        $adapters.VerifyScenario={param($Context,$BeforeFacts,$RunResult)$calls.Add('VerifyScenario');[pscustomobject]@{verified=$true;code='CCOD_INTEGRATION_VERIFIED';facts=$after}}
        &$integration {param($SafeAdapters)$script:CcodBoundaryAdapters=$SafeAdapters;function script:Resolve-CcodInstalledLifecycleAdapters {param($Adapters)return $script:CcodBoundaryAdapters}} $adapters
        $context=&$official {
            param($Root,$Evidence)
            $assetModule=Get-CcodOfficialDraftAssetModule
            $contract=&$assetModule {param($Root)Test-CcodExactReleaseAssetSet -AssetDirectory $Root -Version '2.5.22'} $Root
            $candidate=ConvertTo-CcodOfficialDraftCandidate $contract
            New-CcodOfficialDraftContext -Phase FreshInstall -AssetDirectory $Root -PreviousAssetDirectory $Root -EvidenceRoot $Evidence -Candidate $candidate -Draft ([pscustomobject]@{tag='v2.5.22';id='123'}) -PreviousSetup ([pscustomobject]@{version='2.5.21';assetSha256=('a'*64);manifestSha256=('b'*64)}) -AllowMachineMutation -AllowCodexRestart
        } $sealed.Root $fixture.EvidenceRoot
        $run=&$official {(Get-CcodOfficialDraftDefaultAdapters).RunPhase}
        $control=&$run $context
        Assert-CcodTrue $control.completed 'real default phase and real integration have a valid sealed candidate control'
        $original=$context.candidate|ConvertTo-Json -Depth 8 -Compress
        foreach($mode in @('Installer','Commit','OtherAsset')) {
            $context.candidate=$original|ConvertFrom-Json
            if($mode-ceq'Installer'){$context.candidate.assetHashes[5].sha256='1'*64}
            elseif($mode-ceq'Commit'){$context.candidate.gitCommit='1'*40}
            else{$context.candidate.assetHashes[2].sha256='1'*64}
            $calls.Clear()
            Assert-CcodThrows {&$run $context|Out-Null} 'CCOD_ACCEPTANCE_MACHINE_OPERATION_FAILED'
            Assert-CcodTrue (-not$calls.Contains('CreateRollbackSnapshot')) ($mode+' rejects before snapshot')
            Assert-CcodTrue (-not$calls.Contains('RunScenario')) ($mode+' rejects before machine action rather than post-operation')
            Assert-CcodTrue (-not$calls.Contains('NewEvidenceDirectory')) ($mode+' rejects before creating success evidence')
        }
        $context.candidate=$original|ConvertFrom-Json
        Assert-CcodTrue (&$run $context).completed 'failed binding releases authority for a legitimate retry'
    } finally {
        if($null-ne$integration){Remove-Module $integration.Name -Force -ErrorAction SilentlyContinue}
        if($null-ne$official){Remove-Module $official.Name -Force -ErrorAction SilentlyContinue}
        if($null-ne$sealed){foreach($root in @($sealed.Root,$sealed.Outside)){if(Test-Path $root){Remove-Item $root -Recurse -Force}}}
        if(Test-Path $fixture.Root){Remove-Item $fixture.Root -Recurse -Force}
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

Invoke-CcodTest 'rollback launches the canonical frozen installer path directly' {
    $source = [IO.File]::ReadAllText($harnessPath)
    Assert-CcodTrue (-not $source.Contains('Start-Process -FilePath $installer.FullName')) 'rollback uses the canonical frozen installer path returned by validation'
}

Invoke-CcodTest 'rollback validates the frozen temporary root before copying prior artifacts' {
    $source = [IO.File]::ReadAllText($harnessPath, [Text.UTF8Encoding]::new($false))
    $copy = $source.IndexOf('[IO.File]::Copy($previousCandidate.Path', [StringComparison]::Ordinal)
    $safe = $source.IndexOf('Assert-CcodInstalledLifecycleSafeDirectory -Path $frozenPreviousRoot', [StringComparison]::Ordinal)
    Assert-CcodTrue ($safe -ge 0 -and $copy -ge 0 -and $safe -lt $copy) 'frozen rollback root is checked for canonical non-reparse ancestry before copying'
}

Invoke-CcodTest 'rollback cleanup rejects a descendant reparse point before recursive deletion' {
    . $harnessPath -Library
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-frozen-descendant-reparse-' + [guid]::NewGuid().ToString('N'))
    $outside = Join-Path ([IO.Path]::GetTempPath()) ('ccod-frozen-descendant-outside-' + [guid]::NewGuid().ToString('N'))
    $junction = Join-Path $root 'escape'
    [IO.Directory]::CreateDirectory($root) | Out-Null
    [IO.Directory]::CreateDirectory($outside) | Out-Null
    $outsideFile = Join-Path $outside 'keep.txt'
    [IO.File]::WriteAllText($outsideFile, 'must remain', [Text.UTF8Encoding]::new($false))
    try {
        New-Item -ItemType Junction -Path $junction -Target $outside | Out-Null
        Assert-CcodThrows { Remove-CcodInstalledLifecycleFrozenRoot -Path $root } 'CCOD_INTEGRATION_ROLLBACK_CLEANUP_FAILED'
        Assert-CcodTrue (Test-Path -LiteralPath $outsideFile -PathType Leaf) 'unsafe frozen cleanup does not touch the reparse target'
    } finally {
        try { if ([IO.Directory]::Exists($junction)) { [IO.Directory]::Delete($junction, $false) } } catch { }
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $outside) { Remove-Item -LiteralPath $outside -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Invoke-CcodTest 'default installed verifier preserves converter fields until the integration boundary' {
    $source = [IO.File]::ReadAllText($harnessPath)
    $removeDebug = $source.IndexOf("if (`$afterFacts.PSObject.Properties['debugPorts']) { `$afterFacts.PSObject.Properties.Remove('debugPorts') }")
    $callerConvert = $source.IndexOf('$verification = [pscustomobject][ordered]@{')
    Assert-CcodTrue ($removeDebug -lt 0 -or $callerConvert -lt $removeDebug) 'default verifier does not remove mandatory debug fields before the caller converter'
}

Invoke-CcodTest 'accepts an exact checksum-bound v2.5.21 installer as the source of a v2.5.22 upgrade run' {
    . $harnessPath -Library
    $fixture = New-CcodHarnessFixture
    $sealed=$null
    try {
        $sealed=New-CcodHarnessSealedFixture
        $current=Join-Path $sealed.Root $sealed.Names[5]
        $package=[IO.File]::ReadAllText((Join-Path $sealed.Root $sealed.Names[8]))|ConvertFrom-Json
        $legacy = New-CcodHarnessCandidate -Fixture $fixture -Version '2.5.21' -Bytes ([byte[]](2,3,5,7,11,13,17,19))
        $legacyManifest = Join-Path $fixture.Root 'CodexRemote-fix-2.5.21-setup-release-manifest.json'
        [IO.File]::WriteAllText($legacyManifest, 'legacy release manifest', [Text.UTF8Encoding]::new($false))
        $legacyInstallerHash = Get-CcodTestFileSha256 -Path $legacy
        $legacyManifestHash = Get-CcodTestFileSha256 -Path $legacyManifest
        $calls = [Collections.Generic.List[string]]::new()
        $captured = $null
        $adapters = New-CcodHarnessAdapters -Fixture $fixture -Calls $calls -BeforeVersion '2.5.21' -AfterVersion '2.5.22' -CapturedReceipt ([ref]$captured)
        $after=New-CcodHarnessFacts -Version '2.5.22';$after.runtimeManifestFiles=@($package.files)
        $adapters.VerifyScenario={param($Context,$BeforeFacts,$RunResult)$calls.Add('VerifyScenario');[pscustomobject]@{verified=$true;code='CCOD_INTEGRATION_VERIFIED';facts=$after}}
        $receipt = Invoke-CcodInstalledLifecycleIntegration -InstallerPath $current -PreviousInstallerPath $legacy -PreviousExpectedVersion '2.5.21' -PreviousInstallerSha256 $legacyInstallerHash -PreviousManifestSha256 $legacyManifestHash -ExpectedVersion '2.5.22' -EvidenceRoot $fixture.EvidenceRoot -Scenario Upgrade -AllowMachineMutation -AllowCodexRestart -Adapters $adapters
        Assert-CcodEqual 'Completed' ([string]$receipt.outcome) 'v2.5.21 to v2.5.22 reaches the fake installed verification boundary'
        Assert-CcodTrue ($receipt.beforeFacts.PSObject.Properties['debugPorts'] -and $receipt.beforeFacts.PSObject.Properties['debugEndpoints']) 'upgrade evidence retains the observed pre-operation debug endpoints'
        Assert-CcodTrue ($receipt.verification.facts.PSObject.Properties['debugPorts'] -and $receipt.verification.facts.PSObject.Properties['debugEndpoints']) 'upgrade evidence retains the observed post-operation debug endpoints'
        Assert-CcodEqual (Get-CcodTestFileSha256 -Path $legacy) ([string]$receipt.previousInstallerSha256) 'upgrade evidence binds the exact v2.5.21 installer bytes'
        [IO.File]::WriteAllBytes($legacy, [byte[]](31,29,27,25,23,21,19,17))
        $replacementHash = Get-CcodTestFileSha256 -Path $legacy
        [IO.File]::WriteAllText("$legacy.sha256.txt", ("{0} *{1}`r`n" -f $replacementHash, [IO.Path]::GetFileName($legacy)), [Text.UTF8Encoding]::new($false))
        Assert-CcodThrows {
            Invoke-CcodInstalledLifecycleIntegration -InstallerPath $current -PreviousInstallerPath $legacy -PreviousExpectedVersion '2.5.21' -PreviousInstallerSha256 $legacyInstallerHash -PreviousManifestSha256 $legacyManifestHash -ExpectedVersion '2.5.22' -EvidenceRoot $fixture.EvidenceRoot -Scenario Upgrade -AllowMachineMutation -AllowCodexRestart -Adapters $adapters
        } 'CCOD_INTEGRATION_PREVIOUS_INSTALLER_INVALID'
        Assert-CcodTrue ($replacementHash -cne $legacyInstallerHash) 'replacement fixture changes the prior installer bytes'
        Assert-CcodTrue ($calls -contains 'CreateRollbackSnapshot') 'legacy upgrade captures rollback state before the adapted scenario'
        Assert-CcodTrue ($calls -contains 'VerifyScenario') 'legacy upgrade still requires independent installed verification'
        Assert-CcodEqual 'CaptureFacts:2.5.21' ((@($calls | Where-Object { [string]$_ -like 'CaptureFacts:*' }) -join '|')) 'upgrade observes the retained v2.5.21 state before invoking the v2.5.22 operation'
    } finally {
        if($null-ne$sealed){foreach($root in @($sealed.Root,$sealed.Outside)){if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}}}
        if (Test-Path -LiteralPath $fixture.Root) { Remove-Item -LiteralPath $fixture.Root -Recurse -Force }
    }
}

Invoke-CcodTest 'rejects a self-consistent active runtime whose payload file set is detached from the candidate' {
    . $harnessPath -Library
    $fixture = New-CcodHarnessFixture
    $sealed=$null
    try {
        $sealed=New-CcodHarnessSealedFixture
        $current=Join-Path $sealed.Root $sealed.Names[5]
        $package=[IO.File]::ReadAllText((Join-Path $sealed.Root $sealed.Names[8]))|ConvertFrom-Json
        $calls = [Collections.Generic.List[string]]::new()
        $adapters = New-CcodHarnessAdapters -Fixture $fixture -Calls $calls -BeforeVersion '2.5.21' -AfterVersion '2.5.22' -CapturedReceipt ([ref]$null)
        $state=[pscustomobject]@{After=(New-CcodHarnessFacts -Version '2.5.22')}
        $state.After.runtimeManifestFiles=@($package.files)
        $adapters.VerifyScenario={param($Context,$BeforeFacts,$RunResult)$calls.Add('VerifyScenario');[pscustomobject]@{verified=$true;code='CCOD_INTEGRATION_VERIFIED';facts=$state.After}}
        $control=Invoke-CcodInstalledLifecycleIntegration -InstallerPath $current -ExpectedVersion '2.5.22' -EvidenceRoot $fixture.EvidenceRoot -Scenario FreshLater -AllowMachineMutation -AllowCodexRestart -Adapters $adapters
        Assert-CcodEqual 'Completed' $control.outcome 'sealed candidate and matching runtime records pass before one file changes'
        $state.After.runtimeManifestFiles[0].sha256='f'*64
        Assert-CcodThrows {
            Invoke-CcodInstalledLifecycleIntegration -InstallerPath $current -ExpectedVersion '2.5.22' -EvidenceRoot $fixture.EvidenceRoot -Scenario FreshLater -AllowMachineMutation -AllowCodexRestart -Adapters $adapters
        } 'CCOD_INTEGRATION_VERIFICATION_FAILED'
    } finally {
        if($null-ne$sealed){foreach($root in @($sealed.Root,$sealed.Outside)){if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}}}
        if (Test-Path -LiteralPath $fixture.Root) { Remove-Item -LiteralPath $fixture.Root -Recurse -Force }
    }
}

Invoke-CcodTest 'upgrade rollback routes through a frozen previous installer identity' {
    . $harnessPath -Library
    $fixture = New-CcodHarnessFixture
    try {
        $current = New-CcodHarnessCandidate -Fixture $fixture -Version '2.5.0' -Bytes ([byte[]](9,8,7,6,5,4,3,2))
        $previous = New-CcodHarnessCandidate -Fixture $fixture -Version '2.4.24' -Bytes ([byte[]](2,3,5,7,11,13,17,19))
        $previousManifest = Join-Path $fixture.Root 'CodexRemote-fix-2.4.24-setup-release-manifest.json'
        [IO.File]::WriteAllText($previousManifest, 'previous release manifest', [Text.UTF8Encoding]::new($false))
        $previousInstallerHash = Get-CcodTestFileSha256 -Path $previous
        $previousManifestHash = Get-CcodTestFileSha256 -Path $previousManifest
        $calls = [Collections.Generic.List[string]]::new()
        $captured = $null
        $adapters = New-CcodHarnessAdapters -Fixture $fixture -Calls $calls -FailScenario -ReplacePreviousAfterValidation $previous -RecordRollbackIdentity -CapturedReceipt ([ref]$captured)
        Assert-CcodThrows {
            Invoke-CcodInstalledLifecycleIntegration -InstallerPath $current -PreviousInstallerPath $previous -PreviousExpectedVersion '2.4.24' -PreviousInstallerSha256 $previousInstallerHash -PreviousManifestSha256 $previousManifestHash -ExpectedVersion '2.5.0' -EvidenceRoot $fixture.EvidenceRoot -Scenario Upgrade -AllowMachineMutation -AllowCodexRestart -Adapters $adapters
        } 'CCOD_INTEGRATION_SCENARIO_FAILED'
        $rollbackPath = @($calls | Where-Object { [string]$_ -like 'RollbackPath:*' })[0].Substring(13)
        $rollbackHash = @($calls | Where-Object { [string]$_ -like 'RollbackHash:*' })[0].Substring(13)
        Assert-CcodTrue (-not [string]::IsNullOrWhiteSpace($rollbackPath)) 'failed upgrade enters rollback with an explicit previous installer'
        Assert-CcodEqual $previousInstallerHash $rollbackHash 'rollback uses the byte identity validated before the scenario'
        Assert-CcodTrue ($rollbackPath -cne $previous) 'rollback does not launch the mutable source path'
    } finally {
        if (Test-Path -LiteralPath $fixture.Root) { Remove-Item -LiteralPath $fixture.Root -Recurse -Force }
    }
}

Invoke-CcodTest 'frozen rollback bytes remain held until their actual consumer returns' {
    . $harnessPath -Library
    $fixture=New-CcodHarnessFixture
    $originalStart=${function:Start-Process};$originalAck=${function:Read-CcodInstalledLifecycleOperatorAck}
    try {
        $previous=New-CcodHarnessCandidate -Fixture $fixture -Version '2.4.24'
        $manifest=Join-Path $fixture.Root 'CodexRemote-fix-2.4.24-setup-release-manifest.json'
        [IO.File]::WriteAllText($manifest,'original previous manifest')
        $expected=Get-CcodTestFileSha256 $previous;$manifestHash=Get-CcodTestFileSha256 $manifest
        $calls=[Collections.Generic.List[string]]::new();$captured=$null
        $adapters=New-CcodHarnessAdapters -Fixture $fixture -Calls $calls -FailScenario -CapturedReceipt ([ref]$captured)
        $probe=[pscustomobject]@{Attempts=0;Blocked=0;Consumed=$null;Path=$null;Manifest=$null}
        $adapters.Rollback={param($Context,$Snapshot)$probe.Manifest=$Context.previousManifestPath;Invoke-CcodInstalledLifecycleRollback -Context $Context -Snapshot $Snapshot}
        function Start-Process {param($FilePath,[switch]$PassThru,[switch]$Wait,$ErrorAction)
            $probe.Attempts++;$probe.Path=$FilePath
            foreach($path in @($FilePath,$probe.Manifest)){try{[IO.File]::WriteAllText($path,'changed before rollback launch')}catch [IO.IOException]{$probe.Blocked++}}
            $probe.Consumed=Get-CcodTestFileSha256 $FilePath
            [pscustomobject]@{ExitCode=0}
        }
        function Read-CcodInstalledLifecycleOperatorAck {param($Scenario,$Instructions)}
        Assert-CcodThrows {Invoke-CcodInstalledLifecycleIntegration -InstallerPath $fixture.Installer -PreviousInstallerPath $previous -PreviousExpectedVersion '2.4.24' -PreviousInstallerSha256 $expected -PreviousManifestSha256 $manifestHash -ExpectedVersion '2.5.0' -EvidenceRoot $fixture.EvidenceRoot -Scenario Upgrade -AllowMachineMutation -AllowCodexRestart -Adapters $adapters|Out-Null} 'CCOD_INTEGRATION_SCENARIO_FAILED'
        Assert-CcodEqual 1 $probe.Attempts 'real rollback reaches the native launch seam'
        Assert-CcodEqual $expected $probe.Consumed 'rollback consumes only originally frozen executable bytes'
        Assert-CcodEqual 2 $probe.Blocked 'both executable and manifest remain held through launch'
        Assert-CcodTrue $captured.rollback.completed 'rollback itself completes while the original scenario stays failed'
        Assert-CcodTrue (-not(Test-Path -LiteralPath (Split-Path $probe.Path -Parent))) 'all holds release before frozen directory cleanup'
    } finally {
        foreach($pair in @(@('Start-Process',$originalStart),@('Read-CcodInstalledLifecycleOperatorAck',$originalAck))){if($null-ne$pair[1]){Set-Item ('Function:'+$pair[0]) $pair[1]}else{Remove-Item ('Function:'+$pair[0]) -ErrorAction SilentlyContinue}}
        if(Test-Path $fixture.Root){Remove-Item $fixture.Root -Recurse -Force}
    }
}

Invoke-CcodTest 'accepts only a distinct checksum-bound prior installer for an upgrade rollback path' {
    . $harnessPath -Library
    $fixture = New-CcodHarnessFixture
    try {
        $previous = New-CcodHarnessCandidate -Fixture $fixture -Version '2.4.24'
        $previousManifest = Join-Path $fixture.Root 'CodexRemote-fix-2.4.24-setup-release-manifest.json'
        [IO.File]::WriteAllText($previousManifest, 'previous release manifest', [Text.UTF8Encoding]::new($false))
        $previousInstallerHash = Get-CcodTestFileSha256 -Path $previous
        $previousManifestHash = Get-CcodTestFileSha256 -Path $previousManifest
        $calls = [Collections.Generic.List[string]]::new()
        $captured = $null
        $adapters = New-CcodHarnessAdapters -Fixture $fixture -Calls $calls -CapturedReceipt ([ref]$captured)
        $receipt = Invoke-CcodInstalledLifecycleIntegration -InstallerPath $fixture.Installer -PreviousInstallerPath $previous -PreviousExpectedVersion '2.4.24' -PreviousInstallerSha256 $previousInstallerHash -PreviousManifestSha256 $previousManifestHash -ExpectedVersion '2.5.0' -EvidenceRoot $fixture.EvidenceRoot -Scenario Upgrade -AllowMachineMutation -AllowCodexRestart -Adapters $adapters
        Assert-CcodEqual 'Completed' ([string]$receipt.outcome) 'distinct prior installer can support a checked upgrade run'
        Assert-CcodThrows {
            Invoke-CcodInstalledLifecycleIntegration -InstallerPath $fixture.Installer -PreviousInstallerPath $fixture.Installer -PreviousExpectedVersion '2.4.24' -PreviousInstallerSha256 $previousInstallerHash -PreviousManifestSha256 $previousManifestHash -ExpectedVersion '2.5.0' -EvidenceRoot $fixture.EvidenceRoot -Scenario Upgrade -AllowMachineMutation -AllowCodexRestart -Adapters $adapters
        } 'CCOD_INTEGRATION_PREVIOUS_INSTALLER_INVALID'
        $future = New-CcodHarnessCandidate -Fixture $fixture -Version '2.5.1'
        Assert-CcodThrows {
            Invoke-CcodInstalledLifecycleIntegration -InstallerPath $fixture.Installer -PreviousInstallerPath $future -PreviousExpectedVersion '2.4.24' -PreviousInstallerSha256 $previousInstallerHash -PreviousManifestSha256 $previousManifestHash -ExpectedVersion '2.5.0' -EvidenceRoot $fixture.EvidenceRoot -Scenario Upgrade -AllowMachineMutation -AllowCodexRestart -Adapters $adapters
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

Invoke-CcodTest 'rejects a noncanonical installer path before candidate validation' {
    . $harnessPath -Library
    $fixture = New-CcodHarnessFixture
    try {
        $calls = [Collections.Generic.List[string]]::new()
        $captured = $null
        $adapters = New-CcodHarnessAdapters -Fixture $fixture -Calls $calls -CapturedReceipt ([ref]$captured)
        $nonCanonical = Join-Path $fixture.Root 'nested\..\CodexRemote-fix-2.5.0-setup.exe'
        Assert-CcodThrows {
            Get-CcodInstalledLifecycleCandidate -Path $nonCanonical -ExpectedVersion '2.5.0' -Adapters $adapters -Kind 'Installer' | Out-Null
        } 'CCOD_INTEGRATION_CANDIDATE_INVALID'
    } finally {
        if (Test-Path -LiteralPath $fixture.Root) { Remove-Item -LiteralPath $fixture.Root -Recurse -Force }
    }
}

Invoke-CcodTest 'rejects noncanonical installed observation paths instead of normalizing them' {
    . $harnessPath -Library
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-integration-canonical-' + [guid]::NewGuid().ToString('N'))
    try {
        [IO.Directory]::CreateDirectory($root) | Out-Null
        Set-CcodHarnessProcessFixture -ChatGPT @()
        $probe = { param($Path) throw [IO.FileNotFoundException]::new('fixture missing',$Path) }
        Assert-CcodThrows {
            Get-CcodInstalledLifecycleOptionalDirectoryState -Path (Join-Path $root '.\missing') -GetItem $probe | Out-Null
        } 'CCOD_INTEGRATION_OBSERVATION_UNAVAILABLE'
        Assert-CcodThrows {
            Get-CcodInstalledLifecycleFacts -InstallRoot (Join-Path $root '.')
        } 'CCOD_INTEGRATION_OBSERVATION_UNAVAILABLE'
    } finally {
        Clear-CcodHarnessProcessFixture
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

Invoke-CcodTest 'installed lifecycle optional directory probe fails closed on access errors' {
    . $harnessPath -Library
    $probe = { param($Path) throw [UnauthorizedAccessException]::new('fixture access denied') }
    Assert-CcodThrows { Get-CcodInstalledLifecycleOptionalDirectoryState -Path 'C:\fixture\blocked' -GetItem $probe | Out-Null } 'CCOD_INTEGRATION_OBSERVATION_UNAVAILABLE'
}

Invoke-CcodTest 'installed lifecycle optional missing leaves reject a reparse parent' {
    . $harnessPath -Library
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-integration-reparse-' + [guid]::NewGuid().ToString('N'))
    $outside = Join-Path ([IO.Path]::GetTempPath()) ('ccod-integration-reparse-target-' + [guid]::NewGuid().ToString('N'))
    $junction = Join-Path $root 'state-link'
    try {
        [IO.Directory]::CreateDirectory($root) | Out-Null
        [IO.Directory]::CreateDirectory($outside) | Out-Null
        New-Item -ItemType Junction -Path $junction -Target $outside | Out-Null
        $probe = { param($Path) Get-Item -LiteralPath $Path -Force -ErrorAction Stop }
        Assert-CcodThrows { Get-CcodInstalledLifecycleOptionalRegularFileState -Path (Join-Path $junction 'missing.json') -GetItem $probe | Out-Null } 'CCOD_INTEGRATION_OBSERVATION_UNAVAILABLE'
    } finally {
        if ([IO.Directory]::Exists($junction)) { [IO.Directory]::Delete($junction) }
        if ([IO.Directory]::Exists($root)) { [IO.Directory]::Delete($root, $true) }
        if ([IO.Directory]::Exists($outside)) { [IO.Directory]::Delete($outside, $true) }
    }
}

Invoke-CcodTest 'installed lifecycle default evidence writer cleans a failed readback' {
    . $harnessPath -Library
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-evidence-readback-' + [guid]::NewGuid().ToString('N'))
    $receipt = [pscustomobject][ordered]@{ schemaVersion = 1; transactionId = 'fixture-readback'; outcome = 'Completed' }
    try {
        [IO.Directory]::CreateDirectory($root) | Out-Null
        $defaults = Get-CcodInstalledLifecycleDefaultAdapters
        $directory = & $defaults.NewEvidenceDirectory $root 'fixture-readback'
        $verifier = { param($Path) [IO.File]::WriteAllText($Path, 'tampered', [Text.UTF8Encoding]::new($false)); return $false }
        Assert-CcodThrows { & $defaults.WriteEvidence $directory $receipt $verifier | Out-Null } 'CCOD_INTEGRATION_EVIDENCE_CLEANUP_FAILED'
        Assert-CcodTrue ([IO.File]::Exists((Join-Path $directory 'receipt.json'))) 'unknown replacement evidence remains for manual cleanup'
    } finally {
        if ([IO.Directory]::Exists($root)) { [IO.Directory]::Delete($root, $true) }
    }
}

Invoke-CcodTest 'installed lifecycle rejects unreadable Supervisor and TrayHost identity fields' {
    . $harnessPath -Library
    Assert-CcodThrows { Assert-CcodInstalledLifecycleReadableProcessText -Value $null -Kind 'Supervisor CommandLine' } 'CCOD_INTEGRATION_OBSERVATION_UNAVAILABLE'
    Assert-CcodThrows { Assert-CcodInstalledLifecycleReadableProcessText -Value ([pscustomobject]@{}) -Kind 'TrayHost ExecutablePath' } 'CCOD_INTEGRATION_OBSERVATION_UNAVAILABLE'
}

Invoke-CcodTest 'installed lifecycle clean checkout includes ignored contamination' {
    $raw = [IO.File]::ReadAllText($harnessPath, [Text.UTF8Encoding]::new($false))
    Assert-CcodTrue ($raw.Contains('--ignored=matching')) 'default Git status includes ignored contamination'
}

Invoke-CcodTest 'installed lifecycle accepts schema-one legacy active json' {
    . $harnessPath -Library
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-legacy-active-json-' + [guid]::NewGuid().ToString('N'))
    try {
        [IO.Directory]::CreateDirectory($root) | Out-Null
        $legacyRuntime = '2.5.21-e3b0c44298fc1c14'
        [IO.File]::WriteAllText((Join-Path $root 'active.json'), ([ordered]@{ schemaVersion = 1; activeRuntime = $legacyRuntime; previousRuntime = $null; updatedAtUtc = '2030-02-03T04:05:06.0000000Z' } | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
        $active = Read-CcodInstalledLifecycleActiveFact -InstallRoot $root
        Assert-CcodEqual $legacyRuntime $active.activeRuntime 'legacy active runtime id is retained'
        Assert-CcodEqual ([UInt64]1) ([UInt64]$active.generation) 'schema-one active pointer maps to generation one'
    } finally { if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force } }
}

Invoke-CcodTest 'installed lifecycle rejects an invalid UTC start clock before mutation' {
    . $harnessPath -Library
    $fixture = New-CcodHarnessFixture
    try {
        $calls = [Collections.Generic.List[string]]::new()
        $adapters = New-CcodHarnessAdapters -Fixture $fixture -Calls $calls
        $adapters.GetUtcNow = { [datetime]::SpecifyKind([datetime]::MinValue,[DateTimeKind]::Utc) }
        Assert-CcodThrows {
            Invoke-CcodInstalledLifecycleIntegration -InstallerPath $fixture.Installer -ExpectedVersion '2.5.0' -EvidenceRoot $fixture.EvidenceRoot -Scenario FreshRestart -AllowMachineMutation -AllowCodexRestart -Adapters $adapters
        } 'CCOD_INTEGRATION_CLOCK_INVALID'
        Assert-CcodTrue (-not ($calls -contains 'RunScenario')) 'invalid start clock cannot run a machine scenario'
    } finally {
        if (Test-Path -LiteralPath $fixture.Root) { Remove-Item -LiteralPath $fixture.Root -Recurse -Force }
    }
}

Invoke-CcodTest 'installed lifecycle rejects an invalid completion clock instead of substituting the current time' {
    . $harnessPath -Library
    $fixture = New-CcodHarnessFixture
    try {
        $calls = [Collections.Generic.List[string]]::new()
        $adapters = New-CcodHarnessAdapters -Fixture $fixture -Calls $calls
        $global:CcodLifecycleCompletionClockCalls = 0
        $adapters.GetUtcNow = {
            $global:CcodLifecycleCompletionClockCalls++
            if ($global:CcodLifecycleCompletionClockCalls -eq 1) { return [datetime]::UtcNow }
            return 'not-a-date'
        }
        Assert-CcodThrows {
            Invoke-CcodInstalledLifecycleIntegration -InstallerPath $fixture.Installer -ExpectedVersion '2.5.0' -EvidenceRoot $fixture.EvidenceRoot -Scenario FreshRestart -AllowMachineMutation -AllowCodexRestart -Adapters $adapters
        } 'CCOD_INTEGRATION_CLOCK_INVALID'
    } finally {
        Remove-Variable -Name CcodLifecycleCompletionClockCalls -Scope Global -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $fixture.Root) { Remove-Item -LiteralPath $fixture.Root -Recurse -Force }
    }
}

Invoke-CcodTest 'installed lifecycle rejects an unsafe schema-one active runtime before path use' {
    . $harnessPath -Library
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-legacy-unsafe-active-json-' + [guid]::NewGuid().ToString('N'))
    try {
        [IO.Directory]::CreateDirectory($root) | Out-Null
        $legacy = [ordered]@{ schemaVersion = 1; activeRuntime = '..'; previousRuntime = $null; updatedAtUtc = '2030-02-03T04:05:06.0000000Z' }
        [IO.File]::WriteAllText((Join-Path $root 'active.json'), ($legacy | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
        Assert-CcodThrows { Read-CcodInstalledLifecycleActiveFact -InstallRoot $root | Out-Null } 'CCOD_INTEGRATION_FACTS_INVALID'
    } finally { if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force } }
}

Invoke-CcodTest 'installed lifecycle accepts the documented two-part v2.5.21 runtime identity' {
    . $harnessPath -Library
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-legacy-runtime-' + [guid]::NewGuid().ToString('N'))
    try {
        $runtime = Join-Path $root 'runtime'
        [IO.Directory]::CreateDirectory($runtime) | Out-Null
        $payload = Join-Path $runtime 'payload.txt'
        [IO.File]::WriteAllText($payload, 'legacy payload', [Text.UTF8Encoding]::new($false))
        $length = [int64](Get-Item -LiteralPath $payload).Length
        $sha = Get-CcodInstalledLifecycleHash -Path $payload
        $canonical = 'payload.txt`t{0}`t{1}' -f $length,$sha
        $digestAlgorithm = [Security.Cryptography.SHA256]::Create()
        try { $digest = ([BitConverter]::ToString($digestAlgorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonical)))).Replace('-','').ToLowerInvariant() } finally { $digestAlgorithm.Dispose() }
        $runtimeId = '2.5.21-' + $digest.Substring(0,16)
        $manifest = [pscustomobject][ordered]@{ schemaVersion = 1; projectVersion = '2.5.21'; runtimeId = $runtimeId; files = @([pscustomobject][ordered]@{ path = 'payload.txt'; length = $length; sha256 = $sha }) }
        [IO.File]::WriteAllText((Join-Path $runtime 'manifest.json'), ($manifest | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
        $result = Assert-CcodInstalledLifecycleRuntimeManifest -Manifest $manifest -ExpectedVersion '2.5.21' -ExpectedRuntimeId $runtimeId -RuntimeRoot $runtime
        Assert-CcodEqual $runtimeId $result.runtimeId 'legacy two-part runtime identity is accepted only for v2.5.21'
    } finally { if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force } }
}

Invoke-CcodTest 'installed lifecycle runtime manifest binds schema version project version and runtime id' {
    . $harnessPath -Library
    $manifest = [pscustomobject][ordered]@{ schemaVersion = 1; projectVersion = '2.5.21'; runtimeId = '2.5.22-aaaaaaaaaaaaaaaa-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'; files = @() }
    Assert-CcodThrows { Assert-CcodInstalledLifecycleRuntimeManifest -Manifest $manifest -ExpectedVersion '2.5.22' -ExpectedRuntimeId $manifest.runtimeId } 'CCOD_INTEGRATION_OBSERVATION_UNAVAILABLE'
    $mismatch = [pscustomobject][ordered]@{ schemaVersion = 1; projectVersion = '2.5.22'; runtimeId = '2.5.21-aaaaaaaaaaaaaaaa'; files = @() }
    Assert-CcodThrows { Assert-CcodInstalledLifecycleRuntimeManifest -Manifest $mismatch -ExpectedVersion '2.5.22' -ExpectedRuntimeId $mismatch.runtimeId } 'CCOD_INTEGRATION_OBSERVATION_UNAVAILABLE'
}

Write-Host 'Installed lifecycle harness self-tests passed.'
