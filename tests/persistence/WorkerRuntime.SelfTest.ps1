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

$results += Invoke-CcodTest 'worker process lifecycle starts polls waits and terminates' {
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
        $scriptText = @(
            '[CmdletBinding()]',
            'param([string]$RequestPath,[string]$ResultPath)',
            '$value = Get-Content -LiteralPath $RequestPath -Raw | ConvertFrom-Json',
            '$cim = Get-CimInstance Win32_Process -Filter ("ProcessId=" + $PID) -ErrorAction Stop',
            '[IO.File]::WriteAllText((Join-Path $env:TEMP "ccod-worker-parent.txt"), [string]$cim.ParentProcessId, [Text.UTF8Encoding]::new($false))',
            ('$payloadText = ' + "'" + $json + "'"),
            '[IO.File]::WriteAllText($ResultPath, $payloadText, [Text.UTF8Encoding]::new($false))',
            '[Console]::Out.WriteLine($payloadText)',
            'exit 0'
        ) -join "`r`n"
        [IO.File]::WriteAllText($workerScript, $scriptText, [Text.UTF8Encoding]::new($false))

        $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $receipt = Start-CcodWorkerProcess -Kind 'Lifecycle' -ScriptPath $workerScript -RequestPath $requestPath -ResultPath $resultPath -StderrPath $stderrPath -PowerShellPath $powershell
        Assert-CcodTrue ($receipt.ProcessId -is [int] -and $receipt.ProcessId -ge 1) 'worker start returns a real pid'
        Assert-CcodTrue ($receipt.CreationTimeUtc -cmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}Z$') 'worker start returns canonical creation time'
        Assert-CcodTrue ($null -ne $receipt.Handle) 'worker start returns a process handle'
        $parentFile = Join-Path $env:TEMP 'ccod-worker-parent.txt'
        if (Test-Path $parentFile) {
            Remove-Item $parentFile -Force
        }

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
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

$results += Invoke-CcodTest 'worker termination stops a running worker and unsafe paths are rejected' {
    $root = New-CcodWorkerTempRoot
    $workerScript = Join-Path $root 'hang.ps1'
    $requestPath = Join-Path $root 'request.json'
    $resultPath = Join-Path $root 'result.json'
    try {
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        [IO.File]::WriteAllText($requestPath, '{ "schemaVersion": 1 }', [Text.UTF8Encoding]::new($false))
        $scriptText = @(
            '[CmdletBinding()]',
            'param([string]$RequestPath,[string]$ResultPath)',
            'Start-Sleep -Seconds 120'
        ) -join "`r`n"
        [IO.File]::WriteAllText($workerScript, $scriptText, [Text.UTF8Encoding]::new($false))
        $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $receipt = Start-CcodWorkerProcess -Kind 'Controller' -ScriptPath $workerScript -RequestPath $requestPath -ResultPath $resultPath -StderrPath $null -PowerShellPath $powershell
        $slot = New-CcodWorkerSlot -Receipt $receipt -RequestPath $requestPath -ResultPath $resultPath -StderrPath $null
        try {
            $stopped = Stop-CcodWorkerProcess -Slot $slot
            Assert-CcodEqual $true $stopped 'termination stops the running worker'
            $identity = Get-CcodWorkerIdentity -Pid $slot.ProcessId
            Assert-CcodTrue ($null -eq $identity) 'terminated worker identity is gone'
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
