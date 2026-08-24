Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'PersistenceIO.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'KernelObjects.psm1') -Force

$script:CcodLifecycleEpochProperties = @('schemaVersion','epoch')
$script:CcodLifecycleOwnershipProperties = @('schemaVersion','lease','epoch','runtimeId','runtimeGeneration','ownerIdentity','released')

function Throw-CcodLifecycleEpochError {
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$Message, $Target)

    throw [Management.Automation.ErrorRecord]::new(
        [InvalidOperationException]::new($Message), $Id, [Management.Automation.ErrorCategory]::InvalidData, $Target)
}

function Get-CcodLifecycleEpochErrorId {
    param($ErrorRecord)

    if ($null -eq $ErrorRecord -or $ErrorRecord.FullyQualifiedErrorId -isnot [string]) { return $null }
    return ([string]$ErrorRecord.FullyQualifiedErrorId -split ',')[0]
}

function Get-CcodLifecycleEpochPath {
    param([Parameter(Mandatory)][string]$InstallRoot)

    return Resolve-CcodContainedPath -Root $InstallRoot -RelativePath 'state\lifecycle-epoch.json' -AllowMissingLeaf
}

function Get-CcodLifecycleEpochInitializationPath {
    param([Parameter(Mandatory)][string]$InstallRoot)

    return Resolve-CcodContainedPath -Root $InstallRoot -RelativePath 'state\lifecycle-epoch.initialized.json' -AllowMissingLeaf
}

function Get-CcodLifecycleEpochPropertyNames {
    param($Value)

    if ($Value -is [Collections.IDictionary]) { return @($Value.Keys | ForEach-Object { [string]$_ }) }
    if ($null -eq $Value) { return @() }
    return @($Value.PSObject.Properties | ForEach-Object { $_.Name })
}

function Assert-CcodLifecycleEpochExactProperties {
    param([Parameter(Mandatory)]$Value, [Parameter(Mandatory)][string[]]$Expected, [Parameter(Mandatory)][string]$Kind)

    if ($Value -isnot [pscustomobject] -and $Value -isnot [Collections.IDictionary]) {
        Throw-CcodLifecycleEpochError 'CCOD_LIFECYCLE_EPOCH_INVALID' "$Kind must be an object" $Value
    }
    $actual = @(Get-CcodLifecycleEpochPropertyNames -Value $Value)
    if ($actual.Count -ne $Expected.Count -or ($actual -join "`0") -cne ($Expected -join "`0")) {
        Throw-CcodLifecycleEpochError 'CCOD_LIFECYCLE_EPOCH_INVALID' "$Kind has unexpected, missing, or reordered fields" $Value
    }
    foreach ($property in @($Value.PSObject.Properties)) {
        if ($property.MemberType -notin @('NoteProperty','Property')) {
            Throw-CcodLifecycleEpochError 'CCOD_LIFECYCLE_EPOCH_INVALID' "$Kind contains a non-data property" $Value
        }
    }
}

function ConvertTo-CcodLifecycleEpochUInt64 {
    param([Parameter(Mandatory)]$Value, [Parameter(Mandatory)][string]$Name, [switch]$AllowZero)

    if ($Value -is [decimal]) {
        if ($Value -lt 0 -or [decimal]::Truncate($Value) -ne $Value) {
            Throw-CcodLifecycleEpochError 'CCOD_LIFECYCLE_EPOCH_INVALID' "$Name must be an unsigned 64-bit integer" $Value
        }
        try { return [UInt64]$Value } catch { Throw-CcodLifecycleEpochError 'CCOD_LIFECYCLE_EPOCH_INVALID' "$Name is outside the unsigned 64-bit range" $Value }
    }
    if ($Value -isnot [byte] -and $Value -isnot [uint16] -and $Value -isnot [uint32] -and $Value -isnot [uint64] -and
        $Value -isnot [int16] -and $Value -isnot [int32] -and $Value -isnot [int64]) {
        Throw-CcodLifecycleEpochError 'CCOD_LIFECYCLE_EPOCH_INVALID' "$Name must be an unsigned 64-bit integer" $Value
    }
    if ($Value -lt 0 -or (-not $AllowZero -and $Value -eq 0)) {
        Throw-CcodLifecycleEpochError 'CCOD_LIFECYCLE_EPOCH_INVALID' "$Name must be a positive unsigned 64-bit integer" $Value
    }
    try { return [UInt64]$Value } catch { Throw-CcodLifecycleEpochError 'CCOD_LIFECYCLE_EPOCH_INVALID' "$Name is outside the unsigned 64-bit range" $Value }
}

