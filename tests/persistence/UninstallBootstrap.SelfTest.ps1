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

function New-CcodUninstallBootstrapContext {
    return [pscustomobject][ordered]@{
        runtimeId = '2.5.0-uninstall-test'
        runtimeGeneration = [uint64]7
        leaseEpoch = [uint64]11
        userSid = 'S-1-5-21-111-222-333-1001'
        sessionId = 1
        readyEvidence = [pscustomobject][ordered]@{phase='Ready';installRoot='C:\install';runtimeId='2.5.0-uninstall-test';runtimeGeneration=[uint64]7;packageSha256=('0'*64);manifestSha256=('a'*64);startMenuSha256=('0'*64);desktopSha256=('0'*64);targetPath=$canonicalTaskTarget;arguments='/Run /TN "Codex Control Other Devices Supervisor"'}
        payloadRecords = New-CcodUninstallBootstrapPayloadRecords -ResumeOnly
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
                payloadRecords = New-CcodUninstallBootstrapPayloadRecords -ResumeOnly
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
    param([Parameter(Mandatory)][string]$InstallRoot,[switch]$AppendOnly)
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
    $manifest = New-CcodRuntimeManifest -RuntimeDirectory $runtimeRoot -ProjectVersion '2.5.0-uninstall-test'
    $finalRuntime = Join-Path $InstallRoot ('runtime\' + $manifest.runtimeId)
    [IO.Directory]::Move($runtimeRoot,$finalRuntime)
    [IO.File]::WriteAllText((Join-Path $finalRuntime 'manifest.json'),($manifest | ConvertTo-Json -Depth 16),[Text.UTF8Encoding]::new($false))
    [IO.Directory]::CreateDirectory((Join-Path $InstallRoot 'state')) | Out-Null
    Set-CcodUninstallBootstrapFixtureDirectoryOwner -Path $InstallRoot
    $timestamp = '2030-02-03T03:04:05.0000000Z'
    if($AppendOnly){$pointerRoot=Join-Path $InstallRoot 'state\active-generation';[IO.Directory]::CreateDirectory($pointerRoot)|Out-Null;for($generation=1;$generation-le7;$generation++){[IO.File]::WriteAllText((Join-Path $pointerRoot ('{0:D20}.json'-f$generation)),([ordered]@{schemaVersion=1;generation=[uint64]$generation;activeRuntime=$manifest.runtimeId;previousGeneration=[uint64]($generation-1)}|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))}}
    else{[IO.File]::WriteAllText((Join-Path $InstallRoot 'active.json'),([ordered]@{schemaVersion=2;activeRuntime=$manifest.runtimeId;previousRuntime=$null;generation=[uint64]7;updatedAtUtc=$timestamp}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))}
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
        Assert-CcodEqual 17 @($context.payloadRecords).Count 'only the cleanup entry, two bounded finalizers, bounded reclamation, matched registration module, and imported modules are staged'
        [IO.File]::AppendAllText((Join-Path $fixture.RuntimeRoot 'src\persistence\modules\InstallLifecycle.psm1'),'# altered',[Text.UTF8Encoding]::new($false))
        Assert-CcodThrows { Get-CcodUninstallBootstrapVerifiedRuntimeContext -InstallerRoot $repositoryRoot -InstallRoot $installRoot | Out-Null } 'CCOD_UNINSTALL_RUNTIME_INVALID'
    } finally {
        [Environment]::SetEnvironmentVariable('LOCALAPPDATA',$previousLocalAppData,'Process')
        if (Test-Path -LiteralPath $localAppData) { Remove-Item -LiteralPath $localAppData -Recurse -Force }
    }
}

$results += Invoke-CcodTest 'production uninstall authorization consumes append-only selector before legacy active json' {
    $localAppData=Join-Path ([IO.Path]::GetTempPath()) ('ccod-uninstall-append-'+[guid]::NewGuid().ToString('N'));$installRoot=Join-Path $localAppData 'CodexControlOtherDevices';$previous=[Environment]::GetEnvironmentVariable('LOCALAPPDATA','Process')
    try{[Environment]::SetEnvironmentVariable('LOCALAPPDATA',$localAppData,'Process');$fixture=New-CcodVerifiedUninstallRuntimeFixture -InstallRoot $installRoot -AppendOnly;$context=Get-CcodUninstallBootstrapVerifiedRuntimeContext -InstallerRoot $repositoryRoot -InstallRoot $installRoot;Assert-CcodEqual $fixture.RuntimeId $context.runtimeId 'uninstall context binds append-only active runtime';Assert-CcodEqual 7 ([uint64]$context.runtimeGeneration) 'uninstall context binds latest append-only generation';Assert-CcodEqual $false (Test-Path -LiteralPath (Join-Path $installRoot 'active.json')) 'append-only uninstall authorization needs no legacy pointer'}finally{[Environment]::SetEnvironmentVariable('LOCALAPPDATA',$previous,'Process');if(Test-Path $localAppData){Remove-Item $localAppData -Recurse -Force}}
}

$results += Invoke-CcodTest 'uninstall legacy fallback accepts a valid pointer when the entire state plane is absent' {
    $local=Join-Path ([IO.Path]::GetTempPath()) ('ccod-uninstall-no-state-'+[guid]::NewGuid().ToString('N'));$install=Join-Path $local 'CodexControlOtherDevices';$previous=[Environment]::GetEnvironmentVariable('LOCALAPPDATA','Process')
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
    }finally{[Environment]::SetEnvironmentVariable('LOCALAPPDATA',$previous,'Process');if(Test-Path $local){Remove-Item $local -Recurse -Force}}
}

