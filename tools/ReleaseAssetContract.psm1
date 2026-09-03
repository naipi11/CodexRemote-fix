Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:CcodReleaseReceiptFields = @(
    'schemaVersion','assetType','assetName','assetSha256','checksumName','checksumSha256',
    'manifestName','manifestSha256','version','gitCommit','origin','workflowArtifactIdentity',
    'zoneId','defenderServiceEnabled','antivirusEnabled','realTimeProtectionEnabled',
    'defenderPlatformVersion','defenderEngineVersion','signatureVersion','signatureUpdatedAtUtc',
    'scanStartedAtUtc','scanCompletedAtUtc','detectionCount','outcome','errorCode'
)

function Throw-CcodReleaseContractError {
    param([Parameter(Mandatory)][string]$Id,[Parameter(Mandatory)][string]$Message,$Target)
    throw [Management.Automation.ErrorRecord]::new(
        [InvalidOperationException]::new($Message),$Id,
        [Management.Automation.ErrorCategory]::InvalidData,$Target)
}

function Get-CcodExpectedReleaseAssetNames {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version)
    @(
        "CodexRemote-fix-$Version-windows-x64.zip",
        "CodexRemote-fix-$Version-windows-x64.zip.sha256.txt",
        "CodexRemote-fix-$Version-trayhost-provenance.json",
        "CodexRemote-fix-$Version-payload-manifest.json",
        "CodexRemote-fix-$Version-release-manifest.json",
        "CodexRemote-fix-$Version-setup.exe",
        "CodexRemote-fix-$Version-setup.exe.sha256.txt",
        "CodexRemote-fix-$Version-setup-provenance.json",
        "CodexRemote-fix-$Version-setup-payload-manifest.json",
        "CodexRemote-fix-$Version-setup-destination-inventory.iss",
        "CodexRemote-fix-$Version-setup-release-manifest.json"
    )
}

function Test-CcodReleaseContractCanonicalUtc {
    param($Value)
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value)) { return $false }
    $parsed = [datetime]::MinValue
    return [datetime]::TryParseExact($Value,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$parsed) -and
        $parsed.Kind -eq [DateTimeKind]::Utc -and
        $parsed.ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture) -ceq $Value
}

