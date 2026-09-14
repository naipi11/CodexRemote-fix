$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestSupport.ps1')

$repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$bootstrapScript = Join-Path $repositoryRoot 'src\persistence\UninstallBootstrap.ps1'
$installedFinalizerScript = Join-Path $repositoryRoot 'src\persistence\InstalledUninstallFinalizer.ps1'

if (-not (Test-Path -LiteralPath $bootstrapScript -PathType Leaf)) {
    throw "Uninstall bootstrap script is missing: $bootstrapScript"
}

. $bootstrapScript
if (-not (Test-Path -LiteralPath $installedFinalizerScript -PathType Leaf)) { throw "Installed uninstall finalizer is missing: $installedFinalizerScript" }
. $installedFinalizerScript
Import-Module (Join-Path $repositoryRoot 'src\persistence\modules\RuntimeManifest.psm1') -Force
$canonicalTaskTarget=[IO.Path]::GetFullPath((Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::System)) 'schtasks.exe'))

$results=@()

function New-CcodUninstallBootstrapTestRoot {
    param([AllowNull()][string]$Tag)
    $tempPath=[IO.Path]::GetFullPath(([IO.Path]::GetTempPath()).TrimEnd('\'))
    $tempLeaf=Split-Path $tempPath -Leaf
    $parent=Split-Path $tempPath -Parent
    $base=if($tempLeaf.Length -gt 8 -and -not [string]::IsNullOrWhiteSpace($parent) -and [IO.Directory]::Exists($parent)){$parent}else{$tempPath}
    return Join-Path $base ('ccod-uninstall-' + [guid]::NewGuid().ToString('N').Substring(0,8))
}

$results+=Invoke-CcodTest 'uninstall bootstrap runtime IDs use canonical TAB delimiters' {
    $records=@(
        [pscustomobject]@{ path='a.txt'; length=[int64]5; sha256=('a'*64) }
        [pscustomobject]@{ path='b.txt'; length=[int64]4; sha256=('b'*64) }
    )
    $expected='2.5.22-e71f4818a0f8e98f-0123456789abcdef0123456789abcdef'
    Assert-CcodEqual $expected (Get-CcodUninstallBootstrapRuntimeId -ProjectVersion '2.5.22' -Records $records -Nonce '0123456789abcdef0123456789abcdef') 'uninstall runtime ID digest input must use literal TAB delimiters'
}

function New-CcodUninstallBootstrapTestPayloadRecords {
    $records=@(New-CcodUninstallBootstrapPayloadRecords -ResumeOnly);foreach($record in $records){$record.length=[int64]1;$record.sha256=('d'*64)};$resume=@($records|Where-Object{$_.path-ceq'src/persistence/InstalledUninstallFinalizer.ps1'})[0];$resume.length=[int64]123;$resume.sha256=('e'*64);return $records
}

function New-CcodUninstallBootstrapContext {
    return [pscustomobject][ordered]@{
        runtimeId = '2.5.0-uninstall-test'
        runtimeGeneration = [uint64]7
        leaseEpoch = [uint64]11
        userSid = 'S-1-5-21-111-222-333-1001'
        sessionId = 1
        readyEvidence = [pscustomobject][ordered]@{phase='Ready';installRoot='C:\install';runtimeId='2.5.0-uninstall-test';runtimeGeneration=[uint64]7;packageSha256=('0'*64);manifestSha256=('a'*64);startMenuSha256=('0'*64);desktopSha256=('0'*64);targetPath=$canonicalTaskTarget;arguments='/Run /TN "Codex Control Other Devices Supervisor"'}
        payloadRecords = New-CcodUninstallBootstrapTestPayloadRecords
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
        readyEvidence = [pscustomobject][ordered]@{phase='Ready';installRoot='C:\install';runtimeId='2.5.0-uninstall-test';runtimeGeneration=[uint64]7;packageSha256=('0'*64);manifestSha256=('a'*64);startMenuSha256=('0'*64);desktopSha256=('0'*64);targetPath=$canonicalTaskTarget;arguments='/Run /TN "Codex Control Other Devices Supervisor"'}
        installedBinding = $null
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
                readyEvidence = [pscustomobject][ordered]@{phase='Ready';installRoot='C:\install';runtimeId='2.5.0-uninstall-test';runtimeGeneration=[uint64]7;packageSha256=('0'*64);manifestSha256=('a'*64);startMenuSha256=('0'*64);desktopSha256=('0'*64);targetPath=$canonicalTaskTarget;arguments='/Run /TN "Codex Control Other Devices Supervisor"'}
                payloadRecords = New-CcodUninstallBootstrapTestPayloadRecords
            }
        }.GetNewClosure()
        GetTransactionRoot = {
            [void]$World.Calls.Add('GetRoot')
            return 'C:\ccod-uninstall-test'
        }.GetNewClosure()
        EnterAccountTransition = {param($UserSid)[void]$World.Calls.Add('AccountLock');[pscustomobject]@{Held=$true}}.GetNewClosure()
        ExitAccountTransition = {param($Lease)[void]$World.Calls.Add('AccountUnlock');$Lease.Held=$false}.GetNewClosure()
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
            [void]($World.StagedEntries = @($Context.payloadRecords | ForEach-Object { [string]$_.path }))
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
        ReadReceipt = {
            param($TransactionRoot)
            [void]$World.Calls.Add('ReadReceipt')
            if($null-eq$World.Receipt){return $null}
            [pscustomobject][ordered]@{schemaVersion=1;transactionId=[string]$World.Receipt.transactionId;runtimeId=[string]$World.Receipt.runtimeId;runtimeGeneration=[uint64]$World.Receipt.runtimeGeneration;leaseEpoch=[uint64]$World.Receipt.leaseEpoch;phase=[string]$World.Receipt.phase;updatedAtUtc=[string]$World.Receipt.updatedAtUtc;errorCode=$World.Receipt.errorCode}
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
        RemoveProductRegistration = {
            param($Context)
            [void]$World.Calls.Add('RemoveProduct')
            if($null-eq$World.PSObject.Properties['ProductRegistrationRemovals']){$World|Add-Member -NotePropertyName ProductRegistrationRemovals -NotePropertyValue 0}
            [void]($World.ProductRegistrationRemovals++)
        }.GetNewClosure()
        TestInstallRootAbsent = {
            param($InstallRoot)
            [void]$World.Calls.Add('RootAbsent')
            return [bool]$World.InstallRootAbsent
        }.GetNewClosure()
        GetUtcNow = {
            if($null-eq$World.PSObject.Properties['ClockReads']){$World|Add-Member -NotePropertyName ClockReads -NotePropertyValue 0};$World.ClockReads++;return [DateTime]::Parse('2030-02-03T03:04:05Z').ToUniversalTime().AddSeconds($World.ClockReads)
        }.GetNewClosure()
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
    param([Parameter(Mandatory)][string]$InstallRoot,[switch]$AppendOnly,[string]$ProjectVersion='2.5.0-uninstall-test')
    $runtimeRoot = Join-Path $InstallRoot 'runtime\pending'
    foreach ($entry in @(
        'src/persistence/UninstallBootstrap.ps1',
        'src/persistence/PortableUninstallFinalizer.ps1',
        'src/persistence/InstalledUninstallFinalizer.ps1',
        'src/persistence/modules/GenerationReclamation.psm1',
        'src/persistence/modules/InstallLifecycle.psm1',
        'src/persistence/modules/ProductRegistration.psm1',
        'src/persistence/modules/PortableRelease.psm1',
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
    $manifest = New-CcodRuntimeManifest -RuntimeDirectory $runtimeRoot -ProjectVersion $ProjectVersion
    $finalRuntime = Join-Path $InstallRoot ('runtime\' + $manifest.runtimeId)
    [IO.Directory]::Move($runtimeRoot,$finalRuntime)
    [IO.File]::WriteAllText((Join-Path $finalRuntime 'manifest.json'),($manifest | ConvertTo-Json -Depth 16),[Text.UTF8Encoding]::new($false))
    [IO.Directory]::CreateDirectory((Join-Path $InstallRoot 'state')) | Out-Null
    Set-CcodUninstallBootstrapFixtureDirectoryOwner -Path $InstallRoot
    $timestamp = '2030-02-03T03:04:05.0000000Z'
    if($AppendOnly){$pointerRoot=Join-Path $InstallRoot 'state\active-generation';[IO.Directory]::CreateDirectory($pointerRoot)|Out-Null;for($generation=1;$generation-le7;$generation++){[IO.File]::WriteAllText((Join-Path $pointerRoot ('{0:D20}.json'-f$generation)),([ordered]@{schemaVersion=1;generation=[uint64]$generation;activeRuntime=$manifest.runtimeId;previousGeneration=[uint64]($generation-1)}|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))}}
    else{[IO.File]::WriteAllText((Join-Path $InstallRoot 'active.json'),([ordered]@{schemaVersion=2;activeRuntime=$manifest.runtimeId;previousRuntime=$null;generation=[uint64]7;updatedAtUtc=$timestamp}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))}
    [IO.File]::WriteAllText((Join-Path $InstallRoot 'state\lifecycle-epoch.json'),([ordered]@{schemaVersion=1;epoch=[uint64]11}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    if($ProjectVersion-ceq'2.5.22'){
        $transactionRoot=Join-Path $InstallRoot 'state\install-transactions';[IO.Directory]::CreateDirectory($transactionRoot)|Out-Null;$transactionId='aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';$manifestSha=(Get-FileHash (Join-Path $finalRuntime 'manifest.json') -Algorithm SHA256).Hash.ToLowerInvariant();$phases=@('Prepared','PackageVerified','RuntimeStaged','PreviousProtectionStopped','RuntimePromoted','PointerCommitted','StableShellCommitted','ProtectionReady','Ready')
        for($index=0;$index-lt$phases.Count;$index++){$phase=$phases[$index];$record=[pscustomobject][ordered]@{schemaVersion=1;transactionId=$transactionId;oldRuntimeId=$null;oldGeneration=$null;oldManifestSha256=$null;newRuntimeId=$manifest.runtimeId;newGeneration=[uint64]7;newManifestSha256=$manifestSha;sealedPackageSha256=('9'*64);ownedObjectNames=@($manifest.runtimeId);phase=$phase;errorCode=$null};$leaf='{0:D20}.{1:D2}.{2}.{3}.json'-f[uint64]7,$index,$phase,$transactionId;[IO.File]::WriteAllText((Join-Path $transactionRoot $leaf),($record|ConvertTo-Json -Depth 8 -Compress),[Text.UTF8Encoding]::new($false))}
    }
    return [pscustomobject][ordered]@{RuntimeRoot=$finalRuntime;RuntimeId=$manifest.runtimeId}
}

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
        ProductRegistrationRemovals = 0
    }
    $receipt = Invoke-CcodUninstallBootstrap -InstallerRoot 'C:\installer' -InstallRoot 'C:\install' -Mode Prepare -Adapters (New-CcodUninstallBootstrapAdapters $world)
    Assert-CcodEqual 'ReadyForInno' $receipt.phase 'verified cleanup reaches the Inno boundary'
    Assert-CcodEqual 'Validate,GetRoot,Read,NewId,Create,Write:Requested,Publish,Stage,Cleanup,Write:ReadyForInno,RemoveProduct,Receipt:ReadyForInno' ($world.Calls -join ',') 'Prepare removes only verified product registration after protected application cleanup'
    Assert-CcodEqual 1 $world.ProductRegistrationRemovals 'verified uninstall removes current product registration exactly once'
    Assert-CcodEqual 'src/persistence/UninstallBootstrap.ps1,src/persistence/PortableUninstallFinalizer.ps1,src/persistence/InstalledUninstallFinalizer.ps1,src/persistence/modules/GenerationReclamation.psm1,src/persistence/modules/InstallLifecycle.psm1,src/persistence/modules/ProductRegistration.psm1,src/persistence/modules/PortableRelease.psm1,src/persistence/modules/PersistenceIO.psm1,src/persistence/modules/RuntimeManifest.psm1,src/persistence/modules/LifecycleEpoch.psm1,src/persistence/modules/StateStore.psm1,src/persistence/modules/TrustedLogonIdentity.psm1,src/persistence/modules/ScheduledTask.psm1,src/persistence/modules/KernelObjects.psm1,src/persistence/modules/CompatibilityProbe.psm1,src/persistence/modules/UiPreferences.psm1,src/persistence/modules/LifecycleTransaction.psm1' ($world.StagedEntries -join ',') 'staging has only bounded cleanup code and no device-key material'
    Assert-CcodEqual $null $receipt.errorCode 'ReadyForInno carries no failure code'
}

$results += Invoke-CcodTest 'production runtime verification binds the installed bootstrap to an exact manifest and rejects a hash change' {
    $localAppData = New-CcodUninstallBootstrapTestRoot ('u-b-' + [guid]::NewGuid().ToString('N').Substring(0,12))
    $installRoot = Join-Path $localAppData 'CodexControlOtherDevices'
    $previousLocalAppData = [Environment]::GetEnvironmentVariable('LOCALAPPDATA','Process')
    try {
        [Environment]::SetEnvironmentVariable('LOCALAPPDATA',$localAppData,'Process')
        $fixture = New-CcodVerifiedUninstallRuntimeFixture -InstallRoot $installRoot
        $context = Get-CcodUninstallBootstrapVerifiedRuntimeContext -InstallerRoot $repositoryRoot -InstallRoot $installRoot
        Assert-CcodEqual $fixture.RuntimeId $context.runtimeId 'verified context binds the active manifest runtime'
        Assert-CcodEqual ([uint64]7) ([uint64]$context.runtimeGeneration) 'verified context binds active generation'
        Assert-CcodEqual ([uint64]11) ([uint64]$context.leaseEpoch) 'verified context binds lifecycle epoch'
        Assert-CcodEqual 17 @($context.payloadRecords).Count 'only the cleanup entry, two bounded finalizers, bounded reclamation, matched registration module, and imported modules are staged'
        [IO.File]::AppendAllText((Join-Path $fixture.RuntimeRoot 'src\persistence\modules\InstallLifecycle.psm1'),'# altered',[Text.UTF8Encoding]::new($false))
        Assert-CcodThrows { Get-CcodUninstallBootstrapVerifiedRuntimeContext -InstallerRoot $repositoryRoot -InstallRoot $installRoot | Out-Null } 'CCOD_UNINSTALL_RUNTIME_INVALID'
    } finally {
        [Environment]::SetEnvironmentVariable('LOCALAPPDATA',$previousLocalAppData,'Process')
        if ([IO.Directory]::Exists($localAppData)) { Remove-CcodTestOwnedTree -Path $localAppData }
    }
}

function New-CcodUninstallBootstrapTestInstalledBinding {
    param(
        [string]$TransactionId='11111111-2222-3333-4444-555555555555',
        [string]$RuntimeRoot='C:\install\runtime\2.5.0-uninstall-test',
        [string]$InstallRoot='C:\install',
        [string]$UserSid='S-1-5-21-111-222-333-1001',
        [int]$SessionId=1,
        [int]$WrapperPid=42,
        [string]$WrapperCreationTimeUtc='2030-02-03T03:04:05.0000000Z',
        [object[]]$PayloadRecords,
        [string]$TransactionDirectory,
        [string]$RuntimeManifestSha256=('a'*64)
    )
    $local=Get-CcodInstalledFinalizerLocalAppData;if([string]::IsNullOrWhiteSpace($TransactionDirectory)){$TransactionDirectory=Join-Path (Join-Path $local 'CodexRemote-fix-uninstall') $TransactionId};$resumeScript=[IO.Path]::GetFullPath((Join-Path $TransactionDirectory 'payload\src\persistence\InstalledUninstallFinalizer.ps1'))
    $records=if($null-ne$PayloadRecords){@($PayloadRecords)}else{@(New-CcodUninstallBootstrapTestPayloadRecords)};$resumeRecord=@($records|Where-Object{$_.path-ceq'src/persistence/InstalledUninstallFinalizer.ps1'})[0]
    [pscustomobject][ordered]@{selectedRuntimeRoot=[IO.Path]::GetFullPath($RuntimeRoot);runtimeManifestSha256=$RuntimeManifestSha256;wrapperPid=$WrapperPid;wrapperCreationTimeUtc=$WrapperCreationTimeUtc;wrapperSessionId=$SessionId;wrapperUserSid=$UserSid;resumeWrapperPid=$null;resumeWrapperCreationTimeUtc=$null;resumeWrapperSessionId=$null;resumeWrapperUserSid=$null;resumeScriptPath=$resumeScript;resumeScriptLength=[int64]$resumeRecord.length;resumeScriptSha256=[string]$resumeRecord.sha256;resumeCommand=(Get-CcodUninstallBootstrapInstalledResumeCommand -ResumeScriptPath $resumeScript -TransactionId $TransactionId -RuntimeRoot $RuntimeRoot -InstallRoot $InstallRoot);payloadRecords=$records}
}

function New-CcodInstalledFinalizerMemoryAdapters {
    param([Parameter(Mandatory)]$World)
    @{
        GetCurrentIdentity={ [pscustomobject]@{userSid=[string]$World.Transaction.userSid;sessionId=[int]$World.Transaction.sessionId} }.GetNewClosure()
        EnterAccountTransition={param($Sid)$World.Calls.Add('AccountLock');[pscustomobject]@{Held=$true}}.GetNewClosure()
        ExitAccountTransition={param($Lease)$World.Calls.Add('AccountUnlock');$Lease.Held=$false}.GetNewClosure()
        EnterTransactionLock={param($Sid)$World.Calls.Add('Lock');[pscustomobject]@{Held=$true}}.GetNewClosure()
        ExitTransactionLock={param($Lock)$World.Calls.Add('Unlock');$Lock.Held=$false}.GetNewClosure()
        WaitWrapperExit={param($Identity,$Timeout)$World.Calls.Add('WaitWrapper');if($null-eq$World.PSObject.Properties['LastWaitIdentity']){$World|Add-Member -NotePropertyName LastWaitIdentity -NotePropertyValue $null};$World.LastWaitIdentity=$Identity;[pscustomobject]@{verifiedAtStart=$true;exited=$true}}.GetNewClosure()
        ReadPreparedTransaction={param($Id,$Root)$World.Calls.Add("Read:$($World.Transaction.phase)");$World.Transaction}.GetNewClosure()
        ValidateStagedPayload={param($Transaction,$Root)$World.Calls.Add('ValidatePayload');$true}.GetNewClosure()
        ValidateSelectedGeneration={param($Runtime,$Install,$Transaction)$World.Calls.Add('ValidateGeneration');[bool]$World.RootPresent}.GetNewClosure()
        ReadCurrentEpoch={param($Root)[uint64]$World.Transaction.leaseEpoch}.GetNewClosure()
        GetSelectedRootState={param($Root)if($World.RootPresent){'Present'}else{'Absent'}}.GetNewClosure()
        InstallResumeProductRegistration={param($Transaction)$World.Calls.Add('PublishResume');$World.PublicEntry=$true;$World.PublicCommand=[string]$Transaction.installedBinding.resumeCommand}.GetNewClosure()
        GetResumeProductRegistrationState={param($Transaction)$World.Calls.Add('ValidateResume');if($World.PublicEntry-and[string]$World.PublicCommand-ceq[string]$Transaction.installedBinding.resumeCommand){'Exact'}else{'Absent'}}.GetNewClosure()
        ReclaimSelectedGeneration={param($Runtime,$Transaction)$World.Calls.Add('Reclaim');$World.EntryPresentAtReclaim=[bool]$World.PublicEntry;$World.RootPresent=$false;[pscustomobject]@{phase='Completed';result='Reclaimed';runtimeId=$Transaction.runtimeId}}.GetNewClosure()
        WriteReadyForInno={param($Transaction)$World.Calls.Add('Write:ReadyForInno');if($World.Failure-ceq'PhaseWrite'-and-not$World.FailureInjected){$World.FailureInjected=$true;throw [Management.Automation.ErrorRecord]::new([IO.IOException]::new('durable phase write failed after reclaim'),'CCOD_UNINSTALL_TRANSACTION_WRITE_FAILED',[Management.Automation.ErrorCategory]::WriteError,$Transaction.transactionId)};$Transaction.phase='ReadyForInno';$Transaction.resumePhase='ReadyForInno';$World.Transaction=$Transaction;$Transaction}.GetNewClosure()
        RemoveMatchedProductShortcuts={param($Transaction)$World.Calls.Add('ProductShortcuts');if($World.Failure-ceq'ProductShortcuts'-and-not$World.FailureInjected){$World.FailureInjected=$true;throw [IO.IOException]::new('shortcut cleanup failed')};$World.ShortcutsPresent=$false}.GetNewClosure()
        CleanupProductResidue={param($Transaction)$World.Calls.Add('ProductResidue');[pscustomobject]@{phase='Completed';result='Removed'}}.GetNewClosure()
        FinalizeReceipt={param($Transaction)$World.Calls.Add('FinalizeReceipt');$Transaction.phase='Completed';$Transaction.resumePhase='Completed';$World.Transaction=$Transaction;if($World.Failure-ceq'FinalReceipt'-and-not$World.FailureInjected){$World.FailureInjected=$true;$World.CompletedReceipt=$false;throw [IO.IOException]::new('receipt write failed after Completed transaction')};$World.CompletedReceipt=$true;$Transaction}.GetNewClosure()
        TestCompletedReceipt={param($Transaction)$World.Calls.Add('TestReceipt');[bool]$World.CompletedReceipt}.GetNewClosure()
        RemoveResumeProductRegistration={param($Transaction)$World.Calls.Add('RemoveRegistry');if($World.Failure-ceq'FinalRegistry'-and-not$World.FailureInjected){$World.FailureInjected=$true;throw [IO.IOException]::new('final recovery registry delete failed')};$World.PublicEntry=$false;$World.PublicCommand=$null;$true}.GetNewClosure()
    }
}

function Invoke-CcodInstalledFinalizerPublicResume {
    param([Parameter(Mandatory)]$World,[Parameter(Mandatory)][hashtable]$Adapters)
    if(-not$World.PublicEntry-or[string]::IsNullOrWhiteSpace([string]$World.PublicCommand)-or$World.PublicCommand-cne[string]$World.Transaction.installedBinding.resumeCommand){throw 'public resume command is unavailable or changed'}
    if($World.PublicCommand-cnotmatch(' -Resume -TransactionId "'+[regex]::Escape([string]$World.Transaction.transactionId)+'" ')){throw 'public resume command does not bind the transaction'}
    Invoke-CcodInstalledUninstallFinalizer -TransactionId $World.Transaction.transactionId -RuntimeRoot $World.Transaction.installedBinding.selectedRuntimeRoot -InstallRoot $World.Transaction.readyEvidence.installRoot -WrapperIdentity $null -Resume -Adapters $Adapters
}

$results += Invoke-CcodTest 'production uninstall authorization consumes append-only selector before legacy active json' {
    $localAppData=New-CcodUninstallBootstrapTestRoot ('u-a-'+[guid]::NewGuid().ToString('N').Substring(0,12));$installRoot=Join-Path $localAppData 'CodexControlOtherDevices';$previous=[Environment]::GetEnvironmentVariable('LOCALAPPDATA','Process')
    try{[Environment]::SetEnvironmentVariable('LOCALAPPDATA',$localAppData,'Process');$fixture=New-CcodVerifiedUninstallRuntimeFixture -InstallRoot $installRoot -AppendOnly;$context=Get-CcodUninstallBootstrapVerifiedRuntimeContext -InstallerRoot $repositoryRoot -InstallRoot $installRoot;Assert-CcodEqual $fixture.RuntimeId $context.runtimeId 'uninstall context binds append-only active runtime';Assert-CcodEqual 7 ([uint64]$context.runtimeGeneration) 'uninstall context binds latest append-only generation';Assert-CcodEqual $false (Test-Path -LiteralPath (Join-Path $installRoot 'active.json')) 'append-only uninstall authorization needs no legacy pointer'}finally{[Environment]::SetEnvironmentVariable('LOCALAPPDATA',$previous,'Process');if([IO.Directory]::Exists($localAppData)){Remove-CcodTestOwnedTree -Path $localAppData}}
}

$results += Invoke-CcodTest 'uninstall legacy fallback accepts a valid pointer when the entire state plane is absent' {
    $local=New-CcodUninstallBootstrapTestRoot ('u-n-'+[guid]::NewGuid().ToString('N').Substring(0,12));$install=Join-Path $local 'CodexControlOtherDevices';$previous=[Environment]::GetEnvironmentVariable('LOCALAPPDATA','Process')
    try{
        [Environment]::SetEnvironmentVariable('LOCALAPPDATA',$local,'Process');New-CcodVerifiedUninstallRuntimeFixture -InstallRoot $install|Out-Null
        $state=Join-Path $install 'state';Remove-Item -LiteralPath $state -Recurse -Force
        $activePath=Join-Path $install 'active.json';$validActive=[IO.File]::ReadAllText($activePath)
        Assert-CcodEqual $true (Test-Path -LiteralPath $activePath -PathType Leaf) 'legacy active pointer remains present'
        Assert-CcodEqual $false (Test-Path -LiteralPath $state) 'new selector state plane is entirely absent'
        [IO.File]::WriteAllText($activePath,'{"schemaVersion":3,"activeRuntime":"invalid","previousRuntime":null,"generation":7,"updatedAtUtc":"2030-01-02T03:04:05.0000000Z"}',[Text.UTF8Encoding]::new($false))
        $invalidFailure=$null;try{Get-CcodUninstallBootstrapVerifiedRuntimeContext -InstallerRoot $repositoryRoot -InstallRoot $install|Out-Null}catch{$invalidFailure=$_}
        Assert-CcodTrue ($null-ne$invalidFailure-and$invalidFailure.FullyQualifiedErrorId-like'CCOD_UNINSTALL_RUNTIME_INVALID*') 'an invalid legacy pointer is not skipped when the selector plane is absent'
        Assert-CcodEqual ([IO.Path]::GetFullPath($activePath)) ([string]$invalidFailure.TargetObject) 'legacy fallback still authorizes through the active pointer'
        [IO.File]::WriteAllText($activePath,$validActive,[Text.UTF8Encoding]::new($false))
        $failure=$null;try{Get-CcodUninstallBootstrapVerifiedRuntimeContext -InstallerRoot $repositoryRoot -InstallRoot $install|Out-Null}catch{$failure=$_}
        Assert-CcodTrue ($null-ne$failure-and$failure.FullyQualifiedErrorId-like'CCOD_UNINSTALL_REPARSE_OR_PATH_INVALID*') 'missing lifecycle epoch still fails closed after legacy authorization'
        Assert-CcodEqual ([IO.Path]::GetFullPath($state)) ([string]$failure.TargetObject) 'valid legacy selector fallback reaches the later lifecycle epoch validation'
    }finally{[Environment]::SetEnvironmentVariable('LOCALAPPDATA',$previous,'Process');if([IO.Directory]::Exists($local)){Remove-CcodTestOwnedTree -Path $local}}
}

$results += Invoke-CcodTest 'uninstall append-only authorization rejects unsafe roots leaves JSON and generations' {
    $previous=[Environment]::GetEnvironmentVariable('LOCALAPPDATA','Process')
    try{foreach($kind in @('root-file','root-reparse','leaf-reparse','ads','multilink','malformed','schema','duplicate','fractional','noncanonical')){$local=New-CcodUninstallBootstrapTestRoot $kind;$install=Join-Path $local 'CodexControlOtherDevices';[Environment]::SetEnvironmentVariable('LOCALAPPDATA',$local,'Process');$fixture=New-CcodVerifiedUninstallRuntimeFixture -InstallRoot $install -AppendOnly;$pointerRoot=Join-Path $install 'state\active-generation';$leaf=Join-Path $pointerRoot '00000000000000000007.json';$target=Join-Path $install ("target-$kind");if($kind-ceq'root-file'){Remove-Item $pointerRoot -Recurse -Force;[IO.File]::WriteAllText($pointerRoot,'x',[Text.UTF8Encoding]::new($false))}elseif($kind-ceq'root-reparse'){Remove-Item $pointerRoot -Recurse -Force;[IO.Directory]::CreateDirectory($target)|Out-Null;New-Item -ItemType Junction -Path $pointerRoot -Target $target|Out-Null}elseif($kind-ceq'leaf-reparse'){[IO.File]::Delete($leaf);[IO.Directory]::CreateDirectory($target)|Out-Null;New-Item -ItemType Junction -Path $leaf -Target $target|Out-Null}elseif($kind-ceq'ads'){Set-Content -LiteralPath $leaf -Stream evidence -Value x -NoNewline}elseif($kind-ceq'multilink'){$text=[IO.File]::ReadAllText($leaf);[IO.File]::Delete($leaf);$outside=Join-Path $install 'outside-pointer.json';[IO.File]::WriteAllText($outside,$text,[Text.UTF8Encoding]::new($false));New-Item -ItemType HardLink -Path $leaf -Target $outside|Out-Null}elseif($kind-ceq'malformed'){[IO.File]::WriteAllText($leaf,'{',[Text.UTF8Encoding]::new($false))}elseif($kind-ceq'schema'){$id=$fixture.RuntimeId;[IO.File]::WriteAllText($leaf,('{"schemaVersion":2,"generation":7,"activeRuntime":"'+$id+'","previousGeneration":6}'),[Text.UTF8Encoding]::new($false))}elseif($kind-ceq'duplicate'){$id=$fixture.RuntimeId;[IO.File]::WriteAllText($leaf,('{"schemaVersion":1,"schemaVersion":1,"generation":7,"activeRuntime":"'+$id+'","previousGeneration":6}'),[Text.UTF8Encoding]::new($false))}elseif($kind-ceq'fractional'){$id=$fixture.RuntimeId;[IO.File]::WriteAllText($leaf,('{"schemaVersion":1,"generation":7.5,"activeRuntime":"'+$id+'","previousGeneration":6}'),[Text.UTF8Encoding]::new($false))}else{Move-Item $leaf (Join-Path $pointerRoot '00000000000000000008.json')};Assert-CcodThrows {Get-CcodUninstallBootstrapVerifiedRuntimeContext -InstallerRoot $repositoryRoot -InstallRoot $install|Out-Null} 'CCOD_UNINSTALL_RUNTIME_INVALID';if([IO.Directory]::Exists($local)){Remove-CcodTestOwnedTree -Path $local}}}finally{[Environment]::SetEnvironmentVariable('LOCALAPPDATA',$previous,'Process')}
}

$results += Invoke-CcodTest 'uninstall selector fallback requires proven ItemNotFound instead of a lookup error' {
    $local=New-CcodUninstallBootstrapTestRoot ('ccod-uninstall-lookup-'+[guid]::NewGuid().ToString('N'));$install=Join-Path $local 'CodexControlOtherDevices';$previous=[Environment]::GetEnvironmentVariable('LOCALAPPDATA','Process')
    try{[Environment]::SetEnvironmentVariable('LOCALAPPDATA',$local,'Process');New-CcodVerifiedUninstallRuntimeFixture -InstallRoot $install|Out-Null;Assert-CcodThrows {Get-CcodUninstallBootstrapVerifiedRuntimeContext -InstallerRoot $repositoryRoot -InstallRoot $install -SelectorAdapters @{GetSelectorRootItem={param($Path)throw [UnauthorizedAccessException]::new('selector lookup denied')}}|Out-Null} 'CCOD_UNINSTALL_RUNTIME_INVALID'}finally{[Environment]::SetEnvironmentVariable('LOCALAPPDATA',$previous,'Process');if([IO.Directory]::Exists($local)){Remove-CcodTestOwnedTree -Path $local}}
}

$results += Invoke-CcodTest 'uninstall legacy fallback rejects a state ancestor file at the selector boundary' {
    $local=New-CcodUninstallBootstrapTestRoot ('ccod-uninstall-state-file-'+[guid]::NewGuid().ToString('N'));$install=Join-Path $local 'CodexControlOtherDevices';$previous=[Environment]::GetEnvironmentVariable('LOCALAPPDATA','Process')
    try{
        [Environment]::SetEnvironmentVariable('LOCALAPPDATA',$local,'Process');New-CcodVerifiedUninstallRuntimeFixture -InstallRoot $install|Out-Null
        $state=Join-Path $install 'state';Remove-Item -LiteralPath $state -Recurse -Force;[IO.File]::WriteAllText($state,'not-a-directory',[Text.UTF8Encoding]::new($false))
        $failure=$null;try{Get-CcodUninstallBootstrapVerifiedRuntimeContext -InstallerRoot $repositoryRoot -InstallRoot $install|Out-Null}catch{$failure=$_}
        Assert-CcodTrue ($null-ne$failure-and$failure.FullyQualifiedErrorId-like'CCOD_UNINSTALL_RUNTIME_INVALID*') 'state ancestor file fails uninstall authorization'
        Assert-CcodTrue ($failure.Exception.Message-like'*selector*') 'state ancestor file is rejected at the selector boundary'
    }finally{[Environment]::SetEnvironmentVariable('LOCALAPPDATA',$previous,'Process');if([IO.Directory]::Exists($local)){Remove-CcodTestOwnedTree -Path $local}}
}

$results += Invoke-CcodTest 'external staging refuses a cleanup source changed after runtime verification' {
    $localAppData = New-CcodUninstallBootstrapTestRoot ('ccod-uninstall-race-' + [guid]::NewGuid().ToString('N'))
    $installRoot = Join-Path $localAppData 'CodexControlOtherDevices'
    $previousLocalAppData = [Environment]::GetEnvironmentVariable('LOCALAPPDATA','Process')
    try {
        [Environment]::SetEnvironmentVariable('LOCALAPPDATA',$localAppData,'Process')
        $fixture = New-CcodVerifiedUninstallRuntimeFixture -InstallRoot $installRoot
        $context = Get-CcodUninstallBootstrapVerifiedRuntimeContext -InstallerRoot $repositoryRoot -InstallRoot $installRoot
        [IO.File]::AppendAllText((Join-Path $fixture.RuntimeRoot 'src\persistence\PortableUninstallFinalizer.ps1'),'# changed after verification',[Text.UTF8Encoding]::new($false))
        $transactionDirectory = Join-Path $localAppData 'staged-transaction'
        [IO.Directory]::CreateDirectory($transactionDirectory) | Out-Null
        Assert-CcodThrows {
            Stage-CcodUninstallBootstrapPayload -InstallRoot $installRoot -Context $context -TransactionDirectory $transactionDirectory
        } 'CCOD_UNINSTALL_PAYLOAD_HASH_MISMATCH'
        $payloadRoot = Join-Path $transactionDirectory 'payload'
        Assert-CcodTrue (-not (Test-Path -LiteralPath (Join-Path $payloadRoot 'src\persistence\PortableUninstallFinalizer.ps1'))) 'the changed cleanup source is never staged'
    } finally {
        [Environment]::SetEnvironmentVariable('LOCALAPPDATA',$previousLocalAppData,'Process')
        if ([IO.Directory]::Exists($localAppData)) { Remove-CcodTestOwnedTree -Path $localAppData }
    }
}

$results += Invoke-CcodTest 'real external staging uses a protected current-user transaction directory and copies only verified cleanup inputs' {
    $testRoot = New-CcodUninstallBootstrapTestRoot ('ccod-uninstall-stage-' + [guid]::NewGuid().ToString('N'))
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
        Assert-CcodEqual 17 $payloadFiles.Count 'external payload contains the exact cleanup entry, two bounded finalizers, bounded reclamation, matched registration module, and required modules'
        foreach ($record in @($context.payloadRecords)) {
            $entry = [string]$record.path
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
        if ([IO.Directory]::Exists($testRoot)) { Remove-CcodTestOwnedTree -Path $testRoot }
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
    Assert-CcodEqual 'Validate,GetRoot,Read,Cleanup,Write:ReadyForInno,RemoveProduct,Receipt:ReadyForInno' ($world.Calls -join ',') 'resume reuses the durable transaction and never makes a second payload'
}

$results += Invoke-CcodTest 'Prepare resumes a TaskRemoved transaction even after the runtime root and active pointer have been deleted' {
    $localAppData = New-CcodUninstallBootstrapTestRoot ('ccod-uninstall-resume-' + [guid]::NewGuid().ToString('N'))
    $installRoot = Join-Path $localAppData 'CodexControlOtherDevices'
    $previousLocalAppData = [Environment]::GetEnvironmentVariable('LOCALAPPDATA','Process')
    try {
        [Environment]::SetEnvironmentVariable('LOCALAPPDATA',$localAppData,'Process')
        $identity = Get-CcodUninstallBootstrapCurrentIdentity
        $transaction = New-CcodUninstallBootstrapTestTransaction -Phase 'TaskRemoved'
        $transaction.readyEvidence.installRoot = $installRoot
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
        Assert-CcodEqual 'Validate,GetRoot,Read,Cleanup,Write:ReadyForInno,RemoveProduct,Receipt:ReadyForInno' ($world.Calls -join ',') 'partial deletion resume neither creates another transaction nor restages payload'
    } finally {
        [Environment]::SetEnvironmentVariable('LOCALAPPDATA',$previousLocalAppData,'Process')
        if ([IO.Directory]::Exists($localAppData)) { Remove-CcodTestOwnedTree -Path $localAppData }
    }
}

$results += Invoke-CcodTest 'Prepare rejects a partial-deletion transaction from a different user before cleanup can resume' {
    $localAppData = New-CcodUninstallBootstrapTestRoot ('ccod-uninstall-other-user-' + [guid]::NewGuid().ToString('N'))
    $installRoot = Join-Path $localAppData 'CodexControlOtherDevices'
    $previousLocalAppData = [Environment]::GetEnvironmentVariable('LOCALAPPDATA','Process')
    try {
        [Environment]::SetEnvironmentVariable('LOCALAPPDATA',$localAppData,'Process')
        $transaction = New-CcodUninstallBootstrapTestTransaction -Phase 'TaskRemoved'
        $transaction.readyEvidence.installRoot = $installRoot
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
        if ([IO.Directory]::Exists($localAppData)) { Remove-CcodTestOwnedTree -Path $localAppData }
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
    Assert-CcodEqual 'Validate,GetRoot,Read,Cleanup,Write:ReadyForInno,RemoveProduct,Receipt:ReadyForInno' ($world.Calls -join ',') 'recovery retry reuses the same payload without a second staging pass'
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
    Assert-CcodEqual 'Validate,GetRoot,Read,Stage,Cleanup,Write:ReadyForInno,RemoveProduct,Receipt:ReadyForInno' ($world.Calls -join ',') 'staging retry restages only the existing transaction payload and never republishes a new locator'
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

$results += Invoke-CcodTest 'FinalizeReceipt repairs a missing receipt after the Completed transaction is already durable' {
    $world=[pscustomobject]@{Calls=[Collections.Generic.List[string]]::new();Transaction=(New-CcodUninstallBootstrapTestTransaction -Phase 'Completed');Receipt=$null;ValidationError=$false;StageError=$false;CleanupError=$false;CleanupFailurePhase=$null;InstallRootAbsent=$true;StagedEntries=@()}
    $receipt=Invoke-CcodUninstallBootstrap -InstallerRoot 'C:\installer' -InstallRoot 'C:\install' -Mode FinalizeReceipt -Adapters (New-CcodUninstallBootstrapAdapters $world)
    Assert-CcodEqual 'Completed' $receipt.phase 'Completed transaction remains terminal while its exact receipt is repaired'
    Assert-CcodEqual 'GetRoot,Read,FinalizeInvocation,RootAbsent,Receipt:Completed' ($world.Calls-join',') 'receipt repair performs no second transaction write before the public registry anchor is removed'
}

# Production mutation caught: the generic context matcher rejects a same-SID TaskRemoved
# replacement wrapper merely because its fresh Windows session differs from the historical one.
$results += Invoke-CcodTest 'same-SID new-session TaskRemoved replacement persists a fresh wrapper without rerunning cleanup' {
    $world=[pscustomobject]@{Calls=[Collections.Generic.List[string]]::new();Transaction=(New-CcodUninstallBootstrapTestTransaction -Phase 'TaskRemoved');Receipt=$null;ValidationError=$false;StageError=$false;CleanupError=$false;CleanupFailurePhase=$null;InstallRootAbsent=$false;StagedEntries=@();ProductRegistrationRemovals=0}
    $world.Transaction.installedBinding=New-CcodUninstallBootstrapTestInstalledBinding -SessionId 1 -WrapperPid 42 -WrapperCreationTimeUtc '2030-02-03T03:04:05.0000000Z'
    $adapters=New-CcodUninstallBootstrapAdapters $world;$fresh=New-CcodUninstallBootstrapContext;$fresh.sessionId=99;$fresh.payloadRecords=@($world.Transaction.installedBinding.payloadRecords);$freshCalls=[pscustomobject]@{Count=0};$cleanupCalls=[pscustomobject]@{Count=0}
    $adapters.ValidateInvocation={param($InstallerRoot,$InstallRoot)$freshCalls.Count++;$world.Calls.Add("FreshValidate:$($freshCalls.Count)");$fresh}.GetNewClosure()
    $adapters.GetInstalledBinding={param($InstallerRoot,$InstallRoot,$Context,$WrapperIdentity,$TransactionDirectory,$TransactionId)New-CcodUninstallBootstrapTestInstalledBinding -TransactionId $TransactionId -RuntimeRoot 'C:\install\runtime\2.5.0-uninstall-test' -InstallRoot 'C:\install' -UserSid $WrapperIdentity.userSid -SessionId $WrapperIdentity.sessionId -WrapperPid $WrapperIdentity.pid -WrapperCreationTimeUtc $WrapperIdentity.creationTimeUtc -PayloadRecords $Context.payloadRecords}.GetNewClosure()
    $adapters.RunCleanup={param($InstallerRoot,$InstallRoot,$TransactionRoot,$Transaction,$WriteTransaction,$Mode)$cleanupCalls.Count++;throw 'TASK1_EXISTING_TASKREMOVED_REENTERED_CLEANUP'}.GetNewClosure()
    $replacement=[pscustomobject]@{pid=43;creationTimeUtc='2030-02-03T03:04:06.0000000Z';sessionId=99;userSid='S-1-5-21-111-222-333-1001'}

    $resumed=Invoke-CcodUninstallBootstrap -InstallerRoot 'C:\install\runtime\2.5.0-uninstall-test' -InstallRoot 'C:\install' -Mode PrepareInstalled -WrapperIdentity $replacement -Adapters $adapters

    Assert-CcodEqual 'TaskRemoved' $resumed.phase 'same-SID new-session replacement returns the existing TaskRemoved transaction'
    Assert-CcodEqual 2 $freshCalls.Count 'replacement recovery revalidates runtime selector Ready manifest payload and epoch after both locks are held'
    Assert-CcodTrue ([Array]::IndexOf(@($world.Calls),'AccountLock')-lt[Array]::IndexOf(@($world.Calls),'FreshValidate:2')) 'fresh replacement proof runs only after Local uninstall and Global AccountTransition acquisition'
    Assert-CcodEqual 0 $cleanupCalls.Count 'existing TaskRemoved never re-enters RunCleanup'
    Assert-CcodEqual 1 $resumed.sessionId 'historical transaction session remains immutable evidence'
    Assert-CcodEqual 42 $resumed.installedBinding.wrapperPid 'historical wrapper identity remains immutable evidence'
    Assert-CcodEqual 43 $resumed.installedBinding.resumeWrapperPid 'only the exact replacement wrapper PID is persisted'
    Assert-CcodEqual 99 $resumed.installedBinding.resumeWrapperSessionId 'replacement wrapper records its fresh Windows session'
    Assert-CcodEqual 'TaskRemoved' $world.Receipt.phase 'TaskRemoved replacement receipt is persisted after transaction read-back'
}

$results += Invoke-CcodTest 'disk-backed new-session replacement uses real verified runtime and independent durable read-back' {
    $local=New-CcodUninstallBootstrapTestRoot ('ccod-task1-disk-'+[guid]::NewGuid().ToString('N'));$previous=[Environment]::GetEnvironmentVariable('LOCALAPPDATA','Process')
    try{
        [Environment]::SetEnvironmentVariable('LOCALAPPDATA',$local,'Process');$install=Join-Path $local 'CodexControlOtherDevices';$fixture=New-CcodVerifiedUninstallRuntimeFixture -InstallRoot $install -AppendOnly -ProjectVersion '2.5.22';$runtimeBootstrap=Join-Path $fixture.RuntimeRoot 'src\persistence\UninstallBootstrap.ps1';$context=Get-CcodUninstallBootstrapVerifiedRuntimeContext -InstallerRoot $fixture.RuntimeRoot -InstallRoot $install -InvocationPath $runtimeBootstrap
        $identity=Get-CcodUninstallBootstrapCurrentIdentity;$process=[Diagnostics.Process]::GetCurrentProcess();try{$creation=$process.StartTime.ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture);$wrapper=[pscustomobject]@{pid=[int]$process.Id;creationTimeUtc=$creation;sessionId=[int]$identity.sessionId;userSid=[string]$identity.userSid}}finally{$process.Dispose()}
        $transactionRoot=Get-CcodUninstallBootstrapDefaultTransactionRoot;$id=[guid]::NewGuid().ToString('D');$directory=New-CcodUninstallBootstrapTransactionDirectory -TransactionRoot $transactionRoot -TransactionId $id -UserSid $identity.userSid;$defaults=Get-CcodUninstallBootstrapAdapters $null;$binding=&$defaults.GetInstalledBinding $fixture.RuntimeRoot $install $context $wrapper $directory $id;$transaction=New-CcodUninstallBootstrapTransaction -Context $context -TransactionId $id -NowUtc ([DateTime]::UtcNow.AddMinutes(-1)) -InstalledBinding $binding;$transaction.phase='TaskRemoved';$transaction.resumePhase='TaskRemoved';Write-CcodUninstallBootstrapStoredTransaction -TransactionDirectory $directory -Transaction $transaction;Write-CcodUninstallBootstrapStoredReceipt -TransactionDirectory $directory -Transaction $transaction;Publish-CcodUninstallBootstrapCurrentTransaction -TransactionRoot $transactionRoot -TransactionId $id -UserSid $identity.userSid;Stage-CcodUninstallBootstrapPayload -InstallRoot $install -Context $context -TransactionDirectory $directory
        $priorUpdated=[DateTime]::ParseExact($transaction.updatedAtUtc,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind);$freshSession=[int]$identity.sessionId+98;$realBinding=$defaults.GetInstalledBinding;$cleanup=[pscustomobject]@{Count=0};$diskCalls=[Collections.Generic.List[string]]::new()
        $adapters=@{
            ValidateInvocation={param($InstallerRoot,$InstallRoot)$diskCalls.Add('Validate');$value=Get-CcodUninstallBootstrapVerifiedRuntimeContext -InstallerRoot $InstallerRoot -InstallRoot $InstallRoot -InvocationPath (Join-Path $InstallerRoot 'src\persistence\UninstallBootstrap.ps1');$copy=$value|ConvertTo-Json -Depth 16 -Compress|ConvertFrom-Json;$copy.sessionId=[int]$freshSession;$copy}.GetNewClosure()
            GetInstalledBinding={param($InstallerRoot,$InstallRoot,$FreshContext,$WrapperIdentity,$TransactionDirectory,$TransactionId)$diskCalls.Add('Binding');$actual=[pscustomobject]@{pid=[int]$WrapperIdentity.pid;creationTimeUtc=[string]$WrapperIdentity.creationTimeUtc;sessionId=[int]$identity.sessionId;userSid=[string]$WrapperIdentity.userSid};$value=&$realBinding $InstallerRoot $InstallRoot $FreshContext $actual $TransactionDirectory $TransactionId;$value.wrapperSessionId=[int]$WrapperIdentity.sessionId;$value}.GetNewClosure()
            RunCleanup={param($InstallerRoot,$InstallRoot,$TransactionDirectory,$Value,$Writer,$Mode)$diskCalls.Add('RunCleanup');$cleanup.Count++;throw 'DISK_TASKREMOVED_REENTERED_CLEANUP'}.GetNewClosure()
        }
        $replacement=[pscustomobject]@{pid=[int]$wrapper.pid;creationTimeUtc=[string]$wrapper.creationTimeUtc;sessionId=$freshSession;userSid=[string]$wrapper.userSid};try{$resumed=Invoke-CcodUninstallBootstrap -InstallerRoot $fixture.RuntimeRoot -InstallRoot $install -Mode PrepareInstalled -WrapperIdentity $replacement -Adapters $adapters}catch{throw "DISK_TASK1_DIAGNOSTIC calls=$($diskCalls-join',') id=$($_.FullyQualifiedErrorId) message=$($_.Exception.Message)"}
        $disk=Read-CcodUninstallBootstrapStoredTransaction -TransactionRoot $transactionRoot -ExpectedUserSid $identity.userSid -IncludeCompleted -ExpectedInstallRoot $install;$receipt=Read-CcodUninstallBootstrapStoredReceipt -TransactionDirectory $directory
        Assert-CcodTrue (-not[object]::ReferenceEquals($transaction,$disk)) 'durable transaction proof is an independently deserialized object'
        Assert-CcodTrue ([DateTime]::ParseExact($disk.updatedAtUtc,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)-gt$priorUpdated) 'replacement persistence advances updatedAtUtc strictly'
        Assert-CcodTrue (Test-CcodUninstallBootstrapReceiptMatchesTransaction -Receipt $receipt -Transaction $disk) 'disk receipt binds the fresh replacement timestamp'
        Assert-CcodEqual $freshSession $disk.installedBinding.resumeWrapperSessionId 'disk transaction persists only the new wrapper session seam'
        Assert-CcodEqual 0 $cleanup.Count 'real disk-backed TaskRemoved recovery never enters RunCleanup'
    }finally{[Environment]::SetEnvironmentVariable('LOCALAPPDATA',$previous,'Process');if([IO.Directory]::Exists($local)){Remove-CcodTestOwnedTree -Path $local}}
}

$results += Invoke-CcodTest 'Failed resume TaskRemoved recovers in same and new sessions without RunCleanup' {
    $outcomes=[Collections.Generic.List[string]]::new()
    foreach($session in @(1,99)){
        $world=[pscustomobject]@{Calls=[Collections.Generic.List[string]]::new();Transaction=(New-CcodUninstallBootstrapTestTransaction -Phase 'Failed' -ErrorCode 'CCOD_UNINSTALL_TRANSACTION_WRITE_FAILED');Receipt=$null;ValidationError=$false;StageError=$false;CleanupError=$false;CleanupFailurePhase=$null;InstallRootAbsent=$false;StagedEntries=@();ProductRegistrationRemovals=0};$world.Transaction.resumePhase='TaskRemoved';$world.Transaction.installedBinding=New-CcodUninstallBootstrapTestInstalledBinding
        $fresh=New-CcodUninstallBootstrapContext;$fresh.sessionId=$session;$fresh.payloadRecords=@($world.Transaction.installedBinding.payloadRecords);$adapters=New-CcodUninstallBootstrapAdapters $world;$adapters.ValidateInvocation={param($InstallerRoot,$InstallRoot)$fresh}.GetNewClosure();$adapters.GetInstalledBinding={param($InstallerRoot,$InstallRoot,$Context,$WrapperIdentity,$TransactionDirectory,$TransactionId)New-CcodUninstallBootstrapTestInstalledBinding -TransactionId $TransactionId -RuntimeRoot 'C:\install\runtime\2.5.0-uninstall-test' -InstallRoot 'C:\install' -UserSid $WrapperIdentity.userSid -SessionId $WrapperIdentity.sessionId -WrapperPid $WrapperIdentity.pid -WrapperCreationTimeUtc $WrapperIdentity.creationTimeUtc -PayloadRecords $Context.payloadRecords}.GetNewClosure();$cleanup=[pscustomobject]@{Count=0};$adapters.RunCleanup={param($InstallerRoot,$InstallRoot,$TransactionRoot,$Transaction,$WriteTransaction,$Mode)$cleanup.Count++;throw 'FAILED_TASKREMOVED_REENTERED_CLEANUP'}.GetNewClosure();$replacement=[pscustomobject]@{pid=43;creationTimeUtc='2030-02-03T03:04:06.0000000Z';sessionId=$session;userSid='S-1-5-21-111-222-333-1001'}
        $failure=$null;$result=$null;try{$result=Invoke-CcodUninstallBootstrap -InstallerRoot 'C:\install\runtime\2.5.0-uninstall-test' -InstallRoot 'C:\install' -Mode PrepareInstalled -WrapperIdentity $replacement -Adapters $adapters}catch{$failure=$_}
        $outcome=if($null-ne$result){[string]$result.phase}else{([string]$failure.FullyQualifiedErrorId-split',')[0]};$outcomes.Add(('{0}:{1}:cleanup={2}'-f$session,$outcome,$cleanup.Count))
    }
    Assert-CcodEqual '1:TaskRemoved:cleanup=0|99:TaskRemoved:cleanup=0' (@($outcomes)-join'|') 'Failed resume TaskRemoved normalizes through the same exact early-return profile in both sessions'
}

$results += Invoke-CcodTest 'new-session relaxation rejects every nonexact TaskRemoved identity without mutation' {
    foreach($kind in @('DifferentSid','Runtime','Generation','Epoch','Ready','Payload','PreTaskRemoved')){
        $world=[pscustomobject]@{Calls=[Collections.Generic.List[string]]::new();Transaction=(New-CcodUninstallBootstrapTestTransaction -Phase 'TaskRemoved');Receipt=$null;ValidationError=$false;StageError=$false;CleanupError=$false;CleanupFailurePhase=$null;InstallRootAbsent=$false;StagedEntries=@();ProductRegistrationRemovals=0}
        $world.Transaction.installedBinding=New-CcodUninstallBootstrapTestInstalledBinding
        if($kind-ceq'PreTaskRemoved'){$world.Transaction.phase='ProtectionStopped';$world.Transaction.resumePhase='ProtectionStopped'}
        $fresh=New-CcodUninstallBootstrapContext;$fresh.sessionId=99;$fresh.payloadRecords=@($world.Transaction.installedBinding.payloadRecords|ForEach-Object{[pscustomobject][ordered]@{path=[string]$_.path;length=[int64]$_.length;sha256=[string]$_.sha256}})
        switch($kind){
            'DifferentSid' {$fresh.userSid='S-1-5-21-999-888-777-1001'}
            'Runtime' {$fresh.runtimeId='2.5.0-uninstall-foreign';$fresh.readyEvidence.runtimeId=$fresh.runtimeId}
            'Generation' {$fresh.runtimeGeneration=[uint64]8;$fresh.readyEvidence.runtimeGeneration=[uint64]8}
            'Epoch' {$fresh.leaseEpoch=[uint64]12}
            'Ready' {$fresh.readyEvidence.packageSha256=('f'*64)}
            'Payload' {$fresh.payloadRecords[0].sha256=('f'*64)}
        }
        $adapters=New-CcodUninstallBootstrapAdapters $world;$adapters.ValidateInvocation={param($InstallerRoot,$InstallRoot)$fresh}.GetNewClosure();$cleanup=[pscustomobject]@{Count=0};$adapters.RunCleanup={param($InstallerRoot,$InstallRoot,$TransactionRoot,$Transaction,$WriteTransaction,$Mode)$cleanup.Count++;throw 'TASK1_NEGATIVE_REENTERED_CLEANUP'}.GetNewClosure()
        $replacement=[pscustomobject]@{pid=43;creationTimeUtc='2030-02-03T03:04:06.0000000Z';sessionId=99;userSid='S-1-5-21-111-222-333-1001'}
        Assert-CcodThrows {Invoke-CcodUninstallBootstrap -InstallerRoot 'C:\install\runtime\2.5.0-uninstall-test' -InstallRoot 'C:\install' -Mode PrepareInstalled -WrapperIdentity $replacement -Adapters $adapters|Out-Null} 'CCOD_UNINSTALL_TRANSACTION_MISMATCH'
        Assert-CcodEqual 0 @($world.Calls|Where-Object{$_-like'Write:*'-or$_-like'Receipt:*'}).Count "$kind writes no transaction or receipt"
        Assert-CcodEqual 0 $cleanup.Count "$kind never enters RunCleanup"
        Assert-CcodEqual $null $world.Transaction.installedBinding.resumeWrapperPid "$kind persists no replacement wrapper"
    }
}

$results += Invoke-CcodTest 'replacement recovery rejects historical wrapper SID and session inconsistency with zero writes' {
    foreach($kind in @('HistoricalSid','HistoricalSession')){
        $world=[pscustomobject]@{Calls=[Collections.Generic.List[string]]::new();Transaction=(New-CcodUninstallBootstrapTestTransaction -Phase 'TaskRemoved');Receipt=$null;ValidationError=$false;StageError=$false;CleanupError=$false;CleanupFailurePhase=$null;InstallRootAbsent=$false;StagedEntries=@();ProductRegistrationRemovals=0};$world.Transaction.installedBinding=New-CcodUninstallBootstrapTestInstalledBinding
        if($kind-ceq'HistoricalSid'){$world.Transaction.installedBinding.wrapperUserSid='S-1-5-21-999-888-777-1001'}else{$world.Transaction.installedBinding.wrapperSessionId=2}
        $fresh=New-CcodUninstallBootstrapContext;$fresh.sessionId=99;$fresh.payloadRecords=@($world.Transaction.installedBinding.payloadRecords);$adapters=New-CcodUninstallBootstrapAdapters $world;$adapters.ValidateInvocation={param($InstallerRoot,$InstallRoot)$fresh}.GetNewClosure();$adapters.GetInstalledBinding={param($InstallerRoot,$InstallRoot,$Context,$WrapperIdentity,$TransactionDirectory,$TransactionId)New-CcodUninstallBootstrapTestInstalledBinding -TransactionId $TransactionId -RuntimeRoot 'C:\install\runtime\2.5.0-uninstall-test' -InstallRoot 'C:\install' -UserSid $WrapperIdentity.userSid -SessionId $WrapperIdentity.sessionId -WrapperPid $WrapperIdentity.pid -WrapperCreationTimeUtc $WrapperIdentity.creationTimeUtc -PayloadRecords $Context.payloadRecords}.GetNewClosure();$replacement=[pscustomobject]@{pid=43;creationTimeUtc='2030-02-03T03:04:06.0000000Z';sessionId=99;userSid='S-1-5-21-111-222-333-1001'}
        Assert-CcodThrows {Invoke-CcodUninstallBootstrap -InstallerRoot 'C:\install\runtime\2.5.0-uninstall-test' -InstallRoot 'C:\install' -Mode PrepareInstalled -WrapperIdentity $replacement -Adapters $adapters|Out-Null} 'CCOD_UNINSTALL_TRANSACTION_INVALID'
        Assert-CcodEqual 0 @($world.Calls|Where-Object{$_-like'Write:*'-or$_-like'Receipt:*'}).Count "$kind performs zero persistence"
        Assert-CcodEqual $null $world.Transaction.installedBinding.resumeWrapperPid "$kind adopts no replacement wrapper"
    }
}

$results += Invoke-CcodTest 'replacement persistence rejects stale null-ambiguous no-op failed and malformed read-back' {
    foreach($mode in @('StaleReceipt','EmptyErrorReceipt','NullReceipt','TransactionNoOp','TransactionWriteFailure','StaleTransactionReadBack','MalformedTransactionReadBack','ReceiptWriteFailure','MalformedReceipt')){
        $transaction=New-CcodUninstallBootstrapTestTransaction -Phase 'TaskRemoved';$transaction.installedBinding=New-CcodUninstallBootstrapTestInstalledBinding;$originalJson=$transaction|ConvertTo-Json -Depth 16 -Compress;$originalReceipt=[pscustomobject][ordered]@{schemaVersion=1;transactionId=$transaction.transactionId;runtimeId=$transaction.runtimeId;runtimeGeneration=[uint64]$transaction.runtimeGeneration;leaseEpoch=[uint64]$transaction.leaseEpoch;phase='TaskRemoved';updatedAtUtc=$transaction.updatedAtUtc;errorCode=$null};$store=[pscustomobject]@{TransactionJson=$originalJson;ReceiptJson=($originalReceipt|ConvertTo-Json -Depth 8 -Compress);Reads=0;Clock=0}
        $world=[pscustomobject]@{Calls=[Collections.Generic.List[string]]::new();Transaction=$transaction;Receipt=$null;ValidationError=$false;StageError=$false;CleanupError=$false;CleanupFailurePhase=$null;InstallRootAbsent=$false;StagedEntries=@();ProductRegistrationRemovals=0};$fresh=New-CcodUninstallBootstrapContext;$fresh.sessionId=99;$fresh.payloadRecords=@($transaction.installedBinding.payloadRecords);$adapters=New-CcodUninstallBootstrapAdapters $world;$adapters.ValidateInvocation={param($InstallerRoot,$InstallRoot)$fresh}.GetNewClosure();$adapters.GetUtcNow={$store.Clock++;[DateTime]::Parse(('2030-02-03T03:04:{0:D2}Z'-f(5+$store.Clock))).ToUniversalTime()}.GetNewClosure();$adapters.GetInstalledBinding={param($InstallerRoot,$InstallRoot,$Context,$WrapperIdentity,$TransactionDirectory,$TransactionId)New-CcodUninstallBootstrapTestInstalledBinding -TransactionId $TransactionId -RuntimeRoot 'C:\install\runtime\2.5.0-uninstall-test' -InstallRoot 'C:\install' -UserSid $WrapperIdentity.userSid -SessionId $WrapperIdentity.sessionId -WrapperPid $WrapperIdentity.pid -WrapperCreationTimeUtc $WrapperIdentity.creationTimeUtc -PayloadRecords $Context.payloadRecords}.GetNewClosure()
        $adapters.ReadTransaction={param($Root,$Sid,$IncludeCompleted,$ExpectedRoot)$store.Reads++;if($mode-ceq'MalformedTransactionReadBack'-and$store.Reads-gt1){return [pscustomobject]@{bad='record'}};if($mode-ceq'StaleTransactionReadBack'-and$store.Reads-gt1){return $originalJson|ConvertFrom-Json};$store.TransactionJson|ConvertFrom-Json}.GetNewClosure()
        $adapters.WriteTransaction={param($Root,$Value)if($mode-ceq'TransactionWriteFailure'){throw [Management.Automation.ErrorRecord]::new([IO.IOException]::new('transaction write failed'),'CCOD_UNINSTALL_TRANSACTION_WRITE_FAILED',[Management.Automation.ErrorCategory]::WriteError,$Value.transactionId)};if($mode-cne'TransactionNoOp'){$store.TransactionJson=$Value|ConvertTo-Json -Depth 16 -Compress}}.GetNewClosure()
        $adapters.WriteReceipt={param($Root,$Value)if($mode-ceq'ReceiptWriteFailure'){throw [Management.Automation.ErrorRecord]::new([IO.IOException]::new('receipt write failed'),'CCOD_UNINSTALL_TRANSACTION_WRITE_FAILED',[Management.Automation.ErrorCategory]::WriteError,$Value.transactionId)};if($mode-notin@('StaleReceipt','EmptyErrorReceipt','NullReceipt','MalformedReceipt')){$receipt=[pscustomobject][ordered]@{schemaVersion=1;transactionId=$Value.transactionId;runtimeId=$Value.runtimeId;runtimeGeneration=[uint64]$Value.runtimeGeneration;leaseEpoch=[uint64]$Value.leaseEpoch;phase=$Value.phase;updatedAtUtc=$Value.updatedAtUtc;errorCode=$Value.errorCode};$store.ReceiptJson=$receipt|ConvertTo-Json -Depth 8 -Compress}}.GetNewClosure()
        $adapters.ReadReceipt={param($Root)if($mode-ceq'NullReceipt'){return $null};if($mode-ceq'MalformedReceipt'){return [pscustomobject]@{bad='receipt'}};if($mode-ceq'EmptyErrorReceipt'){$value=$store.TransactionJson|ConvertFrom-Json;return [pscustomobject][ordered]@{schemaVersion=1;transactionId=$value.transactionId;runtimeId=$value.runtimeId;runtimeGeneration=[uint64]$value.runtimeGeneration;leaseEpoch=[uint64]$value.leaseEpoch;phase=$value.phase;updatedAtUtc=$value.updatedAtUtc;errorCode=''}};$store.ReceiptJson|ConvertFrom-Json}.GetNewClosure()
        $replacement=[pscustomobject]@{pid=43;creationTimeUtc='2030-02-03T03:04:06.0000000Z';sessionId=99;userSid='S-1-5-21-111-222-333-1001'}
        Assert-CcodThrows {Invoke-CcodUninstallBootstrap -InstallerRoot 'C:\install\runtime\2.5.0-uninstall-test' -InstallRoot 'C:\install' -Mode PrepareInstalled -WrapperIdentity $replacement -Adapters $adapters|Out-Null} 'CCOD_UNINSTALL_TRANSACTION_WRITE_FAILED'
        $durable=$store.TransactionJson|ConvertFrom-Json;Assert-CcodEqual 'TaskRemoved' $durable.phase "$mode never advances application cleanup";Assert-CcodEqual 1 $durable.sessionId "$mode preserves historical session";Assert-CcodEqual 42 $durable.installedBinding.wrapperPid "$mode preserves historical wrapper"
    }
}

$results += Invoke-CcodTest 'interrupted replacement receipt write converges on an exact later retry' {
    $transaction=New-CcodUninstallBootstrapTestTransaction -Phase 'TaskRemoved';$transaction.installedBinding=New-CcodUninstallBootstrapTestInstalledBinding;$prior=[DateTime]::ParseExact($transaction.updatedAtUtc,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind);$store=[pscustomobject]@{TransactionJson=($transaction|ConvertTo-Json -Depth 16 -Compress);ReceiptJson=$null;FailReceipt=$true;Clock=0}
    $world=[pscustomobject]@{Calls=[Collections.Generic.List[string]]::new();Transaction=$transaction;Receipt=$null;ValidationError=$false;StageError=$false;CleanupError=$false;CleanupFailurePhase=$null;InstallRootAbsent=$false;StagedEntries=@();ProductRegistrationRemovals=0};$fresh=New-CcodUninstallBootstrapContext;$fresh.sessionId=99;$fresh.payloadRecords=@($transaction.installedBinding.payloadRecords);$adapters=New-CcodUninstallBootstrapAdapters $world;$adapters.ValidateInvocation={param($InstallerRoot,$InstallRoot)$fresh}.GetNewClosure();$adapters.GetUtcNow={$store.Clock++;[DateTime]::Parse(('2030-02-03T03:04:{0:D2}Z'-f(5+$store.Clock))).ToUniversalTime()}.GetNewClosure();$adapters.GetInstalledBinding={param($InstallerRoot,$InstallRoot,$Context,$WrapperIdentity,$TransactionDirectory,$TransactionId)New-CcodUninstallBootstrapTestInstalledBinding -TransactionId $TransactionId -RuntimeRoot 'C:\install\runtime\2.5.0-uninstall-test' -InstallRoot 'C:\install' -UserSid $WrapperIdentity.userSid -SessionId $WrapperIdentity.sessionId -WrapperPid $WrapperIdentity.pid -WrapperCreationTimeUtc $WrapperIdentity.creationTimeUtc -PayloadRecords $Context.payloadRecords}.GetNewClosure();$adapters.ReadTransaction={param($Root,$Sid,$IncludeCompleted,$ExpectedRoot)$store.TransactionJson|ConvertFrom-Json}.GetNewClosure();$adapters.WriteTransaction={param($Root,$Value)$store.TransactionJson=$Value|ConvertTo-Json -Depth 16 -Compress}.GetNewClosure();$adapters.WriteReceipt={param($Root,$Value)if($store.FailReceipt){$store.FailReceipt=$false;throw [Management.Automation.ErrorRecord]::new([IO.IOException]::new('first receipt write interrupted'),'CCOD_UNINSTALL_TRANSACTION_WRITE_FAILED',[Management.Automation.ErrorCategory]::WriteError,$Value.transactionId)};$receipt=[pscustomobject][ordered]@{schemaVersion=1;transactionId=$Value.transactionId;runtimeId=$Value.runtimeId;runtimeGeneration=[uint64]$Value.runtimeGeneration;leaseEpoch=[uint64]$Value.leaseEpoch;phase=$Value.phase;updatedAtUtc=$Value.updatedAtUtc;errorCode=$Value.errorCode};$store.ReceiptJson=$receipt|ConvertTo-Json -Depth 8 -Compress}.GetNewClosure();$adapters.ReadReceipt={param($Root)if($null-eq$store.ReceiptJson){$null}else{$store.ReceiptJson|ConvertFrom-Json}}.GetNewClosure()
    $first=[pscustomobject]@{pid=43;creationTimeUtc='2030-02-03T03:04:06.0000000Z';sessionId=99;userSid='S-1-5-21-111-222-333-1001'};Assert-CcodThrows {Invoke-CcodUninstallBootstrap -InstallerRoot 'C:\install\runtime\2.5.0-uninstall-test' -InstallRoot 'C:\install' -Mode PrepareInstalled -WrapperIdentity $first -Adapters $adapters|Out-Null} 'CCOD_UNINSTALL_TRANSACTION_WRITE_FAILED'
    $second=[pscustomobject]@{pid=44;creationTimeUtc='2030-02-03T03:04:07.0000000Z';sessionId=99;userSid='S-1-5-21-111-222-333-1001'};$result=Invoke-CcodUninstallBootstrap -InstallerRoot 'C:\install\runtime\2.5.0-uninstall-test' -InstallRoot 'C:\install' -Mode PrepareInstalled -WrapperIdentity $second -Adapters $adapters;$disk=$store.TransactionJson|ConvertFrom-Json
    Assert-CcodEqual 'TaskRemoved' $result.phase 'retry remains at the exact external finalizer boundary'
    Assert-CcodEqual 44 $disk.installedBinding.resumeWrapperPid 'retry replaces only the interrupted resume wrapper binding'
    Assert-CcodTrue ([DateTime]::ParseExact($disk.updatedAtUtc,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)-gt$prior) 'retry persists a fresh monotonic timestamp'
    Assert-CcodTrue (Test-CcodUninstallBootstrapReceiptMatchesTransaction -Receipt ($store.ReceiptJson|ConvertFrom-Json) -Transaction $disk) 'retry receipt binds the converged transaction'
}

$results += Invoke-CcodTest 'WrapperResume rejects PID creation session and SID mutations before waiting or reclaiming' {
    foreach($kind in @('Pid','Creation','Session','Sid')){
        $transaction=New-CcodUninstallBootstrapTestTransaction -Phase 'TaskRemoved';$transaction.installedBinding=New-CcodUninstallBootstrapTestInstalledBinding;$transaction.installedBinding.resumeWrapperPid=43;$transaction.installedBinding.resumeWrapperCreationTimeUtc='2030-02-03T03:04:06.0000000Z';$transaction.installedBinding.resumeWrapperSessionId=99;$transaction.installedBinding.resumeWrapperUserSid=$transaction.userSid
        $world=[pscustomobject]@{Calls=[Collections.Generic.List[string]]::new();Transaction=$transaction;RootPresent=$true;PublicEntry=$false;PublicCommand=$null;ShortcutsPresent=$true;CompletedReceipt=$false;Failure=$null;FailureInjected=$false;EntryPresentAtReclaim=$false};$adapters=New-CcodInstalledFinalizerMemoryAdapters $world
        $identity=[pscustomobject]@{pid=43;creationTimeUtc='2030-02-03T03:04:06.0000000Z';sessionId=99;userSid=$transaction.userSid};switch($kind){'Pid'{$identity.pid=44}'Creation'{$identity.creationTimeUtc='2030-02-03T03:04:07.0000000Z'}'Session'{$identity.sessionId=100}'Sid'{$identity.userSid='S-1-5-21-999-888-777-1001'}}
        Assert-CcodThrows {Invoke-CcodInstalledUninstallFinalizer -TransactionId $transaction.transactionId -RuntimeRoot $transaction.installedBinding.selectedRuntimeRoot -InstallRoot 'C:\install' -WrapperIdentity $identity -WrapperResume -Adapters $adapters|Out-Null} 'CCOD_INSTALLED_FINALIZER_INVALID'
        Assert-CcodEqual 0 @($world.Calls|Where-Object{$_-in@('WaitWrapper','Reclaim','Write:ReadyForInno')}).Count "$kind mismatch is rejected before wrapper wait or reclamation"
    }
}

# Production mutation caught: a finalizer-start failure leaves no anchor, and a replacement
# wrapper from a new session must bind itself and still be waited before reclamation.
$results += Invoke-CcodTest 'finalizer-start failure recovers through same-SID new-session WrapperResume exact wait' {
    $world=[pscustomobject]@{Calls=[Collections.Generic.List[string]]::new();Transaction=$null;Receipt=$null;ValidationError=$false;StageError=$false;CleanupError=$false;CleanupFailurePhase=$null;InstallRootAbsent=$false;StagedEntries=@();ProductRegistrationRemovals=0}
    $adapters=New-CcodUninstallBootstrapAdapters $world
    $originalCleanup=$adapters.RunCleanup
    $adapters.RunCleanup={param($InstallerRoot,$InstallRoot,$TransactionRoot,$Transaction,$WriteTransaction,$Mode);$world.Calls.Add("Cleanup:$Mode");$Transaction.phase='TaskRemoved';$Transaction.resumePhase='TaskRemoved';&$WriteTransaction $TransactionRoot $Transaction;$Transaction}.GetNewClosure()
    $adapters.GetInstalledBinding={param($InstallerRoot,$InstallRoot,$Context,$WrapperIdentity,$TransactionDirectory,$TransactionId)New-CcodUninstallBootstrapTestInstalledBinding -TransactionId $TransactionId -RuntimeRoot 'C:\install\runtime\2.5.0-uninstall-test' -InstallRoot 'C:\install' -UserSid $WrapperIdentity.userSid -SessionId $WrapperIdentity.sessionId -WrapperPid $WrapperIdentity.pid -WrapperCreationTimeUtc $WrapperIdentity.creationTimeUtc -PayloadRecords $Context.payloadRecords}.GetNewClosure()
    $wrapperIdentity=[pscustomobject]@{pid=42;creationTimeUtc='2030-02-03T03:04:05.0000000Z';sessionId=1;userSid='S-1-5-21-111-222-333-1001'}
    $prepared=Invoke-CcodUninstallBootstrap -InstallerRoot 'C:\install\runtime\2.5.0-uninstall-test' -InstallRoot 'C:\install' -Mode PrepareInstalled -WrapperIdentity $wrapperIdentity -Adapters $adapters
    Assert-CcodEqual 'TaskRemoved' $prepared.phase 'installed wrapper retains application state until it exits'
    Assert-CcodEqual 0 $world.ProductRegistrationRemovals 'installed Prepare removes no product state before the external finalizer'
    $startFailure=$null;try{throw [Management.Automation.ErrorRecord]::new([IO.IOException]::new('injected finalizer start failure'),'CCOD_UNINSTALL_INSTALLED_FINALIZER_START_FAILED',[Management.Automation.ErrorCategory]::OpenError,$prepared.transactionId)}catch{$startFailure=$_}
    Assert-CcodEqual 'CCOD_UNINSTALL_INSTALLED_FINALIZER_START_FAILED' (([string]$startFailure.FullyQualifiedErrorId-split',')[0]) 'first public invocation fails only after durable TaskRemoved and before any Apps anchor'

    $replacementWrapper=[pscustomobject]@{pid=43;creationTimeUtc='2030-02-03T03:04:06.0000000Z';sessionId=99;userSid='S-1-5-21-111-222-333-1001'}
    $replacementContext=New-CcodUninstallBootstrapContext;$replacementContext.sessionId=99;$adapters.ValidateInvocation={param($InstallerRoot,$InstallRoot)$replacementContext}.GetNewClosure()
    $resumedPrepare=Invoke-CcodUninstallBootstrap -InstallerRoot 'C:\install\runtime\2.5.0-uninstall-test' -InstallRoot 'C:\install' -Mode PrepareInstalled -WrapperIdentity $replacementWrapper -Adapters $adapters
    Assert-CcodEqual 'TaskRemoved' $resumedPrepare.phase 'a later runtime wrapper reuses the staged transaction instead of replacing historical wrapper proof'
    Assert-CcodEqual 42 $resumedPrepare.installedBinding.wrapperPid 'historical wrapper identity remains immutable during public retry'
    Assert-CcodEqual 43 $resumedPrepare.installedBinding.resumeWrapperPid 'replacement wrapper launch identity is persisted separately before returning'
    Assert-CcodEqual 99 $resumedPrepare.installedBinding.resumeWrapperSessionId 'same-SID replacement wrapper may come from a new login session without rewriting historical identity'
    Assert-CcodEqual 1 @($world.Calls|Where-Object{$_-ceq'Cleanup:PrepareInstalled'}).Count 'existing TaskRemoved replacement PrepareInstalled never re-enters application cleanup'

    $final=[pscustomobject]@{Calls=[Collections.Generic.List[string]]::new();Transaction=$resumedPrepare;RootPresent=$true;PublicEntry=$false;PublicCommand=$null;ShortcutsPresent=$true;CompletedReceipt=$false;Failure=$null;FailureInjected=$false;EntryPresentAtReclaim=$false}
    $finalAdapters=New-CcodInstalledFinalizerMemoryAdapters $final
    $receipt=Invoke-CcodInstalledUninstallFinalizer -TransactionId $prepared.transactionId -RuntimeRoot 'C:\install\runtime\2.5.0-uninstall-test' -InstallRoot 'C:\install' -WrapperIdentity $replacementWrapper -WrapperResume -Adapters $finalAdapters
    Assert-CcodEqual 'Completed' $receipt.phase 'external finalizer reaches the completion receipt'
    Assert-CcodTrue (-not$final.PublicEntry) 'public recovery entry is removed only after the Completed receipt'
    Assert-CcodTrue $final.EntryPresentAtReclaim 'durable public recovery entry exists before generation reclamation'
    Assert-CcodTrue (@($final.Calls)-ccontains'WaitWrapper') 'replacement wrapper finalizer waits for the exact replacement instance before reclamation'
    Assert-CcodEqual 43 $final.LastWaitIdentity.pid 'WrapperResume waits the newly persisted replacement PID'
    Assert-CcodEqual '2030-02-03T03:04:06.0000000Z' $final.LastWaitIdentity.creationTimeUtc 'WrapperResume waits the newly persisted replacement creation time'
    Assert-CcodEqual 99 $final.LastWaitIdentity.sessionId 'WrapperResume waits the newly persisted replacement session'
    $localLock=[Array]::IndexOf(@($final.Calls),'Lock');$accountLock=[Array]::IndexOf(@($final.Calls),'AccountLock');$reclaim=[Array]::IndexOf(@($final.Calls),'Reclaim');$registry=[Array]::IndexOf(@($final.Calls),'RemoveRegistry');$accountUnlock=[Array]::IndexOf(@($final.Calls),'AccountUnlock');$localUnlock=[Array]::IndexOf(@($final.Calls),'Unlock')
    Assert-CcodTrue ($localLock-ge0-and$accountLock-gt$localLock-and$reclaim-gt$accountLock-and$registry-gt$reclaim-and$accountUnlock-gt$registry-and$localUnlock-gt$accountUnlock) 'Local uninstall then Global AccountTransition acquisition order spans the complete tail without ABBA'
}

# Production mutation caught: after the selected generation is irreversibly reclaimed, a failed
# phase write, shortcut/product cleanup, final receipt, or final registry delete must remain
# reachable through the durable staged public uninstall entry.
$results += Invoke-CcodTest 'installed finalizer resumes every post-reclamation tail failure through the durable public entry' {
    $outcomes=[Collections.Generic.List[string]]::new()
    foreach($kind in @('PhaseWrite','ProductShortcuts','FinalReceipt','FinalRegistry')){
        $transaction=New-CcodUninstallBootstrapTestTransaction -Phase 'TaskRemoved'
        $transaction.installedBinding=New-CcodUninstallBootstrapTestInstalledBinding
        $world=[pscustomobject]@{
            Calls=[Collections.Generic.List[string]]::new();Transaction=$transaction;RootPresent=$true;PublicEntry=$false;PublicCommand=$null;ShortcutsPresent=$true;CompletedReceipt=$false
            Failure=$kind;FailureInjected=$false;EntryPresentAtReclaim=$false
        }
        $adapters=New-CcodInstalledFinalizerMemoryAdapters $world
        $identity=[pscustomobject]@{pid=42;creationTimeUtc='2030-02-03T03:04:05.0000000Z';sessionId=1;userSid='S-1-5-21-111-222-333-1001'}
        $first=$null;try{Invoke-CcodInstalledUninstallFinalizer -TransactionId $transaction.transactionId -RuntimeRoot $transaction.installedBinding.selectedRuntimeRoot -InstallRoot 'C:\install' -WrapperIdentity $identity -Adapters $adapters|Out-Null}catch{$first=$_}
        Assert-CcodTrue ($null-ne$first) "$kind first invocation injects a real post-reclamation failure"
        Assert-CcodTrue $world.EntryPresentAtReclaim "$kind has the durable public entry before reclamation"
        Assert-CcodTrue $world.PublicEntry "$kind keeps the public recovery entry after the first failure"
        Assert-CcodEqual ([string]$transaction.installedBinding.resumeCommand) ([string]$world.PublicCommand) "$kind keeps the exact staged resume command discoverable"

        if($kind-ceq'FinalReceipt'){$adapters.GetCurrentIdentity={ [pscustomobject]@{userSid='S-1-5-21-111-222-333-1001';sessionId=99} }}
        $second=$null;$receipt=$null;try{$receipt=Invoke-CcodInstalledFinalizerPublicResume -World $world -Adapters $adapters}catch{$second=$_}
        $secondOutcome=if($null-ne$receipt){[string]$receipt.phase}else{([string]$second.FullyQualifiedErrorId-split',')[0]}
        $outcomes.Add(('{0}:{1}:phase={2}:entry={3}:receipt={4}'-f$kind,$secondOutcome,[string]$world.Transaction.phase,[bool]$world.PublicEntry,[bool]$world.CompletedReceipt))
        $mutationsBefore=@($world.Calls|Where-Object{$_-in@('Reclaim','Write:ReadyForInno','ProductShortcuts','FinalizeReceipt','RemoveRegistry')}).Count
        $replay=Invoke-CcodInstalledUninstallFinalizer -TransactionId $transaction.transactionId -RuntimeRoot $transaction.installedBinding.selectedRuntimeRoot -InstallRoot 'C:\install' -WrapperIdentity $null -Resume -Adapters $adapters
        Assert-CcodEqual 'Completed' $replay.phase "$kind already-dispatched serial replay observes converged Completed"
        Assert-CcodEqual $mutationsBefore @($world.Calls|Where-Object{$_-in@('Reclaim','Write:ReadyForInno','ProductShortcuts','FinalizeReceipt','RemoveRegistry')}).Count "$kind Completed replay performs no mutation after the anchor is absent"
    }
    $expected=@(
        'PhaseWrite:Completed:phase=Completed:entry=False:receipt=True',
        'ProductShortcuts:Completed:phase=Completed:entry=False:receipt=True',
        'FinalReceipt:Completed:phase=Completed:entry=False:receipt=True',
        'FinalRegistry:Completed:phase=Completed:entry=False:receipt=True'
    )-join'|'
    Assert-CcodEqual $expected (@($outcomes)-join'|') 'every post-reclamation failure converges on its second public invocation'
}

$results += Invoke-CcodTest 'delayed initial finalizer accepts an absent or reused historical wrapper identity' {
    $adapters=Get-CcodInstalledFinalizerAdapters -Adapters $null -TransactionRoot 'C:\unused' -PayloadRoot 'C:\unused\payload' -RuntimeRoot 'C:\install\runtime\unused' -InstallRoot 'C:\install'
    $absent=&$adapters.WaitWrapperExit ([pscustomobject]@{pid=2147483646;creationTimeUtc='2030-02-03T03:04:05.0000000Z';sessionId=1;userSid='S-1-5-21-111-222-333-1001'}) 1
    Assert-CcodTrue ($absent.verifiedAtStart-and$absent.exited) 'durably bound historical PID absence proves the original wrapper has exited'
    $process=[Diagnostics.Process]::GetCurrentProcess();try{$identity=[Security.Principal.WindowsIdentity]::GetCurrent();try{$sid=[string]$identity.User.Value}finally{$identity.Dispose()};$reused=&$adapters.WaitWrapperExit ([pscustomobject]@{pid=[int]$process.Id;creationTimeUtc='2001-02-03T04:05:06.0000000Z';sessionId=[int]$process.SessionId;userSid=$sid}) 1}finally{$process.Dispose()}
    Assert-CcodTrue ($reused.verifiedAtStart-and$reused.exited) 'same PID with a different creation time is a reused process not the historical wrapper'
}

$results += Invoke-CcodTest 'resume rejects a missing anchor or changed command payload caller and epoch before deletion' {
    foreach($kind in @('MissingAnchor','ResumeCommand','ResumeScriptHash','PayloadHash','CallerSid','Epoch')){
        $transaction=New-CcodUninstallBootstrapTestTransaction -Phase 'TaskRemoved';$transaction.installedBinding=New-CcodUninstallBootstrapTestInstalledBinding
        $world=[pscustomobject]@{Calls=[Collections.Generic.List[string]]::new();Transaction=$transaction;RootPresent=($kind-cne'MissingAnchor');PublicEntry=($kind-cne'MissingAnchor');PublicCommand=[string]$transaction.installedBinding.resumeCommand;ShortcutsPresent=$true;CompletedReceipt=$false;Failure=$null;FailureInjected=$false;EntryPresentAtReclaim=$false}
        if($kind-ceq'ResumeCommand'){$transaction.installedBinding.resumeCommand+=' --foreign';$world.PublicCommand=$transaction.installedBinding.resumeCommand}
        if($kind-ceq'ResumeScriptHash'){$transaction.installedBinding.resumeScriptSha256=('f'*64)}
        $adapters=New-CcodInstalledFinalizerMemoryAdapters $world
        if($kind-ceq'PayloadHash'){$adapters.ValidateStagedPayload={param($T,$R)$false}}
        if($kind-ceq'CallerSid'){$adapters.GetCurrentIdentity={ [pscustomobject]@{userSid='S-1-5-21-999-888-777-1001';sessionId=7} }}
        if($kind-ceq'Epoch'){$adapters.ReadCurrentEpoch={param($Root)[uint64]12}}
        Assert-CcodThrows {Invoke-CcodInstalledUninstallFinalizer -TransactionId $transaction.transactionId -RuntimeRoot $transaction.installedBinding.selectedRuntimeRoot -InstallRoot 'C:\install' -WrapperIdentity $null -Resume -Adapters $adapters|Out-Null} 'CCOD_INSTALLED_FINALIZER_INVALID'
        Assert-CcodEqual 0 @($world.Calls|Where-Object{$_-in@('Reclaim','Write:ReadyForInno','ProductShortcuts','FinalizeReceipt','RemoveRegistry')}).Count "$kind performs no reclamation or product tail mutation"
    }
}

$results += Invoke-CcodTest 'epoch is re-read under AccountTransition immediately before reclamation' {
    $transaction=New-CcodUninstallBootstrapTestTransaction -Phase 'TaskRemoved';$transaction.installedBinding=New-CcodUninstallBootstrapTestInstalledBinding
    $world=[pscustomobject]@{Calls=[Collections.Generic.List[string]]::new();Transaction=$transaction;RootPresent=$true;PublicEntry=$false;PublicCommand=$null;ShortcutsPresent=$true;CompletedReceipt=$false;Failure=$null;FailureInjected=$false;EntryPresentAtReclaim=$false};$adapters=New-CcodInstalledFinalizerMemoryAdapters $world;$epochReads=[pscustomobject]@{Count=0}
    $adapters.ReadCurrentEpoch={param($Root)$epochReads.Count++;if($epochReads.Count-eq1){[uint64]11}else{[uint64]12}}.GetNewClosure()
    Assert-CcodThrows {Invoke-CcodInstalledUninstallFinalizer -TransactionId $transaction.transactionId -RuntimeRoot $transaction.installedBinding.selectedRuntimeRoot -InstallRoot 'C:\install' -WrapperIdentity ([pscustomobject]@{pid=42;creationTimeUtc='2030-02-03T03:04:05.0000000Z';sessionId=1;userSid='S-1-5-21-111-222-333-1001'}) -Adapters $adapters|Out-Null} 'CCOD_INSTALLED_FINALIZER_INVALID'
    Assert-CcodEqual 2 $epochReads.Count 'epoch is checked after lock acquisition and again at the reclaim boundary'
    Assert-CcodEqual 0 @($world.Calls|Where-Object{$_-ceq'Reclaim'}).Count 'epoch drift reaches no irreversible reclamation'
    Assert-CcodEqual $false $world.PublicEntry 'epoch drift before resume publication leaves the original product entry and generation intact'
}

# Production mutation caught: treating any durable transaction/path/process as authority to delete application state.
$results += Invoke-CcodTest 'installed finalizer wrong wrapper generation path or transaction performs no deletion' {
    foreach($kind in @('Wrapper','Generation','Transaction','Epoch','Sibling')){
        $transaction=New-CcodUninstallBootstrapTestTransaction -Phase 'TaskRemoved'
        $boundRoot=if($kind-ceq'Sibling'){'C:\install\runtime\sibling'}else{'C:\install\runtime\2.5.0-uninstall-test'};$transaction.installedBinding=New-CcodUninstallBootstrapTestInstalledBinding -RuntimeRoot $boundRoot
        if($kind-ceq'Transaction'){$transaction.transactionId='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'}
        $world=[pscustomobject]@{Calls=[Collections.Generic.List[string]]::new();Transaction=$transaction;RootPresent=$true;PublicEntry=$false;PublicCommand=$null;ShortcutsPresent=$true;CompletedReceipt=$false;Failure=$null;FailureInjected=$false;EntryPresentAtReclaim=$false}
        $adapters=New-CcodInstalledFinalizerMemoryAdapters $world
        if($kind-ceq'Wrapper'){$adapters.WaitWrapperExit={param($Identity,$Timeout)[pscustomobject]@{verifiedAtStart=$false;exited=$false}}}
        if($kind-ceq'Generation'){$adapters.ValidateSelectedGeneration={param($RuntimeRoot,$InstallRoot,$Value)$false}}
        if($kind-ceq'Epoch'){$adapters.ReadCurrentEpoch={param($InstallRoot)[uint64]12}}
        Assert-CcodThrows {Invoke-CcodInstalledUninstallFinalizer -TransactionId '11111111-2222-3333-4444-555555555555' -RuntimeRoot 'C:\install\runtime\2.5.0-uninstall-test' -InstallRoot 'C:\install' -WrapperIdentity ([pscustomobject]@{pid=42;creationTimeUtc='2030-02-03T03:04:05.0000000Z';sessionId=1;userSid='S-1-5-21-111-222-333-1001'}) -Adapters $adapters|Out-Null} 'CCOD_INSTALLED_FINALIZER_INVALID'
        Assert-CcodEqual 0 @($world.Calls|Where-Object{$_-ceq'Reclaim'}).Count "$kind mismatch deletes no application state"
    }
}

$results += Invoke-CcodTest 'noncanonical Ready shortcut target is rejected before uninstall cleanup' {
    $world=[pscustomobject]@{Calls=[Collections.Generic.List[string]]::new();Transaction=$null;Receipt=$null;ValidationError=$false;StageError=$false;CleanupError=$false;CleanupFailurePhase=$null;InstallRootAbsent=$false;StagedEntries=@();ProductRegistrationRemovals=0};$adapters=New-CcodUninstallBootstrapAdapters $world;$context=New-CcodUninstallBootstrapContext;$context.readyEvidence.targetPath='C:\outside\task.exe';$adapters.ValidateInvocation={param($InstallerRoot,$InstallRoot)$context}.GetNewClosure()
    Assert-CcodThrows {Invoke-CcodUninstallBootstrap -InstallerRoot 'C:\runtime' -InstallRoot 'C:\install' -Mode Prepare -Adapters $adapters|Out-Null} 'CCOD_UNINSTALL_BOOTSTRAP_INVALID'
    Assert-CcodEqual 0 @($world.Calls|Where-Object{$_-ceq'Cleanup'}).Count 'invalid target evidence reaches no cleanup deletion'
}

# Production mutation caught: a rooted but unrelated installRoot, or an added field, survives a weaker
# fresh/stored Ready check and reaches application cleanup.
$results += Invoke-CcodTest 'fresh and stored Ready evidence require one exact current-install-root invariant before cleanup' {
    foreach($source in @('Fresh','Stored')){
        foreach($mutation in @('WrongRoot','ExtraField')){
            $world=[pscustomobject]@{Calls=[Collections.Generic.List[string]]::new();Transaction=$null;Receipt=$null;ValidationError=$false;StageError=$false;CleanupError=$false;CleanupFailurePhase=$null;InstallRootAbsent=$false;StagedEntries=@();ProductRegistrationRemovals=0}
            $context=New-CcodUninstallBootstrapContext
            if($source-ceq'Stored'){$world.Transaction=New-CcodUninstallBootstrapTestTransaction -Phase 'TaskRemoved'}
            $ready=if($source-ceq'Fresh'){$context.readyEvidence}else{$world.Transaction.readyEvidence}
            if($mutation-ceq'WrongRoot'){$ready.installRoot='C:\unrelated\CodexControlOtherDevices'}else{$ready|Add-Member -NotePropertyName unexpectedReadyField -NotePropertyValue 'reject'}
            $adapters=New-CcodUninstallBootstrapAdapters $world
            $adapters.ValidateInvocation={param($InstallerRoot,$InstallRoot)$context}.GetNewClosure()
            Assert-CcodThrows {Invoke-CcodUninstallBootstrap -InstallerRoot 'C:\runtime' -InstallRoot 'C:\install' -Mode Prepare -Adapters $adapters|Out-Null} $(if($source-ceq'Fresh'){'CCOD_UNINSTALL_BOOTSTRAP_INVALID'}else{'CCOD_UNINSTALL_TRANSACTION_INVALID'})
            Assert-CcodEqual 0 @($world.Calls|Where-Object{$_-ceq'Cleanup'}).Count "$source $mutation Ready mutation reaches no cleanup"
        }
    }
}

function Invoke-CcodDefaultInstalledProductCleanupCase {
    param([switch]$PartialFailure)
    $local=New-CcodUninstallBootstrapTestRoot ('ccod-installed-finalizer-'+[guid]::NewGuid().ToString('N'));$previous=[Environment]::GetEnvironmentVariable('LOCALAPPDATA','Process')
    try{
        [Environment]::SetEnvironmentVariable('LOCALAPPDATA',$local,'Process');$install=Join-Path $local 'CodexControlOtherDevices';$fixture=New-CcodVerifiedUninstallRuntimeFixture -InstallRoot $install -AppendOnly -ProjectVersion '2.5.22';$identity=Get-CcodUninstallBootstrapCurrentIdentity;$transactionRoot=Get-CcodUninstallBootstrapDefaultTransactionRoot;$id='11111111-2222-3333-4444-555555555555';$directory=New-CcodUninstallBootstrapTransactionDirectory -TransactionRoot $transactionRoot -TransactionId $id -UserSid $identity.userSid
        $payload=Join-Path $directory 'payload';$recordMap=@{};foreach($relative in $script:CcodUninstallPayloadEntries){$source=Join-Path $fixture.RuntimeRoot $relative.Replace('/','\');$destination=Join-Path $payload $relative.Replace('/','\');[IO.Directory]::CreateDirectory((Split-Path $destination -Parent))|Out-Null;[IO.File]::Copy($source,$destination,$true);$recordMap[$relative]=Get-CcodUninstallBootstrapFileFingerprint $source};$payloadRecords=New-CcodUninstallBootstrapPayloadRecords -RecordMap $recordMap
        $tx=New-CcodUninstallBootstrapTestTransaction -Phase 'TaskRemoved';$tx.runtimeId=$fixture.RuntimeId;$tx.runtimeGeneration=[uint64]7;$tx.userSid=$identity.userSid;$tx.sessionId=$identity.sessionId;$tx.readyEvidence.runtimeId=$fixture.RuntimeId;$tx.readyEvidence.runtimeGeneration=[uint64]7;$tx.readyEvidence.installRoot=$install;$manifest=(Get-FileHash (Join-Path $fixture.RuntimeRoot 'manifest.json') -Algorithm SHA256).Hash.ToLowerInvariant();$tx.readyEvidence.manifestSha256=$manifest;$tx.installedBinding=New-CcodUninstallBootstrapTestInstalledBinding -TransactionId $id -RuntimeRoot $fixture.RuntimeRoot -InstallRoot $install -UserSid $identity.userSid -SessionId $identity.sessionId -PayloadRecords $payloadRecords -TransactionDirectory $directory -RuntimeManifestSha256 $manifest;$timestamp=[DateTime]::UtcNow.AddMinutes(-1).ToString('o',[Globalization.CultureInfo]::InvariantCulture);$tx.startedAtUtc=$timestamp;$tx.updatedAtUtc=$timestamp;Write-CcodUninstallBootstrapStoredTransaction -TransactionDirectory $directory -Transaction $tx;Publish-CcodUninstallBootstrapCurrentTransaction -TransactionRoot $transactionRoot -TransactionId $id -UserSid $identity.userSid
        $resume=[pscustomobject]@{Present=$false};$overrides=@{WaitWrapperExit={param($I,$T)[pscustomobject]@{verifiedAtStart=$true;exited=$true}};InstallResumeProductRegistration={param($T)$resume.Present=$true}.GetNewClosure();GetResumeProductRegistrationState={param($T)if($resume.Present){'Exact'}else{'Absent'}}.GetNewClosure();RemoveMatchedProductShortcuts={param($T)};RemoveResumeProductRegistration={param($T)$resume.Present=$false;$true}.GetNewClosure()};$adapters=Get-CcodInstalledFinalizerAdapters -Adapters $overrides -TransactionRoot $transactionRoot -PayloadRoot $payload -RuntimeRoot $fixture.RuntimeRoot -InstallRoot $install
        $wrapper=[pscustomobject]@{pid=42;creationTimeUtc='2030-02-03T03:04:05.0000000Z';sessionId=$identity.sessionId;userSid=$identity.userSid}
        if($PartialFailure){
            $defaultCleanup=$adapters.CleanupProductResidue
            $adapters.CleanupProductResidue={param($Transaction)
                $path=Join-Path $payload 'src/persistence/modules/GenerationReclamation.psm1'
                $reclamation=Import-Module $path -Force -PassThru -DisableNameChecking
                &$reclamation {$script:CcodProductResidueFailCommitAtForTest=18}
                try {&$reclamation {param($Root,$Tx,$Directory)Remove-CcodVerifiedProductResidue -InstallRoot $Root -SelectedRuntimeId $Tx.runtimeId -ExpectedEpoch ([uint64]$Tx.leaseEpoch) -TransactionDirectory $Directory -TransactionId $Tx.transactionId} $install $Transaction $directory}
                finally {&$reclamation {$script:CcodProductResidueFailCommitAtForTest=-1}}
            }.GetNewClosure()
            Assert-CcodThrows {Invoke-CcodInstalledUninstallFinalizer -TransactionId $id -RuntimeRoot $fixture.RuntimeRoot -InstallRoot $install -WrapperIdentity $wrapper -Adapters $adapters|Out-Null} 'CCOD_PRODUCT_RESIDUE_INVALID'
            Assert-CcodTrue $resume.Present 'actual cleanup failure retains the public resume entry'
            Assert-CcodTrue (-not(Test-Path (Join-Path $install 'state/lifecycle-epoch.json'))) 'failure occurs after the live epoch file was deleted'
            $adapters.CleanupProductResidue=$defaultCleanup
            $receipt=Invoke-CcodInstalledUninstallFinalizer -TransactionId $id -RuntimeRoot $fixture.RuntimeRoot -InstallRoot $install -Resume -Adapters $adapters
        }else{$receipt=Invoke-CcodInstalledUninstallFinalizer -TransactionId $id -RuntimeRoot $fixture.RuntimeRoot -InstallRoot $install -WrapperIdentity $wrapper -Adapters $adapters}
        Assert-CcodEqual 'Completed' $receipt.phase 'default finalizer reaches completion'
        Assert-CcodTrue (-not(Test-Path $fixture.RuntimeRoot)) 'default finalizer deletes exact selected runtime'
        Assert-CcodTrue (-not(Test-Path $install)) 'completion receipt requires the product root and state to be absent'
        Assert-CcodTrue (-not$resume.Present) 'default finalizer removes the public anchor last'
    }finally{[Environment]::SetEnvironmentVariable('LOCALAPPDATA',$previous,'Process');if([IO.Directory]::Exists($local)){Remove-CcodTestOwnedTree -Path $local}}
}

$results += Invoke-CcodTest 'default installed finalizer completes bounded product cleanup before its completion receipt' {Invoke-CcodDefaultInstalledProductCleanupCase}
$results += Invoke-CcodTest 'default installed finalizer resumes after product cleanup removed the live epoch file' {Invoke-CcodDefaultInstalledProductCleanupCase -PartialFailure}

function Invoke-CcodInstalledReclamationMutationCase {
    param([Parameter(Mandatory)][ValidateSet('UnexpectedFile','UnexpectedDirectory','Reparse','Hardlink','Ads','OpenChild')][string]$Mutation)
    $local=New-CcodUninstallBootstrapTestRoot ('ccod-installed-reclamation-red-'+[guid]::NewGuid().ToString('N'));$previous=[Environment]::GetEnvironmentVariable('LOCALAPPDATA','Process');$attackState=[pscustomobject]@{Path=$null;OpenHandle=$null}
    try{
        [Environment]::SetEnvironmentVariable('LOCALAPPDATA',$local,'Process');$install=Join-Path $local 'CodexControlOtherDevices';$fixture=New-CcodVerifiedUninstallRuntimeFixture -InstallRoot $install -AppendOnly
        $originalFiles=@(Get-ChildItem -LiteralPath $fixture.RuntimeRoot -File -Recurse -Force|ForEach-Object{[pscustomobject]@{Path=$_.FullName;Length=[int64]$_.Length;Sha256=Get-CcodTestFileSha256 $_.FullName}});$originalDirectories=@(Get-ChildItem -LiteralPath $fixture.RuntimeRoot -Directory -Recurse -Force|ForEach-Object FullName)
        $outside=Join-Path $local 'outside';[IO.Directory]::CreateDirectory($outside)|Out-Null;$outsideSentinel=Join-Path $outside 'sentinel.bin';[IO.File]::WriteAllText($outsideSentinel,'outside-preserved',[Text.UTF8Encoding]::new($false));$outsideHash=Get-CcodTestFileSha256 $outsideSentinel
        $sibling=Join-Path $install 'runtime\sibling-generation';[IO.Directory]::CreateDirectory($sibling)|Out-Null;$siblingSentinel=Join-Path $sibling 'sentinel.bin';[IO.File]::WriteAllText($siblingSentinel,'sibling-preserved',[Text.UTF8Encoding]::new($false));$siblingHash=Get-CcodTestFileSha256 $siblingSentinel
        $deviceKey=Join-Path $install 'state\device-key\private.bin';[IO.Directory]::CreateDirectory((Split-Path $deviceKey -Parent))|Out-Null;[IO.File]::WriteAllText($deviceKey,'dpapi-sentinel-preserved',[Text.UTF8Encoding]::new($false));$deviceKeyHash=Get-CcodTestFileSha256 $deviceKey
        $identity=Get-CcodUninstallBootstrapCurrentIdentity;$transactionRoot=Get-CcodUninstallBootstrapDefaultTransactionRoot;$id=[guid]::NewGuid().ToString('D');$directory=New-CcodUninstallBootstrapTransactionDirectory -TransactionRoot $transactionRoot -TransactionId $id -UserSid $identity.userSid
        $tx=New-CcodUninstallBootstrapTestTransaction -Phase 'TaskRemoved' -TransactionId $id;$tx.runtimeId=$fixture.RuntimeId;$tx.runtimeGeneration=[uint64]7;$tx.userSid=$identity.userSid;$tx.sessionId=$identity.sessionId;$tx.readyEvidence.runtimeId=$fixture.RuntimeId;$tx.readyEvidence.runtimeGeneration=[uint64]7;$tx.readyEvidence.installRoot=$install;$manifest=(Get-FileHash (Join-Path $fixture.RuntimeRoot 'manifest.json') -Algorithm SHA256).Hash.ToLowerInvariant();$tx.readyEvidence.manifestSha256=$manifest;$tx.installedBinding=New-CcodUninstallBootstrapTestInstalledBinding -TransactionId $id -RuntimeRoot $fixture.RuntimeRoot -InstallRoot $install -UserSid $identity.userSid -SessionId $identity.sessionId -TransactionDirectory $directory -RuntimeManifestSha256 $manifest;Write-CcodUninstallBootstrapStoredTransaction -TransactionDirectory $directory -Transaction $tx
        $payload=Join-Path $directory 'payload';[IO.Directory]::CreateDirectory((Join-Path $payload 'src\persistence'))|Out-Null;[IO.File]::Copy($bootstrapScript,(Join-Path $payload 'src\persistence\UninstallBootstrap.ps1'),$true);$reclamationSource=Join-Path $repositoryRoot 'src\persistence\modules\GenerationReclamation.psm1';if(Test-Path -LiteralPath $reclamationSource -PathType Leaf){$reclamationDestination=Join-Path $payload 'src\persistence\modules\GenerationReclamation.psm1';[IO.Directory]::CreateDirectory((Split-Path $reclamationDestination -Parent))|Out-Null;[IO.File]::Copy($reclamationSource,$reclamationDestination,$true)}
        $resume=[pscustomobject]@{Present=$false};$overrides=@{EnterAccountTransition={param($Sid)[pscustomobject]@{Held=$true}};ExitAccountTransition={param($Lease)$Lease.Held=$false};ValidateStagedPayload={param($T,$R)$true};WaitWrapperExit={param($I,$T)[pscustomobject]@{verifiedAtStart=$true;exited=$true}};ReadPreparedTransaction={param($Id,$Root)$tx}.GetNewClosure();ReadCurrentEpoch={param($Root)[uint64]11};InstallResumeProductRegistration={param($T)$resume.Present=$true}.GetNewClosure();GetResumeProductRegistrationState={param($T)if($resume.Present){'Exact'}else{'Absent'}}.GetNewClosure();RemoveMatchedProductShortcuts={param($T)};FinalizeReceipt={param($T)$T.phase='Completed';$T.resumePhase='Completed';$T}.GetNewClosure();TestCompletedReceipt={param($T)$true};RemoveResumeProductRegistration={param($T)$resume.Present=$false;$true}.GetNewClosure()};$adapters=Get-CcodInstalledFinalizerAdapters -Adapters $overrides -TransactionRoot $transactionRoot -PayloadRoot $payload -RuntimeRoot $fixture.RuntimeRoot -InstallRoot $install;$validate=$adapters.ValidateSelectedGeneration;$anchor=Join-Path $fixture.RuntimeRoot 'manifest.json'
        $adapters.ValidateSelectedGeneration={param($Root,$Install,$Transaction);$valid=&$validate $Root $Install $Transaction;if(-not$valid){return $false};switch($Mutation){'UnexpectedFile'{$attackState.Path=Join-Path $Root 'unexpected-after-validation.bin';[IO.File]::WriteAllText($attackState.Path,'hostile',[Text.UTF8Encoding]::new($false))}'UnexpectedDirectory'{$attackState.Path=Join-Path $Root 'unexpected-empty-directory';[IO.Directory]::CreateDirectory($attackState.Path)|Out-Null}'Reparse'{$attackState.Path=Join-Path $Root 'unexpected-reparse';New-Item -ItemType Junction -Path $attackState.Path -Target $outside|Out-Null}'Hardlink'{$attackState.Path=Join-Path $Root 'unexpected-hardlink.bin';New-Item -ItemType HardLink -Path $attackState.Path -Target $outsideSentinel|Out-Null}'Ads'{$attackState.Path=$anchor;$attributes=[IO.File]::GetAttributes($anchor);[IO.File]::SetAttributes($anchor,[IO.FileAttributes]::Normal);try{Set-Content -LiteralPath $anchor -Stream 'ccod-evidence' -Value 'hostile' -NoNewline}finally{[IO.File]::SetAttributes($anchor,$attributes)}}'OpenChild'{$attackState.Path=$anchor;$attackState.OpenHandle=[IO.File]::Open($anchor,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)}};return $true}.GetNewClosure()
        $failure=$null;try{Invoke-CcodInstalledUninstallFinalizer -TransactionId $id -RuntimeRoot $fixture.RuntimeRoot -InstallRoot $install -WrapperIdentity ([pscustomobject]@{pid=42;creationTimeUtc='2030-02-03T03:04:05.0000000Z';sessionId=$identity.sessionId;userSid=$identity.userSid}) -Adapters $adapters|Out-Null}catch{$failure=$_}
        $treeComplete=(Test-Path -LiteralPath $fixture.RuntimeRoot -PathType Container);if($treeComplete){foreach($directoryPath in $originalDirectories){if(-not(Test-Path -LiteralPath $directoryPath -PathType Container)){$treeComplete=$false;break}}};if($treeComplete){foreach($fileProof in $originalFiles){if(-not(Test-Path -LiteralPath $fileProof.Path -PathType Leaf)-or[int64](Get-Item -LiteralPath $fileProof.Path -Force).Length-ne$fileProof.Length-or(Get-CcodTestFileSha256 $fileProof.Path)-cne$fileProof.Sha256){$treeComplete=$false;break}}}
        if($null-eq$failure-or-not$treeComplete){throw [Management.Automation.ErrorRecord]::new([InvalidOperationException]::new("pathname reclamation accepted or partially deleted the $Mutation tree"),'CCOD_RECLAMATION_RED_PATHNAME_DELETE',[Management.Automation.ErrorCategory]::InvalidData,$fixture.RuntimeRoot)}
        if(([string]$failure.FullyQualifiedErrorId-split',')[0]-cne'CCOD_GENERATION_RECLAMATION_INVALID'){throw $failure}
        Assert-CcodEqual $outsideHash (Get-CcodTestFileSha256 $outsideSentinel) "$Mutation preserves outside bytes";Assert-CcodEqual $siblingHash (Get-CcodTestFileSha256 $siblingSentinel) "$Mutation preserves sibling generation bytes";Assert-CcodEqual $deviceKeyHash (Get-CcodTestFileSha256 $deviceKey) "$Mutation preserves device-key bytes"
        if($Mutation-ceq'Ads'){Assert-CcodTrue ($null-ne(Get-Item -LiteralPath $attackState.Path -Stream 'ccod-evidence' -ErrorAction SilentlyContinue)) 'ADS hostile object remains after zero deletion'}else{Assert-CcodTrue (Test-Path -LiteralPath $attackState.Path) "$Mutation hostile object remains after zero deletion"}
        if($null-ne$attackState.OpenHandle){$attackState.OpenHandle.Dispose();$attackState.OpenHandle=$null}
    }finally{[Environment]::SetEnvironmentVariable('LOCALAPPDATA',$previous,'Process');if([IO.Directory]::Exists($local)){Remove-CcodTestOwnedTree -Path $local}}
}

# Production mutation caught: validation and deletion must remain bound across every hostile
# namespace/object change, including an already-open manifest child.
foreach($reclamationMutation in @('UnexpectedFile','UnexpectedDirectory','Reparse','Hardlink','Ads','OpenChild')){
    if(-not[string]::IsNullOrWhiteSpace($env:CCOD_RECLAMATION_RED_CASE)-and$env:CCOD_RECLAMATION_RED_CASE-cne$reclamationMutation){continue}
    $caseName=$reclamationMutation
    $results += Invoke-CcodTest "installed finalizer rejects post-validation $caseName without deleting any generation state" {Invoke-CcodInstalledReclamationMutationCase -Mutation $caseName}
}

function Get-CcodGenerationReclamationTreeProof {
    param([Parameter(Mandatory)][string]$Root)
    [pscustomobject]@{
        Root=[IO.Path]::GetFullPath($Root)
        Directories=@(Get-ChildItem -LiteralPath $Root -Directory -Recurse -Force|ForEach-Object FullName)
        Files=@(Get-ChildItem -LiteralPath $Root -File -Recurse -Force|ForEach-Object{[pscustomobject]@{Path=$_.FullName;Length=[int64]$_.Length;Sha256=Get-CcodTestFileSha256 $_.FullName}})
    }
}

function Assert-CcodGenerationReclamationTreeProof {
    param([Parameter(Mandatory)]$Proof,[Parameter(Mandatory)][string]$Message)
    Assert-CcodTrue (Test-Path -LiteralPath $Proof.Root -PathType Container) "$Message root"
    foreach($path in @($Proof.Directories)){Assert-CcodTrue (Test-Path -LiteralPath $path -PathType Container) "$Message directory $path"}
    foreach($file in @($Proof.Files)){Assert-CcodTrue (Test-Path -LiteralPath $file.Path -PathType Leaf) "$Message file $($file.Path)";Assert-CcodEqual $file.Length ([int64](Get-Item -LiteralPath $file.Path -Force).Length) "$Message length $($file.Path)";Assert-CcodEqual $file.Sha256 (Get-CcodTestFileSha256 $file.Path) "$Message hash $($file.Path)"}
}

if([string]::IsNullOrWhiteSpace($env:CCOD_RECLAMATION_RED_CASE)-or$env:CCOD_RECLAMATION_RED_CASE-ceq'IdentityChange'){
    $results += Invoke-CcodTest 'generation reclamation pins the selected identity before the final pre-delete hook' {
        $modulePath=Join-Path $repositoryRoot 'src\persistence\modules\GenerationReclamation.psm1';if(-not(Test-Path -LiteralPath $modulePath -PathType Leaf)){throw [Management.Automation.ErrorRecord]::new([InvalidOperationException]::new('generation reclamation module is missing'),'CCOD_RECLAMATION_RED_MODULE_MISSING',[Management.Automation.ErrorCategory]::ObjectNotFound,$modulePath)};$module=Import-Module $modulePath -Force -PassThru -DisableNameChecking
        $local=New-CcodUninstallBootstrapTestRoot ('ccod-reclamation-identity-'+[guid]::NewGuid().ToString('N'))
        try{
            $install=Join-Path $local 'install';$fixture=New-CcodVerifiedUninstallRuntimeFixture -InstallRoot $install -AppendOnly;$proof=Get-CcodGenerationReclamationTreeProof $fixture.RuntimeRoot;$manifest=Get-CcodTestFileSha256 (Join-Path $fixture.RuntimeRoot 'manifest.json')
            $replacement=Join-Path $local 'replacement-generation';Copy-Item -LiteralPath $fixture.RuntimeRoot -Destination $replacement -Recurse -Force;$replacementProof=Get-CcodGenerationReclamationTreeProof $replacement;$parked=Join-Path $local 'original-generation';$attack=[pscustomobject]@{Result=$null}
            $hook={try{[IO.Directory]::Move($fixture.RuntimeRoot,$parked);[IO.Directory]::Move($replacement,$fixture.RuntimeRoot);$attack.Result='exchanged'}catch [IO.IOException]{$attack.Result='blocked'}catch [UnauthorizedAccessException]{$attack.Result='blocked'};throw [InvalidOperationException]::new('identity replacement probe')}.GetNewClosure()
            &$module {param($Value)$script:CcodGenerationReclamationBeforeArmForTest=$Value} $hook
            try{Assert-CcodThrows {Remove-CcodVerifiedGenerationTree -InstallRoot $install -RuntimeRoot $fixture.RuntimeRoot -RuntimeId $fixture.RuntimeId -ExpectedManifestSha256 $manifest|Out-Null} 'CCOD_GENERATION_RECLAMATION_INVALID'}finally{&$module {$script:CcodGenerationReclamationBeforeArmForTest=$null}}
            Assert-CcodEqual 'blocked' $attack.Result 'pinned selected root rejects identity replacement';Assert-CcodGenerationReclamationTreeProof $proof 'identity replacement failure preserves selected tree';Assert-CcodGenerationReclamationTreeProof $replacementProof 'identity replacement failure preserves outside replacement tree';Assert-CcodTrue (-not(Test-Path -LiteralPath $parked)) 'identity replacement creates no renamed selected alias'
        }finally{if([IO.Directory]::Exists($local)){Remove-CcodTestOwnedTree -Path $local}}
    }
}

if([string]::IsNullOrWhiteSpace($env:CCOD_RECLAMATION_RED_CASE)-or$env:CCOD_RECLAMATION_RED_CASE-ceq'MarkFailure'){
    $results += Invoke-CcodTest 'file-arm failure disarms every held identity validates the complete tree and permits an exact retry' {
        $modulePath=Join-Path $repositoryRoot 'src\persistence\modules\GenerationReclamation.psm1';if(-not(Test-Path -LiteralPath $modulePath -PathType Leaf)){throw [Management.Automation.ErrorRecord]::new([InvalidOperationException]::new('generation reclamation module is missing'),'CCOD_RECLAMATION_RED_MODULE_MISSING',[Management.Automation.ErrorCategory]::ObjectNotFound,$modulePath)};$module=Import-Module $modulePath -Force -PassThru -DisableNameChecking
        $local=New-CcodUninstallBootstrapTestRoot ('ccod-reclamation-disarm-'+[guid]::NewGuid().ToString('N'))
        try{
            $install=Join-Path $local 'install';$fixture=New-CcodVerifiedUninstallRuntimeFixture -InstallRoot $install -AppendOnly;$proof=Get-CcodGenerationReclamationTreeProof $fixture.RuntimeRoot;$manifest=Get-CcodTestFileSha256 (Join-Path $fixture.RuntimeRoot 'manifest.json');$sibling=Join-Path $install 'runtime\sibling';[IO.Directory]::CreateDirectory($sibling)|Out-Null;$siblingFile=Join-Path $sibling 'sentinel.bin';[IO.File]::WriteAllText($siblingFile,'sibling',[Text.UTF8Encoding]::new($false));$siblingHash=Get-CcodTestFileSha256 $siblingFile;$deviceKey=Join-Path $install 'state\device-key\private.bin';[IO.Directory]::CreateDirectory((Split-Path $deviceKey -Parent))|Out-Null;[IO.File]::WriteAllText($deviceKey,'device-key',[Text.UTF8Encoding]::new($false));$deviceKeyHash=Get-CcodTestFileSha256 $deviceKey
            &$module {$script:CcodGenerationReclamationFailFileArmAtForTest=2}
            try{Assert-CcodThrows {Remove-CcodVerifiedGenerationTree -InstallRoot $install -RuntimeRoot $fixture.RuntimeRoot -RuntimeId $fixture.RuntimeId -ExpectedManifestSha256 $manifest|Out-Null} 'CCOD_GENERATION_RECLAMATION_INVALID'}finally{&$module {$script:CcodGenerationReclamationFailFileArmAtForTest=-1}}
            Assert-CcodGenerationReclamationTreeProof $proof 'file-arm rollback preserves the complete selected tree';Assert-CcodEqual $siblingHash (Get-CcodTestFileSha256 $siblingFile) 'file-arm rollback preserves sibling';Assert-CcodEqual $deviceKeyHash (Get-CcodTestFileSha256 $deviceKey) 'file-arm rollback preserves device-key state'
            $result=Remove-CcodVerifiedGenerationTree -InstallRoot $install -RuntimeRoot $fixture.RuntimeRoot -RuntimeId $fixture.RuntimeId -ExpectedManifestSha256 $manifest;Assert-CcodEqual 'Completed' $result.phase 'successful retry reaches terminal reclamation phase';Assert-CcodEqual 'Reclaimed' $result.result 'successful retry reports exact reclamation';Assert-CcodTrue (-not(Test-Path -LiteralPath $fixture.RuntimeRoot)) 'successful retry removes only selected generation';Assert-CcodEqual $siblingHash (Get-CcodTestFileSha256 $siblingFile) 'successful retry preserves sibling';Assert-CcodEqual $deviceKeyHash (Get-CcodTestFileSha256 $deviceKey) 'successful retry preserves device-key state';Assert-CcodTrue (Test-Path -LiteralPath $install -PathType Container) 'successful retry preserves install root'
        }finally{if([IO.Directory]::Exists($local)){Remove-CcodTestOwnedTree -Path $local}}
    }
}

if([string]::IsNullOrWhiteSpace($env:CCOD_RECLAMATION_RED_CASE)-or$env:CCOD_RECLAMATION_RED_CASE-ceq'CommitFailure'){
    $results += Invoke-CcodTest 'irreversible reclamation failure reports CommitStarted and never touches sibling or lifecycle state' {
        $modulePath=Join-Path $repositoryRoot 'src\persistence\modules\GenerationReclamation.psm1';$module=Import-Module $modulePath -Force -PassThru -DisableNameChecking;$local=New-CcodUninstallBootstrapTestRoot ('ccod-reclamation-commit-failure-'+[guid]::NewGuid().ToString('N'))
        try{
            $install=Join-Path $local 'install';$fixture=New-CcodVerifiedUninstallRuntimeFixture -InstallRoot $install -AppendOnly;$proof=Get-CcodGenerationReclamationTreeProof $fixture.RuntimeRoot;$manifest=Get-CcodTestFileSha256 (Join-Path $fixture.RuntimeRoot 'manifest.json');$outside=Join-Path $local 'outside';[IO.Directory]::CreateDirectory($outside)|Out-Null;$outsideFile=Join-Path $outside 'sentinel.bin';[IO.File]::WriteAllText($outsideFile,'outside',[Text.UTF8Encoding]::new($false));$outsideHash=Get-CcodTestFileSha256 $outsideFile;$sibling=Join-Path $install 'runtime\sibling';[IO.Directory]::CreateDirectory($sibling)|Out-Null;$siblingFile=Join-Path $sibling 'sentinel.bin';[IO.File]::WriteAllText($siblingFile,'sibling',[Text.UTF8Encoding]::new($false));$siblingHash=Get-CcodTestFileSha256 $siblingFile;$deviceKey=Join-Path $install 'state\device-key\private.bin';[IO.Directory]::CreateDirectory((Split-Path $deviceKey -Parent))|Out-Null;[IO.File]::WriteAllText($deviceKey,'device-key',[Text.UTF8Encoding]::new($false));$deviceKeyHash=Get-CcodTestFileSha256 $deviceKey
            &$module {param($Index)$script:CcodGenerationReclamationFailCommitAtForTest=$Index} ($proof.Files.Count+1)
            try{Assert-CcodThrows {Remove-CcodVerifiedGenerationTree -InstallRoot $install -RuntimeRoot $fixture.RuntimeRoot -RuntimeId $fixture.RuntimeId -ExpectedManifestSha256 $manifest|Out-Null} 'CCOD_GENERATION_RECLAMATION_COMMIT_FAILED'}finally{&$module {$script:CcodGenerationReclamationFailCommitAtForTest=-1}}
            Assert-CcodTrue (Test-Path -LiteralPath $fixture.RuntimeRoot -PathType Container) 'CommitStarted failure retains a selected-root failure boundary';Assert-CcodEqual $outsideHash (Get-CcodTestFileSha256 $outsideFile) 'CommitStarted failure preserves outside';Assert-CcodEqual $siblingHash (Get-CcodTestFileSha256 $siblingFile) 'CommitStarted failure preserves sibling';Assert-CcodEqual $deviceKeyHash (Get-CcodTestFileSha256 $deviceKey) 'CommitStarted failure preserves lifecycle/device-key state';Assert-CcodTrue (Test-Path -LiteralPath $install -PathType Container) 'CommitStarted failure preserves install root'
        }finally{if([IO.Directory]::Exists($local)){Remove-CcodTestOwnedTree -Path $local}}

        $tx=New-CcodUninstallBootstrapTestTransaction -Phase 'TaskRemoved';$tx.installedBinding=New-CcodUninstallBootstrapTestInstalledBinding;$world=[pscustomobject]@{Calls=[Collections.Generic.List[string]]::new();Transaction=$tx;RootPresent=$true;PublicEntry=$false;PublicCommand=$null;ShortcutsPresent=$true;CompletedReceipt=$false;Failure=$null;FailureInjected=$false;EntryPresentAtReclaim=$false};$adapters=New-CcodInstalledFinalizerMemoryAdapters $world;$adapters.ReclaimSelectedGeneration={param($Runtime,$Transaction)$world.Calls.Add('Reclaim');throw [Management.Automation.ErrorRecord]::new([IO.IOException]::new('commit failed'),'CCOD_GENERATION_RECLAMATION_COMMIT_FAILED',[Management.Automation.ErrorCategory]::WriteError,$Runtime)}.GetNewClosure()
        Assert-CcodThrows {Invoke-CcodInstalledUninstallFinalizer -TransactionId $tx.transactionId -RuntimeRoot $tx.installedBinding.selectedRuntimeRoot -InstallRoot 'C:\install' -WrapperIdentity ([pscustomobject]@{pid=42;creationTimeUtc='2030-02-03T03:04:05.0000000Z';sessionId=1;userSid='S-1-5-21-111-222-333-1001'}) -Adapters $adapters|Out-Null} 'CCOD_GENERATION_RECLAMATION_COMMIT_FAILED';Assert-CcodEqual 0 @($world.Calls|Where-Object{$_-in@('Write:ReadyForInno','ProductShortcuts','FinalizeReceipt','RemoveRegistry')}).Count 'CommitStarted failure reaches no phase write product removal or completion receipt'
    }
}

function Invoke-CcodDefaultInstalledFinalizerNegative {
    param([Parameter(Mandatory)][ValidateSet('Sibling','WrongPath','StaleEpoch','WrapperIdentity','WrongReadyRoot','ExtraReadyField','PayloadHash')][string]$Mutation)
    $local=New-CcodUninstallBootstrapTestRoot ('ccod-finalizer-negative-'+[guid]::NewGuid().ToString('N'));$previous=[Environment]::GetEnvironmentVariable('LOCALAPPDATA','Process');$wrapper=$null
    try{
        [Environment]::SetEnvironmentVariable('LOCALAPPDATA',$local,'Process');$install=Join-Path $local 'CodexControlOtherDevices';$fixture=New-CcodVerifiedUninstallRuntimeFixture -InstallRoot $install -AppendOnly;$selected=$fixture.RuntimeRoot;$runtime=$selected
        if($Mutation-ceq'Sibling'){$runtime=Join-Path $install 'runtime\same-bootstrap-sibling';Copy-Item -LiteralPath $selected -Destination $runtime -Recurse -Force}
        elseif($Mutation-ceq'WrongPath'){$runtime=Join-Path $selected 'nested-wrong-runtime'}
        $identity=Get-CcodUninstallBootstrapCurrentIdentity;$id=[guid]::NewGuid().ToString('D');$transactionRoot=Get-CcodUninstallBootstrapDefaultTransactionRoot;$directory=New-CcodUninstallBootstrapTransactionDirectory -TransactionRoot $transactionRoot -TransactionId $id -UserSid $identity.userSid
        $wrapper=Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-Command','Start-Sleep -Milliseconds 5000') -WindowStyle Hidden -PassThru;$wrapperCreation=$wrapper.StartTime.ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture)
        $payload=Join-Path $directory 'payload';$recordMap=@{};foreach($relative in $script:CcodUninstallPayloadEntries){$source=Join-Path $selected $relative.Replace('/','\');$destination=Join-Path $payload $relative.Replace('/','\');[IO.Directory]::CreateDirectory((Split-Path $destination -Parent))|Out-Null;[IO.File]::Copy($source,$destination,$true);$recordMap[$relative]=Get-CcodUninstallBootstrapFileFingerprint $source};$payloadRecords=New-CcodUninstallBootstrapPayloadRecords -RecordMap $recordMap
        $tx=New-CcodUninstallBootstrapTestTransaction -Phase 'TaskRemoved';$tx.transactionId=$id;$tx.runtimeId=[IO.Path]::GetFileName($runtime);$tx.runtimeGeneration=[uint64]7;$tx.leaseEpoch=if($Mutation-ceq'StaleEpoch'){[uint64]12}else{[uint64]11};$tx.userSid=$identity.userSid;$tx.sessionId=$identity.sessionId;$tx.readyEvidence.installRoot=$install;$tx.readyEvidence.runtimeId=$tx.runtimeId;$tx.readyEvidence.runtimeGeneration=[uint64]7;$manifest=(Get-FileHash (Join-Path $selected 'manifest.json') -Algorithm SHA256).Hash.ToLowerInvariant();$tx.readyEvidence.manifestSha256=$manifest;$tx.installedBinding=New-CcodUninstallBootstrapTestInstalledBinding -TransactionId $id -RuntimeRoot $runtime -InstallRoot $install -UserSid $identity.userSid -SessionId $identity.sessionId -WrapperPid $wrapper.Id -WrapperCreationTimeUtc $wrapperCreation -PayloadRecords $payloadRecords -TransactionDirectory $directory -RuntimeManifestSha256 $manifest
        Write-CcodUninstallBootstrapStoredTransaction -TransactionDirectory $directory -Transaction $tx;Publish-CcodUninstallBootstrapCurrentTransaction -TransactionRoot $transactionRoot -TransactionId $id -UserSid $identity.userSid
        if($Mutation-ceq'WrongReadyRoot'){$tx.readyEvidence.installRoot=Join-Path $local 'unrelated-root';[IO.File]::WriteAllText((Join-Path $directory 'transaction.json'),($tx|ConvertTo-Json -Depth 12 -Compress),[Text.UTF8Encoding]::new($false))}
        elseif($Mutation-ceq'ExtraReadyField'){$tx.readyEvidence|Add-Member -NotePropertyName unexpectedReadyField -NotePropertyValue 'reject';[IO.File]::WriteAllText((Join-Path $directory 'transaction.json'),($tx|ConvertTo-Json -Depth 12 -Compress),[Text.UTF8Encoding]::new($false))}
        elseif($Mutation-ceq'PayloadHash'){[IO.File]::AppendAllText((Join-Path $payload 'src\persistence\modules\ProductRegistration.psm1'),'# changed after staging',[Text.UTF8Encoding]::new($false))}
        $creationArgument=if($Mutation-ceq'WrapperIdentity'){'2001-02-03T04:05:06.0000000Z'}else{$wrapperCreation};$previousPreference=$ErrorActionPreference;try{$ErrorActionPreference='Continue';$output=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $payload 'src\persistence\InstalledUninstallFinalizer.ps1') -TransactionId $id -RuntimeRoot $runtime -InstallRoot $install -WrapperProcessId $wrapper.Id -WrapperCreationTimeUtc $creationArgument 2>&1;$exit=$LASTEXITCODE}finally{$ErrorActionPreference=$previousPreference}
        if($exit-ne3){throw("FINALIZER_DIAGNOSTIC mutation={0} exit={1} output={2}"-f$Mutation,$exit,(@($output)-join' | '))};Assert-CcodEqual 3 $exit "$Mutation default child rejects before finalization";Assert-CcodTrue (Test-Path -LiteralPath $selected -PathType Container) "$Mutation preserves the selected generation";Assert-CcodTrue (Test-Path -LiteralPath (Join-Path $install 'state') -PathType Container) "$Mutation preserves sibling/root state"

    }finally{if($null-ne$wrapper){try{if(-not$wrapper.HasExited){$wrapper.Kill();$wrapper.WaitForExit()}}catch{};$wrapper.Dispose()};[Environment]::SetEnvironmentVariable('LOCALAPPDATA',$previous,'Process');if([IO.Directory]::Exists($local)){Remove-CcodTestOwnedTree -Path $local}}
}

$results += Invoke-CcodTest 'default staged installed finalizer child rejects the full negative authorization matrix without deletion' {
    foreach($mutation in @('Sibling','WrongPath','StaleEpoch','WrapperIdentity','WrongReadyRoot','ExtraReadyField','PayloadHash')){Invoke-CcodDefaultInstalledFinalizerNegative -Mutation $mutation}
}

$results | ForEach-Object { "PASS $($_.Name)" }
Write-Output "Uninstall bootstrap self-tests passed: $($results.Count)"