function Assert-CcodLifecycleEpochRuntimeId {
    param([Parameter(Mandatory)]$Value)

    if ($Value -isnot [string] -or $Value -cnotmatch '^[A-Za-z0-9._-]{1,96}$') {
        Throw-CcodLifecycleEpochError 'CCOD_LIFECYCLE_FENCE_STALE' 'Lifecycle ownership runtime ID is invalid' $Value
    }
}

function Assert-CcodLifecycleEpochOwnerIdentity {
    param([Parameter(Mandatory)]$OwnerIdentity)

    Assert-CcodLifecycleEpochExactProperties -Value $OwnerIdentity -Expected @('pid','creationTimeUtc') -Kind 'Lifecycle owner identity'
    $pid = ConvertTo-CcodLifecycleEpochUInt64 -Value $OwnerIdentity.pid -Name 'ownerIdentity.pid'
    if ($pid -gt [int]::MaxValue) { Throw-CcodLifecycleEpochError 'CCOD_LIFECYCLE_EPOCH_INVALID' 'ownerIdentity.pid exceeds the legal process range' $OwnerIdentity }
    if ($OwnerIdentity.creationTimeUtc -isnot [string]) { Throw-CcodLifecycleEpochError 'CCOD_LIFECYCLE_EPOCH_INVALID' 'ownerIdentity.creationTimeUtc must be canonical UTC' $OwnerIdentity }
    $parsed = [DateTime]::MinValue
    if (-not [DateTime]::TryParseExact($OwnerIdentity.creationTimeUtc, 'o', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed) -or
        $parsed.Kind -ne [DateTimeKind]::Utc -or $parsed.ToUniversalTime().ToString('o') -cne $OwnerIdentity.creationTimeUtc) {
        Throw-CcodLifecycleEpochError 'CCOD_LIFECYCLE_EPOCH_INVALID' 'ownerIdentity.creationTimeUtc must be canonical UTC' $OwnerIdentity
    }
}

function Get-CcodLifecycleEpochFileSecurity {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        if ($null -eq $identity.User) { Throw-CcodLifecycleEpochError 'CCOD_LIFECYCLE_EPOCH_ACL_INVALID' 'Current user SID is unavailable for lifecycle epoch state' $null }
        $security = [Security.AccessControl.FileSecurity]::new()
        $security.SetOwner($identity.User)
        $security.SetAccessRuleProtection($true, $false)
        foreach ($sidValue in @($identity.User.Value, 'S-1-5-18', 'S-1-5-32-544')) {
            $sid = [Security.Principal.SecurityIdentifier]::new($sidValue)
            $rule = [Security.AccessControl.FileSystemAccessRule]::new($sid, [Security.AccessControl.FileSystemRights]::FullControl, [Security.AccessControl.AccessControlType]::Allow)
            [void]$security.AddAccessRule($rule)
        }
        return $security
    } finally { $identity.Dispose() }
}

function Assert-CcodLifecycleEpochFileAcl {
    param([Parameter(Mandatory)][string]$Path)

    if (-not [IO.File]::Exists($Path)) { return }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $security = [IO.File]::GetAccessControl($Path)
        $rules = @($security.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
        $owner = $security.GetOwner([Security.Principal.SecurityIdentifier])
        if ($null -eq $identity.User -or $null -eq $owner -or $owner.Value -cne $identity.User.Value -or -not $security.AreAccessRulesProtected -or $rules.Count -ne 3) {
            Throw-CcodLifecycleEpochError 'CCOD_LIFECYCLE_EPOCH_ACL_INVALID' 'Lifecycle epoch file ACL is not the required protected current-user ACL' $Path
        }
        $expected = @($identity.User.Value, 'S-1-5-18', 'S-1-5-32-544')
        foreach ($rule in $rules) {
            if ($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or $rule.IsInherited -or
                $rule.FileSystemRights -ne [Security.AccessControl.FileSystemRights]::FullControl -or $expected -cnotcontains $rule.IdentityReference.Value) {
                Throw-CcodLifecycleEpochError 'CCOD_LIFECYCLE_EPOCH_ACL_INVALID' 'Lifecycle epoch file ACL is not the required protected current-user ACL' $Path
            }
        }
    } catch {
        if ((Get-CcodLifecycleEpochErrorId $_) -ceq 'CCOD_LIFECYCLE_EPOCH_ACL_INVALID') { throw }
        Throw-CcodLifecycleEpochError 'CCOD_LIFECYCLE_EPOCH_ACL_INVALID' 'Lifecycle epoch file ACL could not be proven' $Path
    } finally { $identity.Dispose() }
}

