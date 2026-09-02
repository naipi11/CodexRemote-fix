Set-StrictMode -Version Latest

$script:CcodProductVersion = '2.5.22'
$script:CcodProductAppId = '{2B9E9F2E-7A32-4A7E-9C1D-9F5B5C6D7E8F}'
$script:CcodProductKeyName = 'CodexRemote-fix'
$script:CcodProductFields = @(
    'schemaVersion','installRoot','runtimeId','version','packageSha256','runtimeRoot','bootstrapPath','uninstallerPath',
    'productKeyName','startMenuShortcut','desktopShortcut'
)
$script:CcodShortcutFields = @('kind','leaf','relativePath','candidatePath','bootstrapPath','installRoot')
$script:CcodReadyFields = @('phase','runtimeId','version','packageSha256','runtimeGeneration','manifestSha256','startMenuSha256','desktopSha256','targetPath','arguments','transactionRecord','bootstrapPath','uninstallerPath')
$script:CcodLegacyRegistrationFields = @('appId','displayVersion','installLocation','uninstallString','shortcutNames','unsafeShortcutNames')
$script:CcodLegacyProfileFields = @('profileId','appId','minimumVersion','maximumVersion','uninstallCommandShape','shortcutNames')
$script:CcodLegacyMigrationPlanFields = @('appId','expectedInstallRoot','legacyPresent','legacyRegistration','profile','snapshot')
$script:CcodLegacyShortcutSnapshotFields = @('kind','name','path','sha256','bytesBase64','targetPath','arguments','workingDirectory')
$script:CcodVerifiedRegistrationFields = @('verified','runtimeId','version','packageSha256','shortcutNames','startMenuSha256','desktopSha256')
$script:CcodCurrentShortcutNames = @('Programs\CodexRemote-fix\CodexRemote-fix.lnk','Desktop\CodexRemote-fix.lnk')
$script:CcodLegacyRegistryValueNames=@('DisplayName','DisplayVersion','UninstallString','QuietUninstallString','DisplayIcon','InstallLocation','Publisher','URLInfoAbout','HelpLink','URLUpdateInfo','NoModify','NoRepair','InstallDate','MajorVersion','MinorVersion','VersionMajor','VersionMinor','EstimatedSize','Language','Inno Setup: App Path','Inno Setup: Icon Group','Inno Setup: Setup Version','Inno Setup: User')

function Throw-CcodProductRegistrationError {
    param([Parameter(Mandatory)][string]$Id,[Parameter(Mandatory)][string]$Message,$Target)
    throw [Management.Automation.ErrorRecord]::new(
        [InvalidOperationException]::new($Message),$Id,[Management.Automation.ErrorCategory]::InvalidData,$Target)
}

function Test-CcodProductExactProperties {
    param($Value,[Parameter(Mandatory)][string[]]$Names)
    if ($null -eq $Value) { return $false }
    $properties = @($Value.PSObject.Properties)
    if ($properties.Count -ne $Names.Count) { return $false }
    for ($index = 0; $index -lt $Names.Count; $index++) {
        if ($properties[$index].Name -cne $Names[$index]) { return $false }
    }
    return $true
}

function Test-CcodProductExactStringSet {
    param($Values,$ExpectedValues)
    $actual=@($Values);$expected=@($ExpectedValues)
    if($actual.Count-ne$expected.Count){return $false}
    $set=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($value in $actual){if($value-isnot[string]-or[string]::IsNullOrWhiteSpace([string]$value)-or-not$set.Add([string]$value)){return $false}}
    foreach($value in $expected){if($value-isnot[string]-or-not$set.Contains([string]$value)){return $false}}
    return $true
}

function Get-CcodLegacyRegistrationProfiles {
    [CmdletBinding()]
    param()
    $oldStartMenu=@(
        'Programs\Codex Control other devices\Codex Control other devices for Windows.lnk',
        'Programs\Codex Control other devices\Open the tray supervisor.lnk',
        'Programs\Codex Control other devices\Compatibility check.lnk',
        'Programs\Codex Control other devices\Uninstall Codex Control other devices.lnk'
    )
    $oldDesktop='Desktop\Codex '+[char]0x8BBE+[char]0x5907+[char]0x8FDE+[char]0x63A5+' (Device Connection).lnk'
    $rebranded=@(
        'Programs\CodexRemote-fix\CodexRemote-fix.lnk',
        'Programs\CodexRemote-fix\CodexRemote-fix compatibility check.lnk',
        'Programs\CodexRemote-fix\Uninstall CodexRemote-fix.lnk',
        'Desktop\CodexRemote-fix.lnk'
    )
    return @(
        [pscustomobject][ordered]@{profileId='CodexControlOtherDevicesInitial';appId=$script:CcodProductAppId;minimumVersion='2.1.0';maximumVersion='2.1.0';uninstallCommandShape='"{installLocation}\unins000.exe"';shortcutNames=@($oldStartMenu)},
        [pscustomobject][ordered]@{profileId='CodexControlOtherDevicesDesktop';appId=$script:CcodProductAppId;minimumVersion='2.1.1';maximumVersion='2.1.6';uninstallCommandShape='"{installLocation}\unins000.exe"';shortcutNames=@($oldStartMenu)+@($oldDesktop)},
        [pscustomobject][ordered]@{profileId='CodexRemoteFix';appId=$script:CcodProductAppId;minimumVersion='2.2.0';maximumVersion='2.5.21';uninstallCommandShape='"{installLocation}\unins000.exe"';shortcutNames=@($rebranded)}
    )
}

function Resolve-CcodLegacyRegistrationProfile {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$LegacyRegistration)
    if(-not(Test-CcodProductExactProperties $LegacyRegistration $script:CcodLegacyRegistrationFields)-or
       $LegacyRegistration.appId-isnot[string]-or[string]$LegacyRegistration.appId-cne$script:CcodProductAppId-or
       $LegacyRegistration.displayVersion-isnot[string]-or[string]$LegacyRegistration.displayVersion-cnotmatch'^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)$'-or
       $LegacyRegistration.installLocation-isnot[string]-or-not[IO.Path]::IsPathRooted([string]$LegacyRegistration.installLocation)-or
       $LegacyRegistration.uninstallString-isnot[string]-or$null-eq$LegacyRegistration.shortcutNames-or$null-eq$LegacyRegistration.unsafeShortcutNames-or
       @($LegacyRegistration.unsafeShortcutNames).Count-ne0){
        Throw-CcodProductRegistrationError 'CCOD_LEGACY_PRODUCT_REGISTRATION_INVALID' 'Legacy product registration evidence is incomplete or unsafe.' $LegacyRegistration
    }
    try{$installLocation=[IO.Path]::GetFullPath([string]$LegacyRegistration.installLocation).TrimEnd('\');$version=[version]::Parse([string]$LegacyRegistration.displayVersion)}catch{
        Throw-CcodProductRegistrationError 'CCOD_LEGACY_PRODUCT_REGISTRATION_INVALID' 'Legacy product registration paths or version are invalid.' $LegacyRegistration
    }
    if([string]::IsNullOrWhiteSpace($installLocation)-or[string]$LegacyRegistration.installLocation.TrimEnd('\')-cne$installLocation){
        Throw-CcodProductRegistrationError 'CCOD_LEGACY_PRODUCT_REGISTRATION_INVALID' 'Legacy installer location is not canonical.' $LegacyRegistration.installLocation
    }
    $matches=[Collections.Generic.List[object]]::new()
    foreach($profile in @(Get-CcodLegacyRegistrationProfiles)){
        if(-not(Test-CcodProductExactProperties $profile $script:CcodLegacyProfileFields)){continue}
        $minimum=[version]::Parse([string]$profile.minimumVersion);$maximum=[version]::Parse([string]$profile.maximumVersion)
        $expectedUninstall=[string]$profile.uninstallCommandShape.Replace('{installLocation}',$installLocation)
        if([string]$profile.appId-ceq[string]$LegacyRegistration.appId-and$version-ge$minimum-and$version-le$maximum-and
           [string]$LegacyRegistration.uninstallString-ceq$expectedUninstall-and
           (Test-CcodProductExactStringSet $LegacyRegistration.shortcutNames $profile.shortcutNames)){$matches.Add($profile)}
    }
    if($matches.Count-ne1){Throw-CcodProductRegistrationError 'CCOD_LEGACY_PRODUCT_REGISTRATION_INVALID' 'Legacy product entry does not match one complete historical installer profile.' $LegacyRegistration}
    return $matches[0]
}

function Test-CcodCurrentVerifiedRegistration {
    param($Proof)
    return (Test-CcodProductExactProperties $Proof $script:CcodVerifiedRegistrationFields) -and
        $Proof.verified-is[bool] -and [bool]$Proof.verified -and
        $Proof.runtimeId-is[string] -and [string]$Proof.runtimeId-cmatch'^2\.5\.22-[0-9a-f]{16}-[0-9a-f]{32}$' -and
        $Proof.version-is[string] -and [string]$Proof.version-ceq$script:CcodProductVersion -and
        $Proof.packageSha256-is[string] -and [string]$Proof.packageSha256-cmatch'^[0-9a-f]{64}$' -and
        $Proof.startMenuSha256-is[string] -and [string]$Proof.startMenuSha256-cmatch'^[0-9a-f]{64}$' -and
        $Proof.desktopSha256-is[string] -and [string]$Proof.desktopSha256-cmatch'^[0-9a-f]{64}$' -and
        (Test-CcodProductExactStringSet $Proof.shortcutNames $script:CcodCurrentShortcutNames)
}

function Test-CcodCurrentVerifiedRegistrationUnchanged {
    param($Before,$After)
    return (Test-CcodCurrentVerifiedRegistration $Before) -and (Test-CcodCurrentVerifiedRegistration $After) -and
        [string]$Before.runtimeId-ceq[string]$After.runtimeId -and [string]$Before.version-ceq[string]$After.version -and
        [string]$Before.packageSha256-ceq[string]$After.packageSha256 -and
        [string]$Before.startMenuSha256-ceq[string]$After.startMenuSha256 -and [string]$Before.desktopSha256-ceq[string]$After.desktopSha256 -and
        (Test-CcodProductExactStringSet $Before.shortcutNames $After.shortcutNames)
}

function Get-CcodProductFullPath {
    param([Parameter(Mandatory)][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathRooted($Path)) {
        Throw-CcodProductRegistrationError 'CCOD_PRODUCT_REGISTRATION_INVALID' 'Product registration paths must be absolute.' $Path
    }
    try { return [IO.Path]::GetFullPath($Path).TrimEnd('\') }
    catch { Throw-CcodProductRegistrationError 'CCOD_PRODUCT_REGISTRATION_INVALID' 'Product registration path is invalid.' $Path }
}

function Test-CcodProductShortcut {
    param($Shortcut,$Expected)
    if (-not (Test-CcodProductExactProperties $Shortcut $script:CcodShortcutFields)) { return $false }
    foreach ($name in $script:CcodShortcutFields) {
        if ($Shortcut.$name -isnot [string] -or [string]$Shortcut.$name -cne [string]$Expected.$name) { return $false }
    }
    return $true
}

function New-CcodProductRegistration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$RuntimeId,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$PackageSha256,
        [Parameter(Mandatory)]$FileTransaction
    )
    $root = Get-CcodProductFullPath $InstallRoot
    if ($null -eq $FileTransaction -or $Version -cne $script:CcodProductVersion -or
        $RuntimeId -cnotmatch ('^' + [regex]::Escape($Version) + '-[0-9a-f]{16}-[0-9a-f]{32}$') -or
        $PackageSha256 -cnotmatch '^[0-9a-f]{64}$') {
        Throw-CcodProductRegistrationError 'CCOD_PRODUCT_REGISTRATION_INVALID' 'Product registration identity is invalid.' $RuntimeId
    }
    $runtimeRoot = [IO.Path]::GetFullPath((Join-Path (Join-Path $root 'runtime') $RuntimeId))
    $bootstrapPath = [IO.Path]::GetFullPath((Join-Path $runtimeRoot 'src\persistence\bootstrap.ps1'))
    $uninstallerPath = [IO.Path]::GetFullPath((Join-Path $runtimeRoot 'Uninstall-CodexControlOtherDevices.ps1'))
    $candidateRoot = [IO.Path]::GetFullPath((Join-Path $runtimeRoot 'registration'))
    $startMenu = [pscustomobject][ordered]@{
        kind = 'StartMenu'; leaf = 'CodexRemote-fix.lnk'; relativePath = 'CodexRemote-fix\CodexRemote-fix.lnk'
        candidatePath = [IO.Path]::GetFullPath((Join-Path $candidateRoot 'StartMenu.CodexRemote-fix.lnk'))
        bootstrapPath = $bootstrapPath; installRoot = $root
    }
    $desktop = [pscustomobject][ordered]@{
        kind = 'Desktop'; leaf = 'CodexRemote-fix.lnk'; relativePath = 'CodexRemote-fix.lnk'
        candidatePath = [IO.Path]::GetFullPath((Join-Path $candidateRoot 'Desktop.CodexRemote-fix.lnk'))
        bootstrapPath = $bootstrapPath; installRoot = $root
    }
    return [pscustomobject][ordered]@{
        schemaVersion = 1; installRoot = $root; runtimeId = $RuntimeId; version = $Version; packageSha256 = $PackageSha256
        runtimeRoot = $runtimeRoot; bootstrapPath = $bootstrapPath; uninstallerPath = $uninstallerPath
        productKeyName = $script:CcodProductKeyName; startMenuShortcut = $startMenu; desktopShortcut = $desktop
    }
}

function Test-CcodProductRegistration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Registration,
        [Parameter(Mandatory)][string]$ExpectedRuntimeId,
        [Parameter(Mandatory)][string]$ExpectedVersion,
        [Parameter(Mandatory)][string]$ExpectedPackageSha256
    )
    if (-not (Test-CcodProductExactProperties $Registration $script:CcodProductFields) -or
        $Registration.schemaVersion -isnot [int] -or $Registration.schemaVersion -ne 1 -or
        $Registration.installRoot -isnot [string] -or -not [IO.Path]::IsPathRooted([string]$Registration.installRoot) -or
        $Registration.runtimeId -isnot [string] -or [string]$Registration.runtimeId -cne $ExpectedRuntimeId -or
        $Registration.version -isnot [string] -or [string]$Registration.version -cne $ExpectedVersion -or
        $Registration.packageSha256 -isnot [string] -or [string]$Registration.packageSha256 -cne $ExpectedPackageSha256 -or
        $Registration.productKeyName -isnot [string] -or [string]$Registration.productKeyName -cne $script:CcodProductKeyName) { return $false }
    try {
        $expected = New-CcodProductRegistration -InstallRoot ([string]$Registration.installRoot) -RuntimeId $ExpectedRuntimeId -Version $ExpectedVersion -PackageSha256 $ExpectedPackageSha256 -FileTransaction ([pscustomobject]@{})
    } catch { return $false }
    foreach ($name in @('runtimeRoot','bootstrapPath','uninstallerPath','productKeyName')) {
        if ($Registration.$name -isnot [string] -or [string]$Registration.$name -cne [string]$expected.$name) { return $false }
    }
    return (Test-CcodProductShortcut $Registration.startMenuShortcut $expected.startMenuShortcut) -and
        (Test-CcodProductShortcut $Registration.desktopShortcut $expected.desktopShortcut)
}

