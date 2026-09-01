$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestSupport.ps1')

$repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$modulePath = Join-Path $repositoryRoot 'src\persistence\modules\ProductRegistration.psm1'
if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
    throw "ProductRegistration module is missing: $modulePath"
}
$module=Import-Module $modulePath -Force -PassThru

$runtimeId = '2.5.22-1111111111111111-22222222222222222222222222222222'
$packageSha256 = '3' * 64
$appId = '{2B9E9F2E-7A32-4A7E-9C1D-9F5B5C6D7E8F}'
$canonicalTaskTarget=[IO.Path]::GetFullPath((Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::System)) 'schtasks.exe'))
$cleanupReady=[pscustomobject][ordered]@{phase='Ready';installRoot='C:\fixture\CodexControlOtherDevices';runtimeId=$runtimeId;runtimeGeneration=[uint64]7;packageSha256=$packageSha256;manifestSha256=('a'*64);startMenuSha256=('b'*64);desktopSha256=('c'*64);targetPath=$canonicalTaskTarget;arguments='/Run /TN "Codex Control Other Devices Supervisor"'}
$fullReadyRecord=[pscustomobject][ordered]@{schemaVersion=1;transactionId='11111111-2222-3333-4444-555555555555';oldRuntimeId=$null;oldGeneration=$null;oldManifestSha256=$null;newRuntimeId=$runtimeId;newGeneration=[uint64]7;newManifestSha256=('a'*64);sealedPackageSha256=$packageSha256;ownedObjectNames=@($runtimeId);phase='Ready';errorCode=$null}