function New-CcodLifecycleEpochSecureFile {
    param([Parameter(Mandatory)][string]$Path)

    return [IO.FileStream]::new(
        $Path,
        [IO.FileMode]::CreateNew,
        [Security.AccessControl.FileSystemRights]::FullControl,
        [IO.FileShare]::None,
        4096,
        [IO.FileOptions]::WriteThrough,
        (Get-CcodLifecycleEpochFileSecurity))
}

function Get-CcodLifecycleEpochAdapters {
    param([hashtable]$Adapters)

    $resolved = @{
        ReadEpoch = {
            param($InstallRoot, $AllowInitial)
            $path = Get-CcodLifecycleEpochPath -InstallRoot $InstallRoot
            $initializationPath = Get-CcodLifecycleEpochInitializationPath -InstallRoot $InstallRoot
            if (-not [IO.File]::Exists($path)) {
                if ($AllowInitial -and -not [IO.File]::Exists($initializationPath)) { return $null }
                Throw-CcodLifecycleEpochError 'CCOD_LIFECYCLE_EPOCH_INVALID' 'Lifecycle epoch is missing after initialization' $path
            }
            try {
                $json = [IO.File]::ReadAllText($path, [Text.UTF8Encoding]::new($false))
                if ($json -notmatch '(?s)^\s*\{\s*"schemaVersion"\s*:\s*1\s*,\s*"epoch"\s*:\s*(?:0|[1-9][0-9]*)\s*\}\s*$') {
                    Throw-CcodLifecycleEpochError 'CCOD_LIFECYCLE_EPOCH_INVALID' 'Lifecycle epoch must contain one canonical unsigned integer' $path
                }
                return Read-CcodStrictJson -Path $path -ExpectedSchema 1 -Kind 'lifecycle epoch'
            }
            catch { Throw-CcodLifecycleEpochError 'CCOD_LIFECYCLE_EPOCH_INVALID' 'Lifecycle epoch is malformed or unsupported' $path }
        }
        WriteEpoch = {
            param($InstallRoot, $Epoch, $CreateEpochFile)
            $path = Get-CcodLifecycleEpochPath -InstallRoot $InstallRoot
            $initializationPath = Get-CcodLifecycleEpochInitializationPath -InstallRoot $InstallRoot
            $atomicAdapters = @{ CreateNewFile = $CreateEpochFile }
            if (-not [IO.File]::Exists($initializationPath)) {
                Write-CcodAtomicJson -Path $initializationPath -Value ([ordered]@{ schemaVersion = 1 }) -Adapters $atomicAdapters
            }
            Write-CcodAtomicJson -Path $path -Value ([ordered]@{ schemaVersion = 1; epoch = [UInt64]$Epoch }) -Adapters $atomicAdapters
        }
        AssertEpochFileAcl = { param($Path) Assert-CcodLifecycleEpochFileAcl -Path $Path }
        CreateEpochFile = { param($Path) New-CcodLifecycleEpochSecureFile -Path $Path }
        ReadActiveRuntime = {
            param($InstallRoot)
            $runtimePath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'RuntimeManifest.psm1'))
            $runtimeModule = Get-Module | Where-Object { $null -ne $_.Path -and [IO.Path]::GetFullPath($_.Path) -ceq $runtimePath } | Select-Object -First 1
            if ($null -eq $runtimeModule) {
                try { $runtimeModule = Import-Module -Name $runtimePath -PassThru -ErrorAction Stop }
                catch { Throw-CcodLifecycleEpochError 'CCOD_LIFECYCLE_FENCE_STALE' 'The exact runtime manifest module is unavailable for lifecycle fencing' $InstallRoot }
            }
            return & $runtimeModule { param($Root) Read-CcodActiveRuntime -InstallRoot $Root } $InstallRoot
        }
        GetProcessIdentity = {
            param($Pid)
            $process = $null
            try {
                $process = [Diagnostics.Process]::GetProcessById([int]$Pid)
                return [pscustomobject][ordered]@{ pid = [int]$process.Id; creationTimeUtc = $process.StartTime.ToUniversalTime().ToString('o') }
            } catch { return $null }
            finally { if ($null -ne $process) { $process.Dispose() } }
        }
        EnterMutex = { param($UserSid, $SessionId, $TimeoutMilliseconds) Enter-CcodMutex -Kind AccountTransition -UserSid $UserSid -TimeoutMilliseconds $TimeoutMilliseconds }
        ExitMutex = { param($Lease) Exit-CcodMutex -Lease $Lease }
    }
    if ($null -ne $Adapters) {
        if ($Adapters -isnot [hashtable]) { Throw-CcodLifecycleEpochError 'CCOD_LIFECYCLE_EPOCH_INVALID' 'Lifecycle epoch adapters must be a hashtable' $Adapters }
        foreach ($key in $Adapters.Keys) {
            if (-not $resolved.ContainsKey($key) -or $Adapters[$key] -isnot [scriptblock]) {
                Throw-CcodLifecycleEpochError 'CCOD_LIFECYCLE_EPOCH_INVALID' 'Lifecycle epoch adapters are invalid' $key
            }
            $resolved[$key] = $Adapters[$key]
        }
    }
    return $resolved
}

