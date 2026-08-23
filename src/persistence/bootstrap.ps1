[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$InstallRoot = $PSScriptRoot,

    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string]$ReadyToken = '',

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 120)]
    [int]$ReadyTimeoutSeconds = 15
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Throw-CcodBootstrapError {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Message,
        $Target
    )

    throw [Management.Automation.ErrorRecord]::new(
        [InvalidOperationException]::new($Message),
        $Id,
        [Management.Automation.ErrorCategory]::InvalidData,
        $Target
    )
}

function Get-CcodBootstrapErrorId {
    param($ErrorRecord)

    return ([string]$ErrorRecord.FullyQualifiedErrorId -split ',')[0]
}

function Test-CcodBootstrapReparse {
    param([Parameter(Mandatory)][string]$Path)

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    return (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Assert-CcodBootstrapContained {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Path,
        [switch]$AllowMissingLeaf
    )

    $rootPrefix = $Root.TrimEnd('\') + '\'
    $candidate = [IO.Path]::GetFullPath($Path)
    if (-not $candidate.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        Throw-CcodBootstrapError 'CCOD_BOOTSTRAP_PATH_OUTSIDE_ROOT' 'Path escapes the install root' $candidate
    }
    $relative = $candidate.Substring($rootPrefix.Length)
    $cursor = $Root.TrimEnd('\')
    foreach ($segment in ($relative -split '\\' | Where-Object { $_.Length -gt 0 })) {
        $cursor = Join-Path $cursor $segment
        if (-not (Test-Path -LiteralPath $cursor)) {
            if ($AllowMissingLeaf) { break }
            Throw-CcodBootstrapError 'CCOD_BOOTSTRAP_PATH_MISSING' 'Required path is missing' $cursor
        }
        if (Test-CcodBootstrapReparse -Path $cursor) {
            Throw-CcodBootstrapError 'CCOD_BOOTSTRAP_REPARSE_PATH' 'Path contains a reparse point' $cursor
        }
    }
    return $candidate
}

function Get-CcodBootstrapCanonicalRoot {
    param([Parameter(Mandatory)][string]$InstallRoot)

    if ([string]::IsNullOrWhiteSpace($InstallRoot) -or -not [IO.Path]::IsPathRooted($InstallRoot)) {
        Throw-CcodBootstrapError 'CCOD_BOOTSTRAP_INPUT_INVALID' 'InstallRoot must be an absolute path' $InstallRoot
    }
    try {
        $root = [IO.Path]::GetFullPath($InstallRoot)
    } catch {
        Throw-CcodBootstrapError 'CCOD_BOOTSTRAP_INPUT_INVALID' 'InstallRoot could not be canonicalized' $InstallRoot
    }
    if (-not [IO.Directory]::Exists($root)) {
        Throw-CcodBootstrapError 'CCOD_BOOTSTRAP_INSTALL_MISSING' 'Install root does not exist' $root
    }
    if (Test-CcodBootstrapReparse -Path $root) {
        Throw-CcodBootstrapError 'CCOD_BOOTSTRAP_REPARSE_PATH' 'Install root is a reparse point' $root
    }
    return $root
}

function Read-CcodBootstrapJson {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Kind
    )

    if (-not [IO.File]::Exists($Path)) {
        Throw-CcodBootstrapError 'CCOD_BOOTSTRAP_STATE_MISSING' "$Kind is missing" $Path
    }
    $value = $null
    try {
        $value = ([IO.File]::ReadAllText($Path) | ConvertFrom-Json)
    } catch {
        Throw-CcodBootstrapError 'CCOD_BOOTSTRAP_STATE_MALFORMED' "$Kind is malformed" $Path
    }
    if ($null -eq $value -or ($value -isnot [pscustomobject] -and $value -isnot [Collections.IDictionary])) {
        Throw-CcodBootstrapError 'CCOD_BOOTSTRAP_STATE_MALFORMED' "$Kind must be a JSON object" $Path
    }
    return $value
}

function Assert-CcodBootstrapRuntimeId {
    param([Parameter(Mandatory)][string]$RuntimeId)

    if ($RuntimeId -cnotmatch '^[A-Za-z0-9._-]{1,96}$') {
        Throw-CcodBootstrapError 'CCOD_BOOTSTRAP_RUNTIME_ID_INVALID' 'Runtime ID is not a safe relative name' $RuntimeId
    }
    return $RuntimeId
}

function Read-CcodBootstrapActivePointer {
    param([Parameter(Mandatory)][string]$InstallRoot)

    $path = Assert-CcodBootstrapContained -Root $InstallRoot -Path (Join-Path $InstallRoot 'active.json') -AllowMissingLeaf
    $value = Read-CcodBootstrapJson -Path $path -Kind 'active.json'
    if ($null -eq $value.PSObject.Properties['schemaVersion'] -or $value.schemaVersion -isnot [int] -or $value.schemaVersion -notin @(1,2) -or
        $null -eq $value.PSObject.Properties['activeRuntime'] -or $value.activeRuntime -isnot [string] -or
        [string]::IsNullOrWhiteSpace($value.activeRuntime) -or
        $null -eq $value.PSObject.Properties['previousRuntime'] -or
        ($null -ne $value.previousRuntime -and $value.previousRuntime -isnot [string]) -or
        $null -eq $value.PSObject.Properties['updatedAtUtc'] -or $value.updatedAtUtc -isnot [string] -or
        [string]::IsNullOrWhiteSpace($value.updatedAtUtc)) {
        Throw-CcodBootstrapError 'CCOD_BOOTSTRAP_POINTER_INVALID' 'active.json is not a valid active runtime pointer' $path
    }
    [UInt64]$generation = 1
    if ($value.schemaVersion -eq 2) {
        if ($null -eq $value.PSObject.Properties['generation'] -or $value.generation -isnot [byte] -and $value.generation -isnot [uint16] -and $value.generation -isnot [uint32] -and $value.generation -isnot [uint64] -and $value.generation -isnot [int16] -and $value.generation -isnot [int32] -and $value.generation -isnot [int64] -and $value.generation -isnot [decimal]) {
            Throw-CcodBootstrapError 'CCOD_BOOTSTRAP_POINTER_INVALID' 'active.json has an invalid generation' $path
        }
        try { $generation = [UInt64]$value.generation } catch { Throw-CcodBootstrapError 'CCOD_BOOTSTRAP_POINTER_INVALID' 'active.json has an invalid generation' $path }
        if ($generation -eq 0 -or ($value.generation -is [decimal] -and [decimal]::Truncate($value.generation) -ne $value.generation)) {
            Throw-CcodBootstrapError 'CCOD_BOOTSTRAP_POINTER_INVALID' 'active.json has an invalid generation' $path
        }
    }
    Assert-CcodBootstrapRuntimeId -RuntimeId $value.activeRuntime | Out-Null
    if ($null -ne $value.previousRuntime -and -not [string]::IsNullOrWhiteSpace($value.previousRuntime)) {
        Assert-CcodBootstrapRuntimeId -RuntimeId $value.previousRuntime | Out-Null
    }
    return [pscustomobject]@{
        ActiveRuntime = [string]$value.activeRuntime
        PreviousRuntime = if ($null -eq $value.previousRuntime -or [string]::IsNullOrWhiteSpace($value.previousRuntime)) { $null } else { [string]$value.previousRuntime }
        SchemaVersion = [int]$value.schemaVersion
        Generation = $generation
    }
}

function Test-CcodBootstrapManifestPath {
    param([Parameter(Mandatory)][string]$Path)

    return -not (
        [IO.Path]::IsPathRooted($Path) -or
        $Path.StartsWith('/') -or
        $Path.IndexOf('\') -ge 0 -or
        $Path -match '(^|/)(\.|\.\.)(/|$)' -or
        $Path.Contains('//') -or
        [string]::IsNullOrWhiteSpace($Path)
    )
}

function Get-CcodBootstrapFileHash {
    param([Parameter(Mandatory)][string]$Path)

    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $stream = [IO.File]::OpenRead($Path)
        try {
            $bytes = $sha256.ComputeHash($stream)
        } finally {
            $stream.Dispose()
        }
    } finally {
        $sha256.Dispose()
    }
    return ([BitConverter]::ToString($bytes).Replace('-', '')).ToLowerInvariant()
}

function Get-CcodBootstrapFileRecords {
    param([Parameter(Mandatory)][string]$RuntimeDirectory)

    $records = [Collections.Generic.List[object]]::new()
    foreach ($item in Get-ChildItem -LiteralPath $RuntimeDirectory -Force -Recurse -ErrorAction Stop) {
        if (Test-CcodBootstrapReparse -Path $item.FullName) {
            Throw-CcodBootstrapError 'CCOD_BOOTSTRAP_REPARSE_PATH' 'Runtime contains a reparse point' $item.FullName
        }
        if (-not $item.PSIsContainer) {
            $relative = $item.FullName.Substring($RuntimeDirectory.TrimEnd('\').Length + 1).Replace('\', '/')
            if (-not $relative.Equals('manifest.json', [StringComparison]::OrdinalIgnoreCase)) {
                $records.Add([pscustomobject]@{
                    path = $relative
                    length = [int64]$item.Length
                    sha256 = Get-CcodBootstrapFileHash -Path $item.FullName
                })
            }
        }
    }
    $comparison = [Comparison[object]]{
        param($left, $right)
        return [StringComparer]::Ordinal.Compare([string]$left.path, [string]$right.path)
    }
    $records.Sort($comparison)
    return @($records)
}

function Get-CcodBootstrapRuntimeId {
    param(
        [Parameter(Mandatory)][string]$ProjectVersion,
        [Parameter(Mandatory)][object[]]$Files
    )

    $lines = [Collections.Generic.List[string]]::new()
    foreach ($file in $Files) {
        $lines.Add(('{0}`t{1}`t{2}' -f [string]$file.path, [int64]$file.length, [string]$file.sha256))
    }
    $canonical = $lines -join "`n"
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $digest = $sha256.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonical))
    } finally {
        $sha256.Dispose()
    }
    return ('{0}-{1}' -f $ProjectVersion, ([BitConverter]::ToString($digest).Replace('-', '')).ToLowerInvariant().Substring(0, 16))
}

function New-CcodBootstrapRuntimeValidation {
    param(
        [bool]$Valid,
        [Parameter(Mandatory)][string]$Code,
        [string]$RuntimeDirectory,
        [string]$SupervisorPath
    )

    return [pscustomobject]@{
        Valid = $Valid
        Code = $Code
        RuntimeDirectory = $RuntimeDirectory
        SupervisorPath = $SupervisorPath
    }
}

function Test-CcodBootstrapRuntime {
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$RuntimeId
    )

    try {
        Assert-CcodBootstrapRuntimeId -RuntimeId $RuntimeId | Out-Null
        $runtimeDirectory = Assert-CcodBootstrapContained -Root $InstallRoot -Path (Join-Path $InstallRoot ('runtime\' + $RuntimeId)) -AllowMissingLeaf
        if (-not [IO.Directory]::Exists($runtimeDirectory)) {
            return New-CcodBootstrapRuntimeValidation -Valid $false -Code 'CCOD_BOOTSTRAP_RUNTIME_MISSING' -RuntimeDirectory $null -SupervisorPath $null
        }
        $manifestPath = Assert-CcodBootstrapContained -Root $runtimeDirectory -Path (Join-Path $runtimeDirectory 'manifest.json') -AllowMissingLeaf
        if (-not [IO.File]::Exists($manifestPath)) {
            return New-CcodBootstrapRuntimeValidation -Valid $false -Code 'CCOD_BOOTSTRAP_MANIFEST_MISSING' -RuntimeDirectory $runtimeDirectory -SupervisorPath $null
        }
        $manifest = Read-CcodBootstrapJson -Path $manifestPath -Kind 'manifest.json'
        if ($null -eq $manifest.PSObject.Properties['schemaVersion'] -or $manifest.schemaVersion -isnot [int] -or $manifest.schemaVersion -ne 1 -or
            $null -eq $manifest.PSObject.Properties['runtimeId'] -or $manifest.runtimeId -isnot [string] -or
            $null -eq $manifest.PSObject.Properties['projectVersion'] -or $manifest.projectVersion -isnot [string] -or
            [string]::IsNullOrWhiteSpace($manifest.projectVersion) -or
            $null -eq $manifest.PSObject.Properties['files'] -or $null -eq $manifest.files) {
            return New-CcodBootstrapRuntimeValidation -Valid $false -Code 'CCOD_BOOTSTRAP_MANIFEST_INVALID' -RuntimeDirectory $runtimeDirectory -SupervisorPath $null
        }
        $manifestRuntimeId = [string]$manifest.runtimeId
        if ($manifestRuntimeId -cnotmatch '^[A-Za-z0-9._-]{1,96}$' -or $manifestRuntimeId -cne $RuntimeId) {
            return New-CcodBootstrapRuntimeValidation -Valid $false -Code 'CCOD_BOOTSTRAP_RUNTIME_ID_MISMATCH' -RuntimeDirectory $runtimeDirectory -SupervisorPath $null
        }

        $manifestFiles = @($manifest.files)
        $previousPath = $null
        $manifestRecords = [Collections.Generic.List[object]]::new()
        $manifestPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($file in $manifestFiles) {
            if ($file -isnot [pscustomobject] -or
                $null -eq $file.PSObject.Properties['path'] -or $file.path -isnot [string] -or
                $null -eq $file.PSObject.Properties['length'] -or
                $null -eq $file.PSObject.Properties['sha256'] -or $file.sha256 -isnot [string] -or
                -not (Test-CcodBootstrapManifestPath -Path $file.path) -or
                $file.path.Equals('manifest.json', [StringComparison]::OrdinalIgnoreCase) -or
                $file.sha256 -cnotmatch '^[0-9a-f]{64}$' -or
                -not $manifestPaths.Add([string]$file.path)) {
                return New-CcodBootstrapRuntimeValidation -Valid $false -Code 'CCOD_BOOTSTRAP_MANIFEST_INVALID' -RuntimeDirectory $runtimeDirectory -SupervisorPath $null
            }
            try {
                $length = [Convert]::ToInt64($file.length, [Globalization.CultureInfo]::InvariantCulture)
            } catch {
                return New-CcodBootstrapRuntimeValidation -Valid $false -Code 'CCOD_BOOTSTRAP_MANIFEST_INVALID' -RuntimeDirectory $runtimeDirectory -SupervisorPath $null
            }
            if ($length -lt 0 -or ($null -ne $previousPath -and [StringComparer]::Ordinal.Compare($previousPath, [string]$file.path) -ge 0)) {
                return New-CcodBootstrapRuntimeValidation -Valid $false -Code 'CCOD_BOOTSTRAP_MANIFEST_INVALID' -RuntimeDirectory $runtimeDirectory -SupervisorPath $null
            }
            $previousPath = [string]$file.path
            $manifestRecords.Add([pscustomobject]@{ path = [string]$file.path; length = $length; sha256 = [string]$file.sha256 })
        }

        $actualFiles = @(Get-CcodBootstrapFileRecords -RuntimeDirectory $runtimeDirectory)
        if ($manifestRecords.Count -ne $actualFiles.Count) {
            return New-CcodBootstrapRuntimeValidation -Valid $false -Code 'CCOD_BOOTSTRAP_FILE_SET_MISMATCH' -RuntimeDirectory $runtimeDirectory -SupervisorPath $null
        }
        for ($index = 0; $index -lt $actualFiles.Count; $index++) {
            $expected = $manifestRecords[$index]
            $actual = $actualFiles[$index]
            if ($expected.path -cne $actual.path -or $expected.length -ne $actual.length) {
                return New-CcodBootstrapRuntimeValidation -Valid $false -Code 'CCOD_BOOTSTRAP_FILE_SET_MISMATCH' -RuntimeDirectory $runtimeDirectory -SupervisorPath $null
            }
            if ($expected.sha256 -cne $actual.sha256) {
                return New-CcodBootstrapRuntimeValidation -Valid $false -Code 'CCOD_BOOTSTRAP_FILE_HASH_MISMATCH' -RuntimeDirectory $runtimeDirectory -SupervisorPath $null
            }
        }
        $computedRuntimeId = Get-CcodBootstrapRuntimeId -ProjectVersion ([string]$manifest.projectVersion) -Files $actualFiles
        $requiredRuntimeFiles = @('src/persistence/Supervisor.ps1')
        if ($computedRuntimeId -cne $manifestRuntimeId -or @($requiredRuntimeFiles | Where-Object { -not $manifestPaths.Contains($_) }).Count -ne 0) {
            return New-CcodBootstrapRuntimeValidation -Valid $false -Code 'CCOD_BOOTSTRAP_RUNTIME_ID_MISMATCH' -RuntimeDirectory $runtimeDirectory -SupervisorPath $null
        }
        $supervisorPath = Assert-CcodBootstrapContained -Root $runtimeDirectory -Path (Join-Path $runtimeDirectory 'src\persistence\Supervisor.ps1')
        if (-not [IO.File]::Exists($supervisorPath)) {
            return New-CcodBootstrapRuntimeValidation -Valid $false -Code 'CCOD_BOOTSTRAP_SUPERVISOR_MISSING' -RuntimeDirectory $runtimeDirectory -SupervisorPath $null
        }
        return New-CcodBootstrapRuntimeValidation -Valid $true -Code 'CCOD_BOOTSTRAP_RUNTIME_VALID' -RuntimeDirectory $runtimeDirectory -SupervisorPath $supervisorPath
    } catch {
        return New-CcodBootstrapRuntimeValidation -Valid $false -Code (Get-CcodBootstrapErrorId -ErrorRecord $_) -RuntimeDirectory $null -SupervisorPath $null
    }
}

function Import-CcodBootstrapKernelObjects {
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)]$Pointer
    )

    $candidates = @([string]$Pointer.ActiveRuntime)
    if ($null -ne $Pointer.PreviousRuntime -and $Pointer.PreviousRuntime -cne $Pointer.ActiveRuntime) {
        $candidates += [string]$Pointer.PreviousRuntime
    }

    foreach ($runtimeId in $candidates) {
        $validation = Test-CcodBootstrapRuntime -InstallRoot $InstallRoot -RuntimeId $runtimeId
        if (-not $validation.Valid) {
            Write-CcodBootstrapLog -InstallRoot $InstallRoot -Message ("Runtime {0} rejected while locating kernel objects: {1}" -f $runtimeId, $validation.Code)
            continue
        }
        $modulePath = Assert-CcodBootstrapContained -Root $validation.RuntimeDirectory -Path (Join-Path $validation.RuntimeDirectory 'src\persistence\modules\KernelObjects.psm1') -AllowMissingLeaf
        if (-not [IO.File]::Exists($modulePath)) { continue }
        try {
            return Import-Module -Name $modulePath -Force -PassThru -ErrorAction Stop
        } catch {
            Throw-CcodBootstrapError 'CCOD_BOOTSTRAP_KERNEL_IMPORT_FAILED' 'The verified runtime kernel-object module could not be loaded' $modulePath
        }
    }

    Throw-CcodBootstrapError 'CCOD_BOOTSTRAP_KERNEL_MISSING' 'No verified runtime contains the kernel-object module required for launch serialization' $InstallRoot
}

