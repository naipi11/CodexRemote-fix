[CmdletBinding()]
param(
    [string]$InstallerRoot,
    [string]$InstallRoot,
    [ValidateSet('Prepare','FinalizeReceipt')][string]$Mode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:CcodUninstallTransactionFields = @(
    'schemaVersion','transactionId','runtimeId','runtimeGeneration','leaseEpoch','userSid','sessionId',
    'phase','resumePhase','startedAtUtc','updatedAtUtc','errorCode'
)
$script:CcodUninstallPhases = @(
    'Requested','Recovering','RecoveryProven','StoppingProtection','ProtectionStopped','TaskRemoved',
    'ApplicationStateRemoved','ReadyForInno','Completed','Failed'
)
$script:CcodUninstallContextFields = @('runtimeId','runtimeGeneration','leaseEpoch','userSid','sessionId','payloadRecords')
$script:CcodUninstallPayloadEntries = @(
    'src/persistence/UninstallBootstrap.ps1',
    'src/persistence/PortableUninstallFinalizer.ps1',
    'src/persistence/modules/InstallLifecycle.psm1',
    'src/persistence/modules/PortableRelease.psm1',
    'src/persistence/modules/PersistenceIO.psm1',
    'src/persistence/modules/RuntimeManifest.psm1',
    'src/persistence/modules/LifecycleEpoch.psm1',
    'src/persistence/modules/StateStore.psm1',
    'src/persistence/modules/TrustedLogonIdentity.psm1',
    'src/persistence/modules/ScheduledTask.psm1',
    'src/persistence/modules/KernelObjects.psm1',
    'src/persistence/modules/CompatibilityProbe.psm1',
    'src/persistence/modules/UiPreferences.psm1',
    'src/persistence/modules/LifecycleTransaction.psm1'
)

function Throw-CcodUninstallBootstrapError {
    param([Parameter(Mandatory)][string]$Id,[Parameter(Mandatory)][string]$Message,$Target)
    throw [Management.Automation.ErrorRecord]::new(
        [InvalidOperationException]::new($Message),$Id,[Management.Automation.ErrorCategory]::InvalidData,$Target)
}

function Get-CcodUninstallBootstrapErrorId {
    param($ErrorRecord)
    if ($null -eq $ErrorRecord -or $ErrorRecord.FullyQualifiedErrorId -isnot [string]) { return $null }
    return ([string]$ErrorRecord.FullyQualifiedErrorId -split ',')[0]
}

function Get-CcodUninstallBootstrapFullPath {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Kind)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathRooted($Path)) {
        Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_BOOTSTRAP_INVALID' "$Kind must be an absolute path" $Path
    }
    try { return [IO.Path]::GetFullPath($Path) }
    catch { Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_BOOTSTRAP_INVALID' "$Kind is not a valid path" $Path }
}

function Get-CcodUninstallBootstrapComparablePath {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Kind)
    $full = Get-CcodUninstallBootstrapFullPath -Path $Path -Kind $Kind
    $volumeRoot = [IO.Path]::GetPathRoot($full)
    while ($full.Length -gt $volumeRoot.Length -and ($full.EndsWith([IO.Path]::DirectorySeparatorChar) -or $full.EndsWith([IO.Path]::AltDirectorySeparatorChar))) {
        $full = $full.Substring(0,$full.Length - 1)
    }
    return $full
}

function Assert-CcodUninstallBootstrapSafePath {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Path,
        [switch]$AllowMissingLeaf,
        [switch]$RequireLeafFile
    )
    $canonicalRoot = Get-CcodUninstallBootstrapComparablePath -Path $Root -Kind 'Root'
    $canonicalPath = Get-CcodUninstallBootstrapFullPath -Path $Path -Kind 'Contained path'
    $prefix = $canonicalRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not ($canonicalPath -ceq $canonicalRoot -or $canonicalPath.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase))) {
        Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_REPARSE_OR_PATH_INVALID' 'A bootstrap path escaped its expected root' $canonicalPath
    }
    $rootItem = $null
    try { $rootItem = Get-Item -LiteralPath $canonicalRoot -Force -ErrorAction Stop }
    catch { Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_REPARSE_OR_PATH_INVALID' 'A bootstrap root is missing or inaccessible' $canonicalRoot }
    if (-not $rootItem.PSIsContainer -or ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_REPARSE_OR_PATH_INVALID' 'A bootstrap root is not a plain directory' $canonicalRoot
    }
    $cursor = $canonicalRoot
    $relative = $canonicalPath.Substring($canonicalRoot.Length).TrimStart([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    foreach ($segment in @($relative -split '[\\/]' | Where-Object { $_.Length -gt 0 })) {
        if ($segment -eq '.' -or $segment -eq '..' -or $segment.IndexOf(':') -ge 0) {
            Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_REPARSE_OR_PATH_INVALID' 'A bootstrap path segment is unsafe' $canonicalPath
        }
        $cursor = Join-Path $cursor $segment
        try { $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop }
        catch {
            if ($AllowMissingLeaf -and $cursor -ceq $canonicalPath) { break }
            Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_REPARSE_OR_PATH_INVALID' 'A bootstrap path is missing or inaccessible' $cursor
        }
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_REPARSE_OR_PATH_INVALID' 'A bootstrap path contains a reparse point' $cursor
        }
        if ($cursor -ceq $canonicalPath -and $RequireLeafFile -and ($item.PSIsContainer -or $item -isnot [IO.FileInfo])) {
            Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_REPARSE_OR_PATH_INVALID' 'A bootstrap file is not a plain file' $cursor
        }
    }
    return $canonicalPath
}

function Resolve-CcodUninstallBootstrapChildPath {
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$RelativePath,[switch]$AllowMissingLeaf,[switch]$RequireLeafFile)
    if ($RelativePath -isnot [string] -or [IO.Path]::IsPathRooted($RelativePath) -or $RelativePath.Length -eq 0 -or
        $RelativePath.Contains(':') -or $RelativePath -match '(^|[\\/])\.\.?(?:[\\/]|$)') {
        Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_REPARSE_OR_PATH_INVALID' 'A bootstrap relative path is unsafe' $RelativePath
    }
    $candidate = [IO.Path]::GetFullPath((Join-Path $Root $RelativePath))
    return Assert-CcodUninstallBootstrapSafePath -Root $Root -Path $candidate -AllowMissingLeaf:$AllowMissingLeaf -RequireLeafFile:$RequireLeafFile
}