function New-CcodRegistrationWorld {
    param([string]$InstallRoot = 'C:\fixture\CodexControlOtherDevices')

    $registration = New-CcodProductRegistration -InstallRoot $InstallRoot -RuntimeId $runtimeId -Version '2.5.22' -PackageSha256 $packageSha256 -FileTransaction ([pscustomobject]@{})
    $legacyEntries=[Collections.Generic.List[string]]::new();foreach($entry in @('Registry','StartMenu1','StartMenu2','StartMenu3','StartMenu4','StartMenu5','StartMenu6','StartMenu7','Desktop')){$legacyEntries.Add($entry)}
    $world = [pscustomobject]@{
        Registration = $registration
        Ready = [pscustomobject][ordered]@{
            phase = 'Ready'
            runtimeId = $runtimeId
            version = '2.5.22'
            packageSha256 = $packageSha256
            runtimeGeneration = [uint64]7
            manifestSha256 = 'a'*64
            startMenuSha256 = 'b'*64
            desktopSha256 = 'c'*64
            targetPath = $canonicalTaskTarget
            arguments = '/Run /TN "Codex Control Other Devices Supervisor"'
            transactionRecord = $fullReadyRecord
            bootstrapPath = $registration.bootstrapPath
            uninstallerPath = $registration.uninstallerPath
        }
        Product = $null
        Shortcuts = @{}
        WriteProductFailure = $false
        WriteShortcutFailure = $null
        ReadProductFailure = $false
        ReadShortcutFailure = $null
        Legacy = [pscustomobject]@{
            appId = $appId
            uninstallString = '"C:\legacy\unins000.exe"'
            shortcutNames = @(
                'Programs\Codex Control other devices\Codex Control other devices for Windows.lnk',
                'Programs\Codex Control other devices\Open the tray supervisor.lnk',
                'Programs\Codex Control other devices\Compatibility check.lnk',
                'Programs\Codex Control other devices\Uninstall Codex Control other devices.lnk',
                'Programs\Codex Control other devices\CodexRemote-fix.lnk',
                'Programs\Codex Control other devices\CodexRemote-fix compatibility check.lnk',
                'Programs\Codex Control other devices\Uninstall CodexRemote-fix.lnk',
                ('Desktop\Codex ' + [char]0x8BBE + [char]0x5907 + [char]0x8FDE + [char]0x63A5 + ' (Device Connection).lnk')
            )
        }
        LegacyRemoved = $false
        LegacyRemovalCalls = 0
        CurrentProductRemovals = 0
        CurrentProductState = [pscustomobject]@{valid=$true;reason=$null;readyEvidence=$cleanupReady;entries=@('Registry','StartMenu','Desktop')}
        LegacyEntries = $legacyEntries
        LegacyRemoveFailureAt = 0
        LegacyRemoveAttempts = 0
        LegacyRestores = 0
        LegacyReplacementEntry = $null
        LegacyRestoreFailureEntry = $null
        LegacyUnresolvedRecords = [Collections.Generic.List[object]]::new()
        Calls = [Collections.Generic.List[string]]::new()
    }
    $world | Add-Member -NotePropertyName Adapters -NotePropertyValue @{
        GetReadyProof = { param($Registration) $world.Calls.Add('Ready'); $world.Ready }.GetNewClosure()
        WriteProductRegistration = {
            param($Registration)
            $world.Calls.Add('WriteProduct')
            if ($world.WriteProductFailure) { throw 'fixture product write failed' }
            $world.Product = $Registration
        }.GetNewClosure()
        ReadProductRegistration = {
            param($Registration)
            $world.Calls.Add('ReadProduct')
            if ($world.ReadProductFailure) { throw 'fixture product read failed' }
            $world.Product
        }.GetNewClosure()
        WriteShortcut = {
            param($Kind,$Shortcut,$FileTransaction)
            $world.Calls.Add("WriteShortcut:$Kind")
            if ($world.WriteShortcutFailure -ceq $Kind) { throw 'fixture shortcut write failed' }
            $world.Shortcuts[$Kind] = $Shortcut
        }.GetNewClosure()
        ReadShortcut = {
            param($Kind,$Shortcut)
            $world.Calls.Add("ReadShortcut:$Kind")
            if ($world.ReadShortcutFailure -ceq $Kind) { throw 'fixture shortcut read failed' }
            $world.Shortcuts[$Kind]
        }.GetNewClosure()
        ReadLegacyRegistration = { param($ExpectedAppId) $world.Calls.Add('ReadLegacy'); $world.Legacy }.GetNewClosure()
        ReadVerifiedRegistration = { [pscustomobject]@{verified=($null-ne$world.Product-and$world.Shortcuts.Count-eq2)} }.GetNewClosure()
        RemoveLegacyRegistration = { param($ExpectedAppId,$ExpectedShortcutNames) $world.Calls.Add('RemoveLegacy'); $world.LegacyRemovalCalls++; $world.LegacyRemoved = $true }.GetNewClosure()
        ReadCurrentProductState = { param($ExpectedRuntimeId) $world.CurrentProductState }.GetNewClosure()
        RemoveCurrentProductEntry = { param($Entry) $world.CurrentProductRemovals++ }.GetNewClosure()
        ReadLegacySnapshot = { param($ExpectedAppId);if($world.Legacy.appId-cne$ExpectedAppId){return [pscustomobject]@{appId=$world.Legacy.appId;entries=@($world.LegacyEntries)}};if(@($world.Legacy.shortcutNames).Count-ne8){return [pscustomobject]@{appId=$ExpectedAppId;entries=@('Unexpected')}};[pscustomobject]@{appId=$ExpectedAppId;entries=@($world.LegacyEntries)} }.GetNewClosure()
        RemoveLegacyEntry = { param($Entry);$world.LegacyRemoveAttempts++;if($world.LegacyRemoveFailureAt-eq$world.LegacyRemoveAttempts){throw 'fixture legacy delete failure'};[void]$world.LegacyEntries.Remove([string]$Entry) }.GetNewClosure()
        ReadLegacyEntry = { param($Entry);if($world.LegacyReplacementEntry-ceq[string]$Entry){return 'Mismatch'};if($world.LegacyEntries.Contains([string]$Entry)){'Exact'}else{$null} }.GetNewClosure()
        RestoreLegacyEntry = { param($Entry);if($world.LegacyRestoreFailureEntry-ceq[string]$Entry){throw 'fixture restore failed'};if(-not$world.LegacyEntries.Contains([string]$Entry)){$world.LegacyEntries.Add([string]$Entry)};$world.LegacyRestores++ }.GetNewClosure()
        WriteLegacyCompensationFailure = {param($Record)$world.LegacyUnresolvedRecords.Add($Record)}.GetNewClosure()
    }
    return $world
}

$results = @()

