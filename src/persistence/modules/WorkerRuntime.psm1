Set-StrictMode -Version 2.0

Import-Module (Join-Path $PSScriptRoot 'PersistenceIO.psm1') -Force

function Initialize-CcodWorkerJobNative {
    if($null-ne('CcodWorkerJobNativeV1'-as[type])){return}
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public sealed class CcodWorkerJobSafeHandleV1 : SafeHandleZeroOrMinusOneIsInvalid {
    private CcodWorkerJobSafeHandleV1() : base(true) { }
    [DllImport("kernel32.dll", SetLastError=true)] private static extern bool CloseHandle(IntPtr handle);
    protected override bool ReleaseHandle() { return CloseHandle(handle); }
}

public static class CcodWorkerJobNativeV1 {
    private const UInt32 JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;
    private const Int32 JobObjectExtendedLimitInformation = 9;

    [StructLayout(LayoutKind.Sequential)] private struct IO_COUNTERS {
        public UInt64 ReadOperationCount, WriteOperationCount, OtherOperationCount;
        public UInt64 ReadTransferCount, WriteTransferCount, OtherTransferCount;
    }
    [StructLayout(LayoutKind.Sequential)] private struct JOBOBJECT_BASIC_LIMIT_INFORMATION {
        public Int64 PerProcessUserTimeLimit, PerJobUserTimeLimit;
        public UInt32 LimitFlags;
        public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
        public UInt32 ActiveProcessLimit;
        public UIntPtr Affinity;
        public UInt32 PriorityClass, SchedulingClass;
    }
    [StructLayout(LayoutKind.Sequential)] private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
    }

    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    private static extern CcodWorkerJobSafeHandleV1 CreateJobObject(IntPtr attributes, string name);
    [DllImport("kernel32.dll", SetLastError=true)]
    private static extern bool SetInformationJobObject(CcodWorkerJobSafeHandleV1 job, Int32 infoClass, IntPtr info, UInt32 length);
    [DllImport("kernel32.dll", SetLastError=true)]
    private static extern bool AssignProcessToJobObject(CcodWorkerJobSafeHandleV1 job, IntPtr process);

    public static CcodWorkerJobSafeHandleV1 CreateKillOnCloseJob() {
        CcodWorkerJobSafeHandleV1 job = CreateJobObject(IntPtr.Zero, null);
        if (job == null || job.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
        info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        Int32 length = Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
        IntPtr buffer = Marshal.AllocHGlobal(length);
        try {
            Marshal.StructureToPtr(info, buffer, false);
            if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, buffer, (UInt32)length)) {
                Int32 error = Marshal.GetLastWin32Error(); job.Dispose(); throw new Win32Exception(error);
            }
            return job;
        } finally { Marshal.FreeHGlobal(buffer); }
    }

    public static bool Assign(CcodWorkerJobSafeHandleV1 job, IntPtr processHandle) {
        if (job == null || job.IsInvalid || job.IsClosed || processHandle == IntPtr.Zero) return false;
        return AssignProcessToJobObject(job, processHandle);
    }
}
'@
}

function Throw-CcodWorkerRuntimeError {
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

function Get-CcodWorkerLeafState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathRooted($Path)) {
        Throw-CcodWorkerRuntimeError 'CCOD_WORKER_PATH_INVALID' 'Worker leaf path must be absolute' $Path
    }
    $exists = [IO.File]::Exists($Path)
    $isReparse = $false
    if ($exists) {
        try {
            $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
            $isReparse = (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
        } catch {
            $isReparse = $true
        }
    }
    return [pscustomobject][ordered]@{
        Exists = [bool]$exists
        IsReparse = [bool]$isReparse
    }
}

function Write-CcodWorkerRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Request
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathRooted($Path)) {
        Throw-CcodWorkerRuntimeError 'CCOD_WORKER_PATH_INVALID' 'Worker request path must be absolute' $Path
    }
    Write-CcodAtomicJson -Path $Path -Value $Request
}

function Test-CcodWorkerRuntimeCanonicalUtc {
    param($Value)
    $parsed=[DateTime]::MinValue
    return $Value-is[string] -and [DateTime]::TryParseExact($Value,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$parsed) -and $parsed.Kind-eq[DateTimeKind]::Utc -and $parsed.ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture)-ceq$Value
}