function Get-CcodUninstallBootstrapFileFingerprint {
    param([Parameter(Mandatory)][string]$Path)
    $stream = $null
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $stream = [IO.File]::Open([IO.Path]::GetFullPath($Path),[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        return [pscustomobject][ordered]@{
            length = [int64]$stream.Length
            sha256 = [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','').ToLowerInvariant()
        }
    } catch {
        Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_RUNTIME_INVALID' 'A manifest-bound cleanup file could not be hashed' $Path
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
        $sha.Dispose()
    }
}

function New-CcodUninstallBootstrapPayloadRecords {
    param([hashtable]$RecordMap,[switch]$ResumeOnly)
    $records = [Collections.Generic.List[object]]::new()
    foreach ($path in @($script:CcodUninstallPayloadEntries)) {
        $length = [int64]0
        $sha256 = ('0' * 64)
        if (-not $ResumeOnly) {
            if ($null -eq $RecordMap -or -not $RecordMap.ContainsKey($path)) {
                Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_RUNTIME_INVALID' 'The verified runtime lacks a cleanup payload record' $path
            }
            $record = $RecordMap[$path]
            if ($null -eq $record -or [int64]$record.length -lt 0 -or [string]$record.sha256 -cnotmatch '^[0-9a-f]{64}$') {
                Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_RUNTIME_INVALID' 'A verified cleanup payload record is invalid' $path
            }
            $length = [int64]$record.length
            $sha256 = [string]$record.sha256
        }
        $records.Add([pscustomobject][ordered]@{ path=$path; length=$length; sha256=$sha256 })
    }
    return @($records.ToArray())
}

function Test-CcodUninstallBootstrapJsonHasNoDuplicateProperties {
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

function Read-CcodUninstallBootstrapJson {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Kind,[int]$MaximumBytes = 1048576)
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if ($item.PSIsContainer -or $item -isnot [IO.FileInfo] -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $item.Length -lt 1 -or $item.Length -gt $MaximumBytes) { throw 'invalid file' }
        $json = [IO.File]::ReadAllText($Path,[Text.UTF8Encoding]::new($false,$true))
        if (-not (Test-CcodUninstallBootstrapJsonHasNoDuplicateProperties $json)) { throw 'duplicate JSON properties' }
        $value = $json | ConvertFrom-Json -ErrorAction Stop
        if ($value -isnot [pscustomobject]) { throw 'object required' }
        return $value
    } catch {
        Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_STATE_INVALID' "$Kind is malformed, missing, or unsafe" $Path
    }
}

function Assert-CcodUninstallBootstrapManifestRecord {
    param([Parameter(Mandatory)]$Record)
    if (-not (Test-CcodUninstallBootstrapExactProperties $Record @('path','length','sha256')) -or
        $Record.path -isnot [string] -or $Record.path -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]{0,255}$' -or
        $Record.path.Contains('//') -or $Record.path -match '(^|/)(?:\.|\.\.)(?:/|$)' -or
        $Record.sha256 -isnot [string] -or $Record.sha256 -cnotmatch '^[0-9a-f]{64}$') {
        Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_RUNTIME_INVALID' 'A runtime manifest file record is invalid' $Record
    }
    try { $length = [Convert]::ToInt64($Record.length,[Globalization.CultureInfo]::InvariantCulture) }
    catch { Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_RUNTIME_INVALID' 'A runtime manifest file length is invalid' $Record }
    if ($length -lt 0) { Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_RUNTIME_INVALID' 'A runtime manifest file length is invalid' $Record }
    return [pscustomobject][ordered]@{ path = [string]$Record.path; length = [int64]$length; sha256 = [string]$Record.sha256 }
}

function Get-CcodUninstallBootstrapRuntimeRecords {
    param([Parameter(Mandatory)][string]$RuntimeRoot)
    $root = Get-CcodUninstallBootstrapComparablePath -Path $RuntimeRoot -Kind 'Runtime root'
    Assert-CcodUninstallBootstrapSafePath -Root $root -Path $root | Out-Null
    $prefix = $root + [IO.Path]::DirectorySeparatorChar
    $records = [Collections.Generic.List[object]]::new()
    try {
        foreach ($item in Get-ChildItem -LiteralPath $root -Force -Recurse -ErrorAction Stop) {
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_REPARSE_OR_PATH_INVALID' 'The active runtime contains a reparse point' $item.FullName
            }
            if ($item.PSIsContainer) { continue }
            $fullName = [IO.Path]::GetFullPath($item.FullName)
            if (-not $fullName.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) {
                Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_RUNTIME_INVALID' 'A runtime file escaped the active runtime root' $fullName
            }
            $relative = $fullName.Substring($prefix.Length).Replace([IO.Path]::DirectorySeparatorChar,'/')
            if ($relative -ceq 'manifest.json') { continue }
            $fingerprint = Get-CcodUninstallBootstrapFileFingerprint -Path $fullName
            $records.Add([pscustomobject][ordered]@{ path=$relative; length=[int64]$fingerprint.length; sha256=[string]$fingerprint.sha256 })
        }
    } catch {
        if ((Get-CcodUninstallBootstrapErrorId $_) -match '^CCOD_') { throw }
        Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_RUNTIME_INVALID' 'The active runtime file set could not be inspected' $root
    }
    $comparison = [System.Comparison[object]]{
        param($left,$right)
        return [StringComparer]::Ordinal.Compare([string]$left.path,[string]$right.path)
    }
    $records.Sort($comparison)
    return $records.ToArray()
}

function Get-CcodUninstallBootstrapRuntimeId {
    param([Parameter(Mandatory)][string]$ProjectVersion,[Parameter(Mandatory)][object[]]$Records)
    if ($ProjectVersion -isnot [string] -or $ProjectVersion -notmatch '^\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?$') {
        Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_RUNTIME_INVALID' 'The runtime manifest version is invalid' $ProjectVersion
    }
    $lines = [Collections.Generic.List[string]]::new()
    foreach ($record in $Records) { $lines.Add(('{0}`t{1}`t{2}' -f $record.path,[int64]$record.length,$record.sha256)) }
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $digest = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($lines -join "`n")))).Replace('-','').ToLowerInvariant()
        return '{0}-{1}' -f $ProjectVersion,$digest.Substring(0,16)
    } finally { $sha.Dispose() }
}

function Get-CcodUninstallBootstrapExpectedInstallRoot {
    $localAppData = [Environment]::GetEnvironmentVariable('LOCALAPPDATA','Process')
    if ([string]::IsNullOrWhiteSpace($localAppData)) {
        $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    }
    if ([string]::IsNullOrWhiteSpace($localAppData) -or -not [IO.Path]::IsPathRooted($localAppData)) {
        Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_IDENTITY_INVALID' 'Local application data is unavailable for the current user' $null
    }
    return Get-CcodUninstallBootstrapComparablePath -Path (Join-Path ([IO.Path]::GetFullPath($localAppData)) 'CodexControlOtherDevices') -Kind 'Install root'
}

function Get-CcodUninstallBootstrapCurrentIdentity {
    $windowsIdentity = $null
    $process = $null
    try {
        $windowsIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $process = [Diagnostics.Process]::GetCurrentProcess()
        if ($null -eq $windowsIdentity.User -or [string]::IsNullOrWhiteSpace($windowsIdentity.User.Value) -or $process.SessionId -lt 0) {
            Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_IDENTITY_INVALID' 'The current uninstall identity is unavailable' $null
        }
        return [pscustomobject][ordered]@{ userSid=[string]$windowsIdentity.User.Value; sessionId=[int]$process.SessionId }
    } finally {
        if ($null -ne $process) { $process.Dispose() }
        if ($null -ne $windowsIdentity) { $windowsIdentity.Dispose() }
    }
}

function Assert-CcodUninstallBootstrapInstallRootOwner {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$UserSid)
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'invalid install root' }
        $owner = $item.GetAccessControl().GetOwner([Security.Principal.SecurityIdentifier])
        if ($null -eq $owner -or $owner.Value -cne $UserSid) { throw 'owner mismatch' }
    } catch {
        Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_IDENTITY_INVALID' 'The install root is not owned by the current user' $Path
    }
}

function New-CcodUninstallBootstrapResumeContext {
    param(
        [Parameter(Mandatory)][string]$InstallerRoot,
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)]$Transaction,
        [Parameter(Mandatory)]$Identity
    )
    Assert-CcodUninstallBootstrapTransaction $Transaction
    if ($Transaction.userSid -cne $Identity.userSid -or $Transaction.sessionId -ne $Identity.sessionId) {
        Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_TRANSACTION_MISMATCH' 'The interrupted uninstall transaction does not match the current user and session' $Transaction
    }
    $resumePhase = if ($Transaction.phase -ceq 'Failed') { $Transaction.resumePhase } else { $Transaction.phase }
    if (@('TaskRemoved','ApplicationStateRemoved','ReadyForInno') -cnotcontains $resumePhase) {
        Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_RUNTIME_INVALID' 'The active runtime must remain verifiable before this uninstall phase can resume' $Transaction
    }
    $installer = Get-CcodUninstallBootstrapComparablePath -Path $InstallerRoot -Kind 'Installer root'
    $install = Get-CcodUninstallBootstrapComparablePath -Path $InstallRoot -Kind 'Install root'
    Assert-CcodUninstallBootstrapSafePath -Root $installer -Path $installer | Out-Null
    if ($install -cne (Get-CcodUninstallBootstrapExpectedInstallRoot)) {
        Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_BOOTSTRAP_INVALID' 'The uninstall bootstrap was not given the current user install root' $install
    }
    $expectedScript = Resolve-CcodUninstallBootstrapChildPath -Root $installer -RelativePath 'src\persistence\UninstallBootstrap.ps1' -RequireLeafFile
    if ([string]::IsNullOrWhiteSpace($PSCommandPath) -or (Get-CcodUninstallBootstrapFullPath -Path $PSCommandPath -Kind 'Bootstrap script') -cne $expectedScript) {
        Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_BOOTSTRAP_INVALID' 'The uninstall bootstrap was not launched from the installed application root' $PSCommandPath
    }
    return [pscustomobject][ordered]@{
        runtimeId = [string]$Transaction.runtimeId
        runtimeGeneration = [uint64]$Transaction.runtimeGeneration
        leaseEpoch = [uint64]$Transaction.leaseEpoch
        userSid = [string]$Transaction.userSid
        sessionId = [int]$Transaction.sessionId
        # Resume never re-stages payload after the application-state boundary.
        # Zero records therefore fail closed if a later change tries to stage them.
        payloadRecords = New-CcodUninstallBootstrapPayloadRecords -ResumeOnly
    }
}

