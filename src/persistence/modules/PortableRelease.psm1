Set-StrictMode -Version Latest

function Throw-CcodPortableReleaseError {
    param([Parameter(Mandatory)][string]$Id,[Parameter(Mandatory)][string]$Message,$Target)
    throw [Management.Automation.ErrorRecord]::new(
        [InvalidOperationException]::new($Message),$Id,[Management.Automation.ErrorCategory]::InvalidData,$Target)
}

function Get-CcodPortableReleaseFullPath {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Kind)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathRooted($Path)) {
        Throw-CcodPortableReleaseError 'CCOD_PORTABLE_PATH_INVALID' "$Kind must be an absolute path" $Path
    }
    try { return [IO.Path]::GetFullPath($Path) }
    catch { Throw-CcodPortableReleaseError 'CCOD_PORTABLE_PATH_INVALID' "$Kind is not a valid path" $Path }
}

function Test-CcodPortableReleaseReparse {
    param([Parameter(Mandatory)][string]$Path)
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        return (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
    } catch {
        Throw-CcodPortableReleaseError 'CCOD_PORTABLE_PATH_INVALID' 'A portable release path is missing or inaccessible' $Path
    }
}

function Assert-CcodPortableReleaseSafeStreams {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Kind)
    $full = Get-CcodPortableReleaseFullPath -Path $Path -Kind $Kind
    try {
        $streams = @(Get-Item -LiteralPath $full -Stream * -ErrorAction Stop)
    } catch {
        Throw-CcodPortableReleaseError 'CCOD_PORTABLE_ADS_INVALID' "$Kind alternate data streams could not be verified" $full
    }
    foreach ($stream in $streams) {
        $name = [string]$stream.Stream
        if ($name -cnotin @(':$DATA','Zone.Identifier')) {
            Throw-CcodPortableReleaseError 'CCOD_PORTABLE_ADS_INVALID' "$Kind contains an unsupported alternate data stream" $full
        }
    }
    return $full
}

function Assert-CcodPortableReleasePlainDirectory {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Kind)
    $full = Get-CcodPortableReleaseFullPath -Path $Path -Kind $Kind
    try { $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop }
    catch { Throw-CcodPortableReleaseError 'CCOD_PORTABLE_PATH_INVALID' "$Kind is missing or inaccessible" $full }
    if (-not $item.PSIsContainer -or (Test-CcodPortableReleaseReparse -Path $full)) {
        Throw-CcodPortableReleaseError 'CCOD_PORTABLE_REPARSE_PATH' "$Kind is not a plain directory" $full
    }
    return $full
}

function Test-CcodPortableReleaseRelativePath {
    param($Path)
    return $Path -is [string] -and $Path -cmatch '^[A-Za-z0-9][A-Za-z0-9._/-]{0,255}$' -and
        -not $Path.Contains('//') -and -not $Path.Contains('..') -and -not $Path.Contains(':')
}

function Resolve-CcodPortableReleaseChildPath {
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$Relative,[switch]$AllowMissingLeaf)
    $base = Assert-CcodPortableReleasePlainDirectory -Path $Root -Kind 'Portable root'
    if (-not (Test-CcodPortableReleaseRelativePath $Relative)) {
        Throw-CcodPortableReleaseError 'CCOD_PORTABLE_PATH_INVALID' 'A portable release relative path is invalid' $Relative
    }
    $candidate = [IO.Path]::GetFullPath((Join-Path $base ($Relative.Replace('/',[IO.Path]::DirectorySeparatorChar.ToString()))))
    $prefix = $base.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $candidate.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) {
        Throw-CcodPortableReleaseError 'CCOD_PORTABLE_PATH_INVALID' 'A portable release path escaped its root' $candidate
    }
    $cursor = $base
    foreach ($segment in @($Relative -split '/' | Where-Object { $_.Length -gt 0 })) {
        $cursor = Join-Path $cursor $segment
        if (-not (Test-Path -LiteralPath $cursor -PathType Any)) {
            if ($AllowMissingLeaf -and $cursor -ceq $candidate) { break }
            Throw-CcodPortableReleaseError 'CCOD_PORTABLE_PATH_INVALID' 'A portable release path is missing' $cursor
        }
        if (Test-CcodPortableReleaseReparse -Path $cursor) {
            Throw-CcodPortableReleaseError 'CCOD_PORTABLE_REPARSE_PATH' 'A portable release path contains a reparse point' $cursor
        }
    }
    return $candidate
}