function Read-CcodLifecycleEpoch {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$InstallRoot, [switch]$AllowInitial, [hashtable]$Adapters)

    $resolved = Get-CcodLifecycleEpochAdapters -Adapters $Adapters
    $epochPath = Get-CcodLifecycleEpochPath -InstallRoot $InstallRoot
    $initializationPath = Get-CcodLifecycleEpochInitializationPath -InstallRoot $InstallRoot
    foreach ($path in @($initializationPath, $epochPath)) {
        if (-not [IO.File]::Exists($path)) { continue }
        try { & $resolved.AssertEpochFileAcl $path }
        catch { Throw-CcodLifecycleEpochError 'CCOD_LIFECYCLE_EPOCH_ACL_INVALID' 'Lifecycle epoch ACL proof failed' $InstallRoot }
    }
    try { $raw = & $resolved.ReadEpoch $InstallRoot ([bool]$AllowInitial) }
    catch {
        if ((Get-CcodLifecycleEpochErrorId $_) -like 'CCOD_LIFECYCLE_EPOCH_*') { throw }
        Throw-CcodLifecycleEpochError 'CCOD_LIFECYCLE_EPOCH_INVALID' 'Lifecycle epoch could not be read safely' $InstallRoot
    }
    if ($null -eq $raw) {
        if ($AllowInitial) { return [UInt64]0 }
        Throw-CcodLifecycleEpochError 'CCOD_LIFECYCLE_EPOCH_INVALID' 'Lifecycle epoch is missing after initialization' $InstallRoot
    }
    if ($raw -is [pscustomobject] -or $raw -is [Collections.IDictionary]) {
        Assert-CcodLifecycleEpochExactProperties -Value $raw -Expected $script:CcodLifecycleEpochProperties -Kind 'Lifecycle epoch'
        return ConvertTo-CcodLifecycleEpochUInt64 -Value $raw.epoch -Name 'epoch' -AllowZero
    }
    return ConvertTo-CcodLifecycleEpochUInt64 -Value $raw -Name 'epoch' -AllowZero
}

function Write-CcodLifecycleEpoch {
    param([Parameter(Mandatory)][string]$InstallRoot, [Parameter(Mandatory)][UInt64]$Epoch, [hashtable]$Adapters)

    $resolved = Get-CcodLifecycleEpochAdapters -Adapters $Adapters
    try {
        & $resolved.WriteEpoch $InstallRoot $Epoch $resolved.CreateEpochFile
        & $resolved.AssertEpochFileAcl (Get-CcodLifecycleEpochInitializationPath -InstallRoot $InstallRoot)
        & $resolved.AssertEpochFileAcl (Get-CcodLifecycleEpochPath -InstallRoot $InstallRoot)
    } catch {
        if ((Get-CcodLifecycleEpochErrorId $_) -ceq 'CCOD_LIFECYCLE_EPOCH_ACL_INVALID') { throw }
        Throw-CcodLifecycleEpochError 'CCOD_LIFECYCLE_EPOCH_WRITE_FAILED' 'Lifecycle epoch could not be persisted atomically' $InstallRoot
    }
}

