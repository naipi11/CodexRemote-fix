Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'PersistenceIO.psm1') -Force

$script:CcodTrustedLogonIdentityProperties = @('authenticationId','userSid','sessionId')
$script:CcodSafeExitIntentProperties = @('schemaVersion','logonIdentity','runtimeId','recoveryTransactionId','createdAtUtc')

function Throw-CcodTrustedLogonError {
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$Message, $Target)

    throw [Management.Automation.ErrorRecord]::new(
        [InvalidOperationException]::new($Message), $Id, [Management.Automation.ErrorCategory]::InvalidData, $Target)
}

function Get-CcodTrustedLogonErrorId {
    param($ErrorRecord)

    if ($null -eq $ErrorRecord -or $ErrorRecord.FullyQualifiedErrorId -isnot [string]) { return $null }
    return ([string]$ErrorRecord.FullyQualifiedErrorId -split ',')[0]
}

function Get-CcodTrustedLogonPropertyNames {
    param($Value)

    if ($null -eq $Value) { return @() }
    if ($Value -is [Collections.IDictionary]) { return @($Value.Keys | ForEach-Object { [string]$_ }) }
    return @($Value.PSObject.Properties | ForEach-Object { $_.Name })
}

function Assert-CcodTrustedLogonExactProperties {
    param([Parameter(Mandatory)]$Value, [Parameter(Mandatory)][string[]]$Expected, [Parameter(Mandatory)][string]$ErrorId, [Parameter(Mandatory)][string]$Kind)

    if ($Value -isnot [pscustomobject] -and $Value -isnot [Collections.IDictionary]) {
        Throw-CcodTrustedLogonError $ErrorId "$Kind must be an object" $Value
    }
    $actual = @(Get-CcodTrustedLogonPropertyNames -Value $Value)
    if ($actual.Count -ne $Expected.Count -or ($actual -join "`0") -cne ($Expected -join "`0")) {
        Throw-CcodTrustedLogonError $ErrorId "$Kind has unexpected, missing, or reordered fields" $Value
    }
    foreach ($property in @($Value.PSObject.Properties)) {
        if ($property.MemberType -notin @('NoteProperty','Property')) {
            Throw-CcodTrustedLogonError $ErrorId "$Kind contains a non-data property" $Value
        }
    }
}

function Test-CcodCanonicalSid {
    param($Value)

    if ($Value -isnot [string] -or $Value -notmatch '^S-1-(?:0|[1-9][0-9]*)(?:-(?:0|[1-9][0-9]*))+$') { return $false }
    try { return ([Security.Principal.SecurityIdentifier]::new($Value)).Value -ceq $Value } catch { return $false }
}

function Assert-CcodTrustedLogonIdentity {
    param([Parameter(Mandatory)]$Identity, [Parameter(Mandatory)][string]$ErrorId)

    Assert-CcodTrustedLogonExactProperties -Value $Identity -Expected $script:CcodTrustedLogonIdentityProperties -ErrorId $ErrorId -Kind 'Trusted logon identity'
    if ($Identity.authenticationId -isnot [string] -or $Identity.authenticationId -cnotmatch '^[0-9A-F]{8}:[0-9A-F]{8}$' -or
        -not (Test-CcodCanonicalSid -Value $Identity.userSid) -or
        ($Identity.sessionId -isnot [int] -and $Identity.sessionId -isnot [long]) -or $Identity.sessionId -lt 0 -or $Identity.sessionId -gt [int]::MaxValue) {
        Throw-CcodTrustedLogonError $ErrorId 'Trusted logon identity is invalid' $Identity
    }
}