# Production mutation caught: accepting a caller-crafted path/runtime tuple as a registration contract.
$results += Invoke-CcodTest 'registration rejects noncanonical runtime version hash and install targets' {
    Assert-CcodThrows { New-CcodProductRegistration -InstallRoot 'relative' -RuntimeId $runtimeId -Version '2.5.22' -PackageSha256 $packageSha256 -FileTransaction ([pscustomobject]@{}) | Out-Null } 'CCOD_PRODUCT_REGISTRATION_INVALID'
    Assert-CcodThrows { New-CcodProductRegistration -InstallRoot 'C:\fixture\root' -RuntimeId 'runtime' -Version '2.5.22' -PackageSha256 $packageSha256 -FileTransaction ([pscustomobject]@{}) | Out-Null } 'CCOD_PRODUCT_REGISTRATION_INVALID'
    Assert-CcodThrows { New-CcodProductRegistration -InstallRoot 'C:\fixture\root' -RuntimeId $runtimeId -Version '2.5.21' -PackageSha256 $packageSha256 -FileTransaction ([pscustomobject]@{}) | Out-Null } 'CCOD_PRODUCT_REGISTRATION_INVALID'
    Assert-CcodThrows { New-CcodProductRegistration -InstallRoot 'C:\fixture\root' -RuntimeId $runtimeId -Version '2.5.22' -PackageSha256 ('A' * 64) -FileTransaction ([pscustomobject]@{}) | Out-Null } 'CCOD_PRODUCT_REGISTRATION_INVALID'
}

# Production mutation caught: allowing product writes from ProtectionReady or a mismatched Ready proof.
$results += Invoke-CcodTest 'registration performs no writes before an exact Ready proof' {
    foreach ($mutation in @(
        { param($ready) $ready.phase = 'ProtectionReady' },
        { param($ready) $ready.runtimeId = '2.5.22-aaaaaaaaaaaaaaaa-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' },
        { param($ready) $ready.version = '2.5.21' },
        { param($ready) $ready.packageSha256 = '4' * 64 },
        { param($ready) $ready.targetPath = 'C:\outside\task.exe' },
        { param($ready) $ready.bootstrapPath = 'C:\outside\bootstrap.ps1' },
        { param($ready) $ready.uninstallerPath = 'C:\outside\uninstall.ps1' }
    )) {
        $world = New-CcodRegistrationWorld
        & $mutation $world.Ready
        Assert-CcodThrows { Commit-CcodProductRegistration -Registration $world.Registration -FileTransaction ([pscustomobject]@{}) -Adapters $world.Adapters | Out-Null } 'CCOD_PRODUCT_REGISTRATION_NOT_READY'
        Assert-CcodEqual 0 @($world.Calls | Where-Object { $_ -clike 'Write*' }).Count 'a non-Ready proof cannot reach product writes'
        Assert-CcodEqual 0 $world.LegacyRemovalCalls 'a non-Ready proof cannot reach legacy removal'
    }
}

# Production mutation caught: deleting compatibility state after a partial new registration.
$results += Invoke-CcodTest 'write and read-back failures preserve every legacy entry and shortcut name' {
    foreach ($failure in @('WriteProduct','WriteStartMenu','WriteDesktop','ReadProduct','ReadStartMenu','ReadDesktop')) {
        $world = New-CcodRegistrationWorld
        switch ($failure) {
            'WriteProduct' { $world.WriteProductFailure = $true }
            'WriteStartMenu' { $world.WriteShortcutFailure = 'StartMenu' }
            'WriteDesktop' { $world.WriteShortcutFailure = 'Desktop' }
            'ReadProduct' { $world.ReadProductFailure = $true }
            'ReadStartMenu' { $world.ReadShortcutFailure = 'StartMenu' }
            'ReadDesktop' { $world.ReadShortcutFailure = 'Desktop' }
        }
        $legacyUninstallString = $world.Legacy.uninstallString
        $legacyShortcutNames = @($world.Legacy.shortcutNames)
        Assert-CcodThrows { Commit-CcodProductRegistration -Registration $world.Registration -FileTransaction ([pscustomobject]@{}) -Adapters $world.Adapters | Out-Null } 'CCOD_PRODUCT_REGISTRATION_FAILED'
        Assert-CcodEqual $legacyUninstallString $world.Legacy.uninstallString 'failure before read-back retains the legacy entry'
        Assert-CcodEqual ($legacyShortcutNames -join '|') (@($world.Legacy.shortcutNames) -join '|') 'failure before read-back retains exact legacy shortcut names'
        Assert-CcodEqual 0 $world.LegacyRemovalCalls 'failed registration never removes legacy state'
    }
}

