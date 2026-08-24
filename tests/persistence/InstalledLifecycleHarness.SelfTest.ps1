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
    param([string]$Version = '2.5.0')
    return [pscustomobject][ordered]@{
        appPresent = $true
        activeRuntimeId = 'runtime-1'
        activeGeneration = [UInt64]1
        runtimeManifestSha256 = ('a' * 64)
        supervisor = @([pscustomobject]@{ pid = 100; creationTimeUtc = '2026-08-24T00:00:00.0000000Z' })
        trayHost = @([pscustomobject]@{ pid = 101; creationTimeUtc = '2026-08-24T00:00:01.0000000Z' })
        codex = @([pscustomobject]@{ pid = 102; creationTimeUtc = '2026-08-24T00:00:02.0000000Z' })
        taskState = 'Ready'
        statusPhase = 'Active'
        transitionStage = 'Completed'
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