function Initialize-CcodTrustedLogonNative {
    if ($null -ne ('CcodTrustedLogonNative' -as [type])) { return }

    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;

public sealed class CcodProcessTokenFacts
{
    public UInt32 AuthenticationHighPart { get; set; }
    public UInt32 AuthenticationLowPart { get; set; }
    public string userSid { get; set; }
}

public static class CcodTrustedLogonNative
{
    [StructLayout(LayoutKind.Sequential)]
    private struct LUID { public UInt32 LowPart; public Int32 HighPart; }

    [StructLayout(LayoutKind.Sequential)]
    private struct TOKEN_STATISTICS
    {
        public LUID TokenId;
        public LUID AuthenticationId;
        public Int64 ExpirationTime;
        public Int32 TokenType;
        public Int32 ImpersonationLevel;
        public UInt32 DynamicCharged;
        public UInt32 DynamicAvailable;
        public UInt32 GroupCount;
        public UInt32 PrivilegeCount;
        public LUID ModifiedId;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct SID_AND_ATTRIBUTES { public IntPtr Sid; public UInt32 Attributes; }

    [StructLayout(LayoutKind.Sequential)]
    private struct TOKEN_USER { public SID_AND_ATTRIBUTES User; }

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool OpenProcessToken(IntPtr processHandle, UInt32 desiredAccess, out IntPtr tokenHandle);
    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool GetTokenInformation(IntPtr tokenHandle, Int32 tokenInformationClass, IntPtr tokenInformation, UInt32 tokenInformationLength, out UInt32 returnLength);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);

    public static CcodProcessTokenFacts GetCurrentProcessTokenFacts()
    {
        IntPtr token = IntPtr.Zero;
        IntPtr buffer = IntPtr.Zero;
        IntPtr userBuffer = IntPtr.Zero;
        Process process = null;
        try
        {
            process = Process.GetCurrentProcess();
            if (!OpenProcessToken(process.Handle, 0x0008U, out token) || token == IntPtr.Zero || token == new IntPtr(-1))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            UInt32 length;
            GetTokenInformation(token, 10, IntPtr.Zero, 0, out length);
            int minimum = Marshal.SizeOf(typeof(TOKEN_STATISTICS));
            if (length < minimum) throw new InvalidOperationException("TOKEN_STATISTICS buffer is too short");
            buffer = Marshal.AllocHGlobal(checked((int)length));
            if (!GetTokenInformation(token, 10, buffer, length, out length) || length < minimum)
                throw new Win32Exception(Marshal.GetLastWin32Error());
            TOKEN_STATISTICS statistics = (TOKEN_STATISTICS)Marshal.PtrToStructure(buffer, typeof(TOKEN_STATISTICS));
            UInt32 userLength;
            GetTokenInformation(token, 1, IntPtr.Zero, 0, out userLength);
            int minimumUser = Marshal.SizeOf(typeof(TOKEN_USER));
            if (userLength < minimumUser) throw new InvalidOperationException("TOKEN_USER buffer is too short");
            userBuffer = Marshal.AllocHGlobal(checked((int)userLength));
            if (!GetTokenInformation(token, 1, userBuffer, userLength, out userLength) || userLength < minimumUser)
                throw new Win32Exception(Marshal.GetLastWin32Error());
            TOKEN_USER user = (TOKEN_USER)Marshal.PtrToStructure(userBuffer, typeof(TOKEN_USER));
            if (user.User.Sid == IntPtr.Zero) throw new InvalidOperationException("TOKEN_USER SID is unavailable");
            return new CcodProcessTokenFacts {
                AuthenticationHighPart = unchecked((UInt32)statistics.AuthenticationId.HighPart),
                AuthenticationLowPart = statistics.AuthenticationId.LowPart,
                userSid = new System.Security.Principal.SecurityIdentifier(user.User.Sid).Value
            };
        }
        finally
        {
            if (userBuffer != IntPtr.Zero) Marshal.FreeHGlobal(userBuffer);
            if (buffer != IntPtr.Zero) Marshal.FreeHGlobal(buffer);
            if (token != IntPtr.Zero && token != new IntPtr(-1)) CloseHandle(token);
            if (process != null) process.Dispose();
        }
    }
}
'@ -ErrorAction Stop
}