function Get-CcodWorkerGateSecurity {
    param([Security.Principal.SecurityIdentifier]$UserSid)
    $security=[Security.AccessControl.EventWaitHandleSecurity]::new();$security.SetOwner($UserSid);$security.SetAccessRuleProtection($true,$false)
    $read=[Security.AccessControl.EventWaitHandleRights]::ReadPermissions-bor[Security.AccessControl.EventWaitHandleRights]::Synchronize
    [void]$security.AddAccessRule([Security.AccessControl.EventWaitHandleAccessRule]::new($UserSid,$read,[Security.AccessControl.AccessControlType]::Allow))
    foreach($sidValue in @('S-1-5-18','S-1-5-32-544')){[void]$security.AddAccessRule([Security.AccessControl.EventWaitHandleAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sidValue),[Security.AccessControl.EventWaitHandleRights]::FullControl,[Security.AccessControl.AccessControlType]::Allow))}
    return $security
}

function Assert-CcodWorkerGateAcl {
    param([Threading.EventWaitHandle]$Handle,[string]$UserSid)
    try{
        $security=$Handle.GetAccessControl();$owner=$security.GetOwner([Security.Principal.SecurityIdentifier]);$rules=@($security.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]));$read=[Security.AccessControl.EventWaitHandleRights]::ReadPermissions-bor[Security.AccessControl.EventWaitHandleRights]::Synchronize
        if($owner.Value-cne$UserSid -or -not$security.AreAccessRulesProtected -or $rules.Count-ne3){throw 'acl'}
        foreach($rule in $rules){
            $expected=if($rule.IdentityReference.Value-ceq$UserSid){$read}elseif(@('S-1-5-18','S-1-5-32-544')-ccontains$rule.IdentityReference.Value){[Security.AccessControl.EventWaitHandleRights]::FullControl}else{throw 'principal'}
            if($rule.AccessControlType-ne[Security.AccessControl.AccessControlType]::Allow -or $rule.IsInherited -or $rule.EventWaitHandleRights-ne$expected){throw 'rule'}
        }
    }catch{Throw-CcodWorkerRuntimeError 'CCOD_WORKER_GATE_INVALID' 'Worker startup gate ACL is invalid' $null}
}

function New-CcodWorkerGateToken {
    $bytes=New-Object byte[] 32
    $rng=[Security.Cryptography.RandomNumberGenerator]::Create()
    try{$rng.GetBytes($bytes);return [BitConverter]::ToString($bytes).Replace('-','').ToLowerInvariant()}
    finally{$rng.Dispose()}
}

function New-CcodWorkerStartupGate {
    param([string]$Token,$ParentIdentity)
    $windows=$null
    try{
        $windows=[Security.Principal.WindowsIdentity]::GetCurrent();if($null-eq$windows.User){throw 'sid'}
        $name="Local\CodexControlOtherDevices.WorkerGate.$($windows.User.Value).$($ParentIdentity.SessionId).$Token"
        $created=$false;$handle=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,$name,[ref]$created,(Get-CcodWorkerGateSecurity $windows.User))
        if(-not$created){$handle.Dispose();Throw-CcodWorkerRuntimeError 'CCOD_WORKER_GATE_INVALID' 'Worker startup gate collided' $null}
        Assert-CcodWorkerGateAcl $handle $windows.User.Value
        return [pscustomobject][ordered]@{Name=$name;Token=$Token;Handle=$handle;Released=$false;Disposed=$false;ParentPid=[int]$ParentIdentity.Pid;ParentCreationTimeUtc=[string]$ParentIdentity.CreationTimeUtc;SessionId=[int]$ParentIdentity.SessionId;UserSid=$windows.User.Value}
    }catch{if($_.FullyQualifiedErrorId-like'CCOD_WORKER_GATE_INVALID*'){throw};Throw-CcodWorkerRuntimeError 'CCOD_WORKER_GATE_INVALID' 'Worker startup gate could not be created' $null}
    finally{if($null-ne$windows){$windows.Dispose()}}
}

function Get-CcodWorkerParentIdentity {
    $process=[Diagnostics.Process]::GetCurrentProcess()
    try{return [pscustomobject][ordered]@{Pid=[int]$process.Id;CreationTimeUtc=$process.StartTime.ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture);SessionId=[int]$process.SessionId}}
    finally{$process.Dispose()}
}

