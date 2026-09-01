Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'PersistenceIO.psm1')
Import-Module (Join-Path $PSScriptRoot 'LifecycleEpoch.psm1') -Force

function Throw-CcodRuntimeError {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Message,
        $Target
    )

    throw [System.Management.Automation.ErrorRecord]::new(
        [InvalidOperationException]::new($Message),
        $Id,
        [System.Management.Automation.ErrorCategory]::InvalidData,
        $Target
    )
}

function Get-CcodErrorId {
    param([Parameter(Mandatory)]$ErrorRecord)

    return ([string]$ErrorRecord.FullyQualifiedErrorId -split ',')[0]
}

function Assert-CcodRuntimeId {
    param([Parameter(Mandatory)][string]$RuntimeId)

    if ($RuntimeId -notmatch '^[A-Za-z0-9._-]{1,96}$') {
        Throw-CcodRuntimeError 'CCOD_RUNTIME_ID_INVALID' 'Runtime ID must be a safe relative directory name' $RuntimeId
    }
    return $RuntimeId
}

function Get-CcodRuntimeAdapters {
    param([hashtable]$Adapters)

    $resolved = @{
        UtcNow = { [DateTime]::UtcNow }
        GetSelectorRootItem = { param($Path) Get-Item -LiteralPath $Path -Force -ErrorAction Stop }
        AssertLifecycleFence = {
            param($InstallRoot, $Ownership, $ExpectActivePointer, $NewRuntimeId)
            if ([bool]$ExpectActivePointer) {
                $selected=$null;try{$selected=Read-CcodActiveRuntime -InstallRoot $InstallRoot}catch{Throw-CcodRuntimeError 'CCOD_RUNTIME_FENCE_STALE' 'Expected active selector disappeared during lifecycle mutation' $InstallRoot}
                if($null-eq$selected-or$selected.activeRuntime-cne$Ownership.runtimeId-or[uint64]$selected.generation-ne[uint64]$Ownership.runtimeGeneration){Throw-CcodRuntimeError 'CCOD_RUNTIME_FENCE_STALE' 'Append-only selected runtime does not match lifecycle ownership' $Ownership}
                return Assert-CcodLifecycleFence -InstallRoot $InstallRoot -Ownership $Ownership
            }
            try{$unexpected=Read-CcodActiveRuntime -InstallRoot $InstallRoot}catch{if((Get-CcodErrorId $_)-notin@('CCOD_STATE_MISSING','CCOD_PATH_MISSING')){throw};$unexpected=$null}
            if ($null-ne$unexpected-or[IO.Directory]::Exists((Join-Path $InstallRoot 'state\active-generation'))-or[IO.File]::Exists((Join-Path $InstallRoot 'active.json'))) { Throw-CcodRuntimeError 'CCOD_RUNTIME_FENCE_STALE' 'Unexpected active selector appeared during lifecycle initialization' $InstallRoot }
            if ([UInt64]$Ownership.runtimeGeneration -ne 1 -or [string]$Ownership.runtimeId -cne [string]$NewRuntimeId) {
                Throw-CcodRuntimeError 'CCOD_RUNTIME_FENCE_STALE' 'Initial active pointer requires generation-one ownership of the new runtime' $Ownership
            }
            $virtualPointer = [pscustomobject][ordered]@{
                schemaVersion=2; activeRuntime=[string]$Ownership.runtimeId; previousRuntime=$null
                generation=[UInt64]$Ownership.runtimeGeneration; updatedAtUtc='1970-01-01T00:00:00.0000000Z'
            }
            $readVirtualPointer = { param($Root) $virtualPointer }.GetNewClosure()
            return Assert-CcodLifecycleFence -InstallRoot $InstallRoot -Ownership $Ownership -Adapters @{ ReadActiveRuntime=$readVirtualPointer }
        }
    }
    if ($null -ne $Adapters) {
        foreach ($name in $Adapters.Keys) {
            $resolved[$name] = $Adapters[$name]
        }
    }
    return $resolved
}