function Get-CcodTrustedLogonAdapters {
    param([hashtable]$Adapters)

    $resolved = @{
        GetProcessTokenFacts = { Initialize-CcodTrustedLogonNative; [CcodTrustedLogonNative]::GetCurrentProcessTokenFacts() }
        GetCurrentUserSid = { throw 'Thread identity must not be used for trusted logon facts' }
        GetCurrentSessionId = {
            $process = [Diagnostics.Process]::GetCurrentProcess()
            try { [int]$process.SessionId } finally { $process.Dispose() }
        }
    }
    if ($null -ne $Adapters) {
        if ($Adapters -isnot [hashtable]) { Throw-CcodTrustedLogonError 'CCOD_LOGON_IDENTITY_UNAVAILABLE' 'Trusted logon identity is unavailable' $null }
        foreach ($key in $Adapters.Keys) {
            if (-not $resolved.ContainsKey($key) -or $Adapters[$key] -isnot [scriptblock]) {
                Throw-CcodTrustedLogonError 'CCOD_LOGON_IDENTITY_UNAVAILABLE' 'Trusted logon identity is unavailable' $null
            }
            $resolved[$key] = $Adapters[$key]
        }
    }
    return $resolved
}

function Get-CcodTrustedLogonIdentity {
    [CmdletBinding()]
    param([hashtable]$Adapters)

    try {
        $resolved = Get-CcodTrustedLogonAdapters -Adapters $Adapters
        $statistics = & $resolved.GetProcessTokenFacts
        Assert-CcodTrustedLogonExactProperties -Value $statistics -Expected @('AuthenticationHighPart','AuthenticationLowPart','userSid') -ErrorId 'CCOD_LOGON_IDENTITY_UNAVAILABLE' -Kind 'Process token facts'
        foreach ($name in @('AuthenticationHighPart','AuthenticationLowPart')) {
            $value = $statistics.$name
            if (($value -isnot [byte] -and $value -isnot [uint16] -and $value -isnot [uint32] -and $value -isnot [int16] -and $value -isnot [int32] -and $value -isnot [int64]) -or $value -lt 0 -or $value -gt [uint32]::MaxValue) {
                Throw-CcodTrustedLogonError 'CCOD_LOGON_IDENTITY_UNAVAILABLE' 'Trusted logon identity is unavailable' $null
            }
        }
        $identity = [pscustomobject][ordered]@{
            authenticationId = '{0:X8}:{1:X8}' -f ([uint32]$statistics.AuthenticationHighPart),([uint32]$statistics.AuthenticationLowPart)
            userSid = $statistics.userSid
            sessionId = [int](& $resolved.GetCurrentSessionId)
        }
        Assert-CcodTrustedLogonIdentity -Identity $identity -ErrorId 'CCOD_LOGON_IDENTITY_UNAVAILABLE'
        return $identity
    } catch {
        Throw-CcodTrustedLogonError 'CCOD_LOGON_IDENTITY_UNAVAILABLE' 'Trusted logon identity is unavailable' $null
    }
}

function Get-CcodSafeExitIntentPath {
    param([Parameter(Mandatory)][string]$StateRoot)

    return Resolve-CcodContainedPath -Root $StateRoot -RelativePath 'lifecycle\safe-exit-intent.json' -AllowMissingLeaf
}

