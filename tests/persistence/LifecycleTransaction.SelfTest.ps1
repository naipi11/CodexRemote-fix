$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestSupport.ps1')

$repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module (Join-Path $repositoryRoot 'src\persistence\modules\LifecycleTransaction.psm1') -Force

function New-CcodLifecycleFixture {
    $owner = [pscustomobject][ordered]@{ pid=401; creationTimeUtc='2030-02-03T04:05:06.0000000Z' }
    $logon = [pscustomobject][ordered]@{ authenticationId='00000000:000003E7'; userSid='S-1-5-21-1-2-3-1001'; sessionId=2 }
    return New-CcodLifecycleRequest -Kind RestartAndRepair -Origin Installer -RuntimeId '2.5.0-0123456789abcdef' `
        -RuntimeGeneration 7 -LeaseEpoch 11 -OwnerIdentity $owner -LogonIdentity $logon `
        -NowUtc '2030-02-03T04:05:07.0000000Z' -TransactionId '11111111-2222-3333-4444-555555555555'
}

function Copy-CcodLifecycleFixture($Request) {
    return ($Request | ConvertTo-Json -Depth 16 | ConvertFrom-Json)
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-lifecycle-transaction-selftest-' + [Guid]::NewGuid().ToString('N'))
try {
    Invoke-CcodTest 'constructs the exact durable restart request and clones callers during legal phase moves' {
        $request = New-CcodLifecycleFixture
        Assert-CcodEqual 'schemaVersion,transactionId,kind,origin,runtimeId,runtimeGeneration,leaseEpoch,ownerIdentity,logonIdentity,phase,createdAtUtc,updatedAtUtc,launchRequestedAtUtc,manualLaunchExpiresAtUtc,automaticLaunchAttempts,error' (($request.PSObject.Properties.Name) -join ',') 'request has the exact ordered schema'
        Assert-CcodEqual 'Requested' $request.phase 'new lifecycle request starts at Requested'
        $close = Move-CcodLifecyclePhase -Request $request -NextPhase CloseRequested -NowUtc '2030-02-03T04:05:08.0000000Z'
        Assert-CcodEqual 'CloseRequested' $close.phase 'Requested advances to CloseRequested'
        Assert-CcodEqual 'Requested' $request.phase 'phase move does not mutate its caller'
        Assert-CcodEqual '2030-02-03T04:05:08.0000000Z' $close.updatedAtUtc 'phase move records its supplied UTC timestamp'
        Assert-CcodThrows { Move-CcodLifecyclePhase -Request $request -NextPhase RepairRequested -NowUtc '2030-02-03T04:05:08.0000000Z' } 'CCOD_LIFECYCLE_PHASE_INVALID'
    }

    Invoke-CcodTest 'accepts every legal lifecycle edge and rejects terminal mutation' {
        $edges = @(
            @('Requested','CloseRequested'), @('Requested','SupersededByUpgrade'), @('Requested','CancelledBeforeClose'),
            @('CloseRequested','CloseConfirmed'), @('CloseRequested','CloseFailed'),
            @('CloseConfirmed','OrdinaryLaunchRequested'), @('CloseConfirmed','RepairRequested'),
            @('OrdinaryLaunchRequested','OrdinaryObserved'), @('OrdinaryLaunchRequested','WaitingForManualLaunch'), @('OrdinaryLaunchRequested','OrdinaryLaunchFailed'), @('OrdinaryLaunchRequested','OrdinaryObservationTimedOut'),
            @('WaitingForManualLaunch','OrdinaryObserved'), @('WaitingForManualLaunch','LaunchWindowExpired'),
            @('OrdinaryObserved','RepairRequested'),
            @('RepairRequested','RemoteVerified'), @('RepairRequested','RepairFailed'), @('RepairRequested','VerificationFailed'),
            @('RemoteVerified','Completed')
        )
        foreach ($edge in $edges) {
            $request = New-CcodLifecycleFixture
            if ($edge[0] -ne 'Requested') { $request.phase = $edge[0] }
            $next = Move-CcodLifecyclePhase -Request $request -NextPhase $edge[1] -NowUtc '2030-02-03T04:05:08.0000000Z'
            Assert-CcodEqual $edge[1] $next.phase "$($edge[0]) advances only through its declared legal edge"
        }
        foreach ($terminal in @('Completed','CloseFailed','OrdinaryLaunchFailed','OrdinaryObservationTimedOut','LaunchWindowExpired','RepairFailed','VerificationFailed','CancelledBeforeClose','SupersededByUpgrade')) {
            $request = New-CcodLifecycleFixture
            $request.phase = $terminal
            Assert-CcodThrows { Move-CcodLifecyclePhase -Request $request -NextPhase Requested -NowUtc '2030-02-03T04:05:08.0000000Z' } 'CCOD_LIFECYCLE_PHASE_INVALID'
        }
    }

    Invoke-CcodTest 'rejects malformed lifecycle request shapes and every identity boundary' {
        foreach ($variant in @('extra', 'missing', 'reordered', 'script', 'guid', 'timestamp', 'runtime', 'generation', 'epoch', 'owner', 'logon')) {
            $request = Copy-CcodLifecycleFixture (New-CcodLifecycleFixture)
            switch ($variant) {
                'extra' { Add-Member -InputObject $request -NotePropertyName unexpected -NotePropertyValue $true }
                'missing' { $request.PSObject.Properties.Remove('error') }
                'reordered' {
                    $request = [pscustomobject][ordered]@{ transactionId=$request.transactionId; schemaVersion=$request.schemaVersion; kind=$request.kind; origin=$request.origin; runtimeId=$request.runtimeId; runtimeGeneration=$request.runtimeGeneration; leaseEpoch=$request.leaseEpoch; ownerIdentity=$request.ownerIdentity; logonIdentity=$request.logonIdentity; phase=$request.phase; createdAtUtc=$request.createdAtUtc; updatedAtUtc=$request.updatedAtUtc; launchRequestedAtUtc=$request.launchRequestedAtUtc; manualLaunchExpiresAtUtc=$request.manualLaunchExpiresAtUtc; automaticLaunchAttempts=$request.automaticLaunchAttempts; error=$request.error }
                }
                'script' { Add-Member -InputObject $request -MemberType ScriptProperty -Name unexpected -Value { 'not data' } }
                'guid' { $request.transactionId = 'not-a-guid' }
                'timestamp' { $request.createdAtUtc = '2030-02-03T04:05:07Z' }
                'runtime' { $request.runtimeId = '../invalid' }
                'generation' { $request.runtimeGeneration = 0 }
                'epoch' { $request.leaseEpoch = -1 }
                'owner' { $request.ownerIdentity = [pscustomobject][ordered]@{ pid=0; creationTimeUtc='not-a-time' } }
                'logon' { $request.logonIdentity = [pscustomobject][ordered]@{ authenticationId='bad'; userSid='bad'; sessionId=-1 } }
            }
            Assert-CcodThrows { Write-CcodLifecycleRequest -StateRoot (Join-Path $root $variant) -Request $request } 'CCOD_LIFECYCLE_STATE_INVALID'
        }
    }

    Invoke-CcodTest 'atomically persists valid requests, treats an absent active request as idle, and retains terminal receipts' {
        $state = Join-Path $root 'persistence'
        [IO.Directory]::CreateDirectory($state) | Out-Null
        Assert-CcodEqual $null (Read-CcodLifecycleRequest -StateRoot $state) 'absent active request is idle'
        $request = New-CcodLifecycleFixture
        Write-CcodLifecycleRequest -StateRoot $state -Request $request | Out-Null
        Assert-CcodTrue ([IO.File]::Exists((Get-CcodLifecycleRequestPath -StateRoot $state))) 'write creates the canonical active request path'
        $loaded = Read-CcodLifecycleRequest -StateRoot $state
        Assert-CcodEqual $request.transactionId $loaded.transactionId 'strict read returns persisted request'
        $completed = Move-CcodLifecyclePhase -Request (Move-CcodLifecyclePhase -Request (Move-CcodLifecyclePhase -Request (Move-CcodLifecyclePhase -Request (Move-CcodLifecyclePhase -Request $request -NextPhase CloseRequested -NowUtc '2030-02-03T04:05:08.0000000Z') -NextPhase CloseConfirmed -NowUtc '2030-02-03T04:05:09.0000000Z') -NextPhase RepairRequested -NowUtc '2030-02-03T04:05:10.0000000Z') -NextPhase RemoteVerified -NowUtc '2030-02-03T04:05:11.0000000Z') -NextPhase Completed -NowUtc '2030-02-03T04:05:12.0000000Z'
        Complete-CcodLifecycleRequest -StateRoot $state -Request $completed | Out-Null
        Assert-CcodTrue ([IO.File]::Exists((Get-CcodLifecycleReceiptPath -StateRoot $state -TransactionId $request.transactionId))) 'terminal completion persists a correlated receipt'
        Assert-CcodEqual $null (Read-CcodLifecycleRequest -StateRoot $state) 'completion clears the active request'
        Assert-CcodThrows { Complete-CcodLifecycleRequest -StateRoot $state -Request $request } 'CCOD_LIFECYCLE_STATE_INVALID'
    }

    Invoke-CcodTest 'fails closed when an active request JSON document is corrupt' {
        $state = Join-Path $root 'corrupt'
        [IO.Directory]::CreateDirectory((Join-Path $state 'lifecycle')) | Out-Null
        [IO.File]::WriteAllText((Get-CcodLifecycleRequestPath -StateRoot $state), '{broken', [Text.UTF8Encoding]::new($false))
        Assert-CcodThrows { Read-CcodLifecycleRequest -StateRoot $state } 'CCOD_LIFECYCLE_STATE_INVALID'
    }

    Invoke-CcodTest 'fails closed when an active request path is a directory or cannot be read' {
        $directoryState = Join-Path $root 'active-directory'
        [IO.Directory]::CreateDirectory($directoryState) | Out-Null
        [IO.Directory]::CreateDirectory((Get-CcodLifecycleRequestPath -StateRoot $directoryState)) | Out-Null
        Assert-CcodThrows { Read-CcodLifecycleRequest -StateRoot $directoryState } 'CCOD_LIFECYCLE_STATE_INVALID'

        $lockedState = Join-Path $root 'active-locked'
        [IO.Directory]::CreateDirectory($lockedState) | Out-Null
        Write-CcodLifecycleRequest -StateRoot $lockedState -Request (New-CcodLifecycleFixture) | Out-Null
        $lock = [IO.File]::Open((Get-CcodLifecycleRequestPath -StateRoot $lockedState), [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try {
            Assert-CcodThrows { Read-CcodLifecycleRequest -StateRoot $lockedState } 'CCOD_LIFECYCLE_STATE_INVALID'
        } finally {
            $lock.Dispose()
        }
    }

    Invoke-CcodTest 'refuses an uncorrelated terminal completion without replacing its active transaction' {
        $state = Join-Path $root 'stale-completion'
        [IO.Directory]::CreateDirectory($state) | Out-Null
        $current = New-CcodLifecycleFixture
        Write-CcodLifecycleRequest -StateRoot $state -Request $current | Out-Null
        $stale = Copy-CcodLifecycleFixture $current
        $stale.transactionId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
        $stale.phase = 'Completed'
        $stale.updatedAtUtc = '2030-02-03T04:05:08.0000000Z'

        Assert-CcodThrows { Complete-CcodLifecycleRequest -StateRoot $state -Request $stale } 'CCOD_LIFECYCLE_STATE_INVALID'
        Assert-CcodEqual $current.transactionId (Read-CcodLifecycleRequest -StateRoot $state).transactionId 'stale completion leaves the current active transaction durable'
        Assert-CcodEqual $false ([IO.File]::Exists((Get-CcodLifecycleReceiptPath -StateRoot $state -TransactionId $stale.transactionId))) 'stale completion writes no uncorrelated receipt'
    }
} catch {
    Write-Error $_
    exit 1
} finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