function Get-CcodWorkerRuntimeAdapters {
    param([hashtable]$Adapters)
    $resolved=@{
        NewToken={New-CcodWorkerGateToken};GetParentIdentity={Get-CcodWorkerParentIdentity}
        CreateGate={param($Token,$ParentIdentity)New-CcodWorkerStartupGate $Token $ParentIdentity}
        CreateJob={Initialize-CcodWorkerJobNative;[CcodWorkerJobNativeV1]::CreateKillOnCloseJob()}
        StartProcess={param($StartInfo)[Diagnostics.Process]::Start($StartInfo)}
        AssignProcessToJob={param($Job,$Process)[CcodWorkerJobNativeV1]::Assign($Job,$Process.Handle)}
        SignalGate={param($Gate)$set=[bool]$Gate.Handle.Set();if($set){$Gate.Released=$true};$set}
        KillExactProcess={param($Process)try{$Process.Kill();$true}catch{$false}}
        DisposeGate={param($Gate)if($null-ne$Gate-and-not$Gate.Disposed){$Gate.Handle.Dispose();$Gate.Disposed=$true}}
        DisposeJob={param($Job)if($null-ne$Job-and-not$Job.IsClosed){$Job.Dispose()}}
    }
    if($null-ne$Adapters){
        if($Adapters-isnot[hashtable]){Throw-CcodWorkerRuntimeError 'CCOD_WORKER_START_FAILED' 'Worker adapters are invalid' $Adapters}
        foreach($key in $Adapters.Keys){if(-not$resolved.ContainsKey($key)-or$Adapters[$key]-isnot[scriptblock]){Throw-CcodWorkerRuntimeError 'CCOD_WORKER_START_FAILED' 'Worker adapter is invalid' $key};$resolved[$key]=$Adapters[$key]}
    }
    return $resolved
}

function Wait-CcodWorkerStartupGate {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$GateName,[Parameter(Mandatory)][string]$GateToken,[Parameter(Mandatory)][int]$ExpectedParentPid,[Parameter(Mandatory)][string]$ExpectedParentCreationTimeUtc,[ValidateRange(1,30000)][int]$TimeoutMilliseconds=15000)
    if($GateToken-cnotmatch'^[0-9a-f]{64}$' -or $ExpectedParentPid-lt1 -or -not(Test-CcodWorkerRuntimeCanonicalUtc $ExpectedParentCreationTimeUtc)){Throw-CcodWorkerRuntimeError 'CCOD_WORKER_GATE_INVALID' 'Worker startup gate binding is invalid' $null}
    $windows=$null;$current=$null;$parent=$null;$gate=$null
    try{
        $windows=[Security.Principal.WindowsIdentity]::GetCurrent();$current=[Diagnostics.Process]::GetCurrentProcess();$parent=[Diagnostics.Process]::GetProcessById($ExpectedParentPid)
        $expectedName="Local\CodexControlOtherDevices.WorkerGate.$($windows.User.Value).$($current.SessionId).$GateToken"
        $cim=Get-CimInstance Win32_Process -Filter ("ProcessId="+$current.Id) -ErrorAction Stop
        if($GateName-cne$expectedName -or [int]$cim.ParentProcessId-ne$ExpectedParentPid -or $parent.SessionId-ne$current.SessionId -or $parent.StartTime.ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture)-cne$ExpectedParentCreationTimeUtc){Throw-CcodWorkerRuntimeError 'CCOD_WORKER_GATE_INVALID' 'Worker startup gate parent binding is invalid' $null}
        $rights=[Security.AccessControl.EventWaitHandleRights]::ReadPermissions-bor[Security.AccessControl.EventWaitHandleRights]::Synchronize
        $gate=[Threading.EventWaitHandle]::OpenExisting($GateName,$rights);Assert-CcodWorkerGateAcl $gate $windows.User.Value
        if(-not$gate.WaitOne($TimeoutMilliseconds)){Throw-CcodWorkerRuntimeError 'CCOD_WORKER_GATE_TIMEOUT' 'Worker startup gate timed out' $null}
        $parent.Refresh();$cim=Get-CimInstance Win32_Process -Filter ("ProcessId="+$current.Id) -ErrorAction Stop
        if([int]$cim.ParentProcessId-ne$ExpectedParentPid -or $parent.HasExited -or $parent.StartTime.ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture)-cne$ExpectedParentCreationTimeUtc){Throw-CcodWorkerRuntimeError 'CCOD_WORKER_GATE_INVALID' 'Worker startup gate parent changed' $null}
        return $true
    }catch{if($_.FullyQualifiedErrorId-like'CCOD_WORKER_GATE_*'){throw};Throw-CcodWorkerRuntimeError 'CCOD_WORKER_GATE_INVALID' 'Worker startup gate could not be validated' $null}
    finally{if($null-ne$gate){$gate.Dispose()};if($null-ne$parent){$parent.Dispose()};if($null-ne$current){$current.Dispose()};if($null-ne$windows){$windows.Dispose()}}
}

