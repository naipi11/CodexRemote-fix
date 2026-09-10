$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'TestSupport.ps1')
$repositoryRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$module=Import-Module (Join-Path $repositoryRoot 'src/persistence/modules/GenerationReclamation.psm1') -Force -PassThru
$fixtureTokens=$null;$fixtureErrors=$null
$fixtureAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'InstallLifecycle.SelfTest.ps1'),[ref]$fixtureTokens,[ref]$fixtureErrors)
if(@($fixtureErrors).Count-ne0){throw 'installer fixture definitions invalid'}
foreach($definition in @($fixtureAst.EndBlock.Statements|Where-Object {$_-is[Management.Automation.Language.FunctionDefinitionAst]})){. ([scriptblock]::Create($definition.Extent.Text))}
$v2521LifecycleShortcutNames=@('Programs\CodexRemote-fix\CodexRemote-fix.lnk','Programs\CodexRemote-fix\CodexRemote-fix compatibility check.lnk','Programs\CodexRemote-fix\Uninstall CodexRemote-fix.lnk','Desktop\CodexRemote-fix.lnk')
$results=@()

$results+=Invoke-CcodTest 'generation reclamation runtime IDs use canonical TAB delimiters' {
    $records=@(
        [pscustomobject]@{path='a.txt';length=[int64]5;sha256=('a'*64)}
        [pscustomobject]@{path='b.txt';length=[int64]4;sha256=('b'*64)}
    )
    $expected='2.5.22-e71f4818a0f8e98f-0123456789abcdef0123456789abcdef'
    Assert-CcodEqual $expected (&$module {param($ProjectVersion,$Records,$Nonce) Get-CcodGenerationReclamationRuntimeId -ProjectVersion $ProjectVersion -Records $Records -Nonce $Nonce} '2.5.22' $records '0123456789abcdef0123456789abcdef') 'generation reclamation digest input must use literal TAB delimiters'
}