function Get-CcodSafeExitIntentFileSecurity {
    try {
        Initialize-CcodTrustedLogonNative
        $userSid = [CcodTrustedLogonNative]::GetCurrentProcessTokenFacts().userSid
        if (-not (Test-CcodCanonicalSid -Value $userSid)) { Throw-CcodTrustedLogonError 'CCOD_SAFE_EXIT_INTENT_ACL_INVALID' 'Current user SID is unavailable for the safe-exit marker' $null }
        $security = [Security.AccessControl.FileSecurity]::new()
        $security.SetOwner([Security.Principal.SecurityIdentifier]::new($userSid))
        $security.SetAccessRuleProtection($true, $false)
        foreach ($sidValue in @($userSid, 'S-1-5-18', 'S-1-5-32-544')) {
            [void]$security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sidValue), [Security.AccessControl.FileSystemRights]::FullControl, [Security.AccessControl.AccessControlType]::Allow))
        }
        return $security
    } catch {
        if ((Get-CcodTrustedLogonErrorId $_) -ceq 'CCOD_SAFE_EXIT_INTENT_ACL_INVALID') { throw }
        Throw-CcodTrustedLogonError 'CCOD_SAFE_EXIT_INTENT_ACL_INVALID' 'Current process token SID is unavailable for the safe-exit marker' $null
    }
}

function New-CcodSafeExitIntentSecureFile {
    param([Parameter(Mandatory)][string]$Path)

    return [IO.FileStream]::new($Path, [IO.FileMode]::CreateNew, [Security.AccessControl.FileSystemRights]::FullControl, [IO.FileShare]::None, 4096, [IO.FileOptions]::WriteThrough, (Get-CcodSafeExitIntentFileSecurity))
}

