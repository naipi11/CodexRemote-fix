$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestSupport.ps1')

$repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module (Join-Path $repositoryRoot 'src\persistence\modules\TrustedLogonIdentity.psm1') -Force

function New-CcodTrustedIdentityAdapters {
    param(
        [int]$HighPart = 0,
        [int]$LowPart = 999,
        [string]$UserSid = 'S-1-5-21-1-2-3-1001',
        [int]$SessionId = 2
    )

    return @{
        GetTokenStatistics = { [pscustomobject][ordered]@{ AuthenticationHighPart=$HighPart; AuthenticationLowPart=$LowPart } }.GetNewClosure()
        GetCurrentUserSid = { $UserSid }.GetNewClosure()
        GetCurrentSessionId = { $SessionId }.GetNewClosure()
    }
}

function New-CcodTrustedIdentity {
    param([int]$HighPart = 0, [int]$LowPart = 999, [string]$UserSid = 'S-1-5-21-1-2-3-1001', [int]$SessionId = 2)
    return Get-CcodTrustedLogonIdentity -Adapters (New-CcodTrustedIdentityAdapters -HighPart $HighPart -LowPart $LowPart -UserSid $UserSid -SessionId $SessionId)
}

function New-CcodSafeExitFixtureRoot([string]$Root, [string]$Name) {
    $state = Join-Path $Root $Name
    [IO.Directory]::CreateDirectory((Join-Path $state 'lifecycle')) | Out-Null
    return $state
}