function Assert-CcodLifecycleOwnershipReceipt {
    param([Parameter(Mandatory)]$Ownership)

    Assert-CcodLifecycleEpochExactProperties -Value $Ownership -Expected $script:CcodLifecycleOwnershipProperties -Kind 'Lifecycle ownership receipt'
    if ($Ownership.schemaVersion -isnot [int] -and $Ownership.schemaVersion -isnot [int64] -or $Ownership.schemaVersion -ne 1 -or $Ownership.released -isnot [bool]) {
        Throw-CcodLifecycleEpochError 'CCOD_LIFECYCLE_FENCE_STALE' 'Lifecycle ownership receipt is invalid' $Ownership
    }
    [void](ConvertTo-CcodLifecycleEpochUInt64 -Value $Ownership.epoch -Name 'ownership.epoch')
    [void](ConvertTo-CcodLifecycleEpochUInt64 -Value $Ownership.runtimeGeneration -Name 'ownership.runtimeGeneration')
    Assert-CcodLifecycleEpochRuntimeId -Value $Ownership.runtimeId
    Assert-CcodLifecycleEpochOwnerIdentity -OwnerIdentity $Ownership.ownerIdentity
    if ($null -eq $Ownership.lease) { Throw-CcodLifecycleEpochError 'CCOD_LIFECYCLE_FENCE_STALE' 'Lifecycle ownership lease is missing' $Ownership }
}

function Enter-CcodLifecycleOwnership {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$RuntimeId,
        [Parameter(Mandatory)][UInt64]$RuntimeGeneration,
        [Parameter(Mandatory)]$OwnerIdentity,
        [Parameter(Mandatory)][string]$UserSid,
        [Parameter(Mandatory)][int]$SessionId,
        [int]$TimeoutMilliseconds = 15000,
        [hashtable]$Adapters
    )

    Assert-CcodLifecycleEpochRuntimeId -Value $RuntimeId
    if ($RuntimeGeneration -eq 0) { Throw-CcodLifecycleEpochError 'CCOD_LIFECYCLE_EPOCH_INVALID' 'Lifecycle runtime generation must be positive' $RuntimeGeneration }
    Assert-CcodLifecycleEpochOwnerIdentity -OwnerIdentity $OwnerIdentity
    $resolved = Get-CcodLifecycleEpochAdapters -Adapters $Adapters
    try { $lease = & $resolved.EnterMutex $UserSid $SessionId $TimeoutMilliseconds }
    catch { Throw-CcodLifecycleEpochError 'CCOD_LIFECYCLE_LEASE_FAILED' 'Lifecycle ownership mutex could not be acquired safely' $InstallRoot }
    if ($null -eq $lease -or $lease.Outcome -cne 'Acquired') { Throw-CcodLifecycleEpochError 'CCOD_LIFECYCLE_LEASE_TIMEOUT' 'Lifecycle ownership mutex timed out' $InstallRoot }
    try {
        $current = Read-CcodLifecycleEpoch -InstallRoot $InstallRoot -AllowInitial -Adapters $resolved
        if ($current -eq [UInt64]::MaxValue) { Throw-CcodLifecycleEpochError 'CCOD_LIFECYCLE_EPOCH_EXHAUSTED' 'Lifecycle epoch cannot wrap' $InstallRoot }
        $next = [UInt64]($current + 1)
        Write-CcodLifecycleEpoch -InstallRoot $InstallRoot -Epoch $next -Adapters $resolved
        if ((Read-CcodLifecycleEpoch -InstallRoot $InstallRoot -Adapters $resolved) -ne $next) {
            Throw-CcodLifecycleEpochError 'CCOD_LIFECYCLE_EPOCH_UNPROVEN' 'Lifecycle epoch read-back does not prove the committed increment' $InstallRoot
        }
        return [pscustomobject][ordered]@{ schemaVersion=1; lease=$lease; epoch=$next; runtimeId=$RuntimeId; runtimeGeneration=$RuntimeGeneration; ownerIdentity=$OwnerIdentity; released=$false }
    } catch {
        try { [void](& $resolved.ExitMutex $lease) } catch { }
        throw
    }
}

