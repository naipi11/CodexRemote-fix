Set-StrictMode -Version Latest

$script:CcodProcessSnapshotFields = @(
    'Pid',
    'CreationTimeUtc',
    'SessionId',
    'UserSid',
    'Path',
    'PackageFamilyName',
    'CommandLine',
    'ParentPid',
    'IsTopLevel',
    'Mode',
    'RendererPort',
    'MainPort'
)
$script:CcodNativeTypeName = 'Ccod.Persistence.Native.ProcessIdentityV1'
$script:CcodOrdinaryObservationBackoffMilliseconds = @(250, 500, 1000, 2000)

function Initialize-CcodProcessNativeApi {
    if ($null -ne ($script:CcodNativeTypeName -as [type])) { return }

    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Net;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;

namespace Ccod.Persistence.Native {
    public sealed class ProcessIdentityResult {
        public int Pid { get; set; }
        public string CreationTimeUtc { get; set; }
        public int SessionId { get; set; }
        public string UserSid { get; set; }
        public string Path { get; set; }
        public string PackageFamilyName { get; set; }
    }

    public sealed class ProcessCreationQueryResult {
        public string Stage { get; set; }
        public int Pid { get; set; }
        public string CreationTimeUtc { get; set; }
        public int ErrorCode { get; set; }
    }

    public static class ProcessCreationV1 {
        private const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;

        [StructLayout(LayoutKind.Sequential)]
        private struct FILETIME { public uint Low; public uint High; }

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr OpenProcess(uint access, bool inheritHandle, int processId);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr handle);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetProcessTimes(IntPtr process, out FILETIME creation, out FILETIME exit, out FILETIME kernel, out FILETIME user);

        private static ProcessCreationQueryResult Result(string stage, int pid, string creationTimeUtc, int errorCode) {
            return new ProcessCreationQueryResult { Stage = stage, Pid = pid, CreationTimeUtc = creationTimeUtc, ErrorCode = errorCode };
        }

        public static ProcessCreationQueryResult Query(int processId) {
            IntPtr process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, processId);
            if (process == IntPtr.Zero) return Result("OpenProcessFailed", processId, null, Marshal.GetLastWin32Error());
            try {
                FILETIME creation, exit, kernel, user;
                if (!GetProcessTimes(process, out creation, out exit, out kernel, out user)) {
                    return Result("GetProcessTimesFailed", processId, null, Marshal.GetLastWin32Error());
                }
                long fileTime = ((long)creation.High << 32) | creation.Low;
                return Result("Found", processId, DateTime.FromFileTimeUtc(fileTime).ToString("o"), 0);
            } finally { CloseHandle(process); }
        }
    }

    public static class ProcessIdentityV1 {
        private const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
        private const uint TOKEN_QUERY = 0x0008;
        private const int TokenUser = 1;
        private const int ERROR_INSUFFICIENT_BUFFER = 122;
        private const int APPMODEL_ERROR_NO_PACKAGE = 15700;

        [StructLayout(LayoutKind.Sequential)]
        private struct FILETIME { public uint Low; public uint High; }

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr OpenProcess(uint access, bool inheritHandle, int processId);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr handle);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetProcessTimes(IntPtr process, out FILETIME creation, out FILETIME exit, out FILETIME kernel, out FILETIME user);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool ProcessIdToSessionId(uint processId, out uint sessionId);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern bool QueryFullProcessImageName(IntPtr process, int flags, StringBuilder path, ref int size);

        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool OpenProcessToken(IntPtr process, uint desiredAccess, out IntPtr token);

        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool GetTokenInformation(IntPtr token, int informationClass, IntPtr information, int informationLength, out int returnLength);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetPackageFamilyName(IntPtr process, ref uint length, StringBuilder familyName);

        private static void ThrowLastError() { throw new Win32Exception(Marshal.GetLastWin32Error()); }

        private static string ReadUserSid(IntPtr process) {
            IntPtr token;
            if (!OpenProcessToken(process, TOKEN_QUERY, out token)) ThrowLastError();
            try {
                int required;
                GetTokenInformation(token, TokenUser, IntPtr.Zero, 0, out required);
                if (required <= 0 || Marshal.GetLastWin32Error() != ERROR_INSUFFICIENT_BUFFER) ThrowLastError();
                IntPtr buffer = Marshal.AllocHGlobal(required);
                try {
                    if (!GetTokenInformation(token, TokenUser, buffer, required, out required)) ThrowLastError();
                    IntPtr sid = Marshal.ReadIntPtr(buffer);
                    return new SecurityIdentifier(sid).Value;
                } finally { Marshal.FreeHGlobal(buffer); }
            } finally { CloseHandle(token); }
        }

        private static string ReadFamily(IntPtr process) {
            uint length = 0;
            int result = GetPackageFamilyName(process, ref length, null);
            if (result == APPMODEL_ERROR_NO_PACKAGE) return null;
            if (result != ERROR_INSUFFICIENT_BUFFER) throw new Win32Exception(result);
            StringBuilder family = new StringBuilder((int)length);
            result = GetPackageFamilyName(process, ref length, family);
            if (result == APPMODEL_ERROR_NO_PACKAGE) return null;
            if (result != 0) throw new Win32Exception(result);
            return family.ToString();
        }

        public static ProcessIdentityResult Query(int processId) {
            IntPtr process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, processId);
            if (process == IntPtr.Zero) ThrowLastError();
            try {
                FILETIME creation, exit, kernel, user;
                if (!GetProcessTimes(process, out creation, out exit, out kernel, out user)) ThrowLastError();
                long fileTime = ((long)creation.High << 32) | creation.Low;
                uint sessionId;
                if (!ProcessIdToSessionId((uint)processId, out sessionId)) ThrowLastError();
                int capacity = 32768;
                StringBuilder path = new StringBuilder(capacity);
                if (!QueryFullProcessImageName(process, 0, path, ref capacity)) ThrowLastError();
                return new ProcessIdentityResult {
                    Pid = processId,
                    CreationTimeUtc = DateTime.FromFileTimeUtc(fileTime).ToString("o"),
                    SessionId = (int)sessionId,
                    UserSid = ReadUserSid(process),
                    Path = path.ToString(),
                    PackageFamilyName = ReadFamily(process)
                };
            } finally { CloseHandle(process); }
        }
    }

    public sealed class ProcessStopResult {
        public string Outcome { get; set; }
        public bool StoppedByController { get; set; }
        public int Pid { get; set; }
        public string CreationTimeUtc { get; set; }
    }

    public static class CommandLineV1 {
        [DllImport("shell32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern IntPtr CommandLineToArgvW(string commandLine, out int argumentCount);

        [DllImport("kernel32.dll")]
        private static extern IntPtr LocalFree(IntPtr memory);

        public static string[] Parse(string commandLine) {
            if (String.IsNullOrWhiteSpace(commandLine)) return null;
            int count;
            IntPtr arguments = CommandLineToArgvW(commandLine, out count);
            if (arguments == IntPtr.Zero || count < 1) return null;
            try {
                string[] result = new string[count];
                for (int index = 0; index < count; index++) {
                    IntPtr value = Marshal.ReadIntPtr(arguments, index * IntPtr.Size);
                    result[index] = Marshal.PtrToStringUni(value);
                }
                return result;
            } finally { LocalFree(arguments); }
        }
    }

    public static class TcpListenerTableV1 {
        private const int AF_INET = 2;
        private const int TCP_TABLE_OWNER_PID_LISTENER = 3;
        private const int ERROR_INSUFFICIENT_BUFFER = 122;

        [StructLayout(LayoutKind.Sequential)]
        private struct MIB_TCPROW_OWNER_PID {
            public uint State;
            public uint LocalAddress;
            public uint LocalPort;
            public uint RemoteAddress;
            public uint RemotePort;
            public uint OwningPid;
        }

        [DllImport("iphlpapi.dll", SetLastError = true)]
        private static extern uint GetExtendedTcpTable(IntPtr table, ref int size, bool sort, int addressFamily, int tableClass, uint reserved);

        public static int[] GetListenerOwners(string address, int port) {
            IPAddress parsedAddress;
            if (!IPAddress.TryParse(address, out parsedAddress) || parsedAddress.AddressFamily != System.Net.Sockets.AddressFamily.InterNetwork) {
                throw new ArgumentException("An IPv4 address is required.");
            }
            int size = 0;
            uint result = GetExtendedTcpTable(IntPtr.Zero, ref size, true, AF_INET, TCP_TABLE_OWNER_PID_LISTENER, 0);
            if (result != ERROR_INSUFFICIENT_BUFFER) throw new Win32Exception((int)result);
            IntPtr buffer = Marshal.AllocHGlobal(size);
            try {
                result = GetExtendedTcpTable(buffer, ref size, true, AF_INET, TCP_TABLE_OWNER_PID_LISTENER, 0);
                if (result != 0) throw new Win32Exception((int)result);
                uint requestedAddress = BitConverter.ToUInt32(parsedAddress.GetAddressBytes(), 0);
                int count = Marshal.ReadInt32(buffer);
                int rowSize = Marshal.SizeOf(typeof(MIB_TCPROW_OWNER_PID));
                IntPtr rowPointer = IntPtr.Add(buffer, sizeof(uint));
                HashSet<int> owners = new HashSet<int>();
                for (int index = 0; index < count; index++) {
                    MIB_TCPROW_OWNER_PID row = (MIB_TCPROW_OWNER_PID)Marshal.PtrToStructure(rowPointer, typeof(MIB_TCPROW_OWNER_PID));
                    int localPort = (int)(((row.LocalPort & 0xFF) << 8) | ((row.LocalPort & 0xFF00) >> 8));
                    if (row.LocalAddress == requestedAddress && localPort == port) owners.Add((int)row.OwningPid);
                    rowPointer = IntPtr.Add(rowPointer, rowSize);
                }
                int[] values = new int[owners.Count];
                owners.CopyTo(values);
                Array.Sort(values);
                return values;
            } finally { Marshal.FreeHGlobal(buffer); }
        }
    }

    public static class ProcessStopV1 {
        private const uint PROCESS_TERMINATE = 0x0001;
        private const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
        private const uint SYNCHRONIZE = 0x00100000;
        private const uint WAIT_OBJECT_0 = 0;
        private const uint WAIT_TIMEOUT = 258;
        private const uint WAIT_FAILED = 0xFFFFFFFF;

        [StructLayout(LayoutKind.Sequential)]
        private struct FILETIME { public uint Low; public uint High; }

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr OpenProcess(uint access, bool inheritHandle, int processId);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr handle);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetProcessTimes(IntPtr process, out FILETIME creation, out FILETIME exit, out FILETIME kernel, out FILETIME user);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool TerminateProcess(IntPtr process, uint exitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

        private static ProcessStopResult Result(string outcome, bool stopped, int pid, string creation) {
            return new ProcessStopResult { Outcome = outcome, StoppedByController = stopped, Pid = pid, CreationTimeUtc = creation };
        }

        private static ProcessStopResult ErrorResult(int error, int pid, string creation) {
            if (error == 5) return Result("AccessDenied", false, pid, creation);
            if (error == 6 || error == 87 || error == 1168) return Result("ExitedBeforeStop", false, pid, creation);
            return Result("TimedOut", false, pid, creation);
        }

        public static ProcessStopResult StopVerified(int processId, string expectedCreationTimeUtc, int timeoutMilliseconds) {
            IntPtr process = OpenProcess(PROCESS_TERMINATE | PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE, false, processId);
            if (process == IntPtr.Zero) return ErrorResult(Marshal.GetLastWin32Error(), processId, expectedCreationTimeUtc);
            try {
                FILETIME creation, exit, kernel, user;
                if (!GetProcessTimes(process, out creation, out exit, out kernel, out user)) {
                    return ErrorResult(Marshal.GetLastWin32Error(), processId, expectedCreationTimeUtc);
                }
                long fileTime = ((long)creation.High << 32) | creation.Low;
                string actualCreation = DateTime.FromFileTimeUtc(fileTime).ToString("o");
                DateTime expected;
                if (!DateTime.TryParse(expectedCreationTimeUtc, null, System.Globalization.DateTimeStyles.RoundtripKind, out expected) ||
                    expected.ToUniversalTime().ToFileTimeUtc() != fileTime) {
                    return Result("IdentityChanged", false, processId, actualCreation);
                }
                uint priorWait = WaitForSingleObject(process, 0);
                if (priorWait == WAIT_OBJECT_0) return Result("ExitedBeforeStop", false, processId, actualCreation);
                if (priorWait == WAIT_FAILED) return ErrorResult(Marshal.GetLastWin32Error(), processId, actualCreation);
                if (!TerminateProcess(process, 1)) return ErrorResult(Marshal.GetLastWin32Error(), processId, actualCreation);
                uint wait = WaitForSingleObject(process, (uint)timeoutMilliseconds);
                if (wait == WAIT_OBJECT_0) return Result("StoppedByController", true, processId, actualCreation);
                if (wait == WAIT_FAILED) return ErrorResult(Marshal.GetLastWin32Error(), processId, actualCreation);
                return Result("TimedOut", false, processId, actualCreation);
            } finally { CloseHandle(process); }
        }
    }
}
'@
}

function Get-CcodDefaultProcessProbe {
    param([Parameter(Mandatory)][ValidateRange(1,2147483647)][int]$ProcessId)
    try {
        return [pscustomobject][ordered]@{Outcome='Found';Process=(Get-Process -Id $ProcessId -ErrorAction Stop)}
    } catch {
        $id=([string]$_.FullyQualifiedErrorId -split ',')[0]
        if($id -ceq 'NoProcessFoundForGivenId'){return [pscustomobject][ordered]@{Outcome='Absent';Process=$null}}
        throw
    }
}