# Production mutation caught: trusting a shortcut read-back that resolves outside the selected sealed generation.
$results += Invoke-CcodTest 'shortcut path and target mismatches fail the three-record read-back gate' {
    foreach ($kind in @('StartMenu','Desktop')) {
        $world = New-CcodRegistrationWorld
        $originalRead = $world.Adapters.ReadShortcut
        $world.Adapters.ReadShortcut = {
            param($candidateKind,$expected)
            $value = & $originalRead $candidateKind $expected
            if ($candidateKind -ceq $kind) {
                $value = $value.PSObject.Copy()
                $value.bootstrapPath = 'C:\outside\bootstrap.ps1'
            }
            $value
        }.GetNewClosure()
        Assert-CcodThrows { Commit-CcodProductRegistration -Registration $world.Registration -FileTransaction ([pscustomobject]@{}) -Adapters $world.Adapters | Out-Null } 'CCOD_PRODUCT_REGISTRATION_FAILED'
        Assert-CcodEqual 0 $world.LegacyRemovalCalls 'mismatched shortcut target retains legacy state'
    }
}

# Production mutation caught: considering adapter write success equivalent to durable read-back.
$results += Invoke-CcodTest 'valid Ready registration reads all three new records before exact legacy removal' {
    $world = New-CcodRegistrationWorld
    $receipt = Commit-CcodProductRegistration -Registration $world.Registration -FileTransaction ([pscustomobject]@{}) -Adapters $world.Adapters
    Assert-CcodTrue $receipt.verified 'registration returns a verified three-record receipt'
    Assert-CcodEqual 'Ready,WriteProduct,WriteShortcut:StartMenu,WriteShortcut:Desktop,ReadProduct,ReadShortcut:StartMenu,ReadShortcut:Desktop' ($world.Calls -join ',') 'all new writes and read-backs precede legacy migration'
    Remove-CcodLegacyProductRegistration -ExpectedAppId $appId -Adapters $world.Adapters
    Assert-CcodEqual 9 $world.LegacyRemoveAttempts 'exact legacy migration removes each approved entry once'
    Assert-CcodEqual 0 $world.LegacyEntries.Count 'exact legacy registration and shortcut set is removed'
}

# Production mutation caught: accepting an unexpected AppId/name set or an unverified registration receipt.
$results += Invoke-CcodTest 'legacy migration rejects AppId and shortcut-name mismatches without deletion' {
    foreach ($mismatch in @('AppId','Shortcut','Receipt')) {
        $world = New-CcodRegistrationWorld
        $receipt = Commit-CcodProductRegistration -Registration $world.Registration -FileTransaction ([pscustomobject]@{}) -Adapters $world.Adapters
        if ($mismatch -ceq 'AppId') { $world.Legacy.appId = '{AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE}' }
        if ($mismatch -ceq 'Shortcut') { $world.Legacy.shortcutNames = @('Programs\unexpected.lnk') }
        if ($mismatch -ceq 'Receipt') { $world.Product = $null }
        Assert-CcodThrows { Remove-CcodLegacyProductRegistration -ExpectedAppId $appId -Adapters $world.Adapters } 'CCOD_LEGACY_PRODUCT_REGISTRATION_INVALID'
        Assert-CcodEqual 0 $world.LegacyRemoveAttempts 'legacy mismatch is rejected before any deletion'
        Assert-CcodEqual 9 $world.LegacyEntries.Count 'legacy state remains intact on mismatch'
    }
}