function Test-CcodProductReadyProof {
    param($Proof,$Registration)
    if (-not (Test-CcodProductExactProperties $Proof $script:CcodReadyFields)) { return $false }
    $canonicalTarget=[IO.Path]::GetFullPath((Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::System)) 'schtasks.exe'))
    return $Proof.phase -is [string] -and [string]$Proof.phase -ceq 'Ready' -and
        $Proof.runtimeId -is [string] -and [string]$Proof.runtimeId -ceq [string]$Registration.runtimeId -and
        $Proof.version -is [string] -and [string]$Proof.version -ceq [string]$Registration.version -and
        $Proof.packageSha256 -is [string] -and [string]$Proof.packageSha256 -ceq [string]$Registration.packageSha256 -and
        [uint64]$Proof.runtimeGeneration -gt 0 -and $Proof.manifestSha256 -cmatch '^[0-9a-f]{64}$' -and $Proof.startMenuSha256 -cmatch '^[0-9a-f]{64}$' -and $Proof.desktopSha256 -cmatch '^[0-9a-f]{64}$' -and $Proof.targetPath -is [string] -and [IO.Path]::GetFullPath([string]$Proof.targetPath) -ceq $canonicalTarget -and $Proof.arguments -ceq '/Run /TN "Codex Control Other Devices Supervisor"' -and $null-ne$Proof.transactionRecord -and $Proof.transactionRecord.phase-ceq'Ready' -and $Proof.transactionRecord.newRuntimeId-ceq$Proof.runtimeId -and
        $Proof.bootstrapPath -is [string] -and [string]$Proof.bootstrapPath -ceq [string]$Registration.bootstrapPath -and
        $Proof.uninstallerPath -is [string] -and [string]$Proof.uninstallerPath -ceq [string]$Registration.uninstallerPath
}

function Get-CcodProductRegistrationAdapters {
    param([hashtable]$Adapters)
    $defaults = @{
        GetReadyProof = { param($Registration) Throw-CcodProductRegistrationError 'CCOD_PRODUCT_REGISTRATION_NOT_READY' 'No independently verified Ready proof was supplied.' $Registration.runtimeId }
        WriteProductRegistration = { param($Registration,$ReadyEvidence) Write-CcodCurrentUserProductRegistration $Registration $ReadyEvidence }
        ReadProductRegistration = { param($Registration) Read-CcodCurrentUserProductRegistration $Registration }
        WriteShortcut = { param($Kind,$Shortcut,$FileTransaction,$ReadyEvidence) Write-CcodCurrentUserProductShortcut -Kind $Kind -Shortcut $Shortcut -FileTransaction $FileTransaction -ReadyEvidence $ReadyEvidence }
        ReadShortcut = { param($Kind,$Shortcut) Read-CcodCurrentUserProductShortcut -Kind $Kind -Shortcut $Shortcut }
        ReadLegacyRegistration = { param($ExpectedAppId) Read-CcodCurrentUserLegacyRegistration -ExpectedAppId $ExpectedAppId }
        ReadVerifiedRegistration = { Read-CcodCurrentUserVerifiedRegistration }
        RemoveLegacyRegistration = { param($ExpectedAppId,$ExpectedShortcutNames) Remove-CcodCurrentUserLegacyRegistration -ExpectedAppId $ExpectedAppId -ExpectedShortcutNames $ExpectedShortcutNames }
        ReadCurrentProductState = { param($ExpectedRuntimeId) Read-CcodCurrentProductState -ExpectedRuntimeId $ExpectedRuntimeId }
        RemoveCurrentProductEntry = { param($Entry) Remove-CcodCurrentProductEntry -Entry $Entry }
        ReadLegacySnapshot = { param($ExpectedAppId,$ExpectedProfile) Read-CcodLegacySnapshot -ExpectedAppId $ExpectedAppId -ExpectedProfile $ExpectedProfile }
        RemoveLegacyEntry = { param($Entry) Remove-CcodLegacySnapshotEntry -Entry $Entry }
        ReadLegacyEntry = { param($Entry) Read-CcodLegacySnapshotEntry -Entry $Entry }
        RestoreLegacyEntry = { param($Entry) Restore-CcodLegacySnapshotEntry -Entry $Entry }
        WriteLegacyCompensationFailure = {param($Record)Write-CcodLegacyCompensationFailure -Record $Record}
    }
    if ($null -eq $Adapters) { return $defaults }
    if ($Adapters -isnot [hashtable]) { Throw-CcodProductRegistrationError 'CCOD_PRODUCT_ADAPTER_INVALID' 'Product adapters must be a hashtable.' $Adapters }
    $resolved = @{}; foreach ($name in $defaults.Keys) { $resolved[$name] = $defaults[$name] }
    foreach ($name in $Adapters.Keys) {
        if ($name -isnot [string] -or -not $resolved.ContainsKey($name) -or $Adapters[$name] -isnot [scriptblock]) {
            Throw-CcodProductRegistrationError 'CCOD_PRODUCT_ADAPTER_INVALID' 'Product adapter contract is invalid.' $name
        }
        $resolved[$name] = $Adapters[$name]
    }
    return $resolved
}

