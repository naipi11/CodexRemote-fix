$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestSupport.ps1')

$repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$bootstrapScript = Join-Path $repositoryRoot 'src\persistence\UninstallBootstrap.ps1'

if (-not (Test-Path -LiteralPath $bootstrapScript -PathType Leaf)) {
    throw "Uninstall bootstrap script is missing: $bootstrapScript"
}

. $bootstrapScript
Import-Module (Join-Path $repositoryRoot 'src\persistence\modules\RuntimeManifest.psm1') -Force

function New-CcodUninstallBootstrapContext {
    return [pscustomobject][ordered]@{
        runtimeId = '2.5.0-uninstall-test'
        runtimeGeneration = [uint64]7
        leaseEpoch = [uint64]11
        userSid = 'S-1-5-21-111-222-333-1001'
        sessionId = 1
        payloadEntries = @('src/persistence/UninstallBootstrap.ps1','src/persistence/modules/InstallLifecycle.psm1')
    }
}

function New-CcodUninstallBootstrapTestTransaction {
    param(
        [string]$Phase = 'Requested',
        [AllowNull()]$ErrorCode = $null,
        [string]$TransactionId = '11111111-2222-3333-4444-555555555555'
    )

    return [pscustomobject][ordered]@{
        schemaVersion = 1
        transactionId = $TransactionId
        runtimeId = '2.5.0-uninstall-test'
        runtimeGeneration = [uint64]7
        leaseEpoch = [uint64]11
        userSid = 'S-1-5-21-111-222-333-1001'
        sessionId = 1
        phase = $Phase
        resumePhase = $Phase
        startedAtUtc = '2030-02-03T03:04:05.0000000Z'
        updatedAtUtc = '2030-02-03T03:04:05.0000000Z'
        errorCode = $ErrorCode
    }
}

function New-CcodUninstallBootstrapAdapters {
    param([Parameter(Mandatory)]$World)

    return @{
        ValidateInvocation = {
            param($InstallerRoot,$InstallRoot)
            [void]$World.Calls.Add('Validate')
            if ($World.ValidationError) {
                throw [Management.Automation.ErrorRecord]::new([InvalidOperationException]::new('invalid bootstrap context'),'CCOD_UNINSTALL_BOOTSTRAP_INVALID',[Management.Automation.ErrorCategory]::InvalidData,$InstallRoot)
            }
            return [pscustomobject][ordered]@{
                runtimeId = '2.5.0-uninstall-test'
                runtimeGeneration = [uint64]7
                leaseEpoch = [uint64]11
                userSid = 'S-1-5-21-111-222-333-1001'
                sessionId = 1
                payloadEntries = @('src/persistence/UninstallBootstrap.ps1','src/persistence/modules/InstallLifecycle.psm1')
            }
        }.GetNewClosure()
        GetTransactionRoot = {
            [void]$World.Calls.Add('GetRoot')
            return 'C:\ccod-uninstall-test'
        }.GetNewClosure()
        ReadTransaction = {
            param($TransactionRoot)
            [void]$World.Calls.Add('Read')
            return $World.Transaction
        }.GetNewClosure()
        ValidateFinalizationInvocation = {
            param($TransactionRoot,$Transaction,$Identity)
            [void]$World.Calls.Add('FinalizeInvocation')
        }.GetNewClosure()
        GetTransactionDirectory = {
            param($TransactionRoot,$TransactionId)
            return 'C:\ccod-uninstall-test\' + $TransactionId
        }.GetNewClosure()
        NewTransactionId = {
            [void]$World.Calls.Add('NewId')
            return '11111111-2222-3333-4444-555555555555'
        }.GetNewClosure()
        CreateTransactionRoot = {
            param($TransactionRoot,$TransactionId,$UserSid)
            [void]$World.Calls.Add('Create')
            return 'C:\ccod-uninstall-test\11111111-2222-3333-4444-555555555555'
        }.GetNewClosure()
        PublishTransaction = {
            param($TransactionRoot,$TransactionId,$UserSid,$ReplaceCompletedLocator)
            [void]$World.Calls.Add('Publish')
        }.GetNewClosure()
        StagePayload = {
            param($InstallerRoot,$InstallRoot,$Context,$TransactionRoot)
            [void]$World.Calls.Add('Stage')
            if ($World.StageError) {
                throw [Management.Automation.ErrorRecord]::new([InvalidOperationException]::new('payload hash proof failed'),'CCOD_UNINSTALL_PAYLOAD_HASH_MISMATCH',[Management.Automation.ErrorCategory]::InvalidData,$TransactionRoot)
            }
            [void]($World.StagedEntries = @($Context.payloadEntries))
        }.GetNewClosure()
        WriteTransaction = {
            param($TransactionRoot,$Transaction)
            [void]$World.Calls.Add("Write:$($Transaction.phase)")
            [void]($World.Transaction = $Transaction)
        }.GetNewClosure()
        WriteReceipt = {
            param($TransactionRoot,$Transaction)
            [void]$World.Calls.Add("Receipt:$($Transaction.phase)")
            [void]($World.Receipt = $Transaction)
        }.GetNewClosure()
        RunCleanup = {
            param($InstallerRoot,$InstallRoot,$TransactionRoot,$Transaction,$WriteTransaction)
            [void]$World.Calls.Add('Cleanup')
            if ($World.CleanupError) {
                if ($World.CleanupFailurePhase) {
                    [void]($Transaction.phase = [string]$World.CleanupFailurePhase)
                    [void]($Transaction.resumePhase = [string]$World.CleanupFailurePhase)
                    & $WriteTransaction $TransactionRoot $Transaction
                }
                throw [Management.Automation.ErrorRecord]::new([InvalidOperationException]::new('recovery was not proven'),'CCOD_UNINSTALL_RECOVERY_FAILED',[Management.Automation.ErrorCategory]::OperationStopped,$Transaction)
            }
            [void]($Transaction.phase = 'ReadyForInno')
            [void]($Transaction.resumePhase = 'ReadyForInno')
            [void]($Transaction.updatedAtUtc = '2030-02-03T03:04:06.0000000Z')
            [void]($Transaction.errorCode = $null)
            & $WriteTransaction $TransactionRoot $Transaction
            return $Transaction
        }.GetNewClosure()
        TestInstallRootAbsent = {
            param($InstallRoot)
            [void]$World.Calls.Add('RootAbsent')
            return [bool]$World.InstallRootAbsent
        }.GetNewClosure()
        GetUtcNow = {
            return [DateTime]::Parse('2030-02-03T03:04:05Z').ToUniversalTime()
        }
    }
}