function ConvertTo-CcodRuntimeGeneration {
    param([Parameter(Mandatory)]$Value, [Parameter(Mandatory)][string]$Path)

    if ($Value -is [decimal]) {
        if ($Value -lt 1 -or [decimal]::Truncate($Value) -ne $Value) {
            Throw-CcodRuntimeError 'CCOD_RUNTIME_GENERATION_INVALID' 'Active runtime generation must be a positive unsigned integer' $Path
        }
        try { return [UInt64]$Value } catch { Throw-CcodRuntimeError 'CCOD_RUNTIME_GENERATION_INVALID' 'Active runtime generation is outside the unsigned 64-bit range' $Path }
    }
    if ($Value -isnot [byte] -and $Value -isnot [uint16] -and $Value -isnot [uint32] -and $Value -isnot [uint64] -and
        $Value -isnot [int16] -and $Value -isnot [int32] -and $Value -isnot [int64] -or $Value -lt 1) {
        Throw-CcodRuntimeError 'CCOD_RUNTIME_GENERATION_INVALID' 'Active runtime generation must be a positive unsigned integer' $Path
    }
    return [UInt64]$Value
}

function Get-CcodRuntimeRoot {
    param([Parameter(Mandatory)][string]$RuntimeDirectory)

    $root = [IO.Path]::GetFullPath($RuntimeDirectory)
    if (-not [IO.Directory]::Exists($root)) {
        return $null
    }

    $item = Get-Item -LiteralPath $root -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        Throw-CcodRuntimeError 'CCOD_REPARSE_PATH' 'Runtime root is a reparse point' $root
    }
    return $root
}

function Get-CcodRuntimeFileSha256 {
    param([Parameter(Mandatory)][string]$Path)

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $stream = [IO.File]::OpenRead([IO.Path]::GetFullPath($Path))
        try {
            return [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '').ToLowerInvariant()
        } finally {
            $stream.Dispose()
        }
    } finally {
        $sha.Dispose()
    }
}

function ConvertTo-CcodRuntimeRelativePath {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$FullName
    )

    $rootPrefix = $Root.TrimEnd('\') + '\'
    if (-not $FullName.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        Throw-CcodRuntimeError 'CCOD_PATH_OUTSIDE_ROOT' 'Runtime file is outside its runtime root' $FullName
    }
    return $FullName.Substring($rootPrefix.Length).Replace('\', '/')
}

function Assert-CcodManifestRelativePath {
    param([Parameter(Mandatory)][string]$Path)

    if ([IO.Path]::IsPathRooted($Path) -or
        $Path.StartsWith('/') -or
        $Path.IndexOf('\') -ge 0 -or
        $Path -match '(^|/)(\.|\.\.)(/|$)' -or
        $Path.Contains('//')) {
        Throw-CcodRuntimeError 'CCOD_PATH_OUTSIDE_ROOT' 'Manifest file path is not a safe relative path' $Path
    }
    return $Path
}

function Get-CcodRuntimeFileRecords {
    param([Parameter(Mandatory)][string]$RuntimeDirectory)

    $root = Get-CcodRuntimeRoot -RuntimeDirectory $RuntimeDirectory
    if ($null -eq $root) {
        Throw-CcodRuntimeError 'CCOD_RUNTIME_MISSING' 'Runtime directory does not exist' $RuntimeDirectory
    }

    $records = [System.Collections.Generic.List[object]]::new()
    foreach ($item in Get-ChildItem -LiteralPath $root -Force -Recurse -ErrorAction Stop) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            Throw-CcodRuntimeError 'CCOD_REPARSE_PATH' 'Runtime contains a reparse point' $item.FullName
        }
        if (-not $item.PSIsContainer) {
            $relative = ConvertTo-CcodRuntimeRelativePath -Root $root -FullName $item.FullName
            if (-not $relative.Equals('manifest.json', [StringComparison]::OrdinalIgnoreCase)) {
                $records.Add([pscustomobject]@{
                    path = $relative
                    length = [int64]$item.Length
                    sha256 = Get-CcodRuntimeFileSha256 -Path $item.FullName
                })
            }
        }
    }

    $comparison = [System.Comparison[object]]{
        param($left, $right)
        return [StringComparer]::Ordinal.Compare([string]$left.path, [string]$right.path)
    }
    $records.Sort($comparison)
    return $records.ToArray()
}