function Test-CcodWorkerCanonicalUtc {
    param($Value)
    $parsed=[DateTime]::MinValue
    return $Value -is [string] -and [DateTime]::TryParseExact($Value,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$parsed) -and
        $parsed.Kind -eq [DateTimeKind]::Utc -and $parsed.ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture) -ceq $Value
}

function Test-CcodWorkerCanonicalGuid {
    param($Value)
    $parsed=[guid]::Empty
    return $Value -is [string] -and [guid]::TryParseExact($Value,'D',[ref]$parsed) -and $parsed.ToString('D') -ceq $Value
}

function Test-CcodWorkerExactProperties {
    param($Value,[string[]]$Expected)
    return $null -ne $Value -and $Value -is [pscustomobject] -and (@($Value.PSObject.Properties.Name)-join "`0") -ceq ($Expected-join "`0") -and
        @($Value.PSObject.Properties|Where-Object{$_.MemberType -ne [Management.Automation.PSMemberTypes]::NoteProperty}).Count -eq 0
}

function New-CcodLifecycleWorkerRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TransactionId,
        [Parameter(Mandatory)][ValidateSet('Inspect','Close','RequestOrdinaryLaunch','ObserveOrdinary','Apply','VerifyRemote')][string]$Action,
        [Parameter(Mandatory)][string]$RuntimeId,
        [Parameter(Mandatory)][UInt64]$RuntimeGeneration,
        [Parameter(Mandatory)][UInt64]$LeaseEpoch,
        [Parameter(Mandatory)]$OwnerIdentity,
        [Parameter(Mandatory)][string]$NotBeforeUtc,
        [Parameter(Mandatory)][ValidateRange(1,600000)][int]$TimeoutMilliseconds
    )
    $request=[pscustomobject][ordered]@{
        schemaVersion=1;transactionId=$TransactionId;action=$Action;runtimeId=$RuntimeId
        runtimeGeneration=$RuntimeGeneration;leaseEpoch=$LeaseEpoch;ownerIdentity=$OwnerIdentity
        notBeforeUtc=$NotBeforeUtc;timeoutMilliseconds=$TimeoutMilliseconds
    }
    if(-not(Test-CcodWorkerCanonicalGuid $request.transactionId) -or $request.runtimeId -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$' -or
        $request.runtimeGeneration -eq 0 -or $request.leaseEpoch -eq 0 -or -not(Test-CcodWorkerCanonicalUtc $request.notBeforeUtc) -or
        -not(Test-CcodWorkerExactProperties $request.ownerIdentity @('pid','creationTimeUtc')) -or
        ($request.ownerIdentity.pid -isnot [int] -and $request.ownerIdentity.pid -isnot [long]) -or $request.ownerIdentity.pid -lt 1 -or $request.ownerIdentity.pid -gt [int]::MaxValue -or
        -not(Test-CcodWorkerCanonicalUtc $request.ownerIdentity.creationTimeUtc)){
        Throw-CcodWorkerRuntimeError 'CCOD_WORKER_REQUEST_INVALID' 'Lifecycle worker request is invalid' $request
    }
    return $request
}