function Assert-CcodReleaseContractPlainPath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][bool]$Directory,
        [Parameter(Mandatory)][string]$ErrorId
    )
    try {
        if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathRooted($Path) -or $Path.IndexOf(':',$Path.IndexOf(':') + 1) -ge 0) { throw 'path' }
        $canonical = [IO.Path]::GetFullPath($Path)
        $pathRoot = [IO.Path]::GetPathRoot($canonical)
        $full = if ($canonical.Length -gt $pathRoot.Length) { $canonical.TrimEnd('\') } else { $canonical }
        $presented = if ($Path.Length -gt $pathRoot.Length) { $Path.TrimEnd('\') } else { $Path }
        if ($full -cne $presented) { throw 'canonical' }
        if ($Directory) {
            if (-not [IO.Directory]::Exists($full) -or [IO.File]::Exists($full)) { throw 'directory' }
        } else {
            if (-not [IO.File]::Exists($full) -or [IO.Directory]::Exists($full)) { throw 'file' }
        }
        $current = $full
        while (-not [string]::IsNullOrWhiteSpace($current)) {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'reparse' }
            if ($current.TrimEnd('\') -ceq $pathRoot.TrimEnd('\')) { break }
            $parent = [IO.Directory]::GetParent($current)
            if ($null -eq $parent) { break }
            $next = if ($parent.FullName.Length -gt $pathRoot.Length) { $parent.FullName.TrimEnd('\') } else { $parent.FullName }
            if ($next -ceq $current) { break }
            $current = $next
        }
        return $full
    } catch {
        Throw-CcodReleaseContractError $ErrorId 'Release contract path is missing, noncanonical, or has unsafe ancestry.' $Path
    }
}

function Get-CcodReleaseContractHash {
    param([Parameter(Mandatory)][string]$Path)
    $stream = $null
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $stream = [IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        return [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','').ToLowerInvariant()
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
        $sha.Dispose()
    }
}

function Skip-CcodReleaseContractJsonWhitespace {
    param([string]$Json,[int]$Offset)
    $index = $Offset
    while ($index -lt $Json.Length -and [char]::IsWhiteSpace($Json[$index])) { $index++ }
    return $index
}

function Read-CcodReleaseContractJsonStringToken {
    param([string]$Json,[int]$Offset)
    if ($Offset -ge $Json.Length -or $Json[$Offset] -ne [char]34) { throw 'json string' }
    $index = $Offset + 1
    while ($index -lt $Json.Length) {
        $character = $Json[$index]
        if ($character -eq [char]34) {
            $end = $index + 1
            $raw = $Json.Substring($Offset,$end-$Offset)
            $decoded = $raw | ConvertFrom-Json -ErrorAction Stop
            if ($decoded -isnot [string]) { throw 'json string type' }
            return [pscustomobject]@{Value=$decoded;End=$end}
        }
        if ([int][char]$character -lt 32) { throw 'json control' }
        if ($character -eq [char]92) {
            $index++
            if ($index -ge $Json.Length) { throw 'json escape' }
            $escape = $Json[$index]
            if ($escape -eq [char]117) {
                if (($index+4) -ge $Json.Length -or $Json.Substring($index+1,4) -cnotmatch '^[0-9a-fA-F]{4}$') { throw 'json unicode escape' }
                $index += 5
                continue
            }
            if ('"\/bfnrt'.IndexOf($escape) -lt 0) { throw 'json escape' }
        }
        $index++
    }
    throw 'json string end'
}

function Read-CcodReleaseContractJsonValue {
    param([string]$Json,[int]$Offset,[int]$Depth=0)
    if ($Depth -gt 64) { throw 'json depth' }
    $index = Skip-CcodReleaseContractJsonWhitespace $Json $Offset
    if ($index -ge $Json.Length) { throw 'json value' }
    $character = $Json[$index]
    if ($character -eq [char]34) { return [int](Read-CcodReleaseContractJsonStringToken $Json $index).End }
    if ($character -eq [char]123) {
        $index++
        $keys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $index = Skip-CcodReleaseContractJsonWhitespace $Json $index
        if ($index -lt $Json.Length -and $Json[$index] -eq [char]125) { return $index+1 }
        while ($true) {
            $key = Read-CcodReleaseContractJsonStringToken $Json $index
            if (-not $keys.Add([string]$key.Value)) { throw 'duplicate json property' }
            $index = Skip-CcodReleaseContractJsonWhitespace $Json ([int]$key.End)
            if ($index -ge $Json.Length -or $Json[$index] -ne [char]58) { throw 'json colon' }
            $index = Read-CcodReleaseContractJsonValue $Json ($index+1) ($Depth+1)
            $index = Skip-CcodReleaseContractJsonWhitespace $Json $index
            if ($index -ge $Json.Length) { throw 'json object end' }
            if ($Json[$index] -eq [char]125) { return $index+1 }
            if ($Json[$index] -ne [char]44) { throw 'json comma' }
            $index = Skip-CcodReleaseContractJsonWhitespace $Json ($index+1)
        }
    }
    if ($character -eq [char]91) {
        $index++
        $index = Skip-CcodReleaseContractJsonWhitespace $Json $index
        if ($index -lt $Json.Length -and $Json[$index] -eq [char]93) { return $index+1 }
        while ($true) {
            $index = Read-CcodReleaseContractJsonValue $Json $index ($Depth+1)
            $index = Skip-CcodReleaseContractJsonWhitespace $Json $index
            if ($index -ge $Json.Length) { throw 'json array end' }
            if ($Json[$index] -eq [char]93) { return $index+1 }
            if ($Json[$index] -ne [char]44) { throw 'json comma' }
            $index = Skip-CcodReleaseContractJsonWhitespace $Json ($index+1)
        }
    }
    $match = [regex]::Match($Json.Substring($index),'^(?:true|false|null|-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)')
    if (-not $match.Success) { throw 'json primitive' }
    return $index + $match.Length
}

function Assert-CcodReleaseContractJsonLexicalShape {
    param([string]$Json)
    $end = Read-CcodReleaseContractJsonValue $Json 0 0
    $end = Skip-CcodReleaseContractJsonWhitespace $Json $end
    if ($end -ne $Json.Length) { throw 'json trailing data' }
}

function Read-CcodReleaseContractJson {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$ErrorId,[int64]$MaximumBytes=4194304)
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if ($item.Length -le 0 -or $item.Length -gt $MaximumBytes) { throw 'length' }
        $raw = [IO.File]::ReadAllText($Path,[Text.UTF8Encoding]::new($false,$true))
        Assert-CcodReleaseContractJsonLexicalShape -Json $raw
        $value = $raw | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $value -or $value -isnot [pscustomobject]) { throw 'shape' }
        return [pscustomobject]@{ Raw=$raw; Value=$value }
    } catch {
        Throw-CcodReleaseContractError $ErrorId 'Release contract JSON is malformed or outside its size bound.' $Path
    }
}

function Assert-CcodReleaseContractMetadata {
    param($Value,[string]$Version,[string]$GitCommit,[string]$Timestamp,[string]$ErrorId,$Target,[switch]$TimestampOptional)
    if ($null -eq $Value -or $Value -isnot [pscustomobject] -or
        $null -eq $Value.PSObject.Properties['version'] -or $Value.version -isnot [string] -or $Value.version -cne $Version -or
        $null -eq $Value.PSObject.Properties['gitCommit'] -or $Value.gitCommit -isnot [string] -or $Value.gitCommit -cne $GitCommit) {
        Throw-CcodReleaseContractError $ErrorId 'Release metadata does not bind the common version and commit.' $Target
    }
    if (-not $TimestampOptional) {
        if ($null -eq $Value.PSObject.Properties['buildTimestampUtc'] -or -not (Test-CcodReleaseContractCanonicalUtc $Value.buildTimestampUtc) -or $Value.buildTimestampUtc -cne $Timestamp) {
            Throw-CcodReleaseContractError $ErrorId 'Release metadata does not bind the common canonical timestamp.' $Target
        }
    }
}

function Get-CcodReleaseContractManifestMap {
    param(
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)][string[]]$ExpectedNames,
        [Parameter(Mandatory)][string]$ErrorId,
        [Parameter(Mandatory)]$Target
    )
    $assets = @($Manifest.assets)
    if ($assets.Count -ne $ExpectedNames.Count) { Throw-CcodReleaseContractError $ErrorId 'Release manifest asset count is not exact.' $Target }
    $map = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    for ($index=0; $index -lt $assets.Count; $index++) {
        $record = $assets[$index]
        if ($null -eq $record -or $record -isnot [pscustomobject] -or
            (@($record.PSObject.Properties.Name) -join ',') -cne 'name,sha256' -or
            $record.name -isnot [string] -or $record.name -cne $ExpectedNames[$index] -or
            $record.sha256 -isnot [string] -or $record.sha256 -cnotmatch '^[0-9a-f]{64}$' -or
            $map.ContainsKey([string]$record.name)) {
            Throw-CcodReleaseContractError $ErrorId 'Release manifest asset records are malformed, duplicated, or out of order.' $Target
        }
        $map.Add([string]$record.name,[string]$record.sha256)
    }
    return $map
}

function Test-CcodExactReleaseAssetSet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AssetDirectory,
        [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version
    )
    $errorId = 'CCOD_RELEASE_ASSET_SET_INVALID'
    $directory = Assert-CcodReleaseContractPlainPath -Path $AssetDirectory -Directory $true -ErrorId $errorId
    $expected = @(Get-CcodExpectedReleaseAssetNames -Version $Version)
    try { $children = @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop) }
    catch { Throw-CcodReleaseContractError $errorId 'Release asset directory cannot be enumerated exactly.' $directory }
    if ($children.Count -ne $expected.Count) { Throw-CcodReleaseContractError $errorId 'Release asset directory does not contain exactly eleven entries.' $directory }
    $byName = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($child in $children) {
        if ($child.PSIsContainer -or ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $byName.ContainsKey($child.Name)) {
            Throw-CcodReleaseContractError $errorId 'Release assets must be distinct regular non-reparse files.' $child.FullName
        }
        $byName.Add($child.Name,$child)
    }
    foreach ($name in $expected) {
        if (-not $byName.ContainsKey($name) -or [string]$byName[$name].Name -cne $name) {
            Throw-CcodReleaseContractError $errorId 'Release asset names differ by spelling, case, or membership.' $name
        }
        [void](Assert-CcodReleaseContractPlainPath -Path ([string]$byName[$name].FullName) -Directory $false -ErrorId $errorId)
    }

    $portablePath = Join-Path $directory $expected[4]
    $setupPath = Join-Path $directory $expected[10]
    $portableJson = Read-CcodReleaseContractJson -Path $portablePath -ErrorId $errorId
    $setupJson = Read-CcodReleaseContractJson -Path $setupPath -ErrorId $errorId
    $portable = $portableJson.Value; $setup = $setupJson.Value
    if ((@($portable.PSObject.Properties.Name) -join ',') -cne 'schemaVersion,product,version,gitCommit,buildTimestampUtc,distribution,assets' -or
        $portable.schemaVersion -isnot [int] -or $portable.schemaVersion -ne 2 -or $portable.product -cne 'CodexRemote-fix' -or
        $portable.version -cne $Version -or $portable.gitCommit -isnot [string] -or $portable.gitCommit -cnotmatch '^[0-9a-f]{40}$' -or
        -not (Test-CcodReleaseContractCanonicalUtc $portable.buildTimestampUtc) -or $portable.distribution -cne 'portable-zip') {
        Throw-CcodReleaseContractError $errorId 'Portable release manifest metadata is not exact.' $portablePath
    }
    if ((@($setup.PSObject.Properties.Name) -join ',') -cne 'schemaVersion,product,version,gitCommit,buildTimestampUtc,assets' -or
        $setup.schemaVersion -isnot [int] -or $setup.schemaVersion -ne 1 -or $setup.product -cne 'CodexRemote-fix' -or
        $setup.version -cne $Version -or $setup.gitCommit -isnot [string] -or $setup.gitCommit -cne $portable.gitCommit -or
        -not (Test-CcodReleaseContractCanonicalUtc $setup.buildTimestampUtc) -or $setup.buildTimestampUtc -cne $portable.buildTimestampUtc) {
        Throw-CcodReleaseContractError $errorId 'Setup release manifest metadata is not exact or does not share provenance.' $setupPath
    }
    $portableNames = @($expected[0],$expected[1],$expected[2],$expected[3],'CodexRemote-fix.exe','CodexRemote-fix.exe.config')
    $setupNames = @($expected[5],$expected[6],$expected[2],$expected[7],$expected[8],$expected[9])
    $portableMap = Get-CcodReleaseContractManifestMap -Manifest $portable -ExpectedNames $portableNames -ErrorId $errorId -Target $portablePath
    $setupMap = Get-CcodReleaseContractManifestMap -Manifest $setup -ExpectedNames $setupNames -ErrorId $errorId -Target $setupPath
    foreach ($name in @($portableNames | Where-Object { $_ -in $expected })) {
        if ((Get-CcodReleaseContractHash (Join-Path $directory $name)) -cne $portableMap[$name]) { Throw-CcodReleaseContractError $errorId 'Portable manifest hash differs from the public asset bytes.' $name }
    }
    foreach ($name in $setupNames) {
        if ((Get-CcodReleaseContractHash (Join-Path $directory $name)) -cne $setupMap[$name]) { Throw-CcodReleaseContractError $errorId 'Setup manifest hash differs from the public asset bytes.' $name }
    }
    if ($portableMap[$expected[2]] -cne $setupMap[$expected[2]]) { Throw-CcodReleaseContractError $errorId 'Portable and Setup manifests do not share one TrayHost provenance identity.' $expected[2] }
    foreach ($pair in @(@($expected[0],$expected[1]),@($expected[5],$expected[6]))) {
        $checksumText = [IO.File]::ReadAllText((Join-Path $directory $pair[1]),[Text.UTF8Encoding]::new($false,$true)).TrimEnd("`r","`n")
        $assetHash = Get-CcodReleaseContractHash (Join-Path $directory $pair[0])
        if ($checksumText -cne ("$assetHash *$($pair[0])")) { Throw-CcodReleaseContractError $errorId 'Release checksum is not exact.' $pair[1] }
    }
    $tray = (Read-CcodReleaseContractJson -Path (Join-Path $directory $expected[2]) -ErrorId $errorId).Value
    $portablePayload = (Read-CcodReleaseContractJson -Path (Join-Path $directory $expected[3]) -ErrorId $errorId).Value
    $setupProvenance = (Read-CcodReleaseContractJson -Path (Join-Path $directory $expected[7]) -ErrorId $errorId).Value
    $setupPayload = (Read-CcodReleaseContractJson -Path (Join-Path $directory $expected[8]) -ErrorId $errorId).Value
    Assert-CcodReleaseContractMetadata $tray $Version $portable.gitCommit $portable.buildTimestampUtc $errorId $expected[2]
    Assert-CcodReleaseContractMetadata $portablePayload $Version $portable.gitCommit $portable.buildTimestampUtc $errorId $expected[3]
    Assert-CcodReleaseContractMetadata $setupProvenance $Version $portable.gitCommit $portable.buildTimestampUtc $errorId $expected[7]
    Assert-CcodReleaseContractMetadata $setupPayload $Version $portable.gitCommit $portable.buildTimestampUtc $errorId $expected[8] -TimestampOptional

    $records = [Collections.Generic.List[object]]::new()
    foreach ($name in $expected) { $records.Add([pscustomobject][ordered]@{name=$name;sha256=Get-CcodReleaseContractHash (Join-Path $directory $name)}) }
    return [pscustomobject][ordered]@{Valid=$true;Version=$Version;GitCommit=[string]$portable.gitCommit;BuildTimestampUtc=[string]$portable.buildTimestampUtc;Assets=@($records)}
}