function Get-CcodRuntimeId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectVersion,
        [Parameter(Mandatory)][object[]]$Files,
        [string]$Nonce = ([guid]::NewGuid().ToString('N'))
    )

    if($ProjectVersion-cnotmatch'^[A-Za-z0-9][A-Za-z0-9._-]{0,45}$'-or$Nonce-cnotmatch'^[0-9a-f]{32}$'){
        Throw-CcodRuntimeError 'CCOD_RUNTIME_ID_INVALID' 'Runtime identity components are invalid' $ProjectVersion
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($file in $Files) {
        $lines.Add(('{0}`t{1}`t{2}' -f [string]$file.path, [int64]$file.length, [string]$file.sha256))
    }
    $canonical = $lines -join "`n"
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $digest = [BitConverter]::ToString($sha256.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonical))).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha256.Dispose()
    }
    return Assert-CcodRuntimeId -RuntimeId ('{0}-{1}-{2}' -f $ProjectVersion, $digest.Substring(0, 16), $Nonce)
}

function Test-CcodRuntimeIdBinding {
    param([Parameter(Mandatory)][string]$RuntimeId,[Parameter(Mandatory)][string]$ProjectVersion,[Parameter(Mandatory)][object[]]$Files)
    if($RuntimeId-cnotmatch'^(?<version>[A-Za-z0-9][A-Za-z0-9._-]{0,45})-(?<digest>[0-9a-f]{16})-(?<nonce>[0-9a-f]{32})$'-or$Matches.version-cne$ProjectVersion){return $false}
    return (Get-CcodRuntimeId -ProjectVersion $ProjectVersion -Files $Files -Nonce $Matches.nonce)-ceq$RuntimeId
}

function New-CcodRuntimeManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RuntimeDirectory,
        [Parameter(Mandatory)][string]$ProjectVersion,
        [string]$RuntimeId
    )

    $files = @(Get-CcodRuntimeFileRecords -RuntimeDirectory $RuntimeDirectory)
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        projectVersion = $ProjectVersion
        runtimeId = if ([string]::IsNullOrWhiteSpace($RuntimeId)) { Get-CcodRuntimeId -ProjectVersion $ProjectVersion -Files $files } elseif(Test-CcodRuntimeIdBinding -RuntimeId (Assert-CcodRuntimeId $RuntimeId) -ProjectVersion $ProjectVersion -Files $files){$RuntimeId}else{Throw-CcodRuntimeError 'CCOD_RUNTIME_ID_MISMATCH' 'Runtime ID is not bound to the manifest file set and project version' $RuntimeId}
        files = $files
    }
}

function New-CcodRuntimeValidationResult {
    param(
        [bool]$Valid,
        [Parameter(Mandatory)][string]$Code,
        [string]$RuntimeId,
        $Manifest
    )

    return [pscustomobject]@{
        Valid = $Valid
        Code = $Code
        RuntimeId = $RuntimeId
        Manifest = $Manifest
    }
}