function Invoke-CcodBootstrapFencedPointerPromotion {
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)]$Pointer,
        [Parameter(Mandatory)]$Validation,
        [Parameter(Mandatory)][string]$NewRuntimeId,
        [Parameter(Mandatory)][string]$UserSid,
        [Parameter(Mandatory)][int]$SessionId
    )

    $runtimeDirectory = $Validation.RuntimeDirectory
    $lifecyclePath = Assert-CcodBootstrapContained -Root $runtimeDirectory -Path (Join-Path $runtimeDirectory 'src\persistence\modules\LifecycleEpoch.psm1')
    $manifestPath = Assert-CcodBootstrapContained -Root $runtimeDirectory -Path (Join-Path $runtimeDirectory 'src\persistence\modules\RuntimeManifest.psm1')
    if (-not [IO.File]::Exists($lifecyclePath) -or -not [IO.File]::Exists($manifestPath)) {
        Throw-CcodBootstrapError 'CCOD_BOOTSTRAP_FENCE_MODULE_MISSING' 'Verified fallback runtime is missing lifecycle fence modules' $runtimeDirectory
    }
    $lifecycleModule = $null
    $runtimeModule = $null
    $ownership = $null
    $process = [Diagnostics.Process]::GetCurrentProcess()
    try {
        $runtimeModule = Import-Module -Name $manifestPath -Force -PassThru -ErrorAction Stop
        $lifecycleModule = $runtimeModule.NestedModules | Where-Object { $null -ne $_.Path -and [IO.Path]::GetFullPath($_.Path) -ceq [IO.Path]::GetFullPath($lifecyclePath) } | Select-Object -First 1
        if ($null -eq $lifecycleModule) { Throw-CcodBootstrapError 'CCOD_BOOTSTRAP_FENCE_MODULE_MISSING' 'Verified runtime did not load its exact lifecycle fence module' $lifecyclePath }
        $ownerIdentity = [pscustomobject][ordered]@{ pid=[int]$process.Id; creationTimeUtc=$process.StartTime.ToUniversalTime().ToString('o') }
        $ownership = & $lifecycleModule {
            param($Root,$RuntimeId,$Generation,$Owner,$Sid,$Session)
            Enter-CcodLifecycleOwnership -InstallRoot $Root -RuntimeId $RuntimeId -RuntimeGeneration $Generation -OwnerIdentity $Owner -UserSid $Sid -SessionId $Session
        } $InstallRoot $Pointer.ActiveRuntime ([UInt64]$Pointer.Generation) $ownerIdentity $UserSid $SessionId
        return & $runtimeModule { param($Root,$RuntimeId,$Lease) Set-CcodActiveRuntime -InstallRoot $Root -NewRuntimeId $RuntimeId -Ownership $Lease } $InstallRoot $NewRuntimeId $ownership
    } catch {
        $fenceErrorId = Get-CcodBootstrapErrorId -ErrorRecord $_
        Throw-CcodBootstrapError 'CCOD_BOOTSTRAP_FENCE_FAILED' ("Verified fallback runtime could not prove lifecycle ownership before active pointer mutation: {0} {1}" -f $fenceErrorId, $_.Exception.Message) $runtimeDirectory
    } finally {
        if ($null -ne $ownership -and $null -ne $lifecycleModule) {
            try { & $lifecycleModule { param($Lease) Exit-CcodLifecycleOwnership -Ownership $Lease | Out-Null } $ownership } catch { }
        }
        $process.Dispose()
    }
}

