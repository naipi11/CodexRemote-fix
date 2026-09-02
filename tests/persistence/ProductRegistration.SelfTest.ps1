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
$v210ShortcutNames = @(
    'Programs\Codex Control other devices\Codex Control other devices for Windows.lnk',
    'Programs\Codex Control other devices\Open the tray supervisor.lnk',
    'Programs\Codex Control other devices\Compatibility check.lnk',
    'Programs\Codex Control other devices\Uninstall Codex Control other devices.lnk'
)
$v211ShortcutNames = @($v210ShortcutNames) + @(
    ('Desktop\Codex ' + [char]0x8BBE + [char]0x5907 + [char]0x8FDE + [char]0x63A5 + ' (Device Connection).lnk')
)
$v2521ShortcutNames = @(
    'Programs\CodexRemote-fix\CodexRemote-fix.lnk',
    'Programs\CodexRemote-fix\CodexRemote-fix compatibility check.lnk',
    'Programs\CodexRemote-fix\Uninstall CodexRemote-fix.lnk',
    'Desktop\CodexRemote-fix.lnk'
)
$currentShortcutNames=@($v2521ShortcutNames[0],$v2521ShortcutNames[3])
$legacyInstallLocation = 'C:\legacy\CodexControlOtherDevices-installer'

function New-CcodLegacyRegistrationFixture {
    param(
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string[]]$ShortcutNames,
        [string]$AppId = $appId,
        [string]$InstallLocation = $legacyInstallLocation,
        [string]$UninstallString = ('"{0}\unins000.exe"' -f $legacyInstallLocation),
        [string[]]$UnsafeShortcutNames = @()
    )
    [pscustomobject][ordered]@{
        appId = $AppId
        displayVersion = $Version
        installLocation = $InstallLocation
        uninstallString = $UninstallString
        shortcutNames = @($ShortcutNames)
        unsafeShortcutNames = @($UnsafeShortcutNames)
    }
}

