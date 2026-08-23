Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'PersistenceIO.psm1')

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

    $resolved = @{ UtcNow = { [DateTime]::UtcNow } }
    if ($null -ne $Adapters) {
        foreach ($name in $Adapters.Keys) {
            $resolved[$name] = $Adapters[$name]
        }
    }
    return $resolved
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
        [Parameter(Mandatory)][object[]]$Files
    )

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
    return Assert-CcodRuntimeId -RuntimeId ('{0}-{1}' -f $ProjectVersion, $digest.Substring(0, 16))
}

function New-CcodRuntimeManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RuntimeDirectory,
        [Parameter(Mandatory)][string]$ProjectVersion
    )

    $files = @(Get-CcodRuntimeFileRecords -RuntimeDirectory $RuntimeDirectory)
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        projectVersion = $ProjectVersion
        runtimeId = Get-CcodRuntimeId -ProjectVersion $ProjectVersion -Files $files
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
        [Parameter(Mandatory)][string]$ExpectedRuntimeId
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

    $computedRuntimeId = Get-CcodRuntimeId -ProjectVersion ([string]$projectVersionProperty.Value) -Files $actualFiles
    if ($computedRuntimeId -cne $manifestRuntimeId) {
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

function Read-CcodActiveRuntime {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$InstallRoot)

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
    $generation = $active.generation
    if ($generation -isnot [byte] -and $generation -isnot [uint16] -and $generation -isnot [uint32] -and $generation -isnot [uint64] -and
        $generation -isnot [int16] -and $generation -isnot [int32] -and $generation -isnot [int64] -or $generation -le 0) {
        Throw-CcodRuntimeError 'CCOD_RUNTIME_GENERATION_INVALID' 'Active runtime generation must be a positive unsigned integer' $path
    }
    return [pscustomobject][ordered]@{ schemaVersion=2; activeRuntime=$active.activeRuntime; previousRuntime=$active.previousRuntime; generation=[UInt64]$generation; updatedAtUtc=$active.updatedAtUtc }
}

function Set-CcodActiveRuntime {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$NewRuntimeId,
        [hashtable]$Adapters
    )

    $Adapters = Get-CcodRuntimeAdapters -Adapters $Adapters
    Assert-CcodRuntimeId -RuntimeId $NewRuntimeId | Out-Null
    $runtimeDirectory = Get-CcodRuntimeDirectoryForId -InstallRoot $InstallRoot -RuntimeId $NewRuntimeId
    $validation = Test-CcodRuntimeManifest -RuntimeDirectory $runtimeDirectory -ExpectedRuntimeId $NewRuntimeId
    if (-not $validation.Valid) {
        Throw-CcodRuntimeError $validation.Code 'New active runtime did not pass manifest validation' $runtimeDirectory
    }

    $activePath = Resolve-CcodContainedPath -Root $InstallRoot -RelativePath 'active.json' -AllowMissingLeaf
    $previousRuntime = $null
    [UInt64]$currentGeneration = 0
    if ([IO.File]::Exists($activePath)) {
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

Export-ModuleMember -Function Get-CcodRuntimeId, New-CcodRuntimeManifest, Test-CcodRuntimeManifest, Read-CcodActiveRuntime, Set-CcodActiveRuntime
