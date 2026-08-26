$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestSupport.ps1')

$repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$modulePath = Join-Path $repositoryRoot 'src\persistence\modules\WorkerRuntime.psm1'
if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
    throw "WorkerRuntime module is missing: $modulePath"
}
Import-Module $modulePath -Force
Import-Module (Join-Path $repositoryRoot 'src\persistence\modules\PersistenceIO.psm1') -Force

function New-CcodWorkerTempRoot {
    return (Join-Path ([IO.Path]::GetTempPath()) ("ccod-worker-" + [guid]::NewGuid().ToString('N')))
}

function New-CcodWorkerSlot {
    param([Parameter(Mandatory)]$Receipt, [Parameter(Mandatory)][string]$RequestPath, [Parameter(Mandatory)][string]$ResultPath, [AllowNull()][string]$StderrPath)

    return [pscustomobject][ordered]@{
        ProcessId = [int]$Receipt.ProcessId
        CreationTimeUtc = [string]$Receipt.CreationTimeUtc
        Handle = $Receipt.Handle
        JobHandle = $Receipt.JobHandle
        RequestPath = $RequestPath
        ResultPath = $ResultPath
        StderrPath = $StderrPath
    }
}

$results = @()

$results += Invoke-CcodTest 'process enumeration returns one array object, not flattened scalars' {
    $items = @(Get-CcodChatGptProcessIds)
    Assert-CcodEqual 1 $items.Count 'process enumeration emits exactly one output object'
    Assert-CcodTrue ($items[0] -is [int[]] -or $items[0] -is [array]) 'the single output is an array'
    foreach ($pidValue in $items[0]) {
        Assert-CcodTrue ($pidValue -is [int] -and $pidValue -ge 1) 'each entry is a positive int'
    }
}