function Test-CcodNativeProcessQueryProvesExit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Failure,
        [Parameter(Mandatory)][ValidateRange(1,2147483647)][int]$ProcessId,
        [scriptblock]$GetProcess = { param($Id) Get-CcodDefaultProcessProbe -ProcessId $Id }
    )

    $exception = $Failure.Exception
    while ($null -ne $exception -and $exception -isnot [ComponentModel.Win32Exception]) { $exception = $exception.InnerException }
    if ($null -eq $exception -or $exception.NativeErrorCode -ne 31) { return $false }
    $probe = $null
    try {
        $output=@(& $GetProcess $ProcessId 2>&1)
        if($output.Count-ne1-or$output[0]-is[Management.Automation.ErrorRecord]){return $false}
        $state=$output[0]
        if($state-isnot[pscustomobject]-or(@($state.PSObject.Properties.Name)-join',')-cne'Outcome,Process'){return $false}
        if($state.Outcome-ceq'Absent'){return $null-eq$state.Process}
        if($state.Outcome-cne'Found'-or$state.Process-isnot[Diagnostics.Process]){return $false}
        $probe=$state.Process
        $probe.Refresh()
        return [bool]$probe.HasExited
    } catch {
        return $false
    } finally {
        if ($probe -is [Diagnostics.Process]) { $probe.Dispose() }
    }
}

function Get-CcodDefaultNativeProcess {
    param([int]$ProcessId)

    Initialize-CcodProcessNativeApi
    try {
        return [Ccod.Persistence.Native.ProcessIdentityV1]::Query($ProcessId)
    } catch [ComponentModel.Win32Exception] {
        if ($_.Exception.NativeErrorCode -in @(6, 87, 1168)) { return $null }
        if (Test-CcodNativeProcessQueryProvesExit -Failure $_ -ProcessId $ProcessId) { return $null }
        throw
    }
}

function Get-CcodDefaultMinimalNativeProcess {
    param([Parameter(Mandatory)][ValidateRange(1,2147483647)][int]$ProcessId)

    Initialize-CcodProcessNativeApi
    $result = [Ccod.Persistence.Native.ProcessCreationV1]::Query($ProcessId)
    if ($null -eq $result -or $result.Pid -ne $ProcessId -or $result.Stage -isnot [string] -or $result.ErrorCode -isnot [int]) {
        throw [IO.InvalidDataException]::new('Minimal native process query returned a malformed receipt.')
    }
    switch -CaseSensitive ($result.Stage) {
        'Found' {
            if ($result.ErrorCode -ne 0 -or -not (Test-CcodCanonicalUtcTimestamp -Value $result.CreationTimeUtc)) {
                throw [IO.InvalidDataException]::new('Minimal native process query returned malformed creation evidence.')
            }
            return [pscustomobject][ordered]@{Outcome='Found';Pid=$ProcessId;CreationTimeUtc=[string]$result.CreationTimeUtc}
        }
        'OpenProcessFailed' {
            if ($result.ErrorCode -in @(87,1168) -and $null -eq $result.CreationTimeUtc) {
                return [pscustomobject][ordered]@{Outcome='Absent';Pid=$ProcessId;CreationTimeUtc=$null}
            }
            throw [ComponentModel.Win32Exception]::new([int]$result.ErrorCode)
        }
        'GetProcessTimesFailed' {
            throw [ComponentModel.Win32Exception]::new([int]$result.ErrorCode)
        }
        default { throw [IO.InvalidDataException]::new('Minimal native process query returned an unknown stage.') }
    }
}

function Get-CcodProcessIdentityObservation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateRange(1,2147483647)][int]$ProcessId,
        [Parameter(Mandatory)][string]$ExpectedCreationTimeUtc,
        [hashtable]$Adapters
    )

    if (-not (Test-CcodCanonicalUtcTimestamp -Value $ExpectedCreationTimeUtc)) {
        throw [IO.InvalidDataException]::new('ExpectedCreationTimeUtc must be a canonical UTC timestamp.')
    }
    $adapter = Get-CcodProcessAdapters -Adapters $Adapters
    $output = @(& $adapter.GetMinimalNativeProcess $ProcessId 2>&1)
    if ($output.Count -ne 1 -or $output[0] -is [Management.Automation.ErrorRecord]) {
        throw [IO.InvalidDataException]::new('Native process identity query emitted an invalid result stream.')
    }
    $identity = $output[0]
    if (-not (Test-CcodExactProperties -Value $identity -Names @('Outcome','Pid','CreationTimeUtc')) -or
        $identity.Outcome -isnot [string] -or @('Absent','Found') -cnotcontains $identity.Outcome -or
        $identity.Pid -isnot [int] -or $identity.Pid -ne $ProcessId -or
        ($identity.Outcome -ceq 'Absent' -and $null -ne $identity.CreationTimeUtc) -or
        ($identity.Outcome -ceq 'Found' -and -not (Test-CcodCanonicalUtcTimestamp -Value $identity.CreationTimeUtc))) {
        throw [IO.InvalidDataException]::new('Native process identity query returned a malformed receipt.')
    }
    if ($identity.Outcome -ceq 'Absent') {
        return [pscustomobject][ordered]@{ Outcome='Absent'; Pid=$ProcessId; CreationTimeUtc=$null }
    }
    $outcome = if ($identity.CreationTimeUtc -ceq $ExpectedCreationTimeUtc) { 'SameIdentity' } else { 'IdentityChanged' }
    return [pscustomobject][ordered]@{
        Outcome = $outcome
        Pid = $ProcessId
        CreationTimeUtc = [string]$identity.CreationTimeUtc
    }
}

function Get-CcodProcessRendererProbe {
    param([int]$RendererPort, [hashtable]$Adapters)
    try {
        $adapter = Get-CcodProcessAdapters -Adapters $Adapters
        $targets = @(& $adapter.ReadRendererTargets $RendererPort)
        $exact = @($targets | Where-Object {
            $null -ne $_ -and $null -ne $_.PSObject.Properties['type'] -and $null -ne $_.PSObject.Properties['url'] -and
            ($_.type -ceq 'page' -or $_.type -ceq 'webview') -and $_.url -ceq 'app://-/index.html'
        })
        if ($exact.Count -ne 1) { return [pscustomobject]@{ Valid = $false; RendererUrl = $null } }
        return [pscustomobject]@{ Valid = $true; RendererUrl = 'app://-/index.html' }
    } catch { return [pscustomobject]@{ Valid = $false; RendererUrl = $null } }
}

function Get-CcodProcessAdapters {
    param([hashtable]$Adapters)

    $resolved = @{
        GetPackageIdentity = {
            if ($null -eq (Get-Command Get-CcodPackageIdentity -ErrorAction SilentlyContinue)) {
                Import-Module (Join-Path $PSScriptRoot 'CompatibilityProbe.psm1') -Force
            }
            Get-CcodPackageIdentity
        }
        GetCurrentSessionId = { [Diagnostics.Process]::GetCurrentProcess().SessionId }
        GetCurrentUserSid = { [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }
        GetNativeProcess = { param($ProcessId) Get-CcodDefaultNativeProcess -ProcessId $ProcessId }
        GetMinimalNativeProcess = { param($ProcessId) Get-CcodDefaultMinimalNativeProcess -ProcessId $ProcessId }
        ObserveProcessIdentity = { param($ProcessId,$ExpectedCreationTimeUtc) Get-CcodProcessIdentityObservation -ProcessId $ProcessId -ExpectedCreationTimeUtc $ExpectedCreationTimeUtc }
        GetCimProcess = {
            param($ProcessId)
            Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $([int]$ProcessId)" -ErrorAction Stop
        }
        ParseCommandLine = {
            param($CommandLine)
            Initialize-CcodProcessNativeApi
            [Ccod.Persistence.Native.CommandLineV1]::Parse([string]$CommandLine)
        }
        GetListeningPortOwnerPids = {
            param($Port, $Address)
            Initialize-CcodProcessNativeApi
            @([Ccod.Persistence.Native.TcpListenerTableV1]::GetListenerOwners([string]$Address, [int]$Port))
        }
        ReadRendererTargets = {
            param($RendererPort)
            $response = $null
            $reader = $null
            try {
                $request = [Net.HttpWebRequest][Net.WebRequest]::Create(('http://127.0.0.1:{0}/json/list' -f [int]$RendererPort))
                $request.Timeout = 1000
                $request.AllowAutoRedirect = $false
                $request.Proxy = $null
                $response = $request.GetResponse()
                if ($response.StatusCode -ne [Net.HttpStatusCode]::OK) { return @() }
                $reader = [IO.StreamReader]::new($response.GetResponseStream(), [Text.UTF8Encoding]::new($false))
                $value = $reader.ReadToEnd() | ConvertFrom-Json -ErrorAction Stop
                if ($null -eq $value -or $value -isnot [array]) { return @() }
                return @($value)
            } catch { return @() }
            finally {
                if ($null -ne $reader) { $reader.Dispose() }
                if ($null -ne $response) { $response.Dispose() }
            }
        }
        ProbeSpecial = {
            param($ProcessId, $RendererPort, $MainPort)
            try {
                $targets = @(& $resolved.ReadRendererTargets $RendererPort)
                $exact = @($targets | Where-Object {
                    $null -ne $_ -and $null -ne $_.PSObject.Properties['type'] -and $null -ne $_.PSObject.Properties['url'] -and
                    ($_.type -ceq 'page' -or $_.type -ceq 'webview') -and $_.url -ceq 'app://-/index.html'
                })
                if ($exact.Count -eq 1) { return [pscustomobject]@{ Valid = $true; RendererUrl = 'app://-/index.html' } }
            } catch { }
            return [pscustomobject]@{ Valid = $false; RendererUrl = $null }
        }.GetNewClosure()
        GetProcess = { param($ProcessId, $StatusEvidence) Get-CcodProcessSnapshot -ProcessId $ProcessId -StatusEvidence $StatusEvidence }
        ListProcessIds = { @((Get-Process -Name 'ChatGPT' -ErrorAction SilentlyContinue).Id) }
        StopProcess = {
            param($Snapshot, $TimeoutMilliseconds)
            Initialize-CcodProcessNativeApi
            [Ccod.Persistence.Native.ProcessStopV1]::StopVerified(
                [int]$Snapshot.Pid,
                [string]$Snapshot.CreationTimeUtc,
                [int]$TimeoutMilliseconds
            )
        }
        GetGracefulCloseProcess = { param($ProcessId) Get-Process -Id ([int]$ProcessId) -ErrorAction Stop }
        GetGracefulCloseCreationTimeUtc = {
            param($Process)
            $Process.StartTime.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        }
        CloseGracefulProcess = { param($Process) [bool]$Process.CloseMainWindow() }
        DisposeGracefulProcess = { param($Process) $Process.Dispose() }
        ReserveLoopbackPort = {
            param($Address)
            $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Parse([string]$Address), 0)
            try {
                $listener.Start()
                return [int]$listener.LocalEndpoint.Port
            } finally { $listener.Stop() }
        }
        TestLoopbackPortAvailable = {
            param($Port, $Address)
            $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Parse([string]$Address), [int]$Port)
            try {
                $listener.Start()
                return $true
            } catch [Net.Sockets.SocketException] {
                return $false
            } finally { $listener.Stop() }
        }
        ProbeLoopbackPort = {
            param($Port)
            $client = [Net.Sockets.TcpClient]::new([Net.Sockets.AddressFamily]::InterNetwork)
            try {
                $client.Connect('127.0.0.1', [int]$Port)
                return 'Open'
            } catch [Net.Sockets.SocketException] {
                if ($_.Exception.SocketErrorCode -eq [Net.Sockets.SocketError]::ConnectionRefused) { return 'Refused' }
                return 'Error'
            } finally { $client.Dispose() }
        }
        GetUtcNow = { [DateTimeOffset]::UtcNow }
        StartStopwatch = { [Diagnostics.Stopwatch]::StartNew() }
        GetElapsedMilliseconds = { param($Clock) [long]$Clock.ElapsedMilliseconds }
        Delay = { param($Milliseconds) Start-Sleep -Milliseconds ([int]$Milliseconds) }
        StartProcess = {
            param($FilePath, $Arguments, $WindowStyle)
            $parameters = @{
                FilePath = [string]$FilePath
                ArgumentList = @($Arguments)
                PassThru = $true
                ErrorAction = 'Stop'
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$WindowStyle)) { $parameters.WindowStyle = [string]$WindowStyle }
            Start-Process @parameters
        }
    }
    if ($null -ne $Adapters) {
        foreach ($name in $Adapters.Keys) { $resolved[$name] = $Adapters[$name] }
    }
    if ($null -eq $Adapters -or -not $Adapters.ContainsKey('ActivatePackagedApplication')) {
        $resolved.ActivatePackagedApplication = {
            param($AppUserModelId)
            if ($AppUserModelId -isnot [string] -or $AppUserModelId -cnotmatch '^[A-Za-z0-9._-]{1,128}![A-Za-z0-9._-]{1,64}$') { return $null }
            $explorerPath = [IO.Path]::GetFullPath((Join-Path $env:WINDIR 'explorer.exe'))
            if (-not [IO.File]::Exists($explorerPath)) { return $null }
            & $resolved.StartProcess $explorerPath @("shell:AppsFolder\$AppUserModelId") $null
        }.GetNewClosure()
    }
    if ($null -eq $Adapters -or -not $Adapters.ContainsKey('ProbeSpecial')) {
        $resolved.ProbeSpecial = {
            param($ProcessId, $RendererPort, $MainPort)
            try {
                $targets = @(& $resolved.ReadRendererTargets $RendererPort)
                $exact = @($targets | Where-Object {
                    $null -ne $_ -and $null -ne $_.PSObject.Properties['type'] -and $null -ne $_.PSObject.Properties['url'] -and
                    ($_.type -ceq 'page' -or $_.type -ceq 'webview') -and $_.url -ceq 'app://-/index.html'
                })
                if ($exact.Count -eq 1) { return [pscustomobject]@{ Valid = $true; RendererUrl = 'app://-/index.html' } }
            } catch { }
            return [pscustomobject]@{ Valid = $false; RendererUrl = $null }
        }.GetNewClosure()
    }
    if ($null -eq $Adapters -or -not $Adapters.ContainsKey('RequestGracefulClose')) {
        $resolved.RequestGracefulClose = {
            param($Snapshot)
            $process = $null
            try {
                $process = & $resolved.GetGracefulCloseProcess ([int]$Snapshot.Pid)
                if ($null -eq $process) { return [pscustomobject]@{ IdentityMatched=$false; Requested=$false } }
                $creation = & $resolved.GetGracefulCloseCreationTimeUtc $process
                if ($creation -isnot [string] -or -not (Test-CcodOrdinalIgnoreCase $creation ([string]$Snapshot.CreationTimeUtc))) {
                    return [pscustomobject]@{ IdentityMatched=$false; Requested=$false }
                }
                return [pscustomobject]@{ IdentityMatched=$true; Requested=[bool](& $resolved.CloseGracefulProcess $process) }
            } catch {
                return [pscustomobject]@{ IdentityMatched=$false; Requested=$false }
            } finally {
                if ($null -ne $process) { try { & $resolved.DisposeGracefulProcess $process } catch {} }
            }
        }.GetNewClosure()
    }
    return $resolved
}

