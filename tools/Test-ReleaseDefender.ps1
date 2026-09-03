[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Run')][string]$CandidatePath,
    [Parameter(Mandatory, ParameterSetName = 'Run')][string]$ChecksumPath,
    [Parameter(Mandatory, ParameterSetName = 'Run')][string]$ManifestPath,
    [Parameter(Mandatory, ParameterSetName = 'Run')][string]$Origin,
    [Parameter(ParameterSetName = 'Run')]$WorkflowArtifactIdentity,
    [Parameter(Mandatory, ParameterSetName = 'Run')][string]$ExpectedVersion,
    [Parameter(Mandatory, ParameterSetName = 'Run')][string]$ExpectedGitCommit,
    [Parameter(Mandatory, ParameterSetName = 'Run')][string]$EvidencePath,
    [Parameter(Mandatory, ParameterSetName = 'Library')][switch]$Library
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$assetContractPath = Join-Path $PSScriptRoot 'ReleaseAssetContract.psm1'
if (-not [IO.File]::Exists($assetContractPath)) { throw 'CCOD_RELEASE_ASSET_CONTRACT_MISSING' }
Import-Module $assetContractPath -Force -ErrorAction Stop

function Throw-CcodReleaseDefenderError {
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$Message, $Target)
    throw [Management.Automation.ErrorRecord]::new(
        [InvalidOperationException]::new($Message),
        $Id,
        [Management.Automation.ErrorCategory]::InvalidOperation,
        $Target
    )
}

function Get-CcodReleaseDefenderErrorId {
    param([Parameter(Mandatory)]$ErrorRecord)
    $id = [string]$ErrorRecord.FullyQualifiedErrorId
    if ([string]::IsNullOrWhiteSpace($id)) { return $null }
    return ($id -split ',')[0]
}

function Get-CcodReleaseDefenderHash {
    param([Parameter(Mandatory)][string]$Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $stream = [IO.File]::OpenRead($Path)
        try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
        finally { $stream.Dispose() }
    } finally { $sha.Dispose() }
}