function New-CcodBootstrapReadyToken {
    $bytes = [byte[]]::new(32)
    $generator = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $generator.GetBytes($bytes)
    } finally {
        $generator.Dispose()
    }
    return ([BitConverter]::ToString($bytes).Replace('-', '')).ToLowerInvariant()
}

function New-CcodBootstrapEventSecurity {
    param([Parameter(Mandatory)][string]$UserSid)

    $sid = [Security.Principal.SecurityIdentifier]::new($UserSid)
    $security = [Security.AccessControl.EventWaitHandleSecurity]::new()
    $security.SetOwner($sid)
    $security.SetAccessRuleProtection($true, $false)
    foreach ($identityValue in @($UserSid, 'S-1-5-18', 'S-1-5-32-544')) {
        $identity = [Security.Principal.SecurityIdentifier]::new($identityValue)
        $rule = [Security.AccessControl.EventWaitHandleAccessRule]::new(
            $identity,
            [Security.AccessControl.EventWaitHandleRights]::FullControl,
            [Security.AccessControl.AccessControlType]::Allow
        )
        [void]$security.AddAccessRule($rule)
    }
    return $security
}

function New-CcodBootstrapReadyEvent {
    param(
        [Parameter(Mandatory)][string]$UserSid,
        [Parameter(Mandatory)][int]$SessionId,
        [Parameter(Mandatory)][string]$Token
    )

    $name = "Local\CodexControlOtherDevices.Ready.$UserSid.$SessionId.$Token"
    if ($name.Length -gt 260) {
        Throw-CcodBootstrapError 'CCOD_BOOTSTRAP_INPUT_INVALID' 'Ready event name exceeds the kernel-object limit' $name
    }
    $security = New-CcodBootstrapEventSecurity -UserSid $UserSid
    $created = $false
    $handle = $null
    try {
        $handle = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, $name, [ref]$created, $security)
    } catch {
        if ($null -ne $handle) { $handle.Dispose() }
        Throw-CcodBootstrapError 'CCOD_BOOTSTRAP_READY_EVENT_FAILED' 'The one-time ready event could not be created' $name
    }
    return [pscustomobject][ordered]@{
        Name = $name
        Handle = $handle
        CreatedNew = [bool]$created
    }
}

