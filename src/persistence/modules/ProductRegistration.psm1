Set-StrictMode -Version Latest

$script:CcodProductVersion = '2.5.22'
$script:CcodProductAppId = '{2B9E9F2E-7A32-4A7E-9C1D-9F5B5C6D7E8F}'
$script:CcodProductKeyName = 'CodexRemote-fix'
$script:CcodProductFields = @(
    'schemaVersion','installRoot','runtimeId','version','packageSha256','runtimeRoot','bootstrapPath','uninstallerPath',
    'productKeyName','startMenuShortcut','desktopShortcut'
)
$script:CcodShortcutFields = @('kind','leaf','relativePath','candidatePath','bootstrapPath','installRoot')
$script:CcodReadyFields = @('phase','runtimeId','version','packageSha256','bootstrapPath','uninstallerPath')
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
    return $Proof.phase -is [string] -and [string]$Proof.phase -ceq 'Ready' -and
        $Proof.runtimeId -is [string] -and [string]$Proof.runtimeId -ceq [string]$Registration.runtimeId -and
        $Proof.version -is [string] -and [string]$Proof.version -ceq [string]$Registration.version -and
        $Proof.packageSha256 -is [string] -and [string]$Proof.packageSha256 -ceq [string]$Registration.packageSha256 -and
        $Proof.bootstrapPath -is [string] -and [string]$Proof.bootstrapPath -ceq [string]$Registration.bootstrapPath -and
        $Proof.uninstallerPath -is [string] -and [string]$Proof.uninstallerPath -ceq [string]$Registration.uninstallerPath
}

function Get-CcodProductRegistrationAdapters {
    param([hashtable]$Adapters)
    $defaults = @{
        GetReadyProof = { param($Registration) Throw-CcodProductRegistrationError 'CCOD_PRODUCT_REGISTRATION_NOT_READY' 'No independently verified Ready proof was supplied.' $Registration.runtimeId }
        WriteProductRegistration = { param($Registration) Write-CcodCurrentUserProductRegistration $Registration }
        ReadProductRegistration = { param($Registration) Read-CcodCurrentUserProductRegistration $Registration }
        WriteShortcut = { param($Kind,$Shortcut,$FileTransaction) Write-CcodCurrentUserProductShortcut -Kind $Kind -Shortcut $Shortcut -FileTransaction $FileTransaction }
        ReadShortcut = { param($Kind,$Shortcut) Read-CcodCurrentUserProductShortcut -Kind $Kind -Shortcut $Shortcut }
        ReadLegacyRegistration = { param($ExpectedAppId) Read-CcodCurrentUserLegacyRegistration -ExpectedAppId $ExpectedAppId }
        ReadVerifiedRegistration = { Read-CcodCurrentUserVerifiedRegistration }
        RemoveLegacyRegistration = { param($ExpectedAppId,$ExpectedShortcutNames) Remove-CcodCurrentUserLegacyRegistration -ExpectedAppId $ExpectedAppId -ExpectedShortcutNames $ExpectedShortcutNames }
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
    param($Registration)
    $path=Get-CcodProductRegistryPath;$command=Get-CcodProductUninstallCommand $Registration
    New-Item -Path $path -Force -ErrorAction Stop|Out-Null
    $values=[ordered]@{DisplayName='CodexRemote-fix';DisplayVersion=[string]$Registration.version;Publisher='naipi11';InstallLocation=[string]$Registration.runtimeRoot;UninstallString=$command;QuietUninstallString=($command+' -Confirm:$false');NoModify=1;NoRepair=1;CcodRuntimeId=[string]$Registration.runtimeId;CcodPackageSha256=[string]$Registration.packageSha256}
    foreach($name in $values.Keys){$type=if($name-in@('NoModify','NoRepair')){'DWord'}else{'String'};New-ItemProperty -LiteralPath $path -Name $name -Value $values[$name] -PropertyType $type -Force -ErrorAction Stop|Out-Null}
}
function Read-CcodCurrentUserProductRegistration {
    param($Registration)
    try{$value=Get-ItemProperty -LiteralPath (Get-CcodProductRegistryPath) -ErrorAction Stop}catch{return $null}
    $command=Get-CcodProductUninstallCommand $Registration
    if($value.DisplayName-cne'CodexRemote-fix'-or$value.DisplayVersion-cne$Registration.version-or$value.Publisher-cne'naipi11'-or$value.InstallLocation-cne$Registration.runtimeRoot-or$value.UninstallString-cne$command-or$value.QuietUninstallString-cne($command+' -Confirm:$false')-or[int]$value.NoModify-ne1-or[int]$value.NoRepair-ne1-or$value.CcodRuntimeId-cne$Registration.runtimeId-or$value.CcodPackageSha256-cne$Registration.packageSha256){return $null}
    $Registration
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
    param([string]$Kind,$Shortcut,$FileTransaction)
    $source=[IO.Path]::GetFullPath([string]$Shortcut.candidatePath);$runtime=[IO.Path]::GetFullPath((Split-Path (Split-Path $source -Parent) -Parent));if(-not$source.StartsWith($runtime.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)-or-not[IO.File]::Exists($source)){throw 'shortcut candidate missing'}
    $item=Get-Item -LiteralPath $source -Force -ErrorAction Stop;if($item.PSIsContainer-or($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){throw 'shortcut candidate unsafe'}
    Import-Module (Join-Path $PSScriptRoot 'InstallFileTransaction.psm1') -ErrorAction Stop
    $folder=Open-CcodInstallProductSpecialFolder -FileTransaction $FileTransaction -Kind $Kind
    Copy-CcodInstallProductShortcut -Folder $folder -Kind $Kind -SourcePath $source -Leaf 'CodexRemote-fix.lnk' -ExpectedLength ([int64]$item.Length) -ExpectedSha256 (Get-CcodProductFileSha256 $source) -FileTransaction $FileTransaction|Out-Null
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
        & $adapter.WriteProductRegistration $Registration
        & $adapter.WriteShortcut 'StartMenu' $Registration.startMenuShortcut $FileTransaction
        & $adapter.WriteShortcut 'Desktop' $Registration.desktopShortcut $FileTransaction
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
    try { & $adapter.RemoveLegacyRegistration $ExpectedAppId @($script:CcodLegacyShortcutNames) }
    catch { Throw-CcodProductRegistrationError 'CCOD_LEGACY_PRODUCT_REGISTRATION_INVALID' 'Legacy product migration failed without authorizing broader deletion.' $ExpectedAppId }
}

Export-ModuleMember -Function New-CcodProductRegistration,Test-CcodProductRegistration,Commit-CcodProductRegistration,Remove-CcodLegacyProductRegistration