function Get-CcodReleasePromotionReceiptNames {
    param([string]$Version)
    @("CodexRemote-fix-$Version-setup.internet-download.defender.json","CodexRemote-fix-$Version-windows-x64.internet-download.defender.json")
}

function Test-CcodReleasePromotionReceipt {
    param($Receipt,[string]$Raw,[string]$Path,[string]$AssetType,[string]$Version,[string]$GitCommit,[string[]]$AssetNames)
    $errorId = 'CCOD_RELEASE_PROMOTION_EVIDENCE_INVALID'
    if ((@($Receipt.PSObject.Properties.Name) -join ',') -cne ($script:CcodReleaseReceiptFields -join ',')) { Throw-CcodReleaseContractError $errorId 'Defender receipt fields or order are not exact.' $Path }
    foreach ($field in $script:CcodReleaseReceiptFields) {
        if ([regex]::Matches($Raw,'"'+[regex]::Escape($field)+'"\s*:').Count -ne 1) { Throw-CcodReleaseContractError $errorId 'Defender receipt contains a missing or duplicate field.' $Path }
    }
    $setup = $AssetType -ceq 'Setup'
    $expectedAsset = if ($setup) { $AssetNames[5] } else { $AssetNames[0] }
    $expectedChecksum = if ($setup) { $AssetNames[6] } else { $AssetNames[1] }
    $expectedManifest = if ($setup) { $AssetNames[10] } else { $AssetNames[4] }
    if ($Receipt.schemaVersion -isnot [int] -or $Receipt.schemaVersion -ne 2 -or
        $Receipt.assetType -isnot [string] -or $Receipt.assetType -cne $AssetType -or
        $Receipt.assetName -isnot [string] -or $Receipt.assetName -cne $expectedAsset -or
        $Receipt.assetSha256 -isnot [string] -or $Receipt.assetSha256 -cnotmatch '^[0-9a-f]{64}$' -or
        $Receipt.checksumName -isnot [string] -or $Receipt.checksumName -cne $expectedChecksum -or
        $Receipt.checksumSha256 -isnot [string] -or $Receipt.checksumSha256 -cnotmatch '^[0-9a-f]{64}$' -or
        $Receipt.manifestName -isnot [string] -or $Receipt.manifestName -cne $expectedManifest -or
        $Receipt.manifestSha256 -isnot [string] -or $Receipt.manifestSha256 -cnotmatch '^[0-9a-f]{64}$' -or
        $Receipt.version -isnot [string] -or $Receipt.version -cne $Version -or
        $Receipt.gitCommit -isnot [string] -or $Receipt.gitCommit -cne $GitCommit -or
        $Receipt.origin -isnot [string] -or $Receipt.origin -cne 'InternetDownload' -or
        $null -ne $Receipt.workflowArtifactIdentity -or $Receipt.zoneId -isnot [int] -or $Receipt.zoneId -ne 3 -or
        $Receipt.defenderServiceEnabled -isnot [bool] -or -not $Receipt.defenderServiceEnabled -or
        $Receipt.antivirusEnabled -isnot [bool] -or -not $Receipt.antivirusEnabled -or
        $Receipt.realTimeProtectionEnabled -isnot [bool] -or -not $Receipt.realTimeProtectionEnabled -or
        $Receipt.defenderPlatformVersion -isnot [string] -or [string]::IsNullOrWhiteSpace($Receipt.defenderPlatformVersion) -or $Receipt.defenderPlatformVersion.Length -gt 128 -or
        $Receipt.defenderEngineVersion -isnot [string] -or [string]::IsNullOrWhiteSpace($Receipt.defenderEngineVersion) -or $Receipt.defenderEngineVersion.Length -gt 128 -or
        $Receipt.signatureVersion -isnot [string] -or [string]::IsNullOrWhiteSpace($Receipt.signatureVersion) -or $Receipt.signatureVersion.Length -gt 128 -or
        -not (Test-CcodReleaseContractCanonicalUtc $Receipt.signatureUpdatedAtUtc) -or
        -not (Test-CcodReleaseContractCanonicalUtc $Receipt.scanStartedAtUtc) -or
        -not (Test-CcodReleaseContractCanonicalUtc $Receipt.scanCompletedAtUtc) -or
        $Receipt.detectionCount -isnot [int] -or $Receipt.detectionCount -ne 0 -or
        $Receipt.outcome -isnot [string] -or $Receipt.outcome -cne 'Completed' -or $null -ne $Receipt.errorCode) {
        Throw-CcodReleaseContractError $errorId 'Defender receipt does not bind a completed official download scan.' $Path
    }
    $signature = [datetime]::ParseExact($Receipt.signatureUpdatedAtUtc,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
    $started = [datetime]::ParseExact($Receipt.scanStartedAtUtc,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
    $completed = [datetime]::ParseExact($Receipt.scanCompletedAtUtc,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
    if ($signature -lt $started.AddHours(-72) -or $signature -gt $started.AddMinutes(5) -or $completed -lt $started -or $completed -gt $started.AddHours(2)) {
        Throw-CcodReleaseContractError $errorId 'Defender receipt timestamps are stale, future-dated, reversed, or too long.' $Path
    }
    return $Receipt
}

function Test-CcodReleasePromotionEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$EvidenceDirectory,
        [Parameter(Mandatory)][string]$AssetDirectory,
        [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$ExpectedGitCommit
    )
    $errorId = 'CCOD_RELEASE_PROMOTION_EVIDENCE_INVALID'
    $directory = Assert-CcodReleaseContractPlainPath -Path $EvidenceDirectory -Directory $true -ErrorId $errorId
    try { $assetContract = Test-CcodExactReleaseAssetSet -AssetDirectory $AssetDirectory -Version $Version }
    catch { Throw-CcodReleaseContractError $errorId 'Promotion assets do not satisfy the exact eleven-file authority.' $AssetDirectory }
    if ($assetContract.GitCommit -cne $ExpectedGitCommit) { Throw-CcodReleaseContractError $errorId 'Promotion assets do not bind the expected commit.' $AssetDirectory }
    $names = @(Get-CcodReleasePromotionReceiptNames -Version $Version)
    try { $children = @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop) }
    catch { Throw-CcodReleaseContractError $errorId 'Promotion evidence directory cannot be read exactly.' $directory }
    if ($children.Count -ne 2) { Throw-CcodReleaseContractError $errorId 'Promotion requires exactly two receipt leaves.' $directory }
    $assets = @(Get-CcodExpectedReleaseAssetNames -Version $Version)
    $receipts = [Collections.Generic.List[object]]::new()
    for ($index=0; $index -lt 2; $index++) {
        $matching = @($children | Where-Object { $_.Name -ceq $names[$index] })
        if ($matching.Count -ne 1 -or $matching[0].PSIsContainer -or ($matching[0].Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Throw-CcodReleaseContractError $errorId 'Promotion receipt names and kinds are not exact.' $names[$index] }
        $path = Assert-CcodReleaseContractPlainPath -Path ([string]$matching[0].FullName) -Directory $false -ErrorId $errorId
        $json = Read-CcodReleaseContractJson -Path $path -ErrorId $errorId -MaximumBytes 65536
        $type = if ($index -eq 0) { 'Setup' } else { 'PortableZip' }
        $receipts.Add((Test-CcodReleasePromotionReceipt -Receipt $json.Value -Raw $json.Raw -Path $path -AssetType $type -Version $Version -GitCommit $ExpectedGitCommit -AssetNames $assets))
    }
    foreach ($binding in @(
        [pscustomobject]@{Receipt=0;Asset=5;Checksum=6;Manifest=10},
        [pscustomobject]@{Receipt=1;Asset=0;Checksum=1;Manifest=4}
    )) {
        $receipt = $receipts[$binding.Receipt]
        if ($receipt.assetSha256 -cne $assetContract.Assets[$binding.Asset].sha256 -or
            $receipt.checksumSha256 -cne $assetContract.Assets[$binding.Checksum].sha256 -or
            $receipt.manifestSha256 -cne $assetContract.Assets[$binding.Manifest].sha256) {
            Throw-CcodReleaseContractError $errorId 'Promotion receipt hashes do not match the authoritative public asset bytes.' $directory
        }
    }
    if ($receipts[0].assetSha256 -ceq $receipts[1].assetSha256 -or
        $receipts[0].checksumSha256 -ceq $receipts[1].checksumSha256 -or
        $receipts[0].manifestSha256 -ceq $receipts[1].manifestSha256) {
        Throw-CcodReleaseContractError $errorId 'Setup and portable receipts reuse an evidence identity.' $directory
    }
    return [pscustomobject][ordered]@{Valid=$true;Version=$Version;GitCommit=$ExpectedGitCommit;Receipts=@($receipts)}
}

Export-ModuleMember -Function Get-CcodExpectedReleaseAssetNames,Test-CcodExactReleaseAssetSet,Test-CcodReleasePromotionEvidence