function Get-CcodSafeExitIntentPath([string]$StateRoot) {
    return Join-Path $StateRoot 'lifecycle\safe-exit-intent.json'
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('ccod-trusted-logon-selftest-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root) | Out-Null
try {
    Invoke-CcodTest 'encodes the current token AuthenticationId as a fixed-width trusted identity' {
        $identity = New-CcodTrustedIdentity

        Assert-CcodEqual 'authenticationId,userSid,sessionId' (($identity.PSObject.Properties.Name) -join ',') 'identity has the exact ordered shape'
        Assert-CcodEqual '00000000:000003E7' $identity.authenticationId 'LUID has canonical fixed-width encoding'
        Assert-CcodEqual 'S-1-5-21-1-2-3-1001' $identity.userSid 'identity takes the current token user SID'
        Assert-CcodEqual 2 $identity.sessionId 'identity takes the current process session'
    }

    Invoke-CcodTest 'fails closed when a token fact is malformed unavailable or contains extra fields' {
        $invalid = @(
            @{ GetTokenStatistics={ throw 'token query failed' }; GetCurrentUserSid={ 'S-1-5-21-1-2-3-1001' }; GetCurrentSessionId={ 2 } },
            @{ GetTokenStatistics={ [pscustomobject][ordered]@{ AuthenticationHighPart=0; AuthenticationLowPart=1; Unexpected=2 } }; GetCurrentUserSid={ 'S-1-5-21-1-2-3-1001' }; GetCurrentSessionId={ 2 } },
            @{ GetTokenStatistics={ [pscustomobject][ordered]@{ AuthenticationHighPart=0; AuthenticationLowPart=1 } }; GetCurrentUserSid={ 'S-1-05-21-1-2-3-1001' }; GetCurrentSessionId={ 2 } },
            @{ GetTokenStatistics={ [pscustomobject][ordered]@{ AuthenticationHighPart=0; AuthenticationLowPart=1 } }; GetCurrentUserSid={ 'S-1-5-21-1-2-3-1001' }; GetCurrentSessionId={ -1 } }
        )
        foreach ($adapters in $invalid) {
            Assert-CcodThrows { Get-CcodTrustedLogonIdentity -Adapters $adapters } 'CCOD_LOGON_IDENTITY_UNAVAILABLE'
        }
    }

    Invoke-CcodTest 'persists and reads an exact safe-exit intent through the atomic state path' {
        $state = New-CcodSafeExitFixtureRoot -Root $root -Name 'round-trip'
        $identity = New-CcodTrustedIdentity
        $intent = Write-CcodSafeExitIntent -StateRoot $state -LogonIdentity $identity -RuntimeId '2.5.0-a' -RecoveryTransactionId '11111111-2222-3333-4444-555555555555' -NowUtc '2030-02-03T04:05:06.0000000Z'
        $read = Read-CcodSafeExitIntent -StateRoot $state

        Assert-CcodEqual 'schemaVersion,logonIdentity,runtimeId,recoveryTransactionId,createdAtUtc' (($intent.PSObject.Properties.Name) -join ',') 'intent has the exact ordered shape'
        Assert-CcodEqual 'authenticationId,userSid,sessionId' (($intent.logonIdentity.PSObject.Properties.Name) -join ',') 'persisted logon identity has the exact ordered shape'
        Assert-CcodEqual 1 $intent.schemaVersion 'safe-exit intent schema is one'
        Assert-CcodEqual '2.5.0-a' $read.runtimeId 'atomic write is read back from the safe-exit path'
        Assert-CcodTrue (Test-CcodSafeExitIntentForCurrentLogon -Intent $read -LogonIdentity $identity) 'same trusted logon is suppressed'
    }

    Invoke-CcodTest 'requires all trusted identity fields so reconnect switches and reboots cannot suppress startup' {
        $state = New-CcodSafeExitFixtureRoot -Root $root -Name 'identity-comparison'
        $current = New-CcodTrustedIdentity
        $intent = Write-CcodSafeExitIntent -StateRoot $state -LogonIdentity $current -RuntimeId '2.5.0-a' -RecoveryTransactionId '11111111-2222-3333-4444-555555555555' -NowUtc '2030-02-03T04:05:06.0000000Z'

        Assert-CcodTrue (Test-CcodSafeExitIntentForCurrentLogon -Intent $intent -LogonIdentity (New-CcodTrustedIdentity)) 'RDP reconnect in the same logon session is suppressed'
        foreach ($other in @(
            (New-CcodTrustedIdentity -UserSid 'S-1-5-21-1-2-3-2002'),
            (New-CcodTrustedIdentity -HighPart 1 -LowPart 999),
            (New-CcodTrustedIdentity -SessionId 7)
        )) {
            Assert-CcodEqual $false (Test-CcodSafeExitIntentForCurrentLogon -Intent $intent -LogonIdentity $other) 'SID switch LUID reuse and session mismatch do not suppress a new logon'
        }
    }

    Invoke-CcodTest 'treats a missing marker as absent and malformed reparse or cross-user evidence as fail closed' {
        $missingState = New-CcodSafeExitFixtureRoot -Root $root -Name 'missing'
        Assert-CcodEqual $null (Read-CcodSafeExitIntent -StateRoot $missingState) 'missing marker has no safe-exit intent'

        $malformedState = New-CcodSafeExitFixtureRoot -Root $root -Name 'malformed'
        Write-CcodSafeExitIntent -StateRoot $malformedState -LogonIdentity (New-CcodTrustedIdentity) -RuntimeId '2.5.0-a' -RecoveryTransactionId '11111111-2222-3333-4444-555555555555' -NowUtc '2030-02-03T04:05:06.0000000Z'
        [IO.File]::WriteAllText((Get-CcodSafeExitIntentPath $malformedState), '{broken', [Text.UTF8Encoding]::new($false))
        Assert-CcodThrows { Read-CcodSafeExitIntent -StateRoot $malformedState } 'CCOD_SAFE_EXIT_INTENT_INVALID'

        $identity = New-CcodTrustedIdentity
        $aclState = New-CcodSafeExitFixtureRoot -Root $root -Name 'acl'
        Write-CcodSafeExitIntent -StateRoot $aclState -LogonIdentity $identity -RuntimeId '2.5.0-a' -RecoveryTransactionId '11111111-2222-3333-4444-555555555555' -NowUtc '2030-02-03T04:05:06.0000000Z'
        Assert-CcodThrows { Read-CcodSafeExitIntent -StateRoot $aclState -Adapters @{ AssertSafeExitFileAcl={ param($Path) throw 'foreign user access' } } } 'CCOD_SAFE_EXIT_INTENT_ACL_INVALID'
        Assert-CcodThrows { Read-CcodSafeExitIntent -StateRoot $aclState -Adapters @{ ResolveSafeExitIntentPath={ param($StateRoot) throw 'reparse path' } } } 'CCOD_SAFE_EXIT_INTENT_INVALID'
    }

    Invoke-CcodTest 'clears only a validated marker and reports whether one was removed' {
        $state = New-CcodSafeExitFixtureRoot -Root $root -Name 'clear'
        $identity = New-CcodTrustedIdentity
        Write-CcodSafeExitIntent -StateRoot $state -LogonIdentity $identity -RuntimeId '2.5.0-a' -RecoveryTransactionId '11111111-2222-3333-4444-555555555555' -NowUtc '2030-02-03T04:05:06.0000000Z'

        Assert-CcodEqual $true (Clear-CcodSafeExitIntent -StateRoot $state) 'explicit clear removes a validated marker'
        Assert-CcodEqual $false (Clear-CcodSafeExitIntent -StateRoot $state) 'explicit clear reports an already-missing marker'
    }
} catch {
    Write-Error $_
    exit 1
} finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
