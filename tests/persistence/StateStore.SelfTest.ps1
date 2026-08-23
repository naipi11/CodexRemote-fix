$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestSupport.ps1')

$repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module (Join-Path $repositoryRoot 'src\persistence\modules\StateStore.psm1') -Force
Import-Module (Join-Path $repositoryRoot 'src\persistence\modules\LifecycleTransaction.psm1') -Force

function New-CcodStateTestAdapters {
    $fixedUtc = [DateTime]::Parse('2030-02-03T04:05:06.0000000Z').ToUniversalTime()
    return @{
        UtcNow = { $fixedUtc }.GetNewClosure()
        NewGuid = { [Guid]'11111111-2222-3333-4444-555555555555' }
        TestVerifiedNodeCandidate = { param($Path) $Path -eq 'C:\Node\node.exe' }
    }
}

function New-CcodPermissiveNodeTestAdapters {
    $adapters = New-CcodStateTestAdapters
    $adapters.TestVerifiedNodeCandidate = { param($Path) $true }
    return $adapters
}

function Initialize-CcodStateFixture([string]$StateRoot) {
    Initialize-CcodState -StateRoot $StateRoot -NodeCandidates @('C:\Node\node.exe') -CandidateCompatibleOptIn $true -Adapters (New-CcodStateTestAdapters) | Out-Null
}

