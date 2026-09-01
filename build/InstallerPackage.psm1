Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:CcodInstallerPackageMaximumBytes = 536870912
$script:CcodInstallerPackageManifestMaximumBytes = 4194304
$script:CcodInstallerPackageEntryMaximumBytes = 268435456

function Throw-CcodInstallerPackageError {
    param([Parameter(Mandatory)][string]$Id,[Parameter(Mandatory)][string]$Message,$Target)
    throw [Management.Automation.ErrorRecord]::new(
        [IO.InvalidDataException]::new($Message),
        $Id,
        [Management.Automation.ErrorCategory]::InvalidData,
        $Target
    )
}

function Get-CcodInstallerPackageSha256 {
    param([Parameter(Mandatory)][string]$Path)
    $stream = $null
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $stream = [IO.File]::Open([IO.Path]::GetFullPath($Path),[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        return [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','').ToLowerInvariant()
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
        $sha.Dispose()
    }
}

function Get-CcodInstallerPackageStreamSha256 {
    param([Parameter(Mandatory)][IO.Stream]$Stream)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $Stream.Position = 0
        $value = [BitConverter]::ToString($sha.ComputeHash($Stream)).Replace('-','').ToLowerInvariant()
        $Stream.Position = 0
        return $value
    } finally { $sha.Dispose() }
}

function Test-CcodInstallerPackageRelativePath {
    param([AllowNull()][string]$Path)
    return $Path -is [string] -and $Path -cmatch '^[A-Za-z0-9][A-Za-z0-9._/-]{0,255}$' -and
        -not $Path.Contains('//') -and -not $Path.Contains('..') -and -not $Path.Contains(':') -and
        -not $Path.Contains('\') -and -not $Path.EndsWith('/')
}

function Get-CcodInstallerPackageTopLevelJsonPropertyCount {
    param([Parameter(Mandatory)][string]$Json,[Parameter(Mandatory)][string]$Name)
    $count=0;$depth=0;$inString=$false;$escaped=$false;$expectKey=$false;$captureKey=$false;$keyStart=-1
    for($index=0;$index-lt$Json.Length;$index++){
        $character=$Json[$index]
        if($inString){
            if($escaped){$escaped=$false;continue}
            if($character-ceq'\'){$escaped=$true;continue}
            if($character-ceq'"'){
                if($captureKey){
                    try{$key=$Json.Substring($keyStart,$index-$keyStart+1)|ConvertFrom-Json -ErrorAction Stop}catch{return -1}
                    if($key-isnot[string]){return -1};if($key-ceq$Name){$count++};$expectKey=$false
                }
                $inString=$false;$captureKey=$false
            }
            continue
        }
        if($character-ceq'"'){$inString=$true;$captureKey=($depth-eq 1-and$expectKey);if($captureKey){$keyStart=$index};continue}
        if($character-ceq'{'-or$character-ceq'['){$depth++;if($depth-eq 1-and$character-ceq'{'){$expectKey=$true};continue}
        if($character-ceq'}'-or$character-ceq']'){$depth--;if($depth-lt 0){return -1};continue}
        if($character-ceq','-and$depth-eq 1){$expectKey=$true}
    }
    if($inString-or$depth-ne 0){return -1};return $count
}

function Assert-CcodInstallerPackageRegularFile {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Kind,[int64]$MaximumBytes = 536870912)
    $full = [IO.Path]::GetFullPath($Path)
    if (-not [IO.File]::Exists($full)) { Throw-CcodInstallerPackageError 'CCOD_INSTALLER_PACKAGE_INVALID' "$Kind is missing" $full }
    $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $item.Length -le 0 -or $item.Length -gt $MaximumBytes) {
        Throw-CcodInstallerPackageError 'CCOD_INSTALLER_PACKAGE_INVALID' "$Kind is not a bounded regular file" $full
    }
    return $full
}

function Read-CcodInstallerPayloadManifest {
    param([Parameter(Mandatory)][byte[]]$Bytes,[Parameter(Mandatory)][string]$ExpectedVersion)
    try { $text=[Text.UTF8Encoding]::new($false,$true).GetString($Bytes);$manifest=$text|ConvertFrom-Json -ErrorAction Stop }
    catch { Throw-CcodInstallerPackageError 'CCOD_INSTALLER_PACKAGE_INVALID' 'Payload manifest JSON is invalid' $null }
    foreach($name in @('schemaVersion','projectVersion','files')){if((Get-CcodInstallerPackageTopLevelJsonPropertyCount $text $name)-ne 1){Throw-CcodInstallerPackageError 'CCOD_INSTALLER_PACKAGE_INVALID' 'Payload manifest contains duplicate or missing fields' $name}}
    if($manifest-isnot[pscustomobject]-or(@($manifest.PSObject.Properties.Name)-join',')-cne'schemaVersion,projectVersion,files'-or
       $manifest.schemaVersion-isnot[int]-or$manifest.schemaVersion-ne 1-or$manifest.projectVersion-isnot[string]-or$manifest.projectVersion-cne$ExpectedVersion){
        Throw-CcodInstallerPackageError 'CCOD_INSTALLER_PACKAGE_INVALID' 'Payload manifest metadata is invalid' $null
    }
    $records=@($manifest.files);if($records.Count-eq 0){Throw-CcodInstallerPackageError 'CCOD_INSTALLER_PACKAGE_INVALID' 'Payload manifest is empty' $null}
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase);$previous=$null
    foreach($record in $records){
        if($record-isnot[pscustomobject]-or(@($record.PSObject.Properties.Name)-join',')-cne'path,length,sha256'-or
           -not(Test-CcodInstallerPackageRelativePath ([string]$record.path))-or
           $record.length-isnot[ValueType]-or[decimal]$record.length-ne[decimal][int64]$record.length-or[int64]$record.length-lt 0-or[int64]$record.length-gt$script:CcodInstallerPackageEntryMaximumBytes-or
           $record.sha256-isnot[string]-or$record.sha256-cnotmatch'^[0-9a-f]{64}$'-or
           ($null-ne$previous-and[StringComparer]::Ordinal.Compare($previous,[string]$record.path)-ge 0)-or-not$seen.Add([string]$record.path)){
            Throw-CcodInstallerPackageError 'CCOD_INSTALLER_PACKAGE_INVALID' 'Payload manifest file record is invalid' $record
        }
        $previous=[string]$record.path
    }
    return [pscustomobject]@{Text=$text;Manifest=$manifest;Records=$records}
}