function Set-CcodUninstallBootstrapFixtureDirectoryOwner {
    param([Parameter(Mandatory)][string]$Path)
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $security = [IO.Directory]::GetAccessControl($Path)
        $security.SetOwner($identity.User)
        [IO.Directory]::SetAccessControl($Path,$security)
        $owner = [IO.Directory]::GetAccessControl($Path).GetOwner([Security.Principal.SecurityIdentifier])
        Assert-CcodEqual $identity.User.Value $owner.Value 'installed-root fixture owner is the current user'
    } finally {
        $identity.Dispose()
    }
}

function New-CcodVerifiedUninstallRuntimeFixture {
    param([Parameter(Mandatory)][string]$InstallRoot)
    $runtimeRoot = Join-Path $InstallRoot 'runtime\pending'
    foreach ($entry in @(
        'src/persistence/UninstallBootstrap.ps1',
        'src/persistence/modules/InstallLifecycle.psm1',
        'src/persistence/modules/PersistenceIO.psm1',
        'src/persistence/modules/RuntimeManifest.psm1',
        'src/persistence/modules/LifecycleEpoch.psm1',
        'src/persistence/modules/StateStore.psm1',
        'src/persistence/modules/TrustedLogonIdentity.psm1',
        'src/persistence/modules/ScheduledTask.psm1',
        'src/persistence/modules/KernelObjects.psm1',
        'src/persistence/modules/CompatibilityProbe.psm1',
        'src/persistence/modules/UiPreferences.psm1',
        'src/persistence/modules/LifecycleTransaction.psm1'
    )) {
        $source = Join-Path $repositoryRoot $entry
        $destination = Join-Path $runtimeRoot $entry
        [IO.Directory]::CreateDirectory((Split-Path $destination -Parent)) | Out-Null
        [IO.File]::Copy($source,$destination,$true)
    }
    $manifest = New-CcodRuntimeManifest -RuntimeDirectory $runtimeRoot -ProjectVersion '2.5.0-uninstall-test'
    $finalRuntime = Join-Path $InstallRoot ('runtime\' + $manifest.runtimeId)
    [IO.Directory]::Move($runtimeRoot,$finalRuntime)
    [IO.File]::WriteAllText((Join-Path $finalRuntime 'manifest.json'),($manifest | ConvertTo-Json -Depth 16),[Text.UTF8Encoding]::new($false))
    [IO.Directory]::CreateDirectory((Join-Path $InstallRoot 'state')) | Out-Null
    Set-CcodUninstallBootstrapFixtureDirectoryOwner -Path $InstallRoot
    $timestamp = '2030-02-03T03:04:05.0000000Z'
    [IO.File]::WriteAllText((Join-Path $InstallRoot 'active.json'),([ordered]@{schemaVersion=2;activeRuntime=$manifest.runtimeId;previousRuntime=$null;generation=[uint64]7;updatedAtUtc=$timestamp}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $InstallRoot 'state\lifecycle-epoch.json'),([ordered]@{schemaVersion=1;epoch=[uint64]11}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    return [pscustomobject][ordered]@{RuntimeRoot=$finalRuntime;RuntimeId=$manifest.runtimeId}
}

$results = @()

$results += Invoke-CcodTest 'Prepare stages only the manifest-bound cleanup payload and reaches the Inno boundary' {
    $world = [pscustomobject]@{
        Calls = [Collections.Generic.List[string]]::new()
        Transaction = $null
        Receipt = $null
        ValidationError = $false
        StageError = $false
        CleanupError = $false
        CleanupFailurePhase = $null
        InstallRootAbsent = $false
        StagedEntries = @()
    }
    $receipt = Invoke-CcodUninstallBootstrap -InstallerRoot 'C:\installer' -InstallRoot 'C:\install' -Mode Prepare -Adapters (New-CcodUninstallBootstrapAdapters $world)
    Assert-CcodEqual 'ReadyForInno' $receipt.phase 'verified cleanup reaches the Inno boundary'
    Assert-CcodEqual 'Validate,GetRoot,Read,NewId,Create,Write:Requested,Publish,Stage,Cleanup,Write:ReadyForInno,Receipt:ReadyForInno' ($world.Calls -join ',') 'Prepare publishes a recoverable transaction only after its durable transaction record exists'
    Assert-CcodEqual 'src/persistence/UninstallBootstrap.ps1,src/persistence/modules/InstallLifecycle.psm1' ($world.StagedEntries -join ',') 'staging has no device-key material'
    Assert-CcodEqual $null $receipt.errorCode 'ReadyForInno carries no failure code'
}

$results += Invoke-CcodTest 'production runtime verification binds the installed bootstrap to an exact manifest and rejects a hash change' {
    $localAppData = Join-Path ([IO.Path]::GetTempPath()) ('ccod-uninstall-bootstrap-' + [guid]::NewGuid().ToString('N'))
    $installRoot = Join-Path $localAppData 'CodexControlOtherDevices'
    $previousLocalAppData = [Environment]::GetEnvironmentVariable('LOCALAPPDATA','Process')
    try {
        [Environment]::SetEnvironmentVariable('LOCALAPPDATA',$localAppData,'Process')
        $fixture = New-CcodVerifiedUninstallRuntimeFixture -InstallRoot $installRoot
        $context = Get-CcodUninstallBootstrapVerifiedRuntimeContext -InstallerRoot $repositoryRoot -InstallRoot $installRoot
        Assert-CcodEqual $fixture.RuntimeId $context.runtimeId 'verified context binds the active manifest runtime'
        Assert-CcodEqual ([uint64]7) ([uint64]$context.runtimeGeneration) 'verified context binds active generation'
        Assert-CcodEqual ([uint64]11) ([uint64]$context.leaseEpoch) 'verified context binds lifecycle epoch'
        Assert-CcodEqual 12 @($context.payloadEntries).Count 'only the cleanup entry and its imported modules are staged'
        [IO.File]::AppendAllText((Join-Path $fixture.RuntimeRoot 'src\persistence\modules\InstallLifecycle.psm1'),'# altered',[Text.UTF8Encoding]::new($false))
        Assert-CcodThrows { Get-CcodUninstallBootstrapVerifiedRuntimeContext -InstallerRoot $repositoryRoot -InstallRoot $installRoot | Out-Null } 'CCOD_UNINSTALL_RUNTIME_INVALID'
    } finally {
        [Environment]::SetEnvironmentVariable('LOCALAPPDATA',$previousLocalAppData,'Process')
        if (Test-Path -LiteralPath $localAppData) { Remove-Item -LiteralPath $localAppData -Recurse -Force }
    }
}

$results += Invoke-CcodTest 'real external staging uses a protected current-user transaction directory and copies only verified cleanup inputs' {
    $testRoot = Join-Path ([IO.Path]::GetTempPath()) ('ccod-uninstall-stage-' + [guid]::NewGuid().ToString('N'))
    $localAppData = Join-Path $testRoot 'local-app-data'
    $installRoot = Join-Path $localAppData 'CodexControlOtherDevices'
    $transactionRoot = Join-Path $localAppData 'CodexRemote-fix-uninstall'
    $previousLocalAppData = [Environment]::GetEnvironmentVariable('LOCALAPPDATA','Process')
    try {
        [Environment]::SetEnvironmentVariable('LOCALAPPDATA',$localAppData,'Process')
        $fixture = New-CcodVerifiedUninstallRuntimeFixture -InstallRoot $installRoot
        $context = Get-CcodUninstallBootstrapVerifiedRuntimeContext -InstallerRoot $repositoryRoot -InstallRoot $installRoot
        Assert-CcodEqual $transactionRoot (Get-CcodUninstallBootstrapDefaultTransactionRoot) 'the external transaction root follows the same current-user LocalAppData boundary as the installed state root'
        $transactionId = [guid]::NewGuid().ToString('D')
        $transactionDirectory = New-CcodUninstallBootstrapTransactionDirectory -TransactionRoot $transactionRoot -TransactionId $transactionId -UserSid $context.userSid
        Assert-CcodEqual (Join-Path $transactionRoot $transactionId) $transactionDirectory 'transaction payload is directly under the documented external transaction ID root'
        Assert-CcodTrue (Test-CcodUninstallBootstrapCanonicalGuid ([IO.Path]::GetFileName($transactionDirectory))) 'transaction directory has a canonical GUID name'
        Assert-CcodUninstallBootstrapDirectoryAcl -Path $transactionRoot -UserSid $context.userSid
        Assert-CcodUninstallBootstrapDirectoryAcl -Path $transactionDirectory -UserSid $context.userSid
        Assert-CcodTrue (-not (Test-Path -LiteralPath (Join-Path $transactionRoot 'current.json'))) 'an uncommitted transaction directory is not published through the current locator'
        $transaction = New-CcodUninstallBootstrapTransaction -Context $context -TransactionId $transactionId -NowUtc ([DateTime]::UtcNow)
        Write-CcodUninstallBootstrapStoredTransaction -TransactionDirectory $transactionDirectory -Transaction $transaction
        Publish-CcodUninstallBootstrapCurrentTransaction -TransactionRoot $transactionRoot -TransactionId $transactionId -UserSid $context.userSid
        $stored = Read-CcodUninstallBootstrapStoredTransaction -TransactionRoot $transactionRoot -ExpectedUserSid $context.userSid -IncludeCompleted
        Assert-CcodEqual $transactionId $stored.transactionId 'the locator is published only after a readable transaction record exists'
        Stage-CcodUninstallBootstrapPayload -InstallRoot $installRoot -Context $context -TransactionDirectory $transactionDirectory
        $payloadRoot = Join-Path $transactionDirectory 'payload'
        Assert-CcodUninstallBootstrapDirectoryAcl -Path $payloadRoot -UserSid $context.userSid
        $payloadFiles = @(Get-ChildItem -LiteralPath $payloadRoot -Recurse -File -Force)
        Assert-CcodEqual 12 $payloadFiles.Count 'external payload contains the exact cleanup entry and required modules'
        foreach ($entry in @($context.payloadEntries)) {
            $source = Join-Path $fixture.RuntimeRoot ($entry.Replace('/','\'))
            $staged = Join-Path $payloadRoot ($entry.Replace('/','\'))
            Assert-CcodTrue (Test-Path -LiteralPath $staged -PathType Leaf) "manifest-bound payload entry $entry is staged"
            Assert-CcodEqual (Get-CcodTestFileSha256 $source) (Get-CcodTestFileSha256 $staged) "manifest-bound payload entry $entry retains its verified hash"
        }
        $stagedInstallLifecycle = Join-Path $payloadRoot 'src\persistence\modules\InstallLifecycle.psm1'
        $importCommand = '$ErrorActionPreference = ''Stop''; $module = Import-Module -Name ''' + $stagedInstallLifecycle.Replace("'","''") + ''' -Force -PassThru -ErrorAction Stop; Remove-Module -Name $module.Name -Force -ErrorAction Stop'
        $encodedImportCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($importCommand))
        $importOutput = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encodedImportCommand 2>&1)
        Assert-CcodEqual 0 $LASTEXITCODE 'staged InstallLifecycle imports its complete payload-local dependency closure before cleanup'
        Assert-CcodEqual 0 $importOutput.Count 'successful staged InstallLifecycle import emits no untrusted output'
        Assert-CcodEqual 0 (@($payloadFiles | Where-Object { $_.Name -match 'device|key|credential' })).Count 'external payload has no device key or credential material'
        $stagedBootstrap = Join-Path $payloadRoot 'src\persistence\UninstallBootstrap.ps1'
        $transaction.phase = 'ReadyForInno'
        $transaction.resumePhase = 'ReadyForInno'
        $transaction.updatedAtUtc = [DateTime]::UtcNow.ToString('o',[Globalization.CultureInfo]::InvariantCulture)
        Write-CcodUninstallBootstrapStoredTransaction -TransactionDirectory $transactionDirectory -Transaction $transaction
        $removedInstallerRoot = Join-Path $testRoot 'removed-installer-root'
        $finalizeCommand = "`$env:LOCALAPPDATA = '$($localAppData.Replace("'","''"))'; . '$($stagedBootstrap.Replace("'","''"))'; `$finalReceipt = Invoke-CcodUninstallBootstrap -InstallerRoot '$($removedInstallerRoot.Replace("'","''"))' -InstallRoot '$($installRoot.Replace("'","''"))' -Mode FinalizeReceipt; if (`$finalReceipt.phase -ne 'Completed') { throw 'staged finalization did not reach Completed' }"
        $encodedFinalizeCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($finalizeCommand))
        $blockedFinalizeCommand = "`$env:LOCALAPPDATA = '$($localAppData.Replace("'","''"))'; . '$($stagedBootstrap.Replace("'","''"))'; try { `$null = Invoke-CcodUninstallBootstrap -InstallerRoot '$($removedInstallerRoot.Replace("'","''"))' -InstallRoot '$($installRoot.Replace("'","''"))' -Mode FinalizeReceipt; exit 0 } catch { [Console]::Out.WriteLine([string]`$_.FullyQualifiedErrorId); exit 41 }"
        $encodedBlockedFinalizeCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($blockedFinalizeCommand))
        $heldTransactionLock = Enter-CcodUninstallBootstrapTransactionLock -UserSid $context.userSid
        try {
            $blockedOutput = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encodedBlockedFinalizeCommand 2>&1)
            $blockedExitCode = $LASTEXITCODE
            Assert-CcodTrue ($blockedExitCode -ne 0) 'a concurrent staged finalization cannot race the active transaction writer'
            Assert-CcodTrue (($blockedOutput -join "`n") -match 'CCOD_UNINSTALL_TRANSACTION_BUSY') 'the staged finalization reports the stable transaction-busy error'
            $blockedTransaction = Read-CcodUninstallBootstrapStoredTransaction -TransactionRoot $transactionRoot -ExpectedUserSid $context.userSid -IncludeCompleted
            Assert-CcodEqual 'ReadyForInno' $blockedTransaction.phase 'a blocked staged finalization leaves the durable transaction unchanged'
        } finally {
            Exit-CcodUninstallBootstrapTransactionLock -Lock $heldTransactionLock
        }
        $output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encodedFinalizeCommand 2>&1)
        Assert-CcodEqual 0 $LASTEXITCODE 'the staged bootstrap can finalize only after an absent installer-root proof'
        Assert-CcodEqual 0 $output.Count 'successful staged finalization emits no untrusted output'
        $completed = Read-CcodUninstallBootstrapStoredTransaction -TransactionRoot $transactionRoot -ExpectedUserSid $context.userSid -IncludeCompleted
        Assert-CcodEqual 'Completed' $completed.phase 'the exact staged bootstrap writes the durable completed receipt'
        Assert-CcodTrue (Test-Path -LiteralPath (Join-Path $transactionDirectory 'receipt.json') -PathType Leaf) 'staged finalization writes a separate durable receipt'
    } finally {
        [Environment]::SetEnvironmentVariable('LOCALAPPDATA',$previousLocalAppData,'Process')
        if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
    }
}

$results += Invoke-CcodTest 'Prepare rejects an invalid installer or active-runtime boundary before creating a transaction' {
    $world = [pscustomobject]@{
        Calls = [Collections.Generic.List[string]]::new()
        Transaction = $null
        Receipt = $null
        ValidationError = $true
        StageError = $false
        CleanupError = $false
        CleanupFailurePhase = $null
        InstallRootAbsent = $false
        StagedEntries = @()
    }
    Assert-CcodThrows { Invoke-CcodUninstallBootstrap -InstallerRoot 'C:\wrong-installer' -InstallRoot 'C:\install' -Mode Prepare -Adapters (New-CcodUninstallBootstrapAdapters $world) | Out-Null } 'CCOD_UNINSTALL_BOOTSTRAP_INVALID'
    Assert-CcodEqual 'Validate,GetRoot,Read' ($world.Calls -join ',') 'invalid roots, manifest, ACL, or reparse state cannot stage or clean up'
}

$results += Invoke-CcodTest 'Prepare resumes only the exact durable transaction and does not restage payload' {
    $world = [pscustomobject]@{
        Calls = [Collections.Generic.List[string]]::new()
        Transaction = (New-CcodUninstallBootstrapTestTransaction -Phase 'TaskRemoved')
        Receipt = $null
        ValidationError = $false
        StageError = $false
        CleanupError = $false
        CleanupFailurePhase = $null
        InstallRootAbsent = $false
        StagedEntries = @()
    }
    $receipt = Invoke-CcodUninstallBootstrap -InstallerRoot 'C:\installer' -InstallRoot 'C:\install' -Mode Prepare -Adapters (New-CcodUninstallBootstrapAdapters $world)
    Assert-CcodEqual 'ReadyForInno' $receipt.phase 'interrupted cleanup resumes to the Inno boundary'
    Assert-CcodEqual 'Validate,GetRoot,Read,Cleanup,Write:ReadyForInno,Receipt:ReadyForInno' ($world.Calls -join ',') 'resume reuses the durable transaction and never makes a second payload'
}

$results += Invoke-CcodTest 'Prepare resumes a TaskRemoved transaction even after the runtime root and active pointer have been deleted' {
    $localAppData = Join-Path ([IO.Path]::GetTempPath()) ('ccod-uninstall-resume-' + [guid]::NewGuid().ToString('N'))
    $installRoot = Join-Path $localAppData 'CodexControlOtherDevices'
    $previousLocalAppData = [Environment]::GetEnvironmentVariable('LOCALAPPDATA','Process')
    try {
        [Environment]::SetEnvironmentVariable('LOCALAPPDATA',$localAppData,'Process')
        $identity = Get-CcodUninstallBootstrapCurrentIdentity
        $transaction = New-CcodUninstallBootstrapTestTransaction -Phase 'TaskRemoved'
        $transaction.userSid = $identity.userSid
        $transaction.sessionId = [int]$identity.sessionId
        $world = [pscustomobject]@{
            Calls = [Collections.Generic.List[string]]::new()
            Transaction = $transaction
            Receipt = $null
            ValidationError = $true
            StageError = $false
            CleanupError = $false
            InstallRootAbsent = $false
            StagedEntries = @()
        }
        $receipt = Invoke-CcodUninstallBootstrap -InstallerRoot $repositoryRoot -InstallRoot $installRoot -Mode Prepare -Adapters (New-CcodUninstallBootstrapAdapters $world)
        Assert-CcodEqual 'ReadyForInno' $receipt.phase 'partial application deletion can resume without an active runtime pointer'
        Assert-CcodEqual 'Validate,GetRoot,Read,Cleanup,Write:ReadyForInno,Receipt:ReadyForInno' ($world.Calls -join ',') 'partial deletion resume neither creates another transaction nor restages payload'
    } finally {
        [Environment]::SetEnvironmentVariable('LOCALAPPDATA',$previousLocalAppData,'Process')
        if (Test-Path -LiteralPath $localAppData) { Remove-Item -LiteralPath $localAppData -Recurse -Force }
    }
}

$results += Invoke-CcodTest 'Prepare rejects a partial-deletion transaction from a different user before cleanup can resume' {
    $localAppData = Join-Path ([IO.Path]::GetTempPath()) ('ccod-uninstall-other-user-' + [guid]::NewGuid().ToString('N'))
    $installRoot = Join-Path $localAppData 'CodexControlOtherDevices'
    $previousLocalAppData = [Environment]::GetEnvironmentVariable('LOCALAPPDATA','Process')
    try {
        [Environment]::SetEnvironmentVariable('LOCALAPPDATA',$localAppData,'Process')
        $transaction = New-CcodUninstallBootstrapTestTransaction -Phase 'TaskRemoved'
        $transaction.userSid = 'S-1-5-21-999-888-777-1001'
        $world = [pscustomobject]@{
            Calls = [Collections.Generic.List[string]]::new()
            Transaction = $transaction
            Receipt = $null
            ValidationError = $true
            StageError = $false
            CleanupError = $false
            InstallRootAbsent = $false
            StagedEntries = @()
        }
        Assert-CcodThrows { Invoke-CcodUninstallBootstrap -InstallerRoot $repositoryRoot -InstallRoot $installRoot -Mode Prepare -Adapters (New-CcodUninstallBootstrapAdapters $world) | Out-Null } 'CCOD_UNINSTALL_TRANSACTION_MISMATCH'
        Assert-CcodEqual 'Validate,GetRoot,Read' ($world.Calls -join ',') 'another user cannot cause cleanup of a partial transaction'
    } finally {
        [Environment]::SetEnvironmentVariable('LOCALAPPDATA',$previousLocalAppData,'Process')
        if (Test-Path -LiteralPath $localAppData) { Remove-Item -LiteralPath $localAppData -Recurse -Force }
    }
}

$results += Invoke-CcodTest 'failed recovery writes Failed and leaves the staged transaction for retry' {
    $world = [pscustomobject]@{
        Calls = [Collections.Generic.List[string]]::new()
        Transaction = $null
        Receipt = $null
        ValidationError = $false
        StageError = $false
        CleanupError = $true
        CleanupFailurePhase = 'Recovering'
        InstallRootAbsent = $false
        StagedEntries = @()
    }
    Assert-CcodThrows { Invoke-CcodUninstallBootstrap -InstallerRoot 'C:\installer' -InstallRoot 'C:\install' -Mode Prepare -Adapters (New-CcodUninstallBootstrapAdapters $world) | Out-Null } 'CCOD_UNINSTALL_RECOVERY_FAILED'
    Assert-CcodEqual 'Failed' $world.Transaction.phase 'recovery failure is durable and retryable'
    Assert-CcodEqual 'Recovering' $world.Transaction.resumePhase 'recovery failure preserves the exact safe resume phase'
    Assert-CcodEqual 'CCOD_UNINSTALL_RECOVERY_FAILED' $world.Transaction.errorCode 'failure uses a bounded stable code'
    Assert-CcodTrue ($world.Calls -ccontains 'Stage') 'staged cleanup remains available for retry diagnostics'
    $world.Calls.Clear()
    $world.CleanupError = $false
    $receipt = Invoke-CcodUninstallBootstrap -InstallerRoot 'C:\installer' -InstallRoot 'C:\install' -Mode Prepare -Adapters (New-CcodUninstallBootstrapAdapters $world)
    Assert-CcodEqual 'ReadyForInno' $receipt.phase 'a recovery failure can resume after the proof becomes available'
    Assert-CcodEqual 'Validate,GetRoot,Read,Cleanup,Write:ReadyForInno,Receipt:ReadyForInno' ($world.Calls -join ',') 'recovery retry reuses the same payload without a second staging pass'
}

$results += Invoke-CcodTest 'payload staging failure writes a durable Failed transaction and receipt before Inno can delete files' {
    $world = [pscustomobject]@{
        Calls = [Collections.Generic.List[string]]::new()
        Transaction = $null
        Receipt = $null
        ValidationError = $false
        StageError = $true
        CleanupError = $false
        CleanupFailurePhase = $null
        InstallRootAbsent = $false
        StagedEntries = @()
    }
    Assert-CcodThrows { Invoke-CcodUninstallBootstrap -InstallerRoot 'C:\installer' -InstallRoot 'C:\install' -Mode Prepare -Adapters (New-CcodUninstallBootstrapAdapters $world) | Out-Null } 'CCOD_UNINSTALL_PAYLOAD_HASH_MISMATCH'
    Assert-CcodEqual 'Failed' $world.Transaction.phase 'a staging failure is durable instead of silently abandoning the transaction'
    Assert-CcodEqual 'Requested' $world.Transaction.resumePhase 'retry resumes before staging/cleanup after a failed first payload copy'
    Assert-CcodEqual 'CCOD_UNINSTALL_PAYLOAD_HASH_MISMATCH' $world.Transaction.errorCode 'staging failure keeps its stable support code'
    Assert-CcodEqual 'Validate,GetRoot,Read,NewId,Create,Write:Requested,Publish,Stage,Write:Failed,Receipt:Failed' ($world.Calls -join ',') 'staging failure records the external evidence before returning failure'
    $world.Calls.Clear()
    $world.StageError = $false
    $receipt = Invoke-CcodUninstallBootstrap -InstallerRoot 'C:\installer' -InstallRoot 'C:\install' -Mode Prepare -Adapters (New-CcodUninstallBootstrapAdapters $world)
    Assert-CcodEqual 'ReadyForInno' $receipt.phase 'a payload staging failure can retry the same durable transaction'
    Assert-CcodEqual 'Validate,GetRoot,Read,Stage,Cleanup,Write:ReadyForInno,Receipt:ReadyForInno' ($world.Calls -join ',') 'staging retry restages only the existing transaction payload and never republishes a new locator'
}

$results += Invoke-CcodTest 'FinalizeReceipt marks completion only after Inno has removed the application root' {
    $world = [pscustomobject]@{
        Calls = [Collections.Generic.List[string]]::new()
        Transaction = (New-CcodUninstallBootstrapTestTransaction -Phase 'ReadyForInno')
        Receipt = $null
        ValidationError = $false
        StageError = $false
        CleanupError = $false
        CleanupFailurePhase = $null
        InstallRootAbsent = $true
        StagedEntries = @()
    }
    $receipt = Invoke-CcodUninstallBootstrap -InstallerRoot 'C:\installer' -InstallRoot 'C:\install' -Mode FinalizeReceipt -Adapters (New-CcodUninstallBootstrapAdapters $world)
    Assert-CcodEqual 'Completed' $receipt.phase 'external receipt records only a completed Inno deletion'
    Assert-CcodEqual 'GetRoot,Read,FinalizeInvocation,RootAbsent,Write:Completed,Receipt:Completed' ($world.Calls -join ',') 'finalization validates the staged bootstrap and records completion after absence proof'
}

$results += Invoke-CcodTest 'FinalizeReceipt fails closed when installer files remain' {
    $world = [pscustomobject]@{
        Calls = [Collections.Generic.List[string]]::new()
        Transaction = (New-CcodUninstallBootstrapTestTransaction -Phase 'ReadyForInno')
        Receipt = $null
        ValidationError = $false
        StageError = $false
        CleanupError = $false
        CleanupFailurePhase = $null
        InstallRootAbsent = $false
        StagedEntries = @()
    }
    Assert-CcodThrows { Invoke-CcodUninstallBootstrap -InstallerRoot 'C:\installer' -InstallRoot 'C:\install' -Mode FinalizeReceipt -Adapters (New-CcodUninstallBootstrapAdapters $world) | Out-Null } 'CCOD_UNINSTALL_FINALIZATION_INCOMPLETE'
    Assert-CcodEqual 'GetRoot,Read,FinalizeInvocation,RootAbsent' ($world.Calls -join ',') 'Inno residue never receives a false completion receipt'
}

$results | ForEach-Object { "PASS $($_.Name)" }
Write-Output "Uninstall bootstrap self-tests passed: $($results.Count)"
