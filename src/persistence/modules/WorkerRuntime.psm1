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

public sealed class CcodWorkerProcessSafeHandleV1 : SafeHandleZeroOrMinusOneIsInvalid {
    public CcodWorkerProcessSafeHandleV1(IntPtr value) : base(true) { SetHandle(value); }
    [DllImport("kernel32.dll", SetLastError=true)] private static extern bool CloseHandle(IntPtr handle);
    protected override bool ReleaseHandle() { return CloseHandle(handle); }
}

public sealed class CcodWorkerSuspendedProcessV1 : IDisposable {
    public UInt32 ProcessId { get; private set; }
    public CcodWorkerProcessSafeHandleV1 ProcessHandle { get; private set; }
    public CcodWorkerProcessSafeHandleV1 ThreadHandle { get; private set; }
    public CcodWorkerSuspendedProcessV1(UInt32 pid, IntPtr process, IntPtr thread) { ProcessId=pid; ProcessHandle=new CcodWorkerProcessSafeHandleV1(process); ThreadHandle=new CcodWorkerProcessSafeHandleV1(thread); }
    public void Dispose() { if(ThreadHandle!=null)ThreadHandle.Dispose(); if(ProcessHandle!=null)ProcessHandle.Dispose(); }
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
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] private struct STARTUPINFO { public UInt32 cb; public string lpReserved,lpDesktop,lpTitle; public UInt32 dwX,dwY,dwXSize,dwYSize,dwXCountChars,dwYCountChars,dwFillAttribute,dwFlags; public UInt16 wShowWindow,cbReserved2; public IntPtr lpReserved2,hStdInput,hStdOutput,hStdError; }
    [StructLayout(LayoutKind.Sequential)] private struct PROCESS_INFORMATION { public IntPtr hProcess,hThread; public UInt32 dwProcessId,dwThreadId; }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] private static extern bool CreateProcessW(string app, System.Text.StringBuilder command, IntPtr processAttributes, IntPtr threadAttributes, bool inheritHandles, UInt32 flags, IntPtr environment, string currentDirectory, ref STARTUPINFO startup, out PROCESS_INFORMATION processInfo);
    [DllImport("kernel32.dll", SetLastError=true)] private static extern UInt32 ResumeThread(CcodWorkerProcessSafeHandleV1 thread);
    [DllImport("kernel32.dll", SetLastError=true)] private static extern bool TerminateProcess(CcodWorkerProcessSafeHandleV1 process, UInt32 exitCode);
    [DllImport("kernel32.dll", SetLastError=true)] private static extern UInt32 WaitForSingleObject(CcodWorkerProcessSafeHandleV1 handle, UInt32 milliseconds);

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
    public static CcodWorkerSuspendedProcessV1 CreateSuspended(string file, string arguments) {
        STARTUPINFO startup=new STARTUPINFO(); startup.cb=(UInt32)Marshal.SizeOf(typeof(STARTUPINFO)); startup.dwFlags=1; startup.wShowWindow=0;
        PROCESS_INFORMATION info; var command=new System.Text.StringBuilder("\""+file+"\" "+arguments);
        if(!CreateProcessW(file,command,IntPtr.Zero,IntPtr.Zero,false,0x00000004|0x08000000,IntPtr.Zero,System.IO.Path.GetDirectoryName(file),ref startup,out info))throw new Win32Exception(Marshal.GetLastWin32Error());
        return new CcodWorkerSuspendedProcessV1(info.dwProcessId,info.hProcess,info.hThread);
    }
    public static bool Resume(CcodWorkerSuspendedProcessV1 process) { return process!=null && !process.ThreadHandle.IsClosed && ResumeThread(process.ThreadHandle)!=UInt32.MaxValue; }
    public static bool Terminate(CcodWorkerSuspendedProcessV1 process) { if(process==null||process.ProcessHandle.IsClosed)return false; bool ok=TerminateProcess(process.ProcessHandle,1); if(!ok)return false; return WaitForSingleObject(process.ProcessHandle,5000)==0; }
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