function Get-CcodPortableReleaseSha256 {
    param([Parameter(Mandatory)][string]$Path)
    $full = Get-CcodPortableReleaseFullPath -Path $Path -Kind 'Portable release file'
    if (-not [IO.File]::Exists($full) -or (Test-CcodPortableReleaseReparse -Path $full)) {
        Throw-CcodPortableReleaseError 'CCOD_PORTABLE_FILE_INVALID' 'A portable release file is missing or unsafe' $full
    }
    Assert-CcodPortableReleaseSafeStreams -Path $full -Kind 'Portable release file' | Out-Null
    $sha = [Security.Cryptography.SHA256]::Create()
    $stream = $null
    try {
        $stream = [IO.File]::Open($full,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        return [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','').ToLowerInvariant()
    } catch {
        Throw-CcodPortableReleaseError 'CCOD_PORTABLE_FILE_INVALID' 'A portable release file could not be hashed' $full
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
        $sha.Dispose()
    }
}

function Test-CcodPortableReleaseCanonicalUtc {
    param($Value)
    $parsed = [datetime]::MinValue
    return $Value -is [string] -and
        [datetime]::TryParseExact($Value,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$parsed) -and
        $parsed.Kind -eq [DateTimeKind]::Utc -and $parsed.ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture) -ceq $Value
}

function Test-CcodPortableReleaseExactProperties {
    param($Value,[string[]]$Expected)
    if ($null -eq $Value -or $Value -isnot [pscustomobject]) { return $false }
    $actual = @($Value.PSObject.Properties.Name)
    if ($actual.Count -ne $Expected.Count) { return $false }
    for ($index = 0; $index -lt $actual.Count; $index++) {
        if ($actual[$index] -cne $Expected[$index]) { return $false }
    }
    return $true
}

function Test-CcodPortableReleaseJsonHasNoDuplicateProperties {
    param([AllowNull()][string]$Json)
    if ($null -eq $Json) { return $false }
    $objects = [Collections.Generic.Stack[object]]::new()
    for ($index = 0; $index -lt $Json.Length; $index++) {
        $character = $Json[$index]
        if ($character -eq '{') { $objects.Push([Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)); continue }
        if ($character -eq '}') { if ($objects.Count -eq 0) { return $false }; [void]$objects.Pop(); continue }
        if ($character -ne '"') { continue }
        $name = [Text.StringBuilder]::new(); $index++
        while ($index -lt $Json.Length) {
            $character = $Json[$index]
            if ($character -eq '"') { break }
            if ($character -ne [char]92) { [void]$name.Append($character); $index++; continue }
            $index++; if ($index -ge $Json.Length) { return $false }
            $escape = $Json[$index]
            if ($escape -eq 'u') {
                if ($index + 4 -ge $Json.Length) { return $false }
                try { [void]$name.Append([char][Convert]::ToInt32($Json.Substring($index + 1,4),16)) } catch { return $false }
                $index += 5; continue
            }
            switch ([string]$escape) {
                '"' { $decoded = '"' }; '\' { $decoded = [char]92 }; '/' { $decoded = '/' }; 'b' { $decoded = [char]8 }
                'f' { $decoded = [char]12 }; 'n' { $decoded = [char]10 }; 'r' { $decoded = [char]13 }; 't' { $decoded = [char]9 }
                default { return $false }
            }
            [void]$name.Append($decoded); $index++
        }
        if ($index -ge $Json.Length) { return $false }
        $next = $index + 1
        while ($next -lt $Json.Length -and [char]::IsWhiteSpace($Json[$next])) { $next++ }
        if ($next -lt $Json.Length -and $Json[$next] -eq ':') {
            if ($objects.Count -eq 0 -or -not $objects.Peek().Add($name.ToString())) { return $false }
        }
    }
    return $objects.Count -eq 0
}

function Read-CcodPortableReleaseManifest {
    param([Parameter(Mandatory)][string]$ManifestPath)
    $full = Get-CcodPortableReleaseFullPath -Path $ManifestPath -Kind 'Portable payload manifest'
    if (-not [IO.File]::Exists($full) -or (Test-CcodPortableReleaseReparse -Path $full)) {
        Throw-CcodPortableReleaseError 'CCOD_PORTABLE_MANIFEST_INVALID' 'The portable payload manifest is missing or unsafe' $full
    }
    Assert-CcodPortableReleaseSafeStreams -Path $full -Kind 'Portable payload manifest' | Out-Null
    try {
        $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
        if ($item.Length -lt 1 -or $item.Length -gt 4194304) { throw 'manifest size is invalid' }
        $raw = [IO.File]::ReadAllText($full,[Text.UTF8Encoding]::new($false,$true))
        if (-not (Test-CcodPortableReleaseJsonHasNoDuplicateProperties $raw)) { throw 'manifest JSON is ambiguous' }
        $manifest = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Throw-CcodPortableReleaseError 'CCOD_PORTABLE_MANIFEST_INVALID' 'The portable payload manifest is malformed' $full
    }
    return [pscustomobject]@{ Path=$full; Raw=$raw; Value=$manifest }
}

function Get-CcodPortableReleaseExpectedInstallerRoot {
    $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    if ([string]::IsNullOrWhiteSpace($localAppData) -or -not [IO.Path]::IsPathRooted($localAppData)) {
        Throw-CcodPortableReleaseError 'CCOD_PORTABLE_PATH_INVALID' 'Local application data is unavailable' $localAppData
    }
    return [IO.Path]::GetFullPath((Join-Path $localAppData 'CodexControlOtherDevices-installer'))
}

function Get-CcodPortableReleaseFileRecords {
    param([Parameter(Mandatory)][string]$PayloadRoot,[switch]$AllowInstalledMetadata)
    $root = Assert-CcodPortableReleasePlainDirectory -Path $PayloadRoot -Kind 'Portable payload root'
    $records = [Collections.Generic.List[object]]::new()
    $prefix = $root.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    foreach ($item in @(Get-ChildItem -LiteralPath $root -Force -Recurse -ErrorAction Stop)) {
        if (Test-CcodPortableReleaseReparse -Path $item.FullName) {
            Throw-CcodPortableReleaseError 'CCOD_PORTABLE_REPARSE_PATH' 'A portable payload contains a reparse point' $item.FullName
        }
        if ($item.PSIsContainer) { continue }
        $full = [IO.Path]::GetFullPath($item.FullName)
        if (-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) {
            Throw-CcodPortableReleaseError 'CCOD_PORTABLE_PATH_INVALID' 'A portable payload file escaped its root' $full
        }
        $relative = $full.Substring($prefix.Length).Replace([IO.Path]::DirectorySeparatorChar,'/')
        if (-not (Test-CcodPortableReleaseRelativePath $relative)) {
            Throw-CcodPortableReleaseError 'CCOD_PORTABLE_PATH_INVALID' 'A portable payload file has an invalid relative path' $relative
        }
        if ($AllowInstalledMetadata -and $relative -ceq 'portable-payload-manifest.json') {
            continue
        }
        $records.Add([pscustomobject][ordered]@{
            path = $relative
            length = [int64]$item.Length
            sha256 = Get-CcodPortableReleaseSha256 -Path $full
        })
    }
    $comparison = [System.Comparison[object]]{ param($left,$right) [StringComparer]::Ordinal.Compare([string]$left.path,[string]$right.path) }
    $records.Sort($comparison)
    return @($records)
}

function Test-CcodPortablePayloadManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PayloadRoot,
        [Parameter(Mandatory)][string]$ManifestPath,
        [string]$ExpectedVersion,
        [string]$ExpectedGitCommit,
        [switch]$AllowInstalledMetadata
    )
    $payload = Assert-CcodPortableReleasePlainDirectory -Path $PayloadRoot -Kind 'Portable payload root'
    $manifestRecord = Read-CcodPortableReleaseManifest -ManifestPath $ManifestPath
    $manifest = $manifestRecord.Value
    $expectedFields = @('schemaVersion','product','version','gitCommit','buildTimestampUtc','files')
    if (-not (Test-CcodPortableReleaseExactProperties $manifest $expectedFields) -or
        ($manifest.schemaVersion -isnot [int] -and $manifest.schemaVersion -isnot [long]) -or [int]$manifest.schemaVersion -ne 1 -or
        $manifest.product -isnot [string] -or $manifest.product -cne 'CodexRemote-fix' -or
        $manifest.version -isnot [string] -or $manifest.version -cnotmatch '^\d+\.\d+\.\d+$' -or
        $manifest.gitCommit -isnot [string] -or $manifest.gitCommit -cnotmatch '^[0-9a-f]{40}$' -or
        -not (Test-CcodPortableReleaseCanonicalUtc $manifest.buildTimestampUtc) -or $null -eq $manifest.files -or
        (-not [string]::IsNullOrWhiteSpace($ExpectedVersion) -and $manifest.version -cne $ExpectedVersion) -or
        (-not [string]::IsNullOrWhiteSpace($ExpectedGitCommit) -and $manifest.gitCommit -cne $ExpectedGitCommit)) {
        Throw-CcodPortableReleaseError 'CCOD_PORTABLE_MANIFEST_INVALID' 'The portable payload manifest metadata is invalid' $manifestRecord.Path
    }
    $expected = @($manifest.files)
    if ($expected.Count -lt 1 -or $expected.Count -gt 4096) {
        Throw-CcodPortableReleaseError 'CCOD_PORTABLE_MANIFEST_INVALID' 'The portable payload manifest file set is invalid' $manifestRecord.Path
    }
    $previousPath = $null
    for ($index = 0; $index -lt $expected.Count; $index++) {
        $entry = $expected[$index]
        if (-not (Test-CcodPortableReleaseExactProperties $entry @('path','length','sha256')) -or
            -not (Test-CcodPortableReleaseRelativePath $entry.path) -or
            $entry.path -ceq 'portable-payload-manifest.json' -or
            $entry.sha256 -isnot [string] -or $entry.sha256 -cnotmatch '^[0-9a-f]{64}$') {
            Throw-CcodPortableReleaseError 'CCOD_PORTABLE_MANIFEST_INVALID' 'A portable payload manifest file record is invalid' $entry
        }
        try { $length = [Convert]::ToInt64($entry.length,[Globalization.CultureInfo]::InvariantCulture) }
        catch { Throw-CcodPortableReleaseError 'CCOD_PORTABLE_MANIFEST_INVALID' 'A portable payload manifest file length is invalid' $entry }
        if ($length -lt 0 -or ($null -ne $previousPath -and [StringComparer]::Ordinal.Compare($previousPath,[string]$entry.path) -ge 0)) {
            Throw-CcodPortableReleaseError 'CCOD_PORTABLE_MANIFEST_INVALID' 'Portable payload manifest file records are not canonical' $entry
        }
        $previousPath = [string]$entry.path
    }
    $actual = @(Get-CcodPortableReleaseFileRecords -PayloadRoot $payload -AllowInstalledMetadata:$AllowInstalledMetadata)
    if ($actual.Count -ne $expected.Count) {
        Throw-CcodPortableReleaseError 'CCOD_PORTABLE_MANIFEST_INVALID' 'The portable payload file set differs from its manifest' $payload
    }
    for ($index = 0; $index -lt $expected.Count; $index++) {
        $entry = $expected[$index]; $file = $actual[$index]
        if ($entry.path -cne $file.path -or [int64]$entry.length -ne [int64]$file.length -or $entry.sha256 -cne $file.sha256) {
            Throw-CcodPortableReleaseError 'CCOD_PORTABLE_MANIFEST_INVALID' 'A portable payload file does not match its manifest record' $entry.path
        }
    }
    return [pscustomobject][ordered]@{
        Valid = $true
        Version = [string]$manifest.version
        GitCommit = [string]$manifest.gitCommit
        BuildTimestampUtc = [string]$manifest.buildTimestampUtc
        PayloadManifestSha256 = Get-CcodPortableReleaseSha256 -Path $manifestRecord.Path
        Files = $actual
    }
}