function Assert-CcodLifecycleWorkerResult {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Result,[Parameter(Mandatory)]$ExpectedRequest)
    $fields=@('schemaVersion','transactionId','action','ok','outcome','observation','error')
    if(-not(Test-CcodWorkerExactProperties $Result $fields) -or $Result.schemaVersion -isnot [int] -or $Result.schemaVersion -ne 1 -or
        $Result.transactionId -isnot [string] -or $Result.transactionId -cne $ExpectedRequest.transactionId -or
        $Result.action -isnot [string] -or $Result.action -cne $ExpectedRequest.action -or $Result.ok -isnot [bool] -or
        $Result.outcome -isnot [string] -or [string]::IsNullOrWhiteSpace($Result.outcome) -or $Result.observation -isnot [string] -or [string]::IsNullOrWhiteSpace($Result.observation)){
        Throw-CcodWorkerRuntimeError 'CCOD_WORKER_RESULT_INVALID' 'Lifecycle worker result is invalid or uncorrelated' $Result
    }
    if($Result.ok){if($null -ne $Result.error){Throw-CcodWorkerRuntimeError 'CCOD_WORKER_RESULT_INVALID' 'Successful lifecycle result contains an error' $Result}}
    elseif(-not(Test-CcodWorkerExactProperties $Result.error @('code','stage','message')) -or $Result.error.code -isnot [string] -or $Result.error.code -cnotmatch '^CCOD_[A-Z0-9_]+$' -or
        $Result.error.stage -isnot [string] -or $Result.error.message -isnot [string]){
        Throw-CcodWorkerRuntimeError 'CCOD_WORKER_RESULT_INVALID' 'Failed lifecycle result has no stable error' $Result
    }
    return $Result
}

function Start-CcodWorkerProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Controller', 'StaticProbe', 'Lifecycle')][string]$Kind,
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string]$RequestPath,
        [Parameter(Mandatory)][string]$ResultPath,
        [AllowNull()][string]$StderrPath,
        [Parameter(Mandatory)][string]$PowerShellPath,
        [hashtable]$Adapters
    )

    foreach ($path in @($ScriptPath, $RequestPath, $ResultPath)) {
        if (-not [IO.Path]::IsPathRooted($path)) {
            Throw-CcodWorkerRuntimeError 'CCOD_WORKER_PATH_INVALID' 'Worker paths must be absolute' $path
        }
    }
    if (-not [IO.File]::Exists($ScriptPath)) {
        Throw-CcodWorkerRuntimeError 'CCOD_WORKER_SCRIPT_MISSING' 'Worker script does not exist' $ScriptPath
    }
    $adapter=Get-CcodWorkerRuntimeAdapters $Adapters;$parent=&$adapter.GetParentIdentity;$token=&$adapter.NewToken
    if($token-isnot[string]-or$token-cnotmatch'^[0-9a-f]{64}$'-or$null-eq$parent-or$parent.Pid-isnot[int]-or$parent.Pid-lt1-or$parent.SessionId-isnot[int]-or$parent.SessionId-lt0-or-not(Test-CcodWorkerRuntimeCanonicalUtc $parent.CreationTimeUtc)){Throw-CcodWorkerRuntimeError 'CCOD_WORKER_START_FAILED' 'Worker startup binding is invalid' $ScriptPath}
    $gate=$null;$job=$null;$process=$null;$assigned=$false;$success=$false
    try{$gate=&$adapter.CreateGate $token $parent;$job=&$adapter.CreateJob}catch{
        if($null-ne$gate){try{&$adapter.DisposeGate $gate|Out-Null}catch{}}
        if($null-ne$job){try{&$adapter.DisposeJob $job|Out-Null}catch{}}
        Throw-CcodWorkerRuntimeError 'CCOD_WORKER_START_FAILED' 'Worker containment could not be created' $ScriptPath
    }
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + [string]$ScriptPath + '" -RequestPath "' + [string]$RequestPath + '" -ResultPath "' + [string]$ResultPath + '"' +
        ' -StartupGateName "'+$gate.Name+'" -StartupGateToken '+$gate.Token+' -ExpectedParentPid '+$parent.Pid+' -ExpectedParentCreationTimeUtc "'+$parent.CreationTimeUtc+'"'
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = [string]$PowerShellPath
    $startInfo.Arguments = $arguments
    $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $startInfo.CreateNoWindow = $true
    $startInfo.UseShellExecute = $false
    try{
        $process=&$adapter.StartProcess $startInfo
        if($process-isnot[Diagnostics.Process]-or$process.Id-lt1-or$process.SessionId-ne$parent.SessionId){throw 'process'}
        $created=$process.StartTime.ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture)
        $assigned=[bool](&$adapter.AssignProcessToJob $job $process);if(-not$assigned){throw 'job'}
        $released=[bool](&$adapter.SignalGate $gate);if(-not$released-or-not$gate.Released){throw 'gate'}
        $success=$true
        return [pscustomobject][ordered]@{ProcessId=[int]$process.Id;CreationTimeUtc=$created;Handle=$process;JobHandle=$job;StartupGate=$gate}
    }catch{
        if($null-ne$process){
            if($assigned){try{&$adapter.DisposeJob $job|Out-Null}catch{}}
            else{try{[void](&$adapter.KillExactProcess $process)}catch{}}
            try{[void]$process.WaitForExit(5000)}catch{}
        }
        Throw-CcodWorkerRuntimeError 'CCOD_WORKER_START_FAILED' 'The supervisor worker could not be safely launched' $ScriptPath
    }finally{
        if(-not$success){if($null-ne$process){$process.Dispose()};if($null-ne$gate){try{&$adapter.DisposeGate $gate|Out-Null}catch{}};if($null-ne$job){try{&$adapter.DisposeJob $job|Out-Null}catch{}}}
    }
}