function Assert-CcodSafeExitIntentFileAcl {
    param([Parameter(Mandatory)][string]$Path, $Security, [string]$UserSid)

    if ($null -eq $Security -and -not [IO.File]::Exists($Path)) { return }
    try {
        if ([string]::IsNullOrWhiteSpace($UserSid)) {
            Initialize-CcodTrustedLogonNative
            $UserSid = [CcodTrustedLogonNative]::GetCurrentProcessTokenFacts().userSid
        }
        $userSid = $UserSid
        if (-not (Test-CcodCanonicalSid -Value $userSid)) { Throw-CcodTrustedLogonError 'CCOD_SAFE_EXIT_INTENT_ACL_INVALID' 'Safe-exit marker ACL could not be proven' $Path }
        if ($null -eq $Security) { $Security = [IO.File]::GetAccessControl($Path) }
        $security = $Security
        $rules = @($security.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
        $owner = $security.GetOwner([Security.Principal.SecurityIdentifier])
        $expected = @($userSid, 'S-1-5-18', 'S-1-5-32-544')
        if ($null -eq $owner -or $owner.Value -cne $userSid -or -not $security.AreAccessRulesProtected -or $rules.Count -ne $expected.Count) {
            Throw-CcodTrustedLogonError 'CCOD_SAFE_EXIT_INTENT_ACL_INVALID' 'Safe-exit marker ACL is not the required protected current-user ACL' $Path
        }
        $counts = @{}
        foreach ($rule in $rules) {
            if ($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or $rule.IsInherited -or $rule.FileSystemRights -ne [Security.AccessControl.FileSystemRights]::FullControl -or $expected -cnotcontains $rule.IdentityReference.Value) {
                Throw-CcodTrustedLogonError 'CCOD_SAFE_EXIT_INTENT_ACL_INVALID' 'Safe-exit marker ACL is not the required protected current-user ACL' $Path
            }
            $counts[$rule.IdentityReference.Value] = 1 + $(if ($counts.ContainsKey($rule.IdentityReference.Value)) { [int]$counts[$rule.IdentityReference.Value] } else { 0 })
        }
        foreach ($sidValue in $expected) {
            if (-not $counts.ContainsKey($sidValue) -or $counts[$sidValue] -ne 1) {
                Throw-CcodTrustedLogonError 'CCOD_SAFE_EXIT_INTENT_ACL_INVALID' 'Safe-exit marker ACL is not the required protected current-user ACL' $Path
            }
        }
    } catch {
        if ((Get-CcodTrustedLogonErrorId $_) -ceq 'CCOD_SAFE_EXIT_INTENT_ACL_INVALID') { throw }
        Throw-CcodTrustedLogonError 'CCOD_SAFE_EXIT_INTENT_ACL_INVALID' 'Safe-exit marker ACL could not be proven' $Path
    }
}

function Get-CcodSafeExitIntentAdapters {
    param([hashtable]$Adapters)

    $resolved = @{
        ResolveSafeExitIntentPath = { param($StateRoot) Get-CcodSafeExitIntentPath -StateRoot $StateRoot }
        ReadStrictJson = { param($Path) Read-CcodStrictJson -Path $Path -ExpectedSchema 1 -Kind 'safe-exit intent' }
        WriteAtomicJson = { param($Path, $Value, $CreateFile) Write-CcodAtomicJson -Path $Path -Value $Value -Adapters @{ CreateNewFile=$CreateFile } }
        FileExists = { param($Path) [IO.File]::Exists($Path) }
        DeleteFile = { param($Path) [IO.File]::Delete($Path) }
        AssertSafeExitFileAcl = { param($Path) Assert-CcodSafeExitIntentFileAcl -Path $Path }
        CreateSafeExitFile = { param($Path) New-CcodSafeExitIntentSecureFile -Path $Path }
    }
    if ($null -ne $Adapters) {
        if ($Adapters -isnot [hashtable]) { Throw-CcodTrustedLogonError 'CCOD_SAFE_EXIT_INTENT_INVALID' 'Safe-exit marker adapters are invalid' $null }
        foreach ($key in $Adapters.Keys) {
            if (-not $resolved.ContainsKey($key) -or $Adapters[$key] -isnot [scriptblock]) {
                Throw-CcodTrustedLogonError 'CCOD_SAFE_EXIT_INTENT_INVALID' 'Safe-exit marker adapters are invalid' $null
            }
            $resolved[$key] = $Adapters[$key]
        }
    }
    return $resolved
}

function Assert-CcodSafeExitIntent {
    param([Parameter(Mandatory)]$Intent)

    Assert-CcodTrustedLogonExactProperties -Value $Intent -Expected $script:CcodSafeExitIntentProperties -ErrorId 'CCOD_SAFE_EXIT_INTENT_INVALID' -Kind 'Safe-exit intent'
    if (($Intent.schemaVersion -isnot [int] -and $Intent.schemaVersion -isnot [long]) -or $Intent.schemaVersion -ne 1 -or
        $Intent.runtimeId -isnot [string] -or $Intent.runtimeId -cnotmatch '^[A-Za-z0-9._-]{1,96}$' -or
        $Intent.recoveryTransactionId -isnot [string] -or $Intent.recoveryTransactionId -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' -or
        $Intent.createdAtUtc -isnot [string]) {
        Throw-CcodTrustedLogonError 'CCOD_SAFE_EXIT_INTENT_INVALID' 'Safe-exit marker is invalid' $Intent
    }
    $guid = [guid]::Empty
    $timestamp = [DateTime]::MinValue
    if (-not [guid]::TryParseExact($Intent.recoveryTransactionId, 'D', [ref]$guid) -or $guid.ToString('D') -cne $Intent.recoveryTransactionId -or
        -not [DateTime]::TryParseExact($Intent.createdAtUtc, 'o', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$timestamp) -or $timestamp.Kind -ne [DateTimeKind]::Utc -or $timestamp.ToUniversalTime().ToString('o') -cne $Intent.createdAtUtc) {
        Throw-CcodTrustedLogonError 'CCOD_SAFE_EXIT_INTENT_INVALID' 'Safe-exit marker is invalid' $Intent
    }
    Assert-CcodTrustedLogonIdentity -Identity $Intent.logonIdentity -ErrorId 'CCOD_SAFE_EXIT_INTENT_INVALID'
}

function Read-CcodSafeExitIntent {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StateRoot, [hashtable]$Adapters)

    $resolved = Get-CcodSafeExitIntentAdapters -Adapters $Adapters
    try { $path = & $resolved.ResolveSafeExitIntentPath $StateRoot }
    catch { Throw-CcodTrustedLogonError 'CCOD_SAFE_EXIT_INTENT_INVALID' 'Safe-exit marker path is invalid' $null }
    if (-not (& $resolved.FileExists $path)) { return $null }
    try { & $resolved.AssertSafeExitFileAcl $path }
    catch { Throw-CcodTrustedLogonError 'CCOD_SAFE_EXIT_INTENT_ACL_INVALID' 'Safe-exit marker ACL proof failed' $null }
    try { $intent = & $resolved.ReadStrictJson $path; Assert-CcodSafeExitIntent -Intent $intent; return $intent }
    catch { Throw-CcodTrustedLogonError 'CCOD_SAFE_EXIT_INTENT_INVALID' 'Safe-exit marker is unreadable or malformed' $null }
}