function Clear-CcodPortableReleaseZoneIdentifier {
    param([Parameter(Mandatory)][string]$Path)
    try { Remove-Item -LiteralPath $Path -Stream Zone.Identifier -Force -ErrorAction SilentlyContinue } catch { }
}

function New-CcodPortableReleasePlainChildDirectory {
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$Relative)
    $base = Assert-CcodPortableReleasePlainDirectory -Path $Root -Kind 'Portable staging root'
    if (-not (Test-CcodPortableReleaseRelativePath $Relative)) {
        Throw-CcodPortableReleaseError 'CCOD_PORTABLE_PATH_INVALID' 'A portable release destination directory is invalid' $Relative
    }
    $cursor = $base
    foreach ($segment in @($Relative -split '/' | Where-Object { $_.Length -gt 0 })) {
        $cursor = Join-Path $cursor $segment
        if ([IO.File]::Exists($cursor)) {
            Throw-CcodPortableReleaseError 'CCOD_PORTABLE_PATH_INVALID' 'A portable release destination directory is a file' $cursor
        }
        if (-not [IO.Directory]::Exists($cursor)) {
            try { [IO.Directory]::CreateDirectory($cursor) | Out-Null }
            catch { Throw-CcodPortableReleaseError 'CCOD_PORTABLE_PATH_INVALID' 'A portable release destination directory could not be created' $cursor }
        }
        try { $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop }
        catch { Throw-CcodPortableReleaseError 'CCOD_PORTABLE_PATH_INVALID' 'A portable release destination directory is inaccessible' $cursor }
        if (-not $item.PSIsContainer -or (Test-CcodPortableReleaseReparse -Path $cursor)) {
            Throw-CcodPortableReleaseError 'CCOD_PORTABLE_REPARSE_PATH' 'A portable release destination directory is not plain' $cursor
        }
    }
    return $cursor
}