function Get-CcodWorkerPoll {
    [CmdletBinding()]
    param($Slot)

    if ($null -eq $Slot -or $Slot.ProcessId -isnot [int] -or $Slot.ProcessId -lt 1) {
        Throw-CcodWorkerRuntimeError 'CCOD_WORKER_SLOT_INVALID' 'Worker slot is invalid' $Slot
    }
    $completed = $false
    $exitCode = $null
    $probe = Get-Process -Id $Slot.ProcessId -ErrorAction SilentlyContinue
    if ($null -ne $probe) {
        try {
            $probe.Refresh()
            if ($probe.HasExited) {
                $completed = $true
                $exitCode = [int]$probe.ExitCode
            }
        } finally {
            $probe.Dispose()
        }
    } else {
        $completed = $true
        $exitCode = [int]0
    }
    $stdoutText = ''
    if ($completed -and [IO.File]::Exists($Slot.ResultPath)) {
        try {
            $stdoutText = [IO.File]::ReadAllText($Slot.ResultPath, [Text.UTF8Encoding]::new($false)).Trim()
        } catch {
            $stdoutText = ''
        }
    }
    $stdoutBytes = 0
    if (-not [string]::IsNullOrEmpty($stdoutText)) {
        $stdoutBytes = [Text.Encoding]::UTF8.GetByteCount($stdoutText)
    }
    $stderrBytes = 0
    if (-not [string]::IsNullOrWhiteSpace([string]$Slot.StderrPath) -and [IO.File]::Exists($Slot.StderrPath)) {
        try {
            $stderrBytes = [int](Get-Item -LiteralPath $Slot.StderrPath -Force -ErrorAction Stop).Length
        } catch {
            $stderrBytes = 0
        }
    }
    return [pscustomobject][ordered]@{
        Completed = [bool]$completed
        ExitCode = $exitCode
        StdoutText = [string]$stdoutText
        StdoutByteCount = [int]$stdoutBytes
        StdoutOverflow = $stdoutBytes -gt 1048576
        StderrByteCount = [int]$stderrBytes
        StderrOverflow = $stderrBytes -gt 65536
    }
}

function Read-CcodWorkerResult {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not [IO.File]::Exists($Path)) {
        Throw-CcodWorkerRuntimeError 'CCOD_WORKER_RESULT_MISSING' 'Worker result file is missing' $Path
    }
    return Read-CcodStrictJson -Path $Path -ExpectedSchema 1 -Kind 'worker result'
}

function Wait-CcodWorkerExit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Slot,
        [Parameter(Mandatory)][ValidateRange(1, 600000)][int]$TimeoutMilliseconds
    )

    $clock = [Diagnostics.Stopwatch]::StartNew()
    do {
        $handleExited=$false
        if($null-ne$Slot.PSObject.Properties['Handle']-and$Slot.Handle-is[Diagnostics.Process]){
            try{$Slot.Handle.Refresh();$handleExited=[bool]$Slot.Handle.HasExited}catch{$handleExited=$true}
        }
        $identity=Get-CcodWorkerIdentity -Pid $Slot.ProcessId
        $identityGone=$null-eq$identity-or$identity.CreationTimeUtc-cne$Slot.CreationTimeUtc
        if($identityGone-and($handleExited-or$null-eq$Slot.PSObject.Properties['Handle'])){return $true}
        if ($clock.ElapsedMilliseconds -ge [long]$TimeoutMilliseconds) { return $false }
        Start-Sleep -Milliseconds 100
    } while ($true)
}