function Test-CcodRuntimeManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RuntimeDirectory,
        [Parameter(Mandatory)][string]$ExpectedRuntimeId,
        [string]$ExpectedManifestSha256
    )

    Assert-CcodRuntimeId -RuntimeId $ExpectedRuntimeId | Out-Null
    $root = Get-CcodRuntimeRoot -RuntimeDirectory $RuntimeDirectory
    if ($null -eq $root) {
        return New-CcodRuntimeValidationResult -Valid $false -Code 'CCOD_RUNTIME_MISSING' -RuntimeId $ExpectedRuntimeId -Manifest $null
    }

    $manifestPath = Resolve-CcodContainedPath -Root $root -RelativePath 'manifest.json' -AllowMissingLeaf
    if (-not [IO.File]::Exists($manifestPath)) {
        return New-CcodRuntimeValidationResult -Valid $false -Code 'CCOD_RUNTIME_MANIFEST_MISSING' -RuntimeId $ExpectedRuntimeId -Manifest $null
    }
    if(-not[string]::IsNullOrWhiteSpace($ExpectedManifestSha256)){
        if($ExpectedManifestSha256-cnotmatch'^[0-9a-f]{64}$'-or(Get-CcodRuntimeFileSha256 -Path $manifestPath)-cne$ExpectedManifestSha256){return New-CcodRuntimeValidationResult -Valid $false -Code 'CCOD_RUNTIME_MANIFEST_HASH_MISMATCH' -RuntimeId $ExpectedRuntimeId -Manifest $null}
    }

    try {
        $manifest = Read-CcodStrictJson -Path $manifestPath -ExpectedSchema 1 -Kind 'runtime manifest'
    } catch {
        return New-CcodRuntimeValidationResult -Valid $false -Code (Get-CcodErrorId -ErrorRecord $_) -RuntimeId $ExpectedRuntimeId -Manifest $null
    }

    $runtimeIdProperty = $manifest.PSObject.Properties['runtimeId']
    $projectVersionProperty = $manifest.PSObject.Properties['projectVersion']
    $filesProperty = $manifest.PSObject.Properties['files']
    if ($null -eq $runtimeIdProperty -or $null -eq $projectVersionProperty -or $null -eq $filesProperty -or
        $runtimeIdProperty.Value -isnot [string] -or $projectVersionProperty.Value -isnot [string] -or $null -eq $filesProperty.Value) {
        return New-CcodRuntimeValidationResult -Valid $false -Code 'CCOD_RUNTIME_MANIFEST_INVALID' -RuntimeId $ExpectedRuntimeId -Manifest $manifest
    }

    $manifestRuntimeId = [string]$runtimeIdProperty.Value
    if ($manifestRuntimeId -notmatch '^[A-Za-z0-9._-]{1,96}$' -or $manifestRuntimeId -cne $ExpectedRuntimeId) {
        return New-CcodRuntimeValidationResult -Valid $false -Code 'CCOD_RUNTIME_ID_MISMATCH' -RuntimeId $manifestRuntimeId -Manifest $manifest
    }

    $manifestFiles = @($filesProperty.Value)
    $previousPath = $null
    $manifestRecords = [System.Collections.Generic.List[object]]::new()
    foreach ($file in $manifestFiles) {
        if ($file -isnot [pscustomobject] -or
            $null -eq $file.PSObject.Properties['path'] -or
            $null -eq $file.PSObject.Properties['length'] -or
            $null -eq $file.PSObject.Properties['sha256'] -or
            $file.path -isnot [string] -or
            $file.sha256 -isnot [string]) {
            return New-CcodRuntimeValidationResult -Valid $false -Code 'CCOD_RUNTIME_MANIFEST_INVALID' -RuntimeId $manifestRuntimeId -Manifest $manifest
        }

        Assert-CcodManifestRelativePath -Path $file.path | Out-Null
        if ($file.path.Equals('manifest.json', [StringComparison]::OrdinalIgnoreCase) -or
            $file.sha256 -cnotmatch '^[0-9a-f]{64}$') {
            return New-CcodRuntimeValidationResult -Valid $false -Code 'CCOD_RUNTIME_MANIFEST_INVALID' -RuntimeId $manifestRuntimeId -Manifest $manifest
        }
        try {
            $length = [Convert]::ToInt64($file.length, [Globalization.CultureInfo]::InvariantCulture)
        } catch {
            return New-CcodRuntimeValidationResult -Valid $false -Code 'CCOD_RUNTIME_MANIFEST_INVALID' -RuntimeId $manifestRuntimeId -Manifest $manifest
        }
        if ($length -lt 0 -or ($null -ne $previousPath -and [StringComparer]::Ordinal.Compare($previousPath, [string]$file.path) -ge 0)) {
            return New-CcodRuntimeValidationResult -Valid $false -Code 'CCOD_RUNTIME_MANIFEST_INVALID' -RuntimeId $manifestRuntimeId -Manifest $manifest
        }
        $previousPath = [string]$file.path
        $manifestRecords.Add([pscustomobject]@{ path = [string]$file.path; length = $length; sha256 = [string]$file.sha256 })
    }

    $actualFiles = @(Get-CcodRuntimeFileRecords -RuntimeDirectory $root)
    if ($manifestRecords.Count -ne $actualFiles.Count) {
        return New-CcodRuntimeValidationResult -Valid $false -Code 'CCOD_RUNTIME_FILE_SET_MISMATCH' -RuntimeId $manifestRuntimeId -Manifest $manifest
    }
    for ($index = 0; $index -lt $actualFiles.Count; $index++) {
        $expected = $manifestRecords[$index]
        $actual = $actualFiles[$index]
        if ($expected.path -cne $actual.path) {
            return New-CcodRuntimeValidationResult -Valid $false -Code 'CCOD_RUNTIME_FILE_SET_MISMATCH' -RuntimeId $manifestRuntimeId -Manifest $manifest
        }
        if ($expected.length -ne $actual.length) {
            return New-CcodRuntimeValidationResult -Valid $false -Code 'CCOD_RUNTIME_FILE_LENGTH_MISMATCH' -RuntimeId $manifestRuntimeId -Manifest $manifest
        }
        if ($expected.sha256 -cne $actual.sha256) {
            return New-CcodRuntimeValidationResult -Valid $false -Code 'CCOD_RUNTIME_FILE_HASH_MISMATCH' -RuntimeId $manifestRuntimeId -Manifest $manifest
        }
    }

    if(-not(Test-CcodRuntimeIdBinding -RuntimeId $manifestRuntimeId -ProjectVersion ([string]$projectVersionProperty.Value) -Files $actualFiles)){
        return New-CcodRuntimeValidationResult -Valid $false -Code 'CCOD_RUNTIME_ID_MISMATCH' -RuntimeId $manifestRuntimeId -Manifest $manifest
    }
    return New-CcodRuntimeValidationResult -Valid $true -Code 'CCOD_RUNTIME_VALID' -RuntimeId $manifestRuntimeId -Manifest $manifest
}

