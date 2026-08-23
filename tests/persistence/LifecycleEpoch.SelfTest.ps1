$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestSupport.ps1')

$repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module (Join-Path $repositoryRoot 'src\persistence\modules\PersistenceIO.psm1') -Force
Import-Module (Join-Path $repositoryRoot 'src\persistence\modules\LifecycleEpoch.psm1') -Force

function New-CcodEpochTestLease {
    param([bool]$Abandoned = $false)

    return [pscustomobject][ordered]@{
        SchemaVersion = 1; Name = 'Global\CodexControlOtherDevices.AccountTransition.test'; Kind = 'AccountTransition'
        Outcome = 'Acquired'; CreatedNew = $true; Abandoned = $Abandoned; Handle = $null
        OwnerManagedThreadId = 1; Released = $false
    }
}

function Assert-CcodEpochTestFileAcl {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$UserSid)

    $security = [IO.File]::GetAccessControl($Path)
    $owner = $security.GetOwner([Security.Principal.SecurityIdentifier])
    $rules = @($security.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
    Assert-CcodEqual $UserSid $owner.Value "epoch file owner is the current user: $Path"
    Assert-CcodEqual $true $security.AreAccessRulesProtected "epoch file DACL is protected: $Path"
    Assert-CcodEqual 3 $rules.Count "epoch file has exactly three ACL entries: $Path"
    $actual = @($rules | ForEach-Object { '{0}|{1}|{2}|{3}' -f $_.IdentityReference.Value,$_.AccessControlType,$_.FileSystemRights,$_.IsInherited } | Sort-Object)
    $expected = @(
        "$UserSid|Allow|FullControl|False",
        'S-1-5-18|Allow|FullControl|False',
        'S-1-5-32-544|Allow|FullControl|False'
    ) | Sort-Object
    Assert-CcodEqual ($expected -join "`n") ($actual -join "`n") "epoch file ACL entries are exact: $Path"
}

