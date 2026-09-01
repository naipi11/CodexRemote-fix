Set-StrictMode -Version Latest

$script:CcodProductVersion = '2.5.22'
$script:CcodProductAppId = '{2B9E9F2E-7A32-4A7E-9C1D-9F5B5C6D7E8F}'
$script:CcodProductKeyName = 'CodexRemote-fix'
$script:CcodProductFields = @(
    'schemaVersion','installRoot','runtimeId','version','packageSha256','runtimeRoot','bootstrapPath','uninstallerPath',
    'productKeyName','startMenuShortcut','desktopShortcut'
)
$script:CcodShortcutFields = @('kind','leaf','relativePath','candidatePath','bootstrapPath','installRoot')
$script:CcodReadyFields = @('phase','runtimeId','version','packageSha256','runtimeGeneration','manifestSha256','startMenuSha256','desktopSha256','targetPath','arguments','bootstrapPath','uninstallerPath')
$script:CcodLegacyShortcutNames = @(
    'Programs\Codex Control other devices\Codex Control other devices for Windows.lnk',
    'Programs\Codex Control other devices\Open the tray supervisor.lnk',
    'Programs\Codex Control other devices\Compatibility check.lnk',
    'Programs\Codex Control other devices\Uninstall Codex Control other devices.lnk',
    'Programs\Codex Control other devices\CodexRemote-fix.lnk',
    'Programs\Codex Control other devices\CodexRemote-fix compatibility check.lnk',
    'Programs\Codex Control other devices\Uninstall CodexRemote-fix.lnk',
    ('Desktop\Codex ' + [char]0x8BBE + [char]0x5907 + [char]0x8FDE + [char]0x63A5 + ' (Device Connection).lnk')
)
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
        [uint64]$Proof.runtimeGeneration -gt 0 -and $Proof.manifestSha256 -cmatch '^[0-9a-f]{64}$' -and $Proof.startMenuSha256 -cmatch '^[0-9a-f]{64}$' -and $Proof.desktopSha256 -cmatch '^[0-9a-f]{64}$' -and $Proof.targetPath -is [string] -and [IO.Path]::GetFullPath([string]$Proof.targetPath) -ceq $canonicalTarget -and $Proof.arguments -ceq '/Run /TN "Codex Control Other Devices Supervisor"' -and
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
        ReadLegacySnapshot = { param($ExpectedAppId) Read-CcodLegacySnapshot -ExpectedAppId $ExpectedAppId }
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
    $fileReady=[pscustomobject][ordered]@{phase='Ready';runtimeId=[string]$ReadyEvidence.runtimeId;runtimeGeneration=[uint64]$ReadyEvidence.runtimeGeneration;manifestSha256=[string]$ReadyEvidence.manifestSha256;packageSha256=[string]$ReadyEvidence.packageSha256};$source=Open-CcodInstallRetainedFile -Generation $FileTransaction -RelativePath $relative -ReadyEvidence $fileReady
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
function Read-CcodCurrentUserLegacyRegistration {
    param([string]$ExpectedAppId)
    $path=Get-CcodLegacyRegistryPath $ExpectedAppId;if(-not(Test-Path -LiteralPath $path -PathType Container)){return $null}
    $value=Get-ItemProperty -LiteralPath $path -ErrorAction Stop;$present=[Collections.Generic.List[string]]::new()
    $programs=[Environment]::GetFolderPath([Environment+SpecialFolder]::Programs);$desktop=[Environment]::GetFolderPath([Environment+SpecialFolder]::Desktop)
    foreach($name in $script:CcodLegacyShortcutNames){$relative=$name.Substring($name.IndexOf('\')+1);$candidate=if($name.StartsWith('Programs\',[StringComparison]::Ordinal)){Join-Path $programs $relative}else{Join-Path $desktop $relative};if(Test-Path -LiteralPath $candidate -PathType Leaf){$present.Add($name)}}
    [pscustomobject]@{appId=$ExpectedAppId;uninstallString=[string]$value.UninstallString;shortcutNames=@($present)}
}
function Read-CcodCurrentUserVerifiedRegistration {
    $path=Get-CcodProductRegistryPath;if(-not(Test-Path -LiteralPath $path -PathType Container)){return $null}
    $value=Get-ItemProperty -LiteralPath $path -ErrorAction Stop
    if($value.CcodRuntimeId-isnot[string]-or$value.CcodRuntimeId-cnotmatch'^2\.5\.22-[0-9a-f]{16}-[0-9a-f]{32}$'-or$value.DisplayVersion-cne'2.5.22'-or$value.CcodPackageSha256-isnot[string]-or$value.CcodPackageSha256-cnotmatch'^[0-9a-f]{64}$'){return $null}
    foreach($kind in @('StartMenu','Desktop')){if(-not[IO.File]::Exists((Get-CcodProductShortcutDestination $kind))){return $null}}
    [pscustomobject]@{verified=$true;runtimeId=[string]$value.CcodRuntimeId;version=[string]$value.DisplayVersion;packageSha256=[string]$value.CcodPackageSha256}
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
function Read-CcodCurrentProductState {
    param([string]$ExpectedRuntimeId)
    try{
        $subkey='Software\Microsoft\Windows\CurrentVersion\Uninstall\CodexRemote-fix';$key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subkey,$false);if($null-eq$key){return [pscustomobject]@{valid=$true;reason=$null;entries=@()}}
        try{$allowed=@('CcodDesktopSha256','CcodPackageSha256','CcodRuntimeId','CcodRuntimeGeneration','CcodManifestSha256','CcodShortcutArguments','CcodShortcutTarget','CcodStartMenuSha256','DisplayName','DisplayVersion','InstallLocation','NoModify','NoRepair','Publisher','QuietUninstallString','UninstallString');$names=@($key.GetValueNames()|Sort-Object);if(($names-join'|')-cne(($allowed|Sort-Object)-join'|')){return [pscustomobject]@{valid=$false;reason='UnknownRegistryValue';entries=@()}};$runtime=[string]$key.GetValue('CcodRuntimeId',$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames);$installLocation=[string]$key.GetValue('InstallLocation');$expectedUninstaller=Join-Path $installLocation 'Uninstall-CodexControlOtherDevices.ps1';$expectedCommand='"{0}" -NoProfile -ExecutionPolicy Bypass -File "{1}"'-f(Get-CcodProductPowerShellPath),$expectedUninstaller;if($runtime-cne$ExpectedRuntimeId-or$installLocation-cne[IO.Path]::GetFullPath((Join-Path (Join-Path (Split-Path (Split-Path $installLocation -Parent) -Parent) 'runtime') $runtime))-or[string]$key.GetValue('DisplayName')-cne'CodexRemote-fix'-or[string]$key.GetValue('DisplayVersion')-cne'2.5.22'-or[string]$key.GetValue('Publisher')-cne'naipi11'-or[string]$key.GetValue('UninstallString')-cne$expectedCommand-or[string]$key.GetValue('QuietUninstallString')-cne($expectedCommand+' -Confirm:$false')-or[int]$key.GetValue('NoModify')-ne1-or[int]$key.GetValue('NoRepair')-ne1-or[string]$key.GetValue('CcodPackageSha256')-cnotmatch'^[0-9a-f]{64}$'){return [pscustomobject]@{valid=$false;reason='RegistryMismatch';entries=@()}};foreach($dword in @('NoModify','NoRepair')){if($key.GetValueKind($dword)-ne[Microsoft.Win32.RegistryValueKind]::DWord){return [pscustomobject]@{valid=$false;reason='RegistryType';entries=@()}}};if($key.GetValueKind('CcodRuntimeGeneration')-ne[Microsoft.Win32.RegistryValueKind]::QWord){return [pscustomobject]@{valid=$false;reason='RegistryType';entries=@()}};foreach($stringName in @($allowed|Where-Object{$_-notin@('NoModify','NoRepair','CcodRuntimeGeneration')})){if($key.GetValueKind($stringName)-ne[Microsoft.Win32.RegistryValueKind]::String){return [pscustomobject]@{valid=$false;reason='RegistryType';entries=@()}}};$target=[string]$key.GetValue('CcodShortcutTarget');$arguments=[string]$key.GetValue('CcodShortcutArguments');$start=Get-CcodProductShortcutEvidence 'StartMenu';$desktop=Get-CcodProductShortcutEvidence 'Desktop';if($null-eq$start-or$null-eq$desktop-or$start.target-cne$target-or$desktop.target-cne$target-or$start.arguments-cne$arguments-or$desktop.arguments-cne$arguments-or$start.sha256-cne[string]$key.GetValue('CcodStartMenuSha256')-or$desktop.sha256-cne[string]$key.GetValue('CcodDesktopSha256')){return [pscustomobject]@{valid=$false;reason='ShortcutMismatch';entries=@()}};$captured=[ordered]@{};foreach($name in $names){$captured[$name]=[pscustomobject]@{value=$key.GetValue($name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames);kind=[string]$key.GetValueKind($name)}};$installRoot=[IO.Path]::GetFullPath((Split-Path (Split-Path $installLocation -Parent) -Parent));$readyEvidence=[pscustomobject][ordered]@{phase='Ready';installRoot=$installRoot;runtimeId=$runtime;runtimeGeneration=[uint64]$key.GetValue('CcodRuntimeGeneration');packageSha256=[string]$key.GetValue('CcodPackageSha256');manifestSha256=[string]$key.GetValue('CcodManifestSha256');startMenuSha256=$start.sha256;desktopSha256=$desktop.sha256;targetPath=$target;arguments=$arguments};return [pscustomobject]@{valid=$true;reason=$null;readyEvidence=$readyEvidence;entries=@([pscustomobject]@{kind='StartMenu';path=$start.path;sha256=$start.sha256},[pscustomobject]@{kind='Desktop';path=$desktop.path;sha256=$desktop.sha256},[pscustomobject]@{kind='Registry';path=$subkey;valueNames=$names;values=$captured})}}
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
function Read-CcodLegacySnapshot {
    param([string]$ExpectedAppId)
    $legacy=Read-CcodCurrentUserLegacyRegistration $ExpectedAppId;if($null-eq$legacy){return $null};$entries=[Collections.Generic.List[object]]::new();$keyPath=Get-CcodLegacyRegistryPath $ExpectedAppId;$key=Get-Item -LiteralPath $keyPath -ErrorAction Stop;$names=@($key.GetValueNames());if($key.GetSubKeyNames().Count-ne0-or@($names|Where-Object{$script:CcodLegacyRegistryValueNames-cnotcontains$_}).Count-ne0){throw 'legacy registry contains unknown state'};$values=[ordered]@{};foreach($name in $names){$values[$name]=[pscustomobject]@{value=$key.GetValue($name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames);kind=[string]$key.GetValueKind($name)}};$entries.Add([pscustomobject]@{kind='Registry';path=$keyPath;values=$values});$programs=[Environment]::GetFolderPath([Environment+SpecialFolder]::Programs);$desktop=[Environment]::GetFolderPath([Environment+SpecialFolder]::Desktop);foreach($name in $legacy.shortcutNames){$relative=$name.Substring($name.IndexOf('\')+1);$path=[IO.Path]::GetFullPath($(if($name.StartsWith('Programs\',[StringComparison]::Ordinal)){Join-Path $programs $relative}else{Join-Path $desktop $relative}));$item=Get-Item -LiteralPath $path -Force -ErrorAction Stop;if($item.PSIsContainer-or($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){throw 'legacy shortcut unsafe'};$bytes=[IO.File]::ReadAllBytes($path);$entries.Add([pscustomobject]@{kind='Shortcut';name=$name;path=$path;sha256=Get-CcodProductFileSha256 $path;bytesBase64=[Convert]::ToBase64String($bytes)})};[pscustomobject]@{appId=$ExpectedAppId;entries=@($entries)}
}
function Remove-CcodLegacySnapshotEntry {param($Entry);if($Entry-is[string]){return};if($Entry.kind-ceq'Registry'){$key=$null;try{$key=Get-Item -LiteralPath $Entry.path -ErrorAction Stop;if((@($key.GetValueNames()|Sort-Object)-join'|')-cne((@($Entry.values.Keys)|Sort-Object)-join'|')-or$key.GetSubKeyNames().Count-ne0){throw 'legacy registry changed'};foreach($name in @($Entry.values.Keys)){$current=$key.GetValue($name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames);if([string]$current-cne[string]$Entry.values[$name].value-or[string]$key.GetValueKind($name)-cne[string]$Entry.values[$name].kind){throw 'legacy registry value changed'}};foreach($name in @($Entry.values.Keys)){$key.DeleteValue($name,$true)};$key.Dispose();$key=$null;Remove-Item -LiteralPath $Entry.path -Force -ErrorAction Stop;return}catch{if($null-ne$key){$key.Dispose()};if(-not(Test-Path -LiteralPath $Entry.path)){New-Item -Path $Entry.path -Force|Out-Null};foreach($name in $Entry.values.Keys){if($null-eq(Get-ItemProperty -LiteralPath $Entry.path -Name $name -ErrorAction SilentlyContinue)){$kind=[Enum]::Parse([Microsoft.Win32.RegistryValueKind],[string]$Entry.values[$name].kind);New-ItemProperty -LiteralPath $Entry.path -Name $name -Value $Entry.values[$name].value -PropertyType $kind -Force|Out-Null}};throw}};if(-not[IO.File]::Exists($Entry.path)-or(Get-CcodProductFileSha256 $Entry.path)-cne$Entry.sha256){throw 'legacy shortcut changed'};Remove-Item -LiteralPath $Entry.path -Force -ErrorAction Stop}
function Read-CcodLegacySnapshotEntry {param($Entry);if($Entry-is[string]){return $null};if($Entry.kind-ceq'Registry'){if(Test-Path -LiteralPath $Entry.path){return 'Present'};return $null};if([IO.File]::Exists($Entry.path)){return Get-CcodProductFileSha256 $Entry.path};$null}
function Restore-CcodLegacySnapshotEntry {param($Entry);if($Entry-is[string]){return};if($Entry.kind-ceq'Registry'){if(Test-Path -LiteralPath $Entry.path){throw 'legacy registry replacement present'};New-Item -Path $Entry.path -Force|Out-Null;foreach($name in $Entry.values.Keys){$kind=[Enum]::Parse([Microsoft.Win32.RegistryValueKind],[string]$Entry.values[$name].kind);New-ItemProperty -LiteralPath $Entry.path -Name $name -Value $Entry.values[$name].value -PropertyType $kind -Force|Out-Null};return};if([IO.File]::Exists($Entry.path)-or[IO.Directory]::Exists($Entry.path)){throw 'legacy shortcut replacement present'};[IO.Directory]::CreateDirectory((Split-Path $Entry.path -Parent))|Out-Null;$bytes=[Convert]::FromBase64String([string]$Entry.bytesBase64);$stream=[IO.File]::Open($Entry.path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read);try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()};if((Get-CcodProductFileSha256 $Entry.path)-cne$Entry.sha256){throw 'legacy shortcut restore mismatch'}}
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
        [hashtable]$Adapters
    )
    if ($ExpectedAppId -cne $script:CcodProductAppId) {
        Throw-CcodProductRegistrationError 'CCOD_LEGACY_PRODUCT_REGISTRATION_INVALID' 'Legacy product migration requires the canonical AppId and a verified new registration.' $ExpectedAppId
    }
    $adapter = Get-CcodProductRegistrationAdapters $Adapters
    $verified=&$adapter.ReadVerifiedRegistration
    if($null-eq$verified-or$verified.verified-isnot[bool]-or-not$verified.verified){Throw-CcodProductRegistrationError 'CCOD_LEGACY_PRODUCT_REGISTRATION_INVALID' 'Legacy product migration requires a current three-record read-back proof.' $ExpectedAppId}
    $legacy = & $adapter.ReadLegacyRegistration $ExpectedAppId
    if($null-eq$legacy){return}
    if ($legacy.appId -isnot [string] -or [string]$legacy.appId -cne $ExpectedAppId -or
        $legacy.uninstallString -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$legacy.uninstallString) -or
        $null -eq $legacy.shortcutNames -or (@($legacy.shortcutNames) -join '|') -cne ($script:CcodLegacyShortcutNames -join '|')) {
        Throw-CcodProductRegistrationError 'CCOD_LEGACY_PRODUCT_REGISTRATION_INVALID' 'Legacy product entry or shortcut names do not match the exact migration allowlist.' $ExpectedAppId
    }
    $snapshot=&$adapter.ReadLegacySnapshot $ExpectedAppId
    if($null-eq$snapshot-or$snapshot.appId-cne$ExpectedAppId-or@($snapshot.entries).Count-ne9){Throw-CcodProductRegistrationError 'CCOD_LEGACY_PRODUCT_REGISTRATION_INVALID' 'Legacy snapshot is incomplete or ambiguous' $ExpectedAppId}
    $removed=[Collections.Generic.List[object]]::new()
    try{foreach($entry in @($snapshot.entries)){&$adapter.RemoveLegacyEntry $entry;$removed.Add($entry)}}catch{$unresolved=[Collections.Generic.List[string]]::new();for($index=$removed.Count-1;$index-ge0;$index--){$entry=$removed[$index];$name=if($entry-is[string]){[string]$entry}elseif($entry.kind-ceq'Registry'){'Registry'}else{[string]$entry.name};try{if($null-ne(&$adapter.ReadLegacyEntry $entry)){$unresolved.Add($name);continue};&$adapter.RestoreLegacyEntry $entry;if($null-eq(&$adapter.ReadLegacyEntry $entry)){$unresolved.Add($name)}}catch{$unresolved.Add($name)}};if($unresolved.Count-gt0){$record=[pscustomobject][ordered]@{schemaVersion=1;appId=$ExpectedAppId;state='CompensationFailed';entries=@($unresolved);createdAtUtc=[DateTime]::UtcNow.ToString('o',[Globalization.CultureInfo]::InvariantCulture)};try{&$adapter.WriteLegacyCompensationFailure $record}catch{Throw-CcodProductRegistrationError 'CCOD_LEGACY_PRODUCT_COMPENSATION_FAILED' 'Legacy compensation failure record could not be persisted.' $record};Throw-CcodProductRegistrationError 'CCOD_LEGACY_PRODUCT_COMPENSATION_FAILED' 'Legacy migration compensation remains unresolved; exact entries were recorded.' $record};Throw-CcodProductRegistrationError 'CCOD_LEGACY_PRODUCT_REGISTRATION_INVALID' 'Legacy product migration failed and the exact prior set was restored.' $ExpectedAppId}
}

Export-ModuleMember -Function New-CcodProductRegistration,Test-CcodProductRegistration,Commit-CcodProductRegistration,Remove-CcodProductRegistration,Remove-CcodLegacyProductRegistration