function Get-CcodWorkerIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$Pid)

    $probe = Get-Process -Id $Pid -ErrorAction SilentlyContinue
    if ($null -eq $probe) { return $null }
    try {
        return [pscustomobject][ordered]@{
            Pid = [int]$probe.Id
            CreationTimeUtc = $probe.StartTime.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        }
    } catch { return $null }
    finally {
        $probe.Dispose()
    }
}

function Stop-CcodWorkerProcess {
    [CmdletBinding()]
    param($Slot)

    if ($null -eq $Slot -or $Slot.ProcessId -isnot [int] -or $Slot.ProcessId -lt 1) {
        Throw-CcodWorkerRuntimeError 'CCOD_WORKER_SLOT_INVALID' 'Worker slot is invalid' $Slot
    }
    $jobProperty=$Slot.PSObject.Properties['JobHandle']
    if($null-ne$jobProperty-and$null-ne$jobProperty.Value-and-not$jobProperty.Value.IsClosed){
        try{$jobProperty.Value.Dispose()}catch{return $false}
    }elseif($null-ne$Slot.PSObject.Properties['Handle']-and$Slot.Handle-is[Diagnostics.Process]){
        try{$Slot.Handle.Refresh();if(-not$Slot.Handle.HasExited){$Slot.Handle.Kill()}}catch{return $false}
    }else{return $false}
    return Wait-CcodWorkerExit -Slot $Slot -TimeoutMilliseconds 5000
}

function Close-CcodWorkerHandle {
    [CmdletBinding()]
    param($Slot)

    if($null-eq$Slot){return}
    if(-not(Wait-CcodWorkerExit -Slot $Slot -TimeoutMilliseconds 1)){Throw-CcodWorkerRuntimeError 'CCOD_WORKER_STILL_RUNNING' 'Worker containment cannot close while the exact child is alive' $Slot}
    if($null-ne$Slot.PSObject.Properties['StartupGate']-and$null-ne$Slot.StartupGate-and-not$Slot.StartupGate.Disposed){$Slot.StartupGate.Handle.Dispose();$Slot.StartupGate.Disposed=$true}
    if($null-ne$Slot.PSObject.Properties['JobHandle']-and$null-ne$Slot.JobHandle-and-not$Slot.JobHandle.IsClosed){$Slot.JobHandle.Dispose()}
    if($null-ne$Slot.PSObject.Properties['Handle']-and$null-ne$Slot.Handle){$Slot.Handle.Dispose()}
}

function Remove-CcodWorkerFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not [IO.Path]::IsPathRooted($Path)) {
        Throw-CcodWorkerRuntimeError 'CCOD_WORKER_PATH_INVALID' 'Worker file path must be absolute' $Path
    }
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        if (-not [IO.File]::Exists($Path)) { return }
        try {
            [IO.File]::Delete($Path)
            return
        } catch [IO.IOException] {
            if ($attempt -ge 19) { throw }
            Start-Sleep -Milliseconds 250
        }
    }
}

function Open-CcodLogDirectory {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not [IO.Directory]::Exists($Path)) {
        Throw-CcodWorkerRuntimeError 'CCOD_WORKER_LOG_MISSING' 'Log directory does not exist' $Path
    }
    Start-Process explorer.exe -ArgumentList ([string]$Path) -ErrorAction SilentlyContinue
}

function Get-CcodChatGptProcessIds {
    [CmdletBinding()]
    param()

    return ,[int[]]@(Get-Process -Name ChatGPT -ErrorAction SilentlyContinue | ForEach-Object {
        try { [int]$_.Id } finally { $_.Dispose() }
    })
}

Export-ModuleMember -Function @(
    'Get-CcodWorkerLeafState',
    'Write-CcodWorkerRequest',
    'New-CcodLifecycleWorkerRequest',
    'Assert-CcodLifecycleWorkerResult',
    'Wait-CcodWorkerStartupGate',
    'Start-CcodWorkerProcess',
    'Get-CcodWorkerPoll',
    'Read-CcodWorkerResult',
    'Wait-CcodWorkerExit',
    'Get-CcodWorkerIdentity',
    'Stop-CcodWorkerProcess',
    'Close-CcodWorkerHandle',
    'Remove-CcodWorkerFile',
    'Open-CcodLogDirectory',
    'Get-CcodChatGptProcessIds'
)