function Get-CcodUninstallBootstrapVerifiedRuntimeContext {
    param([Parameter(Mandatory)][string]$InstallerRoot,[Parameter(Mandatory)][string]$InstallRoot)
    try {
        $installer = Get-CcodUninstallBootstrapComparablePath -Path $InstallerRoot -Kind 'Installer root'
        $install = Get-CcodUninstallBootstrapComparablePath -Path $InstallRoot -Kind 'Install root'
        Assert-CcodUninstallBootstrapSafePath -Root $installer -Path $installer | Out-Null
        Assert-CcodUninstallBootstrapSafePath -Root $install -Path $install | Out-Null
        $identity = Get-CcodUninstallBootstrapCurrentIdentity
        if ($install -cne (Get-CcodUninstallBootstrapExpectedInstallRoot)) {
            Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_BOOTSTRAP_INVALID' 'The uninstall bootstrap was not given the current user install root' $install
        }
        Assert-CcodUninstallBootstrapInstallRootOwner -Path $install -UserSid $identity.userSid
        $expectedScript = Resolve-CcodUninstallBootstrapChildPath -Root $installer -RelativePath 'src\persistence\UninstallBootstrap.ps1' -RequireLeafFile
        if ([string]::IsNullOrWhiteSpace($PSCommandPath) -or (Get-CcodUninstallBootstrapFullPath -Path $PSCommandPath -Kind 'Bootstrap script') -cne $expectedScript) {
            Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_BOOTSTRAP_INVALID' 'The uninstall bootstrap was not launched from the installed application root' $PSCommandPath
        }
        $activePath = Resolve-CcodUninstallBootstrapChildPath -Root $install -RelativePath 'active.json' -RequireLeafFile
        $active = Read-CcodUninstallBootstrapJson -Path $activePath -Kind 'Active runtime pointer'
        if (-not (Test-CcodUninstallBootstrapExactProperties $active @('schemaVersion','activeRuntime','previousRuntime','generation','updatedAtUtc')) -or
            $active.schemaVersion -isnot [int] -or $active.schemaVersion -ne 2 -or
            $active.activeRuntime -isnot [string] -or $active.activeRuntime -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$' -or
            ($null -ne $active.previousRuntime -and ($active.previousRuntime -isnot [string] -or $active.previousRuntime -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$')) -or
            -not (Test-CcodUninstallBootstrapCanonicalUtc $active.updatedAtUtc)) {
            Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_RUNTIME_INVALID' 'The active runtime pointer is invalid' $activePath
        }
        $generation = ConvertTo-CcodUninstallBootstrapUInt64 $active.generation 'active runtime generation'
        $runtimeRoot = Resolve-CcodUninstallBootstrapChildPath -Root $install -RelativePath ('runtime\' + $active.activeRuntime)
        $runtimeItem = Get-Item -LiteralPath $runtimeRoot -Force -ErrorAction Stop
        if (-not $runtimeItem.PSIsContainer) { Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_RUNTIME_INVALID' 'The active runtime directory is invalid' $runtimeRoot }
        $manifestPath = Resolve-CcodUninstallBootstrapChildPath -Root $runtimeRoot -RelativePath 'manifest.json' -RequireLeafFile
        $manifest = Read-CcodUninstallBootstrapJson -Path $manifestPath -Kind 'Runtime manifest'
        if (-not (Test-CcodUninstallBootstrapExactProperties $manifest @('schemaVersion','projectVersion','runtimeId','files')) -or
            $manifest.schemaVersion -isnot [int] -or $manifest.schemaVersion -ne 1 -or
            $manifest.runtimeId -isnot [string] -or $manifest.runtimeId -cne $active.activeRuntime -or
            $manifest.projectVersion -isnot [string] -or $null -eq $manifest.files) {
            Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_RUNTIME_INVALID' 'The active runtime manifest is invalid' $manifestPath
        }
        $expectedRecords = [Collections.Generic.List[object]]::new(); $previousPath = $null
        foreach ($record in @($manifest.files)) {
            $validated = Assert-CcodUninstallBootstrapManifestRecord $record
            if ($null -ne $previousPath -and [StringComparer]::Ordinal.Compare($previousPath,$validated.path) -ge 0) {
                Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_RUNTIME_INVALID' 'The runtime manifest file order is invalid' $manifestPath
            }
            $previousPath = $validated.path; $expectedRecords.Add($validated)
        }
        $actualRecords = @(Get-CcodUninstallBootstrapRuntimeRecords -RuntimeRoot $runtimeRoot)
        if ($expectedRecords.Count -ne $actualRecords.Count) { Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_RUNTIME_INVALID' 'The active runtime file set differs from its manifest' $runtimeRoot }
        $recordMap = @{}
        for ($index = 0; $index -lt $actualRecords.Count; $index++) {
            $expected = $expectedRecords[$index]; $actual = $actualRecords[$index]
            if ($expected.path -cne $actual.path -or $expected.length -ne $actual.length -or $expected.sha256 -cne $actual.sha256) {
                Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_RUNTIME_INVALID' 'The active runtime file hash differs from its manifest' $runtimeRoot
            }
            $recordMap[$expected.path] = $expected
        }
        if ((Get-CcodUninstallBootstrapRuntimeId -ProjectVersion $manifest.projectVersion -Records $actualRecords) -cne $active.activeRuntime) {
            Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_RUNTIME_INVALID' 'The active runtime ID does not match its verified manifest' $runtimeRoot
        }
        foreach ($entry in $script:CcodUninstallPayloadEntries) {
            if (-not $recordMap.ContainsKey($entry)) { Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_RUNTIME_INVALID' 'The active runtime lacks a required cleanup payload entry' $entry }
        }
        $runtimeBootstrap = Resolve-CcodUninstallBootstrapChildPath -Root $runtimeRoot -RelativePath 'src\persistence\UninstallBootstrap.ps1' -RequireLeafFile
        $runtimeFingerprint = Get-CcodUninstallBootstrapFileFingerprint -Path $runtimeBootstrap
        $installerFingerprint = Get-CcodUninstallBootstrapFileFingerprint -Path $expectedScript
        if ($runtimeFingerprint.length -ne $installerFingerprint.length -or $runtimeFingerprint.sha256 -cne $installerFingerprint.sha256 -or
            $runtimeFingerprint.length -ne $recordMap['src/persistence/UninstallBootstrap.ps1'].length -or $runtimeFingerprint.sha256 -cne $recordMap['src/persistence/UninstallBootstrap.ps1'].sha256) {
            Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_BOOTSTRAP_INVALID' 'The installed bootstrap is not the manifest-bound cleanup entry' $expectedScript
        }
        $epochPath = Resolve-CcodUninstallBootstrapChildPath -Root $install -RelativePath 'state\lifecycle-epoch.json' -RequireLeafFile
        $epochState = Read-CcodUninstallBootstrapJson -Path $epochPath -Kind 'Lifecycle epoch'
        if (-not (Test-CcodUninstallBootstrapExactProperties $epochState @('schemaVersion','epoch')) -or $epochState.schemaVersion -isnot [int] -or $epochState.schemaVersion -ne 1) {
            Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_RUNTIME_INVALID' 'The lifecycle epoch is invalid' $epochPath
        }
        $epoch = ConvertTo-CcodUninstallBootstrapUInt64 $epochState.epoch 'lifecycle epoch'
        return [pscustomobject][ordered]@{
            runtimeId = [string]$active.activeRuntime
            runtimeGeneration = [uint64]$generation
            leaseEpoch = [uint64]$epoch
            userSid = [string]$identity.userSid
            sessionId = [int]$identity.sessionId
            payloadRecords = New-CcodUninstallBootstrapPayloadRecords -RecordMap $recordMap
        }
    } catch {
        $code = Get-CcodUninstallBootstrapErrorId $_
        if ($code -match '^CCOD_') { throw }
        Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_RUNTIME_INVALID' 'The installed cleanup runtime could not be verified' $InstallRoot
    }
}

function New-CcodUninstallBootstrapDirectorySecurity {
    param([Parameter(Mandatory)][string]$UserSid)
    try {
        $user = [Security.Principal.SecurityIdentifier]::new($UserSid)
        $system = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
        $security = [Security.AccessControl.DirectorySecurity]::new()
        $security.SetOwner($user)
        $security.SetAccessRuleProtection($true,$false)
        $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
        foreach ($identity in @($user,$system)) {
            [void]$security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($identity,[Security.AccessControl.FileSystemRights]::FullControl,$inheritance,[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow))
        }
        return $security
    } catch {
        Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_ACL_INVALID' 'A secure uninstall directory ACL could not be created' $UserSid
    }
}

function Assert-CcodUninstallBootstrapDirectoryAcl {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$UserSid)
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'not plain directory' }
        $security = $item.GetAccessControl()
        if ($null -eq $security -or -not $security.AreAccessRulesProtected -or $null -eq $security.GetOwner([Security.Principal.SecurityIdentifier]) -or
            $security.GetOwner([Security.Principal.SecurityIdentifier]).Value -cne $UserSid) { throw 'ACL protection or owner mismatch' }
        $expected = @($UserSid,'S-1-5-18'); $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($rule in @($security.GetAccessRules($true,$false,[Security.Principal.SecurityIdentifier]))) {
            if ($rule.IsInherited -or $rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or
                $expected -cnotcontains $rule.IdentityReference.Value -or
                (($rule.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -ne [Security.AccessControl.FileSystemRights]::FullControl) -or
                -not $seen.Add($rule.IdentityReference.Value)) { throw 'ACL rule mismatch' }
        }
        if ($seen.Count -ne 2) { throw 'ACL principals mismatch' }
    } catch {
        Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_ACL_INVALID' 'The external uninstall transaction directory ACL could not be proven' $Path
    }
}

function Ensure-CcodUninstallBootstrapSecureDirectory {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$UserSid)
    $full = Get-CcodUninstallBootstrapComparablePath -Path $Path -Kind 'Uninstall transaction directory'
    if ([IO.Directory]::Exists($full)) {
        Assert-CcodUninstallBootstrapDirectoryAcl -Path $full -UserSid $UserSid
        return $full
    }
    try { [IO.Directory]::CreateDirectory($full,(New-CcodUninstallBootstrapDirectorySecurity -UserSid $UserSid)) | Out-Null }
    catch { Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_ACL_INVALID' 'The external uninstall transaction directory could not be created' $full }
    Assert-CcodUninstallBootstrapDirectoryAcl -Path $full -UserSid $UserSid
    return $full
}

function Enter-CcodUninstallBootstrapTransactionLock {
    param([Parameter(Mandatory)][string]$UserSid)
    $mutex = $null
    try {
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $digest = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($UserSid))).Replace('-','').ToLowerInvariant()
        } finally { $sha.Dispose() }
        $mutex = [Threading.Mutex]::new($false,('Local\CodexRemote-fix.Uninstall.' + $digest))
        $acquired = $false
        try { $acquired = $mutex.WaitOne(0) }
        catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) {
            Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_TRANSACTION_BUSY' 'Another uninstall bootstrap is already preparing this user transaction' $UserSid
        }
        return $mutex
    } catch {
        if ($null -ne $mutex) { try { $mutex.Dispose() } catch { } }
        if ((Get-CcodUninstallBootstrapErrorId $_) -match '^CCOD_') { throw }
        Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_TRANSACTION_LOCK_FAILED' 'The uninstall transaction lock could not be acquired safely' $UserSid
    }
}