function Read-CcodInstallerPackageManifest {
    param([Parameter(Mandatory)][byte[]]$Bytes,[Parameter(Mandatory)][string]$ExpectedVersion,[Parameter(Mandatory)][string]$ExpectedGitCommit)
    try{$text=[Text.UTF8Encoding]::new($false,$true).GetString($Bytes);$manifest=$text|ConvertFrom-Json -ErrorAction Stop}catch{Throw-CcodInstallerPackageError 'CCOD_INSTALLER_PACKAGE_INVALID' 'Installer package manifest JSON is invalid' $null}
    foreach($name in @('schemaVersion','product','version','gitCommit','payloadManifest','files')){if((Get-CcodInstallerPackageTopLevelJsonPropertyCount $text $name)-ne 1){Throw-CcodInstallerPackageError 'CCOD_INSTALLER_PACKAGE_INVALID' 'Installer package manifest contains duplicate or missing fields' $name}}
    if($manifest-isnot[pscustomobject]-or(@($manifest.PSObject.Properties.Name)-join',')-cne'schemaVersion,product,version,gitCommit,payloadManifest,files'-or
       $manifest.schemaVersion-isnot[int]-or$manifest.schemaVersion-ne 1-or$manifest.product-isnot[string]-or$manifest.product-cne'CodexRemote-fix'-or
       $manifest.version-isnot[string]-or$manifest.version-cne$ExpectedVersion-or$manifest.gitCommit-isnot[string]-or$manifest.gitCommit-cne$ExpectedGitCommit-or
       $manifest.payloadManifest-isnot[pscustomobject]-or(@($manifest.payloadManifest.PSObject.Properties.Name)-join',')-cne'name,length,sha256'-or
       $manifest.payloadManifest.name-isnot[string]-or$manifest.payloadManifest.name-cne'installer-payload.manifest.json'-or
       $manifest.payloadManifest.length-isnot[ValueType]-or[decimal]$manifest.payloadManifest.length-ne[decimal][int64]$manifest.payloadManifest.length-or[int64]$manifest.payloadManifest.length-le 0-or[int64]$manifest.payloadManifest.length-gt$script:CcodInstallerPackageManifestMaximumBytes-or
       $manifest.payloadManifest.sha256-isnot[string]-or$manifest.payloadManifest.sha256-cnotmatch'^[0-9a-f]{64}$'){
        Throw-CcodInstallerPackageError 'CCOD_INSTALLER_PACKAGE_INVALID' 'Installer package manifest metadata is invalid' $null
    }
    return [pscustomobject]@{Text=$text;Manifest=$manifest;Records=@($manifest.files)}
}