function Test-CcodOrdinalIgnoreCase {
    param([AllowNull()][string]$Left, [AllowNull()][string]$Right)
    return [string]::Equals($Left, $Right, [StringComparison]::OrdinalIgnoreCase)
}

function Get-CcodStatusEvidence {
    param($StatusEvidence)

    if ($null -eq $StatusEvidence) { return $null }
    if ($null -ne $StatusEvidence.PSObject.Properties['session'] -and $null -ne $StatusEvidence.session -and
        $null -ne $StatusEvidence.session.PSObject.Properties['codex']) {
        return $StatusEvidence.session.codex
    }
    return $StatusEvidence
}

function Test-CcodExactProperties {
    param(
        $Value,
        [Parameter(Mandatory)][string[]]$Names
    )

    if ($null -eq $Value) { return $false }
    $actual = @($Value.PSObject.Properties.Name)
    if ($actual.Count -ne $Names.Count) { return $false }
    foreach ($name in $Names) {
        if ($actual -cnotcontains $name) { return $false }
    }
    return $true
}

function ConvertTo-CcodStateInt32 {
    param(
        $Value,
        [Parameter(Mandatory)][int]$Minimum,
        [Parameter(Mandatory)][int]$Maximum
    )

    if ($Value -isnot [int] -and $Value -isnot [long]) { return $null }
    $numeric = [long]$Value
    if ($numeric -lt $Minimum -or $numeric -gt $Maximum) { return $null }
    return [int]$numeric
}

function Test-CcodSpecialStatusProof {
    param(
        $Status,
        $Package,
        $SnapshotIdentity,
        [int]$RendererPort,
        [int]$MainPort
    )

    $names = @('pid','creationTimeUtc','packageFullName','packageVersion','appAsarSha256','mainPort','rendererPort','mainProbe','rendererProbe')
    if (-not (Test-CcodExactProperties -Value $Status -Names $names)) { return $false }
    $statusPid = ConvertTo-CcodStateInt32 -Value $Status.pid -Minimum 1 -Maximum ([int]::MaxValue)
    $statusMainPort = ConvertTo-CcodStateInt32 -Value $Status.mainPort -Minimum 1 -Maximum 65535
    $statusRendererPort = ConvertTo-CcodStateInt32 -Value $Status.rendererPort -Minimum 1 -Maximum 65535
    if ($null -eq $statusPid -or $null -eq $statusMainPort -or $null -eq $statusRendererPort) { return $false }
    foreach ($name in @('creationTimeUtc','packageFullName','packageVersion','appAsarSha256','mainProbe','rendererProbe')) {
        if ($Status.$name -isnot [string]) { return $false }
    }
    return [object]::Equals($statusPid, [int]$SnapshotIdentity.Pid) -and
        $Status.creationTimeUtc -ceq $SnapshotIdentity.CreationTimeUtc -and
        $Status.packageFullName -ceq $Package.FullName -and
        $Status.packageVersion -ceq $Package.Version -and
        $Status.appAsarSha256 -cmatch '^[0-9a-f]{64}$' -and
        [object]::Equals($statusRendererPort, $RendererPort) -and
        [object]::Equals($statusMainPort, $MainPort) -and
        $Status.mainProbe -ceq 'Closed' -and
        $Status.rendererProbe -ceq 'BridgeValid'
}

function Test-CcodSpecialProbeProof {
    param($Probe)

    if (-not (Test-CcodExactProperties -Value $Probe -Names @('Valid','RendererUrl'))) { return $false }
    return $Probe.Valid -is [bool] -and $Probe.Valid -eq $true -and
        $Probe.RendererUrl -is [string] -and $Probe.RendererUrl -ceq 'app://-/index.html'
}

function Get-CcodParsedLaunchArguments {
    param(
        [AllowNull()]$CommandLine,
        [Parameter(Mandatory)][string]$ExecutablePath,
        [Parameter(Mandatory)][hashtable]$Adapters
    )

    $invalid = [pscustomobject]@{
        Valid = $false
        IsTopLevel = $false
        HasDebugSwitch = $false
        RendererDebugOnlyValid = $false
        SpecialArgumentsValid = $false
        RendererPort = $null
        MainPort = $null
    }
    if ($CommandLine -isnot [string] -or [string]::IsNullOrWhiteSpace($CommandLine)) { return $invalid }
    try { $arguments = @(& $Adapters.ParseCommandLine $CommandLine) } catch { return $invalid }
    if ($arguments.Count -lt 1 -or $arguments[0] -isnot [string] -or
        -not (Test-CcodOrdinalIgnoreCase $arguments[0] $ExecutablePath)) { return $invalid }
    foreach ($argument in $arguments) {
        if ($argument -isnot [string] -or $null -eq $argument) { return $invalid }
    }

    $hasType = $false
    $debugCount = 0
    $addressCount = 0
    $rendererCount = 0
    $mainCount = 0
    $inspectorCount = 0
    $unrecognizedDebug = $false
    $rendererPort = $null
    $mainPort = $null
    foreach ($argument in @($arguments | Select-Object -Skip 1)) {
        if ($argument -imatch '^(?:--|-|/)type(?:=|$)') { $hasType = $true }
        $isDebug = $argument -imatch '^(?:--|-|/)(?:remote-debugging|inspect)'
        if (-not $isDebug) { continue }
        $debugCount++
        if ($argument -ceq '--remote-debugging-address=127.0.0.1') {
            $addressCount++
            continue
        }
        if ($argument -cmatch '^--remote-debugging-port=(?<port>[0-9]{1,5})$') {
            $parsedPort = 0
            if ([int]::TryParse($Matches.port, [ref]$parsedPort) -and $parsedPort -ge 1 -and $parsedPort -le 65535) {
                $rendererCount++
                $rendererPort = $parsedPort
                continue
            }
        }
        if ($argument -cmatch '^--inspect=127\.0\.0\.1:(?<port>[0-9]{1,5})$') {
            $parsedPort = 0
            if ([int]::TryParse($Matches.port, [ref]$parsedPort) -and $parsedPort -ge 1 -and $parsedPort -le 65535) {
                $mainCount++
                $inspectorCount++
                $mainPort = $parsedPort
                continue
            }
        }
        $unrecognizedDebug = $true
    }

    $rendererDebugOnlyValid = -not $hasType -and -not $unrecognizedDebug -and
        $debugCount -eq 2 -and $addressCount -eq 1 -and $rendererCount -eq 1 -and
        $mainCount -eq 0 -and $rendererPort -ge 1
    $specialValid = -not $hasType -and -not $unrecognizedDebug -and $debugCount -eq 3 -and
        $addressCount -eq 1 -and $rendererCount -eq 1 -and $mainCount -eq 1 -and
        $rendererPort -ne $mainPort
    return [pscustomobject]@{
        Valid = $true
        IsTopLevel = -not $hasType
        HasDebugSwitch = $debugCount -gt 0
        RendererDebugOnlyValid = $rendererDebugOnlyValid
        SpecialArgumentsValid = $specialValid
        RendererPort = if ($null -eq $rendererPort) { $null } else { [int]$rendererPort }
        MainPort = if ($null -eq $mainPort) { $null } else { [int]$mainPort }
    }
}

function ConvertTo-CcodProcessIdValue {
    param(
        [AllowNull()]$Value,
        [int]$Minimum = 1
    )

    $allowedTypes = @(
        [byte], [sbyte], [int16], [uint16], [int], [uint32], [long], [uint64]
    )
    if ($null -eq $Value -or $allowedTypes -notcontains $Value.GetType()) {
        return [pscustomobject]@{ Valid=$false; Value=$null }
    }
    try { $numeric = [decimal]$Value } catch { return [pscustomobject]@{ Valid=$false; Value=$null } }
    if ($numeric -lt $Minimum -or $numeric -gt [int]::MaxValue) {
        return [pscustomobject]@{ Valid=$false; Value=$null }
    }
    return [pscustomobject]@{ Valid=$true; Value=[int]$numeric }
}

function Get-CcodProcessSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateRange(1, 2147483647)][int]$ProcessId,
        $StatusEvidence,
        [hashtable]$Adapters
    )

    $adapter = Get-CcodProcessAdapters -Adapters $Adapters
    $package = & $adapter.GetPackageIdentity
    if ($null -eq $package -or $null -eq $package.PSObject.Properties['Found'] -or -not $package.Found) { return $null }
    foreach ($name in @('FullName', 'FamilyName', 'Version', 'ExecutablePath')) {
        if ($null -eq $package.PSObject.Properties[$name] -or [string]::IsNullOrWhiteSpace([string]$package.$name)) { return $null }
    }

    $before = & $adapter.GetNativeProcess $ProcessId
    if ($null -eq $before -or $before.Pid -isnot [int] -or -not [object]::Equals($before.Pid, [int]$ProcessId)) { return $null }
    $cim = & $adapter.GetCimProcess $ProcessId
    if ($null -eq $cim -or $null -eq $cim.PSObject.Properties['ProcessId']) { return $null }
    $cimProcessId = ConvertTo-CcodProcessIdValue -Value $cim.ProcessId
    if (-not $cimProcessId.Valid -or -not [object]::Equals($cimProcessId.Value, [int]$ProcessId)) { return $null }
    $parentProcessId = $null
    if ($null -ne $cim.PSObject.Properties['ParentProcessId'] -and $null -ne $cim.ParentProcessId) {
        $convertedParent = ConvertTo-CcodProcessIdValue -Value $cim.ParentProcessId -Minimum 0
        if (-not $convertedParent.Valid) { return $null }
        $parentProcessId = $convertedParent.Value
    }
    $after = & $adapter.GetNativeProcess $ProcessId
    if ($null -eq $after -or $after.Pid -isnot [int] -or -not [object]::Equals($after.Pid, [int]$ProcessId) -or
        -not [object]::Equals($before.CreationTimeUtc, $after.CreationTimeUtc)) { return $null }

    $commandLine = if ($null -eq $cim.PSObject.Properties['CommandLine']) { $null } else { $cim.CommandLine }
    $launchArguments = Get-CcodParsedLaunchArguments -CommandLine $commandLine -ExecutablePath $package.ExecutablePath -Adapters $adapter
    $isTopLevel = $launchArguments.Valid -and $launchArguments.IsTopLevel
    $currentSessionId = & $adapter.GetCurrentSessionId
    $currentUserSid = & $adapter.GetCurrentUserSid
    $eligibleRoot = $isTopLevel -and
        $before.SessionId -eq $currentSessionId -and
        $before.UserSid -ceq $currentUserSid -and
        [IO.Path]::GetFileName([string]$before.Path) -ieq 'ChatGPT.exe' -and
        (Test-CcodOrdinalIgnoreCase $before.Path $package.ExecutablePath) -and
        $before.PackageFamilyName -ceq $package.FamilyName

    $rendererPort = $launchArguments.RendererPort
    $mainPort = $launchArguments.MainPort
    $mode = 'Unrelated'
    if ($eligibleRoot -and -not $launchArguments.HasDebugSwitch) {
        $mode = 'Ordinary'
    } elseif ($eligibleRoot -and $launchArguments.RendererDebugOnlyValid) {
        $mode = 'Ordinary'
    } elseif ($eligibleRoot -and $launchArguments.SpecialArgumentsValid) {
        $status = Get-CcodStatusEvidence -StatusEvidence $StatusEvidence
        if (Test-CcodSpecialStatusProof -Status $status -Package $package -SnapshotIdentity $before -RendererPort $rendererPort -MainPort $mainPort) {
            $probe = & $adapter.ProbeSpecial $ProcessId $rendererPort $mainPort
            if (Test-CcodSpecialProbeProof -Probe $probe) { $mode = 'Special' }
        }
    }
    if ($mode -ceq 'Ordinary') {
        $rendererPort = $null
        $mainPort = $null
    }

    return [pscustomobject][ordered]@{
        Pid = [int]$before.Pid
        CreationTimeUtc = [string]$before.CreationTimeUtc
        SessionId = [int]$before.SessionId
        UserSid = [string]$before.UserSid
        Path = [string]$before.Path
        PackageFamilyName = [string]$before.PackageFamilyName
        CommandLine = $commandLine
        ParentPid = $parentProcessId
        IsTopLevel = [bool]$isTopLevel
        Mode = $mode
        RendererPort = if ($null -eq $rendererPort) { $null } else { [int]$rendererPort }
        MainPort = if ($null -eq $mainPort) { $null } else { [int]$mainPort }
    }
}

function Test-CcodProcessMatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Expected,
        [Parameter(Mandatory)]$Actual
    )

    foreach ($field in $script:CcodProcessSnapshotFields) {
        $expectedProperty = $Expected.PSObject.Properties[$field]
        $actualProperty = $Actual.PSObject.Properties[$field]
        if ($null -eq $expectedProperty -or $null -eq $actualProperty) { return $false }
        if (-not [object]::Equals($expectedProperty.Value, $actualProperty.Value)) { return $false }
    }
    return $true
}