function Copy-CcodPortablePayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PayloadRoot,
        [Parameter(Mandatory)][string]$ManifestPath,
        [string]$InstallerRoot = (Get-CcodPortableReleaseExpectedInstallerRoot)
    )
    $source = Assert-CcodPortableReleasePlainDirectory -Path $PayloadRoot -Kind 'Portable payload root'
    $manifest = Test-CcodPortablePayloadManifest -PayloadRoot $source -ManifestPath $ManifestPath
    $target = Get-CcodPortableReleaseFullPath -Path $InstallerRoot -Kind 'Portable installer root'
    $expected = Get-CcodPortableReleaseExpectedInstallerRoot
    if ($target -cne $expected) {
        Throw-CcodPortableReleaseError 'CCOD_PORTABLE_PATH_INVALID' 'The portable installer root is not the current-user application root' $target
    }
    if ([IO.Directory]::Exists($target) -or [IO.File]::Exists($target)) {
        Throw-CcodPortableReleaseError 'CCOD_PORTABLE_INSTALLER_EXISTS' 'A portable installer root already exists; uninstall it before a clean install' $target
    }
    $parent = Assert-CcodPortableReleasePlainDirectory -Path (Split-Path $target -Parent) -Kind 'Portable installer parent'
    $staging = $target + '.staging-' + [guid]::NewGuid().ToString('N')
    [IO.Directory]::CreateDirectory($staging) | Out-Null
    try {
        foreach ($entry in @($manifest.Files)) {
            $sourceFile = Resolve-CcodPortableReleaseChildPath -Root $source -Relative $entry.path
            $separator = ([string]$entry.path).LastIndexOf('/')
            if ($separator -gt 0) {
                $relativeDirectory = ([string]$entry.path).Substring(0,$separator)
                New-CcodPortableReleasePlainChildDirectory -Root $staging -Relative $relativeDirectory | Out-Null
            }
            $destination = Resolve-CcodPortableReleaseChildPath -Root $staging -Relative $entry.path -AllowMissingLeaf
            [IO.File]::Copy($sourceFile,$destination,$false)
            if ((Get-CcodPortableReleaseSha256 -Path $destination) -cne $entry.sha256) {
                Throw-CcodPortableReleaseError 'CCOD_PORTABLE_COPY_HASH_MISMATCH' 'A copied portable payload file did not match its manifest hash' $entry.path
            }
            Clear-CcodPortableReleaseZoneIdentifier -Path $destination
        }
        $installedManifestPath = Join-Path $staging 'portable-payload-manifest.json'
        [IO.File]::Copy($ManifestPath,$installedManifestPath,$false)
        if ((Get-CcodPortableReleaseSha256 -Path $installedManifestPath) -cne $manifest.PayloadManifestSha256) {
            Throw-CcodPortableReleaseError 'CCOD_PORTABLE_COPY_HASH_MISMATCH' 'The copied portable payload manifest did not match its verified hash.' $installedManifestPath
        }
        Clear-CcodPortableReleaseZoneIdentifier -Path $installedManifestPath
        Test-CcodPortablePayloadManifest -PayloadRoot $staging -ManifestPath $installedManifestPath -ExpectedVersion $manifest.Version -ExpectedGitCommit $manifest.GitCommit -AllowInstalledMetadata | Out-Null
        [IO.Directory]::Move($staging,$target)
        return [pscustomobject][ordered]@{ InstallerRoot=$target; Manifest=$manifest }
    } catch {
        if ([IO.Directory]::Exists($staging)) {
            try { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction Stop } catch { }
        }
        throw
    }
}