$results += Invoke-CcodTest 'uninstall append-only authorization rejects unsafe roots leaves JSON and generations' {
    $previous=[Environment]::GetEnvironmentVariable('LOCALAPPDATA','Process')
    try{foreach($kind in @('root-file','root-reparse','leaf-reparse','ads','multilink','malformed','schema','duplicate','fractional','noncanonical')){$local=Join-Path ([IO.Path]::GetTempPath()) ("ccod-uninstall-hostile-$kind-"+[guid]::NewGuid().ToString('N'));$install=Join-Path $local 'CodexControlOtherDevices';[Environment]::SetEnvironmentVariable('LOCALAPPDATA',$local,'Process');$fixture=New-CcodVerifiedUninstallRuntimeFixture -InstallRoot $install -AppendOnly;$pointerRoot=Join-Path $install 'state\active-generation';$leaf=Join-Path $pointerRoot '00000000000000000007.json';$target=Join-Path $install ("target-$kind");if($kind-ceq'root-file'){Remove-Item $pointerRoot -Recurse -Force;[IO.File]::WriteAllText($pointerRoot,'x',[Text.UTF8Encoding]::new($false))}elseif($kind-ceq'root-reparse'){Remove-Item $pointerRoot -Recurse -Force;[IO.Directory]::CreateDirectory($target)|Out-Null;New-Item -ItemType Junction -Path $pointerRoot -Target $target|Out-Null}elseif($kind-ceq'leaf-reparse'){[IO.File]::Delete($leaf);[IO.Directory]::CreateDirectory($target)|Out-Null;New-Item -ItemType Junction -Path $leaf -Target $target|Out-Null}elseif($kind-ceq'ads'){Set-Content -LiteralPath $leaf -Stream evidence -Value x -NoNewline}elseif($kind-ceq'multilink'){$text=[IO.File]::ReadAllText($leaf);[IO.File]::Delete($leaf);$outside=Join-Path $install 'outside-pointer.json';[IO.File]::WriteAllText($outside,$text,[Text.UTF8Encoding]::new($false));New-Item -ItemType HardLink -Path $leaf -Target $outside|Out-Null}elseif($kind-ceq'malformed'){[IO.File]::WriteAllText($leaf,'{',[Text.UTF8Encoding]::new($false))}elseif($kind-ceq'schema'){$id=$fixture.RuntimeId;[IO.File]::WriteAllText($leaf,('{"schemaVersion":2,"generation":7,"activeRuntime":"'+$id+'","previousGeneration":6}'),[Text.UTF8Encoding]::new($false))}elseif($kind-ceq'duplicate'){$id=$fixture.RuntimeId;[IO.File]::WriteAllText($leaf,('{"schemaVersion":1,"schemaVersion":1,"generation":7,"activeRuntime":"'+$id+'","previousGeneration":6}'),[Text.UTF8Encoding]::new($false))}elseif($kind-ceq'fractional'){$id=$fixture.RuntimeId;[IO.File]::WriteAllText($leaf,('{"schemaVersion":1,"generation":7.5,"activeRuntime":"'+$id+'","previousGeneration":6}'),[Text.UTF8Encoding]::new($false))}else{Move-Item $leaf (Join-Path $pointerRoot '00000000000000000008.json')};Assert-CcodThrows {Get-CcodUninstallBootstrapVerifiedRuntimeContext -InstallerRoot $repositoryRoot -InstallRoot $install|Out-Null} 'CCOD_UNINSTALL_RUNTIME_INVALID';if(Test-Path $local){Remove-Item $local -Recurse -Force}}}finally{[Environment]::SetEnvironmentVariable('LOCALAPPDATA',$previous,'Process')}
}

$results += Invoke-CcodTest 'uninstall selector fallback requires proven ItemNotFound instead of a lookup error' {
    $local=Join-Path ([IO.Path]::GetTempPath()) ('ccod-uninstall-lookup-'+[guid]::NewGuid().ToString('N'));$install=Join-Path $local 'CodexControlOtherDevices';$previous=[Environment]::GetEnvironmentVariable('LOCALAPPDATA','Process')
    try{[Environment]::SetEnvironmentVariable('LOCALAPPDATA',$local,'Process');New-CcodVerifiedUninstallRuntimeFixture -InstallRoot $install|Out-Null;Assert-CcodThrows {Get-CcodUninstallBootstrapVerifiedRuntimeContext -InstallerRoot $repositoryRoot -InstallRoot $install -SelectorAdapters @{GetSelectorRootItem={param($Path)throw [UnauthorizedAccessException]::new('selector lookup denied')}}|Out-Null} 'CCOD_UNINSTALL_RUNTIME_INVALID'}finally{[Environment]::SetEnvironmentVariable('LOCALAPPDATA',$previous,'Process');if(Test-Path $local){Remove-Item $local -Recurse -Force}}
}

$results += Invoke-CcodTest 'uninstall legacy fallback rejects a state ancestor file at the selector boundary' {
    $local=Join-Path ([IO.Path]::GetTempPath()) ('ccod-uninstall-state-file-'+[guid]::NewGuid().ToString('N'));$install=Join-Path $local 'CodexControlOtherDevices';$previous=[Environment]::GetEnvironmentVariable('LOCALAPPDATA','Process')
    try{
        [Environment]::SetEnvironmentVariable('LOCALAPPDATA',$local,'Process');New-CcodVerifiedUninstallRuntimeFixture -InstallRoot $install|Out-Null
        $state=Join-Path $install 'state';Remove-Item -LiteralPath $state -Recurse -Force;[IO.File]::WriteAllText($state,'not-a-directory',[Text.UTF8Encoding]::new($false))
        $failure=$null;try{Get-CcodUninstallBootstrapVerifiedRuntimeContext -InstallerRoot $repositoryRoot -InstallRoot $install|Out-Null}catch{$failure=$_}
        Assert-CcodTrue ($null-ne$failure-and$failure.FullyQualifiedErrorId-like'CCOD_UNINSTALL_RUNTIME_INVALID*') 'state ancestor file fails uninstall authorization'
        Assert-CcodTrue ($failure.Exception.Message-like'*selector*') 'state ancestor file is rejected at the selector boundary'
    }finally{[Environment]::SetEnvironmentVariable('LOCALAPPDATA',$previous,'Process');if(Test-Path $local){Remove-Item $local -Recurse -Force}}
}

$results += Invoke-CcodTest 'external staging refuses a cleanup source changed after runtime verification' {
    $localAppData = Join-Path ([IO.Path]::GetTempPath()) ('ccod-uninstall-race-' + [guid]::NewGuid().ToString('N'))
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
    Assert-CcodEqual 'Validate,GetRoot,Read,Cleanup,Write:ReadyForInno,RemoveProduct,Receipt:ReadyForInno' ($world.Calls -join ',') 'resume reuses the durable transaction and never makes a second payload'
}