function Get-CcodRuntimeDirectoryForId {
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$RuntimeId
    )

    Assert-CcodRuntimeId -RuntimeId $RuntimeId | Out-Null
    return Resolve-CcodContainedPath -Root $InstallRoot -RelativePath (Join-Path 'runtime' $RuntimeId) -AllowMissingLeaf
}

function Assert-CcodRuntimePointerFile {
    param([Parameter(Mandatory)][string]$Path)
    try{
        $item=Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if($item.PSIsContainer-or($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){throw 'not plain'}
        $streams=@(Get-Item -LiteralPath $Path -Stream * -ErrorAction Stop);if($streams.Count-ne1-or[string]$streams[0].Stream-cne':$DATA'){throw 'stream'}
        if($null-eq('CcodRuntimePointerIdentity' -as[type])){Add-Type -TypeDefinition @'
using System; using System.ComponentModel; using System.IO; using System.Runtime.InteropServices; using Microsoft.Win32.SafeHandles;
public static class CcodRuntimePointerIdentity { [StructLayout(LayoutKind.Sequential)] struct Info { public uint A; public System.Runtime.InteropServices.ComTypes.FILETIME C,X,W; public uint V,H,L,N,Ih,Il; } [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetFileInformationByHandle(SafeFileHandle h,out Info i); public static uint Links(string p){using(FileStream s=new FileStream(p,FileMode.Open,FileAccess.Read,FileShare.Read)){Info i;if(!GetFileInformationByHandle(s.SafeFileHandle,out i))throw new Win32Exception(Marshal.GetLastWin32Error());return i.N;}} }
'@}
        if([CcodRuntimePointerIdentity]::Links($Path)-ne1){throw 'links'}
    }catch{Throw-CcodRuntimeError 'CCOD_RUNTIME_POINTER_INVALID' 'Active generation selector is not a plain single-link file' $Path}
}

function Read-CcodActiveRuntime {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$InstallRoot,[hashtable]$Adapters)

    $pointerRoot = Resolve-CcodContainedPath -Root $InstallRoot -RelativePath 'state\active-generation' -AllowMissingLeaf
    $selectorRootItem=$null;$selectorRootAbsent=$false;$selectorRootReader=if($null-ne$Adapters-and$Adapters.ContainsKey('GetSelectorRootItem')){$Adapters.GetSelectorRootItem}else{{param($Path)Get-Item -LiteralPath $Path -Force -ErrorAction Stop}}
    try{$selectorRootItem=&$selectorRootReader $pointerRoot;if($null-eq$selectorRootItem){throw [IO.InvalidDataException]::new('selector lookup returned no proof')}}catch [Management.Automation.ItemNotFoundException]{$selectorRootAbsent=$true}catch{Throw-CcodRuntimeError 'CCOD_RUNTIME_POINTER_INVALID' 'Active generation selector root lookup failed' $pointerRoot}
    if (-not$selectorRootAbsent) {
        if(-not$selectorRootItem.PSIsContainer-or($selectorRootItem.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){Throw-CcodRuntimeError 'CCOD_RUNTIME_POINTER_INVALID' 'Active generation selector root is not a plain directory' $pointerRoot}
        $entries=@(Get-ChildItem -LiteralPath $pointerRoot -Force -ErrorAction Stop)
        if($entries.Count-eq 0){Throw-CcodRuntimeError 'CCOD_RUNTIME_POINTER_INVALID' 'Active generation store is empty' $pointerRoot}
        $records=[Collections.Generic.List[object]]::new()
        foreach($entry in $entries){
            if($entry.PSIsContainer-or($entry.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0-or$entry.Name-cnotmatch'^\d{20}\.json$'){Throw-CcodRuntimeError 'CCOD_RUNTIME_POINTER_INVALID' 'Active generation store contains an unknown object' $entry.FullName}
            Assert-CcodRuntimePointerFile -Path $entry.FullName
            $record=Read-CcodStrictJson -Path $entry.FullName -ExpectedSchema 1 -Kind 'active generation'
            $names=@($record.PSObject.Properties.Name);if(($names-join',')-cne'schemaVersion,generation,activeRuntime,previousGeneration'-or$record.activeRuntime-isnot[string]){Throw-CcodRuntimeError 'CCOD_RUNTIME_POINTER_INVALID' 'Active generation record fields are invalid' $entry.FullName}
            $generation=ConvertTo-CcodRuntimeGeneration $record.generation $entry.FullName
            $integerTypes=@([byte],[uint16],[uint32],[uint64],[int16],[int32],[int64]);$typed=$false;foreach($t in $integerTypes){if($record.previousGeneration-is$t){$typed=$true;break}};if(-not$typed){Throw-CcodRuntimeError 'CCOD_RUNTIME_POINTER_INVALID' 'Previous generation is not an integer' $entry.FullName}
            [uint64]$previous=$record.previousGeneration;if($generation-ne($previous+1)-or$entry.Name-cne('{0:D20}.json'-f$generation)){Throw-CcodRuntimeError 'CCOD_RUNTIME_POINTER_INVALID' 'Active generation record is not canonical' $entry.FullName}
            Assert-CcodRuntimeId $record.activeRuntime|Out-Null;$records.Add([pscustomobject]@{generation=$generation;previousGeneration=$previous;activeRuntime=[string]$record.activeRuntime})
        }
        $ordered=@($records|Sort-Object generation);for($i=0;$i-lt$ordered.Count;$i++){if([uint64]$ordered[$i].generation-ne[uint64]($i+1)-or[uint64]$ordered[$i].previousGeneration-ne[uint64]$i){Throw-CcodRuntimeError 'CCOD_RUNTIME_POINTER_INVALID' 'Active generation chain has a gap' $pointerRoot}}
        $latest=$ordered[-1];$previousRuntime=if($latest.previousGeneration-gt0){[string]$ordered[[int]$latest.previousGeneration-1].activeRuntime}else{$null}
        return [pscustomobject][ordered]@{schemaVersion=2;activeRuntime=$latest.activeRuntime;previousRuntime=$previousRuntime;generation=[uint64]$latest.generation;updatedAtUtc=$selectorRootItem.LastWriteTimeUtc.ToString('o')}
    }
    $path = Resolve-CcodContainedPath -Root $InstallRoot -RelativePath 'active.json' -AllowMissingLeaf
    $active = $null
    $legacy = $false
    try {
        $active = Read-CcodStrictJson -Path $path -ExpectedSchema 2 -Kind 'active runtime'
    } catch {
        if ((Get-CcodErrorId -ErrorRecord $_) -cne 'CCOD_SCHEMA_UNSUPPORTED') { throw }
        $active = Read-CcodStrictJson -Path $path -ExpectedSchema 1 -Kind 'active runtime'
        $legacy = $true
    }
    $expected = if ($legacy) { @('schemaVersion', 'activeRuntime', 'previousRuntime', 'updatedAtUtc') } else { @('schemaVersion', 'activeRuntime', 'previousRuntime', 'generation', 'updatedAtUtc') }
    $actual = @($active.PSObject.Properties.Name)
    if ($actual.Count -ne $expected.Count -or ($actual -join "`0") -cne ($expected -join "`0")) {
        Throw-CcodRuntimeError 'CCOD_RUNTIME_POINTER_INVALID' 'Active runtime pointer has unexpected fields' $path
    }
    foreach ($name in @('activeRuntime', 'previousRuntime', 'updatedAtUtc')) {
        if ($null -eq $active.PSObject.Properties[$name]) {
            Throw-CcodRuntimeError 'CCOD_RUNTIME_POINTER_INVALID' "Active runtime pointer is missing $name" $path
        }
    }
    if ($active.activeRuntime -isnot [string]) {
        Throw-CcodRuntimeError 'CCOD_RUNTIME_ID_INVALID' 'Active runtime ID must be a string' $path
    }
    Assert-CcodRuntimeId -RuntimeId $active.activeRuntime | Out-Null
    if ($null -ne $active.previousRuntime) {
        if ($active.previousRuntime -isnot [string]) {
            Throw-CcodRuntimeError 'CCOD_RUNTIME_ID_INVALID' 'Previous runtime ID must be null or a string' $path
        }
        Assert-CcodRuntimeId -RuntimeId $active.previousRuntime | Out-Null
    }
    if ($legacy) {
        return [pscustomobject][ordered]@{ schemaVersion=2; activeRuntime=$active.activeRuntime; previousRuntime=$active.previousRuntime; generation=[UInt64]1; updatedAtUtc=$active.updatedAtUtc }
    }
    $generation = ConvertTo-CcodRuntimeGeneration -Value $active.generation -Path $path
    return [pscustomobject][ordered]@{ schemaVersion=2; activeRuntime=$active.activeRuntime; previousRuntime=$active.previousRuntime; generation=$generation; updatedAtUtc=$active.updatedAtUtc }
}

function Resolve-CcodActiveRuntimeContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$ExpectedRuntimeId,
        [Parameter(Mandatory)][UInt64]$ExpectedGeneration,
        [Parameter(Mandatory)][string]$ExpectedScriptPath,
        [Parameter(Mandatory)][string]$ScriptRelativePath
    )
    try {
        $root=[IO.Path]::GetFullPath($InstallRoot)
        if(-not [IO.Path]::IsPathRooted($InstallRoot) -or $root -cne $InstallRoot -or $ExpectedGeneration -eq 0){throw 'input'}
        Assert-CcodRuntimeId $ExpectedRuntimeId|Out-Null
        $relative=Assert-CcodManifestRelativePath $ScriptRelativePath
        $active=Read-CcodActiveRuntime -InstallRoot $root
        if($active.activeRuntime -cne $ExpectedRuntimeId -or [UInt64]$active.generation -ne $ExpectedGeneration){throw 'active mismatch'}
        $runtimeRoot=Get-CcodRuntimeDirectoryForId -InstallRoot $root -RuntimeId $ExpectedRuntimeId
        $validation=Test-CcodRuntimeManifest -RuntimeDirectory $runtimeRoot -ExpectedRuntimeId $ExpectedRuntimeId
        if(-not $validation.Valid){throw 'manifest'}
        $scriptPath=[IO.Path]::GetFullPath((Join-Path $runtimeRoot $relative.Replace('/','\')))
        $expected=[IO.Path]::GetFullPath($ExpectedScriptPath)
        if(-not [IO.Path]::IsPathRooted($ExpectedScriptPath) -or $expected -cne $ExpectedScriptPath -or $expected -cne $scriptPath -or -not [IO.File]::Exists($scriptPath)){throw 'script'}
        $records=@($validation.Manifest.files|Where-Object{$_.path -ceq $relative})
        if($records.Count -ne 1){throw 'manifest script'}
        return [pscustomobject][ordered]@{
            InstallRoot=$root;RuntimeRoot=$runtimeRoot;RuntimeId=$ExpectedRuntimeId;RuntimeGeneration=[UInt64]$ExpectedGeneration
            ScriptPath=$scriptPath;Manifest=$validation.Manifest
        }
    } catch {
        Throw-CcodRuntimeError 'CCOD_RUNTIME_UNAUTHORIZED' 'The requested worker is not the exact active manifest runtime and generation' $ExpectedScriptPath
    }
}

function Set-CcodActiveRuntime {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [string]$NewRuntimeId,
        $TargetGeneration,
        $FileTransaction,
        $Ownership,
        [hashtable]$Adapters
    )

    $Adapters = Get-CcodRuntimeAdapters -Adapters $Adapters
    if ($null -eq $Ownership) {
        Throw-CcodRuntimeError 'CCOD_RUNTIME_FENCE_REQUIRED' 'Active runtime mutation requires proven lifecycle ownership' $InstallRoot
    }
    if($null-ne$FileTransaction-or$null-ne$TargetGeneration){
        if($null-eq(Get-Command Commit-CcodInstallActivePointer -ErrorAction SilentlyContinue)){Import-Module (Join-Path $PSScriptRoot 'InstallFileTransaction.psm1') -ErrorAction Stop}
        if($null-eq$FileTransaction-or$null-eq$TargetGeneration){Throw-CcodRuntimeError 'CCOD_RUNTIME_POINTER_INVALID' 'Pointer commit requires target and transaction' $InstallRoot}
        $current=$null;try{$current=Read-CcodActiveRuntime -InstallRoot $InstallRoot -Adapters @{GetSelectorRootItem=$Adapters.GetSelectorRootItem}}catch{if((Get-CcodErrorId $_)-notin@('CCOD_STATE_MISSING','CCOD_PATH_MISSING')){throw}}
        [uint64]$previous=if($null-eq$current){0}else{$current.generation}
        try{[void](& $Adapters.AssertLifecycleFence $InstallRoot $Ownership ($null-ne$current) $NewRuntimeId)}catch{Throw-CcodRuntimeError 'CCOD_RUNTIME_FENCE_STALE' 'Active runtime mutation lifecycle fence is stale' $InstallRoot}
        $committed=Commit-CcodInstallActivePointer -InstallRoot $InstallRoot -TargetGeneration $TargetGeneration -ExpectedPreviousGeneration $previous -FileTransaction $FileTransaction
        return Read-CcodActiveRuntime -InstallRoot $InstallRoot
    }
    Assert-CcodRuntimeId -RuntimeId $NewRuntimeId | Out-Null
    $runtimeDirectory = Get-CcodRuntimeDirectoryForId -InstallRoot $InstallRoot -RuntimeId $NewRuntimeId
    $validation = Test-CcodRuntimeManifest -RuntimeDirectory $runtimeDirectory -ExpectedRuntimeId $NewRuntimeId
    if (-not $validation.Valid) {
        Throw-CcodRuntimeError $validation.Code 'New active runtime did not pass manifest validation' $runtimeDirectory
    }

    $activePath = Resolve-CcodContainedPath -Root $InstallRoot -RelativePath 'active.json' -AllowMissingLeaf
    $expectActivePointer = [IO.File]::Exists($activePath)
    try { [void](& $Adapters.AssertLifecycleFence $InstallRoot $Ownership $expectActivePointer $NewRuntimeId) }
    catch { Throw-CcodRuntimeError 'CCOD_RUNTIME_FENCE_STALE' 'Active runtime mutation lifecycle fence is stale before pointer read' $InstallRoot }
    $previousRuntime = $null
    [UInt64]$currentGeneration = 0
    if ($expectActivePointer) {
        $current = Read-CcodActiveRuntime -InstallRoot $InstallRoot
        $currentGeneration = [UInt64]$current.generation
        if ($current.activeRuntime -cne $NewRuntimeId) {
            $previousRuntime = [string]$current.activeRuntime
        } elseif ($null -ne $current.previousRuntime -and $current.previousRuntime -cne $NewRuntimeId) {
            $previousRuntime = [string]$current.previousRuntime
        }
    }
    if ($currentGeneration -eq [UInt64]::MaxValue) {
        Throw-CcodRuntimeError 'CCOD_RUNTIME_GENERATION_EXHAUSTED' 'Active runtime generation cannot wrap' $activePath
    }
    try { [void](& $Adapters.AssertLifecycleFence $InstallRoot $Ownership $expectActivePointer $NewRuntimeId) }
    catch { Throw-CcodRuntimeError 'CCOD_RUNTIME_FENCE_STALE' 'Active runtime mutation lifecycle fence is stale before pointer commit' $InstallRoot }
    $pointer = [ordered]@{
        schemaVersion = 2
        activeRuntime = $NewRuntimeId
        previousRuntime = $previousRuntime
        generation = [UInt64]($currentGeneration + 1)
        updatedAtUtc = (& $Adapters.UtcNow).ToUniversalTime().ToString('o')
    }
    Write-CcodAtomicJson -Path $activePath -Value $pointer
    return [pscustomobject]$pointer
}

Export-ModuleMember -Function Get-CcodRuntimeId, New-CcodRuntimeManifest, Test-CcodRuntimeManifest, Read-CcodActiveRuntime, Resolve-CcodActiveRuntimeContext, Set-CcodActiveRuntime