function Set-CcodStateDamage([string]$StateRoot, [string]$Leaf, [string]$Variant) {
    $path = Join-Path $StateRoot $Leaf
    switch ($Variant) {
        'missing' { [IO.File]::Delete($path) }
        'malformed' { [IO.File]::WriteAllText($path, '{broken', [Text.UTF8Encoding]::new($false)) }
        'unknown-schema' {
            $value = [ordered]@{ schemaVersion = 99; ignored = $true }
            [IO.File]::WriteAllText($path, ($value | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
        }
        default { throw "Unknown damage variant: $Variant" }
    }
}

function Write-CcodStateJson([string]$StateRoot, [string]$Leaf, $Value) {
    [IO.File]::WriteAllText((Join-Path $StateRoot $Leaf), ($Value | ConvertTo-Json -Depth 16 -Compress), [Text.UTF8Encoding]::new($false))
}

function New-CcodTransitionFixture {
    return [ordered]@{
        transactionId = '5f496d99-c839-4458-a6a2-d37ea1afdbda'
        stage = 'IntentWritten'
        sourcePid = 101
        sourceCreationTimeUtc = '2030-02-03T04:05:06.0000000Z'
        packageFullName = 'pkg'
        appAsarSha256 = ('a' * 64)
        runtimeId = 'runtime-1'
        mainPort = 41001
        rendererPort = 41002
        specialPid = $null
        specialCreationTimeUtc = $null
        recoveryPid = $null
        recoveryCreationTimeUtc = $null
        createdAtUtc = '2030-02-03T04:05:06.0000000Z'
        updatedAtUtc = '2030-02-03T04:05:06.0000000Z'
    }
}

function New-CcodStatusSession {
    return [ordered]@{
        supervisorPid = 11
        supervisorCreationTimeUtc = '2030-02-03T04:05:06.0000000Z'
        sessionId = 'session-1'
        runtimeId = 'runtime-1'
        sessionState = 'Active'
        codex = [ordered]@{
            pid = 22
            creationTimeUtc = '2030-02-03T04:05:06.0000000Z'
            packageFullName = 'pkg'
            packageVersion = '1.0.0.0'
            appAsarSha256 = ('a' * 64)
            mainPort = 41001
            rendererPort = 41002
            mainProbe = 'Closed'
            rendererProbe = 'BridgeValid'
        }
    }
}

function New-CcodStatusFixture {
    return [ordered]@{ schemaVersion = 1; session = (New-CcodStatusSession) }
}

function New-CcodLiveProbeFixture {
    $session = New-CcodStatusSession
    return [pscustomobject]@{
        Valid = $true
        runtimeId = $session.runtimeId
        pid = $session.codex.pid
        creationTimeUtc = $session.codex.creationTimeUtc
        packageFullName = $session.codex.packageFullName
        packageVersion = $session.codex.packageVersion
        appAsarSha256 = $session.codex.appAsarSha256
        mainPort = $session.codex.mainPort
        rendererPort = $session.codex.rendererPort
        mainProbe = $session.codex.mainProbe
        rendererProbe = $session.codex.rendererProbe
    }
}

function New-CcodVerifiedRecord {
    return [ordered]@{
        packageFullName = 'pkg'
        packageVersion = '1.0.0.0'
        appAsarSha256 = ('a' * 64)
        runtimeId = 'runtime-1'
        staticClassification = 'CandidateCompatible'
        dynamicOutcome = 'Failed'
        probeState = 'Invalid'
        confirmedAtUtc = '2030-02-03T04:05:06.0000000Z'
    }
}

function Assert-CcodFailedAttemptClearReceipt {
    param($Receipt, [Parameter(Mandatory)][string]$Outcome, [Parameter(Mandatory)][string]$Message)

    Assert-CcodTrue ($null -ne $Receipt) "$Message returns a receipt"
    Assert-CcodEqual 'Outcome' (($Receipt.PSObject.Properties.Name) -join ',') "$Message receipt has one bounded exact field"
    Assert-CcodEqual $Outcome $Receipt.Outcome "$Message receipt outcome"
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-state-selftest-' + [Guid]::NewGuid().ToString('N'))
try {
    Invoke-CcodTest 'initializes independent automation consent and installer-verified absolute Node paths' {
        $state = Join-Path $root 'initial'
        Initialize-CcodStateFixture -StateRoot $state
        $loaded = Read-CcodState -StateRoot $state -CurrentSuppressionKey 'pkg|hash|runtime' -Adapters (New-CcodStateTestAdapters)

        Assert-CcodEqual $true $loaded.Settings.automationEnabled 'fresh explicit install enables automation'
        Assert-CcodEqual $true $loaded.Settings.candidateCompatibleOptIn 'opt-in persists independently from automation'
        Assert-CcodEqual 'C:\Node\node.exe' $loaded.Settings.nodeCandidates[0] 'only the installer supplied candidate is persisted'
        Assert-CcodEqual $true $loaded.AutomaticCandidateTrialsAllowed 'healthy explicit consent and verified history permit a trial'
        Assert-CcodEqual $true $loaded.TransitionActionsAllowed 'healthy initialized transition store permits actions'
        Assert-CcodEqual '2030-02-03T04:05:06.0000000Z' $loaded.Settings.updatedAtUtc 'state uses injected UTC clock'
        Assert-CcodThrows { Initialize-CcodState -StateRoot (Join-Path $root 'relative-node') -NodeCandidates @('node.exe') -Adapters (New-CcodStateTestAdapters) } 'CCOD_NODE_CANDIDATE_INVALID'
    }

    Invoke-CcodTest 'migrates an initialized 2.4 state root only by creating idle lifecycle storage' {
        $state = Join-Path $root 'lifecycle-migration'
        Initialize-CcodStateFixture -StateRoot $state
        $preserved = @{}
        foreach ($leaf in @('settings.json', 'status.json', 'verified-packages.json', 'transition.json')) {
            $preserved[$leaf] = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $state $leaf)))
        }
        $preferencesPath = Join-Path $state 'ui-preferences.json'
        [IO.File]::WriteAllText($preferencesPath, '{"preserved":true}', [Text.UTF8Encoding]::new($false))
        $preferenceBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($preferencesPath))

        Initialize-CcodState -StateRoot $state -Adapters (New-CcodStateTestAdapters) | Out-Null

        Assert-CcodTrue ([IO.Directory]::Exists((Join-Path $state 'lifecycle\receipts'))) 'migration creates lifecycle receipt storage'
        Assert-CcodEqual $null (Read-CcodLifecycleRequest -StateRoot $state) 'migration creates no active lifecycle request'
        foreach ($leaf in $preserved.Keys) {
            Assert-CcodEqual $preserved[$leaf] ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $state $leaf))) ) "$leaf bytes remain untouched by lifecycle migration"
        }
        Assert-CcodEqual $preferenceBytes ([Convert]::ToBase64String([IO.File]::ReadAllBytes($preferencesPath))) 'UI preferences remain untouched by lifecycle migration'

        [IO.File]::WriteAllText((Join-Path $state 'lifecycle\active-request.json'), '{broken', [Text.UTF8Encoding]::new($false))
        Assert-CcodThrows { Initialize-CcodState -StateRoot $state -Adapters (New-CcodStateTestAdapters) } 'CCOD_LIFECYCLE_STATE_INVALID'
    }

    Invoke-CcodTest 'fails closed for every missing malformed and unknown-schema state file' {
        $rules = @(
            [pscustomobject]@{ Leaf = 'settings.json'; ExpectedAutomation = $false; ExpectedTrial = $false; ExpectedTransition = $true },
            [pscustomobject]@{ Leaf = 'verified-packages.json'; ExpectedAutomation = $true; ExpectedTrial = $false; ExpectedTransition = $true },
            [pscustomobject]@{ Leaf = 'transition.json'; ExpectedAutomation = $false; ExpectedTrial = $false; ExpectedTransition = $false },
            [pscustomobject]@{ Leaf = 'status.json'; ExpectedAutomation = $true; ExpectedTrial = $false; ExpectedTransition = $true }
        )
        foreach ($rule in $rules) {
            foreach ($variant in @('missing', 'malformed', 'unknown-schema')) {
                $state = Join-Path $root ("damage-$($rule.Leaf)-$variant")
                Initialize-CcodStateFixture -StateRoot $state
                Set-CcodStateDamage -StateRoot $state -Leaf $rule.Leaf -Variant $variant
                $loaded = Read-CcodState -StateRoot $state -Adapters (New-CcodStateTestAdapters)

                Assert-CcodEqual $rule.ExpectedAutomation $loaded.AutomationEnabled "$($rule.Leaf) $variant applies the correct automation default"
                Assert-CcodEqual $rule.ExpectedTrial $loaded.AutomaticCandidateTrialsAllowed "$($rule.Leaf) $variant applies the correct candidate-trial default"
                Assert-CcodEqual $rule.ExpectedTransition $loaded.TransitionActionsAllowed "$($rule.Leaf) $variant applies the correct transition-action default"
                Assert-CcodTrue ($loaded.Damage.PSObject.Properties[$rule.Leaf] -ne $null) "$($rule.Leaf) $variant is reported as damage"
                if ($variant -ne 'missing') {
                    $quarantine = @(Get-ChildItem -LiteralPath $state -File -Filter ($rule.Leaf + '.corrupt.*'))
                    Assert-CcodEqual 1 $quarantine.Count "$($rule.Leaf) $variant is quarantined instead of silently overwritten"
                }
            }
        }
    }

    Invoke-CcodTest 'requires a live probe before rebuilding damaged status' {
        $state = Join-Path $root 'status-rebuild'
        Initialize-CcodStateFixture -StateRoot $state
        Set-CcodStateDamage -StateRoot $state -Leaf 'status.json' -Variant 'malformed'
        $damaged = Read-CcodState -StateRoot $state -Adapters (New-CcodStateTestAdapters)
        Assert-CcodEqual $true $damaged.StatusRebuildRequired 'damaged status is not trusted as a usable ordinary-session record'
        Assert-CcodThrows { Write-CcodStatus -StateRoot $state -Status (New-CcodStatusFixture) } 'CCOD_LIVE_PROBE_REQUIRED'
        $status = New-CcodStatusFixture
        $mismatchedProbe = New-CcodLiveProbeFixture
        $mismatchedProbe.rendererPort = 49999
        Assert-CcodThrows { Write-CcodStatus -StateRoot $state -Status $status -LiveProbeResult $mismatchedProbe } 'CCOD_LIVE_PROBE_MISMATCH'
        Write-CcodStatus -StateRoot $state -Status $status -LiveProbeResult (New-CcodLiveProbeFixture) | Out-Null
        Assert-CcodEqual 'Active' (Read-CcodStatus -StateRoot $state -Adapters (New-CcodStateTestAdapters)).session.sessionState 'a matching complete live probe permits status reconstruction'
    }

    Invoke-CcodTest 'quarantines invalid status and verified semantic combinations' {
        $statusCases = @(
            [pscustomobject]@{ Name = 'unknown state'; Mutate = { param($status) $status.session.sessionState = 'Whatever' } },
            [pscustomobject]@{ Name = 'codex ordinary'; Mutate = { param($status) $status.session.sessionState = 'Ordinary' } },
            [pscustomobject]@{ Name = 'active without codex'; Mutate = { param($status) $status.session.codex = $null } },
            [pscustomobject]@{ Name = 'open main inspector'; Mutate = { param($status) $status.session.codex.mainProbe = 'Open' } },
            [pscustomobject]@{ Name = 'invalid renderer bridge'; Mutate = { param($status) $status.session.codex.rendererProbe = 'Valid' } }
        )
        foreach ($case in $statusCases) {
            $state = Join-Path $root ('status-semantic-' + $case.Name.Replace(' ', '-'))
            Initialize-CcodStateFixture -StateRoot $state
            $status = New-CcodStatusFixture
            & $case.Mutate $status
            Write-CcodStateJson -StateRoot $state -Leaf 'status.json' -Value $status
            $loaded = Read-CcodState -StateRoot $state -Adapters (New-CcodStateTestAdapters)
            Assert-CcodEqual $true $loaded.StatusRebuildRequired "$($case.Name) status is not adopted"
            Assert-CcodEqual 1 @(Get-ChildItem -LiteralPath $state -File -Filter 'status.json.corrupt.*').Count "$($case.Name) status is quarantined"
        }
        $verifiedCases = @(
            [pscustomobject]@{ Name = 'success invalid probe'; Static = 'CandidateCompatible'; Outcome = 'Succeeded'; Probe = 'Invalid' },
            [pscustomobject]@{ Name = 'failure valid probe'; Static = 'CandidateCompatible'; Outcome = 'Failed'; Probe = 'Valid' },
            [pscustomobject]@{ Name = 'native success'; Static = 'NativeModulePresent'; Outcome = 'Succeeded'; Probe = 'Valid' },
            [pscustomobject]@{ Name = 'unknown success'; Static = 'UnknownOrIncompatible'; Outcome = 'Succeeded'; Probe = 'Valid' }
        )
        foreach ($case in $verifiedCases) {
            $state = Join-Path $root ('verified-semantic-' + $case.Name.Replace(' ', '-'))
            Initialize-CcodStateFixture -StateRoot $state
            $key = 'pkg|aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa|runtime-1'
            $record = New-CcodVerifiedRecord
            $record.staticClassification = $case.Static
            $record.dynamicOutcome = $case.Outcome
            $record.probeState = $case.Probe
            Write-CcodStateJson -StateRoot $state -Leaf 'verified-packages.json' -Value ([ordered]@{ schemaVersion = 1; packages = [ordered]@{ $key = $record } })
            $loaded = Read-CcodState -StateRoot $state -Adapters (New-CcodStateTestAdapters)
            Assert-CcodEqual $false $loaded.AutomaticCandidateTrialsAllowed "$($case.Name) cannot authorize another trial"
            Assert-CcodEqual 1 @(Get-ChildItem -LiteralPath $state -File -Filter 'verified-packages.json.corrupt.*').Count "$($case.Name) verified record is quarantined"
        }
    }

    Invoke-CcodTest 'quarantines case-variant fixed enums and rejects extra live-probe fields' {
        $statusCases = @(
            [pscustomobject]@{ Name = 'lowercase session state'; Mutate = { param($status) $status.session.sessionState = 'active' } },
            [pscustomobject]@{ Name = 'lowercase main probe'; Mutate = { param($status) $status.session.codex.mainProbe = 'closed' } },
            [pscustomobject]@{ Name = 'mixed renderer probe'; Mutate = { param($status) $status.session.codex.rendererProbe = 'bridgeValid' } }
        )
        foreach ($case in $statusCases) {
            $state = Join-Path $root ('status-case-' + [Guid]::NewGuid().ToString('N'))
            Initialize-CcodStateFixture -StateRoot $state
            $status = New-CcodStatusFixture
            & $case.Mutate $status
            Write-CcodStateJson -StateRoot $state -Leaf 'status.json' -Value $status
            $loaded = Read-CcodState -StateRoot $state -Adapters (New-CcodStateTestAdapters)
            Assert-CcodEqual $true $loaded.StatusRebuildRequired "$($case.Name) cannot be adopted"
            Assert-CcodEqual 1 @(Get-ChildItem -LiteralPath $state -File -Filter 'status.json.corrupt.*').Count "$($case.Name) status is quarantined"
        }
        $verifiedCases = @(
            [pscustomobject]@{ Name = 'lowercase classification'; Field = 'staticClassification'; Value = 'candidatecompatible' },
            [pscustomobject]@{ Name = 'lowercase outcome'; Field = 'dynamicOutcome'; Value = 'failed' },
            [pscustomobject]@{ Name = 'lowercase probe'; Field = 'probeState'; Value = 'invalid' }
        )
        foreach ($case in $verifiedCases) {
            $state = Join-Path $root ('verified-case-' + [Guid]::NewGuid().ToString('N'))
            Initialize-CcodStateFixture -StateRoot $state
            $key = 'pkg|aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa|runtime-1'
            $record = New-CcodVerifiedRecord
            $record[$case.Field] = $case.Value
            Write-CcodStateJson -StateRoot $state -Leaf 'verified-packages.json' -Value ([ordered]@{ schemaVersion = 1; packages = [ordered]@{ $key = $record } })
            $loaded = Read-CcodState -StateRoot $state -Adapters (New-CcodStateTestAdapters)
            Assert-CcodEqual $false $loaded.AutomaticCandidateTrialsAllowed "$($case.Name) cannot authorize a trial"
            Assert-CcodEqual 1 @(Get-ChildItem -LiteralPath $state -File -Filter 'verified-packages.json.corrupt.*').Count "$($case.Name) verified evidence is quarantined"
        }
        $state = Join-Path $root 'transition-case'
        Initialize-CcodStateFixture -StateRoot $state
        $transaction = New-CcodTransitionFixture
        $transaction.stage = 'intentwritten'
        Write-CcodStateJson -StateRoot $state -Leaf 'transition.json' -Value ([ordered]@{ schemaVersion = 1; activeTransaction = $transaction })
        $loaded = Read-CcodState -StateRoot $state -Adapters (New-CcodStateTestAdapters)
        Assert-CcodEqual $false $loaded.TransitionActionsAllowed 'lowercase transition stage forbids actions'
        Assert-CcodEqual 1 @(Get-ChildItem -LiteralPath $state -File -Filter 'transition.json.corrupt.*').Count 'lowercase transition stage is quarantined'

        $liveState = Join-Path $root 'live-probe-extra'
        Initialize-CcodStateFixture -StateRoot $liveState
        $probe = New-CcodLiveProbeFixture
        $probe | Add-Member -NotePropertyName unexpected -NotePropertyValue 'extra'
        Assert-CcodThrows { Write-CcodStatus -StateRoot $liveState -Status (New-CcodStatusFixture) -LiveProbeResult $probe } 'CCOD_LIVE_PROBE_INVALID'
        Assert-CcodEqual $null (Read-CcodStatus -StateRoot $liveState -Adapters (New-CcodStateTestAdapters)).session 'extra probe data leaves existing status intact'
    }

    Invoke-CcodTest 'rejects coercive live-probe types and case changes before writing status' {
        $state = Join-Path $root 'live-probe-types'
        Initialize-CcodStateFixture -StateRoot $state
        $badCases = @(
            [pscustomobject]@{ Name = 'numeric valid'; Field = 'Valid'; Value = 1; ErrorId = 'CCOD_LIVE_PROBE_INVALID' },
            [pscustomobject]@{ Name = 'string valid'; Field = 'Valid'; Value = 'True'; ErrorId = 'CCOD_LIVE_PROBE_INVALID' },
            [pscustomobject]@{ Name = 'string PID'; Field = 'pid'; Value = '22'; ErrorId = 'CCOD_LIVE_PROBE_INVALID' },
            [pscustomobject]@{ Name = 'string port'; Field = 'rendererPort'; Value = '41002'; ErrorId = 'CCOD_LIVE_PROBE_INVALID' },
            [pscustomobject]@{ Name = 'case package'; Field = 'packageFullName'; Value = 'PKG'; ErrorId = 'CCOD_LIVE_PROBE_MISMATCH' },
            [pscustomobject]@{ Name = 'case hash'; Field = 'appAsarSha256'; Value = ('A' * 64); ErrorId = 'CCOD_LIVE_PROBE_INVALID' },
            [pscustomobject]@{ Name = 'case runtime'; Field = 'runtimeId'; Value = 'RUNTIME-1'; ErrorId = 'CCOD_LIVE_PROBE_MISMATCH' }
        )
        foreach ($case in $badCases) {
            $probe = New-CcodLiveProbeFixture
            $probe.($case.Field) = $case.Value
            Assert-CcodThrows { Write-CcodStatus -StateRoot $state -Status (New-CcodStatusFixture) -LiveProbeResult $probe } $case.ErrorId
        }
        Assert-CcodEqual $null (Read-CcodStatus -StateRoot $state -Adapters (New-CcodStateTestAdapters)).session 'invalid probes leave the existing empty status intact'
    }

    Invoke-CcodTest 'quarantines noncanonical Node candidate paths even when installer evidence accepts them' {
        foreach ($candidate in @('C:\Node\.\node.exe', 'C:\Node\child\..\node.exe', 'C:\Node\\node.exe')) {
            $state = Join-Path $root ('node-canonical-' + [Guid]::NewGuid().ToString('N'))
            Initialize-CcodStateFixture -StateRoot $state
            Write-CcodStateJson -StateRoot $state -Leaf 'settings.json' -Value ([ordered]@{ schemaVersion = 1; automationEnabled = $true; candidateCompatibleOptIn = $true; nodeCandidates = @($candidate); updatedAtUtc = '2030-02-03T04:05:06.0000000Z' })
            $loaded = Read-CcodState -StateRoot $state -Adapters (New-CcodPermissiveNodeTestAdapters)
            Assert-CcodEqual $false $loaded.AutomationEnabled "$candidate cannot reauthorize automation"
            Assert-CcodEqual 1 @(Get-ChildItem -LiteralPath $state -File -Filter 'settings.json.corrupt.*').Count "$candidate settings evidence is quarantined"
        }
    }

    Invoke-CcodTest 'quarantines every invalid transition shape and disables all actions' {
        $badCases = @(
            [pscustomobject]@{ Name = 'empty transaction'; Field = $null; Value = [ordered]@{} },
            [pscustomobject]@{ Name = 'transaction ID'; Field = 'transactionId'; Value = 1 },
            [pscustomobject]@{ Name = 'stage'; Field = 'stage'; Value = 'BadStage' },
            [pscustomobject]@{ Name = 'source PID'; Field = 'sourcePid'; Value = '101' },
            [pscustomobject]@{ Name = 'source creation'; Field = 'sourceCreationTimeUtc'; Value = 'not-a-time' },
            [pscustomobject]@{ Name = 'package full name'; Field = 'packageFullName'; Value = 1 },
            [pscustomobject]@{ Name = 'asar hash'; Field = 'appAsarSha256'; Value = 'not-a-hash' },
            [pscustomobject]@{ Name = 'runtime ID'; Field = 'runtimeId'; Value = 1 },
            [pscustomobject]@{ Name = 'main port'; Field = 'mainPort'; Value = 0 },
            [pscustomobject]@{ Name = 'renderer port'; Field = 'rendererPort'; Value = 41001 },
            [pscustomobject]@{ Name = 'special PID'; Field = 'specialPid'; Value = '22' },
            [pscustomobject]@{ Name = 'special creation'; Field = 'specialCreationTimeUtc'; Value = 'not-a-time' },
            [pscustomobject]@{ Name = 'recovery PID'; Field = 'recoveryPid'; Value = '33' },
            [pscustomobject]@{ Name = 'recovery creation'; Field = 'recoveryCreationTimeUtc'; Value = 'not-a-time' },
            [pscustomobject]@{ Name = 'created time'; Field = 'createdAtUtc'; Value = 'not-a-time' },
            [pscustomobject]@{ Name = 'updated time'; Field = 'updatedAtUtc'; Value = 'not-a-time' }
        )
        foreach ($case in $badCases) {
            $state = Join-Path $root ('transition-' + $case.Name.Replace(' ', '-'))
            Initialize-CcodStateFixture -StateRoot $state
            $transaction = New-CcodTransitionFixture
            if ($null -eq $case.Field) { $transaction = $case.Value } else { $transaction[$case.Field] = $case.Value }
            Write-CcodStateJson -StateRoot $state -Leaf 'transition.json' -Value ([ordered]@{ schemaVersion = 1; activeTransaction = $transaction })
            $loaded = Read-CcodState -StateRoot $state -Adapters (New-CcodStateTestAdapters)
            Assert-CcodEqual $false $loaded.AutomationEnabled "$($case.Name) transition disables automation"
            Assert-CcodEqual $false $loaded.TransitionActionsAllowed "$($case.Name) transition forbids stop/start/recover"
            Assert-CcodTrue ($loaded.Damage.PSObject.Properties['transition.json'] -ne $null) "$($case.Name) transition is recorded as damage"
            Assert-CcodEqual 1 @(Get-ChildItem -LiteralPath $state -File -Filter 'transition.json.corrupt.*').Count "$($case.Name) transition is quarantined"
        }
    }

    Invoke-CcodTest 'accepts a manual intent before source and debug ports exist' {
        $state = Join-Path $root 'manual-transition-null-pairs'
        Initialize-CcodStateFixture -StateRoot $state
        $transaction = New-CcodTransitionFixture
        $transaction.sourcePid = $null
        $transaction.sourceCreationTimeUtc = $null
        $transaction.mainPort = $null
        $transaction.rendererPort = $null
        Write-CcodStateJson -StateRoot $state -Leaf 'transition.json' -Value ([ordered]@{ schemaVersion = 1; activeTransaction = $transaction })

        $loaded = Read-CcodState -StateRoot $state -Adapters (New-CcodStateTestAdapters)
        Assert-CcodEqual $true $loaded.TransitionActionsAllowed 'manual transition remains actionable before port allocation'
        Assert-CcodEqual $null $loaded.Transition.activeTransaction.sourcePid 'manual source pair stays null'
        Assert-CcodEqual $null $loaded.Transition.activeTransaction.mainPort 'unallocated port pair stays null'
    }

    Invoke-CcodTest 'cross-reads exact ordinary and special durable close transactions without adding a field' {
        $cases = @(
            @{ Name='ordinary-close-requested'; Stage='CloseRequested'; Source=$true; Special=$false; Ports=$false },
            @{ Name='ordinary-closed'; Stage='Closed'; Source=$true; Special=$false; Ports=$false },
            @{ Name='special-close-requested'; Stage='CloseRequested'; Source=$false; Special=$true; Ports=$true },
            @{ Name='special-closed'; Stage='Closed'; Source=$false; Special=$true; Ports=$true }
        )
        foreach ($case in $cases) {
            $state = Join-Path $root $case.Name
            Initialize-CcodStateFixture -StateRoot $state
            $transaction = New-CcodTransitionFixture
            $transaction.stage = $case.Stage
            if (-not $case.Source) {
                $transaction.sourcePid = $null
                $transaction.sourceCreationTimeUtc = $null
            }
            if ($case.Special) {
                $transaction.specialPid = 202
                $transaction.specialCreationTimeUtc = '2030-02-03T04:05:07.0000000Z'
            }
            if (-not $case.Ports) {
                $transaction.mainPort = $null
                $transaction.rendererPort = $null
            }
            Write-CcodStateJson -StateRoot $state -Leaf 'transition.json' -Value ([ordered]@{ schemaVersion=1; activeTransaction=$transaction })

            $loaded = Read-CcodState -StateRoot $state -Adapters (New-CcodStateTestAdapters)
            Assert-CcodEqual $true $loaded.TransitionActionsAllowed "$($case.Name) remains actionable"
            Assert-CcodEqual 15 @($loaded.Transition.activeTransaction.PSObject.Properties).Count "$($case.Name) preserves the fixed field count"
            Assert-CcodEqual $case.Stage $loaded.Transition.activeTransaction.stage "$($case.Name) preserves the exact close stage"
        }
    }

    Invoke-CcodTest 'quarantines illegal durable close target identity and port shapes' {
        $cases = @(
            @{ Name='close-no-root'; Mutate={ param($tx) $tx.stage='CloseRequested'; $tx.sourcePid=$null; $tx.sourceCreationTimeUtc=$null; $tx.mainPort=$null; $tx.rendererPort=$null } },
            @{ Name='close-both-roots'; Mutate={ param($tx) $tx.stage='CloseRequested'; $tx.specialPid=202; $tx.specialCreationTimeUtc='2030-02-03T04:05:07.0000000Z' } },
            @{ Name='ordinary-close-with-ports'; Mutate={ param($tx) $tx.stage='Closed' } },
            @{ Name='special-close-without-ports'; Mutate={ param($tx) $tx.stage='Closed'; $tx.sourcePid=$null; $tx.sourceCreationTimeUtc=$null; $tx.specialPid=202; $tx.specialCreationTimeUtc='2030-02-03T04:05:07.0000000Z'; $tx.mainPort=$null; $tx.rendererPort=$null } },
            @{ Name='close-with-recovery'; Mutate={ param($tx) $tx.stage='Closed'; $tx.mainPort=$null; $tx.rendererPort=$null; $tx.recoveryPid=303; $tx.recoveryCreationTimeUtc='2030-02-03T04:05:08.0000000Z' } }
        )
        foreach ($case in $cases) {
            $state = Join-Path $root ('invalid-' + $case.Name)
            Initialize-CcodStateFixture -StateRoot $state
            $transaction = New-CcodTransitionFixture
            & $case.Mutate $transaction
            Write-CcodStateJson -StateRoot $state -Leaf 'transition.json' -Value ([ordered]@{ schemaVersion=1; activeTransaction=$transaction })

            $loaded = Read-CcodState -StateRoot $state -Adapters (New-CcodStateTestAdapters)
            Assert-CcodEqual $false $loaded.TransitionActionsAllowed "$($case.Name) cannot authorize process action"
            Assert-CcodEqual 1 @(Get-ChildItem -LiteralPath $state -File -Filter 'transition.json.corrupt.*').Count "$($case.Name) is quarantined"
        }
    }

    Invoke-CcodTest 'quarantines semantically inconsistent transition stages and identities' {
        $cases = @(
            @{ Name='noncanonical-guid'; Mutate={ param($tx) $tx.transactionId = '5F496D99-C839-4458-A6A2-D37EA1AFDBDA' } },
            @{ Name='updated-before-created'; Mutate={ param($tx) $tx.updatedAtUtc = '2030-02-03T04:05:05.0000000Z' } },
            @{ Name='manual-stop-requested'; Mutate={ param($tx) $tx.sourcePid=$null; $tx.sourceCreationTimeUtc=$null; $tx.stage='StopRequested' } },
            @{ Name='early-special-identity'; Mutate={ param($tx) $tx.specialPid=201; $tx.specialCreationTimeUtc='2030-02-03T04:05:06.0000000Z' } },
            @{ Name='special-started-without-identity'; Mutate={ param($tx) $tx.stage='SpecialStarted' } },
            @{ Name='validated-without-identity'; Mutate={ param($tx) $tx.stage='Validated' } },
            @{ Name='special-launch-without-ports'; Mutate={ param($tx) $tx.stage='SpecialLaunchRequested'; $tx.mainPort=$null; $tx.rendererPort=$null } },
            @{ Name='recovery-special-without-ports'; Mutate={ param($tx) $tx.stage='RecoveryLaunchRequested'; $tx.mainPort=$null; $tx.rendererPort=$null; $tx.specialPid=201; $tx.specialCreationTimeUtc='2030-02-03T04:05:06.0000000Z' } },
            @{ Name='source-pid-over-int32'; Mutate={ param($tx) $tx.sourcePid=[long]2147483648 } },
            @{ Name='early-recovery-identity'; Mutate={ param($tx) $tx.recoveryPid=301; $tx.recoveryCreationTimeUtc='2030-02-03T04:05:06.0000000Z' } },
            @{ Name='recovered-without-identity'; Mutate={ param($tx) $tx.stage='Recovered' } }
        )
        foreach ($case in $cases) {
            $state = Join-Path $root ('transition-semantic-' + $case.Name)
            Initialize-CcodStateFixture -StateRoot $state
            $transaction = New-CcodTransitionFixture
            & $case.Mutate $transaction
            Write-CcodStateJson -StateRoot $state -Leaf 'transition.json' -Value ([ordered]@{ schemaVersion=1; activeTransaction=$transaction })

            $loaded = Read-CcodState -StateRoot $state -Adapters (New-CcodStateTestAdapters)
            Assert-CcodEqual $false $loaded.TransitionActionsAllowed "$($case.Name) cannot authorize transition actions"
            Assert-CcodEqual 1 @(Get-ChildItem -LiteralPath $state -File -Filter 'transition.json.corrupt.*').Count "$($case.Name) is quarantined"
        }
    }

    Invoke-CcodTest 'quarantines strict status verified and settings schema violations' {
        $cases = @(
            [pscustomobject]@{ Leaf = 'status.json'; Value = [ordered]@{ schemaVersion = 1; session = [ordered]@{} }; Flag = 'StatusRebuildRequired' },
            [pscustomobject]@{ Leaf = 'verified-packages.json'; Value = [ordered]@{ schemaVersion = 1; packages = [ordered]@{ 'wrong|key|value' = (New-CcodVerifiedRecord) } }; Flag = 'AutomaticCandidateTrialsAllowed' },
            [pscustomobject]@{ Leaf = 'verified-packages.json'; Value = [ordered]@{ schemaVersion = 1; packages = [ordered]@{ 'pkg|aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa|runtime-1' = ([ordered]@{ packageFullName='pkg'; packageVersion='1.0.0.0'; appAsarSha256=('a' * 64); runtimeId='runtime-1'; staticClassification='CandidateCompatible'; dynamicOutcome='Failed'; probeState='Invalid'; confirmedAtUtc='bad' }) } }; Flag = 'AutomaticCandidateTrialsAllowed' },
            [pscustomobject]@{ Leaf = 'settings.json'; Value = [ordered]@{ schemaVersion = '1'; automationEnabled=$true; candidateCompatibleOptIn=$true; nodeCandidates=@('C:\Node\node.exe'); updatedAtUtc='2030-02-03T04:05:06.0000000Z' }; Flag = 'AutomationEnabled' },
            [pscustomobject]@{ Leaf = 'settings.json'; Value = [ordered]@{ schemaVersion = 1; automationEnabled=$true; candidateCompatibleOptIn=$true; nodeCandidates='C:\Node\node.exe'; updatedAtUtc='2030-02-03T04:05:06.0000000Z' }; Flag = 'AutomationEnabled' },
            [pscustomobject]@{ Leaf = 'settings.json'; Value = [ordered]@{ schemaVersion = 1; automationEnabled=$true; candidateCompatibleOptIn=$true; nodeCandidates=@('C:node.exe'); updatedAtUtc='2030-02-03T04:05:06.0000000Z' }; Flag = 'AutomationEnabled' },
            [pscustomobject]@{ Leaf = 'settings.json'; Value = [ordered]@{ schemaVersion = 1; automationEnabled=$true; candidateCompatibleOptIn=$true; nodeCandidates=@('\\Node\node.exe'); updatedAtUtc='2030-02-03T04:05:06.0000000Z' }; Flag = 'AutomationEnabled' },
            [pscustomobject]@{ Leaf = 'settings.json'; Value = [ordered]@{ schemaVersion = 1; automationEnabled=$true; candidateCompatibleOptIn=$true; nodeCandidates=@('C:\Node\node.exe'); updatedAtUtc='2030-02-03T04:05:06Z' }; Flag = 'AutomationEnabled' }
        )
        foreach ($case in $cases) {
            $state = Join-Path $root ('strict-' + $case.Leaf + '-' + [Guid]::NewGuid().ToString('N'))
            Initialize-CcodStateFixture -StateRoot $state
            Write-CcodStateJson -StateRoot $state -Leaf $case.Leaf -Value $case.Value
            $loaded = Read-CcodState -StateRoot $state -Adapters (New-CcodStateTestAdapters)
            Assert-CcodTrue ($loaded.Damage.PSObject.Properties[$case.Leaf] -ne $null) "$($case.Leaf) invalid shape is damage"
            Assert-CcodEqual 1 @(Get-ChildItem -LiteralPath $state -File -Filter ($case.Leaf + '.corrupt.*')).Count "$($case.Leaf) invalid shape is quarantined"
        }
    }

    Invoke-CcodTest 'suppresses a previously attempted current package build key' {
        $state = Join-Path $root 'suppression-history'
        Initialize-CcodStateFixture -StateRoot $state
        $key = 'pkg|aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa|runtime-1'
        Write-CcodStateJson -StateRoot $state -Leaf 'verified-packages.json' -Value ([ordered]@{ schemaVersion = 1; packages = [ordered]@{ $key = (New-CcodVerifiedRecord) } })
        $loaded = Read-CcodState -StateRoot $state -CurrentSuppressionKey $key -Adapters (New-CcodStateTestAdapters)
        Assert-CcodEqual $false $loaded.AutomaticCandidateTrialsAllowed 'any recorded outcome suppresses another automatic trial for the same build'
        Assert-CcodEqual $false (Read-CcodState -StateRoot $state -Adapters (New-CcodStateTestAdapters)).AutomaticCandidateTrialsAllowed 'no current build key cannot authorize a trial'
    }

    Invoke-CcodTest 'clears only one exact failed package attempt and preserves unrelated history' {
        $state = Join-Path $root 'clear-failed-exact'
        Initialize-CcodStateFixture -StateRoot $state
        $targetKey = 'pkg|aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa|runtime-1'
        $otherKey = 'other.pkg|bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb|runtime-2'
        $other = New-CcodVerifiedRecord
        $other.packageFullName = 'other.pkg'
        $other.packageVersion = '2.0.0.0'
        $other.appAsarSha256 = ('b' * 64)
        $other.runtimeId = 'runtime-2'
        $other.confirmedAtUtc = '2030-02-03T04:05:07.0000000Z'
        Write-CcodStateJson -StateRoot $state -Leaf 'verified-packages.json' -Value ([ordered]@{
            schemaVersion = 1
            packages = [ordered]@{
                $targetKey = (New-CcodVerifiedRecord)
                $otherKey = $other
            }
        })

        $receipt = Clear-CcodFailedPackageAttempt -StateRoot $state -PackageFullName 'pkg' -AppAsarSha256 ('a' * 64) -RuntimeId 'runtime-1' -ExpectedConfirmedAtUtc '2030-02-03T04:05:06.0000000Z'
        Assert-CcodFailedAttemptClearReceipt -Receipt $receipt -Outcome 'Cleared' -Message 'exact failed clear'
        $after = Read-CcodVerifiedPackages -StateRoot $state -Adapters (New-CcodStateTestAdapters)
        Assert-CcodEqual 1 @($after.packages.PSObject.Properties).Count 'one unrelated record remains'
        Assert-CcodEqual 'other.pkg' $after.packages.$otherKey.packageFullName 'unrelated package is preserved'
        Assert-CcodEqual '2030-02-03T04:05:07.0000000Z' $after.packages.$otherKey.confirmedAtUtc 'unrelated timestamp is preserved'

        Assert-CcodFailedAttemptClearReceipt -Receipt (Clear-CcodFailedPackageAttempt -StateRoot $state -PackageFullName 'pkg' -AppAsarSha256 ('a' * 64) -RuntimeId 'runtime-1' -ExpectedConfirmedAtUtc '2030-02-03T04:05:06.0000000Z') -Outcome 'NotFound' -Message 'already absent clear'
    }

    Invoke-CcodTest 'distinguishes not found successful and stale failed attempts without mutation' {
        $state = Join-Path $root 'clear-failed-outcomes'
        Initialize-CcodStateFixture -StateRoot $state
        $key = 'pkg|aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa|runtime-1'
        $succeeded = New-CcodVerifiedRecord
        $succeeded.dynamicOutcome = 'Succeeded'
        $succeeded.probeState = 'Valid'
        Write-CcodStateJson -StateRoot $state -Leaf 'verified-packages.json' -Value ([ordered]@{ schemaVersion = 1; packages = [ordered]@{ $key = $succeeded } })
        $beforeSuccess = [IO.File]::ReadAllBytes((Join-Path $state 'verified-packages.json'))

        Assert-CcodFailedAttemptClearReceipt -Receipt (Clear-CcodFailedPackageAttempt -StateRoot $state -PackageFullName 'pkg' -AppAsarSha256 ('a' * 64) -RuntimeId 'runtime-1' -ExpectedConfirmedAtUtc '2030-02-03T04:05:06.0000000Z') -Outcome 'NotFailed' -Message 'successful record clear'
        Assert-CcodFailedAttemptClearReceipt -Receipt (Clear-CcodFailedPackageAttempt -StateRoot $state -PackageFullName 'pkg' -AppAsarSha256 ('a' * 64) -RuntimeId 'runtime-1' -ExpectedConfirmedAtUtc '2030-02-03T04:05:07.0000000Z') -Outcome 'NotFailed' -Message 'successful record stale timestamp clear'
        Assert-CcodEqual ([Convert]::ToBase64String($beforeSuccess)) ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $state 'verified-packages.json')))) 'successful history bytes are unchanged'

        $failed = New-CcodVerifiedRecord
        Write-CcodStateJson -StateRoot $state -Leaf 'verified-packages.json' -Value ([ordered]@{ schemaVersion = 1; packages = [ordered]@{ $key = $failed } })
        $beforeConflict = [IO.File]::ReadAllBytes((Join-Path $state 'verified-packages.json'))
        Assert-CcodFailedAttemptClearReceipt -Receipt (Clear-CcodFailedPackageAttempt -StateRoot $state -PackageFullName 'pkg' -AppAsarSha256 ('a' * 64) -RuntimeId 'runtime-1' -ExpectedConfirmedAtUtc '2030-02-03T04:05:07.0000000Z') -Outcome 'Conflict' -Message 'stale timestamp clear'
        Assert-CcodEqual ([Convert]::ToBase64String($beforeConflict)) ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $state 'verified-packages.json')))) 'stale timestamp leaves bytes unchanged'

        Assert-CcodFailedAttemptClearReceipt -Receipt (Clear-CcodFailedPackageAttempt -StateRoot $state -PackageFullName 'PKG' -AppAsarSha256 ('a' * 64) -RuntimeId 'runtime-1' -ExpectedConfirmedAtUtc '2030-02-03T04:05:06.0000000Z') -Outcome 'NotFound' -Message 'package case mismatch'
        Assert-CcodFailedAttemptClearReceipt -Receipt (Clear-CcodFailedPackageAttempt -StateRoot $state -PackageFullName 'pkg' -AppAsarSha256 ('a' * 64) -RuntimeId 'RUNTIME-1' -ExpectedConfirmedAtUtc '2030-02-03T04:05:06.0000000Z') -Outcome 'NotFound' -Message 'runtime case mismatch'
    }

    Invoke-CcodTest 'rejects noncanonical clear inputs without PowerShell coercion' {
        $state = Join-Path $root 'clear-failed-inputs'
        Initialize-CcodStateFixture -StateRoot $state
        $common = @{ StateRoot=$state; PackageFullName='pkg'; AppAsarSha256=('a' * 64); RuntimeId='runtime-1'; ExpectedConfirmedAtUtc='2030-02-03T04:05:06.0000000Z' }
        $cases = @(
            @{ Name='state null'; Mutate={ param($x) $x.StateRoot=$null } },
            @{ Name='state type'; Mutate={ param($x) $x.StateRoot=123 } },
            @{ Name='state dot path'; Mutate={ param($x) $x.StateRoot=(Join-Path $state '.') } },
            @{ Name='package null'; Mutate={ param($x) $x.PackageFullName=$null } },
            @{ Name='package type'; Mutate={ param($x) $x.PackageFullName=123 } },
            @{ Name='package empty'; Mutate={ param($x) $x.PackageFullName='' } },
            @{ Name='package delimiter'; Mutate={ param($x) $x.PackageFullName='pkg|other' } },
            @{ Name='hash null'; Mutate={ param($x) $x.AppAsarSha256=$null } },
            @{ Name='hash type'; Mutate={ param($x) $x.AppAsarSha256=123 } },
            @{ Name='hash uppercase'; Mutate={ param($x) $x.AppAsarSha256=('A' * 64) } },
            @{ Name='runtime null'; Mutate={ param($x) $x.RuntimeId=$null } },
            @{ Name='runtime type'; Mutate={ param($x) $x.RuntimeId=123 } },
            @{ Name='runtime unsafe'; Mutate={ param($x) $x.RuntimeId='../runtime' } },
            @{ Name='timestamp null'; Mutate={ param($x) $x.ExpectedConfirmedAtUtc=$null } },
            @{ Name='timestamp type'; Mutate={ param($x) $x.ExpectedConfirmedAtUtc=[DateTime]::UtcNow } },
            @{ Name='timestamp noncanonical'; Mutate={ param($x) $x.ExpectedConfirmedAtUtc='2030-02-03T04:05:06Z' } }
        )
        foreach ($case in $cases) {
            $arguments = @{}
            foreach ($name in $common.Keys) { $arguments[$name] = $common[$name] }
            & $case.Mutate $arguments
            Assert-CcodThrows { Clear-CcodFailedPackageAttempt @arguments } 'CCOD_FAILED_ATTEMPT_CLEAR_INVALID'
        }
    }

    Invoke-CcodTest 'rejects invalid callback adapter shapes with one bounded non-secret error' {
        foreach ($adapterName in @('BeforeFailedPackageAttemptRecheck', 'WriteAtomicJson')) {
            $state = Join-Path $root ('clear-failed-adapter-' + $adapterName.ToLowerInvariant())
            Initialize-CcodStateFixture -StateRoot $state
            $path = Join-Path $state 'verified-packages.json'
            $key = 'pkg|aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa|runtime-1'
            Write-CcodStateJson -StateRoot $state -Leaf 'verified-packages.json' -Value ([ordered]@{ schemaVersion=1; packages=[ordered]@{ $key=(New-CcodVerifiedRecord) } })
            $before = [IO.File]::ReadAllBytes($path)
            $secretAdapterValue = 'SECRET_ADAPTER_VALUE_' + $adapterName + '_' + $state
            $receipt = $null
            $caught = $null
            try {
                $receipt = Clear-CcodFailedPackageAttempt -StateRoot $state -PackageFullName 'pkg' -AppAsarSha256 ('a' * 64) -RuntimeId 'runtime-1' -ExpectedConfirmedAtUtc '2030-02-03T04:05:06.0000000Z' -Adapters @{ $adapterName=$secretAdapterValue }
            } catch {
                $caught = $_
            }

            Assert-CcodEqual $null $receipt "$adapterName invalid shape returns no receipt"
            Assert-CcodTrue ($null -ne $caught) "$adapterName invalid shape throws"
            Assert-CcodEqual 'CCOD_FAILED_ATTEMPT_ADAPTER_INVALID' (([string]$caught.FullyQualifiedErrorId -split ',')[0]) "$adapterName invalid shape uses one stable ID"
            Assert-CcodEqual 'Failed package attempt adapter contract is invalid' $caught.Exception.Message "$adapterName invalid shape uses a fixed generic message"
            Assert-CcodEqual $null $caught.TargetObject "$adapterName invalid shape has null TargetObject"
            Assert-CcodTrue (-not (($caught | Out-String).Contains($secretAdapterValue))) "$adapterName invalid shape does not expose the adapter value"
            Assert-CcodEqual ([Convert]::ToBase64String($before)) ([Convert]::ToBase64String([IO.File]::ReadAllBytes($path))) "$adapterName invalid shape leaves exact prior target bytes"
        }

        $state = Join-Path $root 'clear-failed-adapter-container'
        Initialize-CcodStateFixture -StateRoot $state
        $secretAdapterShape = 'SECRET_INVALID_ADAPTER_CONTAINER_' + $state
        $caught = $null
        try {
            Clear-CcodFailedPackageAttempt -StateRoot $state -PackageFullName 'pkg' -AppAsarSha256 ('a' * 64) -RuntimeId 'runtime-1' -ExpectedConfirmedAtUtc '2030-02-03T04:05:06.0000000Z' -Adapters $secretAdapterShape | Out-Null
        } catch {
            $caught = $_
        }
        Assert-CcodTrue ($null -ne $caught) 'invalid adapter container throws'
        Assert-CcodEqual 'CCOD_FAILED_ATTEMPT_ADAPTER_INVALID' (([string]$caught.FullyQualifiedErrorId -split ',')[0]) 'invalid adapter container uses one stable ID'
        Assert-CcodEqual 'Failed package attempt adapter contract is invalid' $caught.Exception.Message 'invalid adapter container uses a fixed generic message'
        Assert-CcodEqual $null $caught.TargetObject 'invalid adapter container has null TargetObject'
        Assert-CcodTrue (-not (($caught | Out-String).Contains($secretAdapterShape))) 'invalid adapter container does not expose its value'
    }

    Invoke-CcodTest 'refuses missing corrupt or identity-inconsistent verified state without changing evidence' {
        foreach ($variant in @('missing', 'malformed', 'unknown-schema', 'identity')) {
            $state = Join-Path $root ('clear-failed-damage-' + $variant)
            Initialize-CcodStateFixture -StateRoot $state
            $path = Join-Path $state 'verified-packages.json'
            if ($variant -eq 'missing') {
                [IO.File]::Delete($path)
                $before = $null
            } elseif ($variant -eq 'malformed') {
                [IO.File]::WriteAllText($path, '{broken', [Text.UTF8Encoding]::new($false))
                $before = [IO.File]::ReadAllBytes($path)
            } elseif ($variant -eq 'unknown-schema') {
                Write-CcodStateJson -StateRoot $state -Leaf 'verified-packages.json' -Value ([ordered]@{ schemaVersion=2; packages=[ordered]@{} })
                $before = [IO.File]::ReadAllBytes($path)
            } else {
                $key = 'pkg|aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa|runtime-1'
                $record = New-CcodVerifiedRecord
                $record.packageFullName = 'other.pkg'
                Write-CcodStateJson -StateRoot $state -Leaf 'verified-packages.json' -Value ([ordered]@{ schemaVersion=1; packages=[ordered]@{ $key=$record } })
                $before = [IO.File]::ReadAllBytes($path)
            }

            $expectedError = if ($variant -eq 'missing') { 'CCOD_STATE_MISSING' } elseif ($variant -eq 'malformed') { 'CCOD_STATE_MALFORMED' } elseif ($variant -eq 'unknown-schema') { 'CCOD_SCHEMA_UNSUPPORTED' } else { 'CCOD_VERIFIED_PACKAGES_INVALID' }
            Assert-CcodThrows { Clear-CcodFailedPackageAttempt -StateRoot $state -PackageFullName 'pkg' -AppAsarSha256 ('a' * 64) -RuntimeId 'runtime-1' -ExpectedConfirmedAtUtc '2030-02-03T04:05:06.0000000Z' } $expectedError
            Assert-CcodEqual 0 @(Get-ChildItem -LiteralPath $state -File -Filter 'verified-packages.json.corrupt.*').Count "$variant state is not quarantined or replaced"
            if ($null -eq $before) {
                Assert-CcodEqual $false ([IO.File]::Exists($path)) 'missing verified state remains missing'
            } else {
                Assert-CcodEqual ([Convert]::ToBase64String($before)) ([Convert]::ToBase64String([IO.File]::ReadAllBytes($path))) "$variant evidence bytes remain exact"
            }
        }
    }

    Invoke-CcodTest 'rechecks the complete failed identity and timestamp immediately before commit' {
        foreach ($change in @('timestamp', 'outcome', 'removed', 'unrelated')) {
            $state = Join-Path $root ('clear-failed-race-' + $change)
            Initialize-CcodStateFixture -StateRoot $state
            $path = Join-Path $state 'verified-packages.json'
            $key = 'pkg|aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa|runtime-1'
            Write-CcodStateJson -StateRoot $state -Leaf 'verified-packages.json' -Value ([ordered]@{ schemaVersion=1; packages=[ordered]@{ $key=(New-CcodVerifiedRecord) } })
            $hook = {
                param($VerifiedPath, $SuppressionKey)
                $store = Get-Content -LiteralPath $VerifiedPath -Raw | ConvertFrom-Json
                if ($change -eq 'timestamp') { $store.packages.$SuppressionKey.confirmedAtUtc = '2030-02-03T04:05:07.0000000Z' }
                elseif ($change -eq 'outcome') { $store.packages.$SuppressionKey.dynamicOutcome = 'Succeeded'; $store.packages.$SuppressionKey.probeState = 'Valid' }
                elseif ($change -eq 'removed') { $store.packages.PSObject.Properties.Remove($SuppressionKey) }
                else {
                    $store.packages | Add-Member -NotePropertyName ('other.pkg|' + ('b' * 64) + '|runtime-2') -NotePropertyValue ([pscustomobject]@{
                        packageFullName='other.pkg'; packageVersion='2.0.0.0'; appAsarSha256=('b' * 64); runtimeId='runtime-2'
                        staticClassification='CandidateCompatible'; dynamicOutcome='Failed'; probeState='Invalid'; confirmedAtUtc='2030-02-03T04:05:07.0000000Z'
                    })
                }
                Write-CcodStateJson -StateRoot $state -Leaf 'verified-packages.json' -Value $store
            }.GetNewClosure()
            $receipt = Clear-CcodFailedPackageAttempt -StateRoot $state -PackageFullName 'pkg' -AppAsarSha256 ('a' * 64) -RuntimeId 'runtime-1' -ExpectedConfirmedAtUtc '2030-02-03T04:05:06.0000000Z' -Adapters @{ BeforeFailedPackageAttemptRecheck=$hook }
            Assert-CcodFailedAttemptClearReceipt -Receipt $receipt -Outcome 'Conflict' -Message "$change precommit change"
            $after = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            if ($change -eq 'removed') { Assert-CcodEqual 0 @($after.packages.PSObject.Properties).Count 'concurrent removal remains removed' }
            elseif ($change -eq 'timestamp') { Assert-CcodEqual '2030-02-03T04:05:07.0000000Z' $after.packages.$key.confirmedAtUtc 'concurrent timestamp remains intact' }
            elseif ($change -eq 'outcome') { Assert-CcodEqual 'Succeeded' $after.packages.$key.dynamicOutcome 'concurrent success remains intact' }
            else { Assert-CcodEqual 2 @($after.packages.PSObject.Properties).Count 'concurrent unrelated history remains intact' }
        }
    }

    Invoke-CcodTest 'replaces every recheck and atomic writer callback failure with a fresh bounded error' {
        foreach ($stage in @('Recheck', 'Write')) {
            $state = Join-Path $root ('clear-failed-callback-' + $stage.ToLowerInvariant())
            Initialize-CcodStateFixture -StateRoot $state
            $path = Join-Path $state 'verified-packages.json'
            $key = 'pkg|aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa|runtime-1'
            Write-CcodStateJson -StateRoot $state -Leaf 'verified-packages.json' -Value ([ordered]@{ schemaVersion=1; packages=[ordered]@{ $key=(New-CcodVerifiedRecord) } })
            $before = [IO.File]::ReadAllBytes($path)
            $secretTarget = Join-Path $state ('secret-' + $stage + '.txt')
            $secretMessage = 'SECRET_CALLBACK_MESSAGE_' + $stage + '_' + $secretTarget
            $expectedId = if ($stage -ceq 'Recheck') { 'CCOD_FAILED_ATTEMPT_RECHECK_FAILED' } else { 'CCOD_FAILED_ATTEMPT_WRITE_FAILED' }
            $expectedMessage = if ($stage -ceq 'Recheck') { 'Failed package attempt precommit recheck failed' } else { 'Failed package attempt atomic write failed' }
            $calls = [pscustomobject]@{ Recheck=0; Write=0 }
            $recheck = {
                param($VerifiedPath, $SuppressionKey)
                $calls.Recheck++
                if ($stage -ceq 'Recheck') {
                    throw [Management.Automation.ErrorRecord]::new([InvalidOperationException]::new($secretMessage), $expectedId, [Management.Automation.ErrorCategory]::InvalidData, $secretTarget)
                }
            }.GetNewClosure()
            $writer = {
                param($VerifiedPath, $Value)
                $calls.Write++
                if ($stage -ceq 'Write') {
                    throw [Management.Automation.ErrorRecord]::new([IO.IOException]::new($secretMessage), $expectedId, [Management.Automation.ErrorCategory]::WriteError, $secretTarget)
                }
            }.GetNewClosure()

            $receipt = $null
            $caught = $null
            try {
                $receipt = Clear-CcodFailedPackageAttempt -StateRoot $state -PackageFullName 'pkg' -AppAsarSha256 ('a' * 64) -RuntimeId 'runtime-1' -ExpectedConfirmedAtUtc '2030-02-03T04:05:06.0000000Z' -Adapters @{ BeforeFailedPackageAttemptRecheck=$recheck; WriteAtomicJson=$writer }
            } catch {
                $caught = $_
            }

            Assert-CcodEqual $null $receipt "$stage callback failure returns no Cleared receipt"
            Assert-CcodTrue ($null -ne $caught) "$stage callback failure throws"
            Assert-CcodEqual $expectedId (([string]$caught.FullyQualifiedErrorId -split ',')[0]) "$stage callback failure uses the exact stable ID"
            Assert-CcodEqual $expectedMessage $caught.Exception.Message "$stage callback failure uses a fixed generic message"
            Assert-CcodEqual $null $caught.TargetObject "$stage callback failure has null TargetObject"
            $rendered = $caught | Out-String
            Assert-CcodTrue (-not $rendered.Contains($secretMessage)) "$stage callback error does not expose the secret message"
            Assert-CcodTrue (-not $rendered.Contains($secretTarget)) "$stage callback error does not expose the secret target"
            Assert-CcodEqual 1 $calls.Recheck "$stage path invokes recheck once"
            Assert-CcodEqual ($(if ($stage -ceq 'Write') { 1 } else { 0 })) $calls.Write "$stage path invokes writer only when recheck succeeds"
            Assert-CcodEqual ([Convert]::ToBase64String($before)) ([Convert]::ToBase64String([IO.File]::ReadAllBytes($path))) "$stage callback failure leaves exact prior target bytes"
            Assert-CcodEqual 1 @((Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).packages.PSObject.Properties).Count "$stage callback failure leaves a complete parseable store"
        }
    }

    Invoke-CcodTest 'rejects every emitted callback stream including nonterminating errors from both stages' {
        foreach ($stage in @('Recheck', 'Write')) {
            foreach ($stream in @('Error', 'Output', 'Warning', 'Verbose', 'Debug', 'Information')) {
                $state = Join-Path $root ('clear-failed-stream-' + $stage.ToLowerInvariant() + '-' + $stream.ToLowerInvariant())
                Initialize-CcodStateFixture -StateRoot $state
                $path = Join-Path $state 'verified-packages.json'
                $key = 'pkg|aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa|runtime-1'
                Write-CcodStateJson -StateRoot $state -Leaf 'verified-packages.json' -Value ([ordered]@{ schemaVersion=1; packages=[ordered]@{ $key=(New-CcodVerifiedRecord) } })
                $before = [IO.File]::ReadAllBytes($path)
                $secretTarget = Join-Path $state ('SECRET_STREAM_TARGET_' + $stage + '_' + $stream + '.txt')
                $secretMessage = 'SECRET_STREAM_MESSAGE_' + $stage + '_' + $stream + '_' + $secretTarget
                $expectedId = if ($stage -ceq 'Recheck') { 'CCOD_FAILED_ATTEMPT_RECHECK_FAILED' } else { 'CCOD_FAILED_ATTEMPT_WRITE_FAILED' }
                $expectedMessage = if ($stage -ceq 'Recheck') { 'Failed package attempt precommit recheck failed' } else { 'Failed package attempt atomic write failed' }
                $calls = [pscustomobject]@{ Recheck=0; Write=0 }
                $emit = {
                    switch -CaseSensitive ($stream) {
                        'Error' { Write-Error -Message $secretMessage -ErrorId $expectedId -TargetObject $secretTarget -ErrorAction Continue }
                        'Output' { Write-Output ([pscustomobject]@{ Message=$secretMessage; TargetObject=$secretTarget; FullyQualifiedErrorId=$expectedId }) }
                        'Warning' { Write-Warning $secretMessage }
                        'Verbose' { Write-Verbose $secretMessage -Verbose }
                        'Debug' { $DebugPreference='Continue'; Write-Debug $secretMessage }
                        'Information' { Write-Information $secretMessage -InformationAction Continue }
                    }
                }.GetNewClosure()
                $recheck = {
                    param($VerifiedPath, $SuppressionKey)
                    $calls.Recheck++
                    if ($stage -ceq 'Recheck') { & $emit }
                }.GetNewClosure()
                $writer = {
                    param($VerifiedPath, $Value)
                    $calls.Write++
                    if ($stage -ceq 'Write') { & $emit }
                }.GetNewClosure()

                $receipt = $null
                $caught = $null
                try {
                    $receipt = Clear-CcodFailedPackageAttempt -StateRoot $state -PackageFullName 'pkg' -AppAsarSha256 ('a' * 64) -RuntimeId 'runtime-1' -ExpectedConfirmedAtUtc '2030-02-03T04:05:06.0000000Z' -Adapters @{ BeforeFailedPackageAttemptRecheck=$recheck; WriteAtomicJson=$writer }
                } catch {
                    $caught = $_
                }

                Assert-CcodEqual $null $receipt "$stage $stream emission returns no Cleared receipt"
                Assert-CcodTrue ($null -ne $caught) "$stage $stream emission throws"
                Assert-CcodEqual $expectedId (([string]$caught.FullyQualifiedErrorId -split ',')[0]) "$stage $stream emission uses the exact stage ID"
                Assert-CcodEqual $expectedMessage $caught.Exception.Message "$stage $stream emission uses the fixed generic message"
                Assert-CcodEqual $null $caught.TargetObject "$stage $stream emission has null TargetObject"
                $rendered = $caught | Out-String
                Assert-CcodTrue (-not $rendered.Contains($secretMessage)) "$stage $stream emission does not expose the secret message"
                Assert-CcodTrue (-not $rendered.Contains($secretTarget)) "$stage $stream emission does not expose the secret target"
                Assert-CcodEqual 1 $calls.Recheck "$stage $stream path invokes recheck once"
                Assert-CcodEqual ($(if ($stage -ceq 'Write') { 1 } else { 0 })) $calls.Write "$stage $stream path never advances past an emitting recheck"
                Assert-CcodEqual ([Convert]::ToBase64String($before)) ([Convert]::ToBase64String([IO.File]::ReadAllBytes($path))) "$stage $stream emission leaves exact prior target bytes"
                Assert-CcodEqual 1 @((Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).packages.PSObject.Properties).Count "$stage $stream emission leaves a complete parseable store"
            }
        }
    }

    Invoke-CcodTest 'updates each consent without changing the other consent or verified candidates' {
        $state = Join-Path $root 'setters'
        Initialize-CcodStateFixture -StateRoot $state
        Set-CcodAutomationEnabled -StateRoot $state -Enabled $false -Adapters (New-CcodStateTestAdapters) | Out-Null
        $afterAutomation = Read-CcodSettings -StateRoot $state -Adapters (New-CcodStateTestAdapters)
        Assert-CcodEqual $false $afterAutomation.automationEnabled 'automation setter changes only automation'
        Assert-CcodEqual $true $afterAutomation.candidateCompatibleOptIn 'automation setter preserves candidate opt-in'
        Assert-CcodEqual 'C:\Node\node.exe' $afterAutomation.nodeCandidates[0] 'automation setter preserves verified candidates'
        Assert-CcodEqual $false (Read-CcodState -StateRoot $state -Adapters (New-CcodStateTestAdapters)).AutomaticCandidateTrialsAllowed 'candidate trial requires automation as well as the preserved opt-in'
        Set-CcodAutomationEnabled -StateRoot $state -Enabled $true -Adapters (New-CcodStateTestAdapters) | Out-Null
        Set-CcodCandidateCompatibleOptIn -StateRoot $state -Enabled $false -Adapters (New-CcodStateTestAdapters) | Out-Null
        $afterOptIn = Read-CcodSettings -StateRoot $state -Adapters (New-CcodStateTestAdapters)
        Assert-CcodEqual $true $afterOptIn.automationEnabled 'candidate opt-in setter preserves automation'
        Assert-CcodEqual $false $afterOptIn.candidateCompatibleOptIn 'candidate opt-in setter changes only its own consent'
        Assert-CcodEqual 'C:\Node\node.exe' $afterOptIn.nodeCandidates[0] 'candidate opt-in setter preserves verified candidates'
        Assert-CcodEqual $false (Read-CcodState -StateRoot $state -Adapters (New-CcodStateTestAdapters)).AutomaticCandidateTrialsAllowed 'candidate trial also requires explicit candidate opt-in'
    }

    Invoke-CcodTest 'repair preserves quarantined evidence and keeps both consent switches off' {
        $state = Join-Path $root 'repair'
        Initialize-CcodStateFixture -StateRoot $state
        Set-CcodStateDamage -StateRoot $state -Leaf 'settings.json' -Variant 'malformed'
        Repair-CcodState -StateRoot $state -Adapters (New-CcodStateTestAdapters) | Out-Null
        $repaired = Read-CcodState -StateRoot $state -Adapters (New-CcodStateTestAdapters)
        Assert-CcodEqual $false $repaired.Settings.automationEnabled 'repair leaves automation explicitly off'
        Assert-CcodEqual $false $repaired.Settings.candidateCompatibleOptIn 'repair leaves candidate opt-in explicitly off'
        Assert-CcodTrue (@(Get-ChildItem -LiteralPath $state -File -Filter 'settings.json.corrupt.*').Count -eq 1) 'repair retains the damaged settings evidence'
    }

    Invoke-CcodTest 'constructs stable keys and resolves device-key store without touching it' {
        Assert-CcodEqual '100|2026-08-02T00:00:00.0000000Z' (Get-CcodAttemptKey -Pid 100 -CreationTimeUtc '2026-08-02T00:00:00.0000000Z') 'attempt key is PID plus creation time'
        Assert-CcodEqual '100|created|transaction' (Get-CcodRecoveryIgnoreKey -Pid 100 -CreationTimeUtc 'created' -TransactionId 'transaction') 'recovery key includes transaction lifetime'
        Assert-CcodEqual 'pkg|hash|runtime' (Get-CcodSuppressionKey -PackageFullName 'pkg' -AppAsarSha256 'hash' -RuntimeId 'runtime') 'suppression key includes runtime lifetime'
        Assert-CcodEqual 'pkg|hash' (Get-CcodStaticKey -PackageFullName 'pkg' -AppAsarSha256 'hash') 'static key excludes runtime lifetime'
        $oldCodexHome = [Environment]::GetEnvironmentVariable('CODEX_HOME', 'Process')
        try {
            [Environment]::SetEnvironmentVariable('CODEX_HOME', (Join-Path $root 'codex-home'), 'Process')
            $path = Resolve-CcodDeviceKeyStorePath
            Assert-CcodEqual (Join-Path (Join-Path $root 'codex-home') 'remote-control-device-keys.windows.json') $path 'absolute CODEX_HOME only determines the shared device-key path'
            Assert-CcodEqual $false ([IO.File]::Exists($path)) 'resolving the device-key path does not create or touch the key file'
            [Environment]::SetEnvironmentVariable('CODEX_HOME', 'relative-codex-home', 'Process')
            Assert-CcodThrows { Resolve-CcodDeviceKeyStorePath } 'CCOD_CODEX_HOME_INVALID'
        } finally {
            [Environment]::SetEnvironmentVariable('CODEX_HOME', $oldCodexHome, 'Process')
        }
    }
} catch {
    Write-Error $_
    exit 1
} finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