function Exit-CcodUninstallBootstrapTransactionLock {
    param($Lock)
    if ($null -eq $Lock) { return }
    try { [void]$Lock.ReleaseMutex() } catch { }
    try { $Lock.Dispose() } catch { }
}

function Ensure-CcodUninstallBootstrapPayloadDirectory {
    param([Parameter(Mandatory)][string]$PayloadRoot,[Parameter(Mandatory)][string]$RelativeDirectory)
    if ($RelativeDirectory -isnot [string] -or [string]::IsNullOrWhiteSpace($RelativeDirectory) -or
        [IO.Path]::IsPathRooted($RelativeDirectory) -or $RelativeDirectory.Contains(':') -or
        $RelativeDirectory -match '(^|[\\/])\.\.?(?:[\\/]|$)') {
        Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_REPARSE_OR_PATH_INVALID' 'A staged payload directory is unsafe' $RelativeDirectory
    }
    $root = Get-CcodUninstallBootstrapComparablePath -Path $PayloadRoot -Kind 'Payload root'
    Assert-CcodUninstallBootstrapSafePath -Root $root -Path $root | Out-Null
    $cursor = $root
    foreach ($segment in @($RelativeDirectory -split '[\\/]' | Where-Object { $_.Length -gt 0 })) {
        if ($segment -eq '.' -or $segment -eq '..' -or $segment.IndexOf(':') -ge 0) {
            Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_REPARSE_OR_PATH_INVALID' 'A staged payload directory segment is unsafe' $RelativeDirectory
        }
        $cursor = Join-Path $cursor $segment
        if ([IO.File]::Exists($cursor)) {
            Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_REPARSE_OR_PATH_INVALID' 'A staged payload directory conflicts with a file' $cursor
        }
        if (-not [IO.Directory]::Exists($cursor)) {
            try { [IO.Directory]::CreateDirectory($cursor) | Out-Null }
            catch { Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_TRANSACTION_WRITE_FAILED' 'A staged payload directory could not be created' $cursor }
        }
        Assert-CcodUninstallBootstrapSafePath -Root $root -Path $cursor | Out-Null
    }
    return $cursor
}

function Write-CcodUninstallBootstrapAtomicJson {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)]$Value)
    $directory = Split-Path $Path -Parent
    $temporary = Join-Path $directory ('.ccod-uninstall-' + [guid]::NewGuid().ToString('N') + '.tmp')
    $backup = Join-Path $directory ('.ccod-uninstall-' + [guid]::NewGuid().ToString('N') + '.bak')
    try {
        $json = ($Value | ConvertTo-Json -Depth 16 -Compress) + "`n"
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
        $stream = [IO.FileStream]::new($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None,4096,[IO.FileOptions]::WriteThrough)
        try { $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        if ([IO.File]::Exists($Path)) {
            [IO.File]::Replace($temporary,$Path,$backup,$true)
        } else {
            [IO.File]::Move($temporary,$Path)
        }
    } catch {
        Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_TRANSACTION_WRITE_FAILED' 'The external uninstall transaction could not be written atomically' $Path
    } finally {
        if ([IO.File]::Exists($temporary)) { try { [IO.File]::Delete($temporary) } catch { } }
        if ([IO.File]::Exists($backup)) { try { [IO.File]::Delete($backup) } catch { } }
    }
}

function Get-CcodUninstallBootstrapDefaultTransactionRoot {
    $localAppData = [Environment]::GetEnvironmentVariable('LOCALAPPDATA','Process')
    if ([string]::IsNullOrWhiteSpace($localAppData)) {
        $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    }
    if ([string]::IsNullOrWhiteSpace($localAppData) -or -not [IO.Path]::IsPathRooted($localAppData)) {
        Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_TRANSACTION_ROOT_INVALID' 'Local application data is unavailable' $null
    }
    return Get-CcodUninstallBootstrapComparablePath -Path (Join-Path $localAppData 'CodexRemote-fix-uninstall') -Kind 'External uninstall transaction root'
}