function New-CcodEpochAdapters {
    param(
        [UInt64]$Epoch = 0,
        [string]$RuntimeId = '2.5.0-a',
        [UInt64]$Generation = 3,
        $ProcessIdentity = ([pscustomobject][ordered]@{ pid=101; creationTimeUtc='2030-02-03T04:05:06.0000000Z' })
    )

    $store = [pscustomobject]@{ Epoch = [UInt64]$Epoch; Initialized = $false; RuntimeId = $RuntimeId; Generation = [UInt64]$Generation; ProcessIdentity = $ProcessIdentity; Writes = 0 }
    $adapters = @{
        ReadEpoch = { param($InstallRoot, $AllowInitial) if (-not $store.Initialized -and $AllowInitial) { return $null }; return $store.Epoch }.GetNewClosure()
        WriteEpoch = { param($InstallRoot, $Value) $store.Epoch = [UInt64]$Value; $store.Initialized = $true; $store.Writes++ }.GetNewClosure()
        ReadActiveRuntime = { param($InstallRoot) [pscustomobject][ordered]@{ schemaVersion=2; activeRuntime=$store.RuntimeId; previousRuntime=$null; generation=[UInt64]$store.Generation; updatedAtUtc='2030-02-03T04:05:06.0000000Z' } }.GetNewClosure()
        GetProcessIdentity = { param($Pid) $store.ProcessIdentity }.GetNewClosure()
        EnterMutex = { param($UserSid, $SessionId, $TimeoutMilliseconds) New-CcodEpochTestLease }.GetNewClosure()
        ExitMutex = { param($Lease) $Lease.Released = $true; return $true }.GetNewClosure()
        AssertEpochFileAcl = { param($Path) }.GetNewClosure()
        CreateEpochFile = { param($Path) }.GetNewClosure()
    }
    return [pscustomobject]@{ Store = $store; Adapters = $adapters }
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-lifecycle-epoch-selftest-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root) | Out-Null
try {
    Invoke-CcodTest 'increments exactly once and rejects the stale owner after a later acquisition' {
        $fixture = New-CcodEpochAdapters
        $firstOwner = [pscustomobject][ordered]@{pid=101;creationTimeUtc='2030-02-03T04:05:06.0000000Z'}
        $secondOwner = [pscustomobject][ordered]@{pid=102;creationTimeUtc='2030-02-03T04:05:07.0000000Z'}
        $first = Enter-CcodLifecycleOwnership -InstallRoot $root -RuntimeId '2.5.0-a' -RuntimeGeneration 3 -OwnerIdentity $firstOwner -UserSid 'S-1-5-21-1-2-3-1001' -SessionId 2 -TimeoutMilliseconds 1000 -Adapters $fixture.Adapters
        Exit-CcodLifecycleOwnership -Ownership $first -Adapters $fixture.Adapters | Out-Null
        $fixture.Store.ProcessIdentity = $secondOwner
        $second = Enter-CcodLifecycleOwnership -InstallRoot $root -RuntimeId '2.5.0-a' -RuntimeGeneration 3 -OwnerIdentity $secondOwner -UserSid 'S-1-5-21-1-2-3-1001' -SessionId 2 -TimeoutMilliseconds 1000 -Adapters $fixture.Adapters

        Assert-CcodEqual 'schemaVersion,lease,epoch,runtimeId,runtimeGeneration,ownerIdentity,released' (($first.PSObject.Properties.Name) -join ',') 'ownership receipt has the exact ordered contract'
        Assert-CcodEqual 1 ([UInt64]$first.epoch) 'first lifecycle owner receives epoch one'
        Assert-CcodEqual 2 ([UInt64]$second.epoch) 'next lifecycle owner increments epoch'
        Assert-CcodThrows { Assert-CcodLifecycleFence -InstallRoot $root -Ownership $first -Adapters $fixture.Adapters } 'CCOD_LIFECYCLE_FENCE_STALE'
    }

    Invoke-CcodTest 'fails closed for missing-after-initialization malformed numeric values writes and read-back mismatches' {
        foreach ($case in @('missing', 'negative', 'floating', 'max', 'write', 'readback')) {
            $fixture = New-CcodEpochAdapters
            $owner = [pscustomobject][ordered]@{pid=101;creationTimeUtc='2030-02-03T04:05:06.0000000Z'}
            switch ($case) {
                'missing' { $fixture.Store.Initialized = $true; $fixture.Adapters.ReadEpoch = { param($InstallRoot, $AllowInitial) $null } }
                'negative' { $fixture.Store.Initialized = $true; $fixture.Adapters.ReadEpoch = { param($InstallRoot, $AllowInitial) -1 } }
                'floating' { $fixture.Store.Initialized = $true; $fixture.Adapters.ReadEpoch = { param($InstallRoot, $AllowInitial) 1.5 } }
                'max' { $fixture.Store.Initialized = $true; $fixture.Adapters.ReadEpoch = { param($InstallRoot, $AllowInitial) [UInt64]::MaxValue } }
                'write' { $fixture.Adapters.WriteEpoch = { param($InstallRoot, $Value) throw [Management.Automation.ErrorRecord]::new([IO.IOException]::new('write failure'),'CCOD_ATOMIC_REPLACE_FAILED',[Management.Automation.ErrorCategory]::WriteError,$InstallRoot) } }
                'readback' { $fixture.Adapters.ReadEpoch = { param($InstallRoot, $AllowInitial) if ($AllowInitial) { return [UInt64]0 }; return [UInt64]0 } }
            }
            $expected = if ($case -eq 'max') { 'CCOD_LIFECYCLE_EPOCH_EXHAUSTED' } elseif ($case -eq 'readback') { 'CCOD_LIFECYCLE_EPOCH_UNPROVEN' } elseif ($case -eq 'write') { 'CCOD_LIFECYCLE_EPOCH_WRITE_FAILED' } else { 'CCOD_LIFECYCLE_EPOCH_INVALID' }
            Assert-CcodThrows { Enter-CcodLifecycleOwnership -InstallRoot $root -RuntimeId '2.5.0-a' -RuntimeGeneration 3 -OwnerIdentity $owner -UserSid 'S-1-5-21-1-2-3-1001' -SessionId 2 -Adapters $fixture.Adapters } $expected
        }
    }

    Invoke-CcodTest 'fences runtime generation and exact PID creation identity and releases idempotently' {
        $fixture = New-CcodEpochAdapters
        $owner = [pscustomobject][ordered]@{pid=101;creationTimeUtc='2030-02-03T04:05:06.0000000Z'}
        $ownership = Enter-CcodLifecycleOwnership -InstallRoot $root -RuntimeId '2.5.0-a' -RuntimeGeneration 3 -OwnerIdentity $owner -UserSid 'S-1-5-21-1-2-3-1001' -SessionId 2 -Adapters $fixture.Adapters
        $fixture.Store.Generation = 4
        Assert-CcodThrows { Assert-CcodLifecycleFence -InstallRoot $root -Ownership $ownership -Adapters $fixture.Adapters } 'CCOD_LIFECYCLE_FENCE_STALE'
        $fixture.Store.Generation = 3
        $fixture.Store.RuntimeId = '2.4.9-rollback'
        Assert-CcodThrows { Assert-CcodLifecycleFence -InstallRoot $root -Ownership $ownership -Adapters $fixture.Adapters } 'CCOD_LIFECYCLE_FENCE_STALE'
        $fixture.Store.RuntimeId = '2.5.0-a'
        $fixture.Store.ProcessIdentity = [pscustomobject][ordered]@{pid=101;creationTimeUtc='2030-02-03T04:05:07.0000000Z'}
        Assert-CcodThrows { Assert-CcodLifecycleFence -InstallRoot $root -Ownership $ownership -Adapters $fixture.Adapters } 'CCOD_LIFECYCLE_FENCE_STALE'
        Assert-CcodEqual $true (Exit-CcodLifecycleOwnership -Ownership $ownership -Adapters $fixture.Adapters) 'first release exits the kernel lease'
        Assert-CcodEqual $false (Exit-CcodLifecycleOwnership -Ownership $ownership -Adapters $fixture.Adapters) 'second release is idempotent'
        Assert-CcodEqual $true $ownership.released 'ownership receipt records release'
    }

    Invoke-CcodTest 'accepts abandoned ownership, preserves crash gaps across a reboot simulation, and rejects an invalid active generation' {
        $fixture = New-CcodEpochAdapters -Epoch 7
        $fixture.Store.Initialized = $true
        $fixture.Adapters.EnterMutex = { param($UserSid, $SessionId, $TimeoutMilliseconds) New-CcodEpochTestLease -Abandoned $true }
        $owner = [pscustomobject][ordered]@{pid=101;creationTimeUtc='2030-02-03T04:05:06.0000000Z'}
        $afterCrash = Enter-CcodLifecycleOwnership -InstallRoot $root -RuntimeId '2.5.0-a' -RuntimeGeneration 3 -OwnerIdentity $owner -UserSid 'S-1-5-21-1-2-3-1001' -SessionId 2 -Adapters $fixture.Adapters
        Assert-CcodEqual 8 ([UInt64]$afterCrash.epoch) 'a crash gap resumes at the durable next epoch without reuse'
        Exit-CcodLifecycleOwnership -Ownership $afterCrash -Adapters $fixture.Adapters | Out-Null
        $rebooted = New-CcodEpochAdapters -Epoch ([UInt64]$fixture.Store.Epoch)
        $rebooted.Store.Initialized = $true
        $afterReboot = Enter-CcodLifecycleOwnership -InstallRoot $root -RuntimeId '2.5.0-a' -RuntimeGeneration 3 -OwnerIdentity $owner -UserSid 'S-1-5-21-1-2-3-1001' -SessionId 2 -Adapters $rebooted.Adapters
        Assert-CcodEqual 9 ([UInt64]$afterReboot.epoch) 'reboot simulation never resets the durable lifecycle epoch'
        $rebooted.Adapters.ReadActiveRuntime = { param($InstallRoot) [pscustomobject][ordered]@{ schemaVersion=2; activeRuntime='2.5.0-a'; previousRuntime=$null; generation=-1; updatedAtUtc='2030-02-03T04:05:06.0000000Z' } }
        Assert-CcodThrows { Assert-CcodLifecycleFence -InstallRoot $root -Ownership $afterReboot -Adapters $rebooted.Adapters } 'CCOD_LIFECYCLE_FENCE_STALE'
        Exit-CcodLifecycleOwnership -Ownership $afterReboot -Adapters $rebooted.Adapters | Out-Null
    }

    Invoke-CcodTest 'uses the ACL-validated account transition mutex for a real current-user acquisition' {
        $integrationRoot = Join-Path $root 'kernel-integration'
        [IO.Directory]::CreateDirectory($integrationRoot) | Out-Null
        $windowsIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $process = [Diagnostics.Process]::GetCurrentProcess()
        try {
            $owner = [pscustomobject][ordered]@{ pid=[int]$process.Id; creationTimeUtc=$process.StartTime.ToUniversalTime().ToString('o') }
            $ownership = Enter-CcodLifecycleOwnership -InstallRoot $integrationRoot -RuntimeId '2.5.0-a' -RuntimeGeneration 1 -OwnerIdentity $owner -UserSid $windowsIdentity.User.Value -SessionId ([int]$process.SessionId) -TimeoutMilliseconds 1000
            Assert-CcodEqual 1 ([UInt64]$ownership.epoch) 'fresh durable state begins at epoch one through the real mutex'
            Assert-CcodEpochTestFileAcl -Path (Join-Path $integrationRoot 'state\lifecycle-epoch.initialized.json') -UserSid $windowsIdentity.User.Value
            Assert-CcodEpochTestFileAcl -Path (Join-Path $integrationRoot 'state\lifecycle-epoch.json') -UserSid $windowsIdentity.User.Value
            Assert-CcodEqual $true (Exit-CcodLifecycleOwnership -Ownership $ownership) 'real mutex ownership is released'
        } finally {
            $process.Dispose()
            $windowsIdentity.Dispose()
        }
    }

    Invoke-CcodTest 'recognizes a persisted UInt64 maximum as exhausted without treating it as a floating value' {
        $maximumRoot = Join-Path $root 'persisted-maximum'
        [IO.Directory]::CreateDirectory((Join-Path $maximumRoot 'state')) | Out-Null
        [IO.File]::WriteAllText((Join-Path $maximumRoot 'state\lifecycle-epoch.json'), (([ordered]@{ schemaVersion=1; epoch=[UInt64]::MaxValue }) | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
        $owner = [pscustomobject][ordered]@{pid=101;creationTimeUtc='2030-02-03T04:05:06.0000000Z'}
        $mutexOnly = @{ EnterMutex = { param($UserSid, $SessionId, $TimeoutMilliseconds) New-CcodEpochTestLease }; ExitMutex = { param($Lease) $Lease.Released = $true; $true }; AssertEpochFileAcl = { param($Path) }; CreateEpochFile = { param($Path) } }
        Assert-CcodThrows { Enter-CcodLifecycleOwnership -InstallRoot $maximumRoot -RuntimeId '2.5.0-a' -RuntimeGeneration 1 -OwnerIdentity $owner -UserSid 'S-1-5-21-1-2-3-1001' -SessionId 2 -Adapters $mutexOnly } 'CCOD_LIFECYCLE_EPOCH_EXHAUSTED'
    }

    Invoke-CcodTest 'does not reuse epoch one when a crash deletes the first epoch file before active runtime creation' {
        $missingRoot = Join-Path $root 'missing-after-first-write'
        [IO.Directory]::CreateDirectory($missingRoot) | Out-Null
        $owner = [pscustomobject][ordered]@{pid=101;creationTimeUtc='2030-02-03T04:05:06.0000000Z'}
        $mutexOnly = @{ EnterMutex = { param($UserSid, $SessionId, $TimeoutMilliseconds) New-CcodEpochTestLease }; ExitMutex = { param($Lease) $Lease.Released = $true; $true } }
        $first = Enter-CcodLifecycleOwnership -InstallRoot $missingRoot -RuntimeId '2.5.0-a' -RuntimeGeneration 1 -OwnerIdentity $owner -UserSid 'S-1-5-21-1-2-3-1001' -SessionId 2 -Adapters $mutexOnly
        Exit-CcodLifecycleOwnership -Ownership $first -Adapters $mutexOnly | Out-Null
        [IO.File]::Delete((Join-Path $missingRoot 'state\lifecycle-epoch.json'))
        Assert-CcodThrows { Enter-CcodLifecycleOwnership -InstallRoot $missingRoot -RuntimeId '2.5.0-a' -RuntimeGeneration 1 -OwnerIdentity $owner -UserSid 'S-1-5-21-1-2-3-1001' -SessionId 2 -Adapters $mutexOnly } 'CCOD_LIFECYCLE_EPOCH_INVALID'
    }

    Invoke-CcodTest 'fails closed before reading an epoch file whose current-user ACL proof is rejected' {
        $fixture = New-CcodEpochAdapters
        [IO.Directory]::CreateDirectory((Join-Path $root 'state')) | Out-Null
        [IO.File]::WriteAllText((Join-Path $root 'state\lifecycle-epoch.json'), '{"schemaVersion":1,"epoch":1}', [Text.UTF8Encoding]::new($false))
        $fixture.Adapters.AssertEpochFileAcl = { param($Path) throw [Management.Automation.ErrorRecord]::new([UnauthorizedAccessException]::new('acl mismatch'),'CCOD_TEST_ACL',[Management.Automation.ErrorCategory]::SecurityError,$Path) }
        Assert-CcodThrows { Read-CcodLifecycleEpoch -InstallRoot $root -AllowInitial -Adapters $fixture.Adapters } 'CCOD_LIFECYCLE_EPOCH_ACL_INVALID'
    }

    Invoke-CcodTest 'fails closed when the initialization marker ACL cannot be proven' {
        $aclRoot = Join-Path $root 'marker-acl'
        [IO.Directory]::CreateDirectory((Join-Path $aclRoot 'state')) | Out-Null
        [IO.File]::WriteAllText((Join-Path $aclRoot 'state\lifecycle-epoch.initialized.json'), '{"schemaVersion":1}', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $aclRoot 'state\lifecycle-epoch.json'), '{"schemaVersion":1,"epoch":1}', [Text.UTF8Encoding]::new($false))
        $adapters = @{
            AssertEpochFileAcl = { param($Path) if ($Path.EndsWith('lifecycle-epoch.initialized.json', [StringComparison]::OrdinalIgnoreCase)) { throw 'marker acl mismatch' } }
            CreateEpochFile = { param($Path) }
        }
        Assert-CcodThrows { Read-CcodLifecycleEpoch -InstallRoot $aclRoot -Adapters $adapters } 'CCOD_LIFECYCLE_EPOCH_ACL_INVALID'
    }

    Invoke-CcodTest 'rejects an exact integral Decimal beyond UInt64 range' {
        $fixture = New-CcodEpochAdapters
        $fixture.Adapters.ReadEpoch = { param($InstallRoot, $AllowInitial) [decimal]::Parse('18446744073709551616', [Globalization.CultureInfo]::InvariantCulture) }
        Assert-CcodThrows { Read-CcodLifecycleEpoch -InstallRoot $root -Adapters $fixture.Adapters } 'CCOD_LIFECYCLE_EPOCH_INVALID'
    }
} catch {
    Write-Error $_
    exit 1
}
