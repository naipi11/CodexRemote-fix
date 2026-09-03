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
$startCurrentBytes=[Text.UTF8Encoding]::new($false).GetBytes('current-shortcut:Programs\CodexRemote-fix\CodexRemote-fix.lnk')
$desktopCurrentBytes=[Text.UTF8Encoding]::new($false).GetBytes('current-shortcut:Desktop\CodexRemote-fix.lnk')
$testSha=[Security.Cryptography.SHA256]::Create();try{$startCurrentSha=[BitConverter]::ToString($testSha.ComputeHash($startCurrentBytes)).Replace('-','').ToLowerInvariant();$desktopCurrentSha=[BitConverter]::ToString($testSha.ComputeHash($desktopCurrentBytes)).Replace('-','').ToLowerInvariant()}finally{$testSha.Dispose()}
$cleanupReady=[pscustomobject][ordered]@{phase='Ready';installRoot='C:\fixture\CodexControlOtherDevices';runtimeId=$runtimeId;runtimeGeneration=[uint64]7;packageSha256=$packageSha256;manifestSha256=('a'*64);startMenuSha256=$startCurrentSha;desktopSha256=$desktopCurrentSha;targetPath=$canonicalTaskTarget;arguments='/Run /TN "Codex Control Other Devices Supervisor"'}
$expectedVerifiedRegistration=[pscustomobject][ordered]@{verified=$true;runtimeId=$runtimeId;version='2.5.22';packageSha256=$packageSha256;shortcutNames=@('Programs\CodexRemote-fix\CodexRemote-fix.lnk','Desktop\CodexRemote-fix.lnk');startMenuSha256=$startCurrentSha;desktopSha256=$desktopCurrentSha}
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

function Get-CcodTestBytesSha256([byte[]]$Bytes){$sha=[Security.Cryptography.SHA256]::Create();try{[BitConverter]::ToString($sha.ComputeHash($Bytes)).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}}
function Invoke-CcodTask2Fix1ProductTest([string]$Id,[string]$Name,[scriptblock]$Action){if(-not[string]::IsNullOrWhiteSpace($env:CCOD_TASK2_FIX1_RED_CASE)-and$env:CCOD_TASK2_FIX1_RED_CASE-cne$Id){return};Invoke-CcodTest $Name $Action}

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

