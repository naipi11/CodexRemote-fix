[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Run')][string]$InstallerPath,
    [Parameter(Mandatory, ParameterSetName = 'Run')][string]$ChecksumPath,
    [Parameter(Mandatory, ParameterSetName = 'Run')][string]$EvidencePath,
    [Parameter(Mandatory, ParameterSetName = 'Library')][switch]$Library
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

function Assert-CcodReleaseDefenderRegularFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Kind)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathRooted($Path)) {
        Throw-CcodReleaseDefenderError 'CCOD_RELEASE_ASSET_INVALID' "$Kind must be an absolute path" $Path
    }
    $full = [IO.Path]::GetFullPath($Path)
    if (-not [IO.File]::Exists($full)) { Throw-CcodReleaseDefenderError 'CCOD_RELEASE_ASSET_INVALID' "$Kind is missing" $full }
    $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        Throw-CcodReleaseDefenderError 'CCOD_RELEASE_ASSET_INVALID' "$Kind must be a regular non-reparse file" $full
    }
    return $full
}

function Assert-CcodReleaseDefenderDirectory {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Kind)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathRooted($Path)) {
        Throw-CcodReleaseDefenderError 'CCOD_RELEASE_ASSET_INVALID' "$Kind must be an absolute path" $Path
    }
    $full = [IO.Path]::GetFullPath($Path)
    if (-not [IO.Directory]::Exists($full)) { Throw-CcodReleaseDefenderError 'CCOD_RELEASE_ASSET_INVALID' "$Kind is missing" $full }
    $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    if (-not $item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        Throw-CcodReleaseDefenderError 'CCOD_RELEASE_ASSET_INVALID' "$Kind must be a non-reparse directory" $full
    }
    return $full
}