$results += Invoke-CcodTest 'worker leaf state reports missing and existing paths' {
    $root = New-CcodWorkerTempRoot
    try {
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $missing = Get-CcodWorkerLeafState -Path (Join-Path $root 'missing.request.json')
        Assert-CcodEqual $false $missing.Exists 'missing leaf is reported absent'
        Assert-CcodEqual $false $missing.IsReparse 'missing leaf is not a reparse point'
        $path = Join-Path $root 'existing.result.json'
        [IO.File]::WriteAllText($path, '{ "schemaVersion": 1 }', [Text.UTF8Encoding]::new($false))
        $existing = Get-CcodWorkerLeafState -Path $path
        Assert-CcodEqual $true $existing.Exists 'existing leaf is reported present'
        Assert-CcodEqual $false $existing.IsReparse 'ordinary file is not a reparse point'
    } finally {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

$results += Invoke-CcodTest 'worker request and result round-trip through atomic JSON' {
    $root = New-CcodWorkerTempRoot
    try {
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $request = [pscustomobject][ordered]@{
            schemaVersion = 1
            action = 'StaticProbe'
            requestId = ('a' * 32)
            runtimeId = 'runtime-1'
            targetIdentity = [pscustomobject][ordered]@{ pid = 71; creationTimeUtc = '2030-02-03T03:01:00.0000000Z' }
            timeoutMilliseconds = 30000
        }
        $requestPath = Join-Path $root 'static-probe-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.request.json'
        Write-CcodWorkerRequest -Path $requestPath -Request $request
        Assert-CcodTrue (Test-Path -LiteralPath $requestPath) 'request file is written'
        $read = Read-CcodStrictJson -Path $requestPath -ExpectedSchema 1 -Kind 'worker request'
        Assert-CcodEqual 'StaticProbe' $read.action 'request round-trips the action'
        Assert-CcodEqual 71 $read.targetIdentity.pid 'request round-trips the target pid'

        $result = [pscustomobject][ordered]@{
            schemaVersion = 1
            action = 'StaticProbe'
            ok = $true
            requestId = ('a' * 32)
            runtimeId = 'runtime-1'
            targetIdentity = [pscustomobject][ordered]@{ pid = 71; creationTimeUtc = '2030-02-03T03:01:00.0000000Z' }
            probe = $null
            error = $null
        }
        $resultPath = Join-Path $root 'static-probe-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.result.json'
        Write-CcodAtomicJson -Path $resultPath -Value $result
        $loaded = Read-CcodWorkerResult -Path $resultPath
        Assert-CcodEqual $true $loaded.ok 'worker result reads back ok flag'
        Assert-CcodEqual 71 $loaded.targetIdentity.pid 'worker result round-trips target'

        Remove-CcodWorkerFile -Path $requestPath
        Remove-CcodWorkerFile -Path $resultPath
        Assert-CcodTrue (-not (Test-Path -LiteralPath $requestPath)) 'request file removed'
        Assert-CcodTrue (-not (Test-Path -LiteralPath $resultPath)) 'result file removed'
    } finally {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

$results += Invoke-CcodTest 'lifecycle worker request constructor and result validator enforce exact correlation' {
    $owner=[pscustomobject][ordered]@{pid=401;creationTimeUtc='2030-02-03T04:05:06.0000000Z'}
    $request=New-CcodLifecycleWorkerRequest -TransactionId '11111111-2222-3333-4444-555555555555' -Action Apply -RuntimeId '2.5.0-a' `
        -RuntimeGeneration 4 -LeaseEpoch 9 -OwnerIdentity $owner -NotBeforeUtc '2030-02-03T04:05:10.0000000Z' -TimeoutMilliseconds 45000
    Assert-CcodEqual 'schemaVersion,transactionId,action,runtimeId,runtimeGeneration,leaseEpoch,ownerIdentity,notBeforeUtc,timeoutMilliseconds' (($request.PSObject.Properties.Name)-join ',') 'lifecycle request exact shape'
    Assert-CcodTrue ($request.runtimeGeneration -is [UInt64]) 'runtime generation retains UInt64 type'
    Assert-CcodTrue ($request.leaseEpoch -is [UInt64]) 'lease epoch retains UInt64 type'
    $result=[pscustomobject][ordered]@{schemaVersion=1;transactionId=$request.transactionId;action='Apply';ok=$true;outcome='Activated';observation='Special';error=$null}
    Assert-CcodLifecycleWorkerResult -Result $result -ExpectedRequest $request|Out-Null
    $result.transactionId='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
    Assert-CcodThrows { Assert-CcodLifecycleWorkerResult -Result $result -ExpectedRequest $request } 'CCOD_WORKER_RESULT_INVALID'
}

$results += Invoke-CcodTest 'real worker remains suspended until exact Job assignment and thread resume' {
    $root = New-CcodWorkerTempRoot
    $workerScript = Join-Path $root 'worker.ps1'
    $requestPath = Join-Path $root 'request.json'
    $resultPath = Join-Path $root 'result.json'
    $stderrPath = Join-Path $root 'worker.stderr.log'
    try {
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $request = [pscustomobject][ordered]@{ schemaVersion = 1; action = 'Probe'; requestId = ('b' * 32) }
        Write-CcodAtomicJson -Path $requestPath -Value $request
        $payload = [pscustomobject][ordered]@{ schemaVersion = 1; action = 'Probe'; ok = $true; requestId = ('b' * 32); runtimeId = 'runtime-1'; targetIdentity = $null; probe = $null; error = $null }
        $json = $payload | ConvertTo-Json -Depth 8 -Compress
        $markerPath=Join-Path $root 'after-resume.marker';$parentFile=Join-Path $root 'worker-parent.txt'
        $escapedModule=$modulePath.Replace("'","''");$escapedMarker=$markerPath.Replace("'","''");$escapedParent=$parentFile.Replace("'","''")
        $scriptText = @(
            '[CmdletBinding()]',
            'param([string]$RequestPath,[string]$ResultPath)',
            '$value = Get-Content -LiteralPath $RequestPath -Raw | ConvertFrom-Json',
            ("[IO.File]::WriteAllText('"+$escapedMarker+"','released',[Text.UTF8Encoding]::new(`$false))"),
            '$cim = Get-CimInstance Win32_Process -Filter ("ProcessId=" + $PID) -ErrorAction Stop',
            ("[IO.File]::WriteAllText('"+$escapedParent+"', [string]`$cim.ParentProcessId, [Text.UTF8Encoding]::new(`$false))"),
            ('$payloadText = ' + "'" + $json + "'"),
            '[IO.File]::WriteAllText($ResultPath, $payloadText, [Text.UTF8Encoding]::new($false))',
            '[Console]::Out.WriteLine($payloadText)',
            'exit 0'
        ) -join "`r`n"
        [IO.File]::WriteAllText($workerScript, $scriptText, [Text.UTF8Encoding]::new($false))

        $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $workerModule=Get-Module WorkerRuntime|Select-Object -First 1;$defaults=& $workerModule {Get-CcodWorkerRuntimeAdapters $null}
        $global:CcodSuspendedMarkerPath=$markerPath;$global:CcodSuspendedNative=$null;$global:CcodWorkerDefaults=$defaults
        $receipt = Start-CcodWorkerProcess -Kind 'Lifecycle' -ScriptPath $workerScript -RequestPath $requestPath -ResultPath $resultPath -StderrPath $stderrPath -PowerShellPath $powershell -Adapters @{
            CreateSuspendedProcess={param($File,$Arguments)$native=&$global:CcodWorkerDefaults.CreateSuspendedProcess $File $Arguments;$global:CcodSuspendedNative=$native;$native}
            AssignProcessToJob={param($Job,$Native)if([IO.File]::Exists($global:CcodSuspendedMarkerPath)){throw 'child ran before assignment'};&$global:CcodWorkerDefaults.AssignProcessToJob $Job $Native}
        }
        Assert-CcodEqual $false ([IO.File]::Exists($markerPath)) 'assignment occurs before child can read request or create operation marker'
        Assert-CcodTrue ($receipt.ProcessId -is [int] -and $receipt.ProcessId -ge 1) 'worker start returns a real pid'
        Assert-CcodTrue ($receipt.CreationTimeUtc -cmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}Z$') 'worker start returns canonical creation time'
        Assert-CcodTrue ($null -ne $receipt.Handle) 'worker start returns a process handle'
        Assert-CcodTrue ($null-ne$receipt.JobHandle -and -not$receipt.JobHandle.IsClosed) 'worker start retains the kill-on-close Job handle'
        Assert-CcodTrue ($global:CcodSuspendedNative.ProcessHandle.IsClosed-and$global:CcodSuspendedNative.ThreadHandle.IsClosed) 'primary native process and thread handles close after resume'
        $slot = New-CcodWorkerSlot -Receipt $receipt -RequestPath $requestPath -ResultPath $resultPath -StderrPath $stderrPath
        $completed = Wait-CcodWorkerExit -Slot $slot -TimeoutMilliseconds 20000
        Assert-CcodEqual $true $completed 'worker exits within the wait window'
        if (Test-Path $parentFile) {
            $workerParent = [int](Get-Content $parentFile -Raw)
            Assert-CcodEqual $PID $workerParent 'worker process is a direct child of the calling supervisor'
            Remove-Item $parentFile -Force
        } else {
            throw 'ASSERT_TRUE_FAILED: worker parent identity file was not written'
        }
        $poll = Get-CcodWorkerPoll -Slot $slot
        Assert-CcodEqual $true $poll.Completed 'poll reports completion'
        Assert-CcodEqual 0 $poll.ExitCode 'worker exits zero'
        Assert-CcodTrue ($poll.StdoutText -match '"ok"\s*:\s*true') 'poll stdout carries the result frame'
        Assert-CcodEqual 0 $poll.StderrByteCount 'stderr stays empty'

        $identity = Get-CcodWorkerIdentity -Pid $slot.ProcessId
        Assert-CcodTrue ($null -eq $identity) 'identity is null after exit'

        Close-CcodWorkerHandle -Slot $slot
        Remove-CcodWorkerFile -Path $requestPath
        Remove-CcodWorkerFile -Path $resultPath
        Remove-CcodWorkerFile -Path $stderrPath
        Assert-CcodTrue (-not (Test-Path -LiteralPath $resultPath)) 'result file cleaned'
    } finally {
        Remove-Variable CcodSuspendedMarkerPath,CcodSuspendedNative,CcodWorkerDefaults -Scope Global -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

$results += Invoke-CcodTest 'poll uses the retained worker exit code when PID lookup resolves an unrelated live process' {
    $root = New-CcodWorkerTempRoot
    $workerScript = Join-Path $root 'failed-worker.ps1'
    $requestPath = Join-Path $root 'request.json'
    $resultPath = Join-Path $root 'result.json'
    try {
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        [IO.File]::WriteAllText($requestPath, '{ "schemaVersion": 1 }', [Text.UTF8Encoding]::new($false))
        $payload = '{"schemaVersion":1,"ok":false,"error":{"code":"CCOD_TEST_FAILURE"}}'
        $escapedPayload = $payload.Replace("'", "''")
        $scriptText = @(
            '[CmdletBinding()]',
            'param([string]$RequestPath,[string]$ResultPath)',
            ("[IO.File]::WriteAllText(`$ResultPath,'" + $escapedPayload + "',[Text.UTF8Encoding]::new(`$false))"),
            'exit 1'
        ) -join "`r`n"
        [IO.File]::WriteAllText($workerScript, $scriptText, [Text.UTF8Encoding]::new($false))

        $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $receipt = Start-CcodWorkerProcess -Kind 'Lifecycle' -ScriptPath $workerScript -RequestPath $requestPath -ResultPath $resultPath -StderrPath $null -PowerShellPath $powershell
        $slot = New-CcodWorkerSlot -Receipt $receipt -RequestPath $requestPath -ResultPath $resultPath -StderrPath $null
        try {
            Assert-CcodTrue (Wait-CcodWorkerExit -Slot $slot -TimeoutMilliseconds 20000) 'failed worker exits within the wait window'
            Assert-CcodTrue ($null -eq (Get-CcodWorkerIdentity -Pid $slot.ProcessId)) 'failed worker identity is gone before polling'
            $slot.ProcessId = [int]$PID
            $poll = Get-CcodWorkerPoll -Slot $slot
            Assert-CcodEqual $true $poll.Completed 'poll reports failed worker completion'
            Assert-CcodEqual 1 $poll.ExitCode 'poll ignores an unrelated process returned for the numeric PID lookup'
            Assert-CcodTrue ($poll.StdoutText -match 'CCOD_TEST_FAILURE') 'poll carries the failed result frame'
        } finally {
            Close-CcodWorkerHandle -Slot $slot
            Remove-CcodWorkerFile -Path $requestPath
            Remove-CcodWorkerFile -Path $resultPath
        }
    } finally {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

$results += Invoke-CcodTest 'Job assignment failure kills the exact gated child before request operation' {
    $root=New-CcodWorkerTempRoot;$workerScript=Join-Path $root 'assignment-failure.ps1';$requestPath=Join-Path $root 'request.json';$resultPath=Join-Path $root 'result.json';$markerPath=Join-Path $root 'operation.marker';$capturePath=Join-Path $root 'started.json'
    try{
        $global:CcodWorkerAssignmentCapturePath=$capturePath
        [IO.Directory]::CreateDirectory($root)|Out-Null;[IO.File]::WriteAllText($requestPath,'{"schemaVersion":1}',[Text.UTF8Encoding]::new($false))
        $escapedModule=$modulePath.Replace("'","''");$escapedMarker=$markerPath.Replace("'","''")
        $scriptText=@('[CmdletBinding()]','param([string]$RequestPath,[string]$ResultPath)',("[IO.File]::WriteAllText('"+$escapedMarker+"','ran',[Text.UTF8Encoding]::new(`$false))"),'Start-Sleep -Seconds 30')-join"`r`n"
        [IO.File]::WriteAllText($workerScript,$scriptText,[Text.UTF8Encoding]::new($false));$powershell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        Assert-CcodThrows {Start-CcodWorkerProcess -Kind Lifecycle -ScriptPath $workerScript -RequestPath $requestPath -ResultPath $resultPath -StderrPath $null -PowerShellPath $powershell -Adapters @{
            AssignProcessToJob={param($Job,$Native)[IO.File]::WriteAllText($global:CcodWorkerAssignmentCapturePath,(([ordered]@{pid=[int]$Native.ProcessId}|ConvertTo-Json -Compress)),[Text.UTF8Encoding]::new($false));$false}
        }|Out-Null} 'CCOD_WORKER_START_FAILED'
        Assert-CcodTrue ([IO.File]::Exists($capturePath)) 'assignment failure starts one gated child'
        $captured=Get-Content -LiteralPath $capturePath -Raw|ConvertFrom-Json
        $clock=[Diagnostics.Stopwatch]::StartNew();do{$identity=Get-CcodWorkerIdentity -Pid ([int]$captured.pid);if($null-eq$identity){$stopped=$true;break};if($clock.ElapsedMilliseconds-ge5000){$stopped=$false;break};Start-Sleep -Milliseconds 50}while($true)
        Assert-CcodTrue ([int]$captured.pid-gt0) 'assignment failure started one exact gated child'
        Assert-CcodTrue $stopped 'assignment failure terminates the exact child'
        Assert-CcodEqual $false ([IO.File]::Exists($markerPath)) 'unassigned child never crosses the startup gate'
    }finally{Remove-Variable -Name CcodWorkerAssignmentCapturePath -Scope Global -ErrorAction SilentlyContinue;if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}}
}

$results += Invoke-CcodTest 'suspended process creation failure closes the already-created Job and starts no child' {
    $root=New-CcodWorkerTempRoot;$workerScript=Join-Path $root 'never-start.ps1';$requestPath=Join-Path $root 'request.json';$resultPath=Join-Path $root 'result.json'
    $global:CcodWorkerContainmentFailure=[pscustomobject]@{Job=$null;Disposed=$false;Started=$false}
    try{
        [IO.Directory]::CreateDirectory($root)|Out-Null;[IO.File]::WriteAllText($workerScript,'param()',[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText($requestPath,'{}',[Text.UTF8Encoding]::new($false))
        Assert-CcodThrows {Start-CcodWorkerProcess -Kind Lifecycle -ScriptPath $workerScript -RequestPath $requestPath -ResultPath $resultPath -StderrPath $null -PowerShellPath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -Adapters @{
            CreateJob={$job=[pscustomobject]@{IsClosed=$false};$global:CcodWorkerContainmentFailure.Job=$job;$job}
            CreateSuspendedProcess={param($File,$Arguments)$global:CcodWorkerContainmentFailure.Started=$true;throw 'create suspended failed'}
            DisposeJob={param($Job)$Job.IsClosed=$true;$global:CcodWorkerContainmentFailure.Disposed=$true}
        }|Out-Null} 'CCOD_WORKER_START_FAILED'
        Assert-CcodTrue $global:CcodWorkerContainmentFailure.Started 'suspended create boundary is attempted once'
        Assert-CcodTrue $global:CcodWorkerContainmentFailure.Disposed 'suspended create failure closes the already-created Job'
    }finally{Remove-Variable CcodWorkerContainmentFailure -Scope Global -ErrorAction SilentlyContinue;if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}}
}

$results += Invoke-CcodTest 'resume failure kills the exact assigned suspended child and closes native handles' {
    $root=New-CcodWorkerTempRoot;$workerScript=Join-Path $root 'resume-failure.ps1';$requestPath=Join-Path $root 'request.json';$resultPath=Join-Path $root 'result.json';$markerPath=Join-Path $root 'operation.marker';$global:CcodResumeFailure=[pscustomobject]@{Native=$null}
    try{
        [IO.Directory]::CreateDirectory($root)|Out-Null;[IO.File]::WriteAllText($workerScript,("param([string]`$RequestPath,[string]`$ResultPath)`r`n[IO.File]::WriteAllText('"+$markerPath.Replace("'","''")+"','ran')"),[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText($requestPath,'{}',[Text.UTF8Encoding]::new($false))
        $module=Get-Module WorkerRuntime|Select-Object -First 1;$global:CcodResumeDefaults=&$module{Get-CcodWorkerRuntimeAdapters $null}
        Assert-CcodThrows {Start-CcodWorkerProcess -Kind Lifecycle -ScriptPath $workerScript -RequestPath $requestPath -ResultPath $resultPath -StderrPath $null -PowerShellPath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -Adapters @{
            CreateSuspendedProcess={param($File,$Arguments)$native=&$global:CcodResumeDefaults.CreateSuspendedProcess $File $Arguments;$global:CcodResumeFailure.Native=$native;$native};ResumeProcess={param($Native)$false}
        }|Out-Null} 'CCOD_WORKER_START_FAILED'
        Assert-CcodEqual $false ([IO.File]::Exists($markerPath)) 'resume failure permits zero child operation'
        Assert-CcodTrue ($global:CcodResumeFailure.Native.ProcessHandle.IsClosed-and$global:CcodResumeFailure.Native.ThreadHandle.IsClosed) 'resume failure closes both native handles'
        $clock=[Diagnostics.Stopwatch]::StartNew();do{$identity=Get-CcodWorkerIdentity -Pid $global:CcodResumeFailure.Native.ProcessId;if($null-eq$identity){$gone=$true;break};if($clock.ElapsedMilliseconds-ge5000){$gone=$false;break};Start-Sleep -Milliseconds 50}while($true);Assert-CcodTrue $gone 'resume failure terminates exact suspended child'
    }finally{Remove-Variable CcodResumeFailure,CcodResumeDefaults -Scope Global -ErrorAction SilentlyContinue;if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}}
}

$results += Invoke-CcodTest 'closing the kill-on-close Job stops a surviving gated worker and proves exit' {
    $root = New-CcodWorkerTempRoot
    $workerScript = Join-Path $root 'hang.ps1'
    $requestPath = Join-Path $root 'request.json'
    $resultPath = Join-Path $root 'result.json'
    try {
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        [IO.File]::WriteAllText($requestPath, '{ "schemaVersion": 1 }', [Text.UTF8Encoding]::new($false))
        $escapedModule=$modulePath.Replace("'","''")
        $scriptText = @(
            '[CmdletBinding()]',
            'param([string]$RequestPath,[string]$ResultPath)',
            'Start-Sleep -Seconds 120'
        ) -join "`r`n"
        [IO.File]::WriteAllText($workerScript, $scriptText, [Text.UTF8Encoding]::new($false))
        $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $receipt = Start-CcodWorkerProcess -Kind 'StaticProbe' -ScriptPath $workerScript -RequestPath $requestPath -ResultPath $resultPath -StderrPath $null -PowerShellPath $powershell
        $slot = New-CcodWorkerSlot -Receipt $receipt -RequestPath $requestPath -ResultPath $resultPath -StderrPath $null
        try {
            $stopped = Stop-CcodWorkerProcess -Slot $slot
            Assert-CcodEqual $true $stopped 'Job close stops the running worker'
            Assert-CcodTrue $slot.JobHandle.IsClosed 'kill-on-close Job handle is closed by termination'
            $identity = Get-CcodWorkerIdentity -Pid $slot.ProcessId
            Assert-CcodTrue ($null-eq$identity-or$identity.CreationTimeUtc-cne$slot.CreationTimeUtc) 'terminated exact worker identity is gone'
        } finally {
            Close-CcodWorkerHandle -Slot $slot
            Remove-CcodWorkerFile -Path $requestPath
        }
        Assert-CcodThrows { Remove-CcodWorkerFile -Path 'relative.json' } 'CCOD_WORKER_PATH_INVALID'
        Assert-CcodThrows { Get-CcodWorkerLeafState -Path 'relative.json' } 'CCOD_WORKER_PATH_INVALID'
    } finally {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

$results += Invoke-CcodTest 'log directory opener rejects a missing directory' {
    $root = New-CcodWorkerTempRoot
    try {
        Assert-CcodThrows { Open-CcodLogDirectory -Path (Join-Path $root 'missing-logs') } 'CCOD_WORKER_LOG_MISSING'
    } finally {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

$results | Format-Table -AutoSize
Write-Host ("Worker runtime self-tests passed: {0}" -f $results.Count)