function New-CcodProductLegacyShortcutProofs {
    param([Parameter(Mandatory)]$Legacy,[Parameter(Mandatory)][string]$ExpectedInstallRoot)
    $powershell=[IO.Path]::GetFullPath((Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::System)) 'WindowsPowerShell\v1.0\powershell.exe'))
    $install=[IO.Path]::GetFullPath($ExpectedInstallRoot);$installer=[IO.Path]::GetFullPath([string]$Legacy.installLocation);$version=[version]::Parse([string]$Legacy.displayVersion)
    $bootstrap=Join-Path $install 'bootstrap.ps1';$explicit=if($version-ge[version]'2.5.0'){' -EntryMode Explicit'}else{''};$main='-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -InstallRoot "{1}"{2}'-f$bootstrap,$install,$explicit
    $proofs=@{}
    foreach($name in @($Legacy.shortcutNames)){
        $target=$null;$arguments='';$working=''
        $oldDesktop='Desktop\Codex '+[char]0x8BBE+[char]0x5907+[char]0x8FDE+[char]0x63A5+' (Device Connection).lnk'
        if([string]$name-ceq$oldDesktop){$target=$powershell;$arguments=$main;$working=$install}
        else{
        switch -CaseSensitive ([string]$name){
            'Programs\Codex Control other devices\Codex Control other devices for Windows.lnk' {$target=Join-Path $installer 'README.md'}
            'Programs\Codex Control other devices\Open the tray supervisor.lnk' {$target=$powershell;$arguments='-NoProfile -ExecutionPolicy Bypass -File "{0}"'-f(Join-Path $installer 'Start-CodexControlOtherDevices.ps1');$working=$installer}
            'Programs\Codex Control other devices\Compatibility check.lnk' {$target=$powershell;$arguments='-NoProfile -ExecutionPolicy Bypass -File "{0}"'-f(Join-Path $installer 'Test-CodexControlOtherDevices.ps1');$working=$installer}
            'Programs\Codex Control other devices\Uninstall Codex Control other devices.lnk' {$target=Join-Path $installer 'unins000.exe'}
            'Programs\CodexRemote-fix\CodexRemote-fix.lnk' {$target=$powershell;$arguments=$main;$working=$install}
            'Programs\CodexRemote-fix\CodexRemote-fix compatibility check.lnk' {$target=$powershell;$arguments='-NoProfile -ExecutionPolicy Bypass -File "{0}"'-f(Join-Path $installer 'Test-CodexControlOtherDevices.ps1');$working=$installer}
            'Programs\CodexRemote-fix\Uninstall CodexRemote-fix.lnk' {$target=Join-Path $installer 'unins000.exe'}
            'Desktop\CodexRemote-fix.lnk' {$target=$powershell;$arguments=$main;$working=$install}
            default {throw "unknown test legacy shortcut $name"}
        }
        }
        $bytes=[Text.UTF8Encoding]::new($false).GetBytes(('legacy-shortcut:'+([string]$name)));$sha=[Security.Cryptography.SHA256]::Create();try{$hash=[BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
        $proofs[[string]$name]=[pscustomobject][ordered]@{targetPath=[IO.Path]::GetFullPath($target);arguments=$arguments;workingDirectory=$(if([string]::IsNullOrEmpty($working)){''}else{[IO.Path]::GetFullPath($working).TrimEnd('\')});sha256=$hash;bytesBase64=[Convert]::ToBase64String($bytes)}
    }
    $proofs
}

function New-CcodProductCurrentShortcutProofs {
    $proofs=@{};foreach($name in $currentShortcutNames){$bytes=[Text.UTF8Encoding]::new($false).GetBytes(('current-shortcut:'+([string]$name)));$sha=[Security.Cryptography.SHA256]::Create();try{$hash=[BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()};$proofs[[string]$name]=[pscustomobject][ordered]@{targetPath=$canonicalTaskTarget;arguments='/Run /TN "Codex Control Other Devices Supervisor"';workingDirectory='';sha256=$hash;bytesBase64=[Convert]::ToBase64String($bytes)}};$proofs
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
            startMenuSha256 = $startCurrentSha
            desktopSha256 = $desktopCurrentSha
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
        LegacyShortcutProofs = $null
        CurrentShortcutProofs = (New-CcodProductCurrentShortcutProofs)
        SimulateOverlapWrites = $false
        LegacyMigrationPlanBytes = $null
        LegacyMigrationPlanWrites = 0
        LegacyMigrationPlanReads = 0
        LegacyMigrationPlanWriteMode = $null
        LegacyMigrationPlanReadFailureAt = 0
        Calls = [Collections.Generic.List[string]]::new()
    }
    $world.LegacyShortcutProofs=New-CcodProductLegacyShortcutProofs -Legacy $world.Legacy -ExpectedInstallRoot $registration.installRoot
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
            $legacyName=if($Kind-ceq'StartMenu'){$currentShortcutNames[0]}else{$currentShortcutNames[1]}
            if(-not$world.LegacyEntries.Contains($legacyName)){$world.LegacyEntries.Add($legacyName)}
            if($world.SimulateOverlapWrites){$world.LegacyShortcutProofs[$legacyName]=$world.CurrentShortcutProofs[$legacyName]}
        }.GetNewClosure()
        ReadShortcut = {
            param($Kind,$Shortcut)
            $world.Calls.Add("ReadShortcut:$Kind")
            if ($world.ReadShortcutFailure -ceq $Kind) { throw 'fixture shortcut read failed' }
            $world.Shortcuts[$Kind]
        }.GetNewClosure()
        ReadLegacyRegistration = {param($ExpectedAppId)$world.Calls.Add('ReadLegacy');if(-not$world.LegacyEntries.Contains('Registry')){return $null};[pscustomobject][ordered]@{appId=[string]$world.Legacy.appId;displayVersion=[string]$world.Legacy.displayVersion;installLocation=[string]$world.Legacy.installLocation;uninstallString=[string]$world.Legacy.uninstallString;shortcutNames=@($world.LegacyEntries|Where-Object{[string]$_-cne'Registry'});unsafeShortcutNames=@($world.Legacy.unsafeShortcutNames)}}.GetNewClosure()
        ReadVerifiedRegistration = {
            $world.VerifiedRegistrationReads++
            $startMenuSha256=if($world.VerifiedRegistrationMutationAt-eq$world.VerifiedRegistrationReads){'d'*64}else{[string]$world.Ready.startMenuSha256}
            [pscustomobject][ordered]@{
                verified=($null-ne$world.Product-and$world.Shortcuts.Count-eq2);runtimeId=$runtimeId;version='2.5.22';packageSha256=$packageSha256
                shortcutNames=@($currentShortcutNames);startMenuSha256=$startMenuSha256;desktopSha256=[string]$world.Ready.desktopSha256
            }
        }.GetNewClosure()
        RemoveLegacyRegistration = { param($ExpectedAppId,$ExpectedShortcutNames) $world.Calls.Add('RemoveLegacy'); $world.LegacyRemovalCalls++; $world.LegacyRemoved = $true }.GetNewClosure()
        ReadCurrentProductState = { param($ExpectedRuntimeId) $world.CurrentProductState }.GetNewClosure()
        RemoveCurrentProductEntry = { param($Entry) $world.CurrentProductRemovals++ }.GetNewClosure()
        ReadLegacySnapshot = {
            param($ExpectedAppId,$ExpectedProfile)
            $entries=[Collections.Generic.List[object]]::new()
            foreach($entry in @($world.LegacyEntries)){
                if([string]$entry-cne'Registry'){
                    $base=if(([string]$entry).StartsWith('Programs\',[StringComparison]::Ordinal)){[Environment]::GetFolderPath([Environment+SpecialFolder]::Programs)}else{[Environment]::GetFolderPath([Environment+SpecialFolder]::Desktop)}
                    $relative=([string]$entry).Substring(([string]$entry).IndexOf('\')+1);$proof=$world.LegacyShortcutProofs[[string]$entry];$sha=[string]$proof.sha256
                    if($world.LegacySnapshotHashOverrides.ContainsKey([string]$entry)){$sha=[string]$world.LegacySnapshotHashOverrides[[string]$entry]}
                    $entries.Add([pscustomobject][ordered]@{kind='Shortcut';name=[string]$entry;path=[IO.Path]::GetFullPath((Join-Path $base $relative));sha256=$sha;bytesBase64=[string]$proof.bytesBase64;targetPath=[string]$proof.targetPath;arguments=[string]$proof.arguments;workingDirectory=[string]$proof.workingDirectory})
                }else{$entries.Add([pscustomobject][ordered]@{kind='Registry';path=('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\'+$world.Legacy.appId+'_is1');values=[ordered]@{DisplayVersion=[pscustomobject]@{value=[string]$world.Legacy.displayVersion;kind='String'};InstallLocation=[pscustomobject]@{value=[string]$world.Legacy.installLocation;kind='String'};UninstallString=[pscustomobject]@{value=[string]$world.Legacy.uninstallString;kind='String'}}})}
            }
            [pscustomobject][ordered]@{appId=$world.Legacy.appId;entries=@($entries)}
        }.GetNewClosure()
        GetCurrentShortcutProof = {
            param($Kind,$Shortcut,$ReadyEvidence)
            $name=if($Kind-ceq'StartMenu'){$currentShortcutNames[0]}else{$currentShortcutNames[1]};$proof=$world.CurrentShortcutProofs[$name]
            $base=if($Kind-ceq'StartMenu'){[Environment]::GetFolderPath([Environment+SpecialFolder]::Programs)}else{[Environment]::GetFolderPath([Environment+SpecialFolder]::Desktop)};$relative=$name.Substring($name.IndexOf('\')+1)
            [pscustomobject][ordered]@{kind=$Kind;name=$name;path=[IO.Path]::GetFullPath((Join-Path $base $relative));candidatePath=[IO.Path]::GetFullPath([string]$Shortcut.candidatePath);candidateLength=[int64]([Convert]::FromBase64String([string]$proof.bytesBase64).LongLength);candidateSha256=[string]$proof.sha256;targetPath=[string]$proof.targetPath;arguments=[string]$proof.arguments;workingDirectory=[string]$proof.workingDirectory}
        }.GetNewClosure()
        ReadLegacyMigrationPlan = {param($ReadyEvidence)$world.LegacyMigrationPlanReads++;if($world.LegacyMigrationPlanReadFailureAt-eq$world.LegacyMigrationPlanReads){throw 'fixture durable plan read-back failure'};if($null-eq$world.LegacyMigrationPlanBytes){return $null};$bytes=[byte[]]$world.LegacyMigrationPlanBytes.Clone();[pscustomobject]@{Bytes=$bytes;Length=[int64]$bytes.LongLength;Sha256=(Get-CcodTestBytesSha256 $bytes)}}.GetNewClosure()
        WriteLegacyMigrationPlan = {param($ReadyEvidence,[byte[]]$Bytes)if($null-ne$world.LegacyMigrationPlanBytes){throw 'fixture durable plan collision'};$world.LegacyMigrationPlanWrites++;$world.LegacyMigrationPlanBytes=[byte[]]$Bytes.Clone();if($world.LegacyMigrationPlanWriteMode-ceq'PublishedThenThrow'){throw 'fixture published durable plan then threw'};[pscustomobject]@{Length=[int64]$Bytes.LongLength;Sha256=(Get-CcodTestBytesSha256 $Bytes)}}.GetNewClosure()
        RemoveLegacyEntry = {param($Entry);$name=if($Entry-is[string]){[string]$Entry}elseif($Entry.kind-ceq'Registry'){'Registry'}else{[string]$Entry.name};$world.LegacyRemoveAttempts++;if($world.LegacyRemoveFailureAt-eq$world.LegacyRemoveAttempts){throw 'fixture legacy delete failure'};[void]$world.LegacyEntries.Remove($name)}.GetNewClosure()
        ReadLegacyEntry = {param($Entry);$name=if($Entry-is[string]){[string]$Entry}elseif($Entry.kind-ceq'Registry'){'Registry'}else{[string]$Entry.name};if($world.LegacyReplacementEntry-ceq$name-and$world.LegacyRemoveFailureAt-gt0-and$world.LegacyRemoveAttempts-ge$world.LegacyRemoveFailureAt){return 'Mismatch'};if(-not$world.LegacyEntries.Contains($name)){return $null};if($Entry-isnot[string]-and$Entry.kind-ceq'Shortcut' -and [string]$Entry.sha256-cne[string]$world.LegacyShortcutProofs[$name].sha256){return 'Mismatch'};'Exact'}.GetNewClosure()
        RestoreLegacyEntry = {param($Entry);$name=if($Entry-is[string]){[string]$Entry}elseif($Entry.kind-ceq'Registry'){'Registry'}else{[string]$Entry.name};if($world.LegacyRestoreFailureEntry-ceq$name){throw 'fixture restore failed'};if(-not$world.LegacyEntries.Contains($name)){$world.LegacyEntries.Add($name)};$world.LegacyRestoreOrder.Add($name);$world.LegacyRestores++}.GetNewClosure()
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
    $World.LegacyShortcutProofs=New-CcodProductLegacyShortcutProofs -Legacy $World.Legacy -ExpectedInstallRoot $World.Registration.installRoot
    $World.LegacyEntries.Clear()
    foreach ($entry in @('Registry') + $ShortcutNames) { $World.LegacyEntries.Add($entry) }
}

function Get-CcodProductTestLegacyMigrationPlan {
    param([Parameter(Mandatory)]$World)
    Get-CcodDurableLegacyProductRegistrationMigrationPlan -ExpectedAppId $appId -Registration $World.Registration -ReadyEvidence $World.Ready -Adapters $World.Adapters
}

function New-CcodFix1RegistryKey {
    param([Parameter(Mandatory)][string]$Id,[Parameter(Mandatory)]$Values,[Parameter(Mandatory)]$Kinds,[Parameter(Mandatory)]$World)
    $key=[pscustomobject]@{Id=$Id;Values=$Values;Kinds=$Kinds;World=$World;DeleteCalls=0;DisposeCalls=0;Deleted=$false}
    $key|Add-Member ScriptMethod GetValueNames { @($this.Values.Keys) }
    $key|Add-Member ScriptMethod GetSubKeyNames { ,([string[]]@()) }
    $key|Add-Member ScriptMethod GetValue {param($Name,$DefaultValue,$Options)if($this.Values.Contains([string]$Name)){$this.Values[[string]$Name]}else{$DefaultValue}}
    $key|Add-Member ScriptMethod GetValueKind {param($Name)[Enum]::Parse([Microsoft.Win32.RegistryValueKind],[string]$this.Kinds[[string]$Name])}
    $key|Add-Member ScriptMethod DeleteValue {
        param($Name,$ThrowOnMissing)
        $this.DeleteCalls++
        if($this.World.Mode-ceq'PartialReplacement'-and$this.Id-ceq'Original'-and$this.DeleteCalls-eq2){$this.World.CurrentKey=$this.World.Replacement;throw 'TEST_PARTIAL_REGISTRY_DELETE_FAILURE'}
        if(-not$this.Values.Contains([string]$Name)){if($ThrowOnMissing){throw 'TEST_REGISTRY_VALUE_MISSING'};return}
        $this.Values.Remove([string]$Name)
    }
    $key|Add-Member ScriptMethod Dispose {$this.DisposeCalls++}
    return $key
}

function New-CcodFix1RegistryWorld {
    param([Parameter(Mandatory)][ValidateSet('PartialReplacement','CreateOpened','CreateNew')][string]$Mode)
    $world=[pscustomobject]@{
        Mode=$Mode;CurrentKey=$null;Original=$null;Replacement=$null;Created=$null;NativeCreateCalls=0;ProviderNewItemCalls=0
        ReplacementWrites=0;CompensationRecords=[Collections.Generic.List[object]]::new();RegistryAdapters=$null;LowerFailure=$null
    }
    $world.Original=New-CcodFix1RegistryKey -Id Original -Values ([ordered]@{DisplayName='captured-product';NoModify=1}) -Kinds ([ordered]@{DisplayName='String';NoModify='DWord'}) -World $world
    $world.Replacement=New-CcodFix1RegistryKey -Id Replacement -Values ([ordered]@{DisplayName='replacement-product';ReplacementSentinel=[byte[]]@(0xde,0xad,0xbe,0xef)}) -Kinds ([ordered]@{DisplayName='String';ReplacementSentinel='Binary'}) -World $world
    $world.CurrentKey=$world.Original
    $world.RegistryAdapters=@{
        OpenExisting={param($Path)if($null-eq$world.CurrentKey){return $null};[pscustomobject][ordered]@{key=$world.CurrentKey;resource=$world.CurrentKey;disposition='OpenedExisting'}}.GetNewClosure()
        CloseKey={param($Handle)$Handle.key.Dispose()}.GetNewClosure()
        GetValueNames={param($Handle)@($Handle.key.Values.Keys)}.GetNewClosure()
        GetSubKeyNames={param($Handle)@()}.GetNewClosure()
        GetValue={param($Handle,$Name)if($Handle.key.Values.Contains([string]$Name)){$Handle.key.Values[[string]$Name]}else{$null}}.GetNewClosure()
        GetValueKind={param($Handle,$Name)[string]$Handle.key.Kinds[[string]$Name]}.GetNewClosure()
        DeleteValue={param($Handle,$Name)$Handle.key.DeleteValue([string]$Name,$true)}.GetNewClosure()
        SetValue={param($Handle,$Name,$Value,$Kind)if($Handle.key.Id-ceq'Replacement'){$world.ReplacementWrites++};$Handle.key.Values[[string]$Name]=$Value;$Handle.key.Kinds[[string]$Name]=[string]$Kind}.GetNewClosure()
        DeleteKey={param($Handle)$Handle.key.Deleted=$true;if([object]::ReferenceEquals($world.CurrentKey,$Handle.key)){$world.CurrentKey=$null}}.GetNewClosure()
        TestKeyAtPath={param($Path,$Handle)[object]::ReferenceEquals($world.CurrentKey,$Handle.key)}.GetNewClosure()
        CreateKey={
            param($Path)
            $world.NativeCreateCalls++
            if($world.Mode-ceq'CreateOpened'){$world.CurrentKey=$world.Replacement;return [pscustomobject][ordered]@{key=$world.Replacement;resource=$world.Replacement;disposition='OpenedExisting'}}
            if($null-ne$world.CurrentKey){return [pscustomobject][ordered]@{key=$world.CurrentKey;resource=$world.CurrentKey;disposition='OpenedExisting'}}
            $world.Created=New-CcodFix1RegistryKey -Id Created -Values ([ordered]@{}) -Kinds ([ordered]@{}) -World $world;$world.CurrentKey=$world.Created
            [pscustomobject][ordered]@{key=$world.Created;resource=$world.Created;disposition='CreatedNew'}
        }.GetNewClosure()
    }
    return $world
}

function New-CcodFix1RegistrySnapshotEntry {
    [pscustomobject][ordered]@{
        kind='Registry';path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{2B9E9F2E-7A32-4A7E-9C1D-9F5B5C6D7E8F}_is1'
        values=[ordered]@{DisplayName=[pscustomobject]@{value='captured-product';kind='String'};NoModify=[pscustomobject]@{value=1;kind='DWord'}}
    }
}

function Invoke-CcodFix1RegistryCompensationScenario {
    param([Parameter(Mandatory)][ValidateSet('PartialReplacement','CreateOpened','CreateNew')][string]$Mode)
    $root=Join-Path ([IO.Path]::GetTempPath()) ('ccod-product-fix1-'+[guid]::NewGuid().ToString('N'));[IO.Directory]::CreateDirectory($root)|Out-Null
    $copy=Join-Path $root 'ProductRegistrationFix1.psm1';Copy-Item -LiteralPath $modulePath -Destination $copy
    $isolated=Import-Module $copy -Force -PassThru -DisableNameChecking -Prefix Fix1
    $world=New-CcodFix1RegistryWorld -Mode $Mode;$replacementBefore=($world.Replacement.Values|ConvertTo-Json -Compress);$replacementKindsBefore=($world.Replacement.Kinds|ConvertTo-Json -Compress)
    try{
        &$isolated {
            param($State)
            $script:CcodFix1RegistryWorld=$State
            function script:Get-CcodLegacyRegistryMutationAdapters {param($Adapters)$script:CcodFix1RegistryWorld.RegistryAdapters}
            function script:Get-Item {param($LiteralPath,$ErrorAction)$script:CcodFix1RegistryWorld.CurrentKey}
            function script:Test-Path {param($LiteralPath,$PathType)[bool]($null-ne$script:CcodFix1RegistryWorld.CurrentKey)}
            function script:Get-ItemProperty {param($LiteralPath,$Name,$ErrorAction)$key=$script:CcodFix1RegistryWorld.CurrentKey;if($null-ne$key-and$key.Values.Contains([string]$Name)){[pscustomobject]@{value=$key.Values[[string]$Name]}}else{$null}}
            function script:New-ItemProperty {param($LiteralPath,$Name,$Value,$PropertyType,[switch]$Force)$key=$script:CcodFix1RegistryWorld.CurrentKey;if($key.Id-ceq'Replacement'){$script:CcodFix1RegistryWorld.ReplacementWrites++};$key.Values[[string]$Name]=$Value;$key.Kinds[[string]$Name]=[string]$PropertyType;[pscustomobject]@{value=$Value}}
            function script:Remove-Item {param($LiteralPath,[switch]$Force,$ErrorAction)$key=$script:CcodFix1RegistryWorld.CurrentKey;if($null-ne$key){$key.Deleted=$true};$script:CcodFix1RegistryWorld.CurrentKey=$null}
            function script:New-Item {
                param($Path,[switch]$Force)
                $script:CcodFix1RegistryWorld.ProviderNewItemCalls++
                if($script:CcodFix1RegistryWorld.Mode-in@('PartialReplacement','CreateOpened')){$script:CcodFix1RegistryWorld.CurrentKey=$script:CcodFix1RegistryWorld.Replacement;return $script:CcodFix1RegistryWorld.Replacement}
                $created=New-CcodFix1RegistryKey -Id Created -Values ([ordered]@{}) -Kinds ([ordered]@{}) -World $script:CcodFix1RegistryWorld;$script:CcodFix1RegistryWorld.Created=$created;$script:CcodFix1RegistryWorld.CurrentKey=$created;$created
            }
        } $world
        $registryEntry=New-CcodFix1RegistrySnapshotEntry
        $legacy=New-CcodLegacyRegistrationFixture -Version '2.5.21' -ShortcutNames $v2521ShortcutNames
        $proofs=New-CcodProductLegacyShortcutProofs -Legacy $legacy -ExpectedInstallRoot 'C:\fixture\CodexControlOtherDevices'
        $programs=[Environment]::GetFolderPath([Environment+SpecialFolder]::Programs);$desktop=[Environment]::GetFolderPath([Environment+SpecialFolder]::Desktop)
        $snapshotEntries=[Collections.Generic.List[object]]::new();$snapshotEntries.Add($registryEntry)
        foreach($name in $v2521ShortcutNames){$base=if($name.StartsWith('Programs\',[StringComparison]::Ordinal)){$programs}else{$desktop};$relative=$name.Substring($name.IndexOf('\')+1);$shortcut=$proofs[$name];$snapshotEntries.Add([pscustomobject][ordered]@{kind='Shortcut';name=$name;path=[IO.Path]::GetFullPath((Join-Path $base $relative));sha256=[string]$shortcut.sha256;bytesBase64=[string]$shortcut.bytesBase64;targetPath=[string]$shortcut.targetPath;arguments=[string]$shortcut.arguments;workingDirectory=[string]$shortcut.workingDirectory})}
        $snapshot=[pscustomobject][ordered]@{appId=$appId;entries=@($snapshotEntries)}
        $proof=[pscustomobject][ordered]@{verified=$true;runtimeId=$runtimeId;version='2.5.22';packageSha256=$packageSha256;shortcutNames=@($currentShortcutNames);startMenuSha256=$startCurrentSha;desktopSha256=$desktopCurrentSha}
        $removeRegistry={param($Entry)&$isolated {param($Value)Remove-CcodLegacySnapshotEntry -Entry $Value} $Entry}.GetNewClosure()
        $readRegistry={param($Entry)&$isolated {param($Value)Read-CcodLegacySnapshotEntry -Entry $Value} $Entry}.GetNewClosure()
        $restoreRegistry={param($Entry)&$isolated {param($Value)Restore-CcodLegacySnapshotEntry -Entry $Value} $Entry}.GetNewClosure()
        $adapters=@{
            ReadVerifiedRegistration={$proof}.GetNewClosure();ReadLegacyRegistration={param($ExpectedAppId)$legacy}.GetNewClosure();ReadLegacySnapshot={param($ExpectedAppId,$ExpectedProfile)$snapshot}.GetNewClosure()
            RemoveLegacyEntry={param($Entry)if($Entry-isnot[string]-and$Entry.kind-ceq'Registry'){try{&$removeRegistry $Entry}catch{$world.LowerFailure=$_;throw};return};$name=if($Entry-is[string]){[string]$Entry}else{[string]$Entry.name};if($Mode-cne'PartialReplacement'-and$name-ceq$v2521ShortcutNames[1]){throw 'TEST_LATER_SHORTCUT_DELETE_FAILURE'}}.GetNewClosure()
            ReadLegacyEntry={param($Entry)if($Entry-isnot[string]-and$Entry.kind-ceq'Registry'){&$readRegistry $Entry}else{'Exact'}}.GetNewClosure()
            RestoreLegacyEntry={param($Entry)if($Entry-isnot[string]-and$Entry.kind-ceq'Registry'){&$restoreRegistry $Entry}}.GetNewClosure()
            WriteLegacyCompensationFailure={param($Record)$world.CompensationRecords.Add($Record)}.GetNewClosure()
        }
        $failure=$null;try{&$isolated {param($ExpectedAppId,$ProductAdapters,$ExpectedInstallRoot,$ExpectedCurrentProof)$plan=Get-CcodLegacyProductRegistrationMigrationPlan -ExpectedAppId $ExpectedAppId -ExpectedInstallRoot $ExpectedInstallRoot -Adapters $ProductAdapters;Remove-CcodLegacyProductRegistration -ExpectedAppId $ExpectedAppId -MigrationPlan $plan -ExpectedCurrentProof $ExpectedCurrentProof -Adapters $ProductAdapters} $appId $adapters 'C:\fixture\CodexControlOtherDevices' $proof}catch{$failure=$_}
        return [pscustomobject]@{World=$world;Failure=$failure;ReplacementBefore=$replacementBefore;ReplacementKindsBefore=$replacementKindsBefore;RegistryEntry=$registryEntry}
    }finally{Remove-Module $isolated -Force -ErrorAction SilentlyContinue;if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}}
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

# Production mutation caught: the pre-capture plan exists only in memory, so a failed current
# overlap write permanently destroys the historical proof needed by the next process.
$results += Invoke-CcodTest 'second registration recovers from partial current overlap writes only through a durable pre-capture plan' {
    $outcomes=[Collections.Generic.List[string]]::new()
    foreach($failurePoint in @('DesktopWrite','CurrentReadBack')){
        $world=New-CcodRegistrationWorld;$world.SimulateOverlapWrites=$true;$world.Ready.startMenuSha256=[string]$world.CurrentShortcutProofs[$currentShortcutNames[0]].sha256;$world.Ready.desktopSha256=[string]$world.CurrentShortcutProofs[$currentShortcutNames[1]].sha256
        if($failurePoint-ceq'DesktopWrite'){$world.WriteShortcutFailure='Desktop'}else{$world.ReadProductFailure=$true}
        $firstPlan=Get-CcodProductTestLegacyMigrationPlan $world;$firstFailure=$null;try{Commit-CcodProductRegistration -Registration $world.Registration -FileTransaction ([pscustomobject]@{}) -Adapters $world.Adapters|Out-Null}catch{$firstFailure=$_}
        Assert-CcodEqual 'CCOD_PRODUCT_REGISTRATION_FAILED' (([string]$firstFailure.FullyQualifiedErrorId-split',')[0]) "$failurePoint first attempt fails after its intended overlap boundary"
        $firstPlan=$null;$world.WriteShortcutFailure=$null;$world.ReadProductFailure=$false
        $secondFailure=$null;$secondReceipt=$null;try{$secondPlan=Get-CcodProductTestLegacyMigrationPlan $world;$secondReceipt=Commit-CcodProductRegistration -Registration $world.Registration -FileTransaction ([pscustomobject]@{}) -Adapters $world.Adapters}catch{$secondFailure=$_}
        $outcome=if($null-ne$secondReceipt-and$secondReceipt.verified){'Recovered'}else{([string]$secondFailure.FullyQualifiedErrorId-split',')[0]};$outcomes.Add(('{0}:{1}'-f$failurePoint,$outcome))
    }
    Assert-CcodEqual 'DesktopWrite:Recovered|CurrentReadBack:Recovered' (@($outcomes)-join'|') 'a new process reuses durable historical evidence after either overlap failure'
}

# Production mutation caught: durable replay assumes Start-menu is always replaced before Desktop and rejects another valid crash ordering.
$results += Invoke-CcodTest 'durable replay converges all four independent historical and current overlap states' {
    foreach($state in @('HistoricalHistorical','CurrentHistorical','HistoricalCurrent','CurrentCurrent')){
        $world=New-CcodRegistrationWorld;$null=Get-CcodProductTestLegacyMigrationPlan $world
        if($state-in@('CurrentHistorical','CurrentCurrent')){$world.LegacyShortcutProofs[$currentShortcutNames[0]]=$world.CurrentShortcutProofs[$currentShortcutNames[0]]}
        if($state-in@('HistoricalCurrent','CurrentCurrent')){$world.LegacyShortcutProofs[$currentShortcutNames[1]]=$world.CurrentShortcutProofs[$currentShortcutNames[1]]}
        $plan=Get-CcodProductTestLegacyMigrationPlan $world;$world.SimulateOverlapWrites=$true;$null=Commit-CcodProductRegistration -Registration $world.Registration -FileTransaction ([pscustomobject]@{}) -Adapters $world.Adapters
        Remove-CcodLegacyProductRegistration -ExpectedAppId $appId -MigrationPlan $plan -ExpectedCurrentProof $expectedVerifiedRegistration -Adapters $world.Adapters
        Assert-CcodEqual (($currentShortcutNames|Sort-Object)-join'|') ((@($world.LegacyEntries)|Sort-Object)-join'|') "$state converges to only the two exact current overlaps"
        Assert-CcodEqual 1 $world.LegacyMigrationPlanWrites "$state reuses one append-only plan"
    }
}

# Production mutation caught: a later idempotent registration mistakes already-completed exact legacy cleanup for evidence loss.
$results += Invoke-CcodTest 'durable migration replay continues every registry-first legacy cleanup crash boundary' {
    $legacyOnly=@($v2521ShortcutNames[1],$v2521ShortcutNames[2])
    foreach($removedCount in 0..2){
        $world=New-CcodRegistrationWorld;$world.SimulateOverlapWrites=$true;$null=Get-CcodProductTestLegacyMigrationPlan $world;$null=Commit-CcodProductRegistration -Registration $world.Registration -FileTransaction ([pscustomobject]@{}) -Adapters $world.Adapters
        [void]$world.LegacyEntries.Remove('Registry');for($index=0;$index-lt$removedCount;$index++){[void]$world.LegacyEntries.Remove($legacyOnly[$index])}
        $second=Get-CcodProductTestLegacyMigrationPlan $world
        Assert-CcodEqual $true $second.legacyPresent "registry-first crash boundary $removedCount retains the durable cleanup plan"
        $before=$world.LegacyRemoveAttempts;$null=Commit-CcodProductRegistration -Registration $world.Registration -FileTransaction ([pscustomobject]@{}) -Adapters $world.Adapters;Remove-CcodLegacyProductRegistration -ExpectedAppId $appId -MigrationPlan $second -ExpectedCurrentProof $expectedVerifiedRegistration -Adapters $world.Adapters
        Assert-CcodEqual (2-$removedCount) ($world.LegacyRemoveAttempts-$before) "registry-first crash boundary $removedCount removes only remaining exact legacy-only shortcuts"
        Assert-CcodEqual (($currentShortcutNames|Sort-Object)-join'|') ((@($world.LegacyEntries)|Sort-Object)-join'|') "registry-first crash boundary $removedCount converges without restoring removed entries"
        Assert-CcodEqual 1 $world.LegacyMigrationPlanWrites "registry-first crash boundary $removedCount preserves one append-only plan"
    }
    $partial=New-CcodRegistrationWorld;$partial.SimulateOverlapWrites=$true;$null=Get-CcodProductTestLegacyMigrationPlan $partial;$null=Commit-CcodProductRegistration -Registration $partial.Registration -FileTransaction ([pscustomobject]@{}) -Adapters $partial.Adapters;[void]$partial.LegacyEntries.Remove($legacyOnly[0]);$plan=Get-CcodProductTestLegacyMigrationPlan $partial;$null=Commit-CcodProductRegistration -Registration $partial.Registration -FileTransaction ([pscustomobject]@{}) -Adapters $partial.Adapters;Remove-CcodLegacyProductRegistration -ExpectedAppId $appId -MigrationPlan $plan -ExpectedCurrentProof $expectedVerifiedRegistration -Adapters $partial.Adapters
    Assert-CcodEqual (($currentShortcutNames|Sort-Object)-join'|') ((@($partial.LegacyEntries)|Sort-Object)-join'|') 'registry-present partial legacy-only cleanup also converges absent-or-exact'
    $foreign=New-CcodRegistrationWorld;$foreign.SimulateOverlapWrites=$true;$null=Get-CcodProductTestLegacyMigrationPlan $foreign;$null=Commit-CcodProductRegistration -Registration $foreign.Registration -FileTransaction ([pscustomobject]@{}) -Adapters $foreign.Adapters;[void]$foreign.LegacyEntries.Remove('Registry');$bytes=[Text.UTF8Encoding]::new($false).GetBytes('foreign-legacy-only');$foreign.LegacyShortcutProofs[$legacyOnly[0]]=[pscustomobject][ordered]@{targetPath=$canonicalTaskTarget;arguments='foreign';workingDirectory='';sha256=(Get-CcodTestBytesSha256 $bytes);bytesBase64=[Convert]::ToBase64String($bytes)}
    Assert-CcodThrows {Get-CcodProductTestLegacyMigrationPlan $foreign|Out-Null} 'CCOD_LEGACY_PRODUCT_REGISTRATION_INVALID'
}

# Production mutations caught: accepting a washed hybrid without a plan, or trusting changed durable identity/evidence.
$results += Invoke-CcodTest 'durable migration plan rejects absent tampered foreign and wrong Ready identities before current writes' {
    $absent=New-CcodRegistrationWorld;$foreignBytes=[Text.UTF8Encoding]::new($false).GetBytes('foreign-current-overlap');$foreignSha=Get-CcodTestBytesSha256 $foreignBytes
    $absent.LegacyShortcutProofs[$currentShortcutNames[0]]=[pscustomobject][ordered]@{targetPath=$canonicalTaskTarget;arguments='/Run /TN "foreign"';workingDirectory='';sha256=$foreignSha;bytesBase64=[Convert]::ToBase64String($foreignBytes)}
    Assert-CcodThrows {Get-CcodProductTestLegacyMigrationPlan $absent|Out-Null} 'CCOD_LEGACY_PRODUCT_REGISTRATION_INVALID'
    Assert-CcodEqual 0 $absent.LegacyMigrationPlanWrites 'washed hybrid without a prior plan publishes no replacement authority'
    Assert-CcodEqual 0 $absent.Shortcuts.Count 'washed hybrid without a prior plan performs zero current shortcut writes'

    $oversized=New-CcodRegistrationWorld;$oversizedBytes=[byte[]]::new(262145);$oversizedName=$v2521ShortcutNames[1];$oversizedProof=$oversized.LegacyShortcutProofs[$oversizedName];$oversizedProof.bytesBase64=[Convert]::ToBase64String($oversizedBytes);$oversizedProof.sha256=Get-CcodTestBytesSha256 $oversizedBytes
    Assert-CcodThrows {Get-CcodProductTestLegacyMigrationPlan $oversized|Out-Null} 'CCOD_LEGACY_PRODUCT_REGISTRATION_INVALID'
    Assert-CcodEqual 0 $oversized.LegacyMigrationPlanWrites 'oversized historical shortcut is rejected before durable publication'

    foreach($inconsistency in @('Generation','Manifest','TransactionPackage')){$world=New-CcodRegistrationWorld;$world.Ready.transactionRecord=(($world.Ready.transactionRecord|ConvertTo-Json -Depth 8 -Compress)|ConvertFrom-Json);if($inconsistency-ceq'Generation'){$world.Ready.runtimeGeneration=[uint64]8}elseif($inconsistency-ceq'Manifest'){$world.Ready.manifestSha256='e'*64}else{$world.Ready.transactionRecord.sealedPackageSha256='e'*64};Assert-CcodThrows {Get-CcodProductTestLegacyMigrationPlan $world|Out-Null} 'CCOD_LEGACY_PRODUCT_REGISTRATION_INVALID';Assert-CcodEqual 0 $world.LegacyMigrationPlanWrites "$inconsistency inconsistent Ready proof publishes no plan"}

    foreach($mutation in @('TamperedCurrentProof','WrongReady','WrongPackage','WrongGeneration','Duplicate','UnsafeShortcut','ForeignHybrid')){
        $world=New-CcodRegistrationWorld;$null=Get-CcodProductTestLegacyMigrationPlan $world
        if($mutation-ceq'ForeignHybrid'){
            $world.LegacyShortcutProofs[$currentShortcutNames[0]]=[pscustomobject][ordered]@{targetPath=$canonicalTaskTarget;arguments='/Run /TN "foreign"';workingDirectory='';sha256=$foreignSha;bytesBase64=[Convert]::ToBase64String($foreignBytes)}
        }else{
            $json=[Text.UTF8Encoding]::new($false,$true).GetString($world.LegacyMigrationPlanBytes)
            if($mutation-ceq'Duplicate'){$json=$json.Replace('{"schemaVersion":1','{"schemaVersion":1,"schemaVersion":1')}
            else{
                $record=$json|ConvertFrom-Json -ErrorAction Stop
                switch($mutation){
                    'TamperedCurrentProof' {$record.expectedCurrentProof.shortcuts[0].candidateSha256='f'*64}
                    'WrongReady' {$record.readyTransaction.transactionId='aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'}
                    'WrongPackage' {$record.packageSha256='e'*64}
                    'WrongGeneration' {$record.runtimeGeneration=[uint64]8}
                    'UnsafeShortcut' {$record.snapshot.entries[1].path='C:\outside\foreign.lnk'}
                }
                $json=($record|ConvertTo-Json -Depth 32 -Compress)+"`n"
            }
            $world.LegacyMigrationPlanBytes=[Text.UTF8Encoding]::new($false).GetBytes($json)
        }
        Assert-CcodThrows {Get-CcodProductTestLegacyMigrationPlan $world|Out-Null} 'CCOD_LEGACY_PRODUCT_REGISTRATION_INVALID'
        Assert-CcodEqual 1 $world.LegacyMigrationPlanWrites "$mutation never republishes or overwrites the first plan"
        Assert-CcodEqual 0 $world.Shortcuts.Count "$mutation fails before a current shortcut write"
        Assert-CcodEqual $null $world.Product "$mutation fails before a current registry write"
    }
}

# Production mutation caught: persisted nested evidence is accepted by normalized meaning instead of exact canonical bytes and order.
$results += Invoke-CcodTask2Fix1ProductTest 'schema' 'durable plan requires exact six-field profile and raw canonical identity paths' {
    foreach($mutation in @('ProfileExtra','ProfileMissing','ProfileReordered','ProfileValue','ExpectedRoot','ShortcutPath','ShortcutTarget','ShortcutWorking')){
        $world=New-CcodRegistrationWorld;$null=Get-CcodProductTestLegacyMigrationPlan $world;$json=[Text.UTF8Encoding]::new($false,$true).GetString($world.LegacyMigrationPlanBytes);$record=$json|ConvertFrom-Json -ErrorAction Stop
        switch($mutation){
            'ProfileExtra' {$record.profile|Add-Member -NotePropertyName unexpected -NotePropertyValue 'foreign'}
            'ProfileMissing' {$record.profile.PSObject.Properties.Remove('minimumVersion')}
            'ProfileReordered' {$names=@($record.profile.PSObject.Properties.Name);$profile=[ordered]@{};for($index=$names.Count-1;$index-ge0;$index--){$profile[$names[$index]]=$record.profile.($names[$index])};$record.profile=[pscustomobject]$profile}
            'ProfileValue' {$record.profile.minimumVersion='2.2.1'}
            'ExpectedRoot' {$record.expectedInstallRoot=[string]$record.expectedInstallRoot+'\.'}
            'ShortcutPath' {$entry=@($record.snapshot.entries|Where-Object{$_.kind-ceq'Shortcut'})[0];$entry.path=(Split-Path ([string]$entry.path) -Parent)+'\.\'+[IO.Path]::GetFileName([string]$entry.path)}
            'ShortcutTarget' {$entry=@($record.snapshot.entries|Where-Object{$_.kind-ceq'Shortcut'})[0];$entry.targetPath=(Split-Path ([string]$entry.targetPath) -Parent)+'\.\'+[IO.Path]::GetFileName([string]$entry.targetPath)}
            'ShortcutWorking' {$entry=@($record.snapshot.entries|Where-Object{$_.kind-ceq'Shortcut'-and-not[string]::IsNullOrEmpty([string]$_.workingDirectory)})[0];$entry.workingDirectory=[string]$entry.workingDirectory+'\.'}
        }
        $world.LegacyMigrationPlanBytes=[Text.UTF8Encoding]::new($false).GetBytes(($record|ConvertTo-Json -Depth 32 -Compress)+"`n")
        Assert-CcodThrows {Get-CcodProductTestLegacyMigrationPlan $world|Out-Null} 'CCOD_LEGACY_PRODUCT_REGISTRATION_INVALID'
        Assert-CcodEqual 1 $world.LegacyMigrationPlanWrites "$mutation never republishes the changed durable plan"
        Assert-CcodEqual 0 $world.Shortcuts.Count "$mutation fails before current shortcut writes"
    }
    $exact=New-CcodRegistrationWorld;$null=Get-CcodProductTestLegacyMigrationPlan $exact;$persisted=[Text.UTF8Encoding]::new($false,$true).GetString($exact.LegacyMigrationPlanBytes)|ConvertFrom-Json -ErrorAction Stop
    Assert-CcodEqual 'profileId,appId,minimumVersion,maximumVersion,uninstallCommandShape,shortcutNames' (($persisted.profile.PSObject.Properties.Name)-join',') 'persisted profile has the six canonical fields in canonical order'
}

# Production mutation caught: a post-publish exception or read-back error causes the later process to republish instead of consuming the exact existing plan.
$results += Invoke-CcodTask2Fix1ProductTest 'replay' 'published writer and read-back failures converge without duplicate plan publication' {
    foreach($failure in @('PublishedThenThrow','PostWriteReadBack')){
        $world=New-CcodRegistrationWorld;if($failure-ceq'PublishedThenThrow'){$world.LegacyMigrationPlanWriteMode='PublishedThenThrow'}else{$world.LegacyMigrationPlanReadFailureAt=2}
        Assert-CcodThrows {Get-CcodProductTestLegacyMigrationPlan $world|Out-Null} 'CCOD_LEGACY_PRODUCT_REGISTRATION_INVALID'
        Assert-CcodEqual 1 $world.LegacyMigrationPlanWrites "$failure first invocation published exactly once"
        Assert-CcodTrue ($null-ne$world.LegacyMigrationPlanBytes) "$failure first invocation left the exact published bytes"
        Assert-CcodEqual 0 $world.Shortcuts.Count "$failure first invocation performs zero current shortcut writes"
        Assert-CcodEqual $null $world.Product "$failure first invocation performs zero current registry writes"
        $plan=Get-CcodProductTestLegacyMigrationPlan $world;$world.SimulateOverlapWrites=$true;$null=Commit-CcodProductRegistration -Registration $world.Registration -FileTransaction ([pscustomobject]@{}) -Adapters $world.Adapters;Remove-CcodLegacyProductRegistration -ExpectedAppId $appId -MigrationPlan $plan -ExpectedCurrentProof $expectedVerifiedRegistration -Adapters $world.Adapters
        Assert-CcodEqual 1 $world.LegacyMigrationPlanWrites "$failure later invocation never republishes"
        Assert-CcodEqual (($currentShortcutNames|Sort-Object)-join'|') ((@($world.LegacyEntries)|Sort-Object)-join'|') "$failure later invocation converges from the existing plan"
    }

    $world=New-CcodRegistrationWorld;$null=Get-CcodProductTestLegacyMigrationPlan $world;$world.LegacyShortcutProofs[$currentShortcutNames[0]]=$world.CurrentShortcutProofs[$currentShortcutNames[0]]
    $profile=Resolve-CcodLegacyRegistrationProfile -LegacyRegistration $world.Legacy;$liveRegistration=&$world.Adapters.ReadLegacyRegistration $appId;$liveSnapshot=&$world.Adapters.ReadLegacySnapshot $appId $profile $null
    $payload=[ordered]@{module=$modulePath;appId=$appId;registration=$world.Registration;ready=$world.Ready;planBase64=[Convert]::ToBase64String($world.LegacyMigrationPlanBytes);legacyRegistration=$liveRegistration;legacySnapshot=$liveSnapshot}
    $child=@'
param([Parameter(Mandatory)][string]$PayloadPath)
$ErrorActionPreference='Stop'
$payload=[IO.File]::ReadAllText([IO.Path]::GetFullPath($PayloadPath),[Text.UTF8Encoding]::new($false,$true))|ConvertFrom-Json -ErrorAction Stop
Import-Module ([string]$payload.module) -Force -DisableNameChecking -ErrorAction Stop
function Get-BytesSha([byte[]]$Bytes){$sha=[Security.Cryptography.SHA256]::Create();try{[BitConverter]::ToString($sha.ComputeHash($Bytes)).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}}
$bytes=[Convert]::FromBase64String([string]$payload.planBase64);$writes=0
$adapters=@{
  ReadLegacyMigrationPlan={param($Ready)$copy=[byte[]]$bytes.Clone();[pscustomobject]@{Bytes=$copy;Length=[int64]$copy.LongLength;Sha256=(Get-BytesSha $copy)}}.GetNewClosure()
  WriteLegacyMigrationPlan={param($Ready,[byte[]]$Value)$writes++;throw 'CHILD_UNEXPECTED_REPUBLISH'}.GetNewClosure()
  ReadLegacyRegistration={param($ExpectedAppId)(($payload.legacyRegistration|ConvertTo-Json -Depth 16 -Compress)|ConvertFrom-Json)}.GetNewClosure()
  ReadLegacySnapshot={param($ExpectedAppId,$ExpectedProfile,$CapturedPlan)(($payload.legacySnapshot|ConvertTo-Json -Depth 32 -Compress)|ConvertFrom-Json)}.GetNewClosure()
}
$registration=(($payload.registration|ConvertTo-Json -Depth 16 -Compress)|ConvertFrom-Json);$ready=(($payload.ready|ConvertTo-Json -Depth 16 -Compress)|ConvertFrom-Json)
$plan=Get-CcodDurableLegacyProductRegistrationMigrationPlan -ExpectedAppId ([string]$payload.appId) -Registration $registration -ReadyEvidence $ready -Adapters $adapters
if($null-eq$plan-or-not$plan.legacyPresent-or$writes-ne0){throw 'CHILD_REPLAY_FAILED'}
[Console]::Out.WriteLine('CHILD_DURABLE_REPLAY_OK')
'@
    $childRoot=Join-Path ([IO.Path]::GetTempPath()) ('ccod-product-replay-'+[guid]::NewGuid().ToString('N'));[IO.Directory]::CreateDirectory($childRoot)|Out-Null;$payloadPath=Join-Path $childRoot 'payload.json';$childPath=Join-Path $childRoot 'replay.ps1'
    try{[IO.File]::WriteAllText($payloadPath,($payload|ConvertTo-Json -Depth 32 -Compress),[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText($childPath,$child,[Text.UTF8Encoding]::new($false));$output=@(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $childPath -PayloadPath $payloadPath 2>&1);$exitCode=$LASTEXITCODE}finally{$full=[IO.Path]::GetFullPath($childRoot);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\';if(-not$full.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){throw 'refusing non-temp child cleanup'};if(Test-Path -LiteralPath $full){Remove-Item -LiteralPath $full -Recurse -Force}}
    Assert-CcodEqual 0 $exitCode 'fresh powershell process replays serialized durable/live evidence'
    Assert-CcodEqual 'CHILD_DURABLE_REPLAY_OK' ($output -join'') 'fresh powershell process consumes existing plan without parent object identity'
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
    $plan = Get-CcodProductTestLegacyMigrationPlan $world
    $receipt = Commit-CcodProductRegistration -Registration $world.Registration -FileTransaction ([pscustomobject]@{}) -Adapters $world.Adapters
    Assert-CcodTrue $receipt.verified 'registration returns a verified three-record receipt'
    Assert-CcodEqual 'ReadLegacy,Ready,WriteProduct,WriteShortcut:StartMenu,WriteShortcut:Desktop,ReadProduct,ReadShortcut:StartMenu,ReadShortcut:Desktop' ($world.Calls -join ',') 'legacy profile capture precedes all current writes and read-backs'
    Remove-CcodLegacyProductRegistration -ExpectedAppId $appId -MigrationPlan $plan -ExpectedCurrentProof $expectedVerifiedRegistration -Adapters $world.Adapters
    Assert-CcodEqual 3 $world.LegacyRemoveAttempts 'exact migration removes only the three non-current legacy entries'
    Assert-CcodEqual (($currentShortcutNames|Sort-Object)-join'|') ((@($world.LegacyEntries)|Sort-Object)-join'|') 'exact migration retains both verified current shortcut replacements'
}

# Production mutation caught: requiring the union of every historical shortcut name instead of
# selecting the one complete installer profile that produced the legacy registration.
$results += Invoke-CcodTest 'real v2.5.21 registration removes its exact four-shortcut profile' {
    $world = New-CcodRegistrationWorld
    $plan = Get-CcodProductTestLegacyMigrationPlan $world
    $null = Commit-CcodProductRegistration -Registration $world.Registration -FileTransaction ([pscustomobject]@{}) -Adapters $world.Adapters

    Remove-CcodLegacyProductRegistration -ExpectedAppId $appId -MigrationPlan $plan -ExpectedCurrentProof $expectedVerifiedRegistration -Adapters $world.Adapters

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
        $world.LegacyEntries.Clear();$world.LegacyEntries.Add('Registry');foreach($name in @($legacy.shortcutNames)){$world.LegacyEntries.Add([string]$name)}
        $before=@($world.LegacyEntries|Sort-Object)-join'|'
        Assert-CcodThrows { Resolve-CcodLegacyRegistrationProfile -LegacyRegistration $world.Legacy | Out-Null } 'CCOD_LEGACY_PRODUCT_REGISTRATION_INVALID'
        Assert-CcodThrows { Get-CcodProductTestLegacyMigrationPlan $world | Out-Null } 'CCOD_LEGACY_PRODUCT_REGISTRATION_INVALID'
        Assert-CcodEqual 0 $world.LegacyRemoveAttempts "$kind mismatch is rejected before any legacy deletion"
        Assert-CcodEqual $null $world.Product "$kind mismatch is rejected before the current registry write"
        Assert-CcodEqual 0 $world.Shortcuts.Count "$kind mismatch is rejected before either current shortcut write"
        Assert-CcodEqual $before ((@($world.LegacyEntries|Sort-Object))-join'|') "$kind mismatch preserves the complete exact legacy state"
    }
}

# Production mutation caught: keeping the historical fixed count of nine records either rejects a
# complete older profile or authorizes a same-count snapshot containing an unrelated entry.
$results += Invoke-CcodTest 'legacy snapshot count and names are derived from the selected historical profile' {
    foreach ($case in @(
        [pscustomobject]@{Version='2.1.0';Names=$v210ShortcutNames;RemovalCount=5;Remaining=$currentShortcutNames},
        [pscustomobject]@{Version='2.1.6';Names=$v211ShortcutNames;RemovalCount=6;Remaining=$currentShortcutNames},
        [pscustomobject]@{Version='2.5.21';Names=$v2521ShortcutNames;RemovalCount=3;Remaining=$currentShortcutNames}
    )) {
        $world = New-CcodRegistrationWorld
        Set-CcodRegistrationLegacyFixture -World $world -Version $case.Version -ShortcutNames $case.Names
        $plan = Get-CcodProductTestLegacyMigrationPlan $world
        $null = Commit-CcodProductRegistration -Registration $world.Registration -FileTransaction ([pscustomobject]@{}) -Adapters $world.Adapters
        Remove-CcodLegacyProductRegistration -ExpectedAppId $appId -MigrationPlan $plan -ExpectedCurrentProof $expectedVerifiedRegistration -Adapters $world.Adapters
        Assert-CcodEqual $case.RemovalCount $world.LegacyRemoveAttempts "$($case.Version) removes only legacy entries not replaced by exact current shortcuts"
        Assert-CcodEqual ((@($case.Remaining)|Sort-Object)-join'|') ((@($world.LegacyEntries)|Sort-Object)-join'|') "$($case.Version) leaves exactly its verified current replacement set"
    }

    $world = New-CcodRegistrationWorld
    $plan = Get-CcodProductTestLegacyMigrationPlan $world
    $null = Commit-CcodProductRegistration -Registration $world.Registration -FileTransaction ([pscustomobject]@{}) -Adapters $world.Adapters
    [void]$world.LegacyEntries.Remove($v2521ShortcutNames[3])
    $world.LegacyEntries.Add('Programs\CodexRemote-fix\unexpected.lnk')
    Assert-CcodThrows { Remove-CcodLegacyProductRegistration -ExpectedAppId $appId -MigrationPlan $plan -ExpectedCurrentProof $expectedVerifiedRegistration -Adapters $world.Adapters } 'CCOD_LEGACY_PRODUCT_REGISTRATION_INVALID'
    Assert-CcodEqual 0 $world.LegacyRemoveAttempts 'same-count foreign snapshot is rejected before the first deletion'
}

$results += Invoke-CcodTest 'overlapping legacy names require exact current shortcut hashes before deletion' {
    $world=New-CcodRegistrationWorld
    $world.LegacySnapshotHashOverrides[$currentShortcutNames[0]]='d'*64
    Assert-CcodThrows {Get-CcodProductTestLegacyMigrationPlan $world|Out-Null} 'CCOD_LEGACY_PRODUCT_REGISTRATION_INVALID'
    Assert-CcodEqual 0 $world.LegacyRemoveAttempts 'mismatched replacement hash is rejected before any legacy deletion'
    Assert-CcodEqual $null $world.Product 'mismatched captured bytes are rejected before current product writes'
    Assert-CcodEqual 5 $world.LegacyEntries.Count 'mismatched replacement hash preserves every observed entry'
}

$results += Invoke-CcodTest 'current registration drift after cleanup restores every removed legacy-only entry' {
    $world=New-CcodRegistrationWorld
    $world.VerifiedRegistrationMutationAt=2
    $before=@($world.LegacyEntries)|Sort-Object
    $plan=Get-CcodProductTestLegacyMigrationPlan $world
    $null=Commit-CcodProductRegistration -Registration $world.Registration -FileTransaction ([pscustomobject]@{}) -Adapters $world.Adapters
    Assert-CcodThrows {Remove-CcodLegacyProductRegistration -ExpectedAppId $appId -MigrationPlan $plan -ExpectedCurrentProof $expectedVerifiedRegistration -Adapters $world.Adapters} 'CCOD_LEGACY_PRODUCT_REGISTRATION_INVALID'
    Assert-CcodEqual 3 $world.LegacyRemoveAttempts 'post-cleanup proof drift occurs only after the three legacy-only entries were removed'
    Assert-CcodEqual ($before-join'|') ((@($world.LegacyEntries)|Sort-Object)-join'|') 'post-cleanup proof drift compensates the complete removed legacy-only set'
    Assert-CcodEqual (($v2521ShortcutNames[2],$v2521ShortcutNames[1],'Registry')-join'|') (@($world.LegacyRestoreOrder)-join'|') 'post-cleanup proof drift restores legacy-only entries in reverse order'
}

# Production mutation caught: accepting an unexpected AppId/name set or an unverified registration receipt.
$results += Invoke-CcodTest 'legacy migration rejects AppId shortcut and current-proof mismatches without deletion' {
    foreach ($mismatch in @('AppId','Shortcut','Receipt','CurrentProofHash','CurrentProofNames')) {
        $world = New-CcodRegistrationWorld
        $plan = Get-CcodProductTestLegacyMigrationPlan $world
        $receipt = Commit-CcodProductRegistration -Registration $world.Registration -FileTransaction ([pscustomobject]@{}) -Adapters $world.Adapters
        if ($mismatch -ceq 'AppId') { $plan.legacyRegistration.appId = '{AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE}' }
        if ($mismatch -ceq 'Shortcut') { $plan.legacyRegistration.shortcutNames = @('Programs\unexpected.lnk') }
        if ($mismatch -ceq 'Receipt') { $world.Product = $null }
        if ($mismatch -in @('CurrentProofHash','CurrentProofNames')) {
            $readVerified=$world.Adapters.ReadVerifiedRegistration
            $world.Adapters.ReadVerifiedRegistration={
                $proof=&$readVerified
                if($mismatch-ceq'CurrentProofHash'){$proof.startMenuSha256='d'*64}else{$proof.shortcutNames=@($currentShortcutNames[0])}
                $proof
            }.GetNewClosure()
        }
        Assert-CcodThrows { Remove-CcodLegacyProductRegistration -ExpectedAppId $appId -MigrationPlan $plan -ExpectedCurrentProof $expectedVerifiedRegistration -Adapters $world.Adapters } 'CCOD_LEGACY_PRODUCT_REGISTRATION_INVALID'
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
    $plan=Get-CcodProductTestLegacyMigrationPlan $world
    $receipt=Commit-CcodProductRegistration -Registration $world.Registration -FileTransaction ([pscustomobject]@{}) -Adapters $world.Adapters
    $before=@($world.LegacyEntries)|Sort-Object
    $world.LegacyRemoveFailureAt=3
    Assert-CcodThrows {Remove-CcodLegacyProductRegistration -ExpectedAppId $appId -MigrationPlan $plan -ExpectedCurrentProof $expectedVerifiedRegistration -Adapters $world.Adapters} 'CCOD_LEGACY_PRODUCT_REGISTRATION_INVALID'
    Assert-CcodEqual ($before-join'|') ((@($world.LegacyEntries)|Sort-Object)-join'|') 'failed migration restores the complete exact legacy set'
    Assert-CcodEqual 2 $world.LegacyRestores 'only successfully removed legacy-only entries are restored'
    Assert-CcodEqual (($v2521ShortcutNames[1],'Registry')-join'|') (@($world.LegacyRestoreOrder)-join'|') 'successful legacy-only deletions are compensated in exact reverse order'
}

$results += Invoke-CcodTest 'native registry create-only boundary loads without opening or changing a key' {
    $native=&$module {Initialize-CcodLegacyRegistryNative;[pscustomobject]@{Create=$null-ne[CcodLegacyRegistryNativeV1].GetMethod('CreateCurrentUserKey');Compare=$null-ne[CcodLegacyRegistryNativeV1].GetMethod('IsSameKey');Delete=$null-ne[CcodLegacyRegistryNativeV1].GetMethod('DeleteKey')}}
    Assert-CcodTrue ($native.Create-and$native.Compare-and$native.Delete) 'native boundary exposes only create-with-disposition compare-handle and delete-by-handle operations used by compensation'
}

$results += Invoke-CcodTest 'installed resume registry publish converges only exact old-new partial transitions' {
    $original=[ordered]@{DisplayName='CodexRemote-fix';UninstallString='old-command';QuietUninstallString='old-quiet'}
    $expected=[ordered]@{DisplayName='CodexRemote-fix';UninstallString='resume-command';QuietUninstallString='resume-command';CcodUninstallTransactionId='11111111-2222-3333-4444-555555555555';CcodUninstallResumeScriptSha256=('a'*64)}
    $kinds=[ordered]@{DisplayName='String';UninstallString='String';QuietUninstallString='String';CcodUninstallTransactionId='String';CcodUninstallResumeScriptSha256='String'}
    $world=[pscustomobject]@{ReplacementWrites=0}
    $partial=New-CcodFix1RegistryKey -Id Partial -Values ([ordered]@{DisplayName='CodexRemote-fix';UninstallString='resume-command';QuietUninstallString='old-quiet';CcodUninstallTransactionId='11111111-2222-3333-4444-555555555555'}) -Kinds ([ordered]@{DisplayName='String';UninstallString='String';QuietUninstallString='String';CcodUninstallTransactionId='String'}) -World $world
    $accepted=&$module {param($Key,$Old,$New,$Kinds)Test-CcodInstalledResumeRegistryTransition -Key $Key -Original $Old -Expected $New -ExpectedKinds $Kinds} $partial $original $expected $kinds
    Assert-CcodTrue $accepted 'crash after exact metadata and one command write remains safely convergent'
    $partial.Values.CcodUninstallTransactionId='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
    $foreign=&$module {param($Key,$Old,$New,$Kinds)Test-CcodInstalledResumeRegistryTransition -Key $Key -Original $Old -Expected $New -ExpectedKinds $Kinds} $partial $original $expected $kinds
    Assert-CcodEqual $false $foreign 'foreign partial recovery metadata cannot be overwritten or accepted'
    $partial.Values.CcodUninstallTransactionId='11111111-2222-3333-4444-555555555555';$partial.Values.Unexpected='foreign';$partial.Kinds.Unexpected='String'
    $unknown=&$module {param($Key,$Old,$New,$Kinds)Test-CcodInstalledResumeRegistryTransition -Key $Key -Original $Old -Expected $New -ExpectedKinds $Kinds} $partial $original $expected $kinds
    Assert-CcodEqual $false $unknown 'unknown recovery values fail closed instead of being normalized'
}

$results += Invoke-CcodTest 'create-only registry compensation accepts only a newly created exact key' {
    $result=Invoke-CcodFix1RegistryCompensationScenario -Mode CreateNew
    Assert-CcodEqual 1 $result.World.NativeCreateCalls 'fully absent registry compensation performs exactly one native create-only open'
    Assert-CcodEqual 0 $result.World.ProviderNewItemCalls 'new registry restoration never uses provider New-Item -Force'
    Assert-CcodEqual '{"DisplayName":"captured-product","NoModify":1}' ($result.World.Created.Values|ConvertTo-Json -Compress) 'newly created key is restored to the exact captured values'
    Assert-CcodEqual '{"DisplayName":"String","NoModify":"DWord"}' ($result.World.Created.Kinds|ConvertTo-Json -Compress) 'newly created key is restored to the exact captured value kinds'
    Assert-CcodEqual 'CCOD_LEGACY_PRODUCT_REGISTRATION_INVALID' (([string]$result.Failure.FullyQualifiedErrorId-split',')[0]) 'later failure reports ordinary restored rollback only after exact create-only compensation'
    Assert-CcodEqual 0 $result.World.CompensationRecords.Count 'exact newly created restoration needs no unresolved record'
}

$results += Invoke-CcodTest 'create-only registry compensation preserves a replacement that wins the restore race' {
    $result=Invoke-CcodFix1RegistryCompensationScenario -Mode CreateOpened
    Assert-CcodEqual $result.ReplacementBefore ($result.World.Replacement.Values|ConvertTo-Json -Compress) 'opened-existing restore disposition leaves replacement values unchanged'
    Assert-CcodEqual $result.ReplacementKindsBefore ($result.World.Replacement.Kinds|ConvertTo-Json -Compress) 'opened-existing restore disposition leaves replacement kinds unchanged'
    Assert-CcodEqual 0 $result.World.ReplacementWrites 'opened-existing restore disposition performs zero value writes'
    Assert-CcodEqual 1 $result.World.NativeCreateCalls 'fully deleted registry compensation attempts exactly one native create-only open'
    Assert-CcodEqual 0 $result.World.ProviderNewItemCalls 'registry compensation never falls back to provider New-Item -Force'
    Assert-CcodEqual 'CCOD_LEGACY_PRODUCT_COMPENSATION_FAILED' (([string]$result.Failure.FullyQualifiedErrorId-split',')[0]) 'opened-existing restore disposition remains explicitly unresolved'
    Assert-CcodEqual 'Registry' (@($result.World.CompensationRecords[0].entries)-join'|') 'replacement race records only Registry as unresolved'
}

# Production mutation caught: disposing the partially deleted original registry handle and then
# filling missing values by path writes captured data into a replacement key at the same name.
$results += Invoke-CcodTest 'partial registry compensation never writes captured values into a replacement key' {
    $result=Invoke-CcodFix1RegistryCompensationScenario -Mode PartialReplacement
    Assert-CcodEqual 2 $result.World.Original.DeleteCalls "production registry remover reaches the injected mid-delete failure after one value deletion; lower=$($result.World.LowerFailure.Exception.Message)"
    Assert-CcodEqual $result.ReplacementBefore ($result.World.Replacement.Values|ConvertTo-Json -Compress) 'replacement registry values remain byte-for-byte unchanged'
    Assert-CcodEqual $result.ReplacementKindsBefore ($result.World.Replacement.Kinds|ConvertTo-Json -Compress) 'replacement registry value kinds remain unchanged'
    Assert-CcodEqual 0 $result.World.ReplacementWrites 'captured values are written only through the original open registry handle'
    Assert-CcodEqual 2 $result.World.Original.Values.Count 'partial deletion restores the complete captured value set through the still-open original handle'
    Assert-CcodEqual 'captured-product' $result.World.Original.Values.DisplayName 'same-handle restoration restores the captured string value'
    Assert-CcodEqual 1 $result.World.Original.Values.NoModify 'same-handle restoration restores the captured DWORD value'
    Assert-CcodEqual 0 $result.World.NativeCreateCalls 'unproven partial deletion never falls back to path-level create'
    Assert-CcodEqual 0 $result.World.ProviderNewItemCalls 'unproven partial deletion never uses provider New-Item -Force'
    Assert-CcodEqual 'CCOD_LEGACY_PRODUCT_COMPENSATION_FAILED' (([string]$result.Failure.FullyQualifiedErrorId-split',')[0]) 'replacement during partial registry compensation remains explicitly unresolved'
    Assert-CcodEqual 1 $result.World.CompensationRecords.Count 'one create-only unresolved compensation record is persisted'
    Assert-CcodEqual 'Registry' (@($result.World.CompensationRecords[0].entries)-join'|') 'the unresolved record names only the displaced Registry entry'
}

$results += Invoke-CcodTest 'legacy compensation never overwrites a replacement that appeared after deletion' {
    $world=New-CcodRegistrationWorld;$plan=Get-CcodProductTestLegacyMigrationPlan $world;$null=Commit-CcodProductRegistration -Registration $world.Registration -FileTransaction ([pscustomobject]@{}) -Adapters $world.Adapters;$world.LegacyRemoveFailureAt=3;$world.LegacyReplacementEntry=$v2521ShortcutNames[1]
    Assert-CcodThrows {Remove-CcodLegacyProductRegistration -ExpectedAppId $appId -MigrationPlan $plan -ExpectedCurrentProof $expectedVerifiedRegistration -Adapters $world.Adapters} 'CCOD_LEGACY_PRODUCT_COMPENSATION_FAILED'
    Assert-CcodEqual 1 $world.LegacyRestores 'compensation restores only entries that remain absent'
    Assert-CcodTrue (-not$world.LegacyEntries.Contains($v2521ShortcutNames[1])) 'replacement occupies the removed name and is not overwritten with captured bytes'
    Assert-CcodEqual 1 $world.LegacyUnresolvedRecords.Count 'replacement-blocked restoration is recorded explicitly'
}

$results += Invoke-CcodTest 'legacy restore failure is explicit and records the unresolved exact entries' {
    $world=New-CcodRegistrationWorld;$plan=Get-CcodProductTestLegacyMigrationPlan $world;$null=Commit-CcodProductRegistration -Registration $world.Registration -FileTransaction ([pscustomobject]@{}) -Adapters $world.Adapters;$world.LegacyRemoveFailureAt=3;$world.LegacyRestoreFailureEntry=$v2521ShortcutNames[1]
    Assert-CcodThrows {Remove-CcodLegacyProductRegistration -ExpectedAppId $appId -MigrationPlan $plan -ExpectedCurrentProof $expectedVerifiedRegistration -Adapters $world.Adapters} 'CCOD_LEGACY_PRODUCT_COMPENSATION_FAILED'
    Assert-CcodEqual 1 $world.LegacyUnresolvedRecords.Count 'failed compensation writes one explicit unresolved record'
    Assert-CcodTrue (@($world.LegacyUnresolvedRecords[0].entries)-ccontains$v2521ShortcutNames[1]) 'unresolved record names the exact entry whose restoration failed'
}

$results += Invoke-CcodTest 'partially removed current registry entry is included in unresolved compensation' {
    $world=New-CcodRegistrationWorld;$plan=Get-CcodProductTestLegacyMigrationPlan $world;$null=Commit-CcodProductRegistration -Registration $world.Registration -FileTransaction ([pscustomobject]@{}) -Adapters $world.Adapters;$world.LegacyRemoveFailureAt=1;$world.LegacyRestoreFailureEntry='Registry';$originalRemove=$world.Adapters.RemoveLegacyEntry;$world.Adapters.RemoveLegacyEntry={param($Entry)$name=if($Entry-is[string]){[string]$Entry}elseif($Entry.kind-ceq'Registry'){'Registry'}else{[string]$Entry.name};if($name-ceq'Registry'){[void]$world.LegacyEntries.Remove('Registry');throw 'partial registry failure'};&$originalRemove $Entry}.GetNewClosure()
    Assert-CcodThrows {Remove-CcodLegacyProductRegistration -ExpectedAppId $appId -MigrationPlan $plan -ExpectedCurrentProof $expectedVerifiedRegistration -Adapters $world.Adapters} 'CCOD_LEGACY_PRODUCT_COMPENSATION_FAILED'
    Assert-CcodTrue (@($world.LegacyUnresolvedRecords[0].entries)-ccontains'Registry') 'current partially removed registry entry is recorded unresolved'
}

$results += Invoke-CcodTest 'legacy registry snapshot comparison treats a present partial key as unresolved compensation' {
    $captured=[pscustomobject]@{kind='Registry';path='HKCU:\fixture';values=[ordered]@{DisplayName=[pscustomobject]@{value='Codex';kind='String'};NoModify=[pscustomobject]@{value=1;kind='DWord'}}}
    $partial=[pscustomobject]@{kind='Registry';path='HKCU:\fixture';values=[ordered]@{DisplayName=[pscustomobject]@{value='Codex';kind='String'}}}
    $state=&$module {param($Expected,$Current)Compare-CcodLegacySnapshotEntry -Expected $Expected -Current $Current} $captured $partial
    Assert-CcodEqual 'Mismatch' $state 'a still-present key missing one captured value is not restored'
    $world=New-CcodRegistrationWorld;$plan=Get-CcodProductTestLegacyMigrationPlan $world;$null=Commit-CcodProductRegistration -Registration $world.Registration -FileTransaction ([pscustomobject]@{}) -Adapters $world.Adapters;$world.LegacyRemoveFailureAt=1;$world.Adapters.RemoveLegacyEntry={param($Entry)$name=if($Entry-is[string]){[string]$Entry}elseif($Entry.kind-ceq'Registry'){'Registry'}else{[string]$Entry.name};if($name-ceq'Registry'){$world.LegacyRemoveAttempts++;throw 'partial registry removal and internal restore failed'}}.GetNewClosure();$world.Adapters.ReadLegacyEntry={param($Entry)$name=if($Entry-is[string]){[string]$Entry}elseif($Entry.kind-ceq'Registry'){'Registry'}else{[string]$Entry.name};if($name-ceq'Registry'-and$world.LegacyRemoveAttempts-gt0){return $state};if($world.LegacyEntries.Contains($name)){return 'Exact'};$null}.GetNewClosure()
    Assert-CcodThrows {Remove-CcodLegacyProductRegistration -ExpectedAppId $appId -MigrationPlan $plan -ExpectedCurrentProof $expectedVerifiedRegistration -Adapters $world.Adapters} 'CCOD_LEGACY_PRODUCT_COMPENSATION_FAILED'
    Assert-CcodTrue (@($world.LegacyUnresolvedRecords[0].entries)-ccontains'Registry') 'partial registry key is persisted in the unresolved create-only record'
}

Write-Output "Product registration self-tests passed: $($results.Count)"