$results+=Invoke-CcodTest 'bounded product residue cleanup removes only the verified disposable product root' {
    $root=Join-Path $env:TEMP ('ccod-product-tail-'+[guid]::NewGuid().ToString('N'))
    $install=Join-Path $root 'CodexControlOtherDevices'
    try {
        [IO.Directory]::CreateDirectory((Join-Path $install 'state/active-generation'))|Out-Null
        [IO.Directory]::CreateDirectory((Join-Path $install 'runtime'))|Out-Null
        $runtimeId='2.5.22-'+('a'*16)+'-'+('b'*32)
        [IO.File]::WriteAllText((Join-Path $install 'state/lifecycle-epoch.json'),'{"schemaVersion":1,"epoch":11}')
        [IO.File]::WriteAllText((Join-Path $install 'state/active-generation/00000000000000000001.json'),('{"schemaVersion":1,"generation":1,"activeRuntime":"'+$runtimeId+'","previousGeneration":0}'))
        $outside=Join-Path $root 'project.txt';[IO.File]::WriteAllText($outside,'user project retained')
        $outsideHash=Get-CcodTestFileSha256 $outside
        $result=&$module {
            param($Install,$Runtime)
            Remove-CcodVerifiedProductResidue -InstallRoot $Install -SelectedRuntimeId $Runtime -ExpectedEpoch ([uint64]11)
        } $install $runtimeId
        Assert-CcodEqual 'Removed' $result.result 'product cleanup returns exact terminal result'
        Assert-CcodTrue (-not(Test-Path -LiteralPath $install)) 'complete uninstall removes the product root'
        Assert-CcodEqual $outsideHash (Get-CcodTestFileSha256 $outside) 'sibling project is unchanged'
    } finally {if(Test-Path $root){Remove-Item $root -Recurse -Force}}
}
$results+=Invoke-CcodTest 'bounded product residue cleanup accepts real initialized state and retained manifest files' {
    $root=Join-Path $env:TEMP ('ccod-product-state-'+[guid]::NewGuid().ToString('N'))
    $install=Join-Path $root 'CodexControlOtherDevices'
    $modules=@()
    try {
        $state=Join-Path $install 'state'
        [IO.Directory]::CreateDirectory((Join-Path $state 'active-generation'))|Out-Null
        $modules+=Import-Module (Join-Path $repositoryRoot 'src/persistence/modules/StateStore.psm1') -Force -PassThru -DisableNameChecking
        $modules+=Import-Module (Join-Path $repositoryRoot 'src/persistence/modules/UiPreferences.psm1') -Force -PassThru -DisableNameChecking
        $modules+=Import-Module (Join-Path $repositoryRoot 'src/persistence/modules/RuntimeManifest.psm1') -Force -PassThru -DisableNameChecking
        $initialized=Initialize-CcodState -StateRoot $state -NodeCandidates @() -CandidateCompatibleOptIn $false
        $initialized.settings.automationEnabled=$false
        Write-CcodSettings -StateRoot $state -Settings $initialized.settings
        Initialize-CcodUiPreference -StateRoot $state|Out-Null
        $runtimeId='2.5.22-'+('a'*16)+'-'+('b'*32)
        [IO.File]::WriteAllText((Join-Path $state 'lifecycle-epoch.json'),'{"schemaVersion":1,"epoch":11}')
        [IO.File]::WriteAllText((Join-Path $state 'active-generation/00000000000000000001.json'),('{"schemaVersion":1,"generation":1,"activeRuntime":"'+$runtimeId+'","previousGeneration":0}'))
        $retained=Join-Path $install 'runtime/pending';[IO.Directory]::CreateDirectory($retained)|Out-Null
        [IO.File]::WriteAllText((Join-Path $retained 'payload.txt'),'verified retained product payload')
        $manifest=New-CcodRuntimeManifest -RuntimeDirectory $retained -ProjectVersion '2.5.22'
        $sealed=Join-Path $install ('runtime/'+$manifest.runtimeId);[IO.Directory]::Move($retained,$sealed)
        [IO.File]::WriteAllText((Join-Path $sealed 'manifest.json'),($manifest|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
        $result=&$module {param($Install,$Runtime)Remove-CcodVerifiedProductResidue -InstallRoot $Install -SelectedRuntimeId $Runtime -ExpectedEpoch ([uint64]11)} $install $runtimeId
        Assert-CcodEqual 'Removed' $result.result 'actual producers are accepted without loosening unknown-file handling'
        Assert-CcodTrue (-not(Test-Path -LiteralPath $install)) 'known state and verified retained product files are removed'
    } finally {foreach($imported in $modules){Remove-Module $imported -Force -ErrorAction SilentlyContinue};if(Test-Path $root){Remove-Item $root -Recurse -Force}}
}

foreach($mutation in @('UnknownFile','UnknownDirectory','DeviceKey','Reparse','Hardlink','Ads','OpenFile','EpochDrift')){
    $results+=Invoke-CcodTest "bounded product residue rejects $mutation without deleting any file" {
        $root=Join-Path $env:TEMP ('ccod-product-hostile-'+[guid]::NewGuid().ToString('N'))
        $install=Join-Path $root 'CodexControlOtherDevices';$held=$null
        try {
            [IO.Directory]::CreateDirectory((Join-Path $install 'state/active-generation'))|Out-Null
            [IO.Directory]::CreateDirectory((Join-Path $install 'runtime'))|Out-Null
            $runtimeId='2.5.22-'+('a'*16)+'-'+('b'*32)
            $epoch=Join-Path $install 'state/lifecycle-epoch.json'
            [IO.File]::WriteAllText($epoch,'{"schemaVersion":1,"epoch":11}')
            $pointer=Join-Path $install 'state/active-generation/00000000000000000001.json'
            [IO.File]::WriteAllText($pointer,('{"schemaVersion":1,"generation":1,"activeRuntime":"'+$runtimeId+'","previousGeneration":0}'))
            $outside=Join-Path $root 'outside.txt';[IO.File]::WriteAllText($outside,'outside user data')
            $outsideHash=Get-CcodTestFileSha256 $outside
            switch($mutation){
                'UnknownFile' {[IO.File]::WriteAllText((Join-Path $install 'my-project.txt'),'user-owned')}
                'UnknownDirectory' {[IO.Directory]::CreateDirectory((Join-Path $install 'projects'))|Out-Null}
                'DeviceKey' {[IO.Directory]::CreateDirectory((Join-Path $install 'state/device-key'))|Out-Null;[IO.File]::WriteAllText((Join-Path $install 'state/device-key/sentinel.bin'),'synthetic protected data')}
                'Reparse' {New-Item -ItemType Junction -Path (Join-Path $install 'projects') -Target $root|Out-Null}
                'Hardlink' {Remove-Item $epoch;New-Item -ItemType HardLink -Path $epoch -Target $outside|Out-Null}
                'Ads' {Set-Content -LiteralPath $epoch -Stream 'untrusted' -Value 'ads' -NoNewline}
                'OpenFile' {$held=[IO.File]::Open($epoch,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)}
                'EpochDrift' {[IO.File]::WriteAllText($epoch,'{"schemaVersion":1,"epoch":12}')}
            }
            Assert-CcodThrows {&$module {param($Install,$Runtime)Remove-CcodVerifiedProductResidue -InstallRoot $Install -SelectedRuntimeId $Runtime -ExpectedEpoch ([uint64]11)} $install $runtimeId|Out-Null} 'CCOD_PRODUCT_RESIDUE_INVALID'
            Assert-CcodTrue (Test-Path $pointer) "$mutation leaves the product selector untouched"
            Assert-CcodTrue (Test-Path $epoch) "$mutation leaves the epoch untouched"
            Assert-CcodEqual $outsideHash (Get-CcodTestFileSha256 $outside) "$mutation leaves outside data untouched"
        } finally {if($null-ne$held){$held.Dispose()};if(Test-Path (Join-Path $install 'projects') -PathType Container){$item=Get-Item (Join-Path $install 'projects') -Force;if($item.Attributes-band[IO.FileAttributes]::ReparsePoint){[IO.Directory]::Delete($item.FullName)}};if(Test-Path $root){Remove-Item $root -Recurse -Force}}
    }
}

$results+=Invoke-CcodTest 'bounded cleanup accepts the actual installer state-plane writer output' {
    $root=Join-Path $env:TEMP ('ccod-product-install-plane-'+[guid]::NewGuid().ToString('N'))
    $install=Join-Path $root 'CodexControlOtherDevices';$fileTransaction=$null;$installModule=$null;$fileModule=$null
    try {
        [IO.Directory]::CreateDirectory((Join-Path $install 'state/active-generation'))|Out-Null
        [IO.Directory]::CreateDirectory((Join-Path $install 'runtime'))|Out-Null
        $runtimeId='2.5.22-'+('a'*16)+'-'+('b'*32)
        $fileModule=Import-Module (Join-Path $repositoryRoot 'src/persistence/modules/InstallFileTransaction.psm1') -Force -PassThru -DisableNameChecking
        $installModule=Import-Module (Join-Path $repositoryRoot 'src/persistence/modules/InstallLifecycle.psm1') -Force -PassThru -DisableNameChecking
        $fileTransaction=&$installModule {param($Root)Open-CcodLifecycleInstallStateTransaction -InstallRoot $Root} $install
        &$installModule {param($Root,$Runtime,$Transaction)Initialize-CcodInstallStatePlanes -InstallRoot $Root -RuntimeId $Runtime -FileTransaction $Transaction -NodeCandidates @() -CandidateCompatibleOptIn $false} $install $runtimeId $fileTransaction
        Close-CcodInstallFileTransaction -Transaction $fileTransaction -Disposition Ready|Out-Null;$fileTransaction=$null
        &$installModule {param($Root)$settings=Read-CcodSettings -StateRoot (Join-Path $Root 'state');$settings.automationEnabled=$false;Write-CcodSettings -StateRoot (Join-Path $Root 'state') -Settings $settings} $install
        [IO.File]::WriteAllText((Join-Path $install 'state/lifecycle-epoch.json'),'{"schemaVersion":1,"epoch":11}')
        [IO.File]::WriteAllText((Join-Path $install 'state/active-generation/00000000000000000001.json'),('{"schemaVersion":1,"generation":1,"activeRuntime":"'+$runtimeId+'","previousGeneration":0}'))
        $result=&$module {param($Install,$Runtime)Remove-CcodVerifiedProductResidue -InstallRoot $Install -SelectedRuntimeId $Runtime -ExpectedEpoch ([uint64]11)} $install $runtimeId
        Assert-CcodEqual 'Removed' $result.result 'actual installer initialization records are recognized'
    } finally {if($null-ne$fileTransaction){Close-CcodInstallFileTransaction -Transaction $fileTransaction -Disposition Failed|Out-Null};foreach($m in @($installModule,$fileModule)){if($null-ne$m){Remove-Module $m -Force -ErrorAction SilentlyContinue}};if(Test-Path $root){Remove-Item $root -Recurse -Force}}
}

function Invoke-CcodFullInstallerResidueCase {
    param([switch]$LegacyUpgrade)
    $root=Join-Path $env:TEMP ('ccod-product-real-writers-'+[guid]::NewGuid().ToString('N'))
    $install=Join-Path $root 'CodexControlOtherDevices';$source=Join-Path $root 'source';$nodeRoot=Join-Path $root 'node'
    try {
        Import-Module (Join-Path $repositoryRoot 'src/persistence/modules/InstallLifecycle.psm1') -Force -DisableNameChecking
        Import-Module (Join-Path $repositoryRoot 'src/persistence/modules/StateStore.psm1') -Force -DisableNameChecking
        Import-Module (Join-Path $repositoryRoot 'src/persistence/modules/UiPreferences.psm1') -Force -DisableNameChecking
        Import-Module (Join-Path $repositoryRoot 'src/persistence/modules/RuntimeManifest.psm1') -Force -DisableNameChecking
        Import-Module (Join-Path $repositoryRoot 'src/persistence/modules/LifecycleEpoch.psm1') -Force -DisableNameChecking
        Import-Module (Join-Path $repositoryRoot 'src/persistence/modules/InstallFileTransaction.psm1') -DisableNameChecking
        New-CcodLifecycleSourceFixture -Root $source -Version '2.5.22'|Out-Null
        $fake=New-CcodLifecycleFake -NodePath (New-CcodLifecycleFakeNode -Root $nodeRoot)
        $productState=@{FailWrites=$false;Registration=$null;ReadyEvidence=$null;RetainedError=$null;Writes=0;ShortcutWrites=0;ProductOnlyObserved=$false;Shortcuts=@{}}
        Set-CcodLifecycleDefaultProductRegistrationFixture -Fake $fake -ProductState $productState
        [void]$fake.Adapters.Remove('WriteLog')
        if($LegacyUpgrade){
            $legacySource=Join-Path $root 'legacy-source'
            New-CcodLifecycleSourceFixture -Root $legacySource -Version '2.5.21'|Out-Null
            $legacy=New-CcodLifecycleV2521LegacyInstallFixture -InstallRoot $install -SourceRoot $legacySource
        }
        $receipt=Invoke-CcodInstall -SourceRoot $source -InstallRoot $install -SealedPackageSha256 ('c'*64) -Adapters $fake.Adapters
        Assert-CcodTrue $receipt.ProductRegistrationVerified 'real installer wrote a verified product state'
        $active=Read-CcodActiveRuntime -InstallRoot $install
        $runtime=Join-Path $install ('runtime/'+$active.activeRuntime)
        $manifestHash=Get-CcodTestFileSha256 (Join-Path $runtime 'manifest.json')
        &$module {param($Root,$Runtime,$Id,$Hash)Remove-CcodVerifiedGenerationTree -InstallRoot $Root -RuntimeRoot $Runtime -RuntimeId $Id -ExpectedManifestSha256 $Hash} $install $runtime $active.activeRuntime $manifestHash|Out-Null
        $lifecycle=Get-Module InstallLifecycle
        &$lifecycle {param($Root)$settings=Read-CcodSettings -StateRoot (Join-Path $Root 'state');$settings.automationEnabled=$false;Write-CcodSettings -StateRoot (Join-Path $Root 'state') -Settings $settings} $install
        [IO.File]::WriteAllText((Join-Path $install 'state/lifecycle-epoch.json'),'{"schemaVersion":1,"epoch":11}')
        $result=&$module {param($Root,$Id)Remove-CcodVerifiedProductResidue -InstallRoot $Root -SelectedRuntimeId $Id -ExpectedEpoch ([uint64]11)} $install $active.activeRuntime
        Assert-CcodEqual 'Removed' $result.result 'full installer output is recognized without a fabricated state layout'
    } finally {if(Test-Path $root){Remove-Item $root -Recurse -Force}}
}

$results+=Invoke-CcodTest 'bounded cleanup consumes the full actual installer output with isolated machine adapters' {Invoke-CcodFullInstallerResidueCase}
$results+=Invoke-CcodTest 'bounded cleanup consumes the historical v2521 upgrade output without retaining product files' {Invoke-CcodFullInstallerResidueCase -LegacyUpgrade}

$results+=Invoke-CcodTest 'an existing cleanup journal cannot authorize an unknown user file' {
    $root=Join-Path $env:TEMP ('ccod-product-journal-forgery-'+[guid]::NewGuid().ToString('N'))
    $install=Join-Path $root 'CodexControlOtherDevices';$native=$null
    try {
        [IO.Directory]::CreateDirectory((Join-Path $install 'state/active-generation'))|Out-Null
        $userFile=Join-Path $install 'my-project.txt';[IO.File]::WriteAllText($userFile,'user project must survive')
        $originalHash=Get-CcodTestFileSha256 $userFile
        $runtimeId='2.5.22-'+('a'*16)+'-'+('b'*32);$id='11111111-2222-3333-4444-555555555555'
        [IO.File]::WriteAllText((Join-Path $install 'state/lifecycle-epoch.json'),'{"schemaVersion":1,"epoch":11}')
        [IO.File]::WriteAllText((Join-Path $install 'state/active-generation/00000000000000000001.json'),('{"schemaVersion":1,"generation":1,"activeRuntime":"'+$runtimeId+'","previousGeneration":0}'))
        $directory=Join-Path $root ('CodexRemote-fix-uninstall/'+$id);[IO.Directory]::CreateDirectory($directory)|Out-Null
        $native=&$module {param([string]$Root)Initialize-CcodGenerationReclamationRuntime;Invoke-CcodGenerationReclamationStatic -Name OpenResidue -Arguments @($Root)} $install
        $identity=&$module {param($Native)Invoke-CcodGenerationReclamationMethod -Runtime $Native -Name RootIdentity -Arguments @()} $native
        $snapshot=&$module {param($Native)Invoke-CcodGenerationReclamationMethod -Runtime $Native -Name Snapshot -Arguments @()} $native
        $evidence=@($snapshot.Files|Where-Object {$_.Path.StartsWith('state/')}|ForEach-Object {[pscustomobject][ordered]@{path=$_.Path;text=(&$module {param($Native,[string]$Path)Invoke-CcodGenerationReclamationMethod -Runtime $Native -Name ReadFileText -Arguments @($Path)} $native $_.Path)}})
        $native.Dispose();$native=$null
        $plan=[pscustomobject][ordered]@{schemaVersion=1;transactionId=$id;installRoot=$install;runtimeId=$runtimeId;epoch=11;rootIdentity=$identity;files=@($snapshot.Files|ForEach-Object {[pscustomobject][ordered]@{path=$_.Path;length=$_.Length;sha256=$_.Sha256}});directories=@($snapshot.Directories);evidence=$evidence}
        [IO.File]::WriteAllText((Join-Path $directory 'product-residue-plan.json'),($plan|ConvertTo-Json -Depth 8 -Compress))
        Assert-CcodThrows {&$module {param($Root,$Runtime,$Directory,$Id)Remove-CcodVerifiedProductResidue -InstallRoot $Root -SelectedRuntimeId $Runtime -ExpectedEpoch ([uint64]11) -TransactionDirectory $Directory -TransactionId $Id} $install $runtimeId $directory $id|Out-Null} 'CCOD_PRODUCT_RESIDUE_INVALID'
        Assert-CcodEqual $originalHash (Get-CcodTestFileSha256 $userFile) 'forged journal cannot expand the approved deletion inventory'
    } finally {if($null-ne$native){$native.Dispose()};if(Test-Path $root){Remove-Item $root -Recurse -Force}}
}

function Invoke-CcodResiduePartialRetryCase {
    param([ValidateSet('None','AddedFile','ReplacementRoot','JournalMutation')][string]$Attack='None')
    $root=Join-Path $env:TEMP ('ccod-product-partial-'+[guid]::NewGuid().ToString('N'))
    $install=Join-Path $root 'CodexControlOtherDevices'
    try {
        [IO.Directory]::CreateDirectory((Join-Path $install 'state/active-generation'))|Out-Null
        [IO.Directory]::CreateDirectory((Join-Path $install 'runtime'))|Out-Null
        $runtimeId='2.5.22-'+('a'*16)+'-'+('b'*32);$id='11111111-2222-3333-4444-555555555555'
        [IO.File]::WriteAllText((Join-Path $install 'state/lifecycle-epoch.json'),'{"schemaVersion":1,"epoch":11}')
        [IO.File]::WriteAllText((Join-Path $install 'state/active-generation/00000000000000000001.json'),('{"schemaVersion":1,"generation":1,"activeRuntime":"'+$runtimeId+'","previousGeneration":0}'))
        $directory=Join-Path $root ('CodexRemote-fix-uninstall/'+$id);[IO.Directory]::CreateDirectory($directory)|Out-Null
        &$module {$script:CcodProductResidueFailCommitAtForTest=3}
        Assert-CcodThrows {&$module {param($Root,$Runtime,$Directory,$Id)Remove-CcodVerifiedProductResidue -InstallRoot $Root -SelectedRuntimeId $Runtime -ExpectedEpoch ([uint64]11) -TransactionDirectory $Directory -TransactionId $Id} $install $runtimeId $directory $id|Out-Null} 'CCOD_PRODUCT_RESIDUE_INVALID'
        Assert-CcodTrue (Test-Path $install) 'partial commit retains the same native root'
        Assert-CcodTrue (-not(Test-Path (Join-Path $install 'state/lifecycle-epoch.json'))) 'failure happens after native files were actually deleted'
        Assert-CcodTrue (Test-Path (Join-Path $directory 'product-residue-plan.json')) 'write-ahead plan survives actual partial deletion'
        &$module {$script:CcodProductResidueFailCommitAtForTest=-1}
        if($Attack-cne'None'){
            switch($Attack){
                'AddedFile' {[IO.File]::WriteAllText((Join-Path $install 'my-project.txt'),'added after partial cleanup')}
                'ReplacementRoot' {$parked=Join-Path $root 'original-product-root';[IO.Directory]::Move($install,$parked);[IO.Directory]::CreateDirectory($install)|Out-Null}
                'JournalMutation' {$planPath=Join-Path $directory 'product-residue-plan.json';$plan=[IO.File]::ReadAllText($planPath)|ConvertFrom-Json;$plan.runtimeId='2.5.22-'+('c'*16)+'-'+('d'*32);[IO.File]::WriteAllText($planPath,($plan|ConvertTo-Json -Depth 12 -Compress))}
            }
            Assert-CcodThrows {&$module {param($Root,$Runtime,$Directory,$Id)Remove-CcodVerifiedProductResidue -InstallRoot $Root -SelectedRuntimeId $Runtime -ExpectedEpoch ([uint64]11) -TransactionDirectory $Directory -TransactionId $Id} $install $runtimeId $directory $id|Out-Null} 'CCOD_PRODUCT_RESIDUE_INVALID'
            Assert-CcodTrue (Test-Path $install) 'changed retry target is not removed'
            if($Attack-ceq'AddedFile'){Assert-CcodEqual 'added after partial cleanup' ([IO.File]::ReadAllText((Join-Path $install 'my-project.txt'))) 'new user file is untouched'}
            return
        }
        $result=&$module {param($Root,$Runtime,$Directory,$Id)Remove-CcodVerifiedProductResidue -InstallRoot $Root -SelectedRuntimeId $Runtime -ExpectedEpoch ([uint64]11) -TransactionDirectory $Directory -TransactionId $Id} $install $runtimeId $directory $id
        Assert-CcodEqual 'Removed' $result.result 'same-root retry validates the saved inventory and completes'
        Assert-CcodTrue (-not(Test-Path $install)) 'retried cleanup removes the exact residual root'
    } finally {&$module {$script:CcodProductResidueFailCommitAtForTest=-1};if(Test-Path $root){Remove-Item $root -Recurse -Force}}
}

$results+=Invoke-CcodTest 'bounded cleanup resumes the exact residual tree after a native partial commit failure' {Invoke-CcodResiduePartialRetryCase}
foreach($retryAttack in @('AddedFile','ReplacementRoot','JournalMutation')){
    $results+=Invoke-CcodTest "bounded cleanup refuses $retryAttack on a real partial-commit retry" {Invoke-CcodResiduePartialRetryCase -Attack $retryAttack}
}

$results+=Invoke-CcodTest 'bounded cleanup accepts real epoch initialization and supervisor log writers' {
    $root=Join-Path $env:TEMP ('ccod-product-observation-'+[guid]::NewGuid().ToString('N'))
    $install=Join-Path $root 'CodexControlOtherDevices'
    try {
        [IO.Directory]::CreateDirectory((Join-Path $install 'state/active-generation'))|Out-Null
        [IO.Directory]::CreateDirectory((Join-Path $install 'state/workers'))|Out-Null
        $runtimeId='2.5.22-'+('a'*16)+'-'+('b'*32)
        [IO.File]::WriteAllText((Join-Path $install 'state/active-generation/00000000000000000001.json'),('{"schemaVersion":1,"generation":1,"activeRuntime":"'+$runtimeId+'","previousGeneration":0}'))
        $epochModule=Import-Module (Join-Path $repositoryRoot 'src/persistence/modules/LifecycleEpoch.psm1') -Force -PassThru -DisableNameChecking
        &$epochModule {param($Root)Write-CcodLifecycleEpoch -InstallRoot $Root -Epoch ([uint64]11)} $install
        . (Join-Path $repositoryRoot 'src/persistence/Supervisor.ps1') -ReadyToken ('a'*64)
        $io=Import-Module (Join-Path $repositoryRoot 'src/persistence/modules/PersistenceIO.psm1') -PassThru -DisableNameChecking
        $hostState=[pscustomobject]@{RuntimeCleanupCodes=[Collections.Generic.List[string]]::new()}
        $log=Join-Path $install 'logs/supervisor.log'
        $adapters=@{GetUtcNow={[DateTime]::UtcNow};WriteLog={param($Record)&$io {param($Path,$Value)Write-CcodRotatingLog -Path $Path -Message ($Value|ConvertTo-Json -Depth 8 -Compress)} $log $Record}.GetNewClosure()}
        Write-CcodSupervisorUiFailure -HostState $hostState -Adapters $adapters -Stage LanguageChange -Code 'CCOD_LANGUAGE_CHANGE_FAILED'
        $action=[pscustomobject]@{Command='ShowAbout';Revision=[uint64]1}
        Assert-CcodTrue (Write-CcodSupervisorTrayActionTerminal -HostState $hostState -Adapters $adapters -Action $action -Status Completed -ErrorCode $null) 'actual Supervisor log producer succeeded'
        Assert-CcodEqual 0 $hostState.RuntimeCleanupCodes.Count 'log writing itself succeeded'
        $result=&$module {param($Root,$Id)Remove-CcodVerifiedProductResidue -InstallRoot $Root -SelectedRuntimeId $Id -ExpectedEpoch ([uint64]11)} $install $runtimeId
        Assert-CcodEqual 'Removed' $result.result 'product diagnostics and epoch initializer are recognized'
    } finally {if(Test-Path $root){Remove-Item $root -Recurse -Force}}
}

$results+=Invoke-CcodTest 'protected user data is rejected before opening or hashing its contents' {
    $root=Join-Path $env:TEMP ('ccod-product-protected-'+[guid]::NewGuid().ToString('N'))
    $install=Join-Path $root 'CodexControlOtherDevices';$held=$null
    try {
        [IO.Directory]::CreateDirectory((Join-Path $install 'state/device-key'))|Out-Null
        $file=Join-Path $install 'state/device-key/sentinel.bin';[IO.File]::WriteAllText($file,'synthetic protected sentinel')
        $held=[IO.File]::Open($file,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        $failure=$null
        try {&$module {param($Root)Remove-CcodVerifiedProductResidue -InstallRoot $Root -SelectedRuntimeId ('2.5.22-'+('a'*16)+'-'+('b'*32)) -ExpectedEpoch ([uint64]11)} $install|Out-Null}catch{$failure=$_}
        Assert-CcodTrue ($null-ne$failure-and$failure.Exception.Message.Contains('protected user data')) 'policy rejects the directory name before the exclusive file can cause a read error'
    } finally {if($null-ne$held){$held.Dispose()};if(Test-Path $root){Remove-Item $root -Recurse -Force}}
}

$results+=Invoke-CcodTest 'bounded cleanup accepts actual terminal lifecycle receipts and transaction archive output' {
    $root=Join-Path $env:TEMP ('ccod-product-terminal-'+[guid]::NewGuid().ToString('N'))
    $install=Join-Path $root 'CodexControlOtherDevices';$state=Join-Path $install 'state'
    try {
        [IO.Directory]::CreateDirectory((Join-Path $state 'active-generation'))|Out-Null
        $runtimeId='2.5.22-'+('a'*16)+'-'+('b'*32);$id='11111111-2222-3333-4444-555555555555'
        [IO.File]::WriteAllText((Join-Path $state 'lifecycle-epoch.json'),'{"schemaVersion":1,"epoch":11}')
        [IO.File]::WriteAllText((Join-Path $state 'active-generation/00000000000000000001.json'),('{"schemaVersion":1,"generation":1,"activeRuntime":"'+$runtimeId+'","previousGeneration":0}'))
        $lifecycle=Import-Module (Join-Path $repositoryRoot 'src/persistence/modules/LifecycleTransaction.psm1') -Force -PassThru -DisableNameChecking
        $logon=Import-Module (Join-Path $repositoryRoot 'src/persistence/modules/TrustedLogonIdentity.psm1') -Force -PassThru -DisableNameChecking
        $inbox=Import-Module (Join-Path $repositoryRoot 'src/persistence/modules/LifecycleRequest.psm1') -Force -PassThru -DisableNameChecking
        $journal=Import-Module (Join-Path $repositoryRoot 'src/persistence/modules/TransitionJournal.psm1') -Force -PassThru -DisableNameChecking
        $io=Import-Module (Join-Path $repositoryRoot 'src/persistence/modules/PersistenceIO.psm1') -PassThru -DisableNameChecking
        $identity=&$logon {Get-CcodTrustedLogonIdentity}
        $now=[DateTime]::UtcNow.ToString('o',[Globalization.CultureInfo]::InvariantCulture)
        $request=&$lifecycle {param($Root,$Id,$Runtime,$Identity,$Now)
            $owner=[pscustomobject]@{pid=[int]$PID;creationTimeUtc=[Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().ToString('o')}
            $value=New-CcodLifecycleRequest -Kind SafeExit -Origin Tray -RuntimeId $Runtime -RuntimeGeneration 1 -LeaseEpoch 11 -OwnerIdentity $owner -LogonIdentity $Identity -NowUtc $Now -TransactionId $Id
            $value.phase='CancelledBeforeClose'
            Write-CcodLifecycleRequest -StateRoot $Root -Request $value
            Complete-CcodLifecycleRequest -StateRoot $Root -Request $value
            $value
        } $state $id $runtimeId $identity $now
        &$logon {param($Root,$Identity,$Runtime,$Id,$Now)Write-CcodSafeExitIntent -StateRoot $Root -LogonIdentity $Identity -RuntimeId $Runtime -RecoveryTransactionId $Id -NowUtc $Now} $state $identity $runtimeId $id $now|Out-Null
        &$inbox {param($Root,$Id)Write-CcodLifecycleSubmissionReceipt -StateRoot $Root -SubmissionId $Id -Accepted $true -TransactionId $Id -ErrorCode $null} $state $id|Out-Null
        $transition=[pscustomobject]@{transactionId=$id;stage='Closed';sourcePid=$null;sourceCreationTimeUtc=$null;specialPid=$null;specialCreationTimeUtc=$null;recoveryPid=$null;recoveryCreationTimeUtc=$null;appAsarSha256=('a'*64);runtimeId=$runtimeId}
        $archive=&$journal {param($Transition,$Now)New-CcodArchiveRecord -Transition $Transition -Disposition Closed -CompletedAtUtc $Now} $transition $now
        $completion=&$journal {param($Id,$Now)New-CcodCompletionReceipt -TransactionId $Id -Disposition Closed -TerminalStage Closed -CompletedAtUtc $Now -State Archived -ArchiveErrorId $null} $id $now
        &$io {param($Root,$Archive,$Completion)Write-CcodRotatingLog -Path (Join-Path $Root 'logs/transactions.log') -Message ($Archive|ConvertTo-Json -Depth 8 -Compress);Write-CcodAtomicJson -Path (Join-Path $Root 'state/transaction-completion.receipt.json') -Value $Completion -Compress} $install $archive $completion
        $result=&$module {param($Root,$Runtime)Remove-CcodVerifiedProductResidue -InstallRoot $Root -SelectedRuntimeId $Runtime -ExpectedEpoch ([uint64]11)} $install $runtimeId
        Assert-CcodEqual 'Removed' $result.result 'actual completed lifecycle evidence is disposable product state'
    } finally {if(Test-Path $root){Remove-Item $root -Recurse -Force}}
}

$results+=Invoke-CcodTest 'bounded cleanup accepts real session and legacy install diagnostic writers' {
    $root=Join-Path $env:TEMP ('ccod-product-session-log-'+[guid]::NewGuid().ToString('N'))
    $install=Join-Path $root 'CodexControlOtherDevices'
    try {
        [IO.Directory]::CreateDirectory((Join-Path $install 'state/active-generation'))|Out-Null
        $runtimeId='2.5.22-'+('a'*16)+'-'+('b'*32);$id='11111111-2222-3333-4444-555555555555'
        [IO.File]::WriteAllText((Join-Path $install 'state/lifecycle-epoch.json'),'{"schemaVersion":1,"epoch":11}')
        [IO.File]::WriteAllText((Join-Path $install 'state/active-generation/00000000000000000001.json'),('{"schemaVersion":1,"generation":1,"activeRuntime":"'+$runtimeId+'","previousGeneration":0}'))
        . (Join-Path $repositoryRoot 'src/persistence/SessionController.ps1') -Action Inspect
        $engine=Import-Module (Join-Path $repositoryRoot 'src/persistence/modules/SessionEngine.psm1') -PassThru -DisableNameChecking
        $io=Import-Module (Join-Path $repositoryRoot 'src/persistence/modules/PersistenceIO.psm1') -PassThru -DisableNameChecking
        $paths=[pscustomobject]@{SessionLogPath=(Join-Path $install 'logs/session.log')}
        $adapter=@{UtcNow={[DateTime]::UtcNow};WriteLog={param($Path,$Message)&$io {param($P,$M)Write-CcodRotatingLog -Path $P -Message $M} $Path $Message}.GetNewClosure()}
        $result=[pscustomobject]@{action='Inspect';transactionId=$id;stage='Inspect';error=[pscustomobject]@{code='CCOD_SESSION_FAILED'};logFile=$null}
        Assert-CcodTrue (Write-CcodControllerDiagnostic -Result $result -Request $null -Paths $paths -Adapter $adapter) 'actual controller diagnostic is written'
        &$engine {param($Result,$Id,$Paths,$Adapter)Write-CcodSessionDiagnostic -Result $Result -Action Inspect -TransactionId $Id -Stage Inspect -Code CCOD_SESSION_FAILED -Record $null -Paths $Paths -Adapter $Adapter} $result $id $paths $adapter
        $lifecycle=Import-Module (Join-Path $repositoryRoot 'src/persistence/modules/InstallLifecycle.psm1') -Force -PassThru -DisableNameChecking
        &$lifecycle {param($Root)$adapter=Get-CcodLifecycleAdapters;Write-CcodLifecycleLog -InstallRoot $Root -Adapters $adapter -Stage Install -Code CCOD_INSTALL_COMPLETED -Outcome Installed -ThrowOnFailure} $install
        $result=&$module {param($Root,$Id)Remove-CcodVerifiedProductResidue -InstallRoot $Root -SelectedRuntimeId $Id -ExpectedEpoch ([uint64]11)} $install $runtimeId
        Assert-CcodEqual 'Removed' $result.result 'actual session and legacy install diagnostics are recognized'
    } finally {if(Test-Path $root){Remove-Item $root -Recurse -Force}}
}

$results+=Invoke-CcodTest 'bounded cleanup accepts the exact abandoned-lease warning produced by Supervisor' {
    $root=Join-Path $env:TEMP ('ccod-product-warning-'+[guid]::NewGuid().ToString('N'))
    $install=Join-Path $root 'CodexControlOtherDevices'
    try {
        [IO.Directory]::CreateDirectory((Join-Path $install 'state/active-generation'))|Out-Null
        $runtimeId='2.5.22-'+('a'*16)+'-'+('b'*32)
        [IO.File]::WriteAllText((Join-Path $install 'state/lifecycle-epoch.json'),'{"schemaVersion":1,"epoch":11}')
        [IO.File]::WriteAllText((Join-Path $install 'state/active-generation/00000000000000000001.json'),('{"schemaVersion":1,"generation":1,"activeRuntime":"'+$runtimeId+'","previousGeneration":0}'))
        $supervisorPath=Join-Path $repositoryRoot 'src/persistence/Supervisor.ps1'
        . $supervisorPath -ReadyToken ('a'*64)
        $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($supervisorPath,[ref]$tokens,[ref]$errors)
        Assert-CcodEqual 0 @($errors).Count 'real supervisor source parses'
        $writer=@($ast.FindAll({param($n)$n-is[Management.Automation.Language.AssignmentStatementAst]-and$n.Left.Extent.Text-ceq'$record'-and$n.Right.Extent.Text.Contains("code='CCOD_SUPERVISOR_LEASE_ABANDONED'")},$true))
        Assert-CcodEqual 1 $writer.Count 'one exact production warning producer'
        $adapter=@{GetUtcNow={[DateTime]::UtcNow}}
        $record=&([scriptblock]::Create($writer[0].Right.Extent.Text))
        Assert-CcodEqual 'Warning' $record.outcome 'production outcome is Warning'
        $io=Import-Module (Join-Path $repositoryRoot 'src/persistence/modules/PersistenceIO.psm1') -PassThru -DisableNameChecking
        foreach($changedField in @('stage','code')){
            $bad=$record|ConvertTo-Json -Compress|ConvertFrom-Json
            if($changedField-ceq'stage'){$bad.stage='OtherStage'}else{$bad.code='CCOD_OTHER_WARNING'}
            &$io {param($Root,$Value)Write-CcodRotatingLog -Path (Join-Path $Root 'logs/supervisor.log') -Message ($Value|ConvertTo-Json -Compress)} $install $bad
            Assert-CcodThrows {&$module {param($Root,$Runtime)Remove-CcodVerifiedProductResidue -InstallRoot $Root -SelectedRuntimeId $Runtime -ExpectedEpoch ([uint64]11)} $install $runtimeId|Out-Null} 'CCOD_PRODUCT_RESIDUE_INVALID'
            Assert-CcodTrue (Test-Path (Join-Path $install 'state/lifecycle-epoch.json')) 'unsupported Warning remains rejected before deletion'
            [IO.File]::Delete((Join-Path $install 'logs/supervisor.log'))
        }
        &$io {param($Root,$Value)Write-CcodRotatingLog -Path (Join-Path $Root 'logs/supervisor.log') -Message ($Value|ConvertTo-Json -Compress)} $install $record
        $result=&$module {param($Root,$Runtime)Remove-CcodVerifiedProductResidue -InstallRoot $Root -SelectedRuntimeId $Runtime -ExpectedEpoch ([uint64]11)} $install $runtimeId
        Assert-CcodEqual 'Removed' $result.result 'real abandoned-lease diagnostic does not block uninstall'
    } finally {if(Test-Path $root){Remove-Item $root -Recurse -Force}}
}

$results|ForEach-Object {"PASS $($_.Name)"}
Write-Output "Product residue cleanup self-tests passed: $($results.Count)"