function Get-CcodStalePackageProcessSnapshot {
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        [Parameter(Mandatory)]$Package,
        [Parameter(Mandatory)][hashtable]$Adapter
    )

    $before = & $Adapter.GetNativeProcess $ProcessId
    if ($null -eq $before -or $before.Pid -isnot [int] -or -not [object]::Equals($before.Pid, $ProcessId)) { return $null }
    $cim = & $Adapter.GetCimProcess $ProcessId
    if ($null -eq $cim -or $null -eq $cim.PSObject.Properties['ProcessId']) { return $null }
    $cimProcessId = ConvertTo-CcodProcessIdValue -Value $cim.ProcessId
    if (-not $cimProcessId.Valid -or -not [object]::Equals($cimProcessId.Value, $ProcessId)) { return $null }
    $parentProcessId = $null
    if ($null -ne $cim.PSObject.Properties['ParentProcessId'] -and $null -ne $cim.ParentProcessId) {
        $convertedParent = ConvertTo-CcodProcessIdValue -Value $cim.ParentProcessId -Minimum 0
        if (-not $convertedParent.Valid) { return $null }
        $parentProcessId = $convertedParent.Value
    }
    $after = & $Adapter.GetNativeProcess $ProcessId
    if ($null -eq $after -or $after.Pid -isnot [int] -or -not [object]::Equals($after.Pid, $ProcessId) -or
        -not [object]::Equals($before.CreationTimeUtc, $after.CreationTimeUtc)) { return $null }
    $commandLine = if ($null -eq $cim.PSObject.Properties['CommandLine']) { $null } else { $cim.CommandLine }
    $launchArguments = Get-CcodParsedLaunchArguments -CommandLine $commandLine -ExecutablePath ([string]$before.Path) -Adapters $Adapter
    return [pscustomobject][ordered]@{
        Pid = [int]$before.Pid
        CreationTimeUtc = [string]$before.CreationTimeUtc
        SessionId = [int]$before.SessionId
        UserSid = [string]$before.UserSid
        Path = [string]$before.Path
        PackageFamilyName = [string]$before.PackageFamilyName
        CommandLine = $commandLine
        ParentPid = $parentProcessId
        IsTopLevel = [bool]($launchArguments.Valid -and $launchArguments.IsTopLevel)
        Mode = 'Unrelated'
        RendererPort = if ($null -eq $launchArguments.RendererPort) { $null } else { [int]$launchArguments.RendererPort }
        MainPort = if ($null -eq $launchArguments.MainPort) { $null } else { [int]$launchArguments.MainPort }
    }
}

function New-CcodStalePackageRootResult {
    param(
        [Parameter(Mandatory)][ValidateSet('Confirmed', 'NoCandidate', 'Incomplete', 'Ambiguous')][string]$Outcome,
        $Snapshot
    )

    return [pscustomobject][ordered]@{
        Outcome = $Outcome
        Snapshot = if ($null -eq $Snapshot) { $null } else { Copy-CcodProcessSnapshot -Snapshot $Snapshot }
    }
}

function Get-CcodPackageFullNameParts {
    param($Package)

    if ($null -eq $Package) { return $null }
    foreach ($name in @('FullName', 'FamilyName', 'Version', 'ExecutablePath')) {
        if ($null -eq $Package.PSObject.Properties[$name] -or $Package.$name -isnot [string] -or [string]::IsNullOrWhiteSpace($Package.$name)) { return $null }
    }
    $match = [regex]::Match([string]$Package.FullName, '^(?<name>.+)_(?<version>\d+\.\d+\.\d+\.\d+)_(?<architecture>[^_]+)__(?<publisher>[^_]+)$', [Text.RegularExpressions.RegexOptions]::CultureInvariant)
    if (-not $match.Success -or $match.Groups['version'].Value -cne [string]$Package.Version) { return $null }
    if (([string]$Package.FamilyName) -cne ($match.Groups['name'].Value + '_' + $match.Groups['publisher'].Value)) { return $null }
    return [pscustomobject]@{
        Name = $match.Groups['name'].Value
        Version = $match.Groups['version'].Value
        Architecture = $match.Groups['architecture'].Value
        Publisher = $match.Groups['publisher'].Value
    }
}

function Test-CcodStalePackageRootSnapshot {
    param(
        $Snapshot,
        [Parameter(Mandatory)]$Package,
        [Parameter(Mandatory)]$PackageParts,
        [Parameter(Mandatory)][hashtable]$Adapter
    )

    if ($null -eq $Snapshot -or -not (Test-CcodExactProperties -Value $Snapshot -Names $script:CcodProcessSnapshotFields)) { return $false }
    if ($Snapshot.Pid -isnot [int] -or $Snapshot.Pid -lt 1 -or $Snapshot.SessionId -isnot [int] -or
        $Snapshot.UserSid -isnot [string] -or [string]::IsNullOrWhiteSpace($Snapshot.UserSid) -or
        $Snapshot.Path -isnot [string] -or $Snapshot.PackageFamilyName -isnot [string] -or
        $Snapshot.CommandLine -isnot [string] -or $Snapshot.IsTopLevel -isnot [bool] -or -not $Snapshot.IsTopLevel -or
        $Snapshot.Mode -isnot [string] -or $Snapshot.Mode -cne 'Unrelated' -or
        $Snapshot.RendererPort -isnot [int] -or $Snapshot.MainPort -isnot [int] -or
        $Snapshot.RendererPort -lt 1 -or $Snapshot.RendererPort -gt 65535 -or
        $Snapshot.MainPort -lt 1 -or $Snapshot.MainPort -gt 65535 -or $Snapshot.RendererPort -eq $Snapshot.MainPort) { return $false }
    $launchArguments = Get-CcodParsedLaunchArguments -CommandLine $Snapshot.CommandLine -ExecutablePath $Snapshot.Path -Adapters $Adapter
    if (-not $launchArguments.SpecialArgumentsValid -or $launchArguments.RendererPort -ne $Snapshot.RendererPort -or $launchArguments.MainPort -ne $Snapshot.MainPort) { return $false }
    if (-not (Test-CcodOrdinalIgnoreCase $Snapshot.PackageFamilyName $Package.FamilyName) -or
        (Test-CcodOrdinalIgnoreCase $Snapshot.Path $Package.ExecutablePath) -or
        [IO.Path]::GetFileName($Snapshot.Path) -ine 'ChatGPT.exe' -or
        $null -eq (ConvertTo-CcodDateTimeOffset -Value $Snapshot.CreationTimeUtc)) { return $false }

    # Path is native process-image evidence paired with GetPackageFamilyName.  Accept
    # only the protected WindowsApps long-path spelling; aliases/reparse-like forms
    # are not normalized into the closure boundary.
    $pathPattern = '^C:\\Program Files\\WindowsApps\\' + [regex]::Escape($PackageParts.Name) + '_(?<version>\d+\.\d+\.\d+\.\d+)_' +
        [regex]::Escape($PackageParts.Architecture) + '__' + [regex]::Escape($PackageParts.Publisher) + '\\app\\ChatGPT\.exe$'
    $pathMatch = [regex]::Match($Snapshot.Path, $pathPattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [Text.RegularExpressions.RegexOptions]::CultureInvariant)
    if (-not $pathMatch.Success) { return $false }
    try {
        $candidateVersion = [Version]$pathMatch.Groups['version'].Value
        $currentVersion = [Version]$PackageParts.Version
    } catch { return $false }
    if ($candidateVersion.CompareTo($currentVersion) -ge 0) { return $false }
    return $true
}

function Get-CcodStalePackageRootResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Package,
        [AllowEmptyCollection()][object[]]$Snapshots = @(),
        [AllowEmptyCollection()][int[]]$ProcessIds = @(),
        [hashtable]$Adapters
    )

    $parts = Get-CcodPackageFullNameParts -Package $Package
    if ($null -eq $parts) { return New-CcodStalePackageRootResult -Outcome Incomplete -Snapshot $null }
    $adapter = Get-CcodProcessAdapters -Adapters $Adapters
    $rawMode = $PSBoundParameters.ContainsKey('ProcessIds') -or -not $PSBoundParameters.ContainsKey('Snapshots')
    $rawIncomplete = $false
    $observed = if ($rawMode) {
        $ids = if ($PSBoundParameters.ContainsKey('ProcessIds')) { @($ProcessIds) } else { @(& $adapter.ListProcessIds) }
        $rawSnapshots = [Collections.Generic.List[object]]::new()
        foreach ($rawProcessId in @($ids | Sort-Object -Unique)) {
            $convertedProcessId = ConvertTo-CcodProcessIdValue -Value $rawProcessId
            if (-not $convertedProcessId.Valid) { $rawIncomplete = $true; continue }
            try {
                $snapshot = Get-CcodStalePackageProcessSnapshot -ProcessId $convertedProcessId.Value -Package $Package -Adapter $adapter
            } catch {
                $rawIncomplete = $true
                continue
            }
            if ($null -eq $snapshot) { $rawIncomplete = $true; continue }
            $rawSnapshots.Add($snapshot)
        }
        @($rawSnapshots.ToArray())
    } else { @($Snapshots) }
    if ($rawIncomplete) { return New-CcodStalePackageRootResult -Outcome Incomplete -Snapshot $null }
    $currentSessionId = & $adapter.GetCurrentSessionId
    $currentUserSid = & $adapter.GetCurrentUserSid
    $suspicious = [Collections.Generic.List[object]]::new()
    $candidates = [Collections.Generic.List[object]]::new()
    foreach ($snapshot in @($observed)) {
        if ($null -eq $snapshot -or $snapshot.SessionId -ne $currentSessionId -or $snapshot.UserSid -cne $currentUserSid -or
            $snapshot.PackageFamilyName -isnot [string] -or -not (Test-CcodOrdinalIgnoreCase $snapshot.PackageFamilyName $Package.FamilyName) -or
            $snapshot.Path -isnot [string] -or [IO.Path]::GetFileName($snapshot.Path) -ine 'ChatGPT.exe' -or
            $snapshot.CommandLine -isnot [string] -or $snapshot.IsTopLevel -isnot [bool] -or -not $snapshot.IsTopLevel) { continue }
        $launchArguments = Get-CcodParsedLaunchArguments -CommandLine $snapshot.CommandLine -ExecutablePath $snapshot.Path -Adapters $adapter
        if (-not $launchArguments.Valid -or -not $launchArguments.IsTopLevel -or -not $launchArguments.HasDebugSwitch) { continue }
        $suspicious.Add($snapshot)
        if (Test-CcodStalePackageRootSnapshot -Snapshot $snapshot -Package $Package -PackageParts $parts -Adapter $adapter) {
            $candidates.Add($snapshot)
        }
    }
    $orderedCandidates = @($candidates | Sort-Object CreationTimeUtc, Pid)
    if ($suspicious.Count -eq 0) { return New-CcodStalePackageRootResult -Outcome NoCandidate -Snapshot $null }
    if ($suspicious.Count -ne 1 -or $orderedCandidates.Count -ne 1) { return New-CcodStalePackageRootResult -Outcome Ambiguous -Snapshot $null }
    $candidate = $orderedCandidates[0]
    $first = if ($rawMode) { Get-CcodStalePackageProcessSnapshot -ProcessId ([int]$candidate.Pid) -Package $Package -Adapter $adapter } else { & $adapter.GetProcess ([int]$candidate.Pid) $null }
    $second = if ($rawMode) { Get-CcodStalePackageProcessSnapshot -ProcessId ([int]$candidate.Pid) -Package $Package -Adapter $adapter } else { & $adapter.GetProcess ([int]$candidate.Pid) $null }
    if ($null -eq $first -or $null -eq $second -or -not (Test-CcodProcessMatch -Expected $candidate -Actual $first) -or
        -not (Test-CcodProcessMatch -Expected $first -Actual $second) -or
        -not (Test-CcodStalePackageRootSnapshot -Snapshot $second -Package $Package -PackageParts $parts -Adapter $adapter)) {
        return New-CcodStalePackageRootResult -Outcome Incomplete -Snapshot $null
    }
    return New-CcodStalePackageRootResult -Outcome Confirmed -Snapshot $second
}

function New-CcodStopResult {
    param(
        [Parameter(Mandatory)][ValidateSet('Stopped', 'SourceExited', 'IdentityChanged', 'StopUnconfirmed')][string]$Outcome,
        $Snapshot
    )

    return [pscustomobject][ordered]@{
        Outcome = $Outcome
        StoppedByController = $Outcome -ceq 'Stopped'
        Snapshot = $Snapshot
    }
}

function Get-CcodStrictStopIdentityObservation {
    param(
        [Parameter(Mandatory)]$Expected,
        [Parameter(Mandatory)][hashtable]$Adapter
    )

    if ($null -eq $Expected -or $Expected.Pid -isnot [int] -or $Expected.Pid -lt 1 -or
        $Expected.CreationTimeUtc -isnot [string] -or -not (Test-CcodCanonicalUtcTimestamp -Value $Expected.CreationTimeUtc)) {
        return $null
    }
    try { $output = @(& $Adapter.ObserveProcessIdentity ([int]$Expected.Pid) ([string]$Expected.CreationTimeUtc) 2>&1) } catch { return $null }
    if ($output.Count -ne 1 -or $output[0] -is [Management.Automation.ErrorRecord]) { return $null }
    $observation = $output[0]
    if (-not (Test-CcodExactProperties -Value $observation -Names @('Outcome','Pid','CreationTimeUtc')) -or
        $observation.Outcome -isnot [string] -or @('Absent','SameIdentity','IdentityChanged') -cnotcontains $observation.Outcome -or
        $observation.Pid -isnot [int] -or $observation.Pid -ne $Expected.Pid) { return $null }
    switch -CaseSensitive ($observation.Outcome) {
        'Absent' { if ($null -ne $observation.CreationTimeUtc) { return $null } }
        'SameIdentity' { if ($observation.CreationTimeUtc -isnot [string] -or $observation.CreationTimeUtc -cne $Expected.CreationTimeUtc) { return $null } }
        'IdentityChanged' {
            if ($observation.CreationTimeUtc -isnot [string] -or -not (Test-CcodCanonicalUtcTimestamp -Value $observation.CreationTimeUtc) -or
                $observation.CreationTimeUtc -ceq $Expected.CreationTimeUtc) { return $null }
        }
    }
    return $observation
}