function Test-CcodReleaseDefenderCanonicalUtc {
    param([AllowNull()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    $parsed = [datetime]::MinValue
    if (-not [datetime]::TryParse($Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) { return $false }
    return $parsed.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture) -ceq $Value
}

function Read-CcodReleaseDefenderJsonString {
    param([Parameter(Mandatory)][string]$Json, [Parameter(Mandatory)][int]$Offset)
    if ($Offset -ge $Json.Length -or $Json[$Offset] -ne [char]34) { return $null }
    $builder = [Text.StringBuilder]::new()
    [int]$index = $Offset + 1
    [bool]$hasEscapes = $false
    while ($index -lt $Json.Length) {
        $character = $Json[$index]
        if ($character -eq [char]34) {
            return [pscustomobject]@{ Value = $builder.ToString(); End = $index + 1; HasEscapes = $hasEscapes }
        }
        if ($character -eq [char]92) {
            $hasEscapes = $true
            if (($index + 1) -ge $Json.Length) { return $null }
            $null = $builder.Append($character)
            $index++
            $null = $builder.Append($Json[$index])
            $index++
            continue
        }
        if ([int][char]$character -lt 32) { return $null }
        $null = $builder.Append($character)
        $index++
    }
    return $null
}

function Skip-CcodReleaseDefenderJsonWhitespace {
    param([Parameter(Mandatory)][string]$Json, [Parameter(Mandatory)][int]$Offset)
    [int]$index = $Offset
    while ($index -lt $Json.Length -and [char]::IsWhiteSpace($Json[$index])) { $index++ }
    return $index
}

function Skip-CcodReleaseDefenderJsonValue {
    param([Parameter(Mandatory)][string]$Json, [Parameter(Mandatory)][int]$Offset)
    if ($Offset -ge $Json.Length) { return -1 }
    $character = $Json[$Offset]
    if ($character -eq [char]34) {
        $token = Read-CcodReleaseDefenderJsonString -Json $Json -Offset $Offset
        if ($null -eq $token) { return -1 }
        return [int]$token.End
    }
    if ($character -eq [char]123 -or $character -eq [char]91) {
        [int]$index = $Offset + 1
        [int]$depth = 1
        while ($index -lt $Json.Length -and $depth -gt 0) {
            $nested = $Json[$index]
            if ($nested -eq [char]34) {
                $token = Read-CcodReleaseDefenderJsonString -Json $Json -Offset $index
                if ($null -eq $token) { return -1 }
                $index = [int]$token.End
                continue
            }
            if ($nested -eq [char]123 -or $nested -eq [char]91) {
                $depth++
            } elseif ($nested -eq [char]125 -or $nested -eq [char]93) {
                $depth--
            }
            $index++
        }
        if ($depth -ne 0) { return -1 }
        return $index
    }
    [int]$primitiveStart = $Offset
    [int]$index = $Offset
    while ($index -lt $Json.Length) {
        $current = $Json[$index]
        if ($current -eq [char]44 -or $current -eq [char]125 -or $current -eq [char]93 -or [char]::IsWhiteSpace($current)) { break }
        $index++
    }
    if ($index -eq $primitiveStart) { return -1 }
    return $index
}

function Get-CcodReleaseDefenderRawJsonString {
    param(
        [Parameter(Mandatory)][string]$Json,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z][A-Za-z0-9]*$')][string]$PropertyName
    )
    [int]$index = Skip-CcodReleaseDefenderJsonWhitespace -Json $Json -Offset 0
    if ($index -ge $Json.Length -or $Json[$index] -ne [char]123) { return $null }
    $index++
    [bool]$found = $false
    $value = $null
    while ($true) {
        $index = Skip-CcodReleaseDefenderJsonWhitespace -Json $Json -Offset $index
        if ($index -ge $Json.Length) { return $null }
        if ($Json[$index] -eq [char]125) {
            $index++
            break
        }
        $key = Read-CcodReleaseDefenderJsonString -Json $Json -Offset $index
        if ($null -eq $key) { return $null }
        $index = [int]$key.End
        $index = Skip-CcodReleaseDefenderJsonWhitespace -Json $Json -Offset $index
        if ($index -ge $Json.Length -or $Json[$index] -ne [char]58) { return $null }
        $index++
        $index = Skip-CcodReleaseDefenderJsonWhitespace -Json $Json -Offset $index
        $isTarget = -not $key.HasEscapes -and $key.Value -ceq $PropertyName
        if ($isTarget) {
            if ($found) { return $null }
            $token = Read-CcodReleaseDefenderJsonString -Json $Json -Offset $index
            if ($null -eq $token -or $token.HasEscapes) { return $null }
            $value = $token.Value
            $found = $true
            $index = [int]$token.End
        } else {
            $index = Skip-CcodReleaseDefenderJsonValue -Json $Json -Offset $index
            if ($index -lt 0) { return $null }
        }
        $index = Skip-CcodReleaseDefenderJsonWhitespace -Json $Json -Offset $index
        if ($index -ge $Json.Length) { return $null }
        if ($Json[$index] -eq [char]44) {
            $index++
            continue
        }
        if ($Json[$index] -eq [char]125) {
            $index++
            break
        }
        return $null
    }
    $index = Skip-CcodReleaseDefenderJsonWhitespace -Json $Json -Offset $index
    if ($index -ne $Json.Length -or -not $found) { return $null }
    return $value
}

function Assert-CcodReleaseDefenderPlainAncestry {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$ErrorId,[switch]$AllowMissingLeaf)
    try {
        if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathRooted($Path)) { throw 'absolute' }
        $canonical = [IO.Path]::GetFullPath($Path)
        $root = [IO.Path]::GetPathRoot($canonical)
        $full = if ($canonical.Length -gt $root.Length) { $canonical.TrimEnd('\') } else { $canonical }
        $presented = if ($Path.Length -gt $root.Length) { $Path.TrimEnd('\') } else { $Path }
        if ($full -cne $presented -or $full.IndexOf(':',$full.IndexOf(':') + 1) -ge 0) { throw 'canonical' }
        $current = if ($AllowMissingLeaf) { Split-Path $full -Parent } else { $full }
        while (-not [string]::IsNullOrWhiteSpace($current)) {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'reparse' }
            if ($current.TrimEnd('\') -ceq $root.TrimEnd('\')) { break }
            $parent = [IO.Directory]::GetParent($current)
            if ($null -eq $parent) { break }
            $current = if ($parent.FullName.Length -gt $root.Length) { $parent.FullName.TrimEnd('\') } else { $parent.FullName }
        }
        return $full
    } catch {
        Throw-CcodReleaseDefenderError $ErrorId 'Path is missing, noncanonical, or has unsafe ancestry.' $Path
    }
}

function Assert-CcodReleaseDefenderRegularFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Kind)
    $full = Assert-CcodReleaseDefenderPlainAncestry -Path $Path -ErrorId 'CCOD_RELEASE_ASSET_INVALID'
    try { $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop }
    catch { Throw-CcodReleaseDefenderError 'CCOD_RELEASE_ASSET_INVALID' "$Kind is missing" $full }
    if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        Throw-CcodReleaseDefenderError 'CCOD_RELEASE_ASSET_INVALID' "$Kind must be a regular non-reparse file" $full
    }
    return $full
}

function Assert-CcodReleaseDefenderDirectory {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Kind)
    $full = Assert-CcodReleaseDefenderPlainAncestry -Path $Path -ErrorId 'CCOD_RELEASE_ASSET_INVALID'
    try { $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop }
    catch { Throw-CcodReleaseDefenderError 'CCOD_RELEASE_ASSET_INVALID' "$Kind is missing" $full }
    if (-not $item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        Throw-CcodReleaseDefenderError 'CCOD_RELEASE_ASSET_INVALID' "$Kind must be a non-reparse directory" $full
    }
    return $full
}

function Assert-CcodReleaseDefenderEvidenceTarget {
    param([Parameter(Mandatory)][string]$Path)
    $target = Assert-CcodReleaseDefenderPlainAncestry -Path $Path -ErrorId 'CCOD_DEFENDER_EVIDENCE_INVALID' -AllowMissingLeaf
    if ([IO.Path]::GetExtension($target) -cne '.json' -or [IO.File]::Exists($target) -or [IO.Directory]::Exists($target)) {
        Throw-CcodReleaseDefenderError 'CCOD_DEFENDER_EVIDENCE_INVALID' 'Defender evidence must be a new canonical JSON leaf.' $target
    }
    try {
        $existing = Get-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
        if ($null -ne $existing) { throw 'existing' }
    } catch { Throw-CcodReleaseDefenderError 'CCOD_DEFENDER_EVIDENCE_INVALID' 'Defender evidence target already exists or is unsafe.' $target }
    return $target
}

function Get-CcodReleaseDefenderDefaultAdapters {
    $defaults = @{}
    $defaults.GetFileSha256 = { param($Path) Get-CcodReleaseDefenderHash -Path $Path }
    $defaults.ReadText = { param($Path) [IO.File]::ReadAllText($Path) }
    $defaults.GetZoneId = {
        param($Path)
        try {
            $stream = Get-Item -LiteralPath $Path -Stream Zone.Identifier -ErrorAction Stop
            if ($null -eq $stream -or $stream.Length -le 0 -or $stream.Length -gt 65536) { return $null }
            $text = Get-Content -LiteralPath $Path -Stream Zone.Identifier -Raw -ErrorAction Stop
            $matches = [regex]::Matches([string]$text, '(?im)^[ \t]*ZoneId[ \t]*=[ \t]*([0-9]+)[ \t]*\r?$')
            $zone = 0
            if ($matches.Count -ne 1 -or -not [int]::TryParse($matches[0].Groups[1].Value,[ref]$zone)) { return $null }
            return $zone
        } catch { return $null }
    }
    $defaults.GetDefenderStatus = { Get-MpComputerStatus -ErrorAction Stop }
    $defaults.StartCustomScan = { param($Path) Start-MpScan -ScanType CustomScan -ScanPath $Path -ErrorAction Stop }
    $defaults.GetThreatDetections = { @(Get-MpThreatDetection -ErrorAction Stop) }
    $defaults.GetUtcNow = { [datetime]::UtcNow }
    $defaults.WriteReceipt = {
        param($Path, $Receipt)
        $target = Assert-CcodReleaseDefenderEvidenceTarget -Path $Path
        $parent = Split-Path $target -Parent
        $temporary = Join-Path $parent ('.ccod-defender-receipt-' + [guid]::NewGuid().ToString('N') + '.tmp')
        try {
            $bytes = [Text.UTF8Encoding]::new($false).GetBytes((($Receipt | ConvertTo-Json -Depth 12) + [Environment]::NewLine))
            $stream = [IO.File]::Open($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
            try { $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
            [void](Assert-CcodReleaseDefenderEvidenceTarget -Path $target)
            [IO.File]::Move($temporary, $target)
            return $target
        } finally {
            if ([IO.File]::Exists($temporary)) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
        }
    }
    return $defaults
}

function Resolve-CcodReleaseDefenderAdapters {
    param([hashtable]$Adapters)
    $resolved = Get-CcodReleaseDefenderDefaultAdapters
    if ($null -eq $Adapters) { return $resolved }
    foreach ($name in $Adapters.Keys) {
        if (-not $resolved.ContainsKey([string]$name) -or $Adapters[$name] -isnot [scriptblock]) {
            Throw-CcodReleaseDefenderError 'CCOD_DEFENDER_ADAPTER_INVALID' 'Defender test adapters must replace known scriptblock adapters only' $name
        }
        $resolved[[string]$name] = $Adapters[$name]
    }
    return $resolved
}

function Get-CcodReleaseDefenderChecksum {
    param([Parameter(Mandatory)][string]$CandidatePath, [Parameter(Mandatory)][string]$ChecksumPath, [Parameter(Mandatory)][hashtable]$Adapters)
    $candidate = Assert-CcodReleaseDefenderRegularFile -Path $CandidatePath -Kind 'Release candidate asset'
    $checksum = Assert-CcodReleaseDefenderRegularFile -Path $ChecksumPath -Kind 'Installer checksum'
    $text = & $Adapters.ReadText $checksum
    if ($text -isnot [string]) { Throw-CcodReleaseDefenderError 'CCOD_DEFENDER_CHECKSUM_INVALID' 'Installer checksum could not be read as text' $checksum }
    $match = [regex]::Match($text.TrimEnd("`r", "`n"), '^([0-9a-f]{64}) \*([^\r\n]+)$')
    if (-not $match.Success -or $match.Groups[2].Value -cne [IO.Path]::GetFileName($candidate)) {
        Throw-CcodReleaseDefenderError 'CCOD_DEFENDER_CHECKSUM_INVALID' 'Installer checksum is malformed or names a different asset' $checksum
    }
    $actual = [string](& $Adapters.GetFileSha256 $candidate)
    if ($actual -cnotmatch '^[0-9a-f]{64}$' -or $actual -cne $match.Groups[1].Value) {
        Throw-CcodReleaseDefenderError 'CCOD_DEFENDER_CHECKSUM_INVALID' 'Installer checksum does not match the exact bytes submitted for scanning' $candidate
    }
    return [pscustomobject][ordered]@{ CandidatePath = $candidate; ChecksumPath = $checksum; Sha256 = $actual }
}

function Get-CcodReleaseDefenderStreamHash {
    param([Parameter(Mandatory)][IO.Stream]$Stream)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Stream))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Test-CcodReleasePortablePayloadManifest {
    param(
        [Parameter(Mandatory)]$ReleaseManifest,
        [Parameter(Mandatory)][string]$ReleaseManifestRaw,
        [Parameter(Mandatory)][string]$ReleaseManifestFile,
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$ExpectedVersion
    )
    $manifestTimestamp = Get-CcodReleaseDefenderRawJsonString -Json $ReleaseManifestRaw -PropertyName 'buildTimestampUtc'
    $expectedFields = @('schemaVersion','product','version','gitCommit','buildTimestampUtc','distribution','assets')
    if (((($ReleaseManifest.PSObject.Properties.Name | Sort-Object) -join '|') -cne (($expectedFields | Sort-Object) -join '|')) -or
        ($ReleaseManifest.schemaVersion -isnot [int] -and $ReleaseManifest.schemaVersion -isnot [long]) -or [int]$ReleaseManifest.schemaVersion -ne 2 -or
        $ReleaseManifest.product -isnot [string] -or $ReleaseManifest.product -cne 'CodexRemote-fix' -or
        $ReleaseManifest.version -isnot [string] -or $ReleaseManifest.version -cne $ExpectedVersion -or
        $ReleaseManifest.gitCommit -isnot [string] -or $ReleaseManifest.gitCommit -cnotmatch '^[0-9a-f]{40}$' -or
        $ReleaseManifest.distribution -isnot [string] -or $ReleaseManifest.distribution -cne 'portable-zip' -or
        -not (Test-CcodReleaseDefenderCanonicalUtc $manifestTimestamp)) {
        Throw-CcodReleaseDefenderError 'CCOD_RELEASE_MANIFEST_INVALID' 'Portable release manifest metadata does not have the required canonical shape' $ReleaseManifestFile
    }
    $contractNames = @(Get-CcodExpectedReleaseAssetNames -Version $ExpectedVersion)
    $bundleName = $contractNames[0]
    $checksumName = $contractNames[1]
    $provenanceName = $contractNames[2]
    $payloadManifestName = $contractNames[3]
    $expectedNames = @($bundleName,$checksumName,$provenanceName,$payloadManifestName,'CodexRemote-fix.exe','CodexRemote-fix.exe.config')
    $assetHashes = @{}
    foreach ($asset in @($ReleaseManifest.assets)) {
        if ($null -eq $asset -or (($asset.PSObject.Properties.Name | Sort-Object) -join '|') -cne 'name|sha256' -or
            $asset.name -isnot [string] -or $asset.sha256 -isnot [string] -or $asset.name -cnotmatch '^[A-Za-z0-9._-]+$' -or
            $asset.sha256 -cnotmatch '^[0-9a-f]{64}$' -or $assetHashes.ContainsKey([string]$asset.name)) {
            Throw-CcodReleaseDefenderError 'CCOD_RELEASE_MANIFEST_INVALID' 'Portable release asset records are malformed or duplicate' $ReleaseManifestFile
        }
        $assetHashes[[string]$asset.name] = [string]$asset.sha256
    }
    if ($assetHashes.Count -ne $expectedNames.Count -or (($assetHashes.Keys | Sort-Object) -join '|') -cne (($expectedNames | Sort-Object) -join '|')) {
        Throw-CcodReleaseDefenderError 'CCOD_RELEASE_MANIFEST_INVALID' 'Portable release manifest does not bind the exact final asset set' $ReleaseManifestFile
    }
    foreach ($name in $expectedNames) {
        if ($name -ceq 'CodexRemote-fix.exe' -or $name -ceq 'CodexRemote-fix.exe.config') { continue }
        $assetPath = Assert-CcodReleaseDefenderRegularFile -Path (Join-Path $Directory $name) -Kind 'Portable release asset'
        if ((Get-CcodReleaseDefenderHash -Path $assetPath) -cne $assetHashes[$name]) {
            Throw-CcodReleaseDefenderError 'CCOD_RELEASE_ASSET_HASH_MISMATCH' 'Portable release asset bytes do not match the release manifest' $name
        }
    }
    $checksumText = [IO.File]::ReadAllText((Join-Path $Directory $checksumName)).TrimEnd([char]13,[char]10)
    if ($checksumText -cne ("{0} *{1}" -f $assetHashes[$bundleName],$bundleName)) {
        Throw-CcodReleaseDefenderError 'CCOD_RELEASE_MANIFEST_INVALID' 'Portable release checksum is not bound to the ZIP bytes' $checksumName
    }
    $provenanceRaw = [IO.File]::ReadAllText((Join-Path $Directory $provenanceName))
    try { $provenance = $provenanceRaw | ConvertFrom-Json -ErrorAction Stop }
    catch { Throw-CcodReleaseDefenderError 'CCOD_RELEASE_MANIFEST_INVALID' 'TrayHost provenance is not valid JSON' $provenanceName }
    $provenanceTimestamp = Get-CcodReleaseDefenderRawJsonString -Json $provenanceRaw -PropertyName 'buildTimestampUtc'
    if ($null -eq $provenance.PSObject.Properties['version'] -or $null -eq $provenance.PSObject.Properties['gitCommit'] -or
        $provenance.version -isnot [string] -or $provenance.version -cne $ExpectedVersion -or
        $provenance.gitCommit -isnot [string] -or $provenance.gitCommit -cne $ReleaseManifest.gitCommit -or
        -not (Test-CcodReleaseDefenderCanonicalUtc $provenanceTimestamp) -or $provenanceTimestamp -cne $manifestTimestamp) {
        Throw-CcodReleaseDefenderError 'CCOD_RELEASE_MANIFEST_INVALID' 'TrayHost provenance is not bound to the portable release version, source commit, and timestamp' $provenanceName
    }

    $payloadManifestPath = Join-Path $Directory $payloadManifestName
    $payloadRaw = [IO.File]::ReadAllText($payloadManifestPath)
    try { $payloadManifest = $payloadRaw | ConvertFrom-Json -ErrorAction Stop }
    catch { Throw-CcodReleaseDefenderError 'CCOD_RELEASE_MANIFEST_INVALID' 'Portable payload manifest is not valid JSON' $payloadManifestName }
    $payloadTimestamp = Get-CcodReleaseDefenderRawJsonString -Json $payloadRaw -PropertyName 'buildTimestampUtc'
    $payloadFields = @('schemaVersion','product','version','gitCommit','buildTimestampUtc','files')
    if (((($payloadManifest.PSObject.Properties.Name | Sort-Object) -join '|') -cne (($payloadFields | Sort-Object) -join '|')) -or
        ($payloadManifest.schemaVersion -isnot [int] -and $payloadManifest.schemaVersion -isnot [long]) -or [int]$payloadManifest.schemaVersion -ne 1 -or
        $payloadManifest.product -isnot [string] -or $payloadManifest.product -cne 'CodexRemote-fix' -or
        $payloadManifest.version -isnot [string] -or $payloadManifest.version -cne $ExpectedVersion -or
        $payloadManifest.gitCommit -isnot [string] -or $payloadManifest.gitCommit -cne $ReleaseManifest.gitCommit -or
        -not (Test-CcodReleaseDefenderCanonicalUtc $payloadTimestamp) -or $payloadTimestamp -cne $manifestTimestamp) {
        Throw-CcodReleaseDefenderError 'CCOD_RELEASE_MANIFEST_INVALID' 'Portable payload manifest metadata is not release-bound' $payloadManifestName
    }
    $expectedZipFiles = @{
        'CodexRemote-fix.exe'=$null
        'CodexRemote-fix.exe.config'=$null
        'Install-CodexRemote-fix.ps1'=$null
        'payload-manifest.json'=$null
    }
    $previousPath = $null
    foreach ($record in @($payloadManifest.files)) {
        if ($null -eq $record -or (($record.PSObject.Properties.Name | Sort-Object) -join '|') -cne 'length|path|sha256' -or
            $record.path -isnot [string] -or $record.path -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._/-]{0,255}$' -or
            $record.path.Contains('//') -or $record.path.Contains('..') -or $record.path.Contains(':') -or
            ($record.length -isnot [int] -and $record.length -isnot [long]) -or [int64]$record.length -lt 0 -or
            $record.sha256 -isnot [string] -or $record.sha256 -cnotmatch '^[0-9a-f]{64}$' -or
            ($null -ne $previousPath -and [StringComparer]::Ordinal.Compare($previousPath,[string]$record.path) -ge 0)) {
            Throw-CcodReleaseDefenderError 'CCOD_RELEASE_MANIFEST_INVALID' 'Portable payload file records are invalid, duplicate, or unordered' $payloadManifestName
        }
        $previousPath = [string]$record.path
        $entryName = 'payload/' + $record.path
        if ($expectedZipFiles.ContainsKey($entryName)) {
            Throw-CcodReleaseDefenderError 'CCOD_RELEASE_MANIFEST_INVALID' 'Portable payload manifest has duplicate ZIP entry names' $entryName
        }
        $expectedZipFiles[$entryName] = $record
    }
    if ($expectedZipFiles.Count -le 4) {
        Throw-CcodReleaseDefenderError 'CCOD_RELEASE_MANIFEST_INVALID' 'Portable payload manifest is empty' $payloadManifestName
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    $archive = $null
    try {
        $archive = [IO.Compression.ZipFile]::OpenRead((Join-Path $Directory $bundleName))
        $seen = @{}
        foreach ($entry in @($archive.Entries)) {
            $name = [string]$entry.FullName
            if ($name.Contains('\')) { $name = $name.Replace('\','/') }
            if ([string]::IsNullOrWhiteSpace($name) -or $name.Contains(':') -or $name -match '(^|/)\.\.?(?:/|$)') {
                Throw-CcodReleaseDefenderError 'CCOD_RELEASE_MANIFEST_INVALID' 'Portable ZIP contains an unsafe entry path' $name
            }
            if ($name.EndsWith('/')) {
                if ($name -cne 'payload/' -and -not $name.StartsWith('payload/',[StringComparison]::Ordinal)) {
                    Throw-CcodReleaseDefenderError 'CCOD_RELEASE_MANIFEST_INVALID' 'Portable ZIP contains an unexpected directory entry' $name
                }
                continue
            }
            if (-not $expectedZipFiles.ContainsKey($name) -or $seen.ContainsKey($name)) {
                Throw-CcodReleaseDefenderError 'CCOD_RELEASE_MANIFEST_INVALID' 'Portable ZIP file entries differ from the payload manifest' $name
            }
            $seen[$name] = $entry
        }
        if ($seen.Count -ne $expectedZipFiles.Count) {
            Throw-CcodReleaseDefenderError 'CCOD_RELEASE_MANIFEST_INVALID' 'Portable ZIP is missing an expected payload file' $bundleName
        }
        $manifestEntry = $seen['payload-manifest.json']
        $manifestStream = $null
        try {
            $manifestStream = $manifestEntry.Open()
            if ((Get-CcodReleaseDefenderStreamHash -Stream $manifestStream) -cne (Get-CcodReleaseDefenderHash -Path $payloadManifestPath)) {
                Throw-CcodReleaseDefenderError 'CCOD_RELEASE_ASSET_HASH_MISMATCH' 'Portable ZIP payload manifest differs from the separately released manifest.' $bundleName
            }
        } finally {
            if ($null -ne $manifestStream) { $manifestStream.Dispose() }
        }
        foreach ($rootEntryName in @('CodexRemote-fix.exe','CodexRemote-fix.exe.config')) {
            $rootEntry = $seen[$rootEntryName]
            $rootStream = $null
            try {
                $rootStream = $rootEntry.Open()
                if ((Get-CcodReleaseDefenderStreamHash -Stream $rootStream) -cne $assetHashes[$rootEntryName]) {
                    Throw-CcodReleaseDefenderError 'CCOD_RELEASE_ASSET_HASH_MISMATCH' 'Portable ZIP root launcher differs from the release manifest.' $rootEntryName
                }
            } finally {
                if ($null -ne $rootStream) { $rootStream.Dispose() }
            }
        }
        foreach ($entryName in @($expectedZipFiles.Keys | Where-Object { $_.StartsWith('payload/',[StringComparison]::Ordinal) })) {
            $record = $expectedZipFiles[$entryName]
            $entry = $seen[$entryName]
            if ([int64]$entry.Length -ne [int64]$record.length) {
                Throw-CcodReleaseDefenderError 'CCOD_RELEASE_ASSET_HASH_MISMATCH' 'Portable ZIP payload length differs from its manifest.' $entryName
            }
            $entryStream = $null
            try {
                $entryStream = $entry.Open()
                if ((Get-CcodReleaseDefenderStreamHash -Stream $entryStream) -cne [string]$record.sha256) {
                    Throw-CcodReleaseDefenderError 'CCOD_RELEASE_ASSET_HASH_MISMATCH' 'Portable ZIP payload hash differs from its manifest.' $entryName
                }
            } finally {
                if ($null -ne $entryStream) { $entryStream.Dispose() }
            }
        }
    } finally {
        if ($null -ne $archive) { $archive.Dispose() }
    }
    return [pscustomobject][ordered]@{
        Valid = $true
        Version = $ExpectedVersion
        GitCommit = [string]$ReleaseManifest.gitCommit
        BuildTimestampUtc = $manifestTimestamp
        InstallerSha256 = [string]$assetHashes[$bundleName]
        InstallerName = $bundleName
        Distribution = 'portable-zip'
    }
}

function Test-CcodReleaseAssetManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ManifestPath,
        [Parameter(Mandatory)][string]$AssetDirectory,
        [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$ExpectedVersion
    )
    $manifestFile = Assert-CcodReleaseDefenderRegularFile -Path $ManifestPath -Kind 'Release manifest'
    $directory = Assert-CcodReleaseDefenderDirectory -Path $AssetDirectory -Kind 'Release asset directory'
    $manifestRaw = [IO.File]::ReadAllText($manifestFile)
    try { $manifest = $manifestRaw | ConvertFrom-Json -ErrorAction Stop }
    catch { Throw-CcodReleaseDefenderError 'CCOD_RELEASE_MANIFEST_INVALID' 'Release manifest is not valid JSON' $manifestFile }
    if (($manifest.schemaVersion -is [int] -or $manifest.schemaVersion -is [long]) -and [int]$manifest.schemaVersion -eq 2) {
        return Test-CcodReleasePortablePayloadManifest -ReleaseManifest $manifest -ReleaseManifestRaw $manifestRaw -ReleaseManifestFile $manifestFile -Directory $directory -ExpectedVersion $ExpectedVersion
    }
    $manifestTimestamp = Get-CcodReleaseDefenderRawJsonString -Json $manifestRaw -PropertyName 'buildTimestampUtc'
    $expectedFields = @('schemaVersion','product','version','gitCommit','buildTimestampUtc','assets')
    if ($null -eq $manifest -or (($manifest.PSObject.Properties.Name | Sort-Object) -join '|') -cne (($expectedFields | Sort-Object) -join '|') -or
        ($manifest.schemaVersion -isnot [int] -and $manifest.schemaVersion -isnot [long]) -or [int]$manifest.schemaVersion -ne 1 -or
        $manifest.product -isnot [string] -or $manifest.product -cne 'CodexRemote-fix' -or
        $manifest.version -isnot [string] -or $manifest.version -cne $ExpectedVersion -or
        $manifest.gitCommit -isnot [string] -or $manifest.gitCommit -cnotmatch '^[0-9a-f]{40}$' -or
        ($manifest.buildTimestampUtc -isnot [string] -and $manifest.buildTimestampUtc -isnot [datetime]) -or
        -not (Test-CcodReleaseDefenderCanonicalUtc $manifestTimestamp)) {
        Throw-CcodReleaseDefenderError 'CCOD_RELEASE_MANIFEST_INVALID' 'Release manifest metadata does not have the required canonical shape' $manifestFile
    }
    $assets = @($manifest.assets)
    $contractNames = @(Get-CcodExpectedReleaseAssetNames -Version $ExpectedVersion)
    $expectedNames = @($contractNames[5],$contractNames[6],$contractNames[2],$contractNames[7],$contractNames[8],$contractNames[9])
    if ($assets.Count -ne $expectedNames.Count) { Throw-CcodReleaseDefenderError 'CCOD_RELEASE_MANIFEST_INVALID' 'Release manifest does not bind the exact required asset set' $manifestFile }
    $assetHashes = @{}
    foreach ($asset in $assets) {
        if ($null -eq $asset -or (($asset.PSObject.Properties.Name | Sort-Object) -join '|') -cne 'name|sha256' -or
            $asset.name -isnot [string] -or $asset.sha256 -isnot [string] -or $asset.name -cnotmatch '^[A-Za-z0-9._-]+$' -or $asset.sha256 -cnotmatch '^[0-9a-f]{64}$' -or
            $assetHashes.ContainsKey([string]$asset.name)) {
            Throw-CcodReleaseDefenderError 'CCOD_RELEASE_MANIFEST_INVALID' 'Release manifest asset records are malformed or duplicate' $manifestFile
        }
        $assetHashes[[string]$asset.name] = [string]$asset.sha256
    }
    if ((@($assetHashes.Keys | Sort-Object) -join '|') -cne (@($expectedNames | Sort-Object) -join '|')) {
        Throw-CcodReleaseDefenderError 'CCOD_RELEASE_MANIFEST_INVALID' 'Release manifest asset names are not the exact final candidate set' $manifestFile
    }
    foreach ($name in $expectedNames) {
        $assetPath = Assert-CcodReleaseDefenderRegularFile -Path (Join-Path $directory $name) -Kind 'Release asset'
        $actual = Get-CcodReleaseDefenderHash -Path $assetPath
        if ($actual -cne $assetHashes[$name]) {
            Throw-CcodReleaseDefenderError 'CCOD_RELEASE_ASSET_HASH_MISMATCH' 'Release asset bytes do not match the signed manifest hash' $name
        }
    }
    $installer = Join-Path $directory $expectedNames[0]
    $checksum = Join-Path $directory $expectedNames[1]
    $checksumText = [IO.File]::ReadAllText($checksum).TrimEnd("`r", "`n")
    if ($checksumText -cne ("{0} *{1}" -f $assetHashes[$expectedNames[0]], $expectedNames[0])) {
        Throw-CcodReleaseDefenderError 'CCOD_RELEASE_MANIFEST_INVALID' 'Release checksum file is not bound to the manifest installer hash' $checksum
    }
    $trayHostFile = Join-Path $directory $expectedNames[2]
    $trayHostRaw = [IO.File]::ReadAllText($trayHostFile)
    try { $trayHost = $trayHostRaw | ConvertFrom-Json -ErrorAction Stop }
    catch { Throw-CcodReleaseDefenderError 'CCOD_RELEASE_MANIFEST_INVALID' 'TrayHost provenance is not valid JSON' $expectedNames[2] }
    $trayHostVersion = $trayHost.PSObject.Properties['version']
    $trayHostCommit = $trayHost.PSObject.Properties['gitCommit']
    $trayHostTimestamp = $trayHost.PSObject.Properties['buildTimestampUtc']
    $trayHostTimestampText = Get-CcodReleaseDefenderRawJsonString -Json $trayHostRaw -PropertyName 'buildTimestampUtc'
    if ($null -eq $trayHostVersion -or $null -eq $trayHostCommit -or $null -eq $trayHostTimestamp -or
        $trayHostVersion.Value -isnot [string] -or $trayHostVersion.Value -cne $ExpectedVersion -or
        $trayHostCommit.Value -isnot [string] -or $trayHostCommit.Value -cne $manifest.gitCommit -or
        ($trayHostTimestamp.Value -isnot [string] -and $trayHostTimestamp.Value -isnot [datetime]) -or
        -not (Test-CcodReleaseDefenderCanonicalUtc $trayHostTimestampText) -or
        $trayHostTimestampText -cne $manifestTimestamp) {
        Throw-CcodReleaseDefenderError 'CCOD_RELEASE_MANIFEST_INVALID' 'TrayHost provenance is not bound to the release version, source commit, and timestamp' $expectedNames[2]
    }
    $setupProvenancePath = Join-Path $directory $expectedNames[3]
    $setupArtifactModule = Join-Path (Split-Path $PSScriptRoot -Parent) 'build\SetupArtifact.psm1'
    if (-not [IO.File]::Exists($setupArtifactModule)) {
        Throw-CcodReleaseDefenderError 'CCOD_RELEASE_MANIFEST_INVALID' 'Setup artifact validator is missing' $setupArtifactModule
    }
    Import-Module $setupArtifactModule -Force
    try {
        $setupRaw = [IO.File]::ReadAllText($setupProvenancePath)
        $setupRecord = $setupRaw | ConvertFrom-Json -ErrorAction Stop
        $payloadHash = [string]$setupRecord.payloadManifest.sha256
        if ($payloadHash -cnotmatch '^[0-9a-f]{64}$') { throw 'payload hash' }
        $repositoryRoot = Split-Path $PSScriptRoot -Parent
        $innoTemplatePath = Join-Path $repositoryRoot 'build\CodexControlOtherDevices.iss'
        $compiler = @(
            (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'),
            (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
            (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe')
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and [IO.File]::Exists($_) } | Select-Object -First 1
        if ($null -eq $compiler) { throw 'canonical ISCC compiler missing' }
        Test-CcodSetupBuildProvenance -ProvenancePath $setupProvenancePath -ExpectedVersion $ExpectedVersion -ExpectedGitCommit ([string]$manifest.gitCommit) -ExpectedPayloadManifestSha256 $payloadHash -ExpectedBuildTimestampUtc $manifestTimestamp -InnoTemplatePath $innoTemplatePath -DestinationInventoryPath (Join-Path $directory $expectedNames[5]) -CompilerPath $compiler -PayloadManifestPath (Join-Path $directory $expectedNames[4]) | Out-Null
        Test-CcodSetupArtifact -SetupPath $installer -ExpectedVersion $ExpectedVersion -ExpectedGitCommit ([string]$manifest.gitCommit) -ExpectedPayloadManifestSha256 $payloadHash | Out-Null
    } catch {
        Throw-CcodReleaseDefenderError 'CCOD_RELEASE_MANIFEST_INVALID' ('Setup provenance or final PE contract is invalid: ' + $_.Exception.Message) $setupProvenancePath
    }
    return [pscustomobject][ordered]@{
        Valid = $true
        Version = $ExpectedVersion
        GitCommit = [string]$manifest.gitCommit
        BuildTimestampUtc = $manifestTimestamp
        InstallerSha256 = [string]$assetHashes[$expectedNames[0]]
        InstallerName = $expectedNames[0]
        PayloadManifestSha256 = $payloadHash
        SetupProvenanceName = $expectedNames[3]
        SetupPayloadInputName = $expectedNames[4]
        SetupInventoryInputName = $expectedNames[5]
    }
}

function Get-CcodReleaseDefenderDetectionKeys {
    param($Records)
    $keys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($record in @($Records)) {
        if ($null -eq $record) { continue }
        $threat = if ($null -ne $record.PSObject.Properties['ThreatID']) { [string]$record.ThreatID } else { '' }
        $time = if ($null -ne $record.PSObject.Properties['InitialDetectionTime']) { [string]$record.InitialDetectionTime } else { '' }
        $resources = if ($null -ne $record.PSObject.Properties['Resources']) { (@($record.Resources) -join '|') } else { '' }
        if (-not [string]::IsNullOrWhiteSpace($threat) -or -not [string]::IsNullOrWhiteSpace($time) -or -not [string]::IsNullOrWhiteSpace($resources)) {
            $null = $keys.Add("$threat|$time|$resources")
        }
    }
    Write-Output -NoEnumerate $keys
}

function Test-CcodReleaseDefenderPositiveInteger {
    param($Value)
    if ($Value -is [bool] -or $Value -isnot [ValueType]) { return $false }
    try { return [decimal]$Value -eq [decimal][uint64]$Value -and [uint64]$Value -gt 0 }
    catch { return $false }
}

function Assert-CcodReleaseDefenderOrigin {
    param([Parameter(Mandatory)][string]$Origin,$WorkflowArtifactIdentity,[Parameter(Mandatory)][string]$ExpectedGitCommit)
    if ($Origin -ceq 'InternetDownload') {
        if ($null -ne $WorkflowArtifactIdentity) { Throw-CcodReleaseDefenderError 'CCOD_DEFENDER_ORIGIN_INVALID' 'Internet-download evidence cannot claim a workflow artifact identity.' $WorkflowArtifactIdentity }
        return $null
    }
    if ($Origin -cne 'TrustedWorkflowArtifact' -or $null -eq $WorkflowArtifactIdentity -or $WorkflowArtifactIdentity -isnot [pscustomobject] -or
        (@($WorkflowArtifactIdentity.PSObject.Properties.Name) -join ',') -cne 'provider,repository,runId,runAttempt,artifactId,artifactName,artifactDigest,gitCommit' -or
        $WorkflowArtifactIdentity.provider -isnot [string] -or $WorkflowArtifactIdentity.provider -cne 'GitHubActions' -or
        $WorkflowArtifactIdentity.repository -isnot [string] -or $WorkflowArtifactIdentity.repository -cne 'naipi11/CodexRemote-fix' -or
        -not (Test-CcodReleaseDefenderPositiveInteger $WorkflowArtifactIdentity.runId) -or
        -not (Test-CcodReleaseDefenderPositiveInteger $WorkflowArtifactIdentity.runAttempt) -or
        -not (Test-CcodReleaseDefenderPositiveInteger $WorkflowArtifactIdentity.artifactId) -or
        $WorkflowArtifactIdentity.artifactName -isnot [string] -or $WorkflowArtifactIdentity.artifactName -cne 'CodexRemote-fix portable bundle' -or
        $WorkflowArtifactIdentity.artifactDigest -isnot [string] -or $WorkflowArtifactIdentity.artifactDigest -cnotmatch '^sha256:[0-9a-f]{64}$' -or
        $WorkflowArtifactIdentity.gitCommit -isnot [string] -or $WorkflowArtifactIdentity.gitCommit -cne $ExpectedGitCommit) {
        Throw-CcodReleaseDefenderError 'CCOD_DEFENDER_ORIGIN_INVALID' 'Trusted workflow evidence requires one exact GitHub Actions artifact identity.' $WorkflowArtifactIdentity
    }
    return [pscustomobject][ordered]@{
        provider=[string]$WorkflowArtifactIdentity.provider
        repository=[string]$WorkflowArtifactIdentity.repository
        runId=[uint64]$WorkflowArtifactIdentity.runId
        runAttempt=[uint64]$WorkflowArtifactIdentity.runAttempt
        artifactId=[uint64]$WorkflowArtifactIdentity.artifactId
        artifactName=[string]$WorkflowArtifactIdentity.artifactName
        artifactDigest=[string]$WorkflowArtifactIdentity.artifactDigest
        gitCommit=[string]$WorkflowArtifactIdentity.gitCommit
    }
}

function Get-CcodReleaseDefenderStatusEvidence {
    param([Parameter(Mandatory)]$Status,[Parameter(Mandatory)][datetime]$ScanStarted)
    if ($null -eq $Status -or
        $null -eq $Status.PSObject.Properties['AMServiceEnabled'] -or $Status.AMServiceEnabled -isnot [bool] -or -not $Status.AMServiceEnabled -or
        $null -eq $Status.PSObject.Properties['AntivirusEnabled'] -or $Status.AntivirusEnabled -isnot [bool] -or -not $Status.AntivirusEnabled -or
        $null -eq $Status.PSObject.Properties['RealTimeProtectionEnabled'] -or $Status.RealTimeProtectionEnabled -isnot [bool] -or -not $Status.RealTimeProtectionEnabled -or
        $null -eq $Status.PSObject.Properties['AMProductVersion'] -or $Status.AMProductVersion -isnot [string] -or [string]::IsNullOrWhiteSpace($Status.AMProductVersion) -or $Status.AMProductVersion.Length -gt 128 -or
        $null -eq $Status.PSObject.Properties['AMEngineVersion'] -or $Status.AMEngineVersion -isnot [string] -or [string]::IsNullOrWhiteSpace($Status.AMEngineVersion) -or $Status.AMEngineVersion.Length -gt 128 -or
        $null -eq $Status.PSObject.Properties['AntivirusSignatureVersion'] -or $Status.AntivirusSignatureVersion -isnot [string] -or [string]::IsNullOrWhiteSpace($Status.AntivirusSignatureVersion) -or $Status.AntivirusSignatureVersion.Length -gt 128 -or
        $null -eq $Status.PSObject.Properties['AntivirusSignatureLastUpdated'] -or $Status.AntivirusSignatureLastUpdated -isnot [datetime]) {
        Throw-CcodReleaseDefenderError 'CCOD_DEFENDER_STATUS_INVALID' 'Defender service, AV, real-time, platform, engine, or signature state is incomplete.' $Status
    }
    $signature = ([datetime]$Status.AntivirusSignatureLastUpdated).ToUniversalTime()
    if ($signature -lt $ScanStarted.AddHours(-72) -or $signature -gt $ScanStarted.AddMinutes(5)) {
        Throw-CcodReleaseDefenderError 'CCOD_DEFENDER_STATUS_INVALID' 'Defender signature timestamp is stale or future-dated.' $signature
    }
    return [pscustomobject][ordered]@{
        ServiceEnabled=$true
        AntivirusEnabled=$true
        RealTimeProtectionEnabled=$true
        PlatformVersion=[string]$Status.AMProductVersion
        EngineVersion=[string]$Status.AMEngineVersion
        SignatureVersion=[string]$Status.AntivirusSignatureVersion
        SignatureUpdatedAtUtc=$signature.ToString('o',[Globalization.CultureInfo]::InvariantCulture)
    }
}

function Invoke-CcodReleaseDefenderCheck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CandidatePath,
        [Parameter(Mandatory)][string]$ChecksumPath,
        [Parameter(Mandatory)][string]$ManifestPath,
        [Parameter(Mandatory)][string]$Origin,
        $WorkflowArtifactIdentity,
        [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$ExpectedVersion,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$ExpectedGitCommit,
        [Parameter(Mandatory)][string]$EvidencePath,
        [hashtable]$Adapters
    )
    $adapters = Resolve-CcodReleaseDefenderAdapters -Adapters $Adapters
    $evidenceTarget = Assert-CcodReleaseDefenderEvidenceTarget -Path $EvidencePath
    $candidate = Get-CcodReleaseDefenderChecksum -CandidatePath $CandidatePath -ChecksumPath $ChecksumPath -Adapters $adapters
    $candidateDirectory = Split-Path $candidate.CandidatePath -Parent
    if ((Split-Path $candidate.ChecksumPath -Parent) -cne $candidateDirectory) { Throw-CcodReleaseDefenderError 'CCOD_RELEASE_MANIFEST_INVALID' 'Candidate and checksum must be exact siblings.' $candidate.ChecksumPath }
    $manifestFile = Assert-CcodReleaseDefenderRegularFile -Path $ManifestPath -Kind 'Matching release manifest'
    if ((Split-Path $manifestFile -Parent) -cne $candidateDirectory) { Throw-CcodReleaseDefenderError 'CCOD_RELEASE_MANIFEST_INVALID' 'Candidate and manifest must be exact siblings.' $manifestFile }
    $contractNames = @(Get-CcodExpectedReleaseAssetNames -Version $ExpectedVersion)
    $candidateLeaf = [IO.Path]::GetFileName($candidate.CandidatePath)
    $assetType = if ($candidateLeaf -ceq $contractNames[5]) { 'Setup' } elseif ($candidateLeaf -ceq $contractNames[0]) { 'PortableZip' } else { $null }
    if ($null -eq $assetType) { Throw-CcodReleaseDefenderError 'CCOD_RELEASE_MANIFEST_INVALID' 'Candidate is not the exact versioned Setup or portable ZIP asset.' $candidateLeaf }
    $expectedChecksumName = if ($assetType -ceq 'Setup') { $contractNames[6] } else { $contractNames[1] }
    $expectedManifestName = if ($assetType -ceq 'Setup') { $contractNames[10] } else { $contractNames[4] }
    if ([IO.Path]::GetFileName($candidate.ChecksumPath) -cne $expectedChecksumName -or [IO.Path]::GetFileName($manifestFile) -cne $expectedManifestName) {
        Throw-CcodReleaseDefenderError 'CCOD_RELEASE_MANIFEST_INVALID' 'Checksum or manifest does not match the exact selected asset type.' $candidateLeaf
    }
    $manifest = Test-CcodReleaseAssetManifest -ManifestPath $manifestFile -AssetDirectory $candidateDirectory -ExpectedVersion $ExpectedVersion
    if ($manifest.GitCommit -cne $ExpectedGitCommit -or $manifest.InstallerName -cne $candidateLeaf -or $manifest.InstallerSha256 -cne $candidate.Sha256) {
        Throw-CcodReleaseDefenderError 'CCOD_RELEASE_ASSET_HASH_MISMATCH' 'Expected commit, release manifest, checksum, and candidate bytes do not bind one identity.' $candidateLeaf
    }
    $checksumSha256 = [string](& $adapters.GetFileSha256 $candidate.ChecksumPath)
    $manifestSha256 = [string](& $adapters.GetFileSha256 $manifestFile)
    if ($checksumSha256 -cnotmatch '^[0-9a-f]{64}$' -or $manifestSha256 -cnotmatch '^[0-9a-f]{64}$') { Throw-CcodReleaseDefenderError 'CCOD_RELEASE_ASSET_HASH_MISMATCH' 'Checksum or manifest hash adapter returned an invalid identity.' $candidateLeaf }
    $workflowIdentity = Assert-CcodReleaseDefenderOrigin -Origin $Origin -WorkflowArtifactIdentity $WorkflowArtifactIdentity -ExpectedGitCommit $ExpectedGitCommit
    $zone = $null
    if ($Origin -ceq 'InternetDownload') {
        $zone = & $adapters.GetZoneId $candidate.CandidatePath
        if ($zone -isnot [int] -or [int]$zone -ne 3) { Throw-CcodReleaseDefenderError 'CCOD_DEFENDER_ZONE_REQUIRED' 'The final downloaded candidate must retain actual Internet ZoneId 3 before scanning.' $zone }
        $zone = [int]$zone
    }
    $started = & $adapters.GetUtcNow
    if ($started -isnot [datetime]) { Throw-CcodReleaseDefenderError 'CCOD_DEFENDER_CLOCK_INVALID' 'Defender clock did not return a DateTime value' $started }
    $started = ([datetime]$started).ToUniversalTime()
    $status = Get-CcodReleaseDefenderStatusEvidence -Status (& $adapters.GetDefenderStatus) -ScanStarted $started
    $before = Get-CcodReleaseDefenderDetectionKeys -Records (& $adapters.GetThreatDetections)
    $scanError = $null
    try { & $adapters.StartCustomScan $candidate.CandidatePath }
    catch { $scanError = $_ }
    $completed = & $adapters.GetUtcNow
    if ($completed -isnot [datetime]) { Throw-CcodReleaseDefenderError 'CCOD_DEFENDER_CLOCK_INVALID' 'Defender completion clock did not return a DateTime value.' $completed }
    $completed = ([datetime]$completed).ToUniversalTime()
    if ($completed -lt $started -or $completed -gt $started.AddHours(2)) { Throw-CcodReleaseDefenderError 'CCOD_DEFENDER_CLOCK_INVALID' 'Defender scan timestamps are reversed or exceed the two-hour bound.' $completed }
    $after = Get-CcodReleaseDefenderDetectionKeys -Records (& $adapters.GetThreatDetections)
    $newDetections = @($after | Where-Object { -not $before.Contains($_) })
    try {
        $revalidatedCandidate = Get-CcodReleaseDefenderChecksum -CandidatePath $candidate.CandidatePath -ChecksumPath $candidate.ChecksumPath -Adapters $adapters
        $revalidatedManifest = Test-CcodReleaseAssetManifest -ManifestPath $manifestFile -AssetDirectory $candidateDirectory -ExpectedVersion $ExpectedVersion
        $revalidatedChecksumSha256 = [string](& $adapters.GetFileSha256 $candidate.ChecksumPath)
        $revalidatedManifestSha256 = [string](& $adapters.GetFileSha256 $manifestFile)
    } catch { Throw-CcodReleaseDefenderError 'CCOD_RELEASE_ASSET_HASH_MISMATCH' 'Candidate, checksum, or manifest identity changed during Defender scanning.' $candidateLeaf }
    if ($revalidatedCandidate.Sha256 -cne $candidate.Sha256 -or $revalidatedManifest.GitCommit -cne $ExpectedGitCommit -or
        $revalidatedManifest.InstallerName -cne $candidateLeaf -or $revalidatedManifest.InstallerSha256 -cne $candidate.Sha256 -or
        $revalidatedChecksumSha256 -cne $checksumSha256 -or $revalidatedManifestSha256 -cne $manifestSha256) {
        Throw-CcodReleaseDefenderError 'CCOD_RELEASE_ASSET_HASH_MISMATCH' 'Candidate, checksum, or manifest identity changed during Defender scanning.' $candidateLeaf
    }
    if ($Origin -ceq 'InternetDownload') {
        $revalidatedZone = & $adapters.GetZoneId $candidate.CandidatePath
        if ($revalidatedZone -isnot [int] -or [int]$revalidatedZone -ne 3) { Throw-CcodReleaseDefenderError 'CCOD_DEFENDER_ZONE_REQUIRED' 'Internet ZoneId changed during Defender scanning.' $revalidatedZone }
    }
    $errorCode = $null
    if ($null -ne $scanError) { $errorCode = 'CCOD_DEFENDER_SCAN_FAILED' }
    elseif ($newDetections.Count -gt 0) { $errorCode = 'CCOD_DEFENDER_DETECTIONS_FOUND' }
    $receipt = [pscustomobject][ordered]@{
        schemaVersion = 2
        assetType = $assetType
        assetName = $candidateLeaf
        assetSha256 = $candidate.Sha256
        checksumName = $expectedChecksumName
        checksumSha256 = $checksumSha256
        manifestName = $expectedManifestName
        manifestSha256 = $manifestSha256
        version = $ExpectedVersion
        gitCommit = $ExpectedGitCommit
        origin = $Origin
        workflowArtifactIdentity = $workflowIdentity
        zoneId = $zone
        defenderServiceEnabled = [bool]$status.ServiceEnabled
        antivirusEnabled = [bool]$status.AntivirusEnabled
        realTimeProtectionEnabled = [bool]$status.RealTimeProtectionEnabled
        defenderPlatformVersion = [string]$status.PlatformVersion
        defenderEngineVersion = [string]$status.EngineVersion
        signatureVersion = [string]$status.SignatureVersion
        signatureUpdatedAtUtc = [string]$status.SignatureUpdatedAtUtc
        scanStartedAtUtc = $started.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        scanCompletedAtUtc = $completed.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        detectionCount = [int]$newDetections.Count
        outcome = if ($null -eq $errorCode) { 'Completed' } else { 'Failed' }
        errorCode = $errorCode
    }
    try { & $adapters.WriteReceipt $evidenceTarget $receipt | Out-Null }
    catch {
        $id = Get-CcodReleaseDefenderErrorId $_
        if ($id -ceq 'CCOD_DEFENDER_EVIDENCE_INVALID') { throw }
        Throw-CcodReleaseDefenderError 'CCOD_DEFENDER_EVIDENCE_WRITE_FAILED' 'Defender scan receipt could not be written.' $evidenceTarget
    }
    if ($null -ne $errorCode) { Throw-CcodReleaseDefenderError $errorCode 'The Defender final-asset gate did not complete cleanly.' $candidate.Sha256 }
    return $receipt
}

if (-not $Library) {
    try {
        $receipt = Invoke-CcodReleaseDefenderCheck -CandidatePath $CandidatePath -ChecksumPath $ChecksumPath -ManifestPath $ManifestPath -Origin $Origin -WorkflowArtifactIdentity $WorkflowArtifactIdentity -ExpectedVersion $ExpectedVersion -ExpectedGitCommit $ExpectedGitCommit -EvidencePath $EvidencePath
        $receipt | ConvertTo-Json -Depth 12
    } catch {
        Write-Error $_
        exit 1
    }
}