function Assert-CcodLifecycleFence {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$InstallRoot, [Parameter(Mandatory)]$Ownership, [hashtable]$Adapters)

    Assert-CcodLifecycleOwnershipReceipt -Ownership $Ownership
    if ($Ownership.released -or ($null -ne $Ownership.lease.PSObject.Properties['Released'] -and [bool]$Ownership.lease.Released)) {
        Throw-CcodLifecycleEpochError 'CCOD_LIFECYCLE_FENCE_STALE' 'Lifecycle ownership has already been released' $Ownership
    }
    $resolved = Get-CcodLifecycleEpochAdapters -Adapters $Adapters
    try {
        $epoch = Read-CcodLifecycleEpoch -InstallRoot $InstallRoot -Adapters $resolved
        $pointer = & $resolved.ReadActiveRuntime $InstallRoot
        $identity = & $resolved.GetProcessIdentity $Ownership.ownerIdentity.pid
    } catch {
        Throw-CcodLifecycleEpochError 'CCOD_LIFECYCLE_FENCE_STALE' 'Lifecycle fence could not be revalidated' $Ownership
    }
    $pointerGeneration = $null
    if ($null -ne $pointer -and $null -ne $pointer.PSObject.Properties['generation']) {
        try { $pointerGeneration = ConvertTo-CcodLifecycleEpochUInt64 -Value $pointer.generation -Name 'activeRuntime.generation' }
        catch { Throw-CcodLifecycleEpochError 'CCOD_LIFECYCLE_FENCE_STALE' 'Active runtime generation is invalid' $Ownership }
    }
    if ($epoch -ne [UInt64]$Ownership.epoch -or $null -eq $pointer -or $pointer.activeRuntime -cne $Ownership.runtimeId -or
        $null -eq $pointerGeneration -or $pointerGeneration -ne [UInt64]$Ownership.runtimeGeneration -or $null -eq $identity -or
        $identity.pid -ne $Ownership.ownerIdentity.pid -or $identity.creationTimeUtc -cne $Ownership.ownerIdentity.creationTimeUtc) {
        Throw-CcodLifecycleEpochError 'CCOD_LIFECYCLE_FENCE_STALE' 'Lifecycle owner is stale' $Ownership
    }
    return $true
}

function Suspend-CcodLifecycleOwnership {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Ownership,[Parameter(Mandatory)][string]$InstallRoot,[hashtable]$Adapters)
    [void](Assert-CcodLifecycleFence -InstallRoot $InstallRoot -Ownership $Ownership -Adapters $Adapters)
    $resolved=Get-CcodLifecycleEpochAdapters -Adapters $Adapters
    try{$released=&$resolved.ExitMutex $Ownership.lease}catch{Throw-CcodLifecycleEpochError 'CCOD_LIFECYCLE_RELEASE_FAILED' 'Lifecycle ownership could not enter delegation' $Ownership}
    if($released-isnot[bool]-or-not$released-or-not$Ownership.lease.Released){Throw-CcodLifecycleEpochError 'CCOD_LIFECYCLE_RELEASE_FAILED' 'Lifecycle ownership handoff was not proven' $Ownership}
    return $true
}