function Test-CcodStrictStopExitObservation {
    param($Observation)
    return $null -ne $Observation -and @('Absent','IdentityChanged') -ccontains $Observation.Outcome
}

function Stop-CcodProcessIfMatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Expected,
        $StatusEvidence,
        [ValidateRange(1, 60000)][int]$TimeoutMilliseconds = 5000,
        [hashtable]$Adapters
    )

    $adapter = Get-CcodProcessAdapters -Adapters $Adapters
    $actual = & $adapter.GetProcess ([int]$Expected.Pid) $StatusEvidence
    if ($null -eq $actual) {
        $observation = Get-CcodStrictStopIdentityObservation -Expected $Expected -Adapter $adapter
        if (Test-CcodStrictStopExitObservation -Observation $observation) { return New-CcodStopResult -Outcome 'SourceExited' -Snapshot $null }
        return New-CcodStopResult -Outcome 'StopUnconfirmed' -Snapshot $null
    }
    if (-not (Test-CcodProcessMatch -Expected $Expected -Actual $actual)) {
        return New-CcodStopResult -Outcome 'IdentityChanged' -Snapshot $actual
    }

    try {
        $receipt = & $adapter.StopProcess $actual $TimeoutMilliseconds
    } catch [UnauthorizedAccessException] {
        return New-CcodStopResult -Outcome 'StopUnconfirmed' -Snapshot $actual
    } catch [ComponentModel.Win32Exception] {
        return New-CcodStopResult -Outcome 'StopUnconfirmed' -Snapshot $actual
    }

    if ($null -eq $receipt -or $null -eq $receipt.PSObject.Properties['Outcome']) {
        return New-CcodStopResult -Outcome 'StopUnconfirmed' -Snapshot $actual
    }
    switch -CaseSensitive ([string]$receipt.Outcome) {
        'StoppedByController' {
            if ($null -ne $receipt.PSObject.Properties['StoppedByController'] -and [object]::Equals($receipt.StoppedByController, $true) -and
                $null -ne $receipt.PSObject.Properties['Pid'] -and [object]::Equals($receipt.Pid, $actual.Pid) -and
                $null -ne $receipt.PSObject.Properties['CreationTimeUtc'] -and [object]::Equals($receipt.CreationTimeUtc, $actual.CreationTimeUtc)) {
                return New-CcodStopResult -Outcome 'Stopped' -Snapshot $actual
            }
            return New-CcodStopResult -Outcome 'StopUnconfirmed' -Snapshot $actual
        }
        'ExitedBeforeStop' {
            $observation = Get-CcodStrictStopIdentityObservation -Expected $Expected -Adapter $adapter
            if (Test-CcodStrictStopExitObservation -Observation $observation) { return New-CcodStopResult -Outcome 'SourceExited' -Snapshot $null }
            return New-CcodStopResult -Outcome 'StopUnconfirmed' -Snapshot $actual
        }
        'IdentityChanged' { return New-CcodStopResult -Outcome 'IdentityChanged' -Snapshot $actual }
        'AccessDenied' { return New-CcodStopResult -Outcome 'StopUnconfirmed' -Snapshot $actual }
        'TimedOut' { return New-CcodStopResult -Outcome 'StopUnconfirmed' -Snapshot $actual }
        default { return New-CcodStopResult -Outcome 'StopUnconfirmed' -Snapshot $actual }
    }
}

function New-CcodGracefulCloseResult {
    param(
        [Parameter(Mandatory)][ValidateSet('Requested', 'NotRequested', 'SourceExited', 'IdentityChanged')][string]$Outcome,
        $Snapshot
    )
    return [pscustomobject][ordered]@{ Outcome=$Outcome; Snapshot=$Snapshot }
}

function Request-CcodProcessGracefulCloseIfMatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Expected,
        $StatusEvidence,
        [hashtable]$Adapters
    )

    $adapter = Get-CcodProcessAdapters -Adapters $Adapters
    $actual = & $adapter.GetProcess ([int]$Expected.Pid) $StatusEvidence
    if ($null -eq $actual) { return New-CcodGracefulCloseResult -Outcome SourceExited -Snapshot $null }
    if (-not (Test-CcodProcessMatch -Expected $Expected -Actual $actual)) { return New-CcodGracefulCloseResult -Outcome IdentityChanged -Snapshot $actual }
    try { $receipt = & $adapter.RequestGracefulClose $actual } catch { return New-CcodGracefulCloseResult -Outcome NotRequested -Snapshot $actual }
    if ($receipt -is [bool]) {
        return New-CcodGracefulCloseResult -Outcome $(if ($receipt) { 'Requested' } else { 'NotRequested' }) -Snapshot $actual
    }
    if ($null -eq $receipt -or $receipt.PSObject.Properties['IdentityMatched'] -eq $null -or $receipt.IdentityMatched -isnot [bool] -or
        $receipt.PSObject.Properties['Requested'] -eq $null -or $receipt.Requested -isnot [bool]) {
        return New-CcodGracefulCloseResult -Outcome NotRequested -Snapshot $actual
    }
    if (-not $receipt.IdentityMatched) { return New-CcodGracefulCloseResult -Outcome IdentityChanged -Snapshot $actual }
    return New-CcodGracefulCloseResult -Outcome $(if ($receipt.Requested) { 'Requested' } else { 'NotRequested' }) -Snapshot $actual
}

function New-CcodWaitExitResult {
    param(
        [Parameter(Mandatory)][ValidateSet('SourceExited', 'IdentityChanged', 'StillRunning')][string]$Outcome,
        $Snapshot
    )
    return [pscustomobject][ordered]@{ Outcome=$Outcome; Snapshot=$Snapshot }
}

function Wait-CcodProcessExitIfMatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Expected,
        $StatusEvidence,
        [ValidateRange(1, 60000)][int]$TimeoutMilliseconds = 5000,
        [ValidateRange(1, 1000)][int]$PollMilliseconds = 50,
        [hashtable]$Adapters
    )

    $adapter = Get-CcodProcessAdapters -Adapters $Adapters
    $deadline = (& $adapter.GetUtcNow).AddMilliseconds($TimeoutMilliseconds)
    while ($true) {
        $actual = & $adapter.GetProcess ([int]$Expected.Pid) $StatusEvidence
        if ($null -eq $actual) { return New-CcodWaitExitResult -Outcome SourceExited -Snapshot $null }
        if (-not (Test-CcodProcessMatch -Expected $Expected -Actual $actual)) { return New-CcodWaitExitResult -Outcome IdentityChanged -Snapshot $actual }
        if ((& $adapter.GetUtcNow) -ge $deadline) { return New-CcodWaitExitResult -Outcome StillRunning -Snapshot $actual }
        & $adapter.Delay $PollMilliseconds
    }
}

function Request-CcodStaleProcessGracefulCloseIfMatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Expected,
        [Parameter(Mandatory)]$Package,
        [hashtable]$Adapters
    )

    $adapter = Get-CcodProcessAdapters -Adapters $Adapters
    $actual = Get-CcodStalePackageProcessSnapshot -ProcessId ([int]$Expected.Pid) -Package $Package -Adapter $adapter
    if ($null -eq $actual) { return New-CcodGracefulCloseResult -Outcome SourceExited -Snapshot $null }
    if (-not (Test-CcodProcessMatch -Expected $Expected -Actual $actual)) { return New-CcodGracefulCloseResult -Outcome IdentityChanged -Snapshot $actual }
    try { $receipt = & $adapter.RequestGracefulClose $actual } catch { return New-CcodGracefulCloseResult -Outcome NotRequested -Snapshot $actual }
    if ($receipt -is [bool]) { return New-CcodGracefulCloseResult -Outcome $(if ($receipt) { 'Requested' } else { 'NotRequested' }) -Snapshot $actual }
    if ($null -eq $receipt -or $receipt.PSObject.Properties['IdentityMatched'] -eq $null -or $receipt.IdentityMatched -isnot [bool] -or
        $receipt.PSObject.Properties['Requested'] -eq $null -or $receipt.Requested -isnot [bool]) { return New-CcodGracefulCloseResult -Outcome NotRequested -Snapshot $actual }
    if (-not $receipt.IdentityMatched) { return New-CcodGracefulCloseResult -Outcome IdentityChanged -Snapshot $actual }
    return New-CcodGracefulCloseResult -Outcome $(if ($receipt.Requested) { 'Requested' } else { 'NotRequested' }) -Snapshot $actual
}

function Wait-CcodStaleProcessExitIfMatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Expected,
        [Parameter(Mandatory)]$Package,
        [ValidateRange(1, 60000)][int]$TimeoutMilliseconds = 5000,
        [ValidateRange(1, 1000)][int]$PollMilliseconds = 50,
        [hashtable]$Adapters
    )

    $adapter = Get-CcodProcessAdapters -Adapters $Adapters
    $deadline = (& $adapter.GetUtcNow).AddMilliseconds($TimeoutMilliseconds)
    while ($true) {
        $actual = Get-CcodStalePackageProcessSnapshot -ProcessId ([int]$Expected.Pid) -Package $Package -Adapter $adapter
        if ($null -eq $actual) { return New-CcodWaitExitResult -Outcome SourceExited -Snapshot $null }
        if (-not (Test-CcodProcessMatch -Expected $Expected -Actual $actual)) { return New-CcodWaitExitResult -Outcome IdentityChanged -Snapshot $actual }
        if ((& $adapter.GetUtcNow) -ge $deadline) { return New-CcodWaitExitResult -Outcome StillRunning -Snapshot $actual }
        & $adapter.Delay $PollMilliseconds
    }
}

function Stop-CcodStaleProcessIfMatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Expected,
        [Parameter(Mandatory)]$Package,
        [ValidateRange(1, 60000)][int]$TimeoutMilliseconds = 5000,
        [hashtable]$Adapters
    )

    $adapter = Get-CcodProcessAdapters -Adapters $Adapters
    $actual = Get-CcodStalePackageProcessSnapshot -ProcessId ([int]$Expected.Pid) -Package $Package -Adapter $adapter
    if ($null -eq $actual) { return New-CcodStopResult -Outcome SourceExited -Snapshot $null }
    if (-not (Test-CcodProcessMatch -Expected $Expected -Actual $actual)) { return New-CcodStopResult -Outcome IdentityChanged -Snapshot $actual }
    try { $receipt = & $adapter.StopProcess $actual $TimeoutMilliseconds } catch { return New-CcodStopResult -Outcome StopUnconfirmed -Snapshot $actual }
    if ($null -eq $receipt -or $null -eq $receipt.PSObject.Properties['Outcome']) { return New-CcodStopResult -Outcome StopUnconfirmed -Snapshot $actual }
    switch -CaseSensitive ([string]$receipt.Outcome) {
        'StoppedByController' {
            if ($receipt.PSObject.Properties['StoppedByController'] -ne $null -and [object]::Equals($receipt.StoppedByController, $true) -and
                $receipt.PSObject.Properties['Pid'] -ne $null -and [object]::Equals($receipt.Pid, $actual.Pid) -and
                $receipt.PSObject.Properties['CreationTimeUtc'] -ne $null -and [object]::Equals($receipt.CreationTimeUtc, $actual.CreationTimeUtc)) {
                return New-CcodStopResult -Outcome Stopped -Snapshot $actual
            }
            return New-CcodStopResult -Outcome StopUnconfirmed -Snapshot $actual
        }
        'ExitedBeforeStop' { return New-CcodStopResult -Outcome SourceExited -Snapshot $null }
        'IdentityChanged' { return New-CcodStopResult -Outcome IdentityChanged -Snapshot $actual }
        default { return New-CcodStopResult -Outcome StopUnconfirmed -Snapshot $actual }
    }
}