function Get-CcodBootstrapPowerShellPath {
    return [IO.Path]::GetFullPath((Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'))
}

function Start-CcodBootstrapSupervisor {
    param(
        [Parameter(Mandatory)][string]$SupervisorPath,
        [Parameter(Mandatory)][string]$ReadyToken,
        [Parameter(Mandatory)][string]$WorkingDirectory
    )

    $powershell = Get-CcodBootstrapPowerShellPath
    $arguments = '-NoProfile -ExecutionPolicy Bypass -STA -File "' + $SupervisorPath + '" -ReadyToken ' + $ReadyToken
    try {
        return Start-Process -FilePath $powershell -ArgumentList $arguments -WindowStyle Hidden -WorkingDirectory $WorkingDirectory -PassThru
    } catch {
        Throw-CcodBootstrapError 'CCOD_BOOTSTRAP_LAUNCH_FAILED' 'The runtime supervisor could not be launched' $SupervisorPath
    }
}

function Wait-CcodBootstrapReady {
    param(
        $Event,
        $Process,
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $timeoutMilliseconds = [long]$TimeoutSeconds * 1000
    while ($stopwatch.ElapsedMilliseconds -lt $timeoutMilliseconds) {
        if ($Process.HasExited) { return 'ChildExited' }
        if ($Event.Handle.WaitOne(100)) { return 'Ready' }
    }
    return 'Timeout'
}

function Wait-CcodBootstrapChild {
    param($Process)

    if (-not $Process.HasExited) { $Process.WaitForExit() }
    return [int]$Process.ExitCode
}

function Stop-CcodBootstrapChild {
    param($Process)

    if ($null -eq $Process) { return }
    try {
        if (-not $Process.HasExited) { $Process.Kill() }
        $Process.WaitForExit()
    } catch {
    }
    $Process.Dispose()
}

function Initialize-CcodBootstrapAtomicFile {
    if ($null -ne ('CcodBootstrapAtomicFile' -as [type])) { return }

    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

public static class CcodBootstrapAtomicFile
{
    private const uint GenericWrite = 0x40000000U;
    private const uint Delete = 0x00010000U;
    private const uint CreateNew = 1U;
    private const uint FileAttributeNormal = 0x00000080U;
    private const uint FileFlagWriteThrough = 0x80000000U;
    private const int FileRenameInfo = 3;

    [DllImport("kernel32.dll", EntryPoint = "CreateFileW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFile(
        string fileName,
        uint desiredAccess,
        uint shareMode,
        IntPtr securityAttributes,
        uint creationDisposition,
        uint flagsAndAttributes,
        IntPtr templateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetFileInformationByHandle(
        SafeFileHandle file,
        int fileInformationClass,
        IntPtr fileInformation,
        uint bufferSize);

    public static FileStream CreateNewFile(string path)
    {
        SafeFileHandle handle = CreateFile(
            path,
            GenericWrite | Delete,
            0,
            IntPtr.Zero,
            CreateNew,
            FileAttributeNormal | FileFlagWriteThrough,
            IntPtr.Zero);

        if (handle.IsInvalid)
        {
            int errorCode = Marshal.GetLastWin32Error();
            handle.Dispose();
            throw new IOException("Could not create an owned atomic file", new Win32Exception(errorCode));
        }

        try
        {
            return new FileStream(handle, FileAccess.Write, 4096, false);
        }
        catch
        {
            handle.Dispose();
            throw;
        }
    }

    public static int MoveFileByHandle(SafeFileHandle source, string destination)
    {
        string fullPath = Path.GetFullPath(destination);
        string nativePath = fullPath.StartsWith(@"\\", StringComparison.Ordinal)
            ? @"\??\UNC\" + fullPath.Substring(2)
            : @"\??\" + fullPath;
        byte[] name = Encoding.Unicode.GetBytes(nativePath);
        int rootDirectoryOffset = IntPtr.Size;
        int fileNameLengthOffset = rootDirectoryOffset + IntPtr.Size;
        int fileNameOffset = fileNameLengthOffset + sizeof(uint);
        int bufferSize = checked(fileNameOffset + name.Length + sizeof(char));
        IntPtr buffer = Marshal.AllocHGlobal(bufferSize);

        try
        {
            for (int index = 0; index < bufferSize; index++)
            {
                Marshal.WriteByte(buffer, index, 0);
            }
            Marshal.WriteByte(buffer, 0, 1);
            Marshal.WriteIntPtr(buffer, rootDirectoryOffset, IntPtr.Zero);
            Marshal.WriteInt32(buffer, fileNameLengthOffset, name.Length);
            Marshal.Copy(name, 0, IntPtr.Add(buffer, fileNameOffset), name.Length);

            return SetFileInformationByHandle(source, FileRenameInfo, buffer, (uint)bufferSize)
                ? 0
                : Marshal.GetLastWin32Error();
        }
        finally
        {
            Marshal.FreeHGlobal(buffer);
        }
    }
}
'@
}

function Write-CcodBootstrapAtomicJson {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Value
    )

    Initialize-CcodBootstrapAtomicFile
    $directory = Split-Path $Path -Parent
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $json = ($Value | ConvertTo-Json -Depth 16) + "`n"
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
    $temporary = $null
    $stream = $null
    try {
        for ($attempt = 0; $attempt -lt 32; $attempt++) {
            $leaf = [IO.Path]::GetRandomFileName()
            $candidate = Join-Path $directory $leaf
            try {
                $stream = [CcodBootstrapAtomicFile]::CreateNewFile($candidate)
                $temporary = $candidate
                break
            } catch [IO.IOException] {
                continue
            }
        }
        if ($null -eq $stream) {
            Throw-CcodBootstrapError 'CCOD_BOOTSTRAP_ATOMIC_FAILED' 'Could not claim an atomic sibling file' $Path
        }
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
        $errorCode = [CcodBootstrapAtomicFile]::MoveFileByHandle($stream.SafeFileHandle, $Path)
        if ($errorCode -ne 0) {
            Throw-CcodBootstrapError 'CCOD_BOOTSTRAP_ATOMIC_FAILED' ("Native atomic commit failed with Windows error {0}" -f $errorCode) $Path
        }
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
        if ($null -ne $temporary -and [IO.File]::Exists($temporary)) {
            try { [IO.File]::Delete($temporary) } catch { }
        }
    }
}

function Write-CcodBootstrapLog {
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$Message
    )

    try {
        $logDirectory = Join-Path $InstallRoot 'logs'
        [IO.Directory]::CreateDirectory($logDirectory) | Out-Null
        $record = [ordered]@{
            timestampUtc = [DateTime]::UtcNow.ToString('o')
            message = $Message
        }
        [IO.File]::AppendAllText(
            (Join-Path $logDirectory 'bootstrap.log'),
            (($record | ConvertTo-Json -Depth 4 -Compress) + "`n"),
            [Text.UTF8Encoding]::new($false)
        )
    } catch {
    }
}

$exitCode = 1
$root = $null
$readyEvent = $null
$child = $null
$launchLease = $null
$kernelModule = $null
$identity = $null
$currentProcess = $null
try {
    $root = Get-CcodBootstrapCanonicalRoot -InstallRoot $InstallRoot
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $userSid = [string]$identity.User.Value
    $currentProcess = [Diagnostics.Process]::GetCurrentProcess()
    $sessionId = [int]$currentProcess.SessionId

    $token = $ReadyToken
    if ([string]::IsNullOrWhiteSpace($token)) { $token = New-CcodBootstrapReadyToken }
    if ($token -cnotmatch '^[0-9a-f]{64}$') {
        Throw-CcodBootstrapError 'CCOD_BOOTSTRAP_INPUT_INVALID' 'ReadyToken must be 64 lowercase hex characters' $token
    }

    $initialPointer = Read-CcodBootstrapActivePointer -InstallRoot $root
    $kernelModule = Import-CcodBootstrapKernelObjects -InstallRoot $root -Pointer $initialPointer
    $launchLease = & $kernelModule { param($Sid,$Timeout) Enter-CcodMutex -Kind 'AccountTransition' -UserSid $Sid -TimeoutMilliseconds $Timeout } $userSid ([int]($ReadyTimeoutSeconds * 1000))
    if ($launchLease.Outcome -cne 'Acquired') {
        Throw-CcodBootstrapError 'CCOD_BOOTSTRAP_LAUNCH_BUSY' 'An installation transition is in progress; bootstrap will retry through the scheduled task' $root
    }

    $readyEvent = New-CcodBootstrapReadyEvent -UserSid $userSid -SessionId $sessionId -Token $token
    if (-not $readyEvent.CreatedNew) {
        Throw-CcodBootstrapError 'CCOD_BOOTSTRAP_READY_EVENT_EXISTS' 'A stale ready event already exists; bootstrap refuses to reuse it' $readyEvent.Name
    }

    $pointer = Read-CcodBootstrapActivePointer -InstallRoot $root
    $candidates = @($pointer.ActiveRuntime)
    if ($null -ne $pointer.PreviousRuntime -and $pointer.PreviousRuntime -cne $pointer.ActiveRuntime) {
        $candidates += $pointer.PreviousRuntime
    }

    foreach ($runtimeId in $candidates) {
        if ($null -ne $child) {
            Stop-CcodBootstrapChild -Process $child
            $child = $null
        }
        $validation = Test-CcodBootstrapRuntime -InstallRoot $root -RuntimeId $runtimeId
        if (-not $validation.Valid) {
            Write-CcodBootstrapLog -InstallRoot $root -Message ("Runtime {0} rejected before launch: {1}" -f $runtimeId, $validation.Code)
            continue
        }

        $child = Start-CcodBootstrapSupervisor -SupervisorPath $validation.SupervisorPath -ReadyToken $token -WorkingDirectory $root
        $outcome = Wait-CcodBootstrapReady -Event $readyEvent -Process $child -TimeoutSeconds $ReadyTimeoutSeconds
        if ($outcome -ceq 'Ready') {
            if ($runtimeId -cne $pointer.ActiveRuntime) {
                $updated = Invoke-CcodBootstrapFencedPointerPromotion -InstallRoot $root -Pointer $pointer -Validation $validation -NewRuntimeId $runtimeId -UserSid $userSid -SessionId $sessionId
                Write-CcodBootstrapLog -InstallRoot $root -Message ("Runtime {0} signaled ready; active pointer switched from {1}" -f $runtimeId, $pointer.ActiveRuntime)
            }
            $released = & $kernelModule { param($Lease) Exit-CcodMutex -Lease $Lease } $launchLease
            if ($released -isnot [bool] -or -not $released) {
                Throw-CcodBootstrapError 'CCOD_BOOTSTRAP_LAUNCH_RELEASE_FAILED' 'The launch serialization lease could not be released after Supervisor readiness' $root
            }
            $exitCode = Wait-CcodBootstrapChild -Process $child
            Write-CcodBootstrapLog -InstallRoot $root -Message ("Runtime {0} exited after readiness with code {1}" -f $runtimeId, $exitCode)
            $child = $null
            break
        }

        if ($outcome -ceq 'Timeout') {
            Write-CcodBootstrapLog -InstallRoot $root -Message ("Runtime {0} did not signal ready within {1} seconds" -f $runtimeId, $ReadyTimeoutSeconds)
        } else {
            Write-CcodBootstrapLog -InstallRoot $root -Message ("Runtime {0} exited before signaling ready" -f $runtimeId)
        }
        $childExitCode = [int]$child.ExitCode
        Stop-CcodBootstrapChild -Process $child
        Write-CcodBootstrapLog -InstallRoot $root -Message ("Runtime {0} exited before readiness with code {1}" -f $runtimeId, $childExitCode)
        $child = $null
    }

    if ($null -ne $child) {
        $exitCode = Wait-CcodBootstrapChild -Process $child
        $child = $null
    }
    if ($exitCode -eq 1) {
        Write-CcodBootstrapLog -InstallRoot $root -Message 'No verified runtime signaled ready; bootstrap failed closed'
    }
} catch {
    $errorId = Get-CcodBootstrapErrorId -ErrorRecord $_
    if ($null -ne $root) {
        Write-CcodBootstrapLog -InstallRoot $root -Message ("Bootstrap failed: {0} {1}" -f $errorId, $_.Exception.Message)
    }
    $exitCode = 1
} finally {
    if ($null -ne $child) {
        try { Stop-CcodBootstrapChild -Process $child } catch { }
        $child = $null
    }
    if ($null -ne $readyEvent -and $null -ne $readyEvent.Handle) {
        try { $readyEvent.Handle.Dispose() } catch { }
    }
    if ($null -ne $launchLease -and $launchLease.Outcome -ceq 'Acquired' -and -not $launchLease.Released) {
        try { & $kernelModule { param($Lease) Exit-CcodMutex -Lease $Lease | Out-Null } $launchLease } catch { }
    }
    if ($null -ne $currentProcess) { $currentProcess.Dispose() }
    if ($null -ne $identity) { $identity.Dispose() }
}

exit $exitCode