$results += Invoke-CcodTest 'Prepare resumes a TaskRemoved transaction even after the runtime root and active pointer have been deleted' {
    $localAppData = Join-Path ([IO.Path]::GetTempPath()) ('ccod-uninstall-resume-' + [guid]::NewGuid().ToString('N'))
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

# Production mutation caught: deleting the selected generation while its public wrapper is still executing from it.
$results += Invoke-CcodTest 'installed Prepare stops at TaskRemoved and external finalizer completes only after wrapper exit' {
    $world=[pscustomobject]@{Calls=[Collections.Generic.List[string]]::new();Transaction=$null;Receipt=$null;ValidationError=$false;StageError=$false;CleanupError=$false;CleanupFailurePhase=$null;InstallRootAbsent=$false;StagedEntries=@();ProductRegistrationRemovals=0}
    $adapters=New-CcodUninstallBootstrapAdapters $world
    $originalCleanup=$adapters.RunCleanup
    $adapters.RunCleanup={param($InstallerRoot,$InstallRoot,$TransactionRoot,$Transaction,$WriteTransaction,$Mode);$world.Calls.Add("Cleanup:$Mode");$Transaction.phase='TaskRemoved';$Transaction.resumePhase='TaskRemoved';&$WriteTransaction $TransactionRoot $Transaction;$Transaction}.GetNewClosure()
    $adapters.GetInstalledBinding={param($InstallerRoot,$InstallRoot,$Context,$WrapperIdentity)[pscustomobject]@{selectedRuntimeRoot='C:\install\runtime\2.5.0-uninstall-test';runtimeManifestSha256=('a'*64);wrapperPid=42;wrapperCreationTimeUtc='2030-02-03T03:04:05.0000000Z';wrapperSessionId=1;wrapperUserSid='S-1-5-21-111-222-333-1001'}}
    $wrapperIdentity=[pscustomobject]@{pid=42;creationTimeUtc='2030-02-03T03:04:05.0000000Z';sessionId=1;userSid='S-1-5-21-111-222-333-1001'}
    $prepared=Invoke-CcodUninstallBootstrap -InstallerRoot 'C:\runtime' -InstallRoot 'C:\install' -Mode PrepareInstalled -WrapperIdentity $wrapperIdentity -Adapters $adapters
    Assert-CcodEqual 'TaskRemoved' $prepared.phase 'installed wrapper retains application state until it exits'
    Assert-CcodEqual 0 $world.ProductRegistrationRemovals 'installed Prepare removes no product state before the external finalizer'

    $final=[pscustomobject]@{Calls=[Collections.Generic.List[string]]::new();WrapperExited=$true;ContextValid=$true;Transaction=$prepared;RootAbsent=$false;Finalized=$false;Deletes=0}
    $finalAdapters=@{
        WaitWrapperExit={param($Identity,$Timeout)$final.Calls.Add('WaitWrapper');[pscustomobject]@{verifiedAtStart=$true;exited=$final.WrapperExited}}.GetNewClosure()
        ReadPreparedTransaction={param($Id)$final.Calls.Add('ReadTransaction');$final.Transaction}.GetNewClosure()
        ValidateSelectedGeneration={param($RuntimeRoot,$InstallRoot,$Transaction)$final.Calls.Add('ValidateGeneration');$final.ContextValid}.GetNewClosure()
        ReadCurrentEpoch={param($InstallRoot)[uint64]11}
        RemoveSelectedGeneration={param($RuntimeRoot,$Transaction)$final.Calls.Add('RemoveSelected');$final.Deletes++;$final.RootAbsent=$true;$Transaction.phase='ReadyForInno';$Transaction.resumePhase='ReadyForInno';$Transaction}.GetNewClosure()
        TestSelectedRootAbsent={param($Root)$final.Calls.Add('RootAbsent');$final.RootAbsent}.GetNewClosure()
        RemoveMatchedProductRegistration={param($Transaction)$final.Calls.Add('RemoveProduct')}.GetNewClosure()
        FinalizeReceipt={param($Transaction)$final.Calls.Add('Finalize');$final.Finalized=$true;[pscustomobject]@{phase='Completed'}}.GetNewClosure()
    }
    $receipt=Invoke-CcodInstalledUninstallFinalizer -TransactionId $prepared.transactionId -RuntimeRoot 'C:\install\runtime\2.5.0-uninstall-test' -InstallRoot 'C:\install' -WrapperIdentity $wrapperIdentity -Adapters $finalAdapters
    Assert-CcodEqual 'Completed' $receipt.phase 'external finalizer reaches the completion receipt'
    Assert-CcodEqual 'WaitWrapper,ReadTransaction,ValidateGeneration,RemoveSelected,RootAbsent,RemoveProduct,Finalize' ($final.Calls -join ',') 'wrapper exit and selected generation proof precede selected-root removal and finalization'
}

# Production mutation caught: treating any durable transaction/path/process as authority to delete application state.
$results += Invoke-CcodTest 'installed finalizer wrong wrapper generation path or transaction performs no deletion' {
    foreach($kind in @('Wrapper','Generation','Transaction','Epoch','Sibling')){
        $world=[pscustomobject]@{Calls=[Collections.Generic.List[string]]::new();Deletes=0}
        $transaction=New-CcodUninstallBootstrapTestTransaction -Phase 'TaskRemoved'
        $transaction.installedBinding=[pscustomobject][ordered]@{selectedRuntimeRoot=$(if($kind-ceq'Sibling'){'C:\install\runtime\sibling'}else{'C:\install\runtime\2.5.0-uninstall-test'});runtimeManifestSha256=('a'*64);wrapperPid=42;wrapperCreationTimeUtc='2030-02-03T03:04:05.0000000Z';wrapperSessionId=1;wrapperUserSid='S-1-5-21-111-222-333-1001'}
        if($kind-ceq'Transaction'){$transaction.transactionId='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'}
        $adapters=@{
            WaitWrapperExit={param($Identity,$Timeout)[pscustomobject]@{verifiedAtStart=($kind-cne'Wrapper');exited=$true}}.GetNewClosure()
            ReadPreparedTransaction={param($Id)$transaction}.GetNewClosure()
            ValidateSelectedGeneration={param($RuntimeRoot,$InstallRoot,$Transaction)$kind-cne'Generation'}.GetNewClosure()
            ReadCurrentEpoch={param($InstallRoot)if($kind-ceq'Epoch'){[uint64]12}else{[uint64]11}}.GetNewClosure()
            RemoveSelectedGeneration={param($RuntimeRoot,$Transaction)$world.Deletes++;$Transaction}.GetNewClosure()
            TestSelectedRootAbsent={param($Root)$false};RemoveMatchedProductRegistration={param($Transaction)};FinalizeReceipt={param($Transaction)[pscustomobject]@{phase='Completed'}}
        }
        Assert-CcodThrows {Invoke-CcodInstalledUninstallFinalizer -TransactionId '11111111-2222-3333-4444-555555555555' -RuntimeRoot 'C:\install\runtime\2.5.0-uninstall-test' -InstallRoot 'C:\install' -WrapperIdentity ([pscustomobject]@{pid=42;creationTimeUtc='2030-02-03T03:04:05.0000000Z';sessionId=1;userSid='S-1-5-21-111-222-333-1001'}) -Adapters $adapters|Out-Null} 'CCOD_INSTALLED_FINALIZER_INVALID'
        Assert-CcodEqual 0 $world.Deletes "$kind mismatch deletes no application state"
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

$results += Invoke-CcodTest 'default installed finalizer validates and removes only the exact selected generation fixture' {
    $local=Join-Path ([IO.Path]::GetTempPath()) ('ccod-installed-finalizer-'+[guid]::NewGuid().ToString('N'));$previous=[Environment]::GetEnvironmentVariable('LOCALAPPDATA','Process')
    try{[Environment]::SetEnvironmentVariable('LOCALAPPDATA',$local,'Process');$install=Join-Path $local 'CodexControlOtherDevices';$fixture=New-CcodVerifiedUninstallRuntimeFixture -InstallRoot $install -AppendOnly;$identity=Get-CcodUninstallBootstrapCurrentIdentity;$transactionRoot=Get-CcodUninstallBootstrapDefaultTransactionRoot;$id='11111111-2222-3333-4444-555555555555';$directory=New-CcodUninstallBootstrapTransactionDirectory -TransactionRoot $transactionRoot -TransactionId $id -UserSid $identity.userSid;$tx=New-CcodUninstallBootstrapTestTransaction -Phase 'TaskRemoved';$tx.runtimeId=$fixture.RuntimeId;$tx.runtimeGeneration=[uint64]7;$tx.userSid=$identity.userSid;$tx.sessionId=$identity.sessionId;$tx.readyEvidence.runtimeId=$fixture.RuntimeId;$tx.readyEvidence.runtimeGeneration=[uint64]7;$tx.readyEvidence.installRoot=$install;$manifest=(Get-FileHash (Join-Path $fixture.RuntimeRoot 'manifest.json') -Algorithm SHA256).Hash.ToLowerInvariant();$tx.readyEvidence.manifestSha256=$manifest;$tx.installedBinding=[pscustomobject][ordered]@{selectedRuntimeRoot=$fixture.RuntimeRoot;runtimeManifestSha256=$manifest;wrapperPid=42;wrapperCreationTimeUtc='2030-02-03T03:04:05.0000000Z';wrapperSessionId=$identity.sessionId;wrapperUserSid=$identity.userSid};Write-CcodUninstallBootstrapStoredTransaction -TransactionDirectory $directory -Transaction $tx;Publish-CcodUninstallBootstrapCurrentTransaction -TransactionRoot $transactionRoot -TransactionId $id -UserSid $identity.userSid
        $payload=Join-Path $directory 'payload';foreach($relative in @('src\persistence\UninstallBootstrap.ps1','src\persistence\modules\GenerationReclamation.psm1')){$destination=Join-Path $payload $relative;[IO.Directory]::CreateDirectory((Split-Path $destination -Parent))|Out-Null;[IO.File]::Copy((Join-Path $repositoryRoot $relative),$destination,$true)};$adapters=Get-CcodInstalledFinalizerAdapters -Adapters @{WaitWrapperExit={param($I,$T)[pscustomobject]@{verifiedAtStart=$true;exited=$true}};RemoveMatchedProductRegistration={param($T)};FinalizeReceipt={param($T)[pscustomobject]@{phase='Completed'}}} -TransactionRoot $transactionRoot -PayloadRoot $payload;$receipt=Invoke-CcodInstalledUninstallFinalizer -TransactionId $id -RuntimeRoot $fixture.RuntimeRoot -InstallRoot $install -WrapperIdentity ([pscustomobject]@{pid=42;creationTimeUtc='2030-02-03T03:04:05.0000000Z';sessionId=$identity.sessionId;userSid=$identity.userSid}) -Adapters $adapters;Assert-CcodEqual 'Completed' $receipt.phase 'default finalizer reaches completion';Assert-CcodTrue (-not(Test-Path $fixture.RuntimeRoot)) 'default finalizer deletes exact selected runtime';Assert-CcodTrue (Test-Path (Join-Path $install 'state')) 'default finalizer preserves sibling install state'
    }finally{[Environment]::SetEnvironmentVariable('LOCALAPPDATA',$previous,'Process');if(Test-Path $local){Remove-Item $local -Recurse -Force}}
}

function Invoke-CcodInstalledReclamationMutationCase {
    param([Parameter(Mandatory)][ValidateSet('UnexpectedFile','UnexpectedDirectory','Reparse','Hardlink','Ads','OpenChild')][string]$Mutation)
    $local=Join-Path ([IO.Path]::GetTempPath()) ('ccod-installed-reclamation-red-'+[guid]::NewGuid().ToString('N'));$previous=[Environment]::GetEnvironmentVariable('LOCALAPPDATA','Process');$attackState=[pscustomobject]@{Path=$null;OpenHandle=$null}
    try{
        [Environment]::SetEnvironmentVariable('LOCALAPPDATA',$local,'Process');$install=Join-Path $local 'CodexControlOtherDevices';$fixture=New-CcodVerifiedUninstallRuntimeFixture -InstallRoot $install -AppendOnly
        $originalFiles=@(Get-ChildItem -LiteralPath $fixture.RuntimeRoot -File -Recurse -Force|ForEach-Object{[pscustomobject]@{Path=$_.FullName;Length=[int64]$_.Length;Sha256=Get-CcodTestFileSha256 $_.FullName}});$originalDirectories=@(Get-ChildItem -LiteralPath $fixture.RuntimeRoot -Directory -Recurse -Force|ForEach-Object FullName)
        $outside=Join-Path $local 'outside';[IO.Directory]::CreateDirectory($outside)|Out-Null;$outsideSentinel=Join-Path $outside 'sentinel.bin';[IO.File]::WriteAllText($outsideSentinel,'outside-preserved',[Text.UTF8Encoding]::new($false));$outsideHash=Get-CcodTestFileSha256 $outsideSentinel
        $sibling=Join-Path $install 'runtime\sibling-generation';[IO.Directory]::CreateDirectory($sibling)|Out-Null;$siblingSentinel=Join-Path $sibling 'sentinel.bin';[IO.File]::WriteAllText($siblingSentinel,'sibling-preserved',[Text.UTF8Encoding]::new($false));$siblingHash=Get-CcodTestFileSha256 $siblingSentinel
        $deviceKey=Join-Path $install 'state\device-key\private.bin';[IO.Directory]::CreateDirectory((Split-Path $deviceKey -Parent))|Out-Null;[IO.File]::WriteAllText($deviceKey,'dpapi-sentinel-preserved',[Text.UTF8Encoding]::new($false));$deviceKeyHash=Get-CcodTestFileSha256 $deviceKey
        $identity=Get-CcodUninstallBootstrapCurrentIdentity;$transactionRoot=Get-CcodUninstallBootstrapDefaultTransactionRoot;$id=[guid]::NewGuid().ToString('D');$directory=New-CcodUninstallBootstrapTransactionDirectory -TransactionRoot $transactionRoot -TransactionId $id -UserSid $identity.userSid
        $tx=New-CcodUninstallBootstrapTestTransaction -Phase 'TaskRemoved' -TransactionId $id;$tx.runtimeId=$fixture.RuntimeId;$tx.runtimeGeneration=[uint64]7;$tx.userSid=$identity.userSid;$tx.sessionId=$identity.sessionId;$tx.readyEvidence.runtimeId=$fixture.RuntimeId;$tx.readyEvidence.runtimeGeneration=[uint64]7;$tx.readyEvidence.installRoot=$install;$manifest=(Get-FileHash (Join-Path $fixture.RuntimeRoot 'manifest.json') -Algorithm SHA256).Hash.ToLowerInvariant();$tx.readyEvidence.manifestSha256=$manifest;$tx.installedBinding=[pscustomobject][ordered]@{selectedRuntimeRoot=$fixture.RuntimeRoot;runtimeManifestSha256=$manifest;wrapperPid=42;wrapperCreationTimeUtc='2030-02-03T03:04:05.0000000Z';wrapperSessionId=$identity.sessionId;wrapperUserSid=$identity.userSid};Write-CcodUninstallBootstrapStoredTransaction -TransactionDirectory $directory -Transaction $tx
        $payload=Join-Path $directory 'payload';[IO.Directory]::CreateDirectory((Join-Path $payload 'src\persistence'))|Out-Null;[IO.File]::Copy($bootstrapScript,(Join-Path $payload 'src\persistence\UninstallBootstrap.ps1'),$true);$reclamationSource=Join-Path $repositoryRoot 'src\persistence\modules\GenerationReclamation.psm1';if(Test-Path -LiteralPath $reclamationSource -PathType Leaf){$reclamationDestination=Join-Path $payload 'src\persistence\modules\GenerationReclamation.psm1';[IO.Directory]::CreateDirectory((Split-Path $reclamationDestination -Parent))|Out-Null;[IO.File]::Copy($reclamationSource,$reclamationDestination,$true)}
        $adapters=Get-CcodInstalledFinalizerAdapters -Adapters $null -TransactionRoot $transactionRoot -PayloadRoot $payload;$validate=$adapters.ValidateSelectedGeneration;$anchor=Join-Path $fixture.RuntimeRoot 'manifest.json'
        $adapters.WaitWrapperExit={param($I,$T)[pscustomobject]@{verifiedAtStart=$true;exited=$true}};$adapters.ReadPreparedTransaction={param($Id,$Root)$tx}.GetNewClosure();$adapters.ReadCurrentEpoch={param($Root)[uint64]11};$adapters.ValidateSelectedGeneration={param($Root,$Install,$Transaction);$valid=&$validate $Root $Install $Transaction;if(-not$valid){return $false};switch($Mutation){'UnexpectedFile'{$attackState.Path=Join-Path $Root 'unexpected-after-validation.bin';[IO.File]::WriteAllText($attackState.Path,'hostile',[Text.UTF8Encoding]::new($false))}'UnexpectedDirectory'{$attackState.Path=Join-Path $Root 'unexpected-empty-directory';[IO.Directory]::CreateDirectory($attackState.Path)|Out-Null}'Reparse'{$attackState.Path=Join-Path $Root 'unexpected-reparse';New-Item -ItemType Junction -Path $attackState.Path -Target $outside|Out-Null}'Hardlink'{$attackState.Path=Join-Path $Root 'unexpected-hardlink.bin';New-Item -ItemType HardLink -Path $attackState.Path -Target $outsideSentinel|Out-Null}'Ads'{$attackState.Path=$anchor;$attributes=[IO.File]::GetAttributes($anchor);[IO.File]::SetAttributes($anchor,[IO.FileAttributes]::Normal);try{Set-Content -LiteralPath $anchor -Stream 'ccod-evidence' -Value 'hostile' -NoNewline}finally{[IO.File]::SetAttributes($anchor,$attributes)}}'OpenChild'{$attackState.Path=$anchor;$attackState.OpenHandle=[IO.File]::Open($anchor,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)}};return $true}.GetNewClosure();$adapters.RemoveMatchedProductRegistration={param($T)};$adapters.FinalizeReceipt={param($T)[pscustomobject]@{phase='Completed'}}
        $failure=$null;try{Invoke-CcodInstalledUninstallFinalizer -TransactionId $id -RuntimeRoot $fixture.RuntimeRoot -InstallRoot $install -WrapperIdentity ([pscustomobject]@{pid=42;creationTimeUtc='2030-02-03T03:04:05.0000000Z';sessionId=$identity.sessionId;userSid=$identity.userSid}) -Adapters $adapters|Out-Null}catch{$failure=$_}
        $treeComplete=(Test-Path -LiteralPath $fixture.RuntimeRoot -PathType Container);if($treeComplete){foreach($directoryPath in $originalDirectories){if(-not(Test-Path -LiteralPath $directoryPath -PathType Container)){$treeComplete=$false;break}}};if($treeComplete){foreach($fileProof in $originalFiles){if(-not(Test-Path -LiteralPath $fileProof.Path -PathType Leaf)-or[int64](Get-Item -LiteralPath $fileProof.Path -Force).Length-ne$fileProof.Length-or(Get-CcodTestFileSha256 $fileProof.Path)-cne$fileProof.Sha256){$treeComplete=$false;break}}}
        if($null-eq$failure-or-not$treeComplete){throw [Management.Automation.ErrorRecord]::new([InvalidOperationException]::new("pathname reclamation accepted or partially deleted the $Mutation tree"),'CCOD_RECLAMATION_RED_PATHNAME_DELETE',[Management.Automation.ErrorCategory]::InvalidData,$fixture.RuntimeRoot)}
        if(([string]$failure.FullyQualifiedErrorId-split',')[0]-cne'CCOD_GENERATION_RECLAMATION_INVALID'){throw $failure}
        Assert-CcodEqual $outsideHash (Get-CcodTestFileSha256 $outsideSentinel) "$Mutation preserves outside bytes";Assert-CcodEqual $siblingHash (Get-CcodTestFileSha256 $siblingSentinel) "$Mutation preserves sibling generation bytes";Assert-CcodEqual $deviceKeyHash (Get-CcodTestFileSha256 $deviceKey) "$Mutation preserves device-key bytes"
        if($Mutation-ceq'Ads'){Assert-CcodTrue ($null-ne(Get-Item -LiteralPath $attackState.Path -Stream 'ccod-evidence' -ErrorAction SilentlyContinue)) 'ADS hostile object remains after zero deletion'}else{Assert-CcodTrue (Test-Path -LiteralPath $attackState.Path) "$Mutation hostile object remains after zero deletion"}
    }finally{if($null-ne$attackState.OpenHandle){$attackState.OpenHandle.Dispose()};[Environment]::SetEnvironmentVariable('LOCALAPPDATA',$previous,'Process');if(Test-Path -LiteralPath $local){Remove-Item -LiteralPath $local -Recurse -Force}}
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
        $local=Join-Path ([IO.Path]::GetTempPath()) ('ccod-reclamation-identity-'+[guid]::NewGuid().ToString('N'))
        try{
            $install=Join-Path $local 'install';$fixture=New-CcodVerifiedUninstallRuntimeFixture -InstallRoot $install -AppendOnly;$proof=Get-CcodGenerationReclamationTreeProof $fixture.RuntimeRoot;$manifest=Get-CcodTestFileSha256 (Join-Path $fixture.RuntimeRoot 'manifest.json')
            $replacement=Join-Path $local 'replacement-generation';Copy-Item -LiteralPath $fixture.RuntimeRoot -Destination $replacement -Recurse -Force;$replacementProof=Get-CcodGenerationReclamationTreeProof $replacement;$parked=Join-Path $local 'original-generation';$attack=[pscustomobject]@{Result=$null}
            $hook={try{[IO.Directory]::Move($fixture.RuntimeRoot,$parked);[IO.Directory]::Move($replacement,$fixture.RuntimeRoot);$attack.Result='exchanged'}catch [IO.IOException]{$attack.Result='blocked'}catch [UnauthorizedAccessException]{$attack.Result='blocked'};throw [InvalidOperationException]::new('identity replacement probe')}.GetNewClosure()
            &$module {param($Value)$script:CcodGenerationReclamationBeforeArmForTest=$Value} $hook
            try{Assert-CcodThrows {Remove-CcodVerifiedGenerationTree -InstallRoot $install -RuntimeRoot $fixture.RuntimeRoot -RuntimeId $fixture.RuntimeId -ExpectedManifestSha256 $manifest|Out-Null} 'CCOD_GENERATION_RECLAMATION_INVALID'}finally{&$module {$script:CcodGenerationReclamationBeforeArmForTest=$null}}
            Assert-CcodEqual 'blocked' $attack.Result 'pinned selected root rejects identity replacement';Assert-CcodGenerationReclamationTreeProof $proof 'identity replacement failure preserves selected tree';Assert-CcodGenerationReclamationTreeProof $replacementProof 'identity replacement failure preserves outside replacement tree';Assert-CcodTrue (-not(Test-Path -LiteralPath $parked)) 'identity replacement creates no renamed selected alias'
        }finally{if(Test-Path -LiteralPath $local){Remove-Item -LiteralPath $local -Recurse -Force}}
    }
}

if([string]::IsNullOrWhiteSpace($env:CCOD_RECLAMATION_RED_CASE)-or$env:CCOD_RECLAMATION_RED_CASE-ceq'MarkFailure'){
    $results += Invoke-CcodTest 'file-arm failure disarms every held identity validates the complete tree and permits an exact retry' {
        $modulePath=Join-Path $repositoryRoot 'src\persistence\modules\GenerationReclamation.psm1';if(-not(Test-Path -LiteralPath $modulePath -PathType Leaf)){throw [Management.Automation.ErrorRecord]::new([InvalidOperationException]::new('generation reclamation module is missing'),'CCOD_RECLAMATION_RED_MODULE_MISSING',[Management.Automation.ErrorCategory]::ObjectNotFound,$modulePath)};$module=Import-Module $modulePath -Force -PassThru -DisableNameChecking
        $local=Join-Path ([IO.Path]::GetTempPath()) ('ccod-reclamation-disarm-'+[guid]::NewGuid().ToString('N'))
        try{
            $install=Join-Path $local 'install';$fixture=New-CcodVerifiedUninstallRuntimeFixture -InstallRoot $install -AppendOnly;$proof=Get-CcodGenerationReclamationTreeProof $fixture.RuntimeRoot;$manifest=Get-CcodTestFileSha256 (Join-Path $fixture.RuntimeRoot 'manifest.json');$sibling=Join-Path $install 'runtime\sibling';[IO.Directory]::CreateDirectory($sibling)|Out-Null;$siblingFile=Join-Path $sibling 'sentinel.bin';[IO.File]::WriteAllText($siblingFile,'sibling',[Text.UTF8Encoding]::new($false));$siblingHash=Get-CcodTestFileSha256 $siblingFile;$deviceKey=Join-Path $install 'state\device-key\private.bin';[IO.Directory]::CreateDirectory((Split-Path $deviceKey -Parent))|Out-Null;[IO.File]::WriteAllText($deviceKey,'device-key',[Text.UTF8Encoding]::new($false));$deviceKeyHash=Get-CcodTestFileSha256 $deviceKey
            &$module {$script:CcodGenerationReclamationFailFileArmAtForTest=2}
            try{Assert-CcodThrows {Remove-CcodVerifiedGenerationTree -InstallRoot $install -RuntimeRoot $fixture.RuntimeRoot -RuntimeId $fixture.RuntimeId -ExpectedManifestSha256 $manifest|Out-Null} 'CCOD_GENERATION_RECLAMATION_INVALID'}finally{&$module {$script:CcodGenerationReclamationFailFileArmAtForTest=-1}}
            Assert-CcodGenerationReclamationTreeProof $proof 'file-arm rollback preserves the complete selected tree';Assert-CcodEqual $siblingHash (Get-CcodTestFileSha256 $siblingFile) 'file-arm rollback preserves sibling';Assert-CcodEqual $deviceKeyHash (Get-CcodTestFileSha256 $deviceKey) 'file-arm rollback preserves device-key state'
            $result=Remove-CcodVerifiedGenerationTree -InstallRoot $install -RuntimeRoot $fixture.RuntimeRoot -RuntimeId $fixture.RuntimeId -ExpectedManifestSha256 $manifest;Assert-CcodEqual 'Completed' $result.phase 'successful retry reaches terminal reclamation phase';Assert-CcodEqual 'Reclaimed' $result.result 'successful retry reports exact reclamation';Assert-CcodTrue (-not(Test-Path -LiteralPath $fixture.RuntimeRoot)) 'successful retry removes only selected generation';Assert-CcodEqual $siblingHash (Get-CcodTestFileSha256 $siblingFile) 'successful retry preserves sibling';Assert-CcodEqual $deviceKeyHash (Get-CcodTestFileSha256 $deviceKey) 'successful retry preserves device-key state';Assert-CcodTrue (Test-Path -LiteralPath $install -PathType Container) 'successful retry preserves install root'
        }finally{if(Test-Path -LiteralPath $local){Remove-Item -LiteralPath $local -Recurse -Force}}
    }
}

if([string]::IsNullOrWhiteSpace($env:CCOD_RECLAMATION_RED_CASE)-or$env:CCOD_RECLAMATION_RED_CASE-ceq'CommitFailure'){
    $results += Invoke-CcodTest 'irreversible reclamation failure reports CommitStarted and never touches sibling or lifecycle state' {
        $modulePath=Join-Path $repositoryRoot 'src\persistence\modules\GenerationReclamation.psm1';$module=Import-Module $modulePath -Force -PassThru -DisableNameChecking;$local=Join-Path ([IO.Path]::GetTempPath()) ('ccod-reclamation-commit-failure-'+[guid]::NewGuid().ToString('N'))
        try{
            $install=Join-Path $local 'install';$fixture=New-CcodVerifiedUninstallRuntimeFixture -InstallRoot $install -AppendOnly;$proof=Get-CcodGenerationReclamationTreeProof $fixture.RuntimeRoot;$manifest=Get-CcodTestFileSha256 (Join-Path $fixture.RuntimeRoot 'manifest.json');$outside=Join-Path $local 'outside';[IO.Directory]::CreateDirectory($outside)|Out-Null;$outsideFile=Join-Path $outside 'sentinel.bin';[IO.File]::WriteAllText($outsideFile,'outside',[Text.UTF8Encoding]::new($false));$outsideHash=Get-CcodTestFileSha256 $outsideFile;$sibling=Join-Path $install 'runtime\sibling';[IO.Directory]::CreateDirectory($sibling)|Out-Null;$siblingFile=Join-Path $sibling 'sentinel.bin';[IO.File]::WriteAllText($siblingFile,'sibling',[Text.UTF8Encoding]::new($false));$siblingHash=Get-CcodTestFileSha256 $siblingFile;$deviceKey=Join-Path $install 'state\device-key\private.bin';[IO.Directory]::CreateDirectory((Split-Path $deviceKey -Parent))|Out-Null;[IO.File]::WriteAllText($deviceKey,'device-key',[Text.UTF8Encoding]::new($false));$deviceKeyHash=Get-CcodTestFileSha256 $deviceKey
            &$module {param($Index)$script:CcodGenerationReclamationFailCommitAtForTest=$Index} ($proof.Files.Count+1)
            try{Assert-CcodThrows {Remove-CcodVerifiedGenerationTree -InstallRoot $install -RuntimeRoot $fixture.RuntimeRoot -RuntimeId $fixture.RuntimeId -ExpectedManifestSha256 $manifest|Out-Null} 'CCOD_GENERATION_RECLAMATION_COMMIT_FAILED'}finally{&$module {$script:CcodGenerationReclamationFailCommitAtForTest=-1}}
            Assert-CcodTrue (Test-Path -LiteralPath $fixture.RuntimeRoot -PathType Container) 'CommitStarted failure retains a selected-root failure boundary';Assert-CcodEqual $outsideHash (Get-CcodTestFileSha256 $outsideFile) 'CommitStarted failure preserves outside';Assert-CcodEqual $siblingHash (Get-CcodTestFileSha256 $siblingFile) 'CommitStarted failure preserves sibling';Assert-CcodEqual $deviceKeyHash (Get-CcodTestFileSha256 $deviceKey) 'CommitStarted failure preserves lifecycle/device-key state';Assert-CcodTrue (Test-Path -LiteralPath $install -PathType Container) 'CommitStarted failure preserves install root'
        }finally{if(Test-Path -LiteralPath $local){Remove-Item -LiteralPath $local -Recurse -Force}}

        $calls=[Collections.Generic.List[string]]::new();$tx=New-CcodUninstallBootstrapTestTransaction -Phase 'TaskRemoved';$tx.installedBinding=[pscustomobject][ordered]@{selectedRuntimeRoot='C:\install\runtime\2.5.0-uninstall-test';runtimeManifestSha256=('a'*64);wrapperPid=42;wrapperCreationTimeUtc='2030-02-03T03:04:05.0000000Z';wrapperSessionId=1;wrapperUserSid='S-1-5-21-111-222-333-1001'}
        $adapters=@{WaitWrapperExit={param($I,$T)[pscustomobject]@{verifiedAtStart=$true;exited=$true}};ReadPreparedTransaction={param($Id,$Root)$tx}.GetNewClosure();ValidateSelectedGeneration={param($Runtime,$Install,$Transaction)$true};ReadCurrentEpoch={param($Root)[uint64]11};RemoveSelectedGeneration={param($Runtime,$Transaction)$calls.Add('Remove');throw [Management.Automation.ErrorRecord]::new([IO.IOException]::new('commit failed'),'CCOD_GENERATION_RECLAMATION_COMMIT_FAILED',[Management.Automation.ErrorCategory]::WriteError,$Runtime)}.GetNewClosure();TestSelectedRootAbsent={param($Root)$calls.Add('Absent');$false}.GetNewClosure();RemoveMatchedProductRegistration={param($Transaction)$calls.Add('Product')}.GetNewClosure();FinalizeReceipt={param($Transaction)$calls.Add('Finalize');[pscustomobject]@{phase='Completed'}}.GetNewClosure()}
        Assert-CcodThrows {Invoke-CcodInstalledUninstallFinalizer -TransactionId $tx.transactionId -RuntimeRoot $tx.installedBinding.selectedRuntimeRoot -InstallRoot 'C:\install' -WrapperIdentity ([pscustomobject]@{pid=42;creationTimeUtc='2030-02-03T03:04:05.0000000Z';sessionId=1;userSid='S-1-5-21-111-222-333-1001'}) -Adapters $adapters|Out-Null} 'CCOD_GENERATION_RECLAMATION_COMMIT_FAILED';Assert-CcodEqual 'Remove' ($calls-join',') 'CommitStarted failure reaches no absence proof product removal or completion receipt'
    }
}

function Invoke-CcodDefaultInstalledFinalizerNegative {
    param([Parameter(Mandatory)][ValidateSet('Sibling','WrongPath','StaleEpoch','WrapperIdentity','WrongReadyRoot','ExtraReadyField')][string]$Mutation)
    $local=Join-Path ([IO.Path]::GetTempPath()) ('ccod-finalizer-negative-'+[guid]::NewGuid().ToString('N'));$previous=[Environment]::GetEnvironmentVariable('LOCALAPPDATA','Process');$wrapper=$null
    try{
        [Environment]::SetEnvironmentVariable('LOCALAPPDATA',$local,'Process');$install=Join-Path $local 'CodexControlOtherDevices';$fixture=New-CcodVerifiedUninstallRuntimeFixture -InstallRoot $install -AppendOnly;$selected=$fixture.RuntimeRoot;$runtime=$selected
        if($Mutation-ceq'Sibling'){$runtime=Join-Path $install 'runtime\same-bootstrap-sibling';Copy-Item -LiteralPath $selected -Destination $runtime -Recurse -Force}
        elseif($Mutation-ceq'WrongPath'){$runtime=Join-Path $selected 'nested-wrong-runtime'}
        $identity=Get-CcodUninstallBootstrapCurrentIdentity;$id=[guid]::NewGuid().ToString('D');$transactionRoot=Get-CcodUninstallBootstrapDefaultTransactionRoot;$directory=New-CcodUninstallBootstrapTransactionDirectory -TransactionRoot $transactionRoot -TransactionId $id -UserSid $identity.userSid
        $wrapper=Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-Command','Start-Sleep -Milliseconds 1400') -WindowStyle Hidden -PassThru;$wrapperCreation=$wrapper.StartTime.ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture)
        $tx=New-CcodUninstallBootstrapTestTransaction -Phase 'TaskRemoved';$tx.transactionId=$id;$tx.runtimeId=[IO.Path]::GetFileName($runtime);$tx.runtimeGeneration=[uint64]7;$tx.leaseEpoch=if($Mutation-ceq'StaleEpoch'){[uint64]12}else{[uint64]11};$tx.userSid=$identity.userSid;$tx.sessionId=$identity.sessionId;$tx.readyEvidence.installRoot=$install;$tx.readyEvidence.runtimeId=$tx.runtimeId;$tx.readyEvidence.runtimeGeneration=[uint64]7;$manifest=(Get-FileHash (Join-Path $selected 'manifest.json') -Algorithm SHA256).Hash.ToLowerInvariant();$tx.readyEvidence.manifestSha256=$manifest;$tx.installedBinding=[pscustomobject][ordered]@{selectedRuntimeRoot=$runtime;runtimeManifestSha256=$manifest;wrapperPid=[int]$wrapper.Id;wrapperCreationTimeUtc=$wrapperCreation;wrapperSessionId=$identity.sessionId;wrapperUserSid=$identity.userSid}
        Write-CcodUninstallBootstrapStoredTransaction -TransactionDirectory $directory -Transaction $tx;Publish-CcodUninstallBootstrapCurrentTransaction -TransactionRoot $transactionRoot -TransactionId $id -UserSid $identity.userSid
        if($Mutation-ceq'WrongReadyRoot'){$tx.readyEvidence.installRoot=Join-Path $local 'unrelated-root';[IO.File]::WriteAllText((Join-Path $directory 'transaction.json'),($tx|ConvertTo-Json -Depth 12 -Compress),[Text.UTF8Encoding]::new($false))}
        elseif($Mutation-ceq'ExtraReadyField'){$tx.readyEvidence|Add-Member -NotePropertyName unexpectedReadyField -NotePropertyValue 'reject';[IO.File]::WriteAllText((Join-Path $directory 'transaction.json'),($tx|ConvertTo-Json -Depth 12 -Compress),[Text.UTF8Encoding]::new($false))}
        $payload=Join-Path $directory 'payload';foreach($relative in @('src\persistence\InstalledUninstallFinalizer.ps1','src\persistence\UninstallBootstrap.ps1')){$destination=Join-Path $payload $relative;[IO.Directory]::CreateDirectory((Split-Path $destination -Parent))|Out-Null;[IO.File]::Copy((Join-Path $selected $relative),$destination,$true)}
        $creationArgument=if($Mutation-ceq'WrapperIdentity'){'2001-02-03T04:05:06.0000000Z'}else{$wrapperCreation};$previousPreference=$ErrorActionPreference;try{$ErrorActionPreference='Continue';$output=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $payload 'src\persistence\InstalledUninstallFinalizer.ps1') -TransactionId $id -RuntimeRoot $runtime -InstallRoot $install -WrapperProcessId $wrapper.Id -WrapperCreationTimeUtc $creationArgument 2>&1;$exit=$LASTEXITCODE}finally{$ErrorActionPreference=$previousPreference}
        if($exit-ne3){throw("FINALIZER_DIAGNOSTIC mutation={0} exit={1} output={2}"-f$Mutation,$exit,(@($output)-join' | '))};Assert-CcodEqual 3 $exit "$Mutation default child rejects before finalization";Assert-CcodTrue (Test-Path -LiteralPath $selected -PathType Container) "$Mutation preserves the selected generation";Assert-CcodTrue (Test-Path -LiteralPath (Join-Path $install 'state') -PathType Container) "$Mutation preserves sibling/root state"
        if($Mutation-notin@('WrongPath','WrapperIdentity')){$wrapper.Refresh();Assert-CcodTrue $wrapper.HasExited "$Mutation reaches the default wrapper wait before its later negative boundary"}
    }finally{if($null-ne$wrapper){try{if(-not$wrapper.HasExited){$wrapper.Kill();$wrapper.WaitForExit()}}catch{};$wrapper.Dispose()};[Environment]::SetEnvironmentVariable('LOCALAPPDATA',$previous,'Process');if(Test-Path -LiteralPath $local){Remove-Item -LiteralPath $local -Recurse -Force}}
}

$results += Invoke-CcodTest 'default staged installed finalizer child rejects the full negative authorization matrix without deletion' {
    foreach($mutation in @('Sibling','WrongPath','StaleEpoch','WrapperIdentity','WrongReadyRoot','ExtraReadyField')){Invoke-CcodDefaultInstalledFinalizerNegative -Mutation $mutation}
}

$results | ForEach-Object { "PASS $($_.Name)" }
Write-Output "Uninstall bootstrap self-tests passed: $($results.Count)"