function ConvertTo-CcodDateTimeOffset {
    param([AllowNull()][string]$Value)

    $parsed = [DateTimeOffset]::MinValue
    if ([string]::IsNullOrWhiteSpace($Value) -or
        -not [DateTimeOffset]::TryParseExact($Value, 'o', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) {
        return $null
    }
    return $parsed.ToUniversalTime()
}

function Test-CcodSameProcessOwnerAndPackage {
    param($Root, $Candidate)

    return $Candidate.SessionId -eq $Root.SessionId -and
        $Candidate.UserSid -ceq $Root.UserSid -and
        (Test-CcodOrdinalIgnoreCase $Candidate.Path $Root.Path) -and
        $Candidate.PackageFamilyName -ceq $Root.PackageFamilyName
}

function Get-CcodReachableProcessIds {
    param(
        [Parameter(Mandatory)]$Root,
        [Parameter(Mandatory)][hashtable]$SnapshotsByPid
    )

    $included = @([int]$Root.Pid)
    $changed = $true
    while ($changed) {
        $changed = $false
        foreach ($entry in $SnapshotsByPid.GetEnumerator()) {
            $processId = [int]$entry.Key
            if ($included -contains $processId) { continue }
            $candidate = $entry.Value
            if ($null -eq $candidate.ParentPid -or $included -notcontains [int]$candidate.ParentPid) { continue }
            $parent = $SnapshotsByPid[[int]$candidate.ParentPid]
            if ($null -eq $parent) { continue }
            $childTime = ConvertTo-CcodDateTimeOffset -Value $candidate.CreationTimeUtc
            $parentTime = ConvertTo-CcodDateTimeOffset -Value $parent.CreationTimeUtc
            if ($null -eq $childTime -or $null -eq $parentTime -or $childTime -lt $parentTime) { continue }
            $included += $processId
            $changed = $true
        }
    }
    return @($included)
}

function Test-CcodIndeterminateProcessBlocksVerifiedTree {
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        [Parameter(Mandatory)]$Root,
        [Parameter(Mandatory)][hashtable]$Adapter
    )

    try{$minimalOutput=@(& $Adapter.GetMinimalNativeProcess $ProcessId 2>&1)}catch{return $true}
    if($minimalOutput.Count -ne 1 -or $minimalOutput[0] -is [Management.Automation.ErrorRecord]){return $true}
    $minimal=$minimalOutput[0]
    if(-not (Test-CcodExactProperties -Value $minimal -Names @('Outcome','Pid','CreationTimeUtc')) -or
       $minimal.Outcome -isnot [string] -or @('Absent','Found') -cnotcontains $minimal.Outcome -or
       $minimal.Pid -isnot [int] -or $minimal.Pid -ne $ProcessId){return $true}
    if($minimal.Outcome -ceq 'Absent'){return $null -ne $minimal.CreationTimeUtc}
    if(-not (Test-CcodCanonicalUtcTimestamp -Value $minimal.CreationTimeUtc)){return $true}
    try{$nativeOutput=@(& $Adapter.GetNativeProcess $ProcessId 2>&1)}catch{return $true}
    if($nativeOutput.Count -ne 1 -or $nativeOutput[0] -is [Management.Automation.ErrorRecord]){return $true}
    $native=$nativeOutput[0]
    if(-not (Test-CcodExactProperties -Value $native -Names @('Pid','CreationTimeUtc','SessionId','UserSid','Path','PackageFamilyName')) -or
       $native.Pid -isnot [int] -or $native.Pid -ne $ProcessId -or $native.CreationTimeUtc -isnot [string] -or
       $native.CreationTimeUtc -cne $minimal.CreationTimeUtc -or $native.SessionId -isnot [int] -or $native.SessionId -lt 0 -or
       $native.UserSid -isnot [string] -or [string]::IsNullOrWhiteSpace($native.UserSid) -or
       $native.Path -isnot [string] -or [string]::IsNullOrWhiteSpace($native.Path) -or
       ($null -ne $native.PackageFamilyName -and ($native.PackageFamilyName -isnot [string] -or [string]::IsNullOrWhiteSpace($native.PackageFamilyName)))){return $true}
    return $native.SessionId -eq $Root.SessionId -and $native.UserSid -ceq $Root.UserSid -and
        (Test-CcodOrdinalIgnoreCase $native.Path $Root.Path) -and $native.PackageFamilyName -ceq $Root.PackageFamilyName
}

function Get-CcodVerifiedProcessTree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Root,
        $StatusEvidence,
        [hashtable]$Adapters
    )

    $adapter = Get-CcodProcessAdapters -Adapters $Adapters
    $actualRoot = & $adapter.GetProcess ([int]$Root.Pid) $StatusEvidence
    if ($null -eq $actualRoot -or -not (Test-CcodProcessMatch -Expected $Root -Actual $actualRoot)) { return @() }
    $rootTime = ConvertTo-CcodDateTimeOffset -Value $actualRoot.CreationTimeUtc
    if ($null -eq $rootTime) { return @() }

    $verifiedByPid = @{}
    $verifiedByPid[[int]$actualRoot.Pid] = $actualRoot
    foreach ($processId in @(& $adapter.ListProcessIds | Select-Object -Unique)) {
        if ($null -eq $processId -or [int]$processId -eq [int]$actualRoot.Pid) { continue }
        $candidate = & $adapter.GetProcess ([int]$processId) $null
        if ($null -eq $candidate) {
            if(Test-CcodIndeterminateProcessBlocksVerifiedTree -ProcessId ([int]$processId) -Root $actualRoot -Adapter $adapter){return @()}
            continue
        }
        if (-not (Test-CcodSameProcessOwnerAndPackage -Root $actualRoot -Candidate $candidate)) { continue }
        $candidateTime = ConvertTo-CcodDateTimeOffset -Value $candidate.CreationTimeUtc
        if ($null -eq $candidateTime -or $candidateTime -lt $rootTime) { continue }
        $verifiedByPid[[int]$candidate.Pid] = $candidate
    }

    $preliminary = @(Get-CcodReachableProcessIds -Root $actualRoot -SnapshotsByPid $verifiedByPid)
    $rereadByPid = @{}
    foreach ($processId in $preliminary) {
        $evidence = if ([int]$processId -eq [int]$actualRoot.Pid) { $StatusEvidence } else { $null }
        $current = & $adapter.GetProcess ([int]$processId) $evidence
        $previous = $verifiedByPid[[int]$processId]
        if ($null -eq $current -or -not (Test-CcodProcessMatch -Expected $previous -Actual $current) -or
            -not (Test-CcodSameProcessOwnerAndPackage -Root $actualRoot -Candidate $current)) { return @() }
        $rereadByPid[[int]$processId] = $current
    }
    if (-not $rereadByPid.ContainsKey([int]$actualRoot.Pid)) { return @() }
    $finalRoot = $rereadByPid[[int]$actualRoot.Pid]
    $included = @(Get-CcodReachableProcessIds -Root $finalRoot -SnapshotsByPid $rereadByPid)
    return @($included | Sort-Object | ForEach-Object { $rereadByPid[[int]$_] })
}

function Get-CcodVerifiedStaleProcessTree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Root,
        [Parameter(Mandatory)]$Package,
        [hashtable]$Adapters
    )

    $adapter = Get-CcodProcessAdapters -Adapters $Adapters
    $actualRoot = Get-CcodStalePackageProcessSnapshot -ProcessId ([int]$Root.Pid) -Package $Package -Adapter $adapter
    if ($null -eq $actualRoot -or -not (Test-CcodProcessMatch -Expected $Root -Actual $actualRoot)) { return @() }
    $rootTime = ConvertTo-CcodDateTimeOffset -Value $actualRoot.CreationTimeUtc
    if ($null -eq $rootTime) { return @() }
    $verifiedByPid = @{ ([int]$actualRoot.Pid) = $actualRoot }
    foreach ($processId in @(& $adapter.ListProcessIds | Select-Object -Unique)) {
        if ($processId -isnot [int] -or $processId -eq [int]$actualRoot.Pid) { continue }
        $candidate = Get-CcodStalePackageProcessSnapshot -ProcessId $processId -Package $Package -Adapter $adapter
        if ($null -eq $candidate) {
            if(Test-CcodIndeterminateProcessBlocksVerifiedTree -ProcessId $processId -Root $actualRoot -Adapter $adapter){return @()}
            continue
        }
        if (-not (Test-CcodSameProcessOwnerAndPackage -Root $actualRoot -Candidate $candidate)) { continue }
        $candidateTime = ConvertTo-CcodDateTimeOffset -Value $candidate.CreationTimeUtc
        if ($null -eq $candidateTime -or $candidateTime -lt $rootTime) { continue }
        $verifiedByPid[[int]$candidate.Pid] = $candidate
    }
    $preliminary = @(Get-CcodReachableProcessIds -Root $actualRoot -SnapshotsByPid $verifiedByPid)
    $rereadByPid = @{}
    foreach ($processId in $preliminary) {
        $current = Get-CcodStalePackageProcessSnapshot -ProcessId ([int]$processId) -Package $Package -Adapter $adapter
        $previous = $verifiedByPid[[int]$processId]
        if ($null -eq $current -or -not (Test-CcodProcessMatch -Expected $previous -Actual $current) -or
            -not (Test-CcodSameProcessOwnerAndPackage -Root $actualRoot -Candidate $current)) { return @() }
        $rereadByPid[[int]$processId] = $current
    }
    if (-not $rereadByPid.ContainsKey([int]$actualRoot.Pid)) { return @() }
    $finalRoot = $rereadByPid[[int]$actualRoot.Pid]
    $included = @(Get-CcodReachableProcessIds -Root $finalRoot -SnapshotsByPid $rereadByPid)
    return @($included | Sort-Object | ForEach-Object { $rereadByPid[[int]$_] })
}

function Get-CcodListenerOwnerMapping {
    param(
        [Parameter(Mandatory)][int]$RendererPort,
        [Parameter(Mandatory)][int]$MainPort,
        [Parameter(Mandatory)][hashtable]$Adapters
    )

    try {
        $rendererOwners = @(& $Adapters.GetListeningPortOwnerPids $RendererPort '127.0.0.1' | Sort-Object -Unique)
        $mainOwners = @(& $Adapters.GetListeningPortOwnerPids $MainPort '127.0.0.1' | Sort-Object -Unique)
    } catch {
        return [pscustomobject]@{ Outcome='Incomplete'; RendererOwners=@(); MainOwners=@() }
    }
    foreach ($owner in @($rendererOwners + $mainOwners)) {
        if ($owner -isnot [int] -or $owner -lt 1) {
            return [pscustomobject]@{ Outcome='Incomplete'; RendererOwners=@(); MainOwners=@() }
        }
    }
    if ($rendererOwners.Count -lt 1 -or $mainOwners.Count -lt 1) {
        return [pscustomobject]@{ Outcome='Incomplete'; RendererOwners=$rendererOwners; MainOwners=$mainOwners }
    }
    return [pscustomobject]@{ Outcome='Complete'; RendererOwners=$rendererOwners; MainOwners=$mainOwners }
}

function Test-CcodOwnerMappingMatch {
    param($Expected, $Actual)

    return $Expected.Outcome -ceq 'Complete' -and $Actual.Outcome -ceq 'Complete' -and
        (($Expected.RendererOwners -join ',') -ceq ($Actual.RendererOwners -join ',')) -and
        (($Expected.MainOwners -join ',') -ceq ($Actual.MainOwners -join ','))
}

function Copy-CcodProcessSnapshot {
    param($Snapshot)

    if ($null -eq $Snapshot) { return $null }
    $copy = [ordered]@{}
    foreach ($field in $script:CcodProcessSnapshotFields) {
        $property = $Snapshot.PSObject.Properties[$field]
        if ($null -eq $property) { throw "Process snapshot is missing required field '$field'." }
        $copy[$field] = $property.Value
    }
    return [pscustomobject]$copy
}

function New-CcodTransactionProcessResult {
    param(
        [Parameter(Mandatory)][ValidateSet('Confirmed', 'NoCandidate', 'Incomplete', 'Ambiguous', 'PortConflict')][string]$Outcome,
        $Snapshot,
        [AllowEmptyCollection()][object[]]$Candidates = @(),
        [AllowEmptyCollection()][object[]]$ConflictOwners = @()
    )

    $publicSnapshot = Copy-CcodProcessSnapshot -Snapshot $Snapshot
    $publicCandidates = @($Candidates | Sort-Object Pid | ForEach-Object { Copy-CcodProcessSnapshot -Snapshot $_ })
    $publicConflictOwners = @($ConflictOwners | Sort-Object Pid | ForEach-Object { Copy-CcodProcessSnapshot -Snapshot $_ })
    return [pscustomobject][ordered]@{
        Outcome = $Outcome
        Snapshot = $publicSnapshot
        Candidates = $publicCandidates
        ConflictOwners = $publicConflictOwners
    }
}

function Get-CcodExactOwnerSnapshots {
    param(
        [Parameter(Mandatory)][int[]]$OwnerPids,
        [Parameter(Mandatory)][hashtable]$Adapters
    )

    $snapshots = @()
    foreach ($ownerPid in @($OwnerPids | Sort-Object -Unique)) {
        $first = & $Adapters.GetProcess $ownerPid $null
        $second = & $Adapters.GetProcess $ownerPid $null
        if ($null -eq $first -or $null -eq $second -or
            $first.Pid -isnot [int] -or -not [object]::Equals($first.Pid, $ownerPid) -or
            -not (Test-CcodProcessMatch -Expected $first -Actual $second)) {
            return [pscustomobject]@{ Complete=$false; Snapshots=@() }
        }
        $snapshots += $second
    }
    return [pscustomobject]@{ Complete=$true; Snapshots=@($snapshots) }
}

function Test-CcodTransactionOwnerSnapshot {
    param($Snapshot)

    if ($null -eq $Snapshot -or $Snapshot.Pid -isnot [int] -or $Snapshot.Pid -lt 1 -or
        $Snapshot.SessionId -isnot [int] -or $Snapshot.UserSid -isnot [string] -or
        $Snapshot.Path -isnot [string] -or $Snapshot.PackageFamilyName -isnot [string]) {
        return $false
    }
    return $null -ne (ConvertTo-CcodDateTimeOffset -Value $Snapshot.CreationTimeUtc)
}