# Production mutation caught: deleting a whole product key despite unknown values or mismatched shortcut evidence.
$results += Invoke-CcodTest 'current product cleanup requires exact registry values and shortcut bytes targets and file identity' {
    foreach($mutation in @('UnknownRegistryValue','RegistrySubkey','ShortcutHash','ShortcutTarget','ShortcutReparse','Ambiguous','CoherentReplacement')){
        $world=New-CcodRegistrationWorld;$world.CurrentProductState.valid=$false;$world.CurrentProductState.reason=$mutation
        Assert-CcodThrows {Remove-CcodProductRegistration -ReadyEvidence $cleanupReady -Adapters $world.Adapters} 'CCOD_PRODUCT_CLEANUP_INVALID'
        Assert-CcodEqual 0 $world.CurrentProductRemovals "$mutation mismatch preserves every current product entry"
    }
    $world=New-CcodRegistrationWorld
    Remove-CcodProductRegistration -ReadyEvidence $cleanupReady -Adapters $world.Adapters
    Assert-CcodEqual 3 $world.CurrentProductRemovals 'matched cleanup removes only the exact registry and two shortcut entries'
    $wrong=$cleanupReady.PSObject.Copy();$wrong.targetPath='C:\outside\task.exe';$world=New-CcodRegistrationWorld;$world.CurrentProductState.readyEvidence=$wrong
    Assert-CcodThrows {Remove-CcodProductRegistration -ReadyEvidence $wrong -Adapters $world.Adapters} 'CCOD_PRODUCT_CLEANUP_INVALID'
    Assert-CcodEqual 0 $world.CurrentProductRemovals 'coherent arbitrary target evidence cannot authorize cleanup'
}

# Production mutation caught: the registry reader starts reading shortcut evidence even though an unknown
# product subkey already makes the entire current registration ambiguous.
$results += Invoke-CcodTest 'current product registry preflight rejects a subkey before returning shortcut entries' {
    $allowed=@('CcodRuntimeId','DisplayVersion')
    $accepted=&$module {param($ValueNames,$SubKeyNames,$Allowed)Test-CcodCurrentProductRegistryPreflight -ValueNames $ValueNames -SubKeyNames $SubKeyNames -AllowedValueNames $Allowed} $allowed @('unexpected-child') $allowed
    Assert-CcodEqual $false $accepted 'an unknown subkey invalidates the complete state before shortcut evidence is read'
    $world=New-CcodRegistrationWorld;$world.CurrentProductState.valid=$accepted;$world.CurrentProductState.entries=@()
    Assert-CcodThrows {Remove-CcodProductRegistration -ReadyEvidence $cleanupReady -Adapters $world.Adapters} 'CCOD_PRODUCT_CLEANUP_INVALID'
    Assert-CcodEqual 0 $world.CurrentProductRemovals 'subkey preflight failure performs zero removals'
}

# Production mutation caught: a mid-sequence legacy deletion failure leaves earlier exact entries missing.
$results += Invoke-CcodTest 'legacy migration restores earlier exact deletions after a later deletion failure' {
    $world=New-CcodRegistrationWorld
    $receipt=Commit-CcodProductRegistration -Registration $world.Registration -FileTransaction ([pscustomobject]@{}) -Adapters $world.Adapters
    $before=@($world.LegacyEntries)|Sort-Object
    $world.LegacyRemoveFailureAt=4
    Assert-CcodThrows {Remove-CcodLegacyProductRegistration -ExpectedAppId $appId -Adapters $world.Adapters} 'CCOD_LEGACY_PRODUCT_REGISTRATION_INVALID'
    Assert-CcodEqual ($before-join'|') ((@($world.LegacyEntries)|Sort-Object)-join'|') 'failed migration restores the complete exact legacy set'
    Assert-CcodEqual 3 $world.LegacyRestores 'only successfully removed entries are restored'
}

$results += Invoke-CcodTest 'legacy compensation never overwrites a replacement that appeared after deletion' {
    $world=New-CcodRegistrationWorld;$null=Commit-CcodProductRegistration -Registration $world.Registration -FileTransaction ([pscustomobject]@{}) -Adapters $world.Adapters;$world.LegacyRemoveFailureAt=4;$world.LegacyReplacementEntry='StartMenu1'
    Assert-CcodThrows {Remove-CcodLegacyProductRegistration -ExpectedAppId $appId -Adapters $world.Adapters} 'CCOD_LEGACY_PRODUCT_COMPENSATION_FAILED'
    Assert-CcodEqual 2 $world.LegacyRestores 'compensation restores only entries that remain absent'
    Assert-CcodTrue (-not$world.LegacyEntries.Contains('StartMenu1')) 'replacement occupies the removed name and is not overwritten with captured bytes'
    Assert-CcodEqual 1 $world.LegacyUnresolvedRecords.Count 'replacement-blocked restoration is recorded explicitly'
}