function Get-CcodProductRegistryPath { 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\CodexRemote-fix' }
function Get-CcodLegacyRegistryPath([string]$AppId) { 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\' + $AppId + '_is1' }
function Get-CcodProductPowerShellPath {
    $system=[Environment]::GetFolderPath([Environment+SpecialFolder]::System);if([string]::IsNullOrWhiteSpace($system)){throw 'system folder missing'}
    [IO.Path]::GetFullPath((Join-Path $system 'WindowsPowerShell\v1.0\powershell.exe'))
}

function Get-CcodLegacyShortcutContract {
    param(
        [Parameter(Mandatory)]$LegacyRegistration,
        [Parameter(Mandatory)]$Profile,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$ExpectedInstallRoot
    )
    $installRoot=Get-CcodProductFullPath $ExpectedInstallRoot
    $installerRoot=Get-CcodProductFullPath ([string]$LegacyRegistration.installLocation)
    $powershell=Get-CcodProductPowerShellPath
    $bootstrap=Join-Path $installRoot 'bootstrap.ps1'
    $version=[version]::Parse([string]$LegacyRegistration.displayVersion)
    $explicit=if($version-ge[version]'2.5.0'){' -EntryMode Explicit'}else{''}
    $mainArguments='-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -InstallRoot "{1}"{2}'-f$bootstrap,$installRoot,$explicit
    $oldDesktop='Desktop\Codex '+[char]0x8BBE+[char]0x5907+[char]0x8FDE+[char]0x63A5+' (Device Connection).lnk'
    if($Name-ceq$oldDesktop){return [pscustomobject][ordered]@{targetPath=$powershell;arguments=$mainArguments;workingDirectory=$installRoot}}
    switch -CaseSensitive ($Name) {
        'Programs\Codex Control other devices\Codex Control other devices for Windows.lnk' {
            return [pscustomobject][ordered]@{targetPath=(Join-Path $installerRoot 'README.md');arguments='';workingDirectory=''}
        }
        'Programs\Codex Control other devices\Open the tray supervisor.lnk' {
            return [pscustomobject][ordered]@{targetPath=$powershell;arguments=('-NoProfile -ExecutionPolicy Bypass -File "{0}"'-f(Join-Path $installerRoot 'Start-CodexControlOtherDevices.ps1'));workingDirectory=$installerRoot}
        }
        'Programs\Codex Control other devices\Compatibility check.lnk' {
            return [pscustomobject][ordered]@{targetPath=$powershell;arguments=('-NoProfile -ExecutionPolicy Bypass -File "{0}"'-f(Join-Path $installerRoot 'Test-CodexControlOtherDevices.ps1'));workingDirectory=$installerRoot}
        }
        'Programs\Codex Control other devices\Uninstall Codex Control other devices.lnk' {
            return [pscustomobject][ordered]@{targetPath=(Join-Path $installerRoot 'unins000.exe');arguments='';workingDirectory=''}
        }
        'Programs\CodexRemote-fix\CodexRemote-fix.lnk' {
            return [pscustomobject][ordered]@{targetPath=$powershell;arguments=$mainArguments;workingDirectory=$installRoot}
        }
        'Programs\CodexRemote-fix\CodexRemote-fix compatibility check.lnk' {
            return [pscustomobject][ordered]@{targetPath=$powershell;arguments=('-NoProfile -ExecutionPolicy Bypass -File "{0}"'-f(Join-Path $installerRoot 'Test-CodexControlOtherDevices.ps1'));workingDirectory=$installerRoot}
        }
        'Programs\CodexRemote-fix\Uninstall CodexRemote-fix.lnk' {
            return [pscustomobject][ordered]@{targetPath=(Join-Path $installerRoot 'unins000.exe');arguments='';workingDirectory=''}
        }
        'Desktop\CodexRemote-fix.lnk' {
            return [pscustomobject][ordered]@{targetPath=$powershell;arguments=$mainArguments;workingDirectory=$installRoot}
        }
        default { Throw-CcodProductRegistrationError 'CCOD_LEGACY_PRODUCT_REGISTRATION_INVALID' 'Legacy shortcut has no checked-in historical contract.' $Name }
    }
}
function Get-CcodProductUninstallCommand($Registration) {
    '"{0}" -NoProfile -ExecutionPolicy Bypass -File "{1}"' -f (Get-CcodProductPowerShellPath),([string]$Registration.uninstallerPath).Replace('"','')
}
function Write-CcodCurrentUserProductRegistration {
    param($Registration,$ReadyEvidence)
    $path=Get-CcodProductRegistryPath;$command=Get-CcodProductUninstallCommand $Registration
    $shell=$null;$startLink=$null;$desktopLink=$null;try{$shell=New-Object -ComObject WScript.Shell;$startLink=$shell.CreateShortcut([string]$Registration.startMenuShortcut.candidatePath);$desktopLink=$shell.CreateShortcut([string]$Registration.desktopShortcut.candidatePath);$target=[IO.Path]::GetFullPath([string]$startLink.TargetPath);$arguments=[string]$startLink.Arguments;if([IO.Path]::GetFullPath([string]$desktopLink.TargetPath)-cne$target-or[string]$desktopLink.Arguments-cne$arguments){throw 'candidate target mismatch'}}finally{if($null-ne$startLink){[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($startLink)};if($null-ne$desktopLink){[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($desktopLink)};if($null-ne$shell){[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)}}
    New-Item -Path $path -Force -ErrorAction Stop|Out-Null
    if($ReadyEvidence.startMenuSha256-cne(Get-CcodProductFileSha256 ([string]$Registration.startMenuShortcut.candidatePath))-or$ReadyEvidence.desktopSha256-cne(Get-CcodProductFileSha256 ([string]$Registration.desktopShortcut.candidatePath))-or[IO.Path]::GetFullPath([string]$ReadyEvidence.targetPath)-cne$target-or[string]$ReadyEvidence.arguments-cne$arguments){throw 'Ready shortcut evidence mismatch'}
    $values=[ordered]@{DisplayName='CodexRemote-fix';DisplayVersion=[string]$Registration.version;Publisher='naipi11';InstallLocation=[string]$Registration.runtimeRoot;UninstallString=$command;QuietUninstallString=($command+' -Confirm:$false');NoModify=1;NoRepair=1;CcodRuntimeId=[string]$Registration.runtimeId;CcodRuntimeGeneration=[int64]$ReadyEvidence.runtimeGeneration;CcodPackageSha256=[string]$Registration.packageSha256;CcodManifestSha256=[string]$ReadyEvidence.manifestSha256;CcodStartMenuSha256=[string]$ReadyEvidence.startMenuSha256;CcodDesktopSha256=[string]$ReadyEvidence.desktopSha256;CcodShortcutTarget=$target;CcodShortcutArguments=$arguments}
    foreach($name in $values.Keys){$type=if($name-in@('NoModify','NoRepair')){'DWord'}elseif($name-ceq'CcodRuntimeGeneration'){'QWord'}else{'String'};New-ItemProperty -LiteralPath $path -Name $name -Value $values[$name] -PropertyType $type -Force -ErrorAction Stop|Out-Null}
}
function Read-CcodCurrentUserProductRegistration {
    param($Registration)
    $state=Read-CcodCurrentProductState -ExpectedRuntimeId ([string]$Registration.runtimeId);if($null-ne$state-and$state.valid){$Registration}else{$null}
}
function Get-CcodProductShortcutDestination {
    param([string]$Kind)
    $base=if($Kind-ceq'StartMenu'){[Environment]::GetFolderPath([Environment+SpecialFolder]::Programs)}else{[Environment]::GetFolderPath([Environment+SpecialFolder]::Desktop)}
    if([string]::IsNullOrWhiteSpace($base)-or-not[IO.Path]::IsPathRooted($base)){throw 'special folder missing'}
    if($Kind-ceq'StartMenu'){[IO.Path]::GetFullPath((Join-Path (Join-Path $base 'CodexRemote-fix') 'CodexRemote-fix.lnk'))}else{[IO.Path]::GetFullPath((Join-Path $base 'CodexRemote-fix.lnk'))}
}
function Get-CcodProductFileSha256([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()}
function New-CcodProductShortcutCandidates {
    param([Parameter(Mandatory)][string]$Directory)
    $root=Get-CcodProductFullPath $Directory;if([IO.Directory]::Exists($root)-or[IO.File]::Exists($root)){Throw-CcodProductRegistrationError 'CCOD_PRODUCT_REGISTRATION_INVALID' 'Shortcut candidate root must be create-only.' $root}
    [IO.Directory]::CreateDirectory($root)|Out-Null;$shell=$null
    try{
        $shell=New-Object -ComObject WScript.Shell;$system=[Environment]::GetFolderPath([Environment+SpecialFolder]::System);$target=[IO.Path]::GetFullPath((Join-Path $system 'schtasks.exe'))
        $records=[Collections.Generic.List[object]]::new()
        foreach($name in @('StartMenu.CodexRemote-fix.lnk','Desktop.CodexRemote-fix.lnk')){
            $path=Join-Path $root $name;$link=$shell.CreateShortcut($path);try{$link.TargetPath=$target;$link.Arguments='/Run /TN "Codex Control Other Devices Supervisor"';$link.Description='CodexRemote-fix';$link.Save()}finally{if($null-ne$link){[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($link)}}
            $item=Get-Item -LiteralPath $path -Force -ErrorAction Stop;$records.Add([pscustomobject]@{Relative=('registration/'+$name);Source=$path;ExpectedLength=[int64]$item.Length;ExpectedSha256=Get-CcodProductFileSha256 $path})
        }
        return @($records)
    }finally{if($null-ne$shell){[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)}}
}
function Write-CcodCurrentUserProductShortcut {
    param([string]$Kind,$Shortcut,$FileTransaction,$ReadyEvidence)
    Import-Module (Join-Path $PSScriptRoot 'InstallFileTransaction.psm1') -ErrorAction Stop
    $relative='registration/'+$(if($Kind-ceq'StartMenu'){'StartMenu.CodexRemote-fix.lnk'}else{'Desktop.CodexRemote-fix.lnk'})
    $source=Open-CcodInstallRetainedFile -Generation $FileTransaction -RelativePath $relative -ReadyTransaction $ReadyEvidence.transactionRecord
    $folder=Open-CcodInstallProductSpecialFolder -Generation $FileTransaction -Kind $Kind
    Copy-CcodInstallProductShortcut -Folder $folder -Source $source -Kind $Kind -Leaf 'CodexRemote-fix.lnk'|Out-Null
}
function Read-CcodCurrentUserProductShortcut {
    param([string]$Kind,$Shortcut)
    $destination=Get-CcodProductShortcutDestination $Kind;$source=[string]$Shortcut.candidatePath
    if(-not[IO.File]::Exists($destination)-or-not[IO.File]::Exists($source)){return $null}
    $item=Get-Item -LiteralPath $destination -Force -ErrorAction Stop;if($item.PSIsContainer-or($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0-or(Get-CcodProductFileSha256 $destination)-cne(Get-CcodProductFileSha256 $source)){return $null}
    $Shortcut
}
function Get-CcodLegacyShortcutPath {
    param([Parameter(Mandatory)][string]$RelativeName)
    if($RelativeName.StartsWith('Programs\',[StringComparison]::Ordinal)){$base=[Environment]::GetFolderPath([Environment+SpecialFolder]::Programs);$relative=$RelativeName.Substring(9)}
    elseif($RelativeName.StartsWith('Desktop\',[StringComparison]::Ordinal)){$base=[Environment]::GetFolderPath([Environment+SpecialFolder]::Desktop);$relative=$RelativeName.Substring(8)}
    else{Throw-CcodProductRegistrationError 'CCOD_LEGACY_PRODUCT_REGISTRATION_INVALID' 'Legacy shortcut name is outside the supported special folders.' $RelativeName}
    if([string]::IsNullOrWhiteSpace($base)-or-not[IO.Path]::IsPathRooted($base)-or[string]::IsNullOrWhiteSpace($relative)){
        Throw-CcodProductRegistrationError 'CCOD_LEGACY_PRODUCT_REGISTRATION_INVALID' 'Legacy shortcut special-folder path is invalid.' $RelativeName
    }
    return [IO.Path]::GetFullPath((Join-Path $base $relative))
}

function Read-CcodCurrentUserLegacyRegistration {
    param([string]$ExpectedAppId)
    $path=Get-CcodLegacyRegistryPath $ExpectedAppId;if(-not(Test-Path -LiteralPath $path -PathType Container)){return $null}
    $value=Get-ItemProperty -LiteralPath $path -ErrorAction Stop
    $programs=[Environment]::GetFolderPath([Environment+SpecialFolder]::Programs);$desktop=[Environment]::GetFolderPath([Environment+SpecialFolder]::Desktop)
    if([string]::IsNullOrWhiteSpace($programs)-or-not[IO.Path]::IsPathRooted($programs)-or[string]::IsNullOrWhiteSpace($desktop)-or-not[IO.Path]::IsPathRooted($desktop)){
        Throw-CcodProductRegistrationError 'CCOD_LEGACY_PRODUCT_REGISTRATION_INVALID' 'Legacy shortcut special folders are unavailable.' $ExpectedAppId
    }
    $groups=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);$desktopNames=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($profile in @(Get-CcodLegacyRegistrationProfiles)){
        foreach($name in @($profile.shortcutNames)){
            if($name.StartsWith('Programs\',[StringComparison]::Ordinal)){$tail=$name.Substring(9);$separator=$tail.IndexOf('\');if($separator-lt1){Throw-CcodProductRegistrationError 'CCOD_LEGACY_PRODUCT_REGISTRATION_INVALID' 'Historical Start-menu profile is invalid.' $name};[void]$groups.Add($tail.Substring(0,$separator))}
            elseif($name.StartsWith('Desktop\',[StringComparison]::Ordinal)){[void]$desktopNames.Add($name.Substring(8))}
            else{Throw-CcodProductRegistrationError 'CCOD_LEGACY_PRODUCT_REGISTRATION_INVALID' 'Historical shortcut profile is invalid.' $name}
        }
    }
    $present=[Collections.Generic.List[string]]::new();$unsafe=[Collections.Generic.List[string]]::new()
    foreach($group in @($groups|Sort-Object)){
        $groupPath=Join-Path $programs $group;$groupItem=Get-Item -LiteralPath $groupPath -Force -ErrorAction SilentlyContinue
        if($null-eq$groupItem){continue}
        $groupName='Programs\'+[string]$groupItem.Name
        if(-not$groupItem.PSIsContainer-or($groupItem.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){$present.Add($groupName);$unsafe.Add($groupName);continue}
        foreach($item in @(Get-ChildItem -LiteralPath $groupItem.FullName -Force -ErrorAction Stop)){
            $name=$groupName+'\'+[string]$item.Name;$present.Add($name)
            if($item.PSIsContainer-or($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){$unsafe.Add($name)}
        }
    }
    foreach($desktopName in @($desktopNames|Sort-Object)){
        $item=Get-Item -LiteralPath (Join-Path $desktop $desktopName) -Force -ErrorAction SilentlyContinue
        if($null-eq$item){continue};$name='Desktop\'+[string]$item.Name;$present.Add($name)
        if($item.PSIsContainer-or($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){$unsafe.Add($name)}
    }
    return [pscustomobject][ordered]@{
        appId=$ExpectedAppId;displayVersion=[string]$value.DisplayVersion;installLocation=[string]$value.InstallLocation
        uninstallString=[string]$value.UninstallString;shortcutNames=@($present);unsafeShortcutNames=@($unsafe)
    }
}
function Read-CcodCurrentUserVerifiedRegistration {
    try{
        $path=Get-CcodProductRegistryPath;if(-not(Test-Path -LiteralPath $path -PathType Container)){return $null}
        $value=Get-ItemProperty -LiteralPath $path -ErrorAction Stop;$runtimeId=[string]$value.CcodRuntimeId
        $state=Read-CcodCurrentProductState -ExpectedRuntimeId $runtimeId
        if($null-eq$state-or$state.valid-isnot[bool]-or-not$state.valid-or@($state.entries).Count-ne3-or$null-eq$state.readyEvidence){return $null}
        $proof=[pscustomobject][ordered]@{
            verified=$true;runtimeId=[string]$state.readyEvidence.runtimeId;version=$script:CcodProductVersion;packageSha256=[string]$state.readyEvidence.packageSha256
            shortcutNames=@($script:CcodCurrentShortcutNames);startMenuSha256=[string]$state.readyEvidence.startMenuSha256;desktopSha256=[string]$state.readyEvidence.desktopSha256
        }
        if(Test-CcodCurrentVerifiedRegistration $proof){return $proof}
        return $null
    }catch{return $null}
}
function Remove-CcodCurrentUserLegacyRegistration {
    param([string]$ExpectedAppId,[string[]]$ExpectedShortcutNames)
    $programs=[Environment]::GetFolderPath([Environment+SpecialFolder]::Programs);$desktop=[Environment]::GetFolderPath([Environment+SpecialFolder]::Desktop)
    foreach($name in $ExpectedShortcutNames){$relative=$name.Substring($name.IndexOf('\')+1);$candidate=if($name.StartsWith('Programs\',[StringComparison]::Ordinal)){Join-Path $programs $relative}else{Join-Path $desktop $relative};if(Test-Path -LiteralPath $candidate -PathType Leaf){Remove-Item -LiteralPath $candidate -Force -ErrorAction Stop}}
    $path=Get-CcodLegacyRegistryPath $ExpectedAppId;if(Test-Path -LiteralPath $path -PathType Container){Remove-Item -LiteralPath $path -Force -ErrorAction Stop}
}

function Get-CcodProductShortcutEvidence([string]$Kind){
    $path=Get-CcodProductShortcutDestination $Kind;if(-not[IO.File]::Exists($path)){return $null};$item=Get-Item -LiteralPath $path -Force -ErrorAction Stop;if($item.PSIsContainer-or($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){return $null};$shell=$null;$link=$null;try{$shell=New-Object -ComObject WScript.Shell;$link=$shell.CreateShortcut($path);[pscustomobject]@{kind=$Kind;path=$path;sha256=Get-CcodProductFileSha256 $path;target=[IO.Path]::GetFullPath([string]$link.TargetPath);arguments=[string]$link.Arguments}}finally{if($null-ne$link){[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($link)};if($null-ne$shell){[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)}}
}
function Test-CcodCurrentProductRegistryPreflight {
    param([string[]]$ValueNames,[string[]]$SubKeyNames,[string[]]$AllowedValueNames)
    if($null-eq$ValueNames-or$null-eq$SubKeyNames-or$null-eq$AllowedValueNames-or@($SubKeyNames).Count-ne0){return $false}
    return ((@($ValueNames|Sort-Object)-join"`0")-ceq(@($AllowedValueNames|Sort-Object)-join"`0"))
}
function Read-CcodCurrentProductState {
    param([string]$ExpectedRuntimeId)
    try{
        $subkey='Software\Microsoft\Windows\CurrentVersion\Uninstall\CodexRemote-fix';$key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subkey,$false);if($null-eq$key){return [pscustomobject]@{valid=$true;reason=$null;entries=@()}}
        try{$allowed=@('CcodDesktopSha256','CcodPackageSha256','CcodRuntimeId','CcodRuntimeGeneration','CcodManifestSha256','CcodShortcutArguments','CcodShortcutTarget','CcodStartMenuSha256','DisplayName','DisplayVersion','InstallLocation','NoModify','NoRepair','Publisher','QuietUninstallString','UninstallString');$names=@($key.GetValueNames()|Sort-Object);if(-not(Test-CcodCurrentProductRegistryPreflight -ValueNames $names -SubKeyNames @($key.GetSubKeyNames()) -AllowedValueNames $allowed)){return [pscustomobject]@{valid=$false;reason='UnknownRegistryValue';entries=@()}};$runtime=[string]$key.GetValue('CcodRuntimeId',$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames);$installLocation=[string]$key.GetValue('InstallLocation');$expectedUninstaller=Join-Path $installLocation 'Uninstall-CodexControlOtherDevices.ps1';$expectedCommand='"{0}" -NoProfile -ExecutionPolicy Bypass -File "{1}"'-f(Get-CcodProductPowerShellPath),$expectedUninstaller;if($runtime-cne$ExpectedRuntimeId-or$installLocation-cne[IO.Path]::GetFullPath((Join-Path (Join-Path (Split-Path (Split-Path $installLocation -Parent) -Parent) 'runtime') $runtime))-or[string]$key.GetValue('DisplayName')-cne'CodexRemote-fix'-or[string]$key.GetValue('DisplayVersion')-cne'2.5.22'-or[string]$key.GetValue('Publisher')-cne'naipi11'-or[string]$key.GetValue('UninstallString')-cne$expectedCommand-or[string]$key.GetValue('QuietUninstallString')-cne($expectedCommand+' -Confirm:$false')-or[int]$key.GetValue('NoModify')-ne1-or[int]$key.GetValue('NoRepair')-ne1-or[string]$key.GetValue('CcodPackageSha256')-cnotmatch'^[0-9a-f]{64}$'){return [pscustomobject]@{valid=$false;reason='RegistryMismatch';entries=@()}};foreach($dword in @('NoModify','NoRepair')){if($key.GetValueKind($dword)-ne[Microsoft.Win32.RegistryValueKind]::DWord){return [pscustomobject]@{valid=$false;reason='RegistryType';entries=@()}}};if($key.GetValueKind('CcodRuntimeGeneration')-ne[Microsoft.Win32.RegistryValueKind]::QWord){return [pscustomobject]@{valid=$false;reason='RegistryType';entries=@()}};foreach($stringName in @($allowed|Where-Object{$_-notin@('NoModify','NoRepair','CcodRuntimeGeneration')})){if($key.GetValueKind($stringName)-ne[Microsoft.Win32.RegistryValueKind]::String){return [pscustomobject]@{valid=$false;reason='RegistryType';entries=@()}}};$target=[string]$key.GetValue('CcodShortcutTarget');$arguments=[string]$key.GetValue('CcodShortcutArguments');$start=Get-CcodProductShortcutEvidence 'StartMenu';$desktop=Get-CcodProductShortcutEvidence 'Desktop';if($null-eq$start-or$null-eq$desktop-or$start.target-cne$target-or$desktop.target-cne$target-or$start.arguments-cne$arguments-or$desktop.arguments-cne$arguments-or$start.sha256-cne[string]$key.GetValue('CcodStartMenuSha256')-or$desktop.sha256-cne[string]$key.GetValue('CcodDesktopSha256')){return [pscustomobject]@{valid=$false;reason='ShortcutMismatch';entries=@()}};$captured=[ordered]@{};foreach($name in $names){$captured[$name]=[pscustomobject]@{value=$key.GetValue($name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames);kind=[string]$key.GetValueKind($name)}};$installRoot=[IO.Path]::GetFullPath((Split-Path (Split-Path $installLocation -Parent) -Parent));$readyEvidence=[pscustomobject][ordered]@{phase='Ready';installRoot=$installRoot;runtimeId=$runtime;runtimeGeneration=[uint64]$key.GetValue('CcodRuntimeGeneration');packageSha256=[string]$key.GetValue('CcodPackageSha256');manifestSha256=[string]$key.GetValue('CcodManifestSha256');startMenuSha256=$start.sha256;desktopSha256=$desktop.sha256;targetPath=$target;arguments=$arguments};return [pscustomobject]@{valid=$true;reason=$null;readyEvidence=$readyEvidence;entries=@([pscustomobject]@{kind='StartMenu';path=$start.path;sha256=$start.sha256},[pscustomobject]@{kind='Desktop';path=$desktop.path;sha256=$desktop.sha256},[pscustomobject]@{kind='Registry';path=$subkey;valueNames=$names;values=$captured})}}
        finally{$key.Dispose()}
    }catch{return [pscustomobject]@{valid=$false;reason='Ambiguous';entries=@()}}
}
function Remove-CcodCurrentProductEntry {
    param($Entry)
    if($Entry-is[string]){return}
    if($Entry.kind-in@('StartMenu','Desktop')){$path=[IO.Path]::GetFullPath([string]$Entry.path);if(-not[IO.File]::Exists($path)-or(Get-CcodProductFileSha256 $path)-cne[string]$Entry.sha256){throw 'shortcut changed'};Remove-Item -LiteralPath $path -Force -ErrorAction Stop;return}
    if($Entry.kind-cne'Registry'){throw 'unknown product entry'};$key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey([string]$Entry.path,$true);if($null-eq$key){return};try{if((@($key.GetValueNames()|Sort-Object)-join'|')-cne((@($Entry.valueNames)|Sort-Object)-join'|')-or$key.GetSubKeyNames().Count-ne0){throw 'registry changed'};foreach($name in @($Entry.valueNames)){if([string]$key.GetValue($name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)-cne[string]$Entry.values[$name].value-or[string]$key.GetValueKind($name)-cne[string]$Entry.values[$name].kind){throw 'registry value changed'}};foreach($name in @($Entry.valueNames)){$key.DeleteValue($name,$true)};if($key.GetValueNames().Count-ne0){throw 'registry not empty'}}finally{$key.Dispose()};[Microsoft.Win32.Registry]::CurrentUser.DeleteSubKey([string]$Entry.path,$false)
}
function Remove-CcodProductRegistration {
    [CmdletBinding()]param([Parameter(Mandatory)]$ReadyEvidence,[hashtable]$Adapters)
    $fields=@('phase','installRoot','runtimeId','runtimeGeneration','packageSha256','manifestSha256','startMenuSha256','desktopSha256','targetPath','arguments');$canonicalTarget=[IO.Path]::GetFullPath((Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::System)) 'schtasks.exe'));if(-not(Test-CcodProductExactProperties $ReadyEvidence $fields)-or$ReadyEvidence.phase-cne'Ready'-or$ReadyEvidence.installRoot-isnot[string]-or-not[IO.Path]::IsPathRooted($ReadyEvidence.installRoot)-or$ReadyEvidence.runtimeId-cnotmatch'^2\.5\.22-[0-9a-f]{16}-[0-9a-f]{32}$'-or[uint64]$ReadyEvidence.runtimeGeneration-lt1-or$ReadyEvidence.packageSha256-cnotmatch'^[0-9a-f]{64}$'-or$ReadyEvidence.manifestSha256-cnotmatch'^[0-9a-f]{64}$'-or$ReadyEvidence.startMenuSha256-cnotmatch'^[0-9a-f]{64}$'-or$ReadyEvidence.desktopSha256-cnotmatch'^[0-9a-f]{64}$'-or$ReadyEvidence.targetPath-isnot[string]-or[IO.Path]::GetFullPath([string]$ReadyEvidence.targetPath)-cne$canonicalTarget-or$ReadyEvidence.arguments-cne'/Run /TN "Codex Control Other Devices Supervisor"'){Throw-CcodProductRegistrationError 'CCOD_PRODUCT_CLEANUP_INVALID' 'Exact Ready cleanup evidence is invalid' $ReadyEvidence};$adapter=Get-CcodProductRegistrationAdapters $Adapters;$state=&$adapter.ReadCurrentProductState $ReadyEvidence.runtimeId;if($null-eq$state-or$state.valid-isnot[bool]-or-not$state.valid-or$null-eq$state.readyEvidence-or($state.readyEvidence|ConvertTo-Json -Compress)-cne($ReadyEvidence|ConvertTo-Json -Compress)-or$null-eq$state.entries){Throw-CcodProductRegistrationError 'CCOD_PRODUCT_CLEANUP_INVALID' 'Current product state is not bound to exact Ready evidence' $ReadyEvidence.runtimeId};$entries=@($state.entries);if($entries.Count-notin@(0,3)){Throw-CcodProductRegistrationError 'CCOD_PRODUCT_CLEANUP_INVALID' 'Current product state is ambiguous' $ReadyEvidence.runtimeId};foreach($entry in $entries){&$adapter.RemoveCurrentProductEntry $entry}
}

function Assert-CcodInstalledResumeTransaction {
    param([Parameter(Mandatory)]$Transaction)
    $binding=$Transaction.installedBinding
    if($Transaction.transactionId-isnot[string]-or$Transaction.transactionId-cnotmatch'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'-or
       $Transaction.runtimeId-isnot[string]-or$Transaction.runtimeId-cnotmatch'^2\.5\.22-[0-9a-f]{16}-[0-9a-f]{32}$'-or$Transaction.userSid-isnot[string]-or$Transaction.userSid-cnotmatch'^S-1-'-or
       $Transaction.sessionId-isnot[int]-or$Transaction.sessionId-lt0-or$null-eq$Transaction.readyEvidence-or$null-eq$binding-or
       $binding.selectedRuntimeRoot-isnot[string]-or-not[IO.Path]::IsPathRooted([string]$binding.selectedRuntimeRoot)-or$binding.runtimeManifestSha256-isnot[string]-or$binding.runtimeManifestSha256-cnotmatch'^[0-9a-f]{64}$'-or
       $binding.wrapperUserSid-isnot[string]-or$binding.wrapperUserSid-cne$Transaction.userSid-or$binding.wrapperSessionId-isnot[int]-or$binding.wrapperSessionId-ne$Transaction.sessionId-or
       $binding.resumeScriptPath-isnot[string]-or-not[IO.Path]::IsPathRooted([string]$binding.resumeScriptPath)-or$binding.resumeScriptSha256-isnot[string]-or$binding.resumeScriptSha256-cnotmatch'^[0-9a-f]{64}$'-or
       $binding.resumeCommand-isnot[string]-or[string]::IsNullOrWhiteSpace([string]$binding.resumeCommand)){
        Throw-CcodProductRegistrationError 'CCOD_PRODUCT_CLEANUP_INVALID' 'Installed uninstall resume transaction is invalid.' $Transaction
    }
    try{
        [uint64]$generation=$Transaction.runtimeGeneration;[uint64]$epoch=$Transaction.leaseEpoch;[int64]$scriptLength=$binding.resumeScriptLength
        $install=Get-CcodProductFullPath ([string]$Transaction.readyEvidence.installRoot);$selected=Get-CcodProductFullPath ([string]$binding.selectedRuntimeRoot);$resumeScript=Get-CcodProductFullPath ([string]$binding.resumeScriptPath)
        $expectedSelected=[IO.Path]::GetFullPath((Join-Path (Join-Path $install 'runtime') ([string]$Transaction.runtimeId)))
        $local=[Environment]::GetEnvironmentVariable('LOCALAPPDATA','Process');if([string]::IsNullOrWhiteSpace($local)){$local=[Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)}
        $expectedScript=[IO.Path]::GetFullPath((Join-Path (Join-Path (Join-Path $local 'CodexRemote-fix-uninstall') ([string]$Transaction.transactionId)) 'payload\src\persistence\InstalledUninstallFinalizer.ps1'))
        $system=[Environment]::GetFolderPath([Environment+SpecialFolder]::System);$powershell=[IO.Path]::GetFullPath((Join-Path $system 'WindowsPowerShell\v1.0\powershell.exe'))
        $expectedCommand='"{0}" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{1}" -Resume -TransactionId "{2}" -RuntimeRoot "{3}" -InstallRoot "{4}"'-f$powershell,$expectedScript,$Transaction.transactionId,$expectedSelected,$install
    }catch{Throw-CcodProductRegistrationError 'CCOD_PRODUCT_CLEANUP_INVALID' 'Installed uninstall resume paths are invalid.' $Transaction}
    if($generation-eq0-or$scriptLength-lt0-or$selected-cne$expectedSelected-or$resumeScript-cne$expectedScript-or$binding.resumeCommand-cne$expectedCommand-or
       $Transaction.readyEvidence.runtimeId-cne$Transaction.runtimeId-or[uint64]$Transaction.readyEvidence.runtimeGeneration-ne$generation-or
       $Transaction.readyEvidence.manifestSha256-cne$binding.runtimeManifestSha256){Throw-CcodProductRegistrationError 'CCOD_PRODUCT_CLEANUP_INVALID' 'Installed uninstall resume binding does not match the selected generation.' $Transaction}
    return [pscustomobject][ordered]@{installRoot=$install;selectedRuntimeRoot=$selected;resumeScriptPath=$resumeScript;resumeCommand=$expectedCommand;runtimeGeneration=$generation;leaseEpoch=$epoch;resumeScriptLength=$scriptLength}
}

function Get-CcodInstalledResumeRegistryValues {
    param([Parameter(Mandatory)]$Transaction)
    $proof=Assert-CcodInstalledResumeTransaction $Transaction;$ready=$Transaction.readyEvidence
    [ordered]@{
        DisplayName='CodexRemote-fix';DisplayVersion='2.5.22';Publisher='naipi11';InstallLocation=$proof.selectedRuntimeRoot;UninstallString=$proof.resumeCommand;QuietUninstallString=$proof.resumeCommand;NoModify=1;NoRepair=1
        CcodRuntimeId=[string]$Transaction.runtimeId;CcodRuntimeGeneration=[int64]$proof.runtimeGeneration;CcodPackageSha256=[string]$ready.packageSha256;CcodManifestSha256=[string]$ready.manifestSha256
        CcodStartMenuSha256=[string]$ready.startMenuSha256;CcodDesktopSha256=[string]$ready.desktopSha256;CcodShortcutTarget=[string]$ready.targetPath;CcodShortcutArguments=[string]$ready.arguments
        CcodUninstallTransactionId=[string]$Transaction.transactionId;CcodUninstallUserSid=[string]$Transaction.userSid;CcodUninstallSessionId=[int]$Transaction.sessionId;CcodUninstallLeaseEpoch=[int64]$proof.leaseEpoch
        CcodUninstallSelectedRuntimeRoot=$proof.selectedRuntimeRoot;CcodUninstallRuntimeManifestSha256=[string]$Transaction.installedBinding.runtimeManifestSha256
        CcodUninstallResumeScriptSha256=[string]$Transaction.installedBinding.resumeScriptSha256;CcodUninstallResumeScriptLength=[int64]$proof.resumeScriptLength
    }
}

function Get-CcodInstalledResumeRegistryKinds {
    param([Parameter(Mandatory)][Collections.IDictionary]$Values)
    $kinds=[ordered]@{};foreach($name in $Values.Keys){$kinds[$name]=if($name-in@('NoModify','NoRepair','CcodUninstallSessionId')){'DWord'}elseif($name-in@('CcodRuntimeGeneration','CcodUninstallLeaseEpoch','CcodUninstallResumeScriptLength')){'QWord'}else{'String'}};$kinds
}

function Test-CcodProductRegistryEntryValues {
    param([Parameter(Mandatory)]$Key,[Parameter(Mandatory)][Collections.IDictionary]$Values,[Parameter(Mandatory)][Collections.IDictionary]$Kinds)
    if($Key.GetSubKeyNames().Count-ne0-or-not(Test-CcodProductExactStringSet @($Key.GetValueNames()) @($Values.Keys))){return $false}
    foreach($name in $Values.Keys){$actual=$Key.GetValue([string]$name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames);if([string]$Key.GetValueKind([string]$name)-cne[string]$Kinds[$name]-or($actual|ConvertTo-Json -Compress)-cne($Values[$name]|ConvertTo-Json -Compress)){return $false}}
    return $true
}

function Read-CcodInstalledResumeProductState {
    param([Parameter(Mandatory)]$Transaction)
    $proof=Assert-CcodInstalledResumeTransaction $Transaction;$values=Get-CcodInstalledResumeRegistryValues $Transaction;$kinds=Get-CcodInstalledResumeRegistryKinds $values
    $startPath=Get-CcodProductShortcutDestination 'StartMenu';$desktopPath=Get-CcodProductShortcutDestination 'Desktop';$shortcuts=[Collections.Generic.List[object]]::new()
    foreach($definition in @([pscustomobject]@{kind='StartMenu';path=$startPath;sha=[string]$Transaction.readyEvidence.startMenuSha256},[pscustomobject]@{kind='Desktop';path=$desktopPath;sha=[string]$Transaction.readyEvidence.desktopSha256})){
        if([IO.Directory]::Exists($definition.path)){return [pscustomobject]@{valid=$false;reason='ShortcutType';registryPresent=$false;shortcutEntries=@();registryEntry=$null}}
        if([IO.File]::Exists($definition.path)){$evidence=Get-CcodProductShortcutEvidence $definition.kind;if($null-eq$evidence-or$evidence.sha256-cne$definition.sha-or$evidence.target-cne[string]$Transaction.readyEvidence.targetPath-or$evidence.arguments-cne[string]$Transaction.readyEvidence.arguments){return [pscustomobject]@{valid=$false;reason='ShortcutMismatch';registryPresent=$false;shortcutEntries=@();registryEntry=$null}};$shortcuts.Add([pscustomobject]@{kind=$definition.kind;path=$evidence.path;sha256=$evidence.sha256})}
    }
    $subkey='Software\Microsoft\Windows\CurrentVersion\Uninstall\CodexRemote-fix';$key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subkey,$false)
    if($null-eq$key){return [pscustomobject]@{valid=($shortcuts.Count-eq0);reason=$(if($shortcuts.Count-eq0){$null}else{'RegistryMissing'});registryPresent=$false;shortcutEntries=@($shortcuts);registryEntry=$null}}
    try{if(-not(Test-CcodProductRegistryEntryValues -Key $key -Values $values -Kinds $kinds)){return [pscustomobject]@{valid=$false;reason='RegistryMismatch';registryPresent=$true;shortcutEntries=@();registryEntry=$null}};$captured=[ordered]@{};foreach($name in $values.Keys){$captured[$name]=[pscustomobject]@{value=$key.GetValue([string]$name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames);kind=[string]$key.GetValueKind([string]$name)}};return [pscustomobject]@{valid=$true;reason=$null;registryPresent=$true;shortcutEntries=@($shortcuts);registryEntry=[pscustomobject]@{kind='Registry';path=$subkey;valueNames=@($values.Keys);values=$captured}}}finally{$key.Dispose()}
}

function Get-CcodInstalledResumeOriginalRegistryValues {
    param([Parameter(Mandatory)]$Transaction)
    $proof=Assert-CcodInstalledResumeTransaction $Transaction;$ready=$Transaction.readyEvidence;$uninstaller=Join-Path $proof.selectedRuntimeRoot 'Uninstall-CodexControlOtherDevices.ps1';$command='"{0}" -NoProfile -ExecutionPolicy Bypass -File "{1}"'-f(Get-CcodProductPowerShellPath),$uninstaller
    [ordered]@{DisplayName='CodexRemote-fix';DisplayVersion='2.5.22';Publisher='naipi11';InstallLocation=$proof.selectedRuntimeRoot;UninstallString=$command;QuietUninstallString=($command+' -Confirm:$false');NoModify=1;NoRepair=1;CcodRuntimeId=[string]$Transaction.runtimeId;CcodRuntimeGeneration=[int64]$proof.runtimeGeneration;CcodPackageSha256=[string]$ready.packageSha256;CcodManifestSha256=[string]$ready.manifestSha256;CcodStartMenuSha256=[string]$ready.startMenuSha256;CcodDesktopSha256=[string]$ready.desktopSha256;CcodShortcutTarget=[string]$ready.targetPath;CcodShortcutArguments=[string]$ready.arguments}
}

function Test-CcodInstalledResumeRegistryTransition {
    param([Parameter(Mandatory)]$Key,[Parameter(Mandatory)][Collections.IDictionary]$Original,[Parameter(Mandatory)][Collections.IDictionary]$Expected,[Parameter(Mandatory)][Collections.IDictionary]$ExpectedKinds)
    $names=@($Key.GetValueNames());if($Key.GetSubKeyNames().Count-ne0-or@($Original.Keys|Where-Object{$names-cnotcontains$_}).Count-ne0-or@($names|Where-Object{$Expected.Keys-cnotcontains$_}).Count-ne0){return $false}
    foreach($name in $names){$actual=$Key.GetValue([string]$name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames);$kind=[string]$Key.GetValueKind([string]$name);if($kind-cne[string]$ExpectedKinds[$name]){return $false};if($name-in@('UninstallString','QuietUninstallString')){if(($actual|ConvertTo-Json -Compress)-cne($Original[$name]|ConvertTo-Json -Compress)-and($actual|ConvertTo-Json -Compress)-cne($Expected[$name]|ConvertTo-Json -Compress)){return $false}}elseif(($actual|ConvertTo-Json -Compress)-cne($Expected[$name]|ConvertTo-Json -Compress)){return $false}}
    return $true
}

function Set-CcodInstalledUninstallResumeRegistration {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Transaction)
    if($Transaction.phase-cne'TaskRemoved'-or$Transaction.resumePhase-cne'TaskRemoved'){Throw-CcodProductRegistrationError 'CCOD_PRODUCT_CLEANUP_INVALID' 'Resume registration may be installed only at TaskRemoved.' $Transaction.transactionId}
    $proof=Assert-CcodInstalledResumeTransaction $Transaction
    try{$scriptItem=Get-Item -LiteralPath $proof.resumeScriptPath -Force -ErrorAction Stop;if($scriptItem.PSIsContainer-or($scriptItem.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0-or[int64]$scriptItem.Length-ne[int64]$proof.resumeScriptLength-or(Get-CcodProductFileSha256 $proof.resumeScriptPath)-cne[string]$Transaction.installedBinding.resumeScriptSha256){throw 'staged resume script mismatch'}}catch{Throw-CcodProductRegistrationError 'CCOD_PRODUCT_CLEANUP_INVALID' 'Staged installed resume script is not exact.' $proof.resumeScriptPath}
    foreach($definition in @([pscustomobject]@{kind='StartMenu';sha=[string]$Transaction.readyEvidence.startMenuSha256},[pscustomobject]@{kind='Desktop';sha=[string]$Transaction.readyEvidence.desktopSha256})){$evidence=Get-CcodProductShortcutEvidence $definition.kind;if($null-eq$evidence-or$evidence.sha256-cne$definition.sha-or$evidence.target-cne[string]$Transaction.readyEvidence.targetPath-or$evidence.arguments-cne[string]$Transaction.readyEvidence.arguments){Throw-CcodProductRegistrationError 'CCOD_PRODUCT_CLEANUP_INVALID' 'Current product shortcut is not exact before installing resume entry.' $definition.kind}}
    $values=Get-CcodInstalledResumeRegistryValues $Transaction;$kinds=Get-CcodInstalledResumeRegistryKinds $values;$original=Get-CcodInstalledResumeOriginalRegistryValues $Transaction;$originalKinds=Get-CcodInstalledResumeRegistryKinds $original;$subkey='Software\Microsoft\Windows\CurrentVersion\Uninstall\CodexRemote-fix';$key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subkey,$true)
    if($null-eq$key){Throw-CcodProductRegistrationError 'CCOD_PRODUCT_CLEANUP_INVALID' 'Current product registry disappeared before resume installation.' $Transaction.runtimeId}
    try{
        if(-not(Test-CcodInstalledResumeRegistryTransition -Key $key -Original $original -Expected $values -ExpectedKinds $kinds)){throw 'current/resume registry transition set is invalid'}
        $key.SetValue('UninstallString',[string]$values.UninstallString,[Microsoft.Win32.RegistryValueKind]::String)
        foreach($name in @($values.Keys|Where-Object{$_-notin@('QuietUninstallString','UninstallString')})){$kind=[Enum]::Parse([Microsoft.Win32.RegistryValueKind],[string]$kinds[$name]);$key.SetValue([string]$name,$values[$name],$kind)}
        $key.SetValue('QuietUninstallString',[string]$values.QuietUninstallString,[Microsoft.Win32.RegistryValueKind]::String)
        if(-not(Test-CcodProductRegistryEntryValues -Key $key -Values $values -Kinds $kinds)){throw 'resume registry read-back mismatch'}
    }catch{Throw-CcodProductRegistrationError 'CCOD_PRODUCT_CLEANUP_INVALID' 'Installed resume registration could not be committed exactly.' $Transaction.runtimeId}finally{$key.Dispose()}
    $observed=Read-CcodInstalledResumeProductState $Transaction
    if($null-eq$observed-or-not$observed.valid-or-not$observed.registryPresent-or@($observed.shortcutEntries).Count-ne2){Throw-CcodProductRegistrationError 'CCOD_PRODUCT_CLEANUP_INVALID' 'Installed resume registration is not durable.' $Transaction.runtimeId}
    return $observed
}

function Test-CcodInstalledUninstallResumeRegistration {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Transaction)
    try{$state=Read-CcodInstalledResumeProductState $Transaction;return $null-ne$state-and$state.valid-and$state.registryPresent}catch{return $false}
}

function Get-CcodInstalledUninstallResumeRegistrationState {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Transaction)
    try{$state=Read-CcodInstalledResumeProductState $Transaction;if($null-eq$state-or-not$state.valid){return 'Invalid'};if($state.registryPresent){return 'Exact'};if(@($state.shortcutEntries).Count-eq0){return 'Absent'};return 'Invalid'}catch{return 'Invalid'}
}

function Remove-CcodInstalledUninstallProductShortcuts {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Transaction)
    $effectivePhase=if($Transaction.phase-ceq'Failed'){$Transaction.resumePhase}else{$Transaction.phase};if($effectivePhase-cne'ReadyForInno'){Throw-CcodProductRegistrationError 'CCOD_PRODUCT_CLEANUP_INVALID' 'Installed shortcuts may be removed only at ReadyForInno.' $Transaction.transactionId}
    $state=Read-CcodInstalledResumeProductState $Transaction
    if($null-eq$state-or-not$state.valid-or-not$state.registryPresent){Throw-CcodProductRegistrationError 'CCOD_PRODUCT_CLEANUP_INVALID' 'Durable installed resume entry is missing before shortcut cleanup.' $Transaction.transactionId}
    foreach($entry in @($state.shortcutEntries)){Remove-CcodCurrentProductEntry $entry}
    $after=Read-CcodInstalledResumeProductState $Transaction
    if($null-eq$after-or-not$after.valid-or-not$after.registryPresent-or@($after.shortcutEntries).Count-ne0){Throw-CcodProductRegistrationError 'CCOD_PRODUCT_CLEANUP_INVALID' 'Installed product shortcuts did not converge while the resume entry remained.' $Transaction.transactionId}
    return $after
}

function Remove-CcodInstalledUninstallResumeRegistration {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Transaction,[switch]$CompletedReceiptProven)
    if($Transaction.phase-cne'Completed'-or$Transaction.resumePhase-cne'Completed'-or-not$CompletedReceiptProven){Throw-CcodProductRegistrationError 'CCOD_PRODUCT_CLEANUP_INVALID' 'Final resume registry removal requires a durable Completed transaction and receipt proof.' $Transaction.transactionId}
    $state=Read-CcodInstalledResumeProductState $Transaction
    if($null-eq$state-or-not$state.valid){Throw-CcodProductRegistrationError 'CCOD_PRODUCT_CLEANUP_INVALID' 'Installed resume registration is not exact before final removal.' $Transaction.transactionId}
    if(-not$state.registryPresent){return $true}
    if(@($state.shortcutEntries).Count-ne0){Throw-CcodProductRegistrationError 'CCOD_PRODUCT_CLEANUP_INVALID' 'Installed shortcuts remain before final resume registry removal.' $Transaction.transactionId}
    Initialize-CcodLegacyRegistryNative
    $rights=[Security.AccessControl.RegistryRights]::QueryValues-bor[Security.AccessControl.RegistryRights]::EnumerateSubKeys-bor[Security.AccessControl.RegistryRights]::Delete
    $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey([string]$state.registryEntry.path,[Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,$rights)
    if($null-eq$key){Throw-CcodProductRegistrationError 'CCOD_PRODUCT_CLEANUP_INVALID' 'Installed resume registry disappeared before exact handle deletion.' $Transaction.transactionId}
    try{$values=Get-CcodInstalledResumeRegistryValues $Transaction;$kinds=Get-CcodInstalledResumeRegistryKinds $values;if(-not(Test-CcodProductRegistryEntryValues -Key $key -Values $values -Kinds $kinds)){throw 'resume registry changed'};[CcodLegacyRegistryNativeV1]::DeleteKey($key)}catch{Throw-CcodProductRegistrationError 'CCOD_PRODUCT_CLEANUP_INVALID' 'Installed resume registry could not be deleted by its exact handle.' $Transaction.transactionId}finally{$key.Dispose()}
    $after=Read-CcodInstalledResumeProductState $Transaction
    if($null-eq$after-or-not$after.valid-or$after.registryPresent-or@($after.shortcutEntries).Count-ne0){Throw-CcodProductRegistrationError 'CCOD_PRODUCT_CLEANUP_INVALID' 'Installed resume registry deletion did not converge.' $Transaction.transactionId}
    return $true
}
function Get-CcodLegacySnapshotEntryName {
    param($Entry,[Parameter(Mandatory)][string]$ExpectedAppId)
    if($Entry-is[string]){return [string]$Entry}
    if($null-eq$Entry-or$null-eq$Entry.PSObject.Properties['kind']){return $null}
    if($Entry.kind-ceq'Registry'){
        if($Entry.path-isnot[string]-or[string]$Entry.path-cne(Get-CcodLegacyRegistryPath $ExpectedAppId)){return $null}
        return 'Registry'
    }
    if($Entry.kind-ceq'Shortcut'-and$Entry.name-is[string]){
        try{$expectedPath=Get-CcodLegacyShortcutPath -RelativeName ([string]$Entry.name);$actualPath=[IO.Path]::GetFullPath([string]$Entry.path)}catch{return $null}
        if($actualPath-cne$expectedPath){return $null}
        return [string]$Entry.name
    }
    return $null
}

function Test-CcodLegacySnapshotForProfile {
    param($Snapshot,[Parameter(Mandatory)]$Profile,[Parameter(Mandatory)][string]$ExpectedAppId)
    if($null-eq$Snapshot-or-not(Test-CcodProductExactProperties $Snapshot @('appId','entries'))-or
       $Snapshot.appId-isnot[string]-or[string]$Snapshot.appId-cne$ExpectedAppId-or$null-eq$Snapshot.entries){return $false}
    $actual=[Collections.Generic.List[string]]::new()
    foreach($entry in @($Snapshot.entries)){$name=Get-CcodLegacySnapshotEntryName -Entry $entry -ExpectedAppId $ExpectedAppId;if($null-eq$name){return $false};$actual.Add($name)}
    return Test-CcodProductExactStringSet $actual (@('Registry')+@($Profile.shortcutNames))
}

function Test-CcodLegacyShortcutSnapshotEntry {
    param(
        $Entry,
        [Parameter(Mandatory)]$LegacyRegistration,
        [Parameter(Mandatory)]$Profile,
        [Parameter(Mandatory)][string]$ExpectedInstallRoot
    )
    if(-not(Test-CcodProductExactProperties $Entry $script:CcodLegacyShortcutSnapshotFields)-or
       $Entry.kind-isnot[string]-or$Entry.kind-cne'Shortcut'-or$Entry.name-isnot[string]-or
       $Entry.path-isnot[string]-or$Entry.sha256-isnot[string]-or$Entry.sha256-cnotmatch'^[0-9a-f]{64}$'-or
       $Entry.bytesBase64-isnot[string]-or$Entry.targetPath-isnot[string]-or$Entry.arguments-isnot[string]-or$Entry.workingDirectory-isnot[string]){return $false}
    try{
        $expectedPath=Get-CcodLegacyShortcutPath -RelativeName ([string]$Entry.name)
        $actualPath=[IO.Path]::GetFullPath([string]$Entry.path)
        $contract=Get-CcodLegacyShortcutContract -LegacyRegistration $LegacyRegistration -Profile $Profile -Name ([string]$Entry.name) -ExpectedInstallRoot $ExpectedInstallRoot
        $target=[IO.Path]::GetFullPath([string]$Entry.targetPath)
        $expectedTarget=[IO.Path]::GetFullPath([string]$contract.targetPath)
        $working=if([string]::IsNullOrEmpty([string]$Entry.workingDirectory)){''}else{[IO.Path]::GetFullPath([string]$Entry.workingDirectory).TrimEnd('\')}
        $expectedWorking=if([string]::IsNullOrEmpty([string]$contract.workingDirectory)){''}else{[IO.Path]::GetFullPath([string]$contract.workingDirectory).TrimEnd('\')}
        $bytes=[Convert]::FromBase64String([string]$Entry.bytesBase64)
        $sha=[Security.Cryptography.SHA256]::Create()
        try{$capturedHash=[BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
    }catch{return $false}
    return $actualPath-cne$null-and$actualPath-ceq$expectedPath-and$target-ceq$expectedTarget-and
        [string]$Entry.arguments-ceq[string]$contract.arguments-and$working-ceq$expectedWorking-and$capturedHash-ceq[string]$Entry.sha256
}

function Assert-CcodLegacyMigrationPlan {
    param([Parameter(Mandatory)]$Plan,[Parameter(Mandatory)][string]$ExpectedAppId,[Parameter(Mandatory)][string]$ExpectedInstallRoot)
    $root=Get-CcodProductFullPath $ExpectedInstallRoot
    if(-not(Test-CcodProductExactProperties $Plan $script:CcodLegacyMigrationPlanFields)-or$Plan.appId-isnot[string]-or$Plan.appId-cne$ExpectedAppId-or
       $Plan.expectedInstallRoot-isnot[string]-or(Get-CcodProductFullPath ([string]$Plan.expectedInstallRoot))-cne$root-or$Plan.legacyPresent-isnot[bool]){
        Throw-CcodProductRegistrationError 'CCOD_LEGACY_PRODUCT_REGISTRATION_INVALID' 'Legacy migration plan identity is invalid.' $Plan
    }
    if(-not[bool]$Plan.legacyPresent){
        if($null-ne$Plan.legacyRegistration-or$null-ne$Plan.profile-or$null-ne$Plan.snapshot){Throw-CcodProductRegistrationError 'CCOD_LEGACY_PRODUCT_REGISTRATION_INVALID' 'Absent legacy migration plan contains unexpected evidence.' $Plan}
        return $Plan
    }
    $profile=Resolve-CcodLegacyRegistrationProfile -LegacyRegistration $Plan.legacyRegistration
    if($null-eq$Plan.profile-or$profile.profileId-cne[string]$Plan.profile.profileId-or-not(Test-CcodLegacySnapshotForProfile -Snapshot $Plan.snapshot -Profile $profile -ExpectedAppId $ExpectedAppId)){
        Throw-CcodProductRegistrationError 'CCOD_LEGACY_PRODUCT_REGISTRATION_INVALID' 'Legacy migration plan no longer matches one exact profile.' $Plan
    }
    foreach($entry in @($Plan.snapshot.entries)){
        if($entry-is[string]){if([string]$entry-cne'Registry'){Throw-CcodProductRegistrationError 'CCOD_LEGACY_PRODUCT_REGISTRATION_INVALID' 'Legacy migration plan contains an unbound shortcut.' $entry};continue}
        if($entry.kind-ceq'Shortcut'-and-not(Test-CcodLegacyShortcutSnapshotEntry -Entry $entry -LegacyRegistration $Plan.legacyRegistration -Profile $profile -ExpectedInstallRoot $root)){
            Throw-CcodProductRegistrationError 'CCOD_LEGACY_PRODUCT_REGISTRATION_INVALID' 'Legacy shortcut evidence does not match its historical target contract.' $entry
        }
    }
    return $Plan
}

function Get-CcodLegacyProductRegistrationMigrationPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ExpectedAppId,[Parameter(Mandatory)][string]$ExpectedInstallRoot,[hashtable]$Adapters)
    if($ExpectedAppId-cne$script:CcodProductAppId){Throw-CcodProductRegistrationError 'CCOD_LEGACY_PRODUCT_REGISTRATION_INVALID' 'Legacy product migration requires the canonical AppId.' $ExpectedAppId}
    $root=Get-CcodProductFullPath $ExpectedInstallRoot
    $adapter=Get-CcodProductRegistrationAdapters $Adapters
    $legacy=&$adapter.ReadLegacyRegistration $ExpectedAppId
    if($null-eq$legacy){return [pscustomobject][ordered]@{appId=$ExpectedAppId;expectedInstallRoot=$root;legacyPresent=$false;legacyRegistration=$null;profile=$null;snapshot=$null}}
    $profile=Resolve-CcodLegacyRegistrationProfile -LegacyRegistration $legacy
    $snapshot=&$adapter.ReadLegacySnapshot $ExpectedAppId $profile
    $plan=[pscustomobject][ordered]@{appId=$ExpectedAppId;expectedInstallRoot=$root;legacyPresent=$true;legacyRegistration=$legacy;profile=$profile;snapshot=$snapshot}
    [void](Assert-CcodLegacyMigrationPlan -Plan $plan -ExpectedAppId $ExpectedAppId -ExpectedInstallRoot $root)
    return $plan
}

function Test-CcodLegacySnapshotCurrentReplacement {
    param($Entry,[Parameter(Mandatory)][string]$Name,[Parameter(Mandatory)]$CurrentProof)
    if($Entry-is[string]-or$null-eq$Entry-or$Entry.kind-cne'Shortcut'-or$Entry.name-isnot[string]-or[string]$Entry.name-cne$Name-or
       $Entry.path-isnot[string]-or$Entry.sha256-isnot[string]){return $false}
    try{$expectedPath=Get-CcodLegacyShortcutPath -RelativeName $Name;$actualPath=[IO.Path]::GetFullPath([string]$Entry.path)}catch{return $false}
    if($actualPath-cne$expectedPath){return $false}
    $expectedSha256=if($Name-ceq$script:CcodCurrentShortcutNames[0]){[string]$CurrentProof.startMenuSha256}elseif($Name-ceq$script:CcodCurrentShortcutNames[1]){[string]$CurrentProof.desktopSha256}else{return $false}
    return [string]$Entry.sha256-ceq$expectedSha256
}

function Read-CcodLegacySnapshot {
    param([string]$ExpectedAppId,[Parameter(Mandatory)]$ExpectedProfile)
    $legacy=Read-CcodCurrentUserLegacyRegistration $ExpectedAppId;if($null-eq$legacy){return $null}
    $observedProfile=Resolve-CcodLegacyRegistrationProfile -LegacyRegistration $legacy
    if($observedProfile.profileId-cne$ExpectedProfile.profileId){throw 'legacy profile changed before snapshot'}
    $entries=[Collections.Generic.List[object]]::new();$keyPath=Get-CcodLegacyRegistryPath $ExpectedAppId;$key=Get-Item -LiteralPath $keyPath -ErrorAction Stop
    try{
        $names=@($key.GetValueNames());if($key.GetSubKeyNames().Count-ne0-or@($names|Where-Object{$script:CcodLegacyRegistryValueNames-cnotcontains$_}).Count-ne0){throw 'legacy registry contains unknown state'}
        $values=[ordered]@{};foreach($name in $names){$values[$name]=[pscustomobject]@{value=$key.GetValue($name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames);kind=[string]$key.GetValueKind($name)}}
    }finally{$key.Dispose()}
    $entries.Add([pscustomobject]@{kind='Registry';path=$keyPath;values=$values})
    foreach($name in @($ExpectedProfile.shortcutNames)){
        $path=Get-CcodLegacyShortcutPath -RelativeName $name;$item=Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if($item.PSIsContainer-or($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0-or[string]$item.Name-cne[IO.Path]::GetFileName($name)){throw 'legacy shortcut unsafe'}
        $shell=$null;$shortcut=$null
        try{
            $shell=New-Object -ComObject WScript.Shell;$shortcut=$shell.CreateShortcut($path)
            $target=[IO.Path]::GetFullPath([string]$shortcut.TargetPath);$arguments=[string]$shortcut.Arguments;$workingDirectory=[string]$shortcut.WorkingDirectory
            if(-not[string]::IsNullOrEmpty($workingDirectory)){$workingDirectory=[IO.Path]::GetFullPath($workingDirectory).TrimEnd('\')}
        }finally{
            if($null-ne$shortcut){[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut)}
            if($null-ne$shell){[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)}
        }
        $bytes=[IO.File]::ReadAllBytes($path);$entries.Add([pscustomobject][ordered]@{kind='Shortcut';name=$name;path=$path;sha256=Get-CcodProductFileSha256 $path;bytesBase64=[Convert]::ToBase64String($bytes);targetPath=$target;arguments=$arguments;workingDirectory=$workingDirectory})
    }
    return [pscustomobject][ordered]@{appId=$ExpectedAppId;entries=@($entries)}
}
function Initialize-CcodLegacyRegistryNative {
    if($null-ne('CcodLegacyRegistryNativeV1'-as[type])){return}
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32;
using Microsoft.Win32.SafeHandles;

public sealed class CcodLegacyRegistryCreateResultV1 : IDisposable
{
    private SafeRegistryHandle nativeHandle;
    public RegistryKey Key { get; private set; }
    public uint Disposition { get; private set; }
    internal CcodLegacyRegistryCreateResultV1(IntPtr handle, uint disposition)
    {
        nativeHandle = new SafeRegistryHandle(handle, true);
        Key = RegistryKey.FromHandle(nativeHandle);
        Disposition = disposition;
    }
    public void Dispose()
    {
        if (Key != null) { Key.Dispose(); Key = null; }
        if (nativeHandle != null) { nativeHandle.Dispose(); nativeHandle = null; }
    }
}

public static class CcodLegacyRegistryNativeV1
{
    private const int KEY_QUERY_VALUE = 0x0001;
    private const int KEY_SET_VALUE = 0x0002;
    private const int KEY_ENUMERATE_SUB_KEYS = 0x0008;
    private const int DELETE = 0x00010000;
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern int RegCreateKeyExW(IntPtr hKey, string subKey, uint reserved, string keyClass, uint options, int desiredAccess, IntPtr securityAttributes, out IntPtr result, out uint disposition);
    [DllImport("ntdll.dll", ExactSpelling = true)]
    private static extern int NtCompareObjects(IntPtr first, IntPtr second);
    [DllImport("ntdll.dll", ExactSpelling = true)]
    private static extern int NtDeleteKey(IntPtr keyHandle);
    [DllImport("ntdll.dll", ExactSpelling = true)]
    private static extern uint RtlNtStatusToDosError(int status);

    public static CcodLegacyRegistryCreateResultV1 CreateCurrentUserKey(string subKey)
    {
        IntPtr handle;
        uint disposition;
        int error = RegCreateKeyExW(new IntPtr(unchecked((int)0x80000001)), subKey, 0, null, 0, KEY_QUERY_VALUE | KEY_SET_VALUE | KEY_ENUMERATE_SUB_KEYS | DELETE, IntPtr.Zero, out handle, out disposition);
        if (error != 0) throw new Win32Exception(error);
        return new CcodLegacyRegistryCreateResultV1(handle, disposition);
    }
    public static bool IsSameKey(RegistryKey first, RegistryKey second)
    {
        if (first == null || second == null) return false;
        return NtCompareObjects(first.Handle.DangerousGetHandle(), second.Handle.DangerousGetHandle()) == 0;
    }
    public static void DeleteKey(RegistryKey key)
    {
        if (key == null) throw new ArgumentNullException("key");
        int status = NtDeleteKey(key.Handle.DangerousGetHandle());
        if (status < 0) throw new Win32Exception((int)RtlNtStatusToDosError(status));
    }
}
'@ -ErrorAction Stop
}

function Get-CcodLegacyRegistryNativeSubKey {
    param([Parameter(Mandatory)][string]$Path)
    if(-not$Path.StartsWith('HKCU:\',[StringComparison]::Ordinal)-or$Path.Length-le6){throw 'legacy registry path is invalid'}
    return $Path.Substring(6)
}

function Get-CcodLegacyRegistryMutationAdapters {
    param([hashtable]$Adapters)
    $defaults=@{
        OpenExisting={
            param($Path)
            $rights=[Security.AccessControl.RegistryRights]::QueryValues-bor[Security.AccessControl.RegistryRights]::SetValue-bor[Security.AccessControl.RegistryRights]::EnumerateSubKeys-bor[Security.AccessControl.RegistryRights]::Delete
            $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey((Get-CcodLegacyRegistryNativeSubKey $Path),[Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,$rights)
            if($null-eq$key){return $null}
            [pscustomobject][ordered]@{key=$key;resource=$key;disposition='OpenedExisting'}
        }
        CloseKey={param($Handle)$Handle.resource.Dispose()}
        GetValueNames={param($Handle)@($Handle.key.GetValueNames())}
        GetSubKeyNames={param($Handle)@($Handle.key.GetSubKeyNames())}
        GetValue={param($Handle,$Name)$Handle.key.GetValue([string]$Name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)}
        GetValueKind={param($Handle,$Name)[string]$Handle.key.GetValueKind([string]$Name)}
        DeleteValue={param($Handle,$Name)$Handle.key.DeleteValue([string]$Name,$true)}
        SetValue={param($Handle,$Name,$Value,$Kind)$valueKind=[Enum]::Parse([Microsoft.Win32.RegistryValueKind],[string]$Kind);$Handle.key.SetValue([string]$Name,$Value,$valueKind)}
        DeleteKey={param($Handle)Initialize-CcodLegacyRegistryNative;[CcodLegacyRegistryNativeV1]::DeleteKey($Handle.key)}
        TestKeyAtPath={
            param($Path,$Handle)
            $current=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey((Get-CcodLegacyRegistryNativeSubKey $Path),$false)
            if($null-eq$current){return $false}
            try{Initialize-CcodLegacyRegistryNative;return [CcodLegacyRegistryNativeV1]::IsSameKey($Handle.key,$current)}finally{$current.Dispose()}
        }
        CreateKey={
            param($Path)
            Initialize-CcodLegacyRegistryNative;$result=[CcodLegacyRegistryNativeV1]::CreateCurrentUserKey((Get-CcodLegacyRegistryNativeSubKey $Path))
            $disposition=if($result.Disposition-eq1){'CreatedNew'}elseif($result.Disposition-eq2){'OpenedExisting'}else{$result.Dispose();throw 'legacy registry create disposition is invalid'}
            [pscustomobject][ordered]@{key=$result.Key;resource=$result;disposition=$disposition}
        }
    }
    if($null-eq$Adapters){return $defaults}
    if($Adapters-isnot[hashtable]){throw 'legacy registry adapters are invalid'}
    $resolved=@{};foreach($name in $defaults.Keys){$resolved[$name]=$defaults[$name]}
    foreach($name in $Adapters.Keys){if($name-isnot[string]-or-not$resolved.ContainsKey($name)-or$Adapters[$name]-isnot[scriptblock]){throw 'legacy registry adapters are invalid'};$resolved[$name]=$Adapters[$name]}
    return $resolved
}

function Get-CcodLegacyRegistryMutationState {
    param([Parameter(Mandatory)]$Entry)
    if($null-eq$Entry.PSObject.Properties['mutationState']){$Entry|Add-Member -NotePropertyName mutationState -NotePropertyValue ([pscustomobject]@{status='Captured'})}
    $state=$Entry.mutationState
    if($null-eq$state-or$state.status-isnot[string]){throw 'legacy registry mutation state is invalid'}
    return $state
}

function Test-CcodLegacyRegistryHandleExact {
    param([Parameter(Mandatory)]$Entry,[Parameter(Mandatory)]$Handle,[Parameter(Mandatory)][hashtable]$Adapters)
    $names=@(&$Adapters.GetValueNames $Handle);$subkeys=@(&$Adapters.GetSubKeyNames $Handle)
    if($subkeys.Count-ne0-or-not(Test-CcodProductExactStringSet $names @($Entry.values.Keys))){return $false}
    foreach($name in @($Entry.values.Keys)){
        $actualKind=&$Adapters.GetValueKind $Handle $name;$actualValue=$Adapters.GetValue.InvokeReturnAsIs($Handle,$name)
        if([string]$actualKind-cne[string]$Entry.values[$name].kind-or($actualValue|ConvertTo-Json -Compress)-cne($Entry.values[$name].value|ConvertTo-Json -Compress)){return $false}
    }
    return $true
}

function Remove-CcodLegacySnapshotEntry {
    param($Entry,[hashtable]$RegistryAdapters)
    if($Entry-is[string]){return}
    if($Entry.kind-ceq'Registry'){
        $state=Get-CcodLegacyRegistryMutationState $Entry;$adapter=Get-CcodLegacyRegistryMutationAdapters $RegistryAdapters;$handle=&$adapter.OpenExisting $Entry.path
        if($null-eq$handle){throw 'legacy registry disappeared before deletion'}
        $mutationStarted=$false;$operationFailure=$null;$closeFailure=$null
        try{
            if(-not(Test-CcodLegacyRegistryHandleExact -Entry $Entry -Handle $handle -Adapters $adapter)-or-not(&$adapter.TestKeyAtPath $Entry.path $handle)){throw 'legacy registry changed'}
            foreach($name in @($Entry.values.Keys)){$mutationStarted=$true;&$adapter.DeleteValue $handle $name}
            if(@(&$adapter.GetValueNames $handle).Count-ne0){throw 'legacy registry values remain after deletion'}
            &$adapter.DeleteKey $handle
            $state.status='Deleted'
        }catch{
            $operationFailure=$_
            if($mutationStarted-and$state.status-cne'Deleted'){
                $restored=$false
                try{
                    foreach($name in @($Entry.values.Keys)){&$adapter.SetValue $handle $name $Entry.values[$name].value $Entry.values[$name].kind}
                    $restored=(Test-CcodLegacyRegistryHandleExact -Entry $Entry -Handle $handle -Adapters $adapter)-and[bool](&$adapter.TestKeyAtPath $Entry.path $handle)
                }catch{$restored=$false}
                $state.status=if($restored){'SameHandleRestoredExact'}else{'PartialUnresolved'}
            }
        }finally{try{&$adapter.CloseKey $handle}catch{$closeFailure=$_}}
        if($null-ne$closeFailure){$state.status='PartialUnresolved';throw $closeFailure}
        if($null-ne$operationFailure){throw $operationFailure}
        return
    }
    if($Entry.kind-cne'Shortcut'){throw 'unknown legacy snapshot entry'}
    if(-not[IO.File]::Exists($Entry.path)-or(Get-CcodProductFileSha256 $Entry.path)-cne$Entry.sha256){throw 'legacy shortcut changed'}
    Remove-Item -LiteralPath $Entry.path -Force -ErrorAction Stop
}
function Compare-CcodLegacySnapshotEntry {
    param($Expected,$Current)
    if($null-eq$Current){return 'Absent'}
    if($null-eq$Expected-or$Expected.kind-cne$Current.kind){return 'Mismatch'};$pathMatches=if($Expected.kind-ceq'Registry'){[string]$Expected.path-ceq[string]$Current.path}else{[IO.Path]::GetFullPath([string]$Expected.path)-ceq[IO.Path]::GetFullPath([string]$Current.path)};if(-not$pathMatches){return 'Mismatch'}
    if($Expected.kind-ceq'Registry'){
        $subkeys=@(if($null-ne$Current.PSObject.Properties['subKeyNames']){@($Current.subKeyNames)});if($subkeys.Count-ne0-or(@($Expected.values.Keys|Sort-Object)-join"`0")-cne(@($Current.values.Keys|Sort-Object)-join"`0")){return 'Mismatch'}
        foreach($name in @($Expected.values.Keys)){if([string]$Expected.values[$name].kind-cne[string]$Current.values[$name].kind-or($Expected.values[$name].value|ConvertTo-Json -Compress)-cne($Current.values[$name].value|ConvertTo-Json -Compress)){return 'Mismatch'}}
        return 'Exact'
    }
    if($Expected.kind-ceq'Shortcut'-and$Expected.sha256-is[string]-and$Current.sha256-is[string]-and$Expected.sha256-ceq$Current.sha256){return 'Exact'}
    return 'Mismatch'
}
function Read-CcodLegacySnapshotEntry {
    param($Entry,[hashtable]$RegistryAdapters)
    if($Entry-is[string]){return $null}
    if($Entry.kind-ceq'Registry'){
        $state=Get-CcodLegacyRegistryMutationState $Entry
        if($state.status-in@('SameHandleRestoredExact','CreatedExact')){return 'Exact'}
        if($state.status-in@('PartialUnresolved','CreateBlocked','CreateUnresolved')){return 'Mismatch'}
        $adapter=Get-CcodLegacyRegistryMutationAdapters $RegistryAdapters;$handle=&$adapter.OpenExisting $Entry.path
        if($null-eq$handle){return $null}
        try{
            if($state.status-ceq'Deleted'){return 'Mismatch'}
            if((Test-CcodLegacyRegistryHandleExact -Entry $Entry -Handle $handle -Adapters $adapter)-and[bool](&$adapter.TestKeyAtPath $Entry.path $handle)){return 'Exact'}
            return 'Mismatch'
        }finally{&$adapter.CloseKey $handle}
    }
    if([IO.File]::Exists($Entry.path)){$current=[pscustomobject]@{kind='Shortcut';path=[string]$Entry.path;sha256=Get-CcodProductFileSha256 $Entry.path};return Compare-CcodLegacySnapshotEntry -Expected $Entry -Current $current};$null
}
function Restore-CcodLegacySnapshotEntry {
    param($Entry,[hashtable]$RegistryAdapters)
    if($Entry-is[string]){return}
    if($Entry.kind-ceq'Registry'){
        $state=Get-CcodLegacyRegistryMutationState $Entry
        if($state.status-cne'Deleted'){throw 'legacy registry is not eligible for path-level restoration'}
        $adapter=Get-CcodLegacyRegistryMutationAdapters $RegistryAdapters;$created=$null;$createdNew=$false;$accepted=$false;$operationFailure=$null;$closeFailure=$null
        try{
            $created=&$adapter.CreateKey $Entry.path
            if($null-eq$created-or$created.disposition-cne'CreatedNew'){$state.status='CreateBlocked';throw 'legacy registry replacement won the create-only race'}
            $createdNew=$true
            foreach($name in @($Entry.values.Keys)){&$adapter.SetValue $created $name $Entry.values[$name].value $Entry.values[$name].kind}
            if(-not(Test-CcodLegacyRegistryHandleExact -Entry $Entry -Handle $created -Adapters $adapter)-or-not(&$adapter.TestKeyAtPath $Entry.path $created)){throw 'created legacy registry did not re-read exactly'}
            $state.status='CreatedExact';$accepted=$true
        }catch{
            $operationFailure=$_
            if($createdNew-and-not$accepted){try{&$adapter.DeleteKey $created}catch{};$state.status='CreateUnresolved'}
        }finally{if($null-ne$created){try{&$adapter.CloseKey $created}catch{$closeFailure=$_}}}
        if($null-ne$closeFailure){$state.status='CreateUnresolved';throw $closeFailure}
        if($null-ne$operationFailure){throw $operationFailure}
        return
    }
    if($Entry.kind-cne'Shortcut'){throw 'unknown legacy snapshot entry'}
    if([IO.File]::Exists($Entry.path)-or[IO.Directory]::Exists($Entry.path)){throw 'legacy shortcut replacement present'}
    [IO.Directory]::CreateDirectory((Split-Path $Entry.path -Parent))|Out-Null;$bytes=[Convert]::FromBase64String([string]$Entry.bytesBase64);$stream=[IO.File]::Open($Entry.path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
    if((Get-CcodProductFileSha256 $Entry.path)-cne$Entry.sha256){throw 'legacy shortcut restore mismatch'}
}
function Write-CcodLegacyCompensationFailure {param($Record)$local=[Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData);$root=Join-Path $local 'CodexControlOtherDevices\state\legacy-registration-compensation';[IO.Directory]::CreateDirectory($root)|Out-Null;$path=Join-Path $root (([guid]::NewGuid().ToString('D'))+'.json');$bytes=[Text.UTF8Encoding]::new($false).GetBytes(($Record|ConvertTo-Json -Depth 8 -Compress)+"`n");$stream=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read);try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}}

function Commit-CcodProductRegistration {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Registration,[Parameter(Mandatory)]$FileTransaction,[hashtable]$Adapters)
    if ($null -eq $FileTransaction -or -not (Test-CcodProductRegistration -Registration $Registration -ExpectedRuntimeId ([string]$Registration.runtimeId) -ExpectedVersion $script:CcodProductVersion -ExpectedPackageSha256 ([string]$Registration.packageSha256))) {
        Throw-CcodProductRegistrationError 'CCOD_PRODUCT_REGISTRATION_INVALID' 'Product registration contract is invalid.' $Registration
    }
    $adapter = Get-CcodProductRegistrationAdapters $Adapters
    $ready = & $adapter.GetReadyProof $Registration
    if (-not (Test-CcodProductReadyProof $ready $Registration)) {
        Throw-CcodProductRegistrationError 'CCOD_PRODUCT_REGISTRATION_NOT_READY' 'Product registration requires the exact terminal Ready proof.' $Registration.runtimeId
    }
    try {
        & $adapter.WriteProductRegistration $Registration $ready
        & $adapter.WriteShortcut 'StartMenu' $Registration.startMenuShortcut $FileTransaction $ready
        & $adapter.WriteShortcut 'Desktop' $Registration.desktopShortcut $FileTransaction $ready
        $product = & $adapter.ReadProductRegistration $Registration
        $startMenu = & $adapter.ReadShortcut 'StartMenu' $Registration.startMenuShortcut
        $desktop = & $adapter.ReadShortcut 'Desktop' $Registration.desktopShortcut
        if (-not (Test-CcodProductRegistration -Registration $product -ExpectedRuntimeId $Registration.runtimeId -ExpectedVersion $Registration.version -ExpectedPackageSha256 $Registration.packageSha256) -or
            -not (Test-CcodProductShortcut $startMenu $Registration.startMenuShortcut) -or
            -not (Test-CcodProductShortcut $desktop $Registration.desktopShortcut)) {
            throw 'three-record read-back mismatch'
        }
    } catch {
        Throw-CcodProductRegistrationError 'CCOD_PRODUCT_REGISTRATION_FAILED' 'Product registration write/read-back failed; legacy state was retained.' $Registration.runtimeId
    }
    return [pscustomobject][ordered]@{
        schemaVersion = 1; verified = $true; runtimeId = [string]$Registration.runtimeId; version = [string]$Registration.version
        packageSha256 = [string]$Registration.packageSha256; productKeyName = [string]$Registration.productKeyName
        shortcutNames = @([string]$Registration.startMenuShortcut.relativePath,[string]$Registration.desktopShortcut.relativePath)
    }
}

function Remove-CcodLegacyProductRegistration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ExpectedAppId,
        [AllowNull()]$MigrationPlan,
        [AllowNull()]$ExpectedCurrentProof,
        [hashtable]$Adapters
    )
    if ($ExpectedAppId -cne $script:CcodProductAppId) {
        Throw-CcodProductRegistrationError 'CCOD_LEGACY_PRODUCT_REGISTRATION_INVALID' 'Legacy product migration requires the canonical AppId and a verified new registration.' $ExpectedAppId
    }
    if($null-eq$MigrationPlan){Throw-CcodProductRegistrationError 'CCOD_LEGACY_PRODUCT_REGISTRATION_INVALID' 'Legacy product migration requires a pre-registration capture plan.' $ExpectedAppId}
    if($null-eq$ExpectedCurrentProof-or-not(Test-CcodCurrentVerifiedRegistration $ExpectedCurrentProof)){Throw-CcodProductRegistrationError 'CCOD_LEGACY_PRODUCT_REGISTRATION_INVALID' 'Legacy product migration requires the exact expected current proof.' $ExpectedAppId}
    $adapter = Get-CcodProductRegistrationAdapters $Adapters
    [void](Assert-CcodLegacyMigrationPlan -Plan $MigrationPlan -ExpectedAppId $ExpectedAppId -ExpectedInstallRoot ([string]$MigrationPlan.expectedInstallRoot))
    if(-not[bool]$MigrationPlan.legacyPresent){return}
    $verified=&$adapter.ReadVerifiedRegistration
    if(-not(Test-CcodCurrentVerifiedRegistrationUnchanged -Before $ExpectedCurrentProof -After $verified)){Throw-CcodProductRegistrationError 'CCOD_LEGACY_PRODUCT_REGISTRATION_INVALID' 'Legacy product migration requires an exact current three-record read-back proof.' $ExpectedAppId}
    $profile=$MigrationPlan.profile;$snapshot=$MigrationPlan.snapshot
    $observedLegacy=&$adapter.ReadLegacyRegistration $ExpectedAppId
    if($null-eq$observedLegacy){Throw-CcodProductRegistrationError 'CCOD_LEGACY_PRODUCT_REGISTRATION_INVALID' 'Captured legacy registry disappeared before cleanup.' $ExpectedAppId}
    $expectedObservedNames=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);foreach($name in @($profile.shortcutNames)+@($script:CcodCurrentShortcutNames)){[void]$expectedObservedNames.Add([string]$name)}
    if(-not(Test-CcodProductExactStringSet $observedLegacy.shortcutNames @($expectedObservedNames))-or@($observedLegacy.unsafeShortcutNames).Count-ne0-or
       $observedLegacy.appId-cne$MigrationPlan.legacyRegistration.appId-or
       $observedLegacy.displayVersion-cne$MigrationPlan.legacyRegistration.displayVersion-or$observedLegacy.installLocation-cne$MigrationPlan.legacyRegistration.installLocation-or
       $observedLegacy.uninstallString-cne$MigrationPlan.legacyRegistration.uninstallString){Throw-CcodProductRegistrationError 'CCOD_LEGACY_PRODUCT_REGISTRATION_INVALID' 'Captured legacy profile changed before cleanup.' $ExpectedAppId}
    $removalEntries=[Collections.Generic.List[object]]::new()
    foreach($entry in @($snapshot.entries)){
        $name=Get-CcodLegacySnapshotEntryName -Entry $entry -ExpectedAppId $ExpectedAppId
        if($script:CcodCurrentShortcutNames-ccontains$name){
            continue
        }
        $removalEntries.Add($entry)
    }
    foreach($entry in @($removalEntries)){
        if((&$adapter.ReadLegacyEntry $entry)-cne'Exact'){Throw-CcodProductRegistrationError 'CCOD_LEGACY_PRODUCT_REGISTRATION_INVALID' 'Captured legacy-only state changed before deletion.' (Get-CcodLegacySnapshotEntryName -Entry $entry -ExpectedAppId $ExpectedAppId)}
    }
    $removed=[Collections.Generic.List[object]]::new();$failedEntry=$null
    try{
        foreach($entry in @($removalEntries)){$failedEntry=$entry;&$adapter.RemoveLegacyEntry $entry;$removed.Add($entry);$failedEntry=$null}
        $verifiedAfter=&$adapter.ReadVerifiedRegistration
        if(-not(Test-CcodCurrentVerifiedRegistrationUnchanged -Before $verified -After $verifiedAfter)){throw 'current product registration changed during legacy cleanup'}
    }catch{
        $unresolved=[Collections.Generic.List[string]]::new()
        if($null-ne$failedEntry){
            $failedName=Get-CcodLegacySnapshotEntryName -Entry $failedEntry -ExpectedAppId $ExpectedAppId
            try{$state=&$adapter.ReadLegacyEntry $failedEntry;if($null-eq$state){&$adapter.RestoreLegacyEntry $failedEntry;$state=&$adapter.ReadLegacyEntry $failedEntry};if($state-cne'Exact'){$unresolved.Add($failedName)}}catch{$unresolved.Add($failedName)}
        }
        for($index=$removed.Count-1;$index-ge0;$index--){$entry=$removed[$index];$name=Get-CcodLegacySnapshotEntryName -Entry $entry -ExpectedAppId $ExpectedAppId;try{$state=&$adapter.ReadLegacyEntry $entry;if($null-eq$state){&$adapter.RestoreLegacyEntry $entry;$state=&$adapter.ReadLegacyEntry $entry};if($state-cne'Exact'){$unresolved.Add($name)}}catch{$unresolved.Add($name)}}
        if($unresolved.Count-gt0){$record=[pscustomobject][ordered]@{schemaVersion=1;appId=$ExpectedAppId;state='CompensationFailed';entries=@($unresolved);createdAtUtc=[DateTime]::UtcNow.ToString('o',[Globalization.CultureInfo]::InvariantCulture)};try{&$adapter.WriteLegacyCompensationFailure $record}catch{Throw-CcodProductRegistrationError 'CCOD_LEGACY_PRODUCT_COMPENSATION_FAILED' 'Legacy compensation failure record could not be persisted.' $record};Throw-CcodProductRegistrationError 'CCOD_LEGACY_PRODUCT_COMPENSATION_FAILED' 'Legacy migration compensation remains unresolved; exact entries were recorded.' $record}
        Throw-CcodProductRegistrationError 'CCOD_LEGACY_PRODUCT_REGISTRATION_INVALID' 'Legacy product migration failed and the exact prior set was restored.' $ExpectedAppId
    }
}

Export-ModuleMember -Function New-CcodProductRegistration,Test-CcodProductRegistration,Commit-CcodProductRegistration,Remove-CcodProductRegistration,Remove-CcodLegacyProductRegistration,Get-CcodLegacyProductRegistrationMigrationPlan,Get-CcodLegacyRegistrationProfiles,Resolve-CcodLegacyRegistrationProfile,Set-CcodInstalledUninstallResumeRegistration,Test-CcodInstalledUninstallResumeRegistration,Get-CcodInstalledUninstallResumeRegistrationState,Remove-CcodInstalledUninstallProductShortcuts,Remove-CcodInstalledUninstallResumeRegistration