function Assert-CcodInstallerPackageFileRecords {
    param([Parameter(Mandatory)]$Records)
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase);$previous=$null
    foreach($record in @($Records)){
        if($record-isnot[pscustomobject]-or(@($record.PSObject.Properties.Name)-join',')-cne'path,length,sha256'-or-not(Test-CcodInstallerPackageRelativePath ([string]$record.path))-or
           $record.length-isnot[ValueType]-or[decimal]$record.length-ne[decimal][int64]$record.length-or[int64]$record.length-lt 0-or[int64]$record.length-gt$script:CcodInstallerPackageEntryMaximumBytes-or
           $record.sha256-isnot[string]-or$record.sha256-cnotmatch'^[0-9a-f]{64}$'-or($null-ne$previous-and[StringComparer]::Ordinal.Compare($previous,[string]$record.path)-ge 0)-or-not$seen.Add([string]$record.path)){
            Throw-CcodInstallerPackageError 'CCOD_INSTALLER_PACKAGE_INVALID' 'Installer package file record is invalid' $record
        };$previous=[string]$record.path
    }
    if($seen.Count-eq 0){Throw-CcodInstallerPackageError 'CCOD_INSTALLER_PACKAGE_INVALID' 'Installer package file list is empty' $null}
    return [pscustomobject]@{Set=$seen;Count=$seen.Count}
}