function Write-CcodSafeExitIntent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)]$LogonIdentity,
        [Parameter(Mandatory)][string]$RuntimeId,
        [Parameter(Mandatory)][string]$RecoveryTransactionId,
        [Parameter(Mandatory)][string]$NowUtc,
        [hashtable]$Adapters
    )

    $intent = [pscustomobject][ordered]@{ schemaVersion=1; logonIdentity=$LogonIdentity; runtimeId=$RuntimeId; recoveryTransactionId=$RecoveryTransactionId; createdAtUtc=$NowUtc }
    Assert-CcodSafeExitIntent -Intent $intent
    $resolved = Get-CcodSafeExitIntentAdapters -Adapters $Adapters
    try { $path = & $resolved.ResolveSafeExitIntentPath $StateRoot }
    catch { Throw-CcodTrustedLogonError 'CCOD_SAFE_EXIT_INTENT_INVALID' 'Safe-exit marker path is invalid' $null }
    try {
        & $resolved.WriteAtomicJson $path $intent $resolved.CreateSafeExitFile | Out-Null
        & $resolved.AssertSafeExitFileAcl $path
    } catch {
        if ((Get-CcodTrustedLogonErrorId $_) -ceq 'CCOD_SAFE_EXIT_INTENT_ACL_INVALID') { throw }
        Throw-CcodTrustedLogonError 'CCOD_SAFE_EXIT_INTENT_WRITE_FAILED' 'Safe-exit marker could not be persisted atomically' $null
    }
    return $intent
}

function Test-CcodSafeExitIntentForCurrentLogon {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Intent, [Parameter(Mandatory)]$LogonIdentity)

    Assert-CcodSafeExitIntent -Intent $Intent
    Assert-CcodTrustedLogonIdentity -Identity $LogonIdentity -ErrorId 'CCOD_LOGON_IDENTITY_UNAVAILABLE'
    return $Intent.logonIdentity.authenticationId -ceq $LogonIdentity.authenticationId -and
        $Intent.logonIdentity.userSid -ceq $LogonIdentity.userSid -and
        $Intent.logonIdentity.sessionId -eq $LogonIdentity.sessionId
}

function Clear-CcodSafeExitIntent {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StateRoot, [hashtable]$Adapters)

    $resolved = Get-CcodSafeExitIntentAdapters -Adapters $Adapters
    $intent = Read-CcodSafeExitIntent -StateRoot $StateRoot -Adapters $resolved
    if ($null -eq $intent) { return $false }
    try { $path = & $resolved.ResolveSafeExitIntentPath $StateRoot; & $resolved.DeleteFile $path }
    catch { Throw-CcodTrustedLogonError 'CCOD_SAFE_EXIT_INTENT_CLEAR_FAILED' 'Safe-exit marker could not be cleared' $null }
    return $true
}

Export-ModuleMember -Function Get-CcodTrustedLogonIdentity, Read-CcodSafeExitIntent, Write-CcodSafeExitIntent, Test-CcodSafeExitIntentForCurrentLogon, Clear-CcodSafeExitIntent