function Write-CcodPortableInstalledMarker {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$InstallerRoot,
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)][string]$RuntimeId,
        [Parameter(Mandatory)][uint64]$Generation
    )
    $root = Get-CcodPortableReleaseFullPath -Path $InstallerRoot -Kind 'Portable installer root'
    if ($root -cne (Get-CcodPortableReleaseExpectedInstallerRoot)) {
        Throw-CcodPortableReleaseError 'CCOD_PORTABLE_PATH_INVALID' 'The portable marker root is not the current-user application root' $root
    }
    Assert-CcodPortableReleasePlainDirectory -Path $root -Kind 'Portable installer root' | Out-Null
    if ($Manifest.Version -isnot [string] -or $Manifest.GitCommit -isnot [string] -or $Manifest.PayloadManifestSha256 -isnot [string] -or
        $Manifest.Version -cnotmatch '^\d+\.\d+\.\d+$' -or $Manifest.GitCommit -cnotmatch '^[0-9a-f]{40}$' -or $Manifest.PayloadManifestSha256 -cnotmatch '^[0-9a-f]{64}$' -or
        [string]::IsNullOrWhiteSpace($RuntimeId)) {
        Throw-CcodPortableReleaseError 'CCOD_PORTABLE_MARKER_INVALID' 'Portable installation marker inputs are invalid' $Manifest
    }
    $installedManifestPath = Join-Path $root 'portable-payload-manifest.json'
    $installedPayload = Test-CcodPortablePayloadManifest -PayloadRoot $root -ManifestPath $installedManifestPath -ExpectedVersion $Manifest.Version -ExpectedGitCommit $Manifest.GitCommit -AllowInstalledMetadata
    if ($installedPayload.PayloadManifestSha256 -cne $Manifest.PayloadManifestSha256) {
        Throw-CcodPortableReleaseError 'CCOD_PORTABLE_MARKER_INVALID' 'The installed portable payload manifest does not match the installation receipt.' $installedManifestPath
    }
    $path = Join-Path $root 'portable-release.json'
    if ([IO.File]::Exists($path) -or [IO.Directory]::Exists($path)) {
        Throw-CcodPortableReleaseError 'CCOD_PORTABLE_MARKER_INVALID' 'A portable installation marker already exists' $path
    }
    $marker = [ordered]@{
        schemaVersion = 1
        product = 'CodexRemote-fix'
        version = [string]$Manifest.Version
        gitCommit = [string]$Manifest.GitCommit
        payloadManifestSha256 = [string]$Manifest.PayloadManifestSha256
        runtimeId = $RuntimeId
        generation = [uint64]$Generation
        installedAtUtc = [DateTime]::UtcNow.ToString('o',[Globalization.CultureInfo]::InvariantCulture)
    }
    $temporary = $path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary,($marker | ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporary,$path)
    } finally {
        if ([IO.File]::Exists($temporary)) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
    return $marker
}