function Get-CcodStartupOwnershipReceipt {
    param(
        [Parameter(Mandatory)]$Snapshot,
        [Parameter(Mandatory)][int]$RendererPort,
        [Parameter(Mandatory)][int]$MainPort,
        [Parameter(Mandatory)][hashtable]$Adapters
    )

    $candidateList = @($Snapshot)
    $firstMapping = Get-CcodListenerOwnerMapping -RendererPort $RendererPort -MainPort $MainPort -Adapters $Adapters
    if ($firstMapping.Outcome -cne 'Complete') {
        return New-CcodTransactionProcessResult -Outcome Incomplete -Snapshot $null -Candidates $candidateList
    }
    $tree = @(Get-CcodVerifiedProcessTree -Root $Snapshot -Adapters $Adapters)
    if ($tree.Count -lt 1) { return New-CcodTransactionProcessResult -Outcome Incomplete -Snapshot $null -Candidates $candidateList }
    $treeByPid = @{}
    foreach ($node in $tree) { $treeByPid[[int]$node.Pid] = $node }
    if (-not $treeByPid.ContainsKey([int]$Snapshot.Pid)) {
        return New-CcodTransactionProcessResult -Outcome Incomplete -Snapshot $null -Candidates $candidateList
    }

    $secondMapping = Get-CcodListenerOwnerMapping -RendererPort $RendererPort -MainPort $MainPort -Adapters $Adapters
    if ($secondMapping.Outcome -cne 'Complete') {
        return New-CcodTransactionProcessResult -Outcome Incomplete -Snapshot $null -Candidates $candidateList
    }
    if (-not (Test-CcodOwnerMappingMatch -Expected $firstMapping -Actual $secondMapping)) {
        return New-CcodTransactionProcessResult -Outcome Incomplete -Snapshot $null -Candidates $candidateList
    }
    $ownerPids = @($secondMapping.RendererOwners + $secondMapping.MainOwners | Sort-Object -Unique)
    $externalOwnerPids = @($ownerPids | Where-Object { -not $treeByPid.ContainsKey([int]$_) })
    if ($externalOwnerPids.Count -gt 0) {
        $externalOwners = Get-CcodExactOwnerSnapshots -OwnerPids $externalOwnerPids -Adapters $Adapters
        if (-not $externalOwners.Complete -or @($externalOwners.Snapshots | Where-Object { -not (Test-CcodTransactionOwnerSnapshot $_) }).Count -gt 0) {
            return New-CcodTransactionProcessResult -Outcome Incomplete -Snapshot $null -Candidates $candidateList
        }
        return New-CcodTransactionProcessResult -Outcome PortConflict -Snapshot $null -Candidates $candidateList -ConflictOwners $externalOwners.Snapshots
    }
    foreach ($owner in $ownerPids) {
        $currentOwner = & $Adapters.GetProcess ([int]$owner) $null
        if ($null -eq $currentOwner -or -not (Test-CcodProcessMatch -Expected $treeByPid[[int]$owner] -Actual $currentOwner)) {
            return New-CcodTransactionProcessResult -Outcome Incomplete -Snapshot $null -Candidates $candidateList
        }
    }
    return New-CcodTransactionProcessResult -Outcome Confirmed -Snapshot $Snapshot -Candidates $candidateList
}

function Get-CcodTransactionCandidateResult {
    param(
        [Parameter(Mandatory)][int]$RendererPort,
        [Parameter(Mandatory)][int]$MainPort,
        [Parameter(Mandatory)][string]$TransactionTimeUtc,
        [Parameter(Mandatory)][hashtable]$Adapters
    )

    if ($RendererPort -eq $MainPort) { return New-CcodTransactionProcessResult -Outcome Incomplete -Snapshot $null }
    $transactionTime = ConvertTo-CcodDateTimeOffset -Value $TransactionTimeUtc
    if ($null -eq $transactionTime) { return New-CcodTransactionProcessResult -Outcome Incomplete -Snapshot $null }
    $package = & $Adapters.GetPackageIdentity
    if ($null -eq $package -or $null -eq $package.PSObject.Properties['Found'] -or -not $package.Found) {
        return New-CcodTransactionProcessResult -Outcome Incomplete -Snapshot $null
    }
    foreach ($name in @('FamilyName', 'ExecutablePath')) {
        if ($null -eq $package.PSObject.Properties[$name] -or [string]::IsNullOrWhiteSpace([string]$package.$name)) {
            return New-CcodTransactionProcessResult -Outcome Incomplete -Snapshot $null
        }
    }
    $currentSessionId = & $Adapters.GetCurrentSessionId
    $currentUserSid = & $Adapters.GetCurrentUserSid
    $candidates = @()
    foreach ($processId in @(& $Adapters.ListProcessIds | Select-Object -Unique)) {
        if ($processId -isnot [int] -or $processId -lt 1) { continue }
        $snapshot = & $Adapters.GetProcess ([int]$processId) $null
        if ($null -eq $snapshot -or -not $snapshot.IsTopLevel) { continue }
        if (-not [object]::Equals($snapshot.SessionId, $currentSessionId) -or $snapshot.UserSid -cne $currentUserSid) { continue }
        if (-not (Test-CcodOrdinalIgnoreCase $snapshot.Path $package.ExecutablePath) -or $snapshot.PackageFamilyName -cne $package.FamilyName) { continue }
        $parsed = Get-CcodParsedLaunchArguments -CommandLine $snapshot.CommandLine -ExecutablePath $package.ExecutablePath -Adapters $Adapters
        if (-not $parsed.Valid -or -not $parsed.IsTopLevel -or -not $parsed.SpecialArgumentsValid) { continue }
        if ($snapshot.RendererPort -isnot [int] -or $snapshot.MainPort -isnot [int] -or
            -not [object]::Equals($snapshot.RendererPort, $RendererPort) -or
            -not [object]::Equals($snapshot.MainPort, $MainPort) -or
            -not [object]::Equals($parsed.RendererPort, $RendererPort) -or
            -not [object]::Equals($parsed.MainPort, $MainPort)) { continue }
        $creation = ConvertTo-CcodDateTimeOffset -Value $snapshot.CreationTimeUtc
        if ($null -eq $creation -or $creation -lt $transactionTime) { continue }
        $candidates += $snapshot
    }
    if ($candidates.Count -gt 1) {
        $exactCandidates = @()
        foreach ($candidate in @($candidates | Sort-Object Pid)) {
            $current = & $Adapters.GetProcess ([int]$candidate.Pid) $null
            if ($null -eq $current -or -not (Test-CcodProcessMatch -Expected $candidate -Actual $current)) {
                return New-CcodTransactionProcessResult -Outcome Incomplete -Snapshot $null
            }
            $exactCandidates += $current
        }
        return New-CcodTransactionProcessResult -Outcome Ambiguous -Snapshot $null -Candidates $exactCandidates
    }
    if ($candidates.Count -ne 1) {
        try {
            $rendererOwners = @(& $Adapters.GetListeningPortOwnerPids $RendererPort '127.0.0.1')
            $mainOwners = @(& $Adapters.GetListeningPortOwnerPids $MainPort '127.0.0.1')
        } catch {
            return New-CcodTransactionProcessResult -Outcome Incomplete -Snapshot $null
        }
        $owners = @($rendererOwners + $mainOwners | Sort-Object -Unique)
        if ($owners.Count -eq 0) { return New-CcodTransactionProcessResult -Outcome NoCandidate -Snapshot $null }
        foreach ($owner in $owners) {
            if ($owner -isnot [int] -or $owner -lt 1) { return New-CcodTransactionProcessResult -Outcome Incomplete -Snapshot $null }
        }
        $ownerReceipt = Get-CcodExactOwnerSnapshots -OwnerPids $owners -Adapters $Adapters
        if (-not $ownerReceipt.Complete) { return New-CcodTransactionProcessResult -Outcome Incomplete -Snapshot $null }
        $foreignOwners = @()
        foreach ($ownerSnapshot in $ownerReceipt.Snapshots) {
            if (-not (Test-CcodTransactionOwnerSnapshot -Snapshot $ownerSnapshot)) {
                return New-CcodTransactionProcessResult -Outcome Incomplete -Snapshot $null
            }
            $ownerCreation = ConvertTo-CcodDateTimeOffset -Value $ownerSnapshot.CreationTimeUtc
            $provenForeign = -not [object]::Equals($ownerSnapshot.SessionId, $currentSessionId) -or
                $ownerSnapshot.UserSid -cne $currentUserSid -or
                -not (Test-CcodOrdinalIgnoreCase $ownerSnapshot.Path $package.ExecutablePath) -or
                $ownerSnapshot.PackageFamilyName -cne $package.FamilyName -or
                $ownerCreation -lt $transactionTime
            if ($provenForeign) { $foreignOwners += $ownerSnapshot }
        }
        if ($foreignOwners.Count -gt 0) {
            return New-CcodTransactionProcessResult -Outcome PortConflict -Snapshot $null -ConflictOwners $foreignOwners
        }
        return New-CcodTransactionProcessResult -Outcome Incomplete -Snapshot $null
    }
    return Get-CcodStartupOwnershipReceipt -Snapshot $candidates[0] -RendererPort $RendererPort -MainPort $MainPort -Adapters $Adapters
}

function Get-CcodTransactionProcessResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateRange(1, 65535)][int]$RendererPort,
        [Parameter(Mandatory)][ValidateRange(1, 65535)][int]$MainPort,
        [Parameter(Mandatory)][string]$TransactionTimeUtc,
        [hashtable]$Adapters
    )

    try {
        $adapter = Get-CcodProcessAdapters -Adapters $Adapters
        return Get-CcodTransactionCandidateResult -RendererPort $RendererPort -MainPort $MainPort -TransactionTimeUtc $TransactionTimeUtc -Adapters $adapter
    } catch {
        return New-CcodTransactionProcessResult -Outcome Incomplete -Snapshot $null
    }
}

function Find-CcodTransactionProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateRange(1, 65535)][int]$RendererPort,
        [Parameter(Mandatory)][ValidateRange(1, 65535)][int]$MainPort,
        [Parameter(Mandatory)][string]$TransactionTimeUtc,
        [hashtable]$Adapters
    )

    $result = Get-CcodTransactionProcessResult -RendererPort $RendererPort -MainPort $MainPort -TransactionTimeUtc $TransactionTimeUtc -Adapters $Adapters
    if ($result.Outcome -cne 'Confirmed') { return $null }
    return $result.Snapshot
}

function Get-CcodAvailableLoopbackPort {
    [CmdletBinding()]
    param(
        [AllowNull()][int[]]$ExcludedPorts = @(),
        [ValidateRange(1, 128)][int]$MaximumAttempts = 32,
        [hashtable]$Adapters
    )

    $adapter = Get-CcodProcessAdapters -Adapters $Adapters
    for ($attempt = 0; $attempt -lt $MaximumAttempts; $attempt++) {
        $port = & $adapter.ReserveLoopbackPort '127.0.0.1'
        if ($port -isnot [int] -or $port -lt 1 -or $port -gt 65535) { continue }
        if (@($ExcludedPorts) -contains [int]$port) { continue }
        return [int]$port
    }
    throw 'Could not reserve a distinct IPv4 loopback port.'
}

function Wait-CcodPortClosed {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateRange(1, 65535)][int]$Port,
        [ValidateRange(1, 60000)][int]$TimeoutMilliseconds = 5000,
        [ValidateRange(1, 1000)][int]$PollMilliseconds = 50,
        [hashtable]$Adapters
    )

    $adapter = Get-CcodProcessAdapters -Adapters $Adapters
    $deadline = (& $adapter.GetUtcNow).AddMilliseconds($TimeoutMilliseconds)
    while ($true) {
        $probe = [string](& $adapter.ProbeLoopbackPort $Port)
        if ($probe -ceq 'Refused') { return $true }
        if ($probe -cne 'Open') { return $false }
        if ((& $adapter.GetUtcNow) -ge $deadline) { return $false }
        & $adapter.Delay $PollMilliseconds
    }
}

function New-CcodStartResult {
    param(
        [Parameter(Mandatory)][ValidateSet('Started', 'Adopted', 'PortUnavailable', 'StartUnconfirmed', 'Failed')][string]$Outcome,
        $Snapshot,
        $Process
    )

    [pscustomobject][ordered]@{
        Outcome = $Outcome
        Snapshot = $Snapshot
        Process = $Process
    }
}

function Test-CcodCanonicalUtcTimestamp {
    param([AllowNull()][object]$Value)
    if($Value -isnot [string]){return $false}
    $parsed=[DateTime]::MinValue
    return [DateTime]::TryParseExact($Value,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$parsed) -and
        $parsed.Kind -eq [DateTimeKind]::Utc -and $parsed.ToString('o',[Globalization.CultureInfo]::InvariantCulture) -ceq $Value
}

function Request-CcodOrdinaryPackagedLaunch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RequestedAtUtc,
        [Parameter(Mandatory)]$Ownership,
        [Parameter(Mandatory)][scriptblock]$AssertLifecycleFence,
        [hashtable]$Adapters
    )

    if (-not (Test-CcodCanonicalUtcTimestamp -Value $RequestedAtUtc)) {
        throw 'RequestedAtUtc must be an ISO-8601 round-trip timestamp.'
    }
    if($null -eq $Ownership -or ($Ownership -isnot [pscustomobject] -and $Ownership -isnot [Collections.IDictionary]) -or
        -not (Test-CcodExactProperties -Value $Ownership -Names @('runtimeGeneration','leaseEpoch','ownerIdentity')) -or
        $Ownership.runtimeGeneration -isnot [UInt64] -or $Ownership.runtimeGeneration -eq 0 -or
        $Ownership.leaseEpoch -isnot [UInt64] -or $Ownership.leaseEpoch -eq 0 -or
        $null -eq $Ownership.ownerIdentity -or -not (Test-CcodExactProperties -Value $Ownership.ownerIdentity -Names @('pid','creationTimeUtc')) -or
        $Ownership.ownerIdentity.pid -isnot [int] -or $Ownership.ownerIdentity.pid -lt 1 -or
        -not (Test-CcodCanonicalUtcTimestamp -Value $Ownership.ownerIdentity.creationTimeUtc)){
        $exception=[InvalidOperationException]::new('Lifecycle launch ownership is invalid.')
        throw [Management.Automation.ErrorRecord]::new($exception,'CCOD_LIFECYCLE_FENCE_STALE',[Management.Automation.ErrorCategory]::SecurityError,$Ownership)
    }
    $adapter = Get-CcodProcessAdapters -Adapters $Adapters
    $explorerPath = [IO.Path]::GetFullPath((Join-Path $env:WINDIR 'explorer.exe'))
    try{[void](& $AssertLifecycleFence $Ownership.runtimeGeneration $Ownership.leaseEpoch $Ownership.ownerIdentity)}catch{
        $errorId=[string]$_.FullyQualifiedErrorId;if($errorId.Contains(',')){$errorId=$errorId.Split(',')[0]}
        if($errorId -ceq 'CCOD_LIFECYCLE_FENCE_STALE'){throw}
        $exception=[InvalidOperationException]::new('Lifecycle launch ownership is stale.')
        throw [Management.Automation.ErrorRecord]::new($exception,'CCOD_LIFECYCLE_FENCE_STALE',[Management.Automation.ErrorCategory]::SecurityError,$Ownership.ownerIdentity)
    }
    $process = & $adapter.StartProcess $explorerPath @('shell:AppsFolder\OpenAI.Codex_2p2nqsd0c76g0!App') $null
    $launcherPid = $null
    if ($null -ne $process -and $null -ne $process.PSObject.Properties['Id'] -and $process.Id -is [ValueType]) {
        try {
            $candidatePid = [int]$process.Id
            if ($candidatePid -gt 0) { $launcherPid = $candidatePid }
        } catch { $launcherPid = $null }
    }
    return [pscustomobject][ordered]@{
        outcome = 'LaunchRequested'
        requestedAtUtc = $RequestedAtUtc
        launcherPid = $launcherPid
    }
}