function Get-CcodUninstallBootstrapTransactionPath {
    param([Parameter(Mandatory)][string]$TransactionRoot,[Parameter(Mandatory)][string]$TransactionId)
    if (-not (Test-CcodUninstallBootstrapCanonicalGuid $TransactionId)) { Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_TRANSACTION_INVALID' 'The uninstall transaction ID is invalid' $TransactionId }
    return Resolve-CcodUninstallBootstrapChildPath -Root $TransactionRoot -RelativePath $TransactionId -AllowMissingLeaf
}

function Read-CcodUninstallBootstrapStoredTransaction {
    param(
        [Parameter(Mandatory)][string]$TransactionRoot,
        [string]$ExpectedUserSid,
        [switch]$IncludeCompleted
    )
    if (-not [IO.Directory]::Exists($TransactionRoot)) { return $null }
    $root = Get-CcodUninstallBootstrapComparablePath -Path $TransactionRoot -Kind 'External uninstall transaction root'
    if (-not [string]::IsNullOrWhiteSpace($ExpectedUserSid)) {
        Assert-CcodUninstallBootstrapDirectoryAcl -Path $root -UserSid $ExpectedUserSid
    }
    $currentPath = Resolve-CcodUninstallBootstrapChildPath -Root $root -RelativePath 'current.json' -AllowMissingLeaf
    if (-not [IO.File]::Exists($currentPath)) { return $null }
    $current = Read-CcodUninstallBootstrapJson -Path $currentPath -Kind 'Uninstall transaction locator'
    if (-not (Test-CcodUninstallBootstrapExactProperties $current @('schemaVersion','transactionId')) -or $current.schemaVersion -isnot [int] -or $current.schemaVersion -ne 1 -or
        -not (Test-CcodUninstallBootstrapCanonicalGuid $current.transactionId)) {
        Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_TRANSACTION_INVALID' 'The uninstall transaction locator is invalid' $currentPath
    }
    $transactionDirectory = Get-CcodUninstallBootstrapTransactionPath -TransactionRoot $root -TransactionId $current.transactionId
    Assert-CcodUninstallBootstrapSafePath -Root $root -Path $transactionDirectory | Out-Null
    $transactionPath = Resolve-CcodUninstallBootstrapChildPath -Root $transactionDirectory -RelativePath 'transaction.json' -RequireLeafFile
    $transaction = Read-CcodUninstallBootstrapJson -Path $transactionPath -Kind 'Uninstall transaction'
    Assert-CcodUninstallBootstrapTransaction $transaction
    if ($transaction.transactionId -cne $current.transactionId) { Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_TRANSACTION_INVALID' 'The uninstall transaction locator does not match its receipt' $transactionPath }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedUserSid) -and $transaction.userSid -cne $ExpectedUserSid) {
        Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_TRANSACTION_MISMATCH' 'The external uninstall transaction belongs to another user' $transactionPath
    }
    Assert-CcodUninstallBootstrapDirectoryAcl -Path $transactionDirectory -UserSid $transaction.userSid
    if (-not $IncludeCompleted -and $transaction.phase -ceq 'Completed') { return $null }
    return $transaction
}

function New-CcodUninstallBootstrapTransactionDirectory {
    param(
        [Parameter(Mandatory)][string]$TransactionRoot,
        [Parameter(Mandatory)][string]$TransactionId,
        [Parameter(Mandatory)][string]$UserSid,
        [switch]$ReplaceCompletedLocator
    )
    $root = Get-CcodUninstallBootstrapComparablePath -Path $TransactionRoot -Kind 'External uninstall transaction root'
    [void](Ensure-CcodUninstallBootstrapSecureDirectory -Path $root -UserSid $UserSid)
    $directory = Join-Path $root $TransactionId
    if ([IO.Directory]::Exists($directory) -or [IO.File]::Exists($directory)) { Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_TRANSACTION_BUSY' 'The uninstall transaction ID already exists' $directory }
    [void](Ensure-CcodUninstallBootstrapSecureDirectory -Path $directory -UserSid $UserSid)
    return $directory
}

function Publish-CcodUninstallBootstrapCurrentTransaction {
    param(
        [Parameter(Mandatory)][string]$TransactionRoot,
        [Parameter(Mandatory)][string]$TransactionId,
        [Parameter(Mandatory)][string]$UserSid,
        [switch]$ReplaceCompletedLocator
    )
    $root = Get-CcodUninstallBootstrapComparablePath -Path $TransactionRoot -Kind 'External uninstall transaction root'
    Assert-CcodUninstallBootstrapDirectoryAcl -Path $root -UserSid $UserSid
    $directory = Get-CcodUninstallBootstrapTransactionPath -TransactionRoot $root -TransactionId $TransactionId
    Assert-CcodUninstallBootstrapSafePath -Root $root -Path $directory | Out-Null
    Assert-CcodUninstallBootstrapDirectoryAcl -Path $directory -UserSid $UserSid
    $transactionPath = Resolve-CcodUninstallBootstrapChildPath -Root $directory -RelativePath 'transaction.json' -RequireLeafFile
    $transaction = Read-CcodUninstallBootstrapJson -Path $transactionPath -Kind 'Uninstall transaction'
    Assert-CcodUninstallBootstrapTransaction $transaction
    if ($transaction.transactionId -cne $TransactionId -or $transaction.userSid -cne $UserSid) {
        Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_TRANSACTION_MISMATCH' 'The transaction being published does not belong to the current user' $transactionPath
    }
    $currentPath = Resolve-CcodUninstallBootstrapChildPath -Root $root -RelativePath 'current.json' -AllowMissingLeaf
    if ([IO.File]::Exists($currentPath)) {
        $existing = Read-CcodUninstallBootstrapStoredTransaction -TransactionRoot $root -ExpectedUserSid $UserSid -IncludeCompleted
        if ($null -ne $existing -and $existing.transactionId -ceq $TransactionId) { return }
        if (-not $ReplaceCompletedLocator -or $null -eq $existing -or $existing.phase -cne 'Completed') {
            Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_TRANSACTION_BUSY' 'Another uninstall transaction is already active' $currentPath
        }
    }
    Write-CcodUninstallBootstrapAtomicJson -Path $currentPath -Value ([pscustomobject][ordered]@{schemaVersion=1;transactionId=$TransactionId})
}

function Assert-CcodUninstallBootstrapFinalizationInvocation {
    param(
        [Parameter(Mandatory)][string]$TransactionRoot,
        [Parameter(Mandatory)]$Transaction,
        [Parameter(Mandatory)]$Identity
    )
    Assert-CcodUninstallBootstrapTransaction $Transaction
    if ($Transaction.userSid -cne $Identity.userSid -or $Transaction.sessionId -ne $Identity.sessionId) {
        Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_TRANSACTION_MISMATCH' 'The finalizing uninstall transaction does not match the current user and session' $Transaction
    }
    $root = Get-CcodUninstallBootstrapComparablePath -Path $TransactionRoot -Kind 'External uninstall transaction root'
    Assert-CcodUninstallBootstrapDirectoryAcl -Path $root -UserSid $Identity.userSid
    $directory = Get-CcodUninstallBootstrapTransactionPath -TransactionRoot $root -TransactionId $Transaction.transactionId
    Assert-CcodUninstallBootstrapSafePath -Root $root -Path $directory | Out-Null
    Assert-CcodUninstallBootstrapDirectoryAcl -Path $directory -UserSid $Identity.userSid
    $expectedScript = Resolve-CcodUninstallBootstrapChildPath -Root $directory -RelativePath 'payload\src\persistence\UninstallBootstrap.ps1' -RequireLeafFile
    if ([string]::IsNullOrWhiteSpace($PSCommandPath) -or
        (Get-CcodUninstallBootstrapFullPath -Path $PSCommandPath -Kind 'Staged bootstrap script') -cne $expectedScript) {
        Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_BOOTSTRAP_INVALID' 'The finalization bootstrap was not launched from the staged transaction payload' $PSCommandPath
    }
}

function Write-CcodUninstallBootstrapStoredTransaction {
    param([Parameter(Mandatory)][string]$TransactionDirectory,[Parameter(Mandatory)]$Transaction)
    Assert-CcodUninstallBootstrapTransaction $Transaction
    $directory = Get-CcodUninstallBootstrapComparablePath -Path $TransactionDirectory -Kind 'Uninstall transaction directory'
    $path = Resolve-CcodUninstallBootstrapChildPath -Root $directory -RelativePath 'transaction.json' -AllowMissingLeaf
    Write-CcodUninstallBootstrapAtomicJson -Path $path -Value $Transaction
}

function Write-CcodUninstallBootstrapStoredReceipt {
    param([Parameter(Mandatory)][string]$TransactionDirectory,[Parameter(Mandatory)]$Transaction)
    Assert-CcodUninstallBootstrapTransaction $Transaction
    $receipt = [pscustomobject][ordered]@{
        schemaVersion = 1
        transactionId = [string]$Transaction.transactionId
        runtimeId = [string]$Transaction.runtimeId
        runtimeGeneration = [uint64]$Transaction.runtimeGeneration
        leaseEpoch = [uint64]$Transaction.leaseEpoch
        phase = [string]$Transaction.phase
        updatedAtUtc = [string]$Transaction.updatedAtUtc
        errorCode = $Transaction.errorCode
    }
    $directory = Get-CcodUninstallBootstrapComparablePath -Path $TransactionDirectory -Kind 'Uninstall transaction directory'
    $path = Resolve-CcodUninstallBootstrapChildPath -Root $directory -RelativePath 'receipt.json' -AllowMissingLeaf
    Write-CcodUninstallBootstrapAtomicJson -Path $path -Value $receipt
}

function Stage-CcodUninstallBootstrapPayload {
    param([Parameter(Mandatory)][string]$InstallRoot,[Parameter(Mandatory)]$Context,[Parameter(Mandatory)][string]$TransactionDirectory)
    Assert-CcodUninstallBootstrapContext $Context
    $install = Get-CcodUninstallBootstrapComparablePath -Path $InstallRoot -Kind 'Install root'
    $runtimeRoot = Resolve-CcodUninstallBootstrapChildPath -Root $install -RelativePath ('runtime\' + $Context.runtimeId)
    $transactionDirectory = Get-CcodUninstallBootstrapComparablePath -Path $TransactionDirectory -Kind 'Uninstall transaction directory'
    $payloadRoot = Join-Path $transactionDirectory 'payload'
    [void](Ensure-CcodUninstallBootstrapSecureDirectory -Path $payloadRoot -UserSid $Context.userSid)
    foreach ($record in @($Context.payloadRecords)) {
        $entry = [string]$record.path
        $source = Resolve-CcodUninstallBootstrapChildPath -Root $runtimeRoot -RelativePath ($entry.Replace('/','\')) -RequireLeafFile
        $sourceFingerprint = Get-CcodUninstallBootstrapFileFingerprint -Path $source
        if ($sourceFingerprint.length -ne [int64]$record.length -or $sourceFingerprint.sha256 -cne [string]$record.sha256) {
            Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_PAYLOAD_HASH_MISMATCH' 'A cleanup payload source no longer matches the verified runtime manifest.' $entry
        }
        $relativeDirectory = Split-Path ($entry.Replace('/','\')) -Parent
        [void](Ensure-CcodUninstallBootstrapPayloadDirectory -PayloadRoot $payloadRoot -RelativeDirectory $relativeDirectory)
        $destination = Resolve-CcodUninstallBootstrapChildPath -Root $payloadRoot -RelativePath ($entry.Replace('/','\')) -AllowMissingLeaf
        if (-not [IO.File]::Exists($destination)) {
            [IO.File]::Copy($source,$destination,$false)
        }
        $destinationFingerprint = Get-CcodUninstallBootstrapFileFingerprint -Path $destination
        if ($destinationFingerprint.length -ne [int64]$record.length -or $destinationFingerprint.sha256 -cne [string]$record.sha256) {
            Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_PAYLOAD_HASH_MISMATCH' 'A staged cleanup payload file does not match the manifest-bound source' $entry
        }
    }
}

function Test-CcodUninstallBootstrapCanonicalGuid {
    param($Value)
    $parsed = [guid]::Empty
    return $Value -is [string] -and [guid]::TryParseExact($Value,'D',[ref]$parsed) -and $parsed.ToString('D') -ceq $Value
}

function Test-CcodUninstallBootstrapCanonicalUtc {
    param($Value)
    $parsed = [DateTime]::MinValue
    return $Value -is [string] -and
        [DateTime]::TryParseExact($Value,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$parsed) -and
        $parsed.Kind -eq [DateTimeKind]::Utc -and $parsed.ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture) -ceq $Value
}

function Test-CcodUninstallBootstrapExactProperties {
    param($Value,[string[]]$Expected)
    if ($null -eq $Value -or $Value -isnot [pscustomobject]) { return $false }
    $actual = @($Value.PSObject.Properties.Name)
    if ($actual.Count -ne $Expected.Count) { return $false }
    for ($index = 0; $index -lt $actual.Count; $index++) {
        if ($actual[$index] -cne $Expected[$index]) { return $false }
    }
    return $true
}

function ConvertTo-CcodUninstallBootstrapUInt64 {
    param($Value,[string]$Name)
    if ($Value -is [decimal]) {
        if ($Value -lt 0 -or [decimal]::Truncate($Value) -ne $Value) {
            Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_TRANSACTION_INVALID' "$Name must be an unsigned integer" $Value
        }
    } elseif ($Value -isnot [byte] -and $Value -isnot [uint16] -and $Value -isnot [uint32] -and $Value -isnot [uint64] -and
              $Value -isnot [int16] -and $Value -isnot [int32] -and $Value -isnot [int64]) {
        Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_TRANSACTION_INVALID' "$Name must be an unsigned integer" $Value
    }
    if ($Value -lt 0) { Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_TRANSACTION_INVALID' "$Name must be an unsigned integer" $Value }
    try { return [uint64]$Value } catch { Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_TRANSACTION_INVALID' "$Name is outside the unsigned range" $Value }
}

function Assert-CcodUninstallBootstrapContext {
    param([Parameter(Mandatory)]$Context)
    if (-not (Test-CcodUninstallBootstrapExactProperties $Context $script:CcodUninstallContextFields) -or
        $Context.runtimeId -isnot [string] -or $Context.runtimeId -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$' -or
        $Context.userSid -isnot [string] -or $Context.userSid -cnotmatch '^S-\d-\d+(?:-\d+)+$' -or
        $Context.sessionId -isnot [int] -or $Context.sessionId -lt 0 -or
        $null -eq $Context.payloadRecords) {
        Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_BOOTSTRAP_INVALID' 'The uninstall bootstrap context is invalid' $Context
    }
    [void](ConvertTo-CcodUninstallBootstrapUInt64 $Context.runtimeGeneration 'runtimeGeneration')
    [void](ConvertTo-CcodUninstallBootstrapUInt64 $Context.leaseEpoch 'leaseEpoch')
    $records = @($Context.payloadRecords)
    if ($records.Count -ne $script:CcodUninstallPayloadEntries.Count) { Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_BOOTSTRAP_INVALID' 'The cleanup payload record set is incomplete' $Context }
    for ($index = 0; $index -lt $records.Count; $index++) {
        $record = $records[$index]
        if (-not (Test-CcodUninstallBootstrapExactProperties $record @('path','length','sha256')) -or
            $record.path -isnot [string] -or $record.path -cne $script:CcodUninstallPayloadEntries[$index] -or
            $record.sha256 -isnot [string] -or $record.sha256 -cnotmatch '^[0-9a-f]{64}$') {
            Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_BOOTSTRAP_INVALID' 'The cleanup payload contains an unsafe path' $Context
        }
        try { if ([int64]$record.length -lt 0) { throw 'negative length' } }
        catch { Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_BOOTSTRAP_INVALID' 'The cleanup payload record length is invalid' $Context }
    }
}

function Assert-CcodUninstallBootstrapTransaction {
    param([Parameter(Mandatory)]$Transaction)
    if (-not (Test-CcodUninstallBootstrapExactProperties $Transaction $script:CcodUninstallTransactionFields) -or
        $Transaction.schemaVersion -isnot [int] -or $Transaction.schemaVersion -ne 1 -or
        -not (Test-CcodUninstallBootstrapCanonicalGuid $Transaction.transactionId) -or
        $Transaction.runtimeId -isnot [string] -or $Transaction.runtimeId -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$' -or
        $Transaction.userSid -isnot [string] -or $Transaction.userSid -cnotmatch '^S-\d-\d+(?:-\d+)+$' -or
        $Transaction.sessionId -isnot [int] -or $Transaction.sessionId -lt 0 -or
        $Transaction.phase -isnot [string] -or $script:CcodUninstallPhases -cnotcontains $Transaction.phase -or
        $Transaction.resumePhase -isnot [string] -or $script:CcodUninstallPhases -cnotcontains $Transaction.resumePhase -or
        -not (Test-CcodUninstallBootstrapCanonicalUtc $Transaction.startedAtUtc) -or
        -not (Test-CcodUninstallBootstrapCanonicalUtc $Transaction.updatedAtUtc) -or
        ($null -ne $Transaction.errorCode -and ($Transaction.errorCode -isnot [string] -or $Transaction.errorCode -cnotmatch '^CCOD_[A-Z0-9_]{1,96}$'))) {
        Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_TRANSACTION_INVALID' 'The uninstall transaction is invalid' $Transaction
    }
    [void](ConvertTo-CcodUninstallBootstrapUInt64 $Transaction.runtimeGeneration 'runtimeGeneration')
    [void](ConvertTo-CcodUninstallBootstrapUInt64 $Transaction.leaseEpoch 'leaseEpoch')
    $started = [DateTime]::ParseExact($Transaction.startedAtUtc,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
    $updated = [DateTime]::ParseExact($Transaction.updatedAtUtc,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
    $resumable = @('Requested','Recovering','RecoveryProven','StoppingProtection','ProtectionStopped','TaskRemoved','ApplicationStateRemoved','ReadyForInno')
    if ($updated -lt $started -or
        ($Transaction.phase -eq 'Failed' -and ($Transaction.errorCode -isnot [string] -or $resumable -cnotcontains $Transaction.resumePhase)) -or
        ($Transaction.phase -ne 'Failed' -and ($null -ne $Transaction.errorCode -or $Transaction.resumePhase -cne $Transaction.phase))) {
        Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_TRANSACTION_INVALID' 'The uninstall transaction phase is inconsistent' $Transaction
    }
}

function New-CcodUninstallBootstrapTransaction {
    param([Parameter(Mandatory)]$Context,[Parameter(Mandatory)][string]$TransactionId,[Parameter(Mandatory)][DateTime]$NowUtc)
    $timestamp = $NowUtc.ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture)
    $transaction = [pscustomobject][ordered]@{
        schemaVersion = 1
        transactionId = $TransactionId
        runtimeId = [string]$Context.runtimeId
        runtimeGeneration = [uint64]$Context.runtimeGeneration
        leaseEpoch = [uint64]$Context.leaseEpoch
        userSid = [string]$Context.userSid
        sessionId = [int]$Context.sessionId
        phase = 'Requested'
        resumePhase = 'Requested'
        startedAtUtc = $timestamp
        updatedAtUtc = $timestamp
        errorCode = $null
    }
    Assert-CcodUninstallBootstrapTransaction $transaction
    return $transaction
}

function Assert-CcodUninstallBootstrapTransactionMatchesContext {
    param([Parameter(Mandatory)]$Transaction,[Parameter(Mandatory)]$Context)
    Assert-CcodUninstallBootstrapTransaction $Transaction
    Assert-CcodUninstallBootstrapContext $Context
    if ($Transaction.runtimeId -cne $Context.runtimeId -or [uint64]$Transaction.runtimeGeneration -ne [uint64]$Context.runtimeGeneration -or
        [uint64]$Transaction.leaseEpoch -ne [uint64]$Context.leaseEpoch -or $Transaction.userSid -cne $Context.userSid -or $Transaction.sessionId -ne $Context.sessionId) {
        Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_TRANSACTION_MISMATCH' 'The existing uninstall transaction does not match the current verified runtime' $Transaction
    }
}

function Get-CcodUninstallBootstrapAdapters {
    param([hashtable]$Adapters)
    $defaults = @{
        ValidateInvocation = {
            param($InstallerRoot,$InstallRoot)
            Get-CcodUninstallBootstrapVerifiedRuntimeContext -InstallerRoot $InstallerRoot -InstallRoot $InstallRoot
        }
        GetTransactionRoot = {
            Get-CcodUninstallBootstrapDefaultTransactionRoot
        }
        ReadTransaction = {
            param($TransactionRoot,$ExpectedUserSid,$IncludeCompleted)
            Read-CcodUninstallBootstrapStoredTransaction -TransactionRoot $TransactionRoot -ExpectedUserSid $ExpectedUserSid -IncludeCompleted:([bool]$IncludeCompleted)
        }
        ValidateFinalizationInvocation = {
            param($TransactionRoot,$Transaction,$Identity)
            Assert-CcodUninstallBootstrapFinalizationInvocation -TransactionRoot $TransactionRoot -Transaction $Transaction -Identity $Identity
        }
        GetTransactionDirectory = {
            param($TransactionRoot,$TransactionId)
            Get-CcodUninstallBootstrapTransactionPath -TransactionRoot $TransactionRoot -TransactionId $TransactionId
        }
        NewTransactionId = { [guid]::NewGuid().ToString('D') }
        CreateTransactionRoot = {
            param($TransactionRoot,$TransactionId,$UserSid,$ReplaceCompletedLocator)
            New-CcodUninstallBootstrapTransactionDirectory -TransactionRoot $TransactionRoot -TransactionId $TransactionId -UserSid $UserSid -ReplaceCompletedLocator:([bool]$ReplaceCompletedLocator)
        }
        PublishTransaction = {
            param($TransactionRoot,$TransactionId,$UserSid,$ReplaceCompletedLocator)
            Publish-CcodUninstallBootstrapCurrentTransaction -TransactionRoot $TransactionRoot -TransactionId $TransactionId -UserSid $UserSid -ReplaceCompletedLocator:([bool]$ReplaceCompletedLocator)
        }
        StagePayload = {
            param($InstallerRoot,$InstallRoot,$Context,$TransactionRoot)
            Stage-CcodUninstallBootstrapPayload -InstallRoot $InstallRoot -Context $Context -TransactionDirectory $TransactionRoot
        }
        WriteTransaction = {
            param($TransactionRoot,$Transaction)
            Write-CcodUninstallBootstrapStoredTransaction -TransactionDirectory $TransactionRoot -Transaction $Transaction
        }
        WriteReceipt = {
            param($TransactionRoot,$Transaction)
            Write-CcodUninstallBootstrapStoredReceipt -TransactionDirectory $TransactionRoot -Transaction $Transaction
        }
        RunCleanup = {
            param($InstallerRoot,$InstallRoot,$TransactionRoot,$Transaction,$WriteTransaction)
            $payloadRoot = Resolve-CcodUninstallBootstrapChildPath -Root $TransactionRoot -RelativePath 'payload'
            $modulePath = Resolve-CcodUninstallBootstrapChildPath -Root $payloadRoot -RelativePath 'src\persistence\modules\InstallLifecycle.psm1' -RequireLeafFile
            $module = Import-Module -Name $modulePath -Force -PassThru -ErrorAction Stop
            $writer = {
                param($Value)
                & $WriteTransaction $TransactionRoot $Value
            }.GetNewClosure()
            return (& $module {
                param($Root,$Value,$Writer)
                Invoke-CcodUninstallCleanup -InstallRoot $Root -Transaction $Value -WriteTransaction $Writer
            } $InstallRoot $Transaction $writer)
        }
        TestInstallRootAbsent = { param($InstallerRoot) -not ([IO.Directory]::Exists($InstallerRoot) -or [IO.File]::Exists($InstallerRoot)) }
        GetUtcNow = { [DateTime]::UtcNow }
    }
    if ($null -eq $Adapters) { return $defaults }
    if ($Adapters -isnot [hashtable]) { Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_ADAPTER_INVALID' 'Bootstrap adapters must be a hashtable' $Adapters }
    $resolved = @{}
    foreach ($name in $defaults.Keys) { $resolved[$name] = $defaults[$name] }
    foreach ($key in $Adapters.Keys) {
        if ($key -isnot [string] -or -not $resolved.ContainsKey($key) -or $Adapters[$key] -isnot [scriptblock]) {
            Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_ADAPTER_INVALID' 'Bootstrap adapter contract is invalid' $key
        }
        $resolved[$key] = $Adapters[$key]
    }
    return $resolved
}

function Set-CcodUninstallBootstrapFailedTransaction {
    param([Parameter(Mandatory)]$Transaction,[Parameter(Mandatory)][string]$Code,[Parameter(Mandatory)][hashtable]$Adapters,[Parameter(Mandatory)][string]$TransactionRoot)
    if ($Transaction.phase -ne 'Failed') { $Transaction.resumePhase = $Transaction.phase }
    $Transaction.phase = 'Failed'
    $Transaction.updatedAtUtc = (& $Adapters.GetUtcNow).ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture)
    $Transaction.errorCode = $Code
    try {
        Assert-CcodUninstallBootstrapTransaction $Transaction
        & $Adapters.WriteTransaction $TransactionRoot $Transaction
        & $Adapters.WriteReceipt $TransactionRoot $Transaction
    } catch { }
}

function Invoke-CcodUninstallBootstrap {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$InstallerRoot,
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][ValidateSet('Prepare','FinalizeReceipt')][string]$Mode,
        [hashtable]$Adapters
    )

    $adapter = Get-CcodUninstallBootstrapAdapters $Adapters
    if ($Mode -eq 'FinalizeReceipt') {
        $transactionRoot = & $adapter.GetTransactionRoot
        $identity = Get-CcodUninstallBootstrapCurrentIdentity
        $transactionLock = Enter-CcodUninstallBootstrapTransactionLock -UserSid $identity.userSid
        try {
            $transaction = & $adapter.ReadTransaction $transactionRoot $identity.userSid $true
            if ($null -eq $transaction) { Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_TRANSACTION_MISSING' 'No resumable uninstall transaction exists' $transactionRoot }
            Assert-CcodUninstallBootstrapTransaction $transaction
            if ($transaction.phase -ne 'ReadyForInno') { Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_FINALIZATION_INVALID' 'The uninstall transaction is not ready for Inno finalization' $transaction }
            & $adapter.ValidateFinalizationInvocation $transactionRoot $transaction $identity
            if (-not (& $adapter.TestInstallRootAbsent $InstallerRoot)) { Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_FINALIZATION_INCOMPLETE' 'Inno did not remove the application root' $InstallerRoot }
            $transactionDirectory = & $adapter.GetTransactionDirectory $transactionRoot $transaction.transactionId
            if ($transactionDirectory -isnot [string] -or [string]::IsNullOrWhiteSpace($transactionDirectory)) {
                Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_TRANSACTION_ROOT_INVALID' 'The external uninstall transaction root is invalid' $transactionDirectory
            }
            $transaction.phase = 'Completed'
            $transaction.resumePhase = 'Completed'
            $transaction.updatedAtUtc = (& $adapter.GetUtcNow).ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture)
            $transaction.errorCode = $null
            Assert-CcodUninstallBootstrapTransaction $transaction
            & $adapter.WriteTransaction $transactionDirectory $transaction
            & $adapter.WriteReceipt $transactionDirectory $transaction
            return $transaction
        } finally {
            Exit-CcodUninstallBootstrapTransactionLock -Lock $transactionLock
        }
    }

    $context = $null
    $transactionRoot = $null
    $transaction = $null
    $stageRoot = $null
    $stagePayload = $false
    $transactionLock = $null
    try {
        $validationFailure = $null
        try {
            $context = & $adapter.ValidateInvocation $InstallerRoot $InstallRoot
            Assert-CcodUninstallBootstrapContext $context
        } catch {
            $validationFailure = $_
        }
        $transactionRoot = & $adapter.GetTransactionRoot
        $identity = if ($null -ne $context) {
            [pscustomobject][ordered]@{ userSid=[string]$context.userSid; sessionId=[int]$context.sessionId }
        } else {
            Get-CcodUninstallBootstrapCurrentIdentity
        }
        $transactionLock = Enter-CcodUninstallBootstrapTransactionLock -UserSid $identity.userSid
        $existing = & $adapter.ReadTransaction $transactionRoot $identity.userSid $true
        if ($null -eq $context) {
            if ($null -eq $existing) { throw $validationFailure }
            $context = New-CcodUninstallBootstrapResumeContext -InstallerRoot $InstallerRoot -InstallRoot $InstallRoot -Transaction $existing -Identity $identity
        }
        $replaceCompletedLocator = $null -ne $existing -and $existing.phase -ceq 'Completed'
        if ($replaceCompletedLocator) { $existing = $null }
        $transaction = $existing
        if ($null -eq $transaction) {
            $transactionId = & $adapter.NewTransactionId
            if (-not (Test-CcodUninstallBootstrapCanonicalGuid $transactionId)) { Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_TRANSACTION_INVALID' 'The generated uninstall transaction ID is invalid' $transactionId }
            $stageRoot = & $adapter.CreateTransactionRoot $transactionRoot $transactionId $context.userSid ([bool]$replaceCompletedLocator)
            if ($stageRoot -isnot [string] -or [string]::IsNullOrWhiteSpace($stageRoot)) { Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_TRANSACTION_ROOT_INVALID' 'The external uninstall transaction root is invalid' $stageRoot }
            $now = & $adapter.GetUtcNow
            if ($now -isnot [DateTime]) { Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_CLOCK_INVALID' 'The uninstall clock is invalid' $now }
            $transaction = New-CcodUninstallBootstrapTransaction -Context $context -TransactionId $transactionId -NowUtc $now
            & $adapter.WriteTransaction $stageRoot $transaction
            & $adapter.PublishTransaction $transactionRoot $transactionId $context.userSid ([bool]$replaceCompletedLocator)
            $stagePayload = $true
        } else {
            Assert-CcodUninstallBootstrapTransactionMatchesContext $transaction $context
            $stageRoot = & $adapter.GetTransactionDirectory $transactionRoot $transaction.transactionId
            if ($stageRoot -isnot [string] -or [string]::IsNullOrWhiteSpace($stageRoot)) { Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_TRANSACTION_ROOT_INVALID' 'The external uninstall transaction root is invalid' $stageRoot }
            $stagePayload = $transaction.phase -ceq 'Requested' -or ($transaction.phase -ceq 'Failed' -and $transaction.resumePhase -ceq 'Requested')
        }
        if ($stagePayload) { & $adapter.StagePayload $InstallerRoot $InstallRoot $context $stageRoot }
        $result = & $adapter.RunCleanup $InstallerRoot $InstallRoot $stageRoot $transaction $adapter.WriteTransaction
        if ($null -eq $result) { Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_PREPARE_FAILED' 'The staged cleanup returned no transaction receipt' $stageRoot }
        Assert-CcodUninstallBootstrapTransactionMatchesContext $result $context
        if ($result.phase -ne 'ReadyForInno') { Throw-CcodUninstallBootstrapError 'CCOD_UNINSTALL_PREPARE_FAILED' 'The staged cleanup did not reach the Inno boundary' $result }
        & $adapter.WriteReceipt $stageRoot $result
        return $result
    } catch {
        $code = Get-CcodUninstallBootstrapErrorId $_
        if ($code -notmatch '^CCOD_[A-Z0-9_]+$') { $code = 'CCOD_UNINSTALL_PREPARE_FAILED' }
        if ($null -ne $transaction) { Set-CcodUninstallBootstrapFailedTransaction -Transaction $transaction -Code $code -Adapters $adapter -TransactionRoot $stageRoot }
        if ((Get-CcodUninstallBootstrapErrorId $_) -ceq $code) { throw }
        Throw-CcodUninstallBootstrapError $code 'The uninstall bootstrap failed before Inno deletion' $stageRoot
    } finally {
        Exit-CcodUninstallBootstrapTransactionLock -Lock $transactionLock
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        $receipt = Invoke-CcodUninstallBootstrap -InstallerRoot $InstallerRoot -InstallRoot $InstallRoot -Mode $Mode
        if ($Mode -eq 'Prepare' -and $receipt.phase -ne 'ReadyForInno') { exit 3 }
        if ($Mode -eq 'FinalizeReceipt' -and $receipt.phase -ne 'Completed') { exit 3 }
        exit 0
    } catch {
        Write-Error ([string]$_.FullyQualifiedErrorId)
        exit 3
    }
}