function Get-CcodWorkerRuntimeAdapters {
    param([hashtable]$Adapters)
    $resolved=@{
        CreateJob={Initialize-CcodWorkerJobNative;[CcodWorkerJobNativeV1]::CreateKillOnCloseJob()}
        CreateSuspendedProcess={param($File,$Arguments)Initialize-CcodWorkerJobNative;[CcodWorkerJobNativeV1]::CreateSuspended($File,$Arguments)}
        AssignProcessToJob={param($Job,$Native)[CcodWorkerJobNativeV1]::Assign($Job,$Native.ProcessHandle.DangerousGetHandle())}
        ResumeProcess={param($Native)[CcodWorkerJobNativeV1]::Resume($Native)}
        TerminateNativeProcess={param($Native)[CcodWorkerJobNativeV1]::Terminate($Native)}
        DisposeNativeProcess={param($Native)if($null-ne$Native){$Native.Dispose()}}
        DisposeJob={param($Job)if($null-ne$Job-and-not$Job.IsClosed){$Job.Dispose()}}
    }
    if($null-ne$Adapters){
        if($Adapters-isnot[hashtable]){Throw-CcodWorkerRuntimeError 'CCOD_WORKER_START_FAILED' 'Worker adapters are invalid' $Adapters}
        foreach($key in $Adapters.Keys){if(-not$resolved.ContainsKey($key)-or$Adapters[$key]-isnot[scriptblock]){Throw-CcodWorkerRuntimeError 'CCOD_WORKER_START_FAILED' 'Worker adapter is invalid' $key};$resolved[$key]=$Adapters[$key]}
    }
    return $resolved
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
    $adapter=Get-CcodWorkerRuntimeAdapters $Adapters;$job=$null;$native=$null;$process=$null;$assigned=$false;$resumed=$false;$success=$false
    try{$job=&$adapter.CreateJob}catch{Throw-CcodWorkerRuntimeError 'CCOD_WORKER_START_FAILED' 'Worker containment could not be created' $ScriptPath}
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + [string]$ScriptPath + '" -RequestPath "' + [string]$RequestPath + '" -ResultPath "' + [string]$ResultPath + '"'
    try{
        $native=&$adapter.CreateSuspendedProcess $PowerShellPath $arguments
        if($null-eq$native-or$native.ProcessId-lt1-or$null-eq$native.ProcessHandle-or$null-eq$native.ThreadHandle){throw 'native process'}
        $process=[Diagnostics.Process]::GetProcessById([int]$native.ProcessId)
        $created=$process.StartTime.ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture)
        $process.EnableRaisingEvents=$true
        $assigned=[bool](&$adapter.AssignProcessToJob $job $native);if(-not$assigned){throw 'job'}
        $resumed=[bool](&$adapter.ResumeProcess $native);if(-not$resumed){throw 'resume'}
        &$adapter.DisposeNativeProcess $native|Out-Null
        $success=$true
        return [pscustomobject][ordered]@{ProcessId=[int]$process.Id;CreationTimeUtc=$created;Handle=$process;JobHandle=$job}
    }catch{
        if($null-ne$native){try{[void](&$adapter.TerminateNativeProcess $native)}catch{}}
        if($assigned){try{&$adapter.DisposeJob $job|Out-Null}catch{}}
        Throw-CcodWorkerRuntimeError 'CCOD_WORKER_START_FAILED' 'The supervisor worker could not be safely launched' $ScriptPath
    }finally{
        if(-not$success){if($null-ne$process){$process.Dispose()};if($null-ne$native){try{&$adapter.DisposeNativeProcess $native|Out-Null}catch{}};if($null-ne$job){try{&$adapter.DisposeJob $job|Out-Null}catch{}}}
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
    $retainedHandle = $Slot.PSObject.Properties['Handle']
    if ($null -eq $retainedHandle -or $retainedHandle.Value -isnot [Diagnostics.Process]) {
        Throw-CcodWorkerRuntimeError 'CCOD_WORKER_SLOT_INVALID' 'Worker slot has no retained exact process handle' $Slot
    }
    $retainedHandle.Value.Refresh()
    if ($retainedHandle.Value.HasExited) {
        $completed = $true
        $exitCode = [int]$retainedHandle.Value.ExitCode
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