function Open-CcodInstallerPackageSeal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PackagePath,[Parameter(Mandatory)][string]$ManifestPath,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$ExpectedPackageSha256,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$ExpectedManifestSha256,
        [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$ExpectedVersion,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$ExpectedGitCommit
    )
    Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
    $package=Assert-CcodInstallerPackageRegularFile $PackagePath 'Installer package' $script:CcodInstallerPackageMaximumBytes
    $manifestPathFull=Assert-CcodInstallerPackageRegularFile $ManifestPath 'Installer package manifest' $script:CcodInstallerPackageManifestMaximumBytes
    $packageStream=$null;$manifestStream=$null;$archive=$null
    try{
        $packageStream=[IO.File]::Open($package,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        if((Get-CcodInstallerPackageStreamSha256 $packageStream)-cne$ExpectedPackageSha256){Throw-CcodInstallerPackageError 'CCOD_INSTALLER_PACKAGE_HASH_MISMATCH' 'Installer package hash mismatch' $package}
        $manifestStream=[IO.File]::Open($manifestPathFull,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        if((Get-CcodInstallerPackageStreamSha256 $manifestStream)-cne$ExpectedManifestSha256){Throw-CcodInstallerPackageError 'CCOD_INSTALLER_PACKAGE_MANIFEST_HASH_MISMATCH' 'Installer package manifest hash mismatch' $manifestPathFull}
        $manifestBytes=New-Object byte[] ([int]$manifestStream.Length);$manifestStream.Position=0;$read=$manifestStream.Read($manifestBytes,0,$manifestBytes.Length);if($read-ne$manifestBytes.Length){Throw-CcodInstallerPackageError 'CCOD_INSTALLER_PACKAGE_INVALID' 'Installer package manifest read was incomplete' $manifestPathFull}
        $manifestResult=Read-CcodInstallerPackageManifest -Bytes $manifestBytes -ExpectedVersion $ExpectedVersion -ExpectedGitCommit $ExpectedGitCommit
        $expectedResult=Assert-CcodInstallerPackageFileRecords -Records $manifestResult.Records
        $expected=$expectedResult.Set
        $archive=[IO.Compression.ZipArchive]::new($packageStream,[IO.Compression.ZipArchiveMode]::Read,$true)
        $entries=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach($entry in @($archive.Entries)){
            $name=[string]$entry.FullName
            if(-not(Test-CcodInstallerPackageRelativePath $name)-or$entries.ContainsKey($name)-or$entry.Name.Length-eq 0-or$entry.Length-lt 0-or$entry.Length-gt$script:CcodInstallerPackageEntryMaximumBytes){Throw-CcodInstallerPackageError 'CCOD_INSTALLER_PACKAGE_INVALID' 'Installer package entry set is unsafe or duplicate' $name}
            $entries.Add($name,$entry)
        }
        if($entries.Count-ne($expected.Count+1)-or-not$entries.ContainsKey('installer-payload.manifest.json')){Throw-CcodInstallerPackageError 'CCOD_INSTALLER_PACKAGE_INVALID' 'Installer package entry set differs from its manifest' $package}
        foreach($path in $expected){if(-not$entries.ContainsKey($path)){Throw-CcodInstallerPackageError 'CCOD_INSTALLER_PACKAGE_INVALID' 'Installer package entry is missing' $path}}
        $payloadEntry=$entries['installer-payload.manifest.json'];$payloadBytes=New-Object byte[] ([int]$payloadEntry.Length);$entryStream=$payloadEntry.Open();try{$offset=0;while($offset-lt$payloadBytes.Length){$count=$entryStream.Read($payloadBytes,$offset,$payloadBytes.Length-$offset);if($count-le 0){break};$offset+=$count};if($offset-ne$payloadBytes.Length){Throw-CcodInstallerPackageError 'CCOD_INSTALLER_PACKAGE_INVALID' 'Payload manifest entry read was incomplete' $null}}finally{$entryStream.Dispose()}
        $payloadSha=[Security.Cryptography.SHA256]::Create();try{$payloadHash=[BitConverter]::ToString($payloadSha.ComputeHash($payloadBytes)).Replace('-','').ToLowerInvariant()}finally{$payloadSha.Dispose()}
        if([int64]$payloadBytes.Length-ne[int64]$manifestResult.Manifest.payloadManifest.length-or$payloadHash-cne[string]$manifestResult.Manifest.payloadManifest.sha256){Throw-CcodInstallerPackageError 'CCOD_INSTALLER_PACKAGE_INVALID' 'Embedded payload manifest binding is invalid' $null}
        $payloadResult=Read-CcodInstallerPayloadManifest -Bytes $payloadBytes -ExpectedVersion $ExpectedVersion
        if(@($payloadResult.Records).Count-ne@($manifestResult.Records).Count){Throw-CcodInstallerPackageError 'CCOD_INSTALLER_PACKAGE_INVALID' 'Payload and package manifests differ' $null}
        for($i=0;$i-lt@($payloadResult.Records).Count;$i++){if(($payloadResult.Records[$i]|ConvertTo-Json -Compress)-cne($manifestResult.Records[$i]|ConvertTo-Json -Compress)){Throw-CcodInstallerPackageError 'CCOD_INSTALLER_PACKAGE_INVALID' 'Payload and package file records differ' $null}}
        foreach($record in @($manifestResult.Records)){$entry=$entries[[string]$record.path];if([int64]$entry.Length-ne[int64]$record.length){Throw-CcodInstallerPackageError 'CCOD_INSTALLER_PACKAGE_INVALID' 'Installer package entry length mismatch' $record.path};$s=$entry.Open();$sha=[Security.Cryptography.SHA256]::Create();try{$hash=[BitConverter]::ToString($sha.ComputeHash($s)).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose();$s.Dispose()};if($hash-cne[string]$record.sha256){Throw-CcodInstallerPackageError 'CCOD_INSTALLER_PACKAGE_INVALID' 'Installer package entry hash mismatch' $record.path}}
        return [pscustomobject]@{Valid=$true;PackagePath=$package;ManifestPath=$manifestPathFull;PackageSha256=$ExpectedPackageSha256;ManifestSha256=$ExpectedManifestSha256;PayloadManifestSha256=$payloadHash;Manifest=$manifestResult.Manifest;PayloadManifestBytes=$payloadBytes;PackageStream=$packageStream;ManifestStream=$manifestStream;Archive=$archive;Entries=$entries}
    }catch{if($null-ne$archive){$archive.Dispose()};if($null-ne$manifestStream){$manifestStream.Dispose()};if($null-ne$packageStream){$packageStream.Dispose()};throw}
}

function Close-CcodInstallerPackageSeal { param($Seal) if($null-eq$Seal){return};foreach($name in @('Archive','ManifestStream','PackageStream')){try{$value=$Seal.$name;if($null-ne$value){$value.Dispose()}}catch{}} }

function Expand-CcodInstallerPackageSeal {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Seal,[Parameter(Mandatory)][string]$DestinationRoot)
    if($null-eq$Seal-or-not[bool]$Seal.Valid){Throw-CcodInstallerPackageError 'CCOD_INSTALLER_PACKAGE_INVALID' 'Installer package seal is invalid' $null}
    $destination=[IO.Path]::GetFullPath($DestinationRoot)
    if([IO.File]::Exists($destination)-or[IO.Directory]::Exists($destination)){Throw-CcodInstallerPackageError 'CCOD_INSTALLER_PACKAGE_INVALID' 'Package extraction destination already exists' $destination}
    [IO.Directory]::CreateDirectory($destination)|Out-Null
    try{
        $records=@($Seal.Manifest.files)+@([pscustomobject][ordered]@{path='installer-payload.manifest.json';length=[int64]$Seal.PayloadManifestBytes.Length;sha256=[string]$Seal.PayloadManifestSha256})
        foreach($record in $records){
            $relative=[string]$record.path;$target=[IO.Path]::GetFullPath((Join-Path $destination $relative.Replace('/','\')));$prefix=$destination.TrimEnd('\')+'\'
            if(-not$target.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){Throw-CcodInstallerPackageError 'CCOD_INSTALLER_PACKAGE_INVALID' 'Package extraction path escaped its destination' $relative}
            $parent=Split-Path $target -Parent;if(-not[IO.Directory]::Exists($parent)){[IO.Directory]::CreateDirectory($parent)|Out-Null}
            $entry=$Seal.Entries[$relative];$source=$entry.Open();$output=[IO.File]::Open($target,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
            try{$source.CopyTo($output);$output.Flush($true)}finally{$output.Dispose();$source.Dispose()}
            if([int64](Get-Item -LiteralPath $target -Force).Length-ne[int64]$record.length-or(Get-CcodInstallerPackageSha256 $target)-cne[string]$record.sha256){Throw-CcodInstallerPackageError 'CCOD_INSTALLER_PACKAGE_INVALID' 'Extracted package entry failed verification' $relative}
        }
        return $destination
    }catch{if([IO.Directory]::Exists($destination)){Remove-Item -LiteralPath $destination -Recurse -Force -ErrorAction SilentlyContinue};throw}
}

function Test-CcodInstallerPackage {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PackagePath,[Parameter(Mandatory)][string]$ManifestPath,[Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$ExpectedPackageSha256,[Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$ExpectedManifestSha256,[Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$ExpectedVersion,[Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$ExpectedGitCommit)
    $seal=$null;try{$seal=Open-CcodInstallerPackageSeal @PSBoundParameters;return [pscustomobject]@{Valid=$true;PackageSha256=$seal.PackageSha256;ManifestSha256=$seal.ManifestSha256;PayloadManifestSha256=$seal.PayloadManifestSha256;FileCount=@($seal.Manifest.files).Count}}finally{Close-CcodInstallerPackageSeal $seal}
}

function New-CcodInstallerPackage {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PayloadRoot,[Parameter(Mandatory)][string]$PayloadManifestPath,[Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version,[Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$GitCommit,[Parameter(Mandatory)][string]$OutputPath,[Parameter(Mandatory)][string]$ManifestOutputPath)
    Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    $root=[IO.Path]::GetFullPath($PayloadRoot).TrimEnd('\');if(-not[IO.Directory]::Exists($root)){Throw-CcodInstallerPackageError 'CCOD_INSTALLER_PACKAGE_INVALID' 'Payload root is missing' $root};$rootItem=Get-Item -LiteralPath $root -Force;if(($rootItem.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne 0){Throw-CcodInstallerPackageError 'CCOD_INSTALLER_PACKAGE_INVALID' 'Payload root is a reparse point' $root}
    $payloadManifest=Assert-CcodInstallerPackageRegularFile $PayloadManifestPath 'Payload manifest' $script:CcodInstallerPackageManifestMaximumBytes;$payloadBytes=[IO.File]::ReadAllBytes($payloadManifest);$payloadResult=Read-CcodInstallerPayloadManifest -Bytes $payloadBytes -ExpectedVersion $Version
    $records=@($payloadResult.Records);$actual=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($item in @(Get-ChildItem -LiteralPath $root -Force -Recurse)) { if(($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne 0){Throw-CcodInstallerPackageError 'CCOD_INSTALLER_PACKAGE_INVALID' 'Payload contains a reparse point' $item.FullName};if($item.PSIsContainer-or$item.FullName.Equals($payloadManifest,[StringComparison]::OrdinalIgnoreCase)){continue};$relative=$item.FullName.Substring($root.Length+1).Replace('\','/');[void]$actual.Add($relative) }
    if($actual.Count-ne$records.Count){Throw-CcodInstallerPackageError 'CCOD_INSTALLER_PACKAGE_INVALID' 'Payload file set differs from its manifest' $root}
    foreach($record in $records){$path=Join-Path $root ([string]$record.path).Replace('/','\');if(-not[IO.File]::Exists($path)-or-not$actual.Contains([string]$record.path)-or[int64](Get-Item -LiteralPath $path -Force).Length-ne[int64]$record.length-or(Get-CcodInstallerPackageSha256 $path)-cne[string]$record.sha256){Throw-CcodInstallerPackageError 'CCOD_INSTALLER_PACKAGE_INVALID' 'Payload file differs from its manifest' $record.path}}
    $payloadSha=[Security.Cryptography.SHA256]::Create();try{$payloadHash=[BitConverter]::ToString($payloadSha.ComputeHash($payloadBytes)).Replace('-','').ToLowerInvariant()}finally{$payloadSha.Dispose()}
    $packageManifest=[ordered]@{schemaVersion=1;product='CodexRemote-fix';version=$Version;gitCommit=$GitCommit;payloadManifest=[ordered]@{name='installer-payload.manifest.json';length=[int64]$payloadBytes.Length;sha256=$payloadHash};files=$records}
    $output=[IO.Path]::GetFullPath($OutputPath);$manifestOutput=[IO.Path]::GetFullPath($ManifestOutputPath);if(-not[IO.Path]::IsPathRooted($OutputPath)-or-not[IO.Path]::IsPathRooted($ManifestOutputPath)-or$output-eq$manifestOutput-or[IO.File]::Exists($output)-or[IO.Directory]::Exists($output)-or[IO.File]::Exists($manifestOutput)-or[IO.Directory]::Exists($manifestOutput)){Throw-CcodInstallerPackageError 'CCOD_INSTALLER_PACKAGE_INVALID' 'Package outputs must be distinct absent absolute paths' $output}
    foreach($parent in @((Split-Path $output -Parent),(Split-Path $manifestOutput -Parent))){if(-not[IO.Directory]::Exists($parent)){[IO.Directory]::CreateDirectory($parent)|Out-Null}}
    $tempPackage=Join-Path (Split-Path $output -Parent) ('.ccod.'+[guid]::NewGuid().ToString('N')+'.zip.tmp');$tempManifest=Join-Path (Split-Path $manifestOutput -Parent) ('.ccod.'+[guid]::NewGuid().ToString('N')+'.json.tmp')
    try{
        $archive=[IO.Compression.ZipFile]::Open($tempPackage,[IO.Compression.ZipArchiveMode]::Create);try{foreach($record in $records){$entry=$archive.CreateEntry([string]$record.path,[IO.Compression.CompressionLevel]::Optimal);$source=[IO.File]::OpenRead((Join-Path $root ([string]$record.path).Replace('/','\')));$dest=$entry.Open();try{$source.CopyTo($dest)}finally{$dest.Dispose();$source.Dispose()}};$entry=$archive.CreateEntry('installer-payload.manifest.json',[IO.Compression.CompressionLevel]::Optimal);$dest=$entry.Open();try{$dest.Write($payloadBytes,0,$payloadBytes.Length)}finally{$dest.Dispose()}}finally{$archive.Dispose()}
        [IO.File]::WriteAllText($tempManifest,(($packageManifest|ConvertTo-Json -Depth 8)+[Environment]::NewLine),[Text.UTF8Encoding]::new($false))
        $packageHash=Get-CcodInstallerPackageSha256 $tempPackage;$manifestHash=Get-CcodInstallerPackageSha256 $tempManifest
        Test-CcodInstallerPackage -PackagePath $tempPackage -ManifestPath $tempManifest -ExpectedPackageSha256 $packageHash -ExpectedManifestSha256 $manifestHash -ExpectedVersion $Version -ExpectedGitCommit $GitCommit|Out-Null
        [IO.File]::Move($tempPackage,$output);[IO.File]::Move($tempManifest,$manifestOutput)
        return [pscustomobject]@{PackagePath=$output;ManifestPath=$manifestOutput;PackageSha256=$packageHash;ManifestSha256=$manifestHash;PayloadManifestSha256=$payloadHash;FileCount=$records.Count}
    }catch{foreach($path in @($tempPackage,$tempManifest)){if([IO.File]::Exists($path)){[IO.File]::Delete($path)}};if([IO.File]::Exists($output)-and-not[IO.File]::Exists($manifestOutput)){[IO.File]::Delete($output)};throw}
}

Export-ModuleMember -Function New-CcodInstallerPackage,Test-CcodInstallerPackage,Open-CcodInstallerPackageSeal,Close-CcodInstallerPackageSeal,Expand-CcodInstallerPackageSeal,Get-CcodInstallerPackageSha256