function Assert-CcodPortableInstalledMarker {
    param([Parameter(Mandatory)][string]$InstallerRoot)
    $root = Get-CcodPortableReleaseFullPath -Path $InstallerRoot -Kind 'Portable installer root'
    if ($root -cne (Get-CcodPortableReleaseExpectedInstallerRoot)) {
        Throw-CcodPortableReleaseError 'CCOD_PORTABLE_PATH_INVALID' 'The portable marker root is not the current-user application root' $root
    }
    Assert-CcodPortableReleasePlainDirectory -Path $root -Kind 'Portable installer root' | Out-Null
    $markerPath = Join-Path $root 'portable-release.json'
    $record = Read-CcodPortableReleaseManifest -ManifestPath $markerPath
    $marker = $record.Value
    $expected = @('schemaVersion','product','version','gitCommit','payloadManifestSha256','runtimeId','generation','installedAtUtc')
    if (-not (Test-CcodPortableReleaseExactProperties $marker $expected) -or
        ($marker.schemaVersion -isnot [int] -and $marker.schemaVersion -isnot [long]) -or [int]$marker.schemaVersion -ne 1 -or
        $marker.product -isnot [string] -or $marker.product -cne 'CodexRemote-fix' -or
        $marker.version -isnot [string] -or $marker.version -cnotmatch '^\d+\.\d+\.\d+$' -or
        $marker.gitCommit -isnot [string] -or $marker.gitCommit -cnotmatch '^[0-9a-f]{40}$' -or
        $marker.payloadManifestSha256 -isnot [string] -or $marker.payloadManifestSha256 -cnotmatch '^[0-9a-f]{64}$' -or
        $marker.runtimeId -isnot [string] -or $marker.runtimeId -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$' -or
        -not (Test-CcodPortableReleaseCanonicalUtc $marker.installedAtUtc)) {
        Throw-CcodPortableReleaseError 'CCOD_PORTABLE_MARKER_INVALID' 'The portable installation marker is invalid' $markerPath
    }
    try { [void][Convert]::ToUInt64($marker.generation,[Globalization.CultureInfo]::InvariantCulture) }
    catch { Throw-CcodPortableReleaseError 'CCOD_PORTABLE_MARKER_INVALID' 'The portable installation generation is invalid' $markerPath }
    $installedManifestPath = Join-Path $root 'portable-payload-manifest.json'
    $installedPayload = Test-CcodPortablePayloadManifest -PayloadRoot $root -ManifestPath $installedManifestPath -ExpectedVersion $marker.version -ExpectedGitCommit $marker.gitCommit -AllowInstalledMetadata
    if ($installedPayload.PayloadManifestSha256 -cne $marker.payloadManifestSha256) {
        Throw-CcodPortableReleaseError 'CCOD_PORTABLE_MARKER_INVALID' 'The installed portable payload manifest does not match its marker.' $installedManifestPath
    }
    return $marker
}