function Enter-CcodLifecycleDelegation {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$InstallRoot,[Parameter(Mandatory)][string]$RuntimeId,[Parameter(Mandatory)][UInt64]$RuntimeGeneration,[Parameter(Mandatory)][UInt64]$LeaseEpoch,[Parameter(Mandatory)]$OwnerIdentity,[Parameter(Mandatory)][string]$UserSid,[Parameter(Mandatory)][int]$SessionId,[int]$TimeoutMilliseconds=15000,[hashtable]$Adapters)
    $resolved=Get-CcodLifecycleEpochAdapters -Adapters $Adapters;$lease=$null
    try{$lease=&$resolved.EnterMutex $UserSid $SessionId $TimeoutMilliseconds}catch{Throw-CcodLifecycleEpochError 'CCOD_LIFECYCLE_LEASE_FAILED' 'Delegated lifecycle mutex could not be acquired' $InstallRoot}
    if($null-eq$lease-or$lease.Outcome-cne'Acquired'){Throw-CcodLifecycleEpochError 'CCOD_LIFECYCLE_LEASE_TIMEOUT' 'Delegated lifecycle mutex timed out' $InstallRoot}
    $delegation=[pscustomobject][ordered]@{schemaVersion=1;lease=$lease;epoch=$LeaseEpoch;runtimeId=$RuntimeId;runtimeGeneration=$RuntimeGeneration;ownerIdentity=$OwnerIdentity;released=$false}
    try{[void](Assert-CcodLifecycleFence -InstallRoot $InstallRoot -Ownership $delegation -Adapters $resolved);return $delegation}catch{try{[void](&$resolved.ExitMutex $lease)}catch{};throw}
}

function Exit-CcodLifecycleDelegation {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Delegation,[hashtable]$Adapters)
    return Exit-CcodLifecycleOwnership -Ownership $Delegation -Adapters $Adapters
}

function Resume-CcodLifecycleOwnership {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Ownership,[Parameter(Mandatory)][string]$InstallRoot,[Parameter(Mandatory)][string]$UserSid,[Parameter(Mandatory)][int]$SessionId,[int]$TimeoutMilliseconds=15000,[hashtable]$Adapters)
    Assert-CcodLifecycleOwnershipReceipt -Ownership $Ownership
    if($Ownership.released-or$null-eq$Ownership.lease.PSObject.Properties['Released']-or-not$Ownership.lease.Released){Throw-CcodLifecycleEpochError 'CCOD_LIFECYCLE_FENCE_STALE' 'Lifecycle ownership is not suspended for delegation' $Ownership}
    $resolved=Get-CcodLifecycleEpochAdapters -Adapters $Adapters;$lease=$null
    try{$lease=&$resolved.EnterMutex $UserSid $SessionId $TimeoutMilliseconds}catch{Throw-CcodLifecycleEpochError 'CCOD_LIFECYCLE_LEASE_FAILED' 'Lifecycle ownership could not be reacquired' $InstallRoot}
    if($null-eq$lease-or$lease.Outcome-cne'Acquired'){Throw-CcodLifecycleEpochError 'CCOD_LIFECYCLE_LEASE_TIMEOUT' 'Lifecycle ownership reacquire timed out' $InstallRoot}
    $candidate=[pscustomobject][ordered]@{schemaVersion=1;lease=$lease;epoch=$Ownership.epoch;runtimeId=$Ownership.runtimeId;runtimeGeneration=$Ownership.runtimeGeneration;ownerIdentity=$Ownership.ownerIdentity;released=$false}
    try{[void](Assert-CcodLifecycleFence -InstallRoot $InstallRoot -Ownership $candidate -Adapters $resolved);$Ownership.lease=$lease;$Ownership.released=$false;return $true}catch{try{[void](&$resolved.ExitMutex $lease)}catch{};throw}
}

function Exit-CcodLifecycleOwnership {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Ownership, [hashtable]$Adapters)

    Assert-CcodLifecycleOwnershipReceipt -Ownership $Ownership
    if ($Ownership.released) { return $false }
    $resolved = Get-CcodLifecycleEpochAdapters -Adapters $Adapters
    try { $released = & $resolved.ExitMutex $Ownership.lease }
    catch { Throw-CcodLifecycleEpochError 'CCOD_LIFECYCLE_RELEASE_FAILED' 'Lifecycle ownership mutex could not be released safely' $Ownership }
    if ($released -isnot [bool] -or -not $released) { Throw-CcodLifecycleEpochError 'CCOD_LIFECYCLE_RELEASE_FAILED' 'Lifecycle ownership mutex was not released' $Ownership }
    $Ownership.released = $true
    return $true
}

Export-ModuleMember -Function Enter-CcodLifecycleOwnership, Assert-CcodLifecycleFence, Suspend-CcodLifecycleOwnership, Enter-CcodLifecycleDelegation, Exit-CcodLifecycleDelegation, Resume-CcodLifecycleOwnership, Exit-CcodLifecycleOwnership, Read-CcodLifecycleEpoch