function Test-CcodVerifiedOrdinaryObservation {
    param(
        $Snapshot,
        [Parameter(Mandatory)]$Package,
        [Parameter(Mandatory)][DateTimeOffset]$NotBefore,
        [Parameter(Mandatory)][string]$ExpectedUserSid,
        [Parameter(Mandatory)][int]$ExpectedSessionId,
        [Parameter(Mandatory)][hashtable]$Adapters
    )

    if ($null -eq $Snapshot -or -not (Test-CcodExactProperties -Value $Snapshot -Names $script:CcodProcessSnapshotFields) -or
        $Snapshot.Pid -isnot [int] -or $Snapshot.Pid -lt 1 -or $Snapshot.SessionId -isnot [int] -or
        $Snapshot.SessionId -ne $ExpectedSessionId -or $Snapshot.UserSid -isnot [string] -or $Snapshot.UserSid -cne $ExpectedUserSid -or
        $Snapshot.Path -isnot [string] -or -not (Test-CcodOrdinalIgnoreCase $Snapshot.Path $Package.ExecutablePath) -or
        $Snapshot.PackageFamilyName -isnot [string] -or $Snapshot.PackageFamilyName -cne $Package.FamilyName -or
        $Snapshot.CommandLine -isnot [string] -or $Snapshot.IsTopLevel -isnot [bool] -or -not $Snapshot.IsTopLevel -or
        $Snapshot.Mode -isnot [string] -or $Snapshot.Mode -cne 'Ordinary' -or
        $null -ne $Snapshot.RendererPort -or $null -ne $Snapshot.MainPort) {
        return $false
    }
    $created = ConvertTo-CcodDateTimeOffset -Value $Snapshot.CreationTimeUtc
    if ($null -eq $created -or $created -lt $NotBefore) { return $false }
    $arguments = Get-CcodParsedLaunchArguments -CommandLine $Snapshot.CommandLine -ExecutablePath $Package.ExecutablePath -Adapters $Adapters
    return $arguments.Valid -and $arguments.IsTopLevel -and -not $arguments.HasDebugSwitch
}

function Get-CcodVerifiedOrdinaryObservation {
    param(
        [Parameter(Mandatory)][DateTimeOffset]$NotBefore,
        [Parameter(Mandatory)][string]$ExpectedUserSid,
        [Parameter(Mandatory)][int]$ExpectedSessionId,
        $StatusEvidence,
        [Parameter(Mandatory)][hashtable]$Adapters
    )

    $package = & $Adapters.GetPackageIdentity
    if ($null -eq $package -or $null -eq $package.PSObject.Properties['Found'] -or $package.Found -isnot [bool] -or -not $package.Found) { return $null }
    foreach ($name in @('FamilyName', 'ExecutablePath')) {
        if ($null -eq $package.PSObject.Properties[$name] -or $package.$name -isnot [string] -or [string]::IsNullOrWhiteSpace($package.$name)) { return $null }
    }
    $candidates = @()
    foreach ($processId in @(& $Adapters.ListProcessIds | Select-Object -Unique)) {
        if ($processId -isnot [int] -or $processId -lt 1) { continue }
        $first = & $Adapters.GetProcess $processId $StatusEvidence
        if (-not (Test-CcodVerifiedOrdinaryObservation -Snapshot $first -Package $package -NotBefore $NotBefore -ExpectedUserSid $ExpectedUserSid -ExpectedSessionId $ExpectedSessionId -Adapters $Adapters)) { continue }
        $second = & $Adapters.GetProcess $processId $StatusEvidence
        if ($null -eq $second -or -not (Test-CcodProcessMatch -Expected $first -Actual $second) -or
            -not (Test-CcodVerifiedOrdinaryObservation -Snapshot $second -Package $package -NotBefore $NotBefore -ExpectedUserSid $ExpectedUserSid -ExpectedSessionId $ExpectedSessionId -Adapters $Adapters)) { continue }
        $candidates += $second
    }
    if ($candidates.Count -ne 1) { return $null }
    return Copy-CcodProcessSnapshot -Snapshot $candidates[0]
}

function Wait-CcodVerifiedOrdinaryRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$NotBeforeUtc,
        [Parameter(Mandatory)][string]$ExpectedUserSid,
        [Parameter(Mandatory)][ValidateRange(0, 2147483647)][int]$ExpectedSessionId,
        [Parameter(Mandatory)]$StatusEvidence,
        [ValidateRange(1, 45000)][int]$TimeoutMilliseconds = 45000,
        [hashtable]$Adapters
    )

    $notBefore = ConvertTo-CcodDateTimeOffset -Value $NotBeforeUtc
    if (-not (Test-CcodCanonicalUtcTimestamp -Value $NotBeforeUtc) -or $null -eq $notBefore -or [string]::IsNullOrWhiteSpace($ExpectedUserSid)) { return $null }
    $adapter = Get-CcodProcessAdapters -Adapters $Adapters
    $clock = & $adapter.StartStopwatch
    if ($null -eq $clock) { return $null }
    $backoffIndex = 0
    while ($true) {
        $candidate = Get-CcodVerifiedOrdinaryObservation -NotBefore $notBefore -ExpectedUserSid $ExpectedUserSid -ExpectedSessionId $ExpectedSessionId -StatusEvidence $StatusEvidence -Adapters $adapter
        if ($null -ne $candidate) { return $candidate }
        $elapsed = & $adapter.GetElapsedMilliseconds $clock
        if (($elapsed -isnot [int] -and $elapsed -isnot [long]) -or $elapsed -lt 0 -or $elapsed -ge $TimeoutMilliseconds) { return $null }
        $delayIndex = [Math]::Min($backoffIndex, $script:CcodOrdinaryObservationBackoffMilliseconds.Count - 1)
        $delay = [int]$script:CcodOrdinaryObservationBackoffMilliseconds[$delayIndex]
        $remaining = [int]([long]$TimeoutMilliseconds - [long]$elapsed)
        if ($delay -gt $remaining) { $delay = $remaining }
        & $adapter.Delay $delay
        $backoffIndex++
    }
}

function Start-CcodProcess {
    [CmdletBinding(DefaultParameterSetName = 'Codex')]
    param(
        [Parameter(ParameterSetName = 'Codex')][ValidateSet('Ordinary', 'Special')][string]$Mode = 'Ordinary',
        [Parameter(ParameterSetName = 'Codex')][ValidateRange(1, 65535)][Nullable[int]]$RendererPort,
        [Parameter(ParameterSetName = 'Codex')][ValidateRange(1, 65535)][Nullable[int]]$MainPort,
        [Parameter(ParameterSetName = 'Codex')][ValidateRange(1, 60000)][int]$StartupTimeoutMilliseconds = 5000,
        [Parameter(ParameterSetName = 'Codex')][ValidateRange(1, 1000)][int]$StartupPollMilliseconds = 50,
        [Parameter(Mandatory, ParameterSetName = 'Helper')][switch]$BackgroundHelper,
        [Parameter(Mandatory, ParameterSetName = 'Helper')][string]$HelperPath,
        [Parameter(ParameterSetName = 'Helper')][AllowEmptyCollection()][string[]]$HelperArguments = @(),
        [hashtable]$Adapters
    )

    $adapter = Get-CcodProcessAdapters -Adapters $Adapters
    if ($PSCmdlet.ParameterSetName -ceq 'Helper') {
        if (-not [IO.Path]::IsPathRooted($HelperPath)) { return New-CcodStartResult -Outcome 'Failed' -Snapshot $null -Process $null }
        $process = & $adapter.StartProcess $HelperPath @($HelperArguments) 'Hidden'
        if ($null -eq $process) { return New-CcodStartResult -Outcome 'Failed' -Snapshot $null -Process $null }
        return New-CcodStartResult -Outcome 'Started' -Snapshot $null -Process $process
    }

    $package = & $adapter.GetPackageIdentity
    if ($null -eq $package -or $null -eq $package.PSObject.Properties['Found'] -or -not $package.Found -or
        $null -eq $package.PSObject.Properties['FamilyName'] -or $null -eq $package.PSObject.Properties['ExecutablePath'] -or
        [string]::IsNullOrWhiteSpace([string]$package.FamilyName) -or [string]::IsNullOrWhiteSpace([string]$package.ExecutablePath)) {
        return New-CcodStartResult -Outcome 'Failed' -Snapshot $null -Process $null
    }

    if ($Mode -ceq 'Ordinary') {
        $currentSessionId = & $adapter.GetCurrentSessionId
        $currentUserSid = & $adapter.GetCurrentUserSid
        $ordinaryRoots = @()
        foreach ($processId in @(& $adapter.ListProcessIds | Select-Object -Unique)) {
            if ($null -eq $processId) { continue }
            $snapshot = & $adapter.GetProcess ([int]$processId) $null
            if ($null -eq $snapshot -or $snapshot.Mode -cne 'Ordinary' -or -not $snapshot.IsTopLevel) { continue }
            if ($snapshot.SessionId -ne $currentSessionId -or $snapshot.UserSid -cne $currentUserSid) { continue }
            if (-not (Test-CcodOrdinalIgnoreCase $snapshot.Path $package.ExecutablePath) -or $snapshot.PackageFamilyName -cne $package.FamilyName) { continue }
            $ordinaryRoots += $snapshot
        }
        if ($ordinaryRoots.Count -gt 0) {
            $adopted = @($ordinaryRoots | Sort-Object CreationTimeUtc, Pid)[0]
            return New-CcodStartResult -Outcome 'Adopted' -Snapshot $adopted -Process $null
        }
        $arguments = @()
        $transactionTimeUtc = $null
        $deadline = $null
    } else {
        if (-not $PSBoundParameters.ContainsKey('RendererPort') -or -not $PSBoundParameters.ContainsKey('MainPort') -or
            [int]$RendererPort -eq [int]$MainPort) {
            return New-CcodStartResult -Outcome 'PortUnavailable' -Snapshot $null -Process $null
        }
        foreach ($port in @([int]$RendererPort, [int]$MainPort)) {
            if (-not (& $adapter.TestLoopbackPortAvailable $port '127.0.0.1')) {
                return New-CcodStartResult -Outcome 'PortUnavailable' -Snapshot $null -Process $null
            }
        }
        $arguments = @(
            '--remote-debugging-address=127.0.0.1',
            "--remote-debugging-port=$([int]$RendererPort)",
            "--inspect=127.0.0.1:$([int]$MainPort)"
        )
        $transactionTime = & $adapter.GetUtcNow
        if ($transactionTime -isnot [DateTimeOffset]) {
            return New-CcodStartResult -Outcome 'Failed' -Snapshot $null -Process $null
        }
        $transactionTime = $transactionTime.ToUniversalTime()
        $transactionTimeUtc = $transactionTime.ToString('o')
        $deadline = $transactionTime.AddMilliseconds($StartupTimeoutMilliseconds)
    }

    if ($Mode -ceq 'Ordinary') {
        $appUserModelId = '{0}!App' -f [string]$package.FamilyName
        $process = & $adapter.ActivatePackagedApplication $appUserModelId
    } else {
        $process = & $adapter.StartProcess ([string]$package.ExecutablePath) $arguments $null
    }
    if ($null -eq $process) { return New-CcodStartResult -Outcome 'Failed' -Snapshot $null -Process $null }
    if ($Mode -ceq 'Special') {
        while ($true) {
            $candidate = Get-CcodTransactionProcessResult -RendererPort ([int]$RendererPort) -MainPort ([int]$MainPort) `
                -TransactionTimeUtc $transactionTimeUtc -Adapters $adapter
            switch -CaseSensitive ($candidate.Outcome) {
                'Confirmed' { return New-CcodStartResult -Outcome 'Started' -Snapshot $candidate.Snapshot -Process $process }
                'PortConflict' { return New-CcodStartResult -Outcome 'PortUnavailable' -Snapshot $candidate.Snapshot -Process $process }
                'Ambiguous' { return New-CcodStartResult -Outcome 'Failed' -Snapshot $null -Process $process }
            }
            $now = & $adapter.GetUtcNow
            if ($now -isnot [DateTimeOffset] -or $now.ToUniversalTime() -ge $deadline) {
                return New-CcodStartResult -Outcome 'StartUnconfirmed' -Snapshot $null -Process $process
            }
            & $adapter.Delay $StartupPollMilliseconds
        }
    }
    return New-CcodStartResult -Outcome 'Started' -Snapshot $null -Process $process
}

Export-ModuleMember -Function Get-CcodProcessIdentityObservation, Get-CcodProcessSnapshot, Test-CcodProcessMatch, Get-CcodStalePackageProcessSnapshot, Get-CcodStalePackageRootResult, Get-CcodVerifiedProcessTree, Get-CcodVerifiedStaleProcessTree, Get-CcodTransactionProcessResult, Find-CcodTransactionProcess, Stop-CcodProcessIfMatch, Stop-CcodStaleProcessIfMatch, Request-CcodProcessGracefulCloseIfMatch, Request-CcodStaleProcessGracefulCloseIfMatch, Wait-CcodProcessExitIfMatch, Wait-CcodStaleProcessExitIfMatch, Start-CcodProcess, Request-CcodOrdinaryPackagedLaunch, Wait-CcodVerifiedOrdinaryRoot, Get-CcodAvailableLoopbackPort, Wait-CcodPortClosed