function Remove-CcodPortableInstallerRoot {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory)][string]$InstallerRoot)
    $root = Get-CcodPortableReleaseFullPath -Path $InstallerRoot -Kind 'Portable installer root'
    if ($root -cne (Get-CcodPortableReleaseExpectedInstallerRoot)) {
        Throw-CcodPortableReleaseError 'CCOD_PORTABLE_PATH_INVALID' 'The portable installer root is not the current-user application root' $root
    }
    if (-not [IO.Directory]::Exists($root)) { return $false }
    Assert-CcodPortableInstalledMarker -InstallerRoot $root | Out-Null
    foreach ($item in @(Get-ChildItem -LiteralPath $root -Force -Recurse -ErrorAction Stop)) {
        if (Test-CcodPortableReleaseReparse -Path $item.FullName) {
            Throw-CcodPortableReleaseError 'CCOD_PORTABLE_REPARSE_PATH' 'The portable installer root contains a reparse point' $item.FullName
        }
    }
    if ($PSCmdlet.ShouldProcess($root,'Remove the verified portable installer root after protected uninstall cleanup')) {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop
        return $true
    }
    return $false
}

Export-ModuleMember -Function Test-CcodPortablePayloadManifest, Copy-CcodPortablePayload, Write-CcodPortableInstalledMarker, Assert-CcodPortableInstalledMarker, Remove-CcodPortableInstallerRoot, Get-CcodPortableReleaseSha256