function New-CcodRegistrationWorld {
    param([string]$InstallRoot = 'C:\fixture\CodexControlOtherDevices')

    $registration = New-CcodProductRegistration -InstallRoot $InstallRoot -RuntimeId $runtimeId -Version '2.5.22' -PackageSha256 $packageSha256 -FileTransaction ([pscustomobject]@{})
    $legacyEntries=[Collections.Generic.List[string]]::new();foreach($entry in @('Registry')+$v2521ShortcutNames){$legacyEntries.Add($entry)}
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
        Legacy = New-CcodLegacyRegistrationFixture -Version '2.5.21' -ShortcutNames $v2521ShortcutNames
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
        LegacyRestoreOrder = [Collections.Generic.List[string]]::new()
        VerifiedRegistrationReads = 0
        VerifiedRegistrationMutationAt = 0
        LegacySnapshotHashOverrides = @{}
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
        ReadLegacyRegistration = { param($ExpectedAppId) $world.Calls.Add('ReadLegacy');if($world.LegacyEntries.Contains('Registry')){$world.Legacy}else{$null} }.GetNewClosure()
        ReadVerifiedRegistration = {
            $world.VerifiedRegistrationReads++
            $startMenuSha256=if($world.VerifiedRegistrationMutationAt-eq$world.VerifiedRegistrationReads){'d'*64}else{'b'*64}
            [pscustomobject][ordered]@{
                verified=($null-ne$world.Product-and$world.Shortcuts.Count-eq2);runtimeId=$runtimeId;version='2.5.22';packageSha256=$packageSha256
                shortcutNames=@($currentShortcutNames);startMenuSha256=$startMenuSha256;desktopSha256=('c'*64)
            }
        }.GetNewClosure()
        RemoveLegacyRegistration = { param($ExpectedAppId,$ExpectedShortcutNames) $world.Calls.Add('RemoveLegacy'); $world.LegacyRemovalCalls++; $world.LegacyRemoved = $true }.GetNewClosure()
        ReadCurrentProductState = { param($ExpectedRuntimeId) $world.CurrentProductState }.GetNewClosure()
        RemoveCurrentProductEntry = { param($Entry) $world.CurrentProductRemovals++ }.GetNewClosure()
        ReadLegacySnapshot = {
            param($ExpectedAppId,$ExpectedProfile)
            $entries=[Collections.Generic.List[object]]::new()
            foreach($entry in @($world.LegacyEntries)){
                if($currentShortcutNames-ccontains[string]$entry){
                    $base=if(([string]$entry).StartsWith('Programs\',[StringComparison]::Ordinal)){[Environment]::GetFolderPath([Environment+SpecialFolder]::Programs)}else{[Environment]::GetFolderPath([Environment+SpecialFolder]::Desktop)}
                    $relative=([string]$entry).Substring(([string]$entry).IndexOf('\')+1);$sha=if([string]$entry-ceq$currentShortcutNames[0]){'b'*64}else{'c'*64}
                    if($world.LegacySnapshotHashOverrides.ContainsKey([string]$entry)){$sha=[string]$world.LegacySnapshotHashOverrides[[string]$entry]}
                    $entries.Add([pscustomobject]@{kind='Shortcut';name=[string]$entry;path=[IO.Path]::GetFullPath((Join-Path $base $relative));sha256=$sha;bytesBase64=''})
                }else{$entries.Add([string]$entry)}
            }
            [pscustomobject][ordered]@{appId=$world.Legacy.appId;entries=@($entries)}
        }.GetNewClosure()
        RemoveLegacyEntry = { param($Entry);$world.LegacyRemoveAttempts++;if($world.LegacyRemoveFailureAt-eq$world.LegacyRemoveAttempts){throw 'fixture legacy delete failure'};[void]$world.LegacyEntries.Remove([string]$Entry) }.GetNewClosure()
        ReadLegacyEntry = { param($Entry);if($world.LegacyReplacementEntry-ceq[string]$Entry){return 'Mismatch'};if($world.LegacyEntries.Contains([string]$Entry)){'Exact'}else{$null} }.GetNewClosure()
        RestoreLegacyEntry = { param($Entry);if($world.LegacyRestoreFailureEntry-ceq[string]$Entry){throw 'fixture restore failed'};if(-not$world.LegacyEntries.Contains([string]$Entry)){$world.LegacyEntries.Add([string]$Entry)};$world.LegacyRestoreOrder.Add([string]$Entry);$world.LegacyRestores++ }.GetNewClosure()
        WriteLegacyCompensationFailure = {param($Record)$world.LegacyUnresolvedRecords.Add($Record)}.GetNewClosure()
    }
    return $world
}

function Set-CcodRegistrationLegacyFixture {
    param(
        [Parameter(Mandatory)]$World,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string[]]$ShortcutNames,
        [string]$AppId = $appId,
        [string]$InstallLocation = $legacyInstallLocation,
        [string]$UninstallString = ('"{0}\unins000.exe"' -f $legacyInstallLocation),
        [string[]]$UnsafeShortcutNames = @()
    )
    $World.Legacy = New-CcodLegacyRegistrationFixture -Version $Version -ShortcutNames $ShortcutNames -AppId $AppId -InstallLocation $InstallLocation -UninstallString $UninstallString -UnsafeShortcutNames $UnsafeShortcutNames
    $World.LegacyEntries.Clear()
    foreach ($entry in @('Registry') + $ShortcutNames) { $World.LegacyEntries.Add($entry) }
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
    Assert-CcodEqual 3 $world.LegacyRemoveAttempts 'exact migration removes only the three non-current legacy entries'
    Assert-CcodEqual (($currentShortcutNames|Sort-Object)-join'|') ((@($world.LegacyEntries)|Sort-Object)-join'|') 'exact migration retains both verified current shortcut replacements'
}

# Production mutation caught: requiring the union of every historical shortcut name instead of
# selecting the one complete installer profile that produced the legacy registration.
$results += Invoke-CcodTest 'real v2.5.21 registration removes its exact four-shortcut profile' {
    $world = New-CcodRegistrationWorld
    $null = Commit-CcodProductRegistration -Registration $world.Registration -FileTransaction ([pscustomobject]@{}) -Adapters $world.Adapters

    Remove-CcodLegacyProductRegistration -ExpectedAppId $appId -Adapters $world.Adapters

    Assert-CcodEqual 3 $world.LegacyRemoveAttempts 'v2.5.21 cleanup removes the registry compatibility link and uninstall link'
    Assert-CcodEqual (($currentShortcutNames|Sort-Object)-join'|') ((@($world.LegacyEntries)|Sort-Object)-join'|') 'v2.5.21 cleanup retains the two verified current shortcut replacements'
    Assert-CcodEqual 2 $world.VerifiedRegistrationReads 'v2.5.21 cleanup re-verifies the exact current three-record registration after deletion'
}

# Production mutation caught: widening, narrowing, or crossing a checked-in installer profile's
# version/name boundary can select the wrong legacy objects for deletion.
$results += Invoke-CcodTest 'historical installer profiles resolve at their exact version boundaries' {
    $cases = @(
        [pscustomobject]@{Version='2.1.0';Names=$v210ShortcutNames;ProfileId='CodexControlOtherDevicesInitial';Minimum='2.1.0';Maximum='2.1.0'},
        [pscustomobject]@{Version='2.1.1';Names=$v211ShortcutNames;ProfileId='CodexControlOtherDevicesDesktop';Minimum='2.1.1';Maximum='2.1.6'},
        [pscustomobject]@{Version='2.1.6';Names=$v211ShortcutNames;ProfileId='CodexControlOtherDevicesDesktop';Minimum='2.1.1';Maximum='2.1.6'},
        [pscustomobject]@{Version='2.2.0';Names=$v2521ShortcutNames;ProfileId='CodexRemoteFix';Minimum='2.2.0';Maximum='2.5.21'},
        [pscustomobject]@{Version='2.5.21';Names=@($v2521ShortcutNames[3..0]);ProfileId='CodexRemoteFix';Minimum='2.2.0';Maximum='2.5.21'}
    )
    foreach ($case in $cases) {
        $legacy = New-CcodLegacyRegistrationFixture -Version $case.Version -ShortcutNames $case.Names
        $profile = Resolve-CcodLegacyRegistrationProfile -LegacyRegistration $legacy
        Assert-CcodEqual $case.ProfileId $profile.profileId "$($case.Version) selects the installer profile that emitted its exact shortcut set"
        Assert-CcodEqual $appId $profile.appId "$($case.Version) remains bound to the canonical Inno AppId"
        Assert-CcodEqual $case.Minimum $profile.minimumVersion "$($case.Version) reports the checked-in lower version boundary"
        Assert-CcodEqual $case.Maximum $profile.maximumVersion "$($case.Version) reports the checked-in upper version boundary"
        Assert-CcodEqual '"{installLocation}\unins000.exe"' $profile.uninstallCommandShape "$($case.Version) requires the quoted Inno uninstaller under InstallLocation"
    }
    Assert-CcodEqual 3 @(Get-CcodLegacyRegistrationProfiles).Count 'only the three checked-in historical layouts are supported'
}

# Production mutation caught: validating only a shortcut count, a case-insensitive set, or an
# unbound registry command permits a foreign/replaced entry to be deleted as legacy state.
$results += Invoke-CcodTest 'profile resolution rejects ambiguous registry and shortcut evidence before deletion' {
    foreach ($kind in @('AppId','Missing','Extra','CrossProfile','Case','Reparse','VersionBinding','VersionGap','VersionTooNew','UninstallOutside','UninstallArguments','UninstallUnquoted','InstallLocationRelative')) {
        $world = New-CcodRegistrationWorld
        $legacy = New-CcodLegacyRegistrationFixture -Version '2.5.21' -ShortcutNames $v2521ShortcutNames
        switch ($kind) {
            'AppId' { $legacy.appId = '{AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE}' }
            'Missing' { $legacy.shortcutNames = @($v2521ShortcutNames[0..2]) }
            'Extra' { $legacy.shortcutNames = @($v2521ShortcutNames) + 'Programs\CodexRemote-fix\unexpected.lnk' }
            'CrossProfile' { $legacy.shortcutNames = @($v2521ShortcutNames[0..2]) + $v211ShortcutNames[4] }
            'Case' { $legacy.shortcutNames = @($v2521ShortcutNames[0..2]) + 'desktop\CodexRemote-fix.lnk' }
            'Reparse' { $legacy.unsafeShortcutNames = @($v2521ShortcutNames[0]) }
            'VersionBinding' { $legacy.displayVersion = '2.1.6' }
            'VersionGap' { $legacy.displayVersion = '2.1.7' }
            'VersionTooNew' { $legacy.displayVersion = '2.5.22' }
            'UninstallOutside' { $legacy.uninstallString = '"C:\outside\unins000.exe"' }
            'UninstallArguments' { $legacy.uninstallString += ' /SILENT' }
            'UninstallUnquoted' { $legacy.uninstallString = 'C:\legacy\CodexControlOtherDevices-installer\unins000.exe' }
            'InstallLocationRelative' { $legacy.installLocation = 'relative\installer' }
        }
        $world.Legacy = $legacy
        $null = Commit-CcodProductRegistration -Registration $world.Registration -FileTransaction ([pscustomobject]@{}) -Adapters $world.Adapters
        Assert-CcodThrows { Resolve-CcodLegacyRegistrationProfile -LegacyRegistration $world.Legacy | Out-Null } 'CCOD_LEGACY_PRODUCT_REGISTRATION_INVALID'
        Assert-CcodThrows { Remove-CcodLegacyProductRegistration -ExpectedAppId $appId -Adapters $world.Adapters } 'CCOD_LEGACY_PRODUCT_REGISTRATION_INVALID'
        Assert-CcodEqual 0 $world.LegacyRemoveAttempts "$kind mismatch is rejected before any legacy deletion"
        Assert-CcodEqual 5 $world.LegacyEntries.Count "$kind mismatch preserves the complete exact legacy state"
    }
}

# Production mutation caught: keeping the historical fixed count of nine records either rejects a
# complete older profile or authorizes a same-count snapshot containing an unrelated entry.
$results += Invoke-CcodTest 'legacy snapshot count and names are derived from the selected historical profile' {
    foreach ($case in @(
        [pscustomobject]@{Version='2.1.0';Names=$v210ShortcutNames;RemovalCount=5;Remaining=@()},
        [pscustomobject]@{Version='2.1.6';Names=$v211ShortcutNames;RemovalCount=6;Remaining=@()},
        [pscustomobject]@{Version='2.5.21';Names=$v2521ShortcutNames;RemovalCount=3;Remaining=$currentShortcutNames}
    )) {
        $world = New-CcodRegistrationWorld
        Set-CcodRegistrationLegacyFixture -World $world -Version $case.Version -ShortcutNames $case.Names
        $null = Commit-CcodProductRegistration -Registration $world.Registration -FileTransaction ([pscustomobject]@{}) -Adapters $world.Adapters
        Remove-CcodLegacyProductRegistration -ExpectedAppId $appId -Adapters $world.Adapters
        Assert-CcodEqual $case.RemovalCount $world.LegacyRemoveAttempts "$($case.Version) removes only legacy entries not replaced by exact current shortcuts"
        Assert-CcodEqual ((@($case.Remaining)|Sort-Object)-join'|') ((@($world.LegacyEntries)|Sort-Object)-join'|') "$($case.Version) leaves exactly its verified current replacement set"
    }

    $world = New-CcodRegistrationWorld
    $null = Commit-CcodProductRegistration -Registration $world.Registration -FileTransaction ([pscustomobject]@{}) -Adapters $world.Adapters
    [void]$world.LegacyEntries.Remove($v2521ShortcutNames[3])
    $world.LegacyEntries.Add('Programs\CodexRemote-fix\unexpected.lnk')
    Assert-CcodThrows { Remove-CcodLegacyProductRegistration -ExpectedAppId $appId -Adapters $world.Adapters } 'CCOD_LEGACY_PRODUCT_REGISTRATION_INVALID'
    Assert-CcodEqual 0 $world.LegacyRemoveAttempts 'same-count foreign snapshot is rejected before the first deletion'
}

$results += Invoke-CcodTest 'overlapping legacy names require exact current shortcut hashes before deletion' {
    $world=New-CcodRegistrationWorld
    $world.LegacySnapshotHashOverrides[$currentShortcutNames[0]]='d'*64
    $null=Commit-CcodProductRegistration -Registration $world.Registration -FileTransaction ([pscustomobject]@{}) -Adapters $world.Adapters
    Assert-CcodThrows {Remove-CcodLegacyProductRegistration -ExpectedAppId $appId -Adapters $world.Adapters} 'CCOD_LEGACY_PRODUCT_REGISTRATION_INVALID'
    Assert-CcodEqual 0 $world.LegacyRemoveAttempts 'mismatched replacement hash is rejected before any legacy deletion'
    Assert-CcodEqual 5 $world.LegacyEntries.Count 'mismatched replacement hash preserves every observed entry'
}

$results += Invoke-CcodTest 'current registration drift after cleanup restores every removed legacy-only entry' {
    $world=New-CcodRegistrationWorld
    $world.VerifiedRegistrationMutationAt=2
    $before=@($world.LegacyEntries)|Sort-Object
    $null=Commit-CcodProductRegistration -Registration $world.Registration -FileTransaction ([pscustomobject]@{}) -Adapters $world.Adapters
    Assert-CcodThrows {Remove-CcodLegacyProductRegistration -ExpectedAppId $appId -Adapters $world.Adapters} 'CCOD_LEGACY_PRODUCT_REGISTRATION_INVALID'
    Assert-CcodEqual 3 $world.LegacyRemoveAttempts 'post-cleanup proof drift occurs only after the three legacy-only entries were removed'
    Assert-CcodEqual ($before-join'|') ((@($world.LegacyEntries)|Sort-Object)-join'|') 'post-cleanup proof drift compensates the complete removed legacy-only set'
    Assert-CcodEqual (($v2521ShortcutNames[2],$v2521ShortcutNames[1],'Registry')-join'|') (@($world.LegacyRestoreOrder)-join'|') 'post-cleanup proof drift restores legacy-only entries in reverse order'
}

# Production mutation caught: accepting an unexpected AppId/name set or an unverified registration receipt.
$results += Invoke-CcodTest 'legacy migration rejects AppId shortcut and current-proof mismatches without deletion' {
    foreach ($mismatch in @('AppId','Shortcut','Receipt','CurrentProofHash','CurrentProofNames')) {
        $world = New-CcodRegistrationWorld
        $receipt = Commit-CcodProductRegistration -Registration $world.Registration -FileTransaction ([pscustomobject]@{}) -Adapters $world.Adapters
        if ($mismatch -ceq 'AppId') { $world.Legacy.appId = '{AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE}' }
        if ($mismatch -ceq 'Shortcut') { $world.Legacy.shortcutNames = @('Programs\unexpected.lnk') }
        if ($mismatch -ceq 'Receipt') { $world.Product = $null }
        if ($mismatch -in @('CurrentProofHash','CurrentProofNames')) {
            $readVerified=$world.Adapters.ReadVerifiedRegistration
            $world.Adapters.ReadVerifiedRegistration={
                $proof=&$readVerified
                if($mismatch-ceq'CurrentProofHash'){$proof.startMenuSha256='d'*64}else{$proof.shortcutNames=@($currentShortcutNames[0])}
                $proof
            }.GetNewClosure()
        }
        Assert-CcodThrows { Remove-CcodLegacyProductRegistration -ExpectedAppId $appId -Adapters $world.Adapters } 'CCOD_LEGACY_PRODUCT_REGISTRATION_INVALID'
        Assert-CcodEqual 0 $world.LegacyRemoveAttempts 'legacy mismatch is rejected before any deletion'
        Assert-CcodEqual 5 $world.LegacyEntries.Count 'legacy state remains intact on mismatch'
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
    $world.LegacyRemoveFailureAt=3
    Assert-CcodThrows {Remove-CcodLegacyProductRegistration -ExpectedAppId $appId -Adapters $world.Adapters} 'CCOD_LEGACY_PRODUCT_REGISTRATION_INVALID'
    Assert-CcodEqual ($before-join'|') ((@($world.LegacyEntries)|Sort-Object)-join'|') 'failed migration restores the complete exact legacy set'
    Assert-CcodEqual 2 $world.LegacyRestores 'only successfully removed legacy-only entries are restored'
    Assert-CcodEqual (($v2521ShortcutNames[1],'Registry')-join'|') (@($world.LegacyRestoreOrder)-join'|') 'successful legacy-only deletions are compensated in exact reverse order'
}

$results += Invoke-CcodTest 'legacy compensation never overwrites a replacement that appeared after deletion' {
    $world=New-CcodRegistrationWorld;$null=Commit-CcodProductRegistration -Registration $world.Registration -FileTransaction ([pscustomobject]@{}) -Adapters $world.Adapters;$world.LegacyRemoveFailureAt=3;$world.LegacyReplacementEntry=$v2521ShortcutNames[1]
    Assert-CcodThrows {Remove-CcodLegacyProductRegistration -ExpectedAppId $appId -Adapters $world.Adapters} 'CCOD_LEGACY_PRODUCT_COMPENSATION_FAILED'
    Assert-CcodEqual 1 $world.LegacyRestores 'compensation restores only entries that remain absent'
    Assert-CcodTrue (-not$world.LegacyEntries.Contains($v2521ShortcutNames[1])) 'replacement occupies the removed name and is not overwritten with captured bytes'
    Assert-CcodEqual 1 $world.LegacyUnresolvedRecords.Count 'replacement-blocked restoration is recorded explicitly'
}

$results += Invoke-CcodTest 'legacy restore failure is explicit and records the unresolved exact entries' {
    $world=New-CcodRegistrationWorld;$null=Commit-CcodProductRegistration -Registration $world.Registration -FileTransaction ([pscustomobject]@{}) -Adapters $world.Adapters;$world.LegacyRemoveFailureAt=3;$world.LegacyRestoreFailureEntry=$v2521ShortcutNames[1]
    Assert-CcodThrows {Remove-CcodLegacyProductRegistration -ExpectedAppId $appId -Adapters $world.Adapters} 'CCOD_LEGACY_PRODUCT_COMPENSATION_FAILED'
    Assert-CcodEqual 1 $world.LegacyUnresolvedRecords.Count 'failed compensation writes one explicit unresolved record'
    Assert-CcodTrue (@($world.LegacyUnresolvedRecords[0].entries)-ccontains$v2521ShortcutNames[1]) 'unresolved record names the exact entry whose restoration failed'
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