$results += Invoke-CcodTest 'legacy restore failure is explicit and records the unresolved exact entries' {
    $world=New-CcodRegistrationWorld;$null=Commit-CcodProductRegistration -Registration $world.Registration -FileTransaction ([pscustomobject]@{}) -Adapters $world.Adapters;$world.LegacyRemoveFailureAt=4;$world.LegacyRestoreFailureEntry='StartMenu2'
    Assert-CcodThrows {Remove-CcodLegacyProductRegistration -ExpectedAppId $appId -Adapters $world.Adapters} 'CCOD_LEGACY_PRODUCT_COMPENSATION_FAILED'
    Assert-CcodEqual 1 $world.LegacyUnresolvedRecords.Count 'failed compensation writes one explicit unresolved record'
    Assert-CcodTrue (@($world.LegacyUnresolvedRecords[0].entries)-ccontains'StartMenu2') 'unresolved record names the exact entry whose restoration failed'
}

$results += Invoke-CcodTest 'partially removed current registry entry is included in unresolved compensation' {
    $world=New-CcodRegistrationWorld;$null=Commit-CcodProductRegistration -Registration $world.Registration -FileTransaction ([pscustomobject]@{}) -Adapters $world.Adapters;$world.LegacyRemoveFailureAt=1;$world.LegacyRestoreFailureEntry='Registry';$originalRemove=$world.Adapters.RemoveLegacyEntry;$world.Adapters.RemoveLegacyEntry={param($Entry)if([string]$Entry-ceq'Registry'){[void]$world.LegacyEntries.Remove('Registry');throw 'partial registry failure'};&$originalRemove $Entry}.GetNewClosure()
    Assert-CcodThrows {Remove-CcodLegacyProductRegistration -ExpectedAppId $appId -Adapters $world.Adapters} 'CCOD_LEGACY_PRODUCT_COMPENSATION_FAILED'
    Assert-CcodTrue (@($world.LegacyUnresolvedRecords[0].entries)-ccontains'Registry') 'current partially removed registry entry is recorded unresolved'
}

$results += Invoke-CcodTest 'legacy registry snapshot comparison treats a present partial key as unresolved compensation' {
    $captured=[pscustomobject]@{kind='Registry';path='HKCU:\fixture';values=[ordered]@{DisplayName=[pscustomobject]@{value='Codex';kind='String'};NoModify=[pscustomobject]@{value=1;kind='DWord'}}}
    $partial=[pscustomobject]@{kind='Registry';path='HKCU:\fixture';values=[ordered]@{DisplayName=[pscustomobject]@{value='Codex';kind='String'}}}
    $state=&$module {param($Expected,$Current)Compare-CcodLegacySnapshotEntry -Expected $Expected -Current $Current} $captured $partial
    Assert-CcodEqual 'Mismatch' $state 'a still-present key missing one captured value is not restored'
    $world=New-CcodRegistrationWorld;$null=Commit-CcodProductRegistration -Registration $world.Registration -FileTransaction ([pscustomobject]@{}) -Adapters $world.Adapters;$world.LegacyRemoveFailureAt=1;$world.Adapters.RemoveLegacyEntry={param($Entry)if([string]$Entry-ceq'Registry'){throw 'partial registry removal and internal restore failed'}};$world.Adapters.ReadLegacyEntry={param($Entry)if([string]$Entry-ceq'Registry'){return $state};if($world.LegacyEntries.Contains([string]$Entry)){return 'Exact'};$null}.GetNewClosure()
    Assert-CcodThrows {Remove-CcodLegacyProductRegistration -ExpectedAppId $appId -Adapters $world.Adapters} 'CCOD_LEGACY_PRODUCT_COMPENSATION_FAILED'
    Assert-CcodTrue (@($world.LegacyUnresolvedRecords[0].entries)-ccontains'Registry') 'partial registry key is persisted in the unresolved create-only record'
}

Write-Output "Product registration self-tests passed: $($results.Count)"