function Get-CcodReleaseDefenderDefaultAdapters {
    $defaults = @{}
    $defaults.GetFileSha256 = { param($Path) Get-CcodReleaseDefenderHash -Path $Path }.GetNewClosure()
    $defaults.ReadText = { param($Path) [IO.File]::ReadAllText($Path) }.GetNewClosure()
    $defaults.GetZoneId = {
        param($Path)
        try {
            $stream = Get-Item -LiteralPath $Path -Stream Zone.Identifier -ErrorAction Stop
            if ($null -eq $stream) { return $null }
            $text = Get-Content -LiteralPath $Path -Stream Zone.Identifier -Raw -ErrorAction Stop
            $match = [regex]::Match([string]$text, '(?m)^ZoneId=(\d+)\s*$')
            if (-not $match.Success) { return $null }
            return [int]$match.Groups[1].Value
        } catch { return $null }
    }.GetNewClosure()
    $defaults.GetDefenderStatus = { Get-MpComputerStatus -ErrorAction Stop }.GetNewClosure()
    $defaults.StartCustomScan = { param($Path) Start-MpScan -ScanType CustomScan -ScanPath $Path -ErrorAction Stop }.GetNewClosure()
    $defaults.GetThreatDetections = { @(Get-MpThreatDetection -ErrorAction Stop) }.GetNewClosure()
    $defaults.GetUtcNow = { [datetime]::UtcNow }.GetNewClosure()
    $defaults.WriteReceipt = {
        param($Path, $Receipt)
        if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathRooted($Path)) {
            Throw-CcodReleaseDefenderError 'CCOD_DEFENDER_EVIDENCE_INVALID' 'Defender evidence path must be absolute' $Path
        }
        $target = [IO.Path]::GetFullPath($Path)
        $parent = Split-Path $target -Parent
        if (-not [IO.Directory]::Exists($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
        $parentItem = Get-Item -LiteralPath $parent -Force -ErrorAction Stop
        if (($parentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or [IO.File]::Exists($target)) {
            Throw-CcodReleaseDefenderError 'CCOD_DEFENDER_EVIDENCE_INVALID' 'Defender evidence target is unsafe or already exists' $target
        }
        $temporary = "$target.$([guid]::NewGuid().ToString('N')).tmp"
        try {
            [IO.File]::WriteAllText($temporary, ($Receipt | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
            [IO.File]::Move($temporary, $target)
            return $target
        } finally {
            if ([IO.File]::Exists($temporary)) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
        }
    }.GetNewClosure()
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
    param([Parameter(Mandatory)][string]$InstallerPath, [Parameter(Mandatory)][string]$ChecksumPath, [Parameter(Mandatory)][hashtable]$Adapters)
    $installer = Assert-CcodReleaseDefenderRegularFile -Path $InstallerPath -Kind 'Installer asset'
    $checksum = Assert-CcodReleaseDefenderRegularFile -Path $ChecksumPath -Kind 'Installer checksum'
    $text = & $Adapters.ReadText $checksum
    if ($text -isnot [string]) { Throw-CcodReleaseDefenderError 'CCOD_DEFENDER_CHECKSUM_INVALID' 'Installer checksum could not be read as text' $checksum }
    $match = [regex]::Match($text.TrimEnd("`r", "`n"), '^([0-9a-f]{64}) \*([^\r\n]+)$')
    if (-not $match.Success -or $match.Groups[2].Value -cne [IO.Path]::GetFileName($installer)) {
        Throw-CcodReleaseDefenderError 'CCOD_DEFENDER_CHECKSUM_INVALID' 'Installer checksum is malformed or names a different asset' $checksum
    }
    $actual = [string](& $Adapters.GetFileSha256 $installer)
    if ($actual -cnotmatch '^[0-9a-f]{64}$' -or $actual -cne $match.Groups[1].Value) {
        Throw-CcodReleaseDefenderError 'CCOD_DEFENDER_CHECKSUM_INVALID' 'Installer checksum does not match the exact bytes submitted for scanning' $installer
    }
    return [pscustomobject][ordered]@{ InstallerPath = $installer; ChecksumPath = $checksum; Sha256 = $actual }
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
    $bundleName = "CodexRemote-fix-$ExpectedVersion-windows-x64.zip"
    $checksumName = "$bundleName.sha256.txt"
    $provenanceName = "CodexRemote-fix-$ExpectedVersion-trayhost-provenance.json"
    $payloadManifestName = "CodexRemote-fix-$ExpectedVersion-payload-manifest.json"
    $expectedNames = @($bundleName,$checksumName,$provenanceName,$payloadManifestName)
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
    $expectedZipFiles = @{'Install-CodexRemote-fix.ps1'=$null;'payload-manifest.json'=$null}
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
    if ($expectedZipFiles.Count -le 2) {
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
    $expectedNames = @(
        "CodexRemote-fix-$ExpectedVersion-setup.exe",
        "CodexRemote-fix-$ExpectedVersion-setup.exe.sha256.txt",
        "CodexRemote-fix-$ExpectedVersion-trayhost-provenance.json"
    )
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
    return [pscustomobject][ordered]@{
        Valid = $true
        Version = $ExpectedVersion
        GitCommit = [string]$manifest.gitCommit
        BuildTimestampUtc = $manifestTimestamp
        InstallerSha256 = [string]$assetHashes[$expectedNames[0]]
        InstallerName = $expectedNames[0]
    }
}

function Get-CcodReleaseDefenderDetectionKeys {
    param($Records)
    $keys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($record in @($Records)) {
        if ($null -eq $record) { continue }
        $threat = if ($null -ne $record.PSObject.Properties['ThreatID']) { [string]$record.ThreatID } else { '' }
        $time = if ($null -ne $record.PSObject.Properties['InitialDetectionTime']) { [string]$record.InitialDetectionTime } else { '' }
        $resources = if ($null -ne $record.PSObject.Properties['Resources']) { [string]$record.Resources } else { '' }
        if (-not [string]::IsNullOrWhiteSpace($threat) -or -not [string]::IsNullOrWhiteSpace($time) -or -not [string]::IsNullOrWhiteSpace($resources)) {
            $null = $keys.Add("$threat|$time|$resources")
        }
    }
    Write-Output -NoEnumerate $keys
}

function Invoke-CcodReleaseDefenderCheck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$InstallerPath,
        [Parameter(Mandatory)][string]$ChecksumPath,
        [Parameter(Mandatory)][string]$EvidencePath,
        [hashtable]$Adapters
    )
    $adapters = Resolve-CcodReleaseDefenderAdapters -Adapters $Adapters
    $candidate = Get-CcodReleaseDefenderChecksum -InstallerPath $InstallerPath -ChecksumPath $ChecksumPath -Adapters $adapters
    $installerLeaf = [IO.Path]::GetFileName($candidate.InstallerPath)
    $versionMatch = [regex]::Match($installerLeaf, '^CodexRemote-fix-(\d+\.\d+\.\d+)-(?:setup\.exe|windows-x64\.zip)$')
    if (-not $versionMatch.Success) { Throw-CcodReleaseDefenderError 'CCOD_RELEASE_MANIFEST_INVALID' 'Release candidate name cannot bind a release manifest version' $installerLeaf }
    $version = $versionMatch.Groups[1].Value
    $manifestPath = Join-Path (Split-Path $candidate.InstallerPath -Parent) "CodexRemote-fix-$version-release-manifest.json"
    $manifest = Test-CcodReleaseAssetManifest -ManifestPath $manifestPath -AssetDirectory (Split-Path $candidate.InstallerPath -Parent) -ExpectedVersion $version
    if ($manifest.InstallerSha256 -cne $candidate.Sha256) { Throw-CcodReleaseDefenderError 'CCOD_RELEASE_ASSET_HASH_MISMATCH' 'Release manifest and checksum bind different installer bytes' $installerLeaf }
    $zone = & $adapters.GetZoneId $candidate.InstallerPath
    if ($zone -isnot [int] -or [int]$zone -ne 3) {
        Throw-CcodReleaseDefenderError 'CCOD_DEFENDER_ZONE_REQUIRED' 'The final downloaded installer must retain Internet ZoneId 3 before scanning.' $zone
    }
    $status = & $adapters.GetDefenderStatus
    if ($null -eq $status -or $null -eq $status.PSObject.Properties['AMProductVersion'] -or $null -eq $status.PSObject.Properties['AntivirusSignatureVersion'] -or
        $status.AMProductVersion -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$status.AMProductVersion) -or
        $status.AntivirusSignatureVersion -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$status.AntivirusSignatureVersion)) {
        Throw-CcodReleaseDefenderError 'CCOD_DEFENDER_STATUS_INVALID' 'Defender platform or signature version is unavailable.' $status
    }
    $before = Get-CcodReleaseDefenderDetectionKeys -Records (& $adapters.GetThreatDetections)
    $started = & $adapters.GetUtcNow
    if ($started -isnot [datetime]) { Throw-CcodReleaseDefenderError 'CCOD_DEFENDER_CLOCK_INVALID' 'Defender clock did not return a DateTime value' $started }
    $scanError = $null
    try { & $adapters.StartCustomScan $candidate.InstallerPath }
    catch { $scanError = $_ }
    $completed = & $adapters.GetUtcNow
    if ($completed -isnot [datetime]) { $completed = [datetime]::UtcNow }
    $after = Get-CcodReleaseDefenderDetectionKeys -Records (& $adapters.GetThreatDetections)
    $newDetections = @($after | Where-Object { -not $before.Contains($_) })
    $errorCode = $null
    if ($null -ne $scanError) { $errorCode = 'CCOD_DEFENDER_SCAN_FAILED' }
    elseif ($newDetections.Count -gt 0) { $errorCode = 'CCOD_DEFENDER_DETECTIONS_FOUND' }
    $receipt = [pscustomobject][ordered]@{
        schemaVersion = 1
        installerSha256 = $candidate.Sha256
        zoneId = [int]$zone
        defenderPlatformVersion = [string]$status.AMProductVersion
        signatureVersion = [string]$status.AntivirusSignatureVersion
        scanStartedAtUtc = $started.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        scanCompletedAtUtc = $completed.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        detectionCount = [int]$newDetections.Count
        outcome = if ($null -eq $errorCode) { 'Completed' } else { 'Failed' }
        errorCode = $errorCode
    }
    try { & $adapters.WriteReceipt $EvidencePath $receipt | Out-Null }
    catch { Throw-CcodReleaseDefenderError 'CCOD_DEFENDER_EVIDENCE_WRITE_FAILED' 'Defender scan receipt could not be written.' $EvidencePath }
    if ($null -ne $errorCode) { Throw-CcodReleaseDefenderError $errorCode 'The Defender final-asset gate did not complete cleanly.' $candidate.Sha256 }
    return $receipt
}

if (-not $Library) {
    try {
        $receipt = Invoke-CcodReleaseDefenderCheck -InstallerPath $InstallerPath -ChecksumPath $ChecksumPath -EvidencePath $EvidencePath
        $receipt | ConvertTo-Json -Depth 8
    } catch {
        Write-Error $_
        exit 1
    }
}
